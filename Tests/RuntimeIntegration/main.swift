import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

private final class FakeSession: RuntimeBackendCaptureSession, @unchecked Sendable {
    let outputFormat: RuntimePCMFormatDTO
    private let queue = DispatchQueue(label: "RuntimeIntegration.FakeSession")
    private var timer: DispatchSourceTimer?
    private let onEnded: @Sendable (RuntimeErrorDTO?) -> Void

    init(format: RuntimePCMFormatDTO,
         onFrame: @escaping @Sendable (RuntimeBackendAudioFrame) -> Void,
         onEnded: @escaping @Sendable (RuntimeErrorDTO?) -> Void) {
        outputFormat = format
        self.onEnded = onEnded
        let timer = DispatchSource.makeTimerSource(queue: queue)
        var sequence: UInt64 = 0
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler {
            let frameCount = format.sampleRate / 100
            let payload = Data(repeating: UInt8(truncatingIfNeeded: sequence),
                count: Int(frameCount) * format.bytesPerFrame)
            onFrame(RuntimeBackendAudioFrame(payload: payload, sequence: sequence,
                timestampNanoseconds: sequence * 10_000_000, frameCount: frameCount,
                format: format))
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
        format: RuntimePCMFormatDTO,
        onFrame: @escaping @Sendable (RuntimeBackendAudioFrame) -> Void,
        onDeviceChanged: @escaping @Sendable () -> Void,
        onEnded: @escaping @Sendable (RuntimeErrorDTO?) -> Void) throws -> RuntimeBackendCaptureSession {
        guard sourceID == "app.test.audio" else {
            throw RuntimeErrorDTO(code: "source_not_found", message: "Unknown synthetic source")
        }
        return FakeSession(format: format, onFrame: onFrame, onEnded: onEnded)
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
    expect(client.handshake?.protocolVersion == 2, "protocol v2 handshake failed")
    expect(client.handshake?.capabilities.contains("event_stream") == true,
           "handshake did not advertise events")
    let sources = try client.listSources()
    expect(sources.map(\.id) == ["app.test.audio"], "source enumeration failed")

    do {
        let duplicate = SonexisRuntimeServer(socketDirectory: directory, backend: FakeBackend())
        try duplicate.start()
        duplicate.stop()
        fatalError("a second runtime replaced the live control socket")
    } catch UnixSocketError.pathOccupied {
        // Expected: a stale socket may be replaced, a live runtime may not.
    }

    let malformed = try UnixSocketSystem.connect(path: server.paths.controlSocketPath)
    try malformed.write(Data(repeating: 0x61,
        count: RuntimeProtocolCodec.maximumControlMessageBytes + 1))
    let malformedResponse = try RuntimeProtocolCodec.decodeLine(
        RuntimeResponse.self,
        from: malformed.read()
    )
    expect(malformedResponse.error?.code == "message_too_large",
           "oversized control input did not return a typed error")
    malformed.close()

    let noHandshake = try UnixSocketSystem.connect(path: server.paths.controlSocketPath)
    try noHandshake.write(RuntimeProtocolCodec.encodeLine(RuntimeCommand(command: .listSources)))
    let noHandshakeResponse = try RuntimeProtocolCodec.decodeLine(RuntimeResponse.self,
        from: noHandshake.read())
    expect(noHandshakeResponse.error?.code == "handshake_required",
           "commands before hello were accepted")
    noHandshake.close()

    let wrongVersion = try UnixSocketSystem.connect(path: server.paths.controlSocketPath)
    try wrongVersion.write(RuntimeProtocolCodec.encodeLine(RuntimeCommand(protocolVersion: 99,
        command: .hello, supportedProtocolVersions: [99])))
    let wrongVersionResponse = try RuntimeProtocolCodec.decodeLine(RuntimeResponse.self,
        from: wrongVersion.read())
    expect(wrongVersionResponse.error?.code == "unsupported_protocol_version",
           "unsupported protocol version returned the wrong error")
    wrongVersion.close()

    if let cliPath = ProcessInfo.processInfo.environment["SONEXISCTL_BINARY"] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["sources", "--socket", server.paths.controlSocketPath]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        expect(process.terminationStatus == 0, "sonexisctl sources failed: \(text)")
        expect(text.contains("app.test.audio") && text.contains("Synthetic Audio"),
               "sonexisctl did not render sources: \(text)")
    }

    if let python = ProcessInfo.processInfo.environment["PYTHON_BINARY"],
       let smoke = ProcessInfo.processInfo.environment["PYTHON_SMOKE"] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [smoke, server.paths.controlSocketPath]
        process.environment = ProcessInfo.processInfo.environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        expect(process.terminationStatus == 0, "Python SDK smoke failed: \(text)")
        expect(text.contains("Python SDK real-Runtime smoke passed"),
               "Python SDK smoke omitted success marker: \(text)")
    }

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

    for format in RuntimePCMFormatDTO.supported {
        let session = try client.startCapture(sourceID: sources[0].id, format: format)
        expect(session.streamID != session.id, "session and stream IDs were not distinct")
        expect(session.format == format, "negotiated format changed")
        var received = 0
        try client.receiveFrames(session: session) { frame in
            expect(frame.header.sampleRate == format.sampleRate,
                   "negotiated sample rate was not framed")
            expect(frame.header.channelCount == format.channelCount,
                   "negotiated channel count was not framed")
            expect(frame.header.sampleFormat == format.sampleFormat,
                   "negotiated sample format was not framed")
            expect(frame.payload.count == Int(frame.header.frameCount) * format.bytesPerFrame,
                   "negotiated payload size is wrong")
            received += 1
            return received < 2
        }
        _ = try client.stopCapture(sessionID: session.id)
    }

    do {
        _ = try client.startCapture(sourceID: sources[0].id,
            format: RuntimePCMFormatDTO(sampleRate: 44_100, channelCount: 2))
        fatalError("unsupported format was accepted")
    } catch let error as RuntimeErrorDTO {
        expect(error.code == "unsupported_format", "unsupported format returned wrong error")
    }

    let subscription = try client.subscribeEvents([.captureStarted])
    let eventConnection = try UnixSocketSystem.connect(path: subscription.eventSocketPath)
    usleep(20_000)
    let eventSession = try client.startCapture(sourceID: sources[0].id)
    let event = try RuntimeProtocolCodec.decodeLine(RuntimeEventDTO.self,
        from: eventConnection.read())
    expect(event.type == .captureStarted && event.sessionID == eventSession.id,
           "capture_started event was not delivered")
    _ = try client.stopCapture(sessionID: eventSession.id)
    eventConnection.close()
    try client.unsubscribeEvents(id: subscription.id)

    let runtimeStatus = try client.runtimeStatus()
    expect(runtimeStatus.runtimeVersion == "0.2.0", "runtime status omitted version")
    expect(runtimeStatus.totalSessionsStarted >= 10, "runtime session counter did not advance")

    let firstTerminal = try client.startCapture(sourceID: sources[0].id)
    _ = try client.stopCapture(sessionID: firstTerminal.id)
    for _ in 0..<130 {
        let churn = try client.startCapture(sourceID: sources[0].id)
        _ = try client.stopCapture(sessionID: churn.id)
    }
    do {
        _ = try client.sessionStatus(sessionID: firstTerminal.id)
        fatalError("terminal session history was not bounded")
    } catch let error as RuntimeErrorDTO {
        expect(error.code == "session_not_found", "pruned session returned wrong error")
    }

    let abandonedClient = SonexisRuntimeClient(controlSocketPath: server.paths.controlSocketPath)
    try abandonedClient.connect()
    let abandoned = try abandonedClient.startCapture(sourceID: sources[0].id)
    abandonedClient.disconnect()
    var ownerCleanedUp = false
    for _ in 0..<50 where !ownerCleanedUp {
        usleep(10_000)
        do {
            _ = try client.sessionStatus(sessionID: abandoned.id)
        } catch let error as RuntimeErrorDTO where error.code == "session_not_found" {
            ownerCleanedUp = true
        }
    }
    expect(ownerCleanedUp, "control disconnect did not clean up its capture session")

    let concurrentA = try client.startCapture(sourceID: sources[0].id)
    let concurrentB = try client.startCapture(sourceID: sources[0].id)
    _ = try client.stopCapture(sessionID: concurrentA.id)
    _ = try client.stopCapture(sessionID: concurrentB.id)

    var cappedSessions: [RuntimeSessionDTO] = []
    for _ in 0..<8 { cappedSessions.append(try client.startCapture(sourceID: sources[0].id)) }
    do {
        _ = try client.startCapture(sourceID: sources[0].id)
        fatalError("per-client session limit was not enforced")
    } catch let error as RuntimeErrorDTO {
        expect(error.code == "session_limit_exceeded", "session limit returned wrong error")
    }
    for session in cappedSessions { _ = try client.stopCapture(sessionID: session.id) }

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

    let pressurePath = directory.appendingPathComponent("pressure.sock").path
    let pressurePlane = RuntimeDataPlane(path: pressurePath, streamID: UUID(), maximumSubscribers: 1)
    try pressurePlane.start()
    let stalled = try UnixSocketSystem.connect(path: pressurePath)
    usleep(20_000)
    let pressureFormat = RuntimePCMFormatDTO(sampleRate: 48_000, channelCount: 2,
        sampleFormat: .float32LE)
    let pressurePayload = Data(repeating: 7, count: 32_768 * pressureFormat.bytesPerFrame)
    for sequence in 0..<500 {
        pressurePlane.offer(RuntimeBackendAudioFrame(payload: pressurePayload,
            sequence: UInt64(sequence), timestampNanoseconds: UInt64(sequence) * 1_000_000,
            frameCount: 32_768, format: pressureFormat))
    }
    usleep(100_000)
    let pressureMetrics = pressurePlane.metrics()
    expect(pressureMetrics.queueDroppedFrames > 0 || pressureMetrics.slowConsumerDisconnects > 0,
           "slow consumer did not trigger bounded backpressure")
    expect(pressureMetrics.queueHighWaterMark <= 64, "data queue exceeded its bound")
    pressurePlane.stop()
    stalled.close()
    client.disconnect()
    print("Runtime integration tests passed")
} catch {
    server.stop()
    try? FileManager.default.removeItem(at: directory)
    fatalError("Runtime integration test failed: \(error)")
}
