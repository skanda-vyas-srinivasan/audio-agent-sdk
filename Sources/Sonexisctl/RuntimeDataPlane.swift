import Foundation

public struct RuntimeDataPlaneMetrics: Equatable, Sendable {
    public let framesForwarded: UInt64
    public let queueDroppedFrames: UInt64
    public let noSubscriberFrames: UInt64
    public let slowConsumerDisconnects: UInt64
    public let bytesTransmitted: UInt64
    public let connectedClients: Int
    public let queueHighWaterMark: Int
}

public final class RuntimeDataPlane: @unchecked Sendable {
    public let path: String
    public let streamID: UUID
    private let queue: DispatchQueue
    private let listener: UnixSocketListener
    private let maximumSubscribers: Int
    private let warningHandler: @Sendable (_ disconnectedClients: Int) -> Void
    private let capacityLimit = 64
    private let capacity = DispatchSemaphore(value: 64)
    private let metricsLock = NSLock()
    private var clients: [UUID: UnixSocketConnection] = [:]
    private var running = false
    private var queuedPackets = 0
    private var queueHighWater = 0
    private var forwarded: UInt64 = 0
    private var queueDropped: UInt64 = 0
    private var noSubscriber: UInt64 = 0
    private var slowDisconnects: UInt64 = 0
    private var transmittedBytes: UInt64 = 0
    private var pendingDroppedFrames: UInt64 = 0
    // Only the delivery queue owns losses discovered after admission.
    private var deliveryDroppedFrames: UInt64 = 0
    private var lastSequence: UInt64 = 0
    private var lastTimestamp: UInt64 = 0

    public init(path: String, streamID: UUID, maximumSubscribers: Int = 4,
                warningHandler: @escaping @Sendable (_ disconnectedClients: Int) -> Void = { _ in }) {
        self.path = path
        self.streamID = streamID
        self.maximumSubscribers = maximumSubscribers
        self.warningHandler = warningHandler
        queue = DispatchQueue(label: "com.sonexis.runtime.data.\(streamID.uuidString)")
        listener = UnixSocketListener(path: path, queue: queue, acceptedConnectionsNonBlocking: true)
    }

    public func start() throws {
        try queue.sync {
            guard !running else { return }
            try listener.start { [weak self] connection in
                guard let self else { connection.close(); return }
                self.clients = self.clients.filter { !$0.value.isPeerClosed() }
                guard self.clients.count < self.maximumSubscribers else {
                    connection.close()
                    return
                }
                self.clients[UUID()] = connection
            }
            running = true
        }
    }

    /// Enqueues at most 64 packets. The newest packet is dropped when full. A
    /// subscriber whose nonblocking socket cannot accept a complete packet is
    /// disconnected, preserving framing for every remaining subscriber.
    public func offer(_ frame: RuntimeBackendAudioFrame) {
        // Admission, loss attribution, and submission share one ordering lock.
        // An older queued packet must never consume a later rejected packet's loss.
        metricsLock.lock()
        guard capacity.wait(timeout: .now()) == .success else {
            queueDropped &+= UInt64(frame.frameCount)
            pendingDroppedFrames &+= UInt64(frame.frameCount) &+ UInt64(frame.droppedFramesBefore)
            metricsLock.unlock()
            return
        }
        let admissionDrops = pendingDroppedFrames
        pendingDroppedFrames = 0
        queuedPackets += 1
        queueHighWater = max(queueHighWater, queuedPackets)
        queue.async { [weak self] in
            defer {
                self?.metricsLock.lock()
                self?.queuedPackets -= 1
                self?.metricsLock.unlock()
                self?.capacity.signal()
            }
            guard let self, self.running else { return }
            self.clients = self.clients.filter { !$0.value.isPeerClosed() }
            guard !self.clients.isEmpty else {
                self.recordNoSubscriber(frame.frameCount)
                self.deliveryDroppedFrames &+= admissionDrops &+ UInt64(frame.frameCount)
                    &+ UInt64(frame.droppedFramesBefore)
                return
            }

            let pendingDrops = admissionDrops &+ self.deliveryDroppedFrames
            self.deliveryDroppedFrames = 0
            var flags: RuntimePCMFrameFlags = frame.discontinuity || pendingDrops > 0 ? [.discontinuity] : []
            let totalDropped = UInt64(frame.droppedFramesBefore) &+ pendingDrops
            if totalDropped > 0 { flags.insert(.discontinuity) }
            do {
                guard frame.payload.count <= Int(UInt32.max) else {
                    self.recordQueueDrop(frame.frameCount)
                    self.deliveryDroppedFrames &+= pendingDrops &+ UInt64(frame.frameCount)
                        &+ UInt64(frame.droppedFramesBefore)
                    return
                }
                let header = RuntimePCMFrameHeader(flags: flags,
                    payloadByteCount: UInt32(frame.payload.count), streamID: self.streamID,
                    sequence: frame.sequence, timestampNanoseconds: frame.timestampNanoseconds,
                    sampleRate: frame.format.sampleRate, frameCount: frame.frameCount,
                    channelCount: frame.format.channelCount, sampleFormat: frame.format.sampleFormat,
                    droppedFramesBefore: UInt32(clamping: totalDropped))
                let encoded = try RuntimePCMFrameCodec.encode(header: header, payload: frame.payload)
                var dead: [UUID] = []
                var successfulWrites = 0
                for (id, client) in self.clients {
                    do {
                        try client.write(encoded)
                        successfulWrites += 1
                    } catch {
                        dead.append(id)
                        client.close()
                    }
                }
                dead.forEach { self.clients.removeValue(forKey: $0) }
                self.metricsLock.lock()
                self.slowDisconnects &+= UInt64(dead.count)
                if successfulWrites > 0 {
                    self.forwarded &+= UInt64(frame.frameCount)
                    self.transmittedBytes &+= UInt64(encoded.count * successfulWrites)
                } else {
                    self.noSubscriber &+= UInt64(frame.frameCount)
                    self.deliveryDroppedFrames &+= totalDropped &+ UInt64(frame.frameCount)
                }
                self.metricsLock.unlock()
                if !dead.isEmpty { self.warningHandler(dead.count) }
                self.lastSequence = frame.sequence
                self.lastTimestamp = frame.timestampNanoseconds
            } catch {
                self.deliveryDroppedFrames &+= totalDropped &+ UInt64(frame.frameCount)
                self.recordQueueDrop(frame.frameCount)
            }
        }
        metricsLock.unlock()
    }

    public func stop() {
        queue.sync {
            guard running else { return }
            running = false
            let eos = RuntimePCMFrameHeader(flags: [.endOfStream], payloadByteCount: 0,
                streamID: streamID, sequence: lastSequence &+ 1,
                timestampNanoseconds: lastTimestamp, sampleRate: 0, frameCount: 0,
                channelCount: 0, sampleFormat: .pcmS16LE)
            if let encoded = try? RuntimePCMFrameCodec.encode(header: eos, payload: Data()) {
                clients.values.forEach { try? $0.write(encoded) }
            }
            listener.stop()
            clients.values.forEach { $0.close() }
            clients.removeAll()
        }
    }

    public func metrics() -> RuntimeDataPlaneMetrics {
        metricsLock.lock()
        let counters = (forwarded, queueDropped, noSubscriber, slowDisconnects,
                        transmittedBytes, queueHighWater)
        metricsLock.unlock()
        let clientCount = queue.sync { clients.count }
        return RuntimeDataPlaneMetrics(framesForwarded: counters.0,
            queueDroppedFrames: counters.1, noSubscriberFrames: counters.2,
            slowConsumerDisconnects: counters.3, bytesTransmitted: counters.4,
            connectedClients: clientCount, queueHighWaterMark: counters.5)
    }

    private func recordQueueDrop(_ frames: UInt32) {
        metricsLock.lock()
        queueDropped &+= UInt64(frames)
        metricsLock.unlock()
    }

    private func recordNoSubscriber(_ frames: UInt32) {
        metricsLock.lock()
        noSubscriber &+= UInt64(frames)
        metricsLock.unlock()
    }
}

/// One bounded NDJSON event stream. Events never share a writer with control
/// responses, so a slow watcher cannot interleave or stall request traffic.
public final class RuntimeEventPlane: @unchecked Sendable {
    public let path: String
    private let queue: DispatchQueue
    private let listener: UnixSocketListener
    private let capacity = DispatchSemaphore(value: 256)
    private let metricsLock = NSLock()
    private var connection: UnixSocketConnection?
    private var running = false
    private var droppedEvents: UInt64 = 0
    private var pendingDroppedEvents: UInt64 = 0
    private var nextSequence: UInt64 = 1

    public init(path: String) {
        self.path = path
        queue = DispatchQueue(label: "com.sonexis.runtime.events.\(UUID().uuidString)")
        listener = UnixSocketListener(path: path, queue: queue, acceptedConnectionsNonBlocking: true)
    }

    public func start() throws {
        try queue.sync {
            try listener.start { [weak self] candidate in
                guard let self else { candidate.close(); return }
                if let existing = self.connection, !existing.isPeerClosed() {
                    candidate.close()
                } else {
                    self.connection?.close()
                    self.connection = candidate
                }
            }
            running = true
        }
    }

    public func offer(_ event: RuntimeEventDTO) {
        guard capacity.wait(timeout: .now()) == .success else {
            recordDrop()
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.capacity.signal() }
            guard self.running, let connection = self.connection else {
                self.recordDrop()
                return
            }
            let pending = self.takePendingDrops()
            let delivered = event.delivered(sequence: self.nextSequence,
                droppedEventsBefore: pending)
            do {
                try connection.write(RuntimeProtocolCodec.encodeLine(delivered))
                self.nextSequence &+= 1
            } catch {
                connection.close()
                self.connection = nil
                self.restoreDrops(pending &+ 1)
            }
        }
    }

    public func metrics() -> UInt64 {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return droppedEvents
    }

    public func stop() {
        queue.sync {
            guard running else { return }
            running = false
            listener.stop()
            connection?.close()
            connection = nil
        }
    }

    private func recordDrop() {
        metricsLock.lock()
        droppedEvents &+= 1
        pendingDroppedEvents &+= 1
        metricsLock.unlock()
    }

    private func takePendingDrops() -> UInt64 {
        metricsLock.lock()
        let value = pendingDroppedEvents
        pendingDroppedEvents = 0
        metricsLock.unlock()
        return value
    }

    private func restoreDrops(_ count: UInt64) {
        metricsLock.lock()
        droppedEvents &+= 1
        pendingDroppedEvents &+= count
        metricsLock.unlock()
    }
}

public final class RuntimeEventHub: @unchecked Sendable {
    private final class Subscription {
        let id: String
        let ownerID: String
        let types: Set<RuntimeEventTypeDTO>
        let plane: RuntimeEventPlane
        init(id: String, ownerID: String, types: Set<RuntimeEventTypeDTO>, plane: RuntimeEventPlane) {
            self.id = id
            self.ownerID = ownerID
            self.types = types
            self.plane = plane
        }
    }

    private let directory: URL
    private let limits: RuntimeResourceLimitsDTO
    private let queue = DispatchQueue(label: "com.sonexis.runtime.event-hub")
    private var subscriptions: [String: Subscription] = [:]
    private var reservedSubscriptions = 0
    private var archivedDroppedEvents: UInt64 = 0

    public init(directory: URL, limits: RuntimeResourceLimitsDTO = .init()) {
        self.directory = directory
        self.limits = limits
    }

    public func subscribe(ownerID: String, eventTypes: [RuntimeEventTypeDTO]?) throws -> RuntimeEventSubscriptionDTO {
        let id = UUID().uuidString.lowercased()
        // Protocol-v2 clients from v0.3 cannot decode output event enum values.
        // Preserve the original wildcard set and require v0.4 clients to opt in
        // to output events explicitly.
        let legacyDefaults: [RuntimeEventTypeDTO] = [
            .sourceAdded, .sourceRemoved, .sourceUpdated, .captureStarted,
            .captureStopped, .captureFailed, .clientWarning, .deviceChanged,
            .runtimeWarning, .runtimeShuttingDown,
        ]
        let selected = Set(eventTypes ?? legacyDefaults)
        guard !selected.isEmpty else {
            throw RuntimeErrorDTO(code: "invalid_event_filter", message: "At least one event type is required")
        }
        try queue.sync {
            guard subscriptions.count + reservedSubscriptions < limits.maximumEventSubscriptions else {
                throw RuntimeErrorDTO(code: "subscription_limit_exceeded",
                    message: "Runtime event subscription limit reached", retryable: true)
            }
            let owned = subscriptions.values.filter { $0.ownerID == ownerID }.count
            guard owned < limits.maximumEventSubscriptionsPerClient else {
                throw RuntimeErrorDTO(code: "subscription_limit_exceeded",
                    message: "Client event subscription limit reached", retryable: true)
            }
            reservedSubscriptions += 1
        }
        var reservationActive = true
        defer {
            if reservationActive { queue.sync { reservedSubscriptions -= 1 } }
        }
        let compactID = id.replacingOccurrences(of: "-", with: "")
        let path = directory.appendingPathComponent("e-\(compactID).sock").path
        let plane = RuntimeEventPlane(path: path)
        try plane.start()
        queue.sync {
            reservedSubscriptions -= 1
            reservationActive = false
            subscriptions[id] = Subscription(id: id, ownerID: ownerID, types: selected, plane: plane)
        }
        return RuntimeEventSubscriptionDTO(id: id, eventSocketPath: path,
            eventTypes: selected.sorted { $0.rawValue < $1.rawValue })
    }

    public func unsubscribe(id: String, ownerID: String) throws {
        let removed: Subscription = try queue.sync {
            guard let subscription = subscriptions[id] else {
                throw RuntimeErrorDTO(code: "subscription_not_found", message: "Event subscription was not found")
            }
            guard subscription.ownerID == ownerID else {
                throw RuntimeErrorDTO(code: "subscription_not_owned", message: "Event subscription belongs to another client")
            }
            return subscriptions.removeValue(forKey: id)!
        }
        removed.plane.stop()
        queue.sync { archivedDroppedEvents &+= removed.plane.metrics() }
    }

    public func publish(_ event: RuntimeEventDTO) {
        let targets = queue.sync { subscriptions.values.filter { $0.types.contains(event.type) }.map(\.plane) }
        targets.forEach { $0.offer(event) }
    }

    public func removeSubscriptions(ownerID: String) {
        let removed: [Subscription] = queue.sync {
            let matches = subscriptions.values.filter { $0.ownerID == ownerID }
            matches.forEach { subscriptions.removeValue(forKey: $0.id) }
            return matches
        }
        removed.forEach { $0.plane.stop() }
        queue.sync { archivedDroppedEvents &+= removed.reduce(0) { $0 &+ $1.plane.metrics() } }
    }

    public func stopAll() {
        let removed = queue.sync { () -> [Subscription] in
            let values = Array(subscriptions.values)
            subscriptions.removeAll()
            return values
        }
        removed.forEach { $0.plane.stop() }
        queue.sync { archivedDroppedEvents &+= removed.reduce(0) { $0 &+ $1.plane.metrics() } }
    }

    public var count: Int { queue.sync { subscriptions.count } }

    public var totalDroppedEvents: UInt64 {
        queue.sync {
            archivedDroppedEvents &+ subscriptions.values.reduce(0) { $0 &+ $1.plane.metrics() }
        }
    }
}
