import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

private final class FakeSession: RuntimeBackendCaptureSession, @unchecked Sendable {
    let outputFormat = RuntimePCMFormatDTO.runtimeDefault
    private let queue = DispatchQueue(label: "RuntimeIntegration.FakeSession")
    private var timer: DispatchSourceTimer?
    private let onEnded: @Sendable (RuntimeErrorDTO?) -> Void

    init(onFrame: @escaping @Sendable (RuntimeBackendAudioFrame) -> Void,
         onEnded: @escaping @Sendable (RuntimeErrorDTO?) -> Void) {
        self.onEnded = onEnded
        let timer = DispatchSource.makeTimerSource(queue: queue)
        var sequence: UInt64 = 0
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler {
            let payload = Data(repeating: UInt8(truncatingIfNeeded: sequence), count: 320)
            onFrame(RuntimeBackendAudioFrame(payload: payload, sequence: sequence,
                timestampNanoseconds: sequence * 10_000_000, frameCount: 160,
                format: .runtimeDefault))
            sequence &+= 1
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        queue.sync {
            guard let timer else { return }
            timer.setEventHandler {}
            timer.cancel()
            self.timer = nil
            onEnded(nil)
        }
    }
}

private final class FakeBackend: RuntimeCaptureBackend, @unchecked Sendable {
    func availableSources() throws -> [RuntimeSourceDTO] {
        [RuntimeSourceDTO(id: "app.test.audio", processID: 123, bundleIdentifier: "test.audio",
            name: "Synthetic Audio", isActive: true, isProducingAudio: true)]
    }

    func startCapture(sourceID: String,
        onFrame: @escaping @Sendable (RuntimeBackendAudioFrame) -> Void,
        onEnded: @escaping @Sendable (RuntimeErrorDTO?) -> Void) throws -> RuntimeBackendCaptureSession {
        guard sourceID == "app.test.audio" else {
            throw RuntimeErrorDTO(code: "source_not_found", message: "Unknown synthetic source")
        }
        return FakeSession(onFrame: onFrame, onEnded: onEnded)
    }
}

let directory = URL(fileURLWithPath: "/tmp/sxr-\(UUID().uuidString)", isDirectory: true)
let server = SonexisRuntimeServer(socketDirectory: directory, backend: FakeBackend())

do {
    try server.start()
    defer {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }
    let client = SonexisRuntimeClient(controlSocketPath: server.paths.controlSocketPath)
    try client.connect()
    let sources = try client.listSources()
    expect(sources.map(\.id) == ["app.test.audio"], "source enumeration failed")

    for _ in 0..<3 {
        let session = try client.startCapture(sourceID: sources[0].id)
        expect(session.state == .capturing, "session did not enter capturing")
        var received = 0
        try client.receiveFrames(session: session) { frame in
            expect(frame.header.sampleRate == 16_000, "wrong sample rate")
            expect(frame.header.channelCount == 1 && frame.header.bitsPerChannel == 16,
                   "wrong normalized PCM format")
            expect(frame.payload.count == 320, "wrong payload size")
            received += 1
            return received < 5
        }
        expect(received == 5, "PCM frames did not arrive")
        let stopped = try client.stopCapture(sessionID: session.id)
        expect(stopped.state == .stopped,
               "capture did not stop")
        let stoppedAgain = try client.stopCapture(sessionID: session.id)
        expect(stoppedAgain.state == .stopped,
               "second stop was not idempotent")
    }

    do {
        _ = try client.startCapture(sourceID: "invalid")
        fatalError("invalid source was accepted")
    } catch let error as RuntimeErrorDTO {
        expect(error.code == "source_not_found", "invalid source returned wrong error")
    }

    let secondClient = SonexisRuntimeClient(controlSocketPath: server.paths.controlSocketPath)
    try secondClient.connect()
    let secondSources = try secondClient.listSources()
    expect(secondSources.count == 1, "second client could not connect")
    secondClient.disconnect()
    client.disconnect()
    print("Runtime integration tests passed")
} catch {
    server.stop()
    try? FileManager.default.removeItem(at: directory)
    fatalError("Runtime integration test failed: \(error)")
}
