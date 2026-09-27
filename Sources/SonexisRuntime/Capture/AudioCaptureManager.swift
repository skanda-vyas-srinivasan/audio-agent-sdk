import Foundation
#if canImport(SonexisAudioEngine)
import SonexisAudioEngine
#endif

final class AudioCaptureManager: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Sonexis.RuntimeCaptureManager")
    private var sessions: [UUID: AudioCaptureSession] = [:]

    func startCapture(
        source: AudioSource,
        outputFormat: RuntimePCMFormat = .pcm16Mono16kHz,
        onAudioFrame: AudioCaptureSession.FrameHandler? = nil
    ) throws -> AudioCaptureSession {
        let session = try AudioCaptureSession(
            source: source,
            outputFormat: outputFormat,
            frameHandler: onAudioFrame,
            onTermination: { [weak self] id in
                guard let manager = self else { return }
                manager.queue.async { [manager] in
                    manager.sessions.removeValue(forKey: id)
                }
            }
        )
        queue.sync { sessions[session.id] = session }
        do {
            try session.start()
        } catch {
            _ = queue.sync { sessions.removeValue(forKey: session.id) }
            throw error
        }
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
