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
    private var records: [String: Record] = [:]
    private var reservedStarts = 0
    private var totalSessionsStarted: UInt64 = 0
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

    public func availableSources() throws -> [RuntimeSourceDTO] { try backend.availableSources() }

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
        let dataPath = socketDirectory.appendingPathComponent("stream-\(streamID.uuidString.lowercased()).sock").path
        let plane = RuntimeDataPlane(path: dataPath, streamID: streamID,
            maximumSubscribers: limits.maximumSubscribersPerStream)
        try plane.start()

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let record = Record(id: sessionID, streamID: streamID, sourceID: sourceID, ownerID: ownerID,
                            startedAt: startedAt, format: format, dataPlane: plane)
        queue.sync {
            reservedStarts -= 1
            reservationActive = false
            records[sessionID] = record
            totalSessionsStarted &+= 1
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
            let snapshot = queue.sync {
                // Backend startup may synchronously report termination.
                guard record.state == .starting else {
                    backendSession.stop()
                    return snapshot(record)
                }
                record.format = backendSession.outputFormat
                record.backendSession = backendSession
                record.state = .capturing
                return self.snapshot(record)
            }
            eventHandler(RuntimeEventDTO(type: .captureStarted, sourceID: sourceID,
                sessionID: sessionID, streamID: streamID.uuidString.lowercased(), session: snapshot))
            return snapshot
        } catch {
            _ = queue.sync { records.removeValue(forKey: sessionID) }
            plane.stop()
            throw error
        }
    }

    public func stopCapture(sessionID: String, ownerID: String) throws -> RuntimeSessionDTO {
        let terminal = try queue.sync {
            guard let record = records[sessionID] else {
                throw RuntimeErrorDTO(code: "session_not_found", message: "No capture session named \(sessionID)")
            }
            stop(record, state: .stopped, error: nil)
            let terminal = snapshot(record)
            pruneTerminalRecords()
            return terminal
        }
        eventHandler(RuntimeEventDTO(type: .captureStopped, sourceID: terminal.sourceID,
            sessionID: terminal.id, streamID: terminal.streamID, session: terminal))
        return terminal
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
        queue.sync {
            let owned = records.values.filter { $0.ownerID == ownerID }
            owned.filter { $0.state == .starting || $0.state == .capturing }
                .forEach { stop($0, state: .stopped, error: nil) }
            owned.forEach { records.removeValue(forKey: $0.id) }
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
        queue.sync {
            records.values.filter { $0.state == .starting || $0.state == .capturing }
                .forEach { stop($0, state: .stopped, error: nil) }
            records.removeAll()
        }
    }

    public func diagnostics() -> (activeSessions: Int, totalSessionsStarted: UInt64,
                                  frames: UInt64, dropped: UInt64, bytes: UInt64) {
        queue.sync {
            let active = records.values.filter { $0.state == .starting || $0.state == .capturing }
            let metrics = records.values.map { $0.dataPlane.metrics() }
            for record in records.values {
                if let session = record.backendSession { record.captureMetrics = session.metrics() }
            }
            let captureDrops = records.values.reduce(UInt64(0)) {
                $0 &+ $1.captureMetrics.ringDroppedFrames &+ $1.captureMetrics.deliveryDroppedFrames
            }
            return (active.count, totalSessionsStarted,
                metrics.reduce(0) { $0 &+ $1.framesForwarded },
                captureDrops &+ metrics.reduce(0) { $0 &+ $1.queueDroppedFrames &+ $1.noSubscriberFrames },
                metrics.reduce(0) { $0 &+ $1.bytesTransmitted })
        }
    }

    private func captureEnded(sessionID: String, error: RuntimeErrorDTO?) {
        queue.async { [weak self] in
            guard let self, let record = self.records[sessionID], record.state == .starting || record.state == .capturing else { return }
            self.stop(record, state: error == nil ? .stopped : .failed, error: error)
            let snapshot = self.snapshot(record)
            self.pruneTerminalRecords()
            self.eventHandler(RuntimeEventDTO(type: error == nil ? .captureStopped : .captureFailed,
                sourceID: record.sourceID, sessionID: record.id,
                streamID: record.streamID.uuidString.lowercased(), session: snapshot, error: error))
        }
    }

    private func stop(_ record: Record, state: RuntimeSessionStateDTO, error: RuntimeErrorDTO?) {
        guard record.state == .starting || record.state == .capturing else { return }
        record.state = state
        record.terminalError = error
        let session = record.backendSession
        if let session { record.captureMetrics = session.metrics() }
        record.backendSession = nil
        // Stop production before closing subscribers, so no callback can target a removed socket.
        session?.stop()
        record.dataPlane.stop()
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
            records.removeValue(forKey: record.id)
        }
    }
}
