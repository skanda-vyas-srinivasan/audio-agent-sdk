import Foundation

final class AudioCaptureManager: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Sonexis.RuntimeCaptureManager")
    private var sessions: [UUID: AudioCaptureSession] = [:]

    func startCapture(
        source: AudioSource,
        onAudioFrame: AudioCaptureSession.FrameHandler? = nil
    ) throws -> AudioCaptureSession {
        let session = try AudioCaptureSession(
            source: source,
            frameHandler: onAudioFrame,
            onTermination: { [weak self] id in
                guard let manager = self else { return }
                manager.queue.async { [manager] in
                    manager.sessions.removeValue(forKey: id)
                }
            }
        )
        try session.start()
        queue.sync { sessions[session.id] = session }
        return session
    }

    func session(id: UUID) -> AudioCaptureSession? {
        queue.sync { sessions[id] }
    }

    func activeSessions() -> [AudioCaptureSession] {
        queue.sync { Array(sessions.values) }
    }

    func stopCapture(id: UUID) throws {
        guard let session = session(id: id) else {
            throw AudioCaptureError.sessionNotFound(id)
        }
        session.stop()
    }

    func stopAll() {
        let active = activeSessions()
        for session in active { session.stop() }
    }
}
