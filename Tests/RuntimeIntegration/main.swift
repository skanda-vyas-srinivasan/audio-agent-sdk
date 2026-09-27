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

private final class FakeOutputSession: RuntimeBackendOutputSession, @unchecked Sendable {
    let inputFormat: RuntimePCMFormatDTO
    let destination: RuntimeOutputDestinationDTO
    private let lock = NSLock()
    private let onEnded: @Sendable (RuntimeErrorDTO?) -> Void
    private var frames: UInt64 = 0
    private var writes: UInt64 = 0
    private var flushed: UInt64 = 0
    private var ended = false

    init(format: RuntimePCMFormatDTO,
         onEnded: @escaping @Sendable (RuntimeErrorDTO?) -> Void) {
        inputFormat = format
        destination = RuntimeOutputDestinationDTO(id: "default", kind: .playback,
            name: "Synthetic Output", isAvailable: true, isDefault: true,
            followsSystemDefault: true)
        self.onEnded = onEnded
    }

    func write(_ frame: RuntimePCMFrame) throws {
        lock.lock(); defer { lock.unlock() }
        guard !ended else {
            throw RuntimeErrorDTO(code: "output_not_writable", message: "Synthetic output ended")
        }
        frames &+= UInt64(frame.header.frameCount)
        writes &+= 1
    }

    func finish() {
        lock.lock()
        guard !ended else { lock.unlock(); return }
        ended = true
        lock.unlock()
        onEnded(nil)
    }

    func flush() throws {
        lock.lock()
        flushed &+= frames
        frames = 0
        lock.unlock()
    }

    func stop() {
        lock.lock(); ended = true; lock.unlock()
    }

    func metrics() -> RuntimeOutputMetricsDTO {
        lock.lock(); defer { lock.unlock() }
        return RuntimeOutputMetricsDTO(deviceFramesEnqueued: frames,
            deviceFramesRendered: frames, flushedFrames: flushed,
            queueHighWaterFrames: UInt32(clamping: frames),
            targetBufferMilliseconds: 60, conversionBatches: writes)
    }
}

private final class FakeOutputBackend: RuntimeOutputBackend, @unchecked Sendable {
    func availableOutputDestinations() throws -> [RuntimeOutputDestinationDTO] {
        [RuntimeOutputDestinationDTO(id: "default", kind: .playback,
            name: "Synthetic Output", isAvailable: true, isDefault: true,
            followsSystemDefault: true)]
    }

    func startOutput(destinationID: String, format: RuntimePCMFormatDTO,
                     targetBufferMilliseconds: UInt32,
                     onEvent: @escaping @Sendable (RuntimeOutputBackendEvent) -> Void,
                     onEnded: @escaping @Sendable (RuntimeErrorDTO?) -> Void)
        throws -> RuntimeBackendOutputSession {
        guard destinationID == "default" else {
            throw RuntimeErrorDTO(code: "output_destination_unavailable",
                message: "Unknown synthetic output")
        }
        return FakeOutputSession(format: format, onEnded: onEnded)
    }
}

let directory = URL(fileURLWithPath: "/tmp/sxr-\(UUID().uuidString)", isDirectory: true)
let server = SonexisRuntimeServer(socketDirectory: directory, backend: FakeBackend(),
    outputBackend: FakeOutputBackend())

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
    expect(client.handshake?.capabilities.contains("output_sessions") == true,
           "handshake did not advertise output")
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

    let unknownCommand = try UnixSocketSystem.connect(path: server.paths.controlSocketPath)
    try unknownCommand.write(RuntimeProtocolCodec.encodeLine(RuntimeCommand(command: .hello,
        supportedProtocolVersions: [2], clientName: "unknown-command-test")))
    _ = try RuntimeProtocolCodec.decodeLine(RuntimeResponse.self, from: unknownCommand.read())
    let unknownJSON = Data("{\"message_type\":\"request\",\"protocol_version\":2,\"request_id\":\"unknown-1\",\"command\":\"future_command\"}\n".utf8)
    try unknownCommand.write(unknownJSON)
    let unknownResponse = try RuntimeProtocolCodec.decodeLine(RuntimeResponse.self,
        from: unknownCommand.read())
    expect(unknownResponse.error?.code == "unsupported_command",
           "unknown command was not reported as unsupported")
    unknownCommand.close()

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

    var cappedSubscriptions: [RuntimeEventSubscriptionDTO] = []
    for _ in 0..<4 { cappedSubscriptions.append(try client.subscribeEvents()) }
    do {
        _ = try client.subscribeEvents()
        fatalError("per-client event subscription limit was not enforced")
    } catch let error as RuntimeErrorDTO {
        expect(error.code == "subscription_limit_exceeded",
               "event subscription cap returned the wrong error")
    }
    for item in cappedSubscriptions { try client.unsubscribeEvents(id: item.id) }

    let runtimeStatus = try client.runtimeStatus()
    expect(runtimeStatus.runtimeVersion == "0.4.0", "runtime status omitted version")
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
    // Session management is intentionally shared by same-UID clients so the
    // standalone `sonexisctl stop SESSION` command works. The owner connection
    // still controls automatic disconnect cleanup and per-client quotas.
    let sharedSession = try client.startCapture(sourceID: sources[0].id)
    let sharedStatus = try secondClient.sessionStatus(sessionID: sharedSession.id)
    expect(sharedStatus.state == .capturing,
           "same-user session status was not shared")
    let sharedStop = try secondClient.stopCapture(sessionID: sharedSession.id)
    expect(sharedStop.state == .stopped,
           "same-user session stop was not shared")
    secondClient.disconnect()

    let destinations = try client.listOutputDestinations()
    expect(destinations.map(\.id) == ["default"], "output destinations were not listed")
    let output = try client.startOutput(destinationID: "default",
        format: RuntimePCMFormatDTO(sampleRate: 24_000, channelCount: 1),
        targetBufferMilliseconds: 80)
    expect(output.state == .ready && output.streamID != output.id,
           "output session did not become ready")
    let outputWriter = try client.outputWriter(session: output)
    try outputWriter.write(Data(repeating: 1, count: 4_800))
    try outputWriter.finish()
    var drained = false
    for _ in 0..<100 where !drained {
        usleep(5_000)
        let status = try client.outputStatus(outputSessionID: output.id)
        drained = status.state == .stopped
        if drained {
            expect(status.metrics.inputFramesReceived == 2_400,
                   "output input-frame metrics were wrong")
            expect(status.metrics.deviceFramesRendered == 2_400,
                   "synthetic rendered-frame metrics were wrong")
        }
    }
    expect(drained, "output EOS did not drain and stop")

    let flushable = try client.startOutput(destinationID: "default")
    let staleWriter = try client.outputWriter(session: flushable)
    try staleWriter.write(Data(repeating: 2, count: 320))
    let flushIntruder = SonexisRuntimeClient(controlSocketPath: server.paths.controlSocketPath)
    try flushIntruder.connect()
    do {
        _ = try flushIntruder.flushOutput(outputSessionID: flushable.id)
        fatalError("a non-owner rotated an active producer stream")
    } catch let error as RuntimeErrorDTO {
        expect(error.code == "output_session_not_owned",
               "non-owner flush returned the wrong structured error")
    }
    flushIntruder.disconnect()
    let flushed = try client.flushOutput(outputSessionID: flushable.id)
    expect(flushed.streamID != flushable.streamID,
           "flush did not rotate the output stream epoch")
    staleWriter.cancel()
    let currentWriter = try client.outputWriter(session: flushed)
    try currentWriter.write(Data(repeating: 3, count: 320), discontinuity: true)
    currentWriter.cancel()
    let cancelled = try client.stopOutput(outputSessionID: flushed.id)
    expect(cancelled.state == .cancelled, "output stop did not cancel buffered playback")
    let cancelledAgain = try client.stopOutput(outputSessionID: flushed.id)
    expect(cancelledAgain.state == .cancelled, "duplicate output stop was not idempotent")

    let abandonedOutputClient = SonexisRuntimeClient(controlSocketPath: server.paths.controlSocketPath)
    try abandonedOutputClient.connect()
    let abandonedOutput = try abandonedOutputClient.startOutput()
    abandonedOutputClient.disconnect()
    var abandonedOutputCleaned = false
    for _ in 0..<50 where !abandonedOutputCleaned {
        usleep(10_000)
        do { _ = try client.outputStatus(outputSessionID: abandonedOutput.id) }
        catch let error as RuntimeErrorDTO where error.code == "output_session_not_found" {
            abandonedOutputCleaned = true
        }
    }
    expect(abandonedOutputCleaned, "control disconnect did not clean output ownership")

    let malformedOutput = try client.startOutput()
    let malformedConnection = try UnixSocketSystem.connect(path: malformedOutput.dataSocketPath)
    let wrongFormatPayload = Data(repeating: 0, count: 320)
    let wrongFormatHeader = RuntimePCMFrameHeader(payloadByteCount: 320,
        streamID: UUID(uuidString: malformedOutput.streamID)!, sequence: 0,
        timestampNanoseconds: 0, sampleRate: 24_000, frameCount: 160,
        channelCount: 1)
    try malformedConnection.write(RuntimePCMFrameCodec.encode(
        header: wrongFormatHeader, payload: wrongFormatPayload))
    malformedConnection.close()
    var malformedFailed = false
    for _ in 0..<50 where !malformedFailed {
        usleep(10_000)
        let value = try client.outputStatus(outputSessionID: malformedOutput.id)
        malformedFailed = value.state == .failed && value.error?.code == "output_format_mismatch"
    }
    expect(malformedFailed, "malformed output did not fail only its session")

    let tinyOutput = try client.startOutput(format:
        RuntimePCMFormatDTO(sampleRate: 24_000, channelCount: 1))
    let tinyConnection = try UnixSocketSystem.connect(path: tinyOutput.dataSocketPath)
    let tinyHeader = RuntimePCMFrameHeader(payloadByteCount: 2,
        streamID: UUID(uuidString: tinyOutput.streamID)!, sequence: 0,
        timestampNanoseconds: 0, sampleRate: 24_000, frameCount: 1,
        channelCount: 1)
    try tinyConnection.write(RuntimePCMFrameCodec.encode(
        header: tinyHeader, payload: Data([0, 0])))
    tinyConnection.close()
    var tinyFailed = false
    for _ in 0..<50 where !tinyFailed {
        usleep(10_000)
        let value = try client.outputStatus(outputSessionID: tinyOutput.id)
        tinyFailed = value.state == .failed && value.error?.code == "output_packet_too_short"
    }
    expect(tinyFailed, "sub-millisecond packet amplification was not rejected")

    let outputRuntimeStatus = try client.runtimeStatus()
    expect((outputRuntimeStatus.totalOutputSessionsStarted ?? 0) >= 4,
           "runtime output diagnostics did not advance")

    let eventPressurePath = directory.appendingPathComponent("event-pressure.sock").path
    let eventPressure = RuntimeEventPlane(path: eventPressurePath)
    try eventPressure.start()
    for index in 0..<20 {
        eventPressure.offer(RuntimeEventDTO(type: .runtimeWarning, message: "missed \(index)"))
    }
    for _ in 0..<100 where eventPressure.metrics() < 20 { usleep(1_000) }
    expect(eventPressure.metrics() == 20, "pre-attach event loss was not counted")
    let eventPressureClient = try UnixSocketSystem.connect(path: eventPressurePath)
    usleep(10_000)
    eventPressure.offer(RuntimeEventDTO(type: .runtimeWarning, message: "marker"))
    let marker = try RuntimeProtocolCodec.decodeLine(RuntimeEventDTO.self,
        from: eventPressureClient.read())
    expect(marker.eventSequence == 1 && marker.droppedEventsBefore == 20,
           "event loss was not reported on the next delivered event")
    eventPressure.stop()
    eventPressureClient.close()

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
