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
    private var lastSequence: UInt64 = 0
    private var lastTimestamp: UInt64 = 0

    public init(path: String, streamID: UUID, maximumSubscribers: Int = 4) {
        self.path = path
        self.streamID = streamID
        self.maximumSubscribers = maximumSubscribers
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
        guard capacity.wait(timeout: .now()) == .success else {
            recordQueueDrop(frame.frameCount)
            return
        }
        metricsLock.lock()
        queuedPackets += 1
        queueHighWater = max(queueHighWater, queuedPackets)
        metricsLock.unlock()
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
                return
            }

            let pendingDrops = self.takePendingDrops()
            var flags: RuntimePCMFrameFlags = frame.discontinuity || pendingDrops > 0 ? [.discontinuity] : []
            let totalDropped = UInt64(frame.droppedFramesBefore) &+ pendingDrops
            if totalDropped > 0 { flags.insert(.discontinuity) }
            do {
                guard frame.payload.count <= Int(UInt32.max) else {
                    self.recordQueueDrop(frame.frameCount)
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
                    self.pendingDroppedFrames &+= UInt64(frame.frameCount)
                }
                self.metricsLock.unlock()
                self.lastSequence = frame.sequence
                self.lastTimestamp = frame.timestampNanoseconds
            } catch {
                self.restorePendingDrops(pendingDrops &+ UInt64(frame.frameCount))
                self.recordQueueDrop(frame.frameCount, addToPending: false)
            }
        }
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

    private func recordQueueDrop(_ frames: UInt32, addToPending: Bool = true) {
        metricsLock.lock()
        queueDropped &+= UInt64(frames)
        if addToPending { pendingDroppedFrames &+= UInt64(frames) }
        metricsLock.unlock()
    }

    private func recordNoSubscriber(_ frames: UInt32) {
        metricsLock.lock()
        noSubscriber &+= UInt64(frames)
        pendingDroppedFrames &+= UInt64(frames)
        metricsLock.unlock()
    }

    private func takePendingDrops() -> UInt64 {
        metricsLock.lock()
        let value = pendingDroppedFrames
        pendingDroppedFrames = 0
        metricsLock.unlock()
        return value
    }

    private func restorePendingDrops(_ frames: UInt64) {
        metricsLock.lock()
        pendingDroppedFrames &+= frames
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
    private var connection: UnixSocketConnection?
    private var running = false
    private(set) var droppedEvents: UInt64 = 0

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
            queue.async { [weak self] in self?.droppedEvents &+= 1 }
            return
        }
        queue.async { [weak self] in
            defer { self?.capacity.signal() }
            guard let self, self.running, let connection = self.connection else {
                self?.droppedEvents &+= 1
                return
            }
            do {
                try connection.write(RuntimeProtocolCodec.encodeLine(event))
            } catch {
                connection.close()
                self.connection = nil
                self.droppedEvents &+= 1
            }
        }
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
    private let queue = DispatchQueue(label: "com.sonexis.runtime.event-hub")
    private var subscriptions: [String: Subscription] = [:]

    public init(directory: URL) { self.directory = directory }

    public func subscribe(ownerID: String, eventTypes: [RuntimeEventTypeDTO]?) throws -> RuntimeEventSubscriptionDTO {
        let id = UUID().uuidString.lowercased()
        let selected = Set(eventTypes ?? RuntimeEventTypeDTO.allCases)
        guard !selected.isEmpty else {
            throw RuntimeErrorDTO(code: "invalid_event_filter", message: "At least one event type is required")
        }
        let path = directory.appendingPathComponent("events-\(id).sock").path
        let plane = RuntimeEventPlane(path: path)
        try plane.start()
        queue.sync { subscriptions[id] = Subscription(id: id, ownerID: ownerID, types: selected, plane: plane) }
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
    }

    public func stopAll() {
        let removed = queue.sync { () -> [Subscription] in
            let values = Array(subscriptions.values)
            subscriptions.removeAll()
            return values
        }
        removed.forEach { $0.plane.stop() }
    }

    public var count: Int { queue.sync { subscriptions.count } }
}
