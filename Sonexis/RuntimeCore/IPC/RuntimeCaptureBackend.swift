import Foundation

public struct RuntimeBackendAudioFrame: Sendable {
    public let payload: Data
    public let sequence: UInt64
    public let timestampNanoseconds: UInt64
    public let frameCount: UInt32
    public let format: RuntimePCMFormatDTO

    public init(payload: Data, sequence: UInt64, timestampNanoseconds: UInt64,
                frameCount: UInt32, format: RuntimePCMFormatDTO) {
        self.payload = payload
        self.sequence = sequence
        self.timestampNanoseconds = timestampNanoseconds
        self.frameCount = frameCount
        self.format = format
    }
}

public protocol RuntimeBackendCaptureSession: AnyObject, Sendable {
    var outputFormat: RuntimePCMFormatDTO { get }
    func stop()
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
        onFrame: @escaping @Sendable (RuntimeBackendAudioFrame) -> Void,
        onEnded: @escaping @Sendable (RuntimeErrorDTO?) -> Void
    ) throws -> RuntimeBackendCaptureSession
}

public final class RuntimeSessionCoordinator: @unchecked Sendable {
    private final class Record {
        let id: String
        let sourceID: String
        let ownerID: String
        let startedAt: UInt64
        var format: RuntimePCMFormatDTO
        let dataPlane: RuntimeDataPlane
        var backendSession: RuntimeBackendCaptureSession?
        var state: RuntimeSessionStateDTO = .starting
        var terminalError: RuntimeErrorDTO?

        init(id: String, sourceID: String, ownerID: String, startedAt: UInt64,
             format: RuntimePCMFormatDTO, dataPlane: RuntimeDataPlane) {
            self.id = id; self.sourceID = sourceID; self.ownerID = ownerID
            self.startedAt = startedAt; self.format = format; self.dataPlane = dataPlane
        }
    }

    private let backend: RuntimeCaptureBackend
    private let socketDirectory: URL
    private let queue = DispatchQueue(label: "com.sonexis.runtime.sessions")
    private var records: [String: Record] = [:]

    public init(backend: RuntimeCaptureBackend, socketDirectory: URL) {
        self.backend = backend
        self.socketDirectory = socketDirectory
    }

    public func availableSources() throws -> [RuntimeSourceDTO] { try backend.availableSources() }

    public func startCapture(sourceID: String, ownerID: String) throws -> RuntimeSessionDTO {
        guard !sourceID.isEmpty, sourceID.utf8.count <= 1024 else {
            throw RuntimeErrorDTO(code: "invalid_source_id", message: "A valid source ID is required")
        }
        let sessionID = UUID().uuidString.lowercased()
        let dataPath = socketDirectory.appendingPathComponent("capture-\(sessionID).sock").path
        let plane = RuntimeDataPlane(path: dataPath)
        try plane.start()

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let record = Record(id: sessionID, sourceID: sourceID, ownerID: ownerID,
                            startedAt: startedAt, format: .runtimeDefault, dataPlane: plane)
        queue.sync { records[sessionID] = record }

        do {
            let backendSession = try backend.startCapture(sourceID: sourceID, onFrame: { [weak self] frame in
                self?.forward(frame, sessionID: sessionID)
            }, onEnded: { [weak self] error in
                self?.captureEnded(sessionID: sessionID, error: error)
            })
            queue.sync {
                // Backend startup may synchronously report termination.
                guard record.state == .starting else { backendSession.stop(); return }
                record.format = backendSession.outputFormat
                record.backendSession = backendSession
                record.state = .capturing
            }
            return snapshot(record)
        } catch {
            _ = queue.sync { records.removeValue(forKey: sessionID) }
            plane.stop()
            throw error
        }
    }

    public func stopCapture(sessionID: String) throws -> RuntimeSessionDTO {
        try queue.sync {
            guard let record = records[sessionID] else {
                throw RuntimeErrorDTO(code: "session_not_found", message: "No capture session named \(sessionID)")
            }
            stop(record, state: .stopped, error: nil)
            return snapshot(record)
        }
    }

    public func session(sessionID: String) throws -> RuntimeSessionDTO {
        try queue.sync {
            guard let record = records[sessionID] else {
                throw RuntimeErrorDTO(code: "session_not_found", message: "No capture session named \(sessionID)")
            }
            return snapshot(record)
        }
    }

    public func stopSessions(ownerID: String) {
        queue.sync {
            records.values.filter { $0.ownerID == ownerID && ($0.state == .starting || $0.state == .capturing) }
                .forEach { stop($0, state: .stopped, error: nil) }
        }
    }

    public func stopAll() {
        queue.sync {
            records.values.filter { $0.state == .starting || $0.state == .capturing }
                .forEach { stop($0, state: .stopped, error: nil) }
        }
    }

    private func forward(_ frame: RuntimeBackendAudioFrame, sessionID: String) {
        queue.async { [weak self] in
            guard let self, let record = self.records[sessionID], record.state == .capturing else { return }
            record.dataPlane.offer(frame)
        }
    }

    private func captureEnded(sessionID: String, error: RuntimeErrorDTO?) {
        queue.async { [weak self] in
            guard let self, let record = self.records[sessionID], record.state == .starting || record.state == .capturing else { return }
            self.stop(record, state: error == nil ? .stopped : .failed, error: error)
        }
    }

    private func stop(_ record: Record, state: RuntimeSessionStateDTO, error: RuntimeErrorDTO?) {
        guard record.state == .starting || record.state == .capturing else { return }
        record.state = state
        record.terminalError = error
        let session = record.backendSession
        record.backendSession = nil
        // Stop production before closing subscribers, so no callback can target a removed socket.
        session?.stop()
        record.dataPlane.stop()
    }

    private func snapshot(_ record: Record) -> RuntimeSessionDTO {
        let metrics = record.dataPlane.metrics()
        return RuntimeSessionDTO(id: record.id, sourceID: record.sourceID, state: record.state,
            format: record.format, dataSocketPath: record.dataPlane.path,
            startedAtNanoseconds: record.startedAt, framesForwarded: metrics.framesForwarded,
            droppedFrames: metrics.droppedFrames)
    }
}
