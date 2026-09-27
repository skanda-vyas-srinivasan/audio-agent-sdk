import Foundation

public struct RuntimeBackendAudioFrame: Sendable {
    public let payload: Data
    public let sequence: UInt64
    public let timestampNanoseconds: UInt64
    public let frameCount: UInt32
    public let format: RuntimePCMFormatDTO
    public let discontinuity: Bool
    public let droppedFramesBefore: UInt32

    public init(payload: Data, sequence: UInt64, timestampNanoseconds: UInt64,
                frameCount: UInt32, format: RuntimePCMFormatDTO,
                discontinuity: Bool = false, droppedFramesBefore: UInt32 = 0) {
        self.payload = payload
        self.sequence = sequence
        self.timestampNanoseconds = timestampNanoseconds
        self.frameCount = frameCount
        self.format = format
        self.discontinuity = discontinuity
        self.droppedFramesBefore = droppedFramesBefore
    }
}

public protocol RuntimeBackendCaptureSession: AnyObject, Sendable {
    var outputFormat: RuntimePCMFormatDTO { get }
    func metrics() -> RuntimeCaptureMetricsDTO
    func stop()
}

public extension RuntimeBackendCaptureSession {
    func metrics() -> RuntimeCaptureMetricsDTO { .init() }
}

/// Adapter point between the IPC runtime and Sonexis capture core.
///
/// `onFrame` must not be invoked directly from a CoreAudio realtime callback. The
/// capture adapter should copy/enqueue into its existing worker first. This keeps
/// framing, dispatch, and socket syscalls off the realtime thread.
public protocol RuntimeCaptureBackend: AnyObject, Sendable {
    func availableSources() throws -> [RuntimeSourceDTO]
    func startCapture(
        sourceID: String,
        format: RuntimePCMFormatDTO,
        onFrame: @escaping @Sendable (RuntimeBackendAudioFrame) -> Void,
        onDeviceChanged: @escaping @Sendable () -> Void,
        onEnded: @escaping @Sendable (RuntimeErrorDTO?) -> Void
    ) throws -> RuntimeBackendCaptureSession
}

public final class RuntimeSessionCoordinator: @unchecked Sendable {
    private final class Record {
        let id: String
        let streamID: UUID
        let sourceID: String
        let ownerID: String
        let startedAt: UInt64
        var format: RuntimePCMFormatDTO
        let dataPlane: RuntimeDataPlane
        var backendSession: RuntimeBackendCaptureSession?
        var state: RuntimeSessionStateDTO = .starting
        var terminalError: RuntimeErrorDTO?
        var captureMetrics = RuntimeCaptureMetricsDTO()

        init(id: String, streamID: UUID, sourceID: String, ownerID: String, startedAt: UInt64,
             format: RuntimePCMFormatDTO, dataPlane: RuntimeDataPlane) {
            self.id = id; self.streamID = streamID; self.sourceID = sourceID; self.ownerID = ownerID
            self.startedAt = startedAt; self.format = format; self.dataPlane = dataPlane
        }
    }

    private let backend: RuntimeCaptureBackend
    private let socketDirectory: URL
    private let queue = DispatchQueue(label: "com.sonexis.runtime.sessions")
    private let cleanupQueue = DispatchQueue(label: "com.sonexis.runtime.session-cleanup",
                                              attributes: .concurrent)
    private var records: [String: Record] = [:]
    private var acceptingStarts = true
    private var reservedStarts = 0
    private var totalSessionsStarted: UInt64 = 0
    private var archivedFrames: UInt64 = 0
    private var archivedRingDrops: UInt64 = 0
    private var archivedDeliveryDrops: UInt64 = 0
    private var archivedQueueDrops: UInt64 = 0
    private var archivedNoSubscriberFrames: UInt64 = 0
    private var archivedBytes: UInt64 = 0
    private let limits: RuntimeResourceLimitsDTO
    private let eventHandler: @Sendable (RuntimeEventDTO) -> Void

    public init(backend: RuntimeCaptureBackend, socketDirectory: URL,
                limits: RuntimeResourceLimitsDTO = .init(),
                eventHandler: @escaping @Sendable (RuntimeEventDTO) -> Void = { _ in }) {
        self.backend = backend
        self.socketDirectory = socketDirectory
        self.limits = limits
        self.eventHandler = eventHandler
    }

    public func availableSources() throws -> [RuntimeSourceDTO] {
        let sources = try backend.availableSources()
        let maximum = max(1, limits.maximumSources ?? 256)
        guard sources.count <= maximum else {
            throw RuntimeErrorDTO(code: "source_limit_exceeded",
                message: "Source discovery returned more than \(maximum) sources")
        }
        var identifiers = Set<String>()
        for source in sources {
            guard !source.id.isEmpty, source.id.utf8.count <= 1_024,
                  !source.name.isEmpty, source.name.utf8.count <= 256 else {
                throw RuntimeErrorDTO(code: "invalid_source",
                    message: "Source discovery returned an invalid source identity")
            }
            guard identifiers.insert(source.id).inserted else {
                throw RuntimeErrorDTO(code: "duplicate_source",
                    message: "Source discovery returned duplicate source ID \(source.id)")
            }
            guard source.processIDs.count <= 128 else {
                throw RuntimeErrorDTO(code: "invalid_source",
                    message: "Source \(source.id) contains too many process identifiers")
            }
        }
        let encoded = try RuntimeProtocolCodec.encodeLine(sources)
        guard encoded.count <= limits.maximumControlMessageBytes - 1_024 else {
            throw RuntimeErrorDTO(code: "source_response_too_large",
                message: "Source discovery metadata exceeds the control response limit")
        }
        return sources
    }

    public func startCapture(sourceID: String, format: RuntimePCMFormatDTO,
                             ownerID: String) throws -> RuntimeSessionDTO {
        guard !sourceID.isEmpty, sourceID.utf8.count <= 1024 else {
            throw RuntimeErrorDTO(code: "invalid_source_id", message: "A valid source ID is required")
        }
        guard format.isSupported else {
            throw RuntimeErrorDTO(code: "unsupported_format", message: "Requested audio format is not supported",
                details: ["supported_formats": RuntimePCMFormatDTO.supported.map {
                    "\($0.sampleFormat.rawValue):\($0.sampleRate):\($0.channelCount)"
                }.joined(separator: ",")])
        }
        try queue.sync {
            guard acceptingStarts else {
                throw RuntimeErrorDTO(code: "runtime_shutting_down",
                    message: "Runtime is shutting down", retryable: true)
            }
            let active = records.values.filter { $0.state == .starting || $0.state == .capturing }
            let owned = active.filter { $0.ownerID == ownerID }
            guard active.count + reservedStarts < limits.maximumSessions else {
                throw RuntimeErrorDTO(code: "session_limit_exceeded", message: "Runtime session limit reached", retryable: true)
            }
            guard owned.count < limits.maximumSessionsPerClient else {
                throw RuntimeErrorDTO(code: "session_limit_exceeded", message: "Client session limit reached", retryable: true)
            }
            reservedStarts += 1
        }
        var reservationActive = true
        defer {
            if reservationActive { queue.sync { reservedStarts -= 1 } }
        }
        let sessionID = UUID().uuidString.lowercased()
        let streamID = UUID()
        let compactStreamID = streamID.uuidString.lowercased()
            .replacingOccurrences(of: "-", with: "")
        let dataPath = socketDirectory.appendingPathComponent("i-\(compactStreamID).sock").path
        let plane = RuntimeDataPlane(path: dataPath, streamID: streamID,
            maximumSubscribers: limits.maximumSubscribersPerStream) { [eventHandler] disconnected in
                eventHandler(RuntimeEventDTO(type: .clientWarning, sourceID: sourceID,
                    sessionID: sessionID, streamID: streamID.uuidString.lowercased(),
                    message: "Disconnected \(disconnected) slow audio subscriber(s)"))
            }
        try plane.start()

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let record = Record(id: sessionID, streamID: streamID, sourceID: sourceID, ownerID: ownerID,
                            startedAt: startedAt, format: format, dataPlane: plane)
        do {
            try queue.sync {
                guard acceptingStarts else {
                    throw RuntimeErrorDTO(code: "runtime_shutting_down",
                        message: "Runtime is shutting down", retryable: true)
                }
                reservedStarts -= 1
                reservationActive = false
                records[sessionID] = record
                totalSessionsStarted &+= 1
            }
        } catch {
            plane.stop()
            throw error
        }

        do {
            let backendSession = try backend.startCapture(sourceID: sourceID, format: format, onFrame: { frame in
                plane.offer(frame)
            }, onDeviceChanged: { [weak self] in
                self?.eventHandler(RuntimeEventDTO(type: .deviceChanged, sourceID: sourceID,
                    sessionID: sessionID, streamID: streamID.uuidString.lowercased()))
            }, onEnded: { [weak self] error in
                self?.captureEnded(sessionID: sessionID, error: error)
            })
            do {
                return try queue.sync {
                    // Backend startup may synchronously report termination.
                    guard record.state == .starting else {
                        throw record.terminalError ?? RuntimeErrorDTO(code: "capture_ended_during_start",
                            message: "Capture ended before startup completed", retryable: true)
                    }
                    record.format = backendSession.outputFormat
                    record.backendSession = backendSession
                    record.state = .capturing
                    let snapshot = self.snapshot(record)
                    // Publish while serialized with termination so capture_started can
                    // never follow capture_stopped/capture_failed for this session.
                    self.eventHandler(RuntimeEventDTO(type: .captureStarted, sourceID: sourceID,
                        sessionID: sessionID, streamID: streamID.uuidString.lowercased(), session: snapshot))
                    return snapshot
                }
            } catch {
                // Backend teardown may block. Never run it on the coordinator's
                // serial state queue or one late startup can wedge all sessions.
                backendSession.stop()
                throw error
            }
        } catch {
            let failure = error as? RuntimeErrorDTO ?? RuntimeErrorDTO(code: "capture_start_failed",
                message: String(describing: error), retryable: true)
            let shouldPublishFailure = queue.sync {
                var publish = false
                if let existing = records[sessionID] {
                    if existing.state == .starting {
                        existing.state = .failed
                        existing.terminalError = failure
                        publish = true
                    }
                    archiveAndRemove(existing)
                }
                return publish
            }
            plane.stop()
            if shouldPublishFailure {
                eventHandler(RuntimeEventDTO(type: .captureFailed, sourceID: sourceID,
                    sessionID: sessionID, streamID: streamID.uuidString.lowercased(), error: failure))
            }
            throw error
        }
    }

    public func stopCapture(sessionID: String, ownerID: String) throws -> RuntimeSessionDTO {
        let resources: (Record, RuntimeBackendCaptureSession?, Bool) = try queue.sync {
            guard let record = records[sessionID] else {
                throw RuntimeErrorDTO(code: "session_not_found", message: "No capture session named \(sessionID)")
            }
            let wasActive = record.state == .starting || record.state == .capturing
            return (record, beginStop(record, state: .stopped, error: nil), wasActive)
        }
        if resources.2 {
            resources.1?.stop()
            let finalMetrics = resources.1?.metrics()
            resources.0.dataPlane.stop()
            let terminal = queue.sync {
                if let finalMetrics { resources.0.captureMetrics = finalMetrics }
                let value = snapshot(resources.0)
                pruneTerminalRecords()
                return value
            }
            eventHandler(RuntimeEventDTO(type: .captureStopped, sourceID: terminal.sourceID,
                sessionID: terminal.id, streamID: terminal.streamID, session: terminal))
            return terminal
        }
        return queue.sync { snapshot(resources.0) }
    }

    public func session(sessionID: String, ownerID: String) throws -> RuntimeSessionDTO {
        try queue.sync {
            guard let record = records[sessionID] else {
                throw RuntimeErrorDTO(code: "session_not_found", message: "No capture session named \(sessionID)")
            }
            return snapshot(record)
        }
    }

    public func stopSessions(ownerID: String) {
        let stopped: [(Record, RuntimeBackendCaptureSession?)] = queue.sync {
            let owned = records.values.filter { $0.ownerID == ownerID }
            let active = owned.filter { $0.state == .starting || $0.state == .capturing }
            return active.map { record in
                (record, beginStop(record, state: .stopped, error: nil))
            }
        }
        stopped.forEach { record, session in
            record.dataPlane.stop()
            cleanupQueue.async { [weak self] in
                session?.stop()
                let finalMetrics = session?.metrics()
                guard let self else { return }
                let terminal = self.queue.sync {
                    if let finalMetrics { record.captureMetrics = finalMetrics }
                    let value = self.snapshot(record)
                    self.archiveAndRemove(record)
                    return value
                }
                self.eventHandler(RuntimeEventDTO(type: .captureStopped,
                    sourceID: terminal.sourceID, sessionID: terminal.id,
                    streamID: terminal.streamID, session: terminal,
                    message: "Owning control client disconnected"))
            }
        }
    }

    public func hasActiveSessions(ownerID: String) -> Bool {
        queue.sync {
            records.values.contains {
                $0.ownerID == ownerID && ($0.state == .starting || $0.state == .capturing)
            }
        }
    }

    public func stopAll() {
        prepareForShutdown()
        let resources: [(Record, RuntimeDataPlane, RuntimeBackendCaptureSession?)] = queue.sync {
            let existing = Array(records.values)
            let active = existing.filter { $0.state == .starting || $0.state == .capturing }
                .map { record -> (Record, RuntimeDataPlane, RuntimeBackendCaptureSession?) in
                    record.state = .stopped
                    let session = record.backendSession
                    record.backendSession = nil
                    return (record, record.dataPlane, session)
                }
            existing.filter { record in
                !active.contains { $0.0 === record }
            }.forEach(archiveAndRemove)
            return active
        }
        resources.forEach { record, plane, session in
            plane.stop()
            cleanupQueue.async { [weak self] in
                session?.stop()
                let finalMetrics = session?.metrics()
                self?.queue.sync {
                    if let finalMetrics { record.captureMetrics = finalMetrics }
                    self?.archiveAndRemove(record)
                }
            }
        }
    }

    public func prepareForShutdown() {
        queue.sync { acceptingStarts = false }
    }

    public func resume() {
        queue.sync { acceptingStarts = true }
    }

    public func diagnostics() -> (activeSessions: Int, totalSessionsStarted: UInt64,
                                  frames: UInt64, dropped: UInt64, bytes: UInt64,
                                  ringDropped: UInt64, deliveryDropped: UInt64,
                                  queueDropped: UInt64, noSubscriber: UInt64,
                                  connectedSubscribers: Int, retainedTerminalRecords: Int,
                                  reservedStarts: Int) {
        queue.sync {
            let active = records.values.filter { $0.state == .starting || $0.state == .capturing }
            let metrics = records.values.map { $0.dataPlane.metrics() }
            for record in records.values {
                if let session = record.backendSession { record.captureMetrics = session.metrics() }
            }
            let ringDropped = archivedRingDrops &+ records.values.reduce(UInt64(0)) {
                $0 &+ $1.captureMetrics.ringDroppedFrames
            }
            let deliveryDropped = archivedDeliveryDrops &+ records.values.reduce(UInt64(0)) {
                $0 &+ $1.captureMetrics.deliveryDroppedFrames
            }
            let queueDropped = archivedQueueDrops &+ metrics.reduce(UInt64(0)) {
                $0 &+ $1.queueDroppedFrames
            }
            let noSubscriber = archivedNoSubscriberFrames &+ metrics.reduce(UInt64(0)) {
                $0 &+ $1.noSubscriberFrames
            }
            let terminalCount = records.values.filter {
                $0.state == .stopped || $0.state == .failed
            }.count
            return (active.count, totalSessionsStarted,
                archivedFrames &+ metrics.reduce(0) { $0 &+ $1.framesForwarded },
                ringDropped &+ deliveryDropped &+ queueDropped &+ noSubscriber,
                archivedBytes &+ metrics.reduce(0) { $0 &+ $1.bytesTransmitted },
                ringDropped, deliveryDropped, queueDropped, noSubscriber,
                metrics.reduce(0) { $0 + $1.connectedClients }, terminalCount,
                reservedStarts)
        }
    }

    private func captureEnded(sessionID: String, error: RuntimeErrorDTO?) {
        queue.async { [weak self] in
            guard let self, let record = self.records[sessionID], record.state == .starting || record.state == .capturing else { return }
            let session = self.beginStop(record,
                state: error == nil ? .stopped : .failed, error: error)
            self.cleanupQueue.async { [weak self] in
                session?.stop()
                let finalMetrics = session?.metrics()
                record.dataPlane.stop()
                guard let self else { return }
                let value = self.queue.sync {
                    if let finalMetrics { record.captureMetrics = finalMetrics }
                    let snapshot = self.snapshot(record)
                    self.pruneTerminalRecords()
                    return snapshot
                }
                self.eventHandler(RuntimeEventDTO(
                    type: error == nil ? .captureStopped : .captureFailed,
                    sourceID: record.sourceID, sessionID: record.id,
                    streamID: record.streamID.uuidString.lowercased(), session: value,
                    error: error))
            }
        }
    }

    /// Transitions ownership under `queue`; backend teardown always runs after
    /// the queue is released so a faulty Core Audio stop cannot block status or
    /// process shutdown.
    private func beginStop(_ record: Record, state: RuntimeSessionStateDTO,
                           error: RuntimeErrorDTO?) -> RuntimeBackendCaptureSession? {
        guard record.state == .starting || record.state == .capturing else { return nil }
        record.state = state
        record.terminalError = error
        let session = record.backendSession
        if let session { record.captureMetrics = session.metrics() }
        record.backendSession = nil
        return session
    }

    private func snapshot(_ record: Record) -> RuntimeSessionDTO {
        let metrics = record.dataPlane.metrics()
        if let session = record.backendSession { record.captureMetrics = session.metrics() }
        let capture = record.captureMetrics
        return RuntimeSessionDTO(id: record.id, streamID: record.streamID.uuidString.lowercased(),
            sourceID: record.sourceID, state: record.state, format: record.format,
            dataSocketPath: record.dataPlane.path, startedAtNanoseconds: record.startedAt,
            metrics: RuntimeSessionMetricsDTO(captureCallbacks: capture.captureCallbacks,
                nativeFramesReceived: capture.nativeFramesReceived,
                normalizedFramesDelivered: capture.normalizedFramesDelivered,
                ringDroppedFrames: capture.ringDroppedFrames,
                deliveryDroppedFrames: capture.deliveryDroppedFrames,
                conversionBatches: capture.conversionBatches,
                conversionNanoseconds: capture.conversionNanoseconds,
                ringBacklogFrames: capture.ringBacklogFrames,
                framesForwarded: metrics.framesForwarded,
                queueDroppedFrames: metrics.queueDroppedFrames,
                noSubscriberFrames: metrics.noSubscriberFrames,
                slowConsumerDisconnects: metrics.slowConsumerDisconnects,
                bytesTransmitted: metrics.bytesTransmitted,
                connectedSubscribers: metrics.connectedClients,
                dataQueueHighWaterMark: metrics.queueHighWaterMark), error: record.terminalError)
    }

    private func pruneTerminalRecords(limit: Int = 128) {
        let terminal = records.values
            .filter { $0.state == .stopped || $0.state == .failed }
            .sorted { $0.startedAt < $1.startedAt }
        for record in terminal.prefix(max(0, terminal.count - limit)) {
            archiveAndRemove(record)
        }
    }

    /// Moves a record's final counters into monotonic Runtime lifetime totals.
    /// Must be called on `queue`.
    private func archiveAndRemove(_ record: Record) {
        guard records.removeValue(forKey: record.id) != nil else { return }
        let data = record.dataPlane.metrics()
        archivedFrames &+= data.framesForwarded
        archivedRingDrops &+= record.captureMetrics.ringDroppedFrames
        archivedDeliveryDrops &+= record.captureMetrics.deliveryDroppedFrames
        archivedQueueDrops &+= data.queueDroppedFrames
        archivedNoSubscriberFrames &+= data.noSubscriberFrames
        archivedBytes &+= data.bytesTransmitted
    }
}
