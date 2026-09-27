import Foundation

public struct RuntimeOutputBackendEvent: Sendable {
    public enum Kind: Sendable {
        case underrun
        case overrun
        case dropped
        case destinationChanged
    }

    public let kind: Kind
    public let frames: UInt64
    public let message: String?

    public init(kind: Kind, frames: UInt64 = 0, message: String? = nil) {
        self.kind = kind
        self.frames = frames
        self.message = message
    }
}

public protocol RuntimeBackendOutputSession: AnyObject, Sendable {
    var inputFormat: RuntimePCMFormatDTO { get }
    var destination: RuntimeOutputDestinationDTO { get }
    func write(_ frame: RuntimePCMFrame) throws
    /// Finish queued audio and invoke the backend's completion callback.
    func finish()
    /// Discard queued audio while keeping the device session usable.
    func flush() throws
    /// Stop immediately and release device resources. Must be idempotent.
    func stop()
    func metrics() -> RuntimeOutputMetricsDTO
}

public protocol RuntimeOutputBackend: AnyObject, Sendable {
    func availableOutputDestinations() throws -> [RuntimeOutputDestinationDTO]
    func startOutput(
        destinationID: String,
        format: RuntimePCMFormatDTO,
        targetBufferMilliseconds: UInt32,
        onEvent: @escaping @Sendable (RuntimeOutputBackendEvent) -> Void,
        onEnded: @escaping @Sendable (RuntimeErrorDTO?) -> Void
    ) throws -> RuntimeBackendOutputSession
}

/// Used by capture-only test servers and on unsupported hosts. Production
/// Runtime startup injects the macOS HAL playback backend.
public final class UnavailableRuntimeOutputBackend: RuntimeOutputBackend, @unchecked Sendable {
    public init() {}
    public func availableOutputDestinations() throws -> [RuntimeOutputDestinationDTO] { [] }
    public func startOutput(destinationID: String, format: RuntimePCMFormatDTO,
                            targetBufferMilliseconds: UInt32,
                            onEvent: @escaping @Sendable (RuntimeOutputBackendEvent) -> Void,
                            onEnded: @escaping @Sendable (RuntimeErrorDTO?) -> Void)
        throws -> RuntimeBackendOutputSession {
        throw RuntimeErrorDTO(code: "output_unavailable",
            message: "This Runtime has no audio output backend", retryable: true)
    }
}

public final class RuntimeOutputCoordinator: @unchecked Sendable {
    private final class Record {
        let id: String
        let destinationID: String
        let ownerID: String
        let startedAt: UInt64
        let format: RuntimePCMFormatDTO
        let targetBufferMilliseconds: UInt32
        var streamID: UUID
        var dataPlane: RuntimeOutputDataPlane
        var backendSession: RuntimeBackendOutputSession?
        var finalBackendMetrics = RuntimeOutputMetricsDTO()
        var state: RuntimeOutputSessionStateDTO = .starting
        var terminalError: RuntimeErrorDTO?
        var retiredPacketsReceived: UInt64 = 0
        var retiredInputFramesReceived: UInt64 = 0
        var retiredInputBytesReceived: UInt64 = 0
        var retiredDiscontinuities: UInt64 = 0

        init(id: String, destinationID: String, ownerID: String, startedAt: UInt64,
             format: RuntimePCMFormatDTO, targetBufferMilliseconds: UInt32,
             streamID: UUID, dataPlane: RuntimeOutputDataPlane) {
            self.id = id
            self.destinationID = destinationID
            self.ownerID = ownerID
            self.startedAt = startedAt
            self.format = format
            self.targetBufferMilliseconds = targetBufferMilliseconds
            self.streamID = streamID
            self.dataPlane = dataPlane
        }
    }

    private let backend: RuntimeOutputBackend
    private let socketDirectory: URL
    private let limits: RuntimeResourceLimitsDTO
    private let eventHandler: @Sendable (RuntimeEventDTO) -> Void
    private let queue = DispatchQueue(label: "com.sonexis.runtime.output-sessions")
    private let cleanupQueue = DispatchQueue(label: "com.sonexis.runtime.output-cleanup",
                                              attributes: .concurrent)
    private let startGroup = DispatchGroup()
    private var records: [String: Record] = [:]
    private var acceptingStarts = true
    private var reservedStarts = 0
    private var totalSessionsStarted: UInt64 = 0
    private var archivedReceived: UInt64 = 0
    private var archivedRendered: UInt64 = 0
    private var archivedDropped: UInt64 = 0
    private var archivedBytes: UInt64 = 0

    public init(backend: RuntimeOutputBackend, socketDirectory: URL,
                limits: RuntimeResourceLimitsDTO = .init(),
                eventHandler: @escaping @Sendable (RuntimeEventDTO) -> Void = { _ in }) {
        self.backend = backend
        self.socketDirectory = socketDirectory
        self.limits = limits
        self.eventHandler = eventHandler
    }

    public func availableDestinations() throws -> [RuntimeOutputDestinationDTO] {
        try backend.availableOutputDestinations()
    }

    public func startOutput(destinationID: String, format: RuntimePCMFormatDTO,
                            targetBufferMilliseconds: UInt32 = 60,
                            ownerID: String) throws -> RuntimeOutputSessionDTO {
        guard !destinationID.isEmpty, destinationID.utf8.count <= 256 else {
            throw RuntimeErrorDTO(code: "invalid_output_destination",
                message: "A valid output destination ID is required")
        }
        guard format.isSupportedOutput else {
            throw RuntimeErrorDTO(code: "unsupported_output_format",
                message: "Requested output format is not supported")
        }
        guard (20...250).contains(targetBufferMilliseconds) else {
            throw RuntimeErrorDTO(code: "invalid_output_buffer",
                message: "target_buffer_milliseconds must be between 20 and 250")
        }
        try reserveStart(ownerID: ownerID)
        defer { startGroup.leave() }
        var reservationActive = true
        defer {
            if reservationActive { queue.sync { reservedStarts -= 1 } }
        }

        let sessionID = UUID().uuidString.lowercased()
        let streamID = UUID()
        let plane = makeDataPlane(sessionID: sessionID, streamID: streamID, format: format)
        try plane.start()
        let record = Record(id: sessionID, destinationID: destinationID, ownerID: ownerID,
            startedAt: DispatchTime.now().uptimeNanoseconds, format: format,
            targetBufferMilliseconds: targetBufferMilliseconds,
            streamID: streamID, dataPlane: plane)
        queue.sync {
            reservedStarts -= 1
            reservationActive = false
            records[sessionID] = record
            totalSessionsStarted &+= 1
        }

        do {
            let session = try backend.startOutput(destinationID: destinationID, format: format,
                targetBufferMilliseconds: targetBufferMilliseconds,
                onEvent: { [weak self] event in
                    self?.backendEvent(sessionID: sessionID, event: event)
                }, onEnded: { [weak self] error in
                    self?.outputEnded(sessionID: sessionID, error: error)
                })
            return try queue.sync {
                guard record.state == .starting else {
                    session.stop()
                    throw record.terminalError ?? RuntimeErrorDTO(code: "output_ended_during_start",
                        message: "Output ended before startup completed", retryable: true)
                }
                record.backendSession = session
                record.state = .ready
                let value = snapshot(record)
                eventHandler(RuntimeEventDTO(type: .outputStarted,
                    sessionID: record.id, streamID: record.streamID.uuidString.lowercased(),
                    outputSession: value))
                return value
            }
        } catch {
            let failure = error as? RuntimeErrorDTO ?? RuntimeErrorDTO(
                code: "output_initialization_failed", message: String(describing: error),
                retryable: true)
            queue.sync {
                record.state = .failed
                record.terminalError = failure
                archiveAndRemove(record)
            }
            plane.stop()
            eventHandler(RuntimeEventDTO(type: .outputFailed, sessionID: sessionID,
                streamID: streamID.uuidString.lowercased(), error: failure))
            throw failure
        }
    }

    public func session(outputSessionID: String, ownerID: String) throws -> RuntimeOutputSessionDTO {
        try queue.sync {
            guard let record = records[outputSessionID] else { throw notFound(outputSessionID) }
            return snapshot(record)
        }
    }

    public func flush(outputSessionID: String, ownerID: String) throws -> RuntimeOutputSessionDTO {
        let resources: (Record, RuntimeOutputDataPlane, RuntimeBackendOutputSession) = try queue.sync {
            guard let record = records[outputSessionID] else { throw notFound(outputSessionID) }
            guard record.ownerID == ownerID else {
                throw RuntimeErrorDTO(code: "output_session_not_owned",
                    message: "Only the creating client can flush an active output session")
            }
            guard record.state == .ready, let session = record.backendSession else {
                throw RuntimeErrorDTO(code: "output_not_writable",
                    message: "Only a ready output session can be flushed")
            }
            record.state = .starting
            return (record, record.dataPlane, session)
        }
        resources.1.stop()
        let retired = resources.1.metrics()
        do { try resources.2.flush() }
        catch {
            let failure = RuntimeErrorDTO(code: "output_flush_failed",
                message: String(describing: error), retryable: true)
            fail(outputSessionID: outputSessionID, error: failure)
            throw failure
        }

        let nextStreamID = UUID()
        let nextPlane = makeDataPlane(sessionID: resources.0.id, streamID: nextStreamID,
            format: resources.0.format)
        do { try nextPlane.start() }
        catch {
            let failure = RuntimeErrorDTO(code: "output_flush_failed",
                message: String(describing: error), retryable: true)
            fail(outputSessionID: outputSessionID, error: failure)
            throw failure
        }
        return try queue.sync {
            guard resources.0.state == .starting else {
                nextPlane.stop()
                throw RuntimeErrorDTO(code: "output_not_writable",
                    message: "Output stopped while flush was in progress")
            }
            resources.0.streamID = nextStreamID
            resources.0.dataPlane = nextPlane
            resources.0.retiredPacketsReceived &+= retired.packetsReceived
            resources.0.retiredInputFramesReceived &+= retired.inputFramesReceived
            resources.0.retiredInputBytesReceived &+= retired.inputBytesReceived
            resources.0.retiredDiscontinuities &+= retired.discontinuitiesReceived
            resources.0.state = .ready
            return snapshot(resources.0)
        }
    }

    public func stopOutput(outputSessionID: String, ownerID: String) throws -> RuntimeOutputSessionDTO {
        let resources: (Record, Bool, RuntimeOutputDataPlane, RuntimeBackendOutputSession?) = try queue.sync {
            guard let record = records[outputSessionID] else { throw notFound(outputSessionID) }
            let active = record.state == .starting || record.state == .ready || record.state == .draining
            if active { record.state = .cancelled }
            return (record, active, record.dataPlane, record.backendSession)
        }
        if resources.1 {
            resources.2.stop()
            resources.3?.stop()
            let value = queue.sync { snapshot(resources.0) }
            eventHandler(RuntimeEventDTO(type: .outputCancelled, sessionID: value.id,
                streamID: value.streamID, outputSession: value))
            queue.sync { pruneTerminalRecords() }
            return value
        }
        return queue.sync { snapshot(resources.0) }
    }

    public func stopSessions(ownerID: String) {
        let active: [(Record, RuntimeOutputDataPlane, RuntimeBackendOutputSession?)] = queue.sync {
            records.values.filter { $0.ownerID == ownerID }.compactMap { record in
                guard record.state == .starting || record.state == .ready || record.state == .draining else {
                    archiveAndRemove(record)
                    return nil
                }
                record.state = .cancelled
                return (record, record.dataPlane, record.backendSession)
            }
        }
        for (record, plane, session) in active {
            plane.stop()
            session?.stop()
            let value = queue.sync { snapshot(record) }
            eventHandler(RuntimeEventDTO(type: .outputCancelled, sessionID: value.id,
                streamID: value.streamID, message: "Owning control client disconnected",
                outputSession: value))
            queue.sync { archiveAndRemove(record) }
        }
    }

    public func stopAll() {
        prepareForShutdown()
        let active: [(Record, RuntimeOutputDataPlane, RuntimeBackendOutputSession?)] = queue.sync {
            records.values.compactMap { record in
                let wasActive = record.state == .starting || record.state == .ready || record.state == .draining
                if wasActive { record.state = .cancelled }
                return wasActive ? (record, record.dataPlane, record.backendSession) : nil
            }
        }
        active.forEach { _, plane, session in plane.stop(); session?.stop() }
        queue.sync { Array(records.values).forEach(archiveAndRemove) }
    }

    public func prepareForShutdown() {
        queue.sync { acceptingStarts = false }
        startGroup.wait()
    }

    public func resume() { queue.sync { acceptingStarts = true } }

    public func diagnostics() -> (activeSessions: Int, totalSessionsStarted: UInt64,
                                  received: UInt64, rendered: UInt64,
                                  dropped: UInt64, bytes: UInt64) {
        queue.sync {
            let active = records.values.filter {
                $0.state == .starting || $0.state == .ready || $0.state == .draining
            }
            let values = records.values.map { snapshot($0).metrics }
            return (active.count, totalSessionsStarted,
                archivedReceived &+ values.reduce(0) { $0 &+ $1.inputFramesReceived },
                archivedRendered &+ values.reduce(0) { $0 &+ $1.deviceFramesRendered },
                archivedDropped &+ values.reduce(0) { $0 &+ $1.droppedFrames &+ $1.flushedFrames },
                archivedBytes &+ values.reduce(0) { $0 &+ $1.inputBytesReceived })
        }
    }

    private func reserveStart(ownerID: String) throws {
        try queue.sync {
            guard acceptingStarts else {
                throw RuntimeErrorDTO(code: "runtime_shutting_down",
                    message: "Runtime is shutting down", retryable: true)
            }
            let active = records.values.filter {
                $0.state == .starting || $0.state == .ready || $0.state == .draining
            }
            let owned = active.filter { $0.ownerID == ownerID }
            guard active.count + reservedStarts < (limits.maximumOutputSessions ?? 8) else {
                throw RuntimeErrorDTO(code: "output_session_limit_exceeded",
                    message: "Runtime output session limit reached", retryable: true)
            }
            guard owned.count < (limits.maximumOutputSessionsPerClient ?? 4) else {
                throw RuntimeErrorDTO(code: "output_session_limit_exceeded",
                    message: "Client output session limit reached", retryable: true)
            }
            reservedStarts += 1
            startGroup.enter()
        }
    }

    private func makeDataPlane(sessionID: String, streamID: UUID,
                               format: RuntimePCMFormatDTO) -> RuntimeOutputDataPlane {
        let path = socketDirectory.appendingPathComponent(
            "output-\(streamID.uuidString.lowercased()).sock").path
        return RuntimeOutputDataPlane(path: path, streamID: streamID, format: format,
            maximumPacketMilliseconds: UInt32(limits.maximumOutputPacketMilliseconds ?? 200),
            onFrame: { [weak self] frame in
                try self?.acceptFrame(sessionID: sessionID, streamID: streamID, frame: frame)
            }, onEndOfStream: { [weak self] in
                self?.beginDrain(sessionID: sessionID, streamID: streamID)
            }, onFailure: { [weak self] error in
                self?.fail(outputSessionID: sessionID, streamID: streamID, error: error)
            })
    }

    private func acceptFrame(sessionID: String, streamID: UUID,
                             frame: RuntimePCMFrame) throws {
        let session: RuntimeBackendOutputSession = try queue.sync {
            guard let record = records[sessionID], record.streamID == streamID else {
                throw RuntimeErrorDTO(code: "stale_output_stream",
                    message: "Output packet belongs to an expired stream epoch")
            }
            guard record.state == .ready, let session = record.backendSession else {
                throw RuntimeErrorDTO(code: "output_not_writable",
                    message: "Output session is not accepting audio")
            }
            return session
        }
        try session.write(frame)
    }

    private func beginDrain(sessionID: String, streamID: UUID) {
        let session: RuntimeBackendOutputSession? = queue.sync {
            guard let record = records[sessionID], record.streamID == streamID,
                  record.state == .ready else { return nil }
            record.state = .draining
            return record.backendSession
        }
        session?.finish()
    }

    private func outputEnded(sessionID: String, error: RuntimeErrorDTO?) {
        queue.async { [weak self] in
            guard let self, let record = self.records[sessionID],
                  record.state == .starting || record.state == .ready || record.state == .draining else { return }
            record.backendSession.map { record.finalBackendMetrics = $0.metrics() }
            let session = record.backendSession
            record.backendSession = nil
            record.state = error == nil ? .stopped : .failed
            record.terminalError = error
            let plane = record.dataPlane
            let value = self.snapshot(record)
            self.pruneTerminalRecords()
            self.cleanupQueue.async { plane.stop(); session?.stop() }
            self.eventHandler(RuntimeEventDTO(type: error == nil ? .outputStopped : .outputFailed,
                sessionID: value.id, streamID: value.streamID, error: error,
                outputSession: value))
        }
    }

    private func fail(outputSessionID: String, streamID: UUID? = nil,
                      error: RuntimeErrorDTO) {
        queue.async { [weak self] in
            guard let self, let record = self.records[outputSessionID],
                  streamID == nil || record.streamID == streamID,
                  record.state == .starting || record.state == .ready || record.state == .draining else { return }
            record.backendSession.map { record.finalBackendMetrics = $0.metrics() }
            let session = record.backendSession
            record.backendSession = nil
            record.state = .failed
            record.terminalError = error
            let plane = record.dataPlane
            let value = self.snapshot(record)
            self.pruneTerminalRecords()
            self.cleanupQueue.async { plane.stop(); session?.stop() }
            self.eventHandler(RuntimeEventDTO(type: .outputFailed, sessionID: value.id,
                streamID: value.streamID, error: error, outputSession: value))
        }
    }

    private func backendEvent(sessionID: String, event: RuntimeOutputBackendEvent) {
        queue.async { [weak self] in
            guard let self, let record = self.records[sessionID],
                  record.state == .ready || record.state == .draining else { return }
            let type: RuntimeEventTypeDTO
            switch event.kind {
            case .underrun: type = .outputUnderrun
            case .overrun: type = .outputOverrun
            case .dropped: type = .outputDropped
            case .destinationChanged: type = .outputDestinationChanged
            }
            self.eventHandler(RuntimeEventDTO(type: type, sessionID: record.id,
                streamID: record.streamID.uuidString.lowercased(), message: event.message,
                droppedFrames: event.frames == 0 ? nil : event.frames,
                outputSession: self.snapshot(record)))
        }
    }

    private func snapshot(_ record: Record) -> RuntimeOutputSessionDTO {
        let plane = record.dataPlane.metrics()
        let backendMetrics = record.backendSession?.metrics() ?? record.finalBackendMetrics
        let metrics = RuntimeOutputMetricsDTO(
            packetsReceived: record.retiredPacketsReceived &+ plane.packetsReceived,
            inputFramesReceived: record.retiredInputFramesReceived &+ plane.inputFramesReceived,
            inputBytesReceived: record.retiredInputBytesReceived &+ plane.inputBytesReceived,
            deviceFramesEnqueued: backendMetrics.deviceFramesEnqueued,
            deviceFramesRendered: backendMetrics.deviceFramesRendered,
            droppedFrames: backendMetrics.droppedFrames,
            flushedFrames: backendMetrics.flushedFrames,
            lateFrames: backendMetrics.lateFrames &+ record.retiredDiscontinuities
                &+ plane.discontinuitiesReceived,
            underrunFrames: backendMetrics.underrunFrames,
            underrunEvents: backendMetrics.underrunEvents,
            overrunEvents: backendMetrics.overrunEvents,
            queueDepthFrames: backendMetrics.queueDepthFrames,
            queueHighWaterFrames: backendMetrics.queueHighWaterFrames,
            bufferedMilliseconds: backendMetrics.bufferedMilliseconds,
            targetBufferMilliseconds: record.targetBufferMilliseconds,
            conversionBatches: backendMetrics.conversionBatches,
            conversionNanoseconds: backendMetrics.conversionNanoseconds,
            routeChanges: backendMetrics.routeChanges,
            producerConnected: plane.producerConnected,
            deviceSampleRate: backendMetrics.deviceSampleRate,
            deviceChannelCount: backendMetrics.deviceChannelCount,
            estimatedOutputLatencyMilliseconds:
                backendMetrics.estimatedOutputLatencyMilliseconds,
            uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds &- record.startedAt)
        return RuntimeOutputSessionDTO(id: record.id,
            streamID: record.streamID.uuidString.lowercased(),
            destinationID: record.destinationID, state: record.state, format: record.format,
            dataSocketPath: record.dataPlane.path,
            startedAtNanoseconds: record.startedAt,
            targetBufferMilliseconds: record.targetBufferMilliseconds,
            metrics: metrics, error: record.terminalError)
    }

    private func pruneTerminalRecords(limit: Int = 128) {
        let terminal = records.values.filter {
            $0.state == .stopped || $0.state == .cancelled || $0.state == .failed
        }.sorted { $0.startedAt < $1.startedAt }
        for record in terminal.prefix(max(0, terminal.count - limit)) { archiveAndRemove(record) }
    }

    private func archiveAndRemove(_ record: Record) {
        guard records.removeValue(forKey: record.id) != nil else { return }
        let metrics = snapshot(record).metrics
        archivedReceived &+= metrics.inputFramesReceived
        archivedRendered &+= metrics.deviceFramesRendered
        archivedDropped &+= metrics.droppedFrames &+ metrics.flushedFrames
        archivedBytes &+= metrics.inputBytesReceived
    }

    private func notFound(_ id: String) -> RuntimeErrorDTO {
        RuntimeErrorDTO(code: "output_session_not_found",
            message: "No output session named \(id)")
    }
}
