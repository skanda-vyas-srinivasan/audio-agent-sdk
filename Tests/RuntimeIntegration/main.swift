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

    func metrics() -> RuntimeCaptureMetricsDTO {
        queue.sync {
            RuntimeCaptureMetricsDTO(deliveryDroppedFrames: timer == nil ? 7 : 0)
        }
    }
}

private final class FakeBackend: RuntimeCaptureBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var discoveryFailure = false

    func setDiscoveryFailure(_ value: Bool) {
        lock.lock(); discoveryFailure = value; lock.unlock()
    }

    func availableSources() throws -> [RuntimeSourceDTO] {
        lock.lock(); let shouldFail = discoveryFailure; lock.unlock()
        if shouldFail {
            throw RuntimeErrorDTO(code: "synthetic_source_failure",
                message: "synthetic source discovery failure", retryable: true)
        }
        return [RuntimeSourceDTO(id: "app.test.audio", processID: 123, bundleIdentifier: "test.audio",
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

private final class DuplicateSourceBackend: RuntimeCaptureBackend, @unchecked Sendable {
    func availableSources() throws -> [RuntimeSourceDTO] {
        let source = RuntimeSourceDTO(id: "app.duplicate", processID: 1,
            bundleIdentifier: "duplicate", name: "Duplicate", isActive: true)
        return [source, source]
    }
    func startCapture(sourceID: String, format: RuntimePCMFormatDTO,
        onFrame: @escaping @Sendable (RuntimeBackendAudioFrame) -> Void,
        onDeviceChanged: @escaping @Sendable () -> Void,
        onEnded: @escaping @Sendable (RuntimeErrorDTO?) -> Void)
        throws -> RuntimeBackendCaptureSession {
        throw RuntimeErrorDTO(code: "unused", message: "unused")
    }
}

private final class SlowStartSession: RuntimeBackendCaptureSession, @unchecked Sendable {
    let outputFormat: RuntimePCMFormatDTO
    init(format: RuntimePCMFormatDTO) { outputFormat = format }
    func stop() {}
}

private final class SlowStartBackend: RuntimeCaptureBackend, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func availableSources() throws -> [RuntimeSourceDTO] { [] }
    func startCapture(sourceID: String, format: RuntimePCMFormatDTO,
        onFrame: @escaping @Sendable (RuntimeBackendAudioFrame) -> Void,
        onDeviceChanged: @escaping @Sendable () -> Void,
        onEnded: @escaping @Sendable (RuntimeErrorDTO?) -> Void)
        throws -> RuntimeBackendCaptureSession {
        entered.signal()
        release.wait()
        return SlowStartSession(format: format)
    }
}

private final class SlowStopSession: RuntimeBackendCaptureSession, @unchecked Sendable {
    let outputFormat: RuntimePCMFormatDTO
    let entered: DispatchSemaphore
    let release: DispatchSemaphore
    init(format: RuntimePCMFormatDTO, entered: DispatchSemaphore,
         release: DispatchSemaphore) {
        outputFormat = format
        self.entered = entered
        self.release = release
    }
    func stop() { entered.signal(); release.wait() }
}

private final class SlowStopBackend: RuntimeCaptureBackend, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func availableSources() throws -> [RuntimeSourceDTO] { [] }
    func startCapture(sourceID: String, format: RuntimePCMFormatDTO,
        onFrame: @escaping @Sendable (RuntimeBackendAudioFrame) -> Void,
        onDeviceChanged: @escaping @Sendable () -> Void,
        onEnded: @escaping @Sendable (RuntimeErrorDTO?) -> Void)
        throws -> RuntimeBackendCaptureSession {
        SlowStopSession(format: format, entered: entered, release: release)
    }
}

private final class SlowStartStopBackend: RuntimeCaptureBackend, @unchecked Sendable {
    let startEntered = DispatchSemaphore(value: 0)
    let startRelease = DispatchSemaphore(value: 0)
    let stopEntered = DispatchSemaphore(value: 0)
    let stopRelease = DispatchSemaphore(value: 0)
    func availableSources() throws -> [RuntimeSourceDTO] { [] }
    func startCapture(sourceID: String, format: RuntimePCMFormatDTO,
        onFrame: @escaping @Sendable (RuntimeBackendAudioFrame) -> Void,
        onDeviceChanged: @escaping @Sendable () -> Void,
        onEnded: @escaping @Sendable (RuntimeErrorDTO?) -> Void)
        throws -> RuntimeBackendCaptureSession {
        startEntered.signal(); startRelease.wait()
        return SlowStopSession(format: format, entered: stopEntered, release: stopRelease)
    }
}

private final class SlowStartStopOutputBackend: RuntimeOutputBackend, @unchecked Sendable {
    let startEntered = DispatchSemaphore(value: 0)
    let startRelease = DispatchSemaphore(value: 0)
    let stopEntered = DispatchSemaphore(value: 0)
    let stopRelease = DispatchSemaphore(value: 0)
    func availableOutputDestinations() throws -> [RuntimeOutputDestinationDTO] { [] }
    func startOutput(destinationID: String, format: RuntimePCMFormatDTO,
                     targetBufferMilliseconds: UInt32,
                     onEvent: @escaping @Sendable (RuntimeOutputBackendEvent) -> Void,
                     onEnded: @escaping @Sendable (RuntimeErrorDTO?) -> Void)
        throws -> RuntimeBackendOutputSession {
        startEntered.signal(); startRelease.wait()
        return BlockingOutputSession(format: format, entered: stopEntered, release: stopRelease)
    }
}

private final class BlockingOutputSession: RuntimeBackendOutputSession, @unchecked Sendable {
    let inputFormat: RuntimePCMFormatDTO
    let destination = RuntimeOutputDestinationDTO(id: "default", kind: .playback,
        name: "Blocking", isAvailable: true, isDefault: true)
    private let entered: DispatchSemaphore
    private let release: DispatchSemaphore
    init(format: RuntimePCMFormatDTO, entered: DispatchSemaphore,
         release: DispatchSemaphore) {
        inputFormat = format; self.entered = entered; self.release = release
    }
    func write(_ frame: RuntimePCMFrame) throws {}
    func finish() {}
    func flush() throws {}
    func stop() { entered.signal(); release.wait() }
    func metrics() -> RuntimeOutputMetricsDTO { .init() }
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
    private let lock = NSLock()
    private var destinations = [RuntimeOutputDestinationDTO(id: "default", kind: .playback,
        name: "Synthetic Output", isAvailable: true, isDefault: true,
        followsSystemDefault: true, activeDeviceID: "coreaudio:synthetic-a",
        activeDeviceName: "Synthetic A")]

    func availableOutputDestinations() throws -> [RuntimeOutputDestinationDTO] {
        lock.lock(); defer { lock.unlock() }
        return destinations
    }

    func replaceDestinations(_ next: [RuntimeOutputDestinationDTO]) {
        lock.lock(); destinations = next; lock.unlock()
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
private let outputBackend = FakeOutputBackend()
private let captureBackend = FakeBackend()
let server = SonexisRuntimeServer(socketDirectory: directory, backend: captureBackend,
    outputBackend: outputBackend, handshakeTimeoutMilliseconds: 100)

do {
    // The control socket fits here, but a UUID-bearing PCM/event socket does not.
    let longDirectory = directory.appendingPathComponent(String(repeating: "x", count: 25))
    let longServer = SonexisRuntimeServer(socketDirectory: longDirectory, backend: FakeBackend())
    defer { longServer.stop(); try? FileManager.default.removeItem(at: longDirectory) }
    do {
        try longServer.start()
        longServer.stop()
        fatalError("Runtime accepted a directory that cannot hold its session sockets")
    } catch let error as RuntimeErrorDTO {
        expect(error.code == "invalid_socket_directory", "wrong long-directory startup error")
        expect(error.message.contains("shorter"), "long-directory error needs actionable guidance")
    }
    expect(!FileManager.default.fileExists(atPath: longDirectory.path),
           "invalid directory validation must precede filesystem mutation")

    let sampleID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let maximumDirectoryBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
        - "/i-\(sampleID).sock".utf8.count
    let boundary = directory.appendingPathComponent(String(repeating: "b",
        count: maximumDirectoryBytes - directory.path.utf8.count - 1))
    try RuntimeSocketPaths(directory: boundary).prepareDirectory()
    defer { try? FileManager.default.removeItem(at: boundary) }
    for prefix in ["i", "o", "e"] {
        let path = boundary.appendingPathComponent("\(prefix)-\(sampleID).sock").path
        let listener = UnixSocketListener(path: path,
            queue: DispatchQueue(label: "RuntimeIntegration.PathBoundary"))
        try listener.start { $0.close() }
        listener.stop()
    }
    for invalid in [URL(fileURLWithPath: boundary.path + "x"),
                    directory.appendingPathComponent(String(repeating: "é", count: 15))] {
        do {
            try RuntimeSocketPaths(directory: invalid).prepareDirectory()
            fatalError("oversized UTF-8 socket directory passed validation")
        } catch let error as RuntimeErrorDTO {
            expect(error.code == "invalid_socket_directory", "wrong UTF-8 path error")
        }
        expect(!FileManager.default.fileExists(atPath: invalid.path), "invalid path created a directory")
    }

    let duplicateCoordinator = RuntimeSessionCoordinator(backend: DuplicateSourceBackend(),
        socketDirectory: directory)
    do {
        _ = try duplicateCoordinator.availableSources()
        fatalError("duplicate source discovery was accepted")
    } catch let error as RuntimeErrorDTO {
        expect(error.code == "duplicate_source",
               "duplicate source discovery returned the wrong error")
    }

    let slowBackend = SlowStartBackend()
    let slowDirectory = directory.appendingPathComponent("slow", isDirectory: true)
    try FileManager.default.createDirectory(at: slowDirectory,
        withIntermediateDirectories: true)
    let slowCoordinator = RuntimeSessionCoordinator(backend: slowBackend,
        socketDirectory: slowDirectory)
    let slowGroup = DispatchGroup()
    slowGroup.enter()
    DispatchQueue.global().async {
        _ = try? slowCoordinator.startCapture(sourceID: "slow", format: .runtimeDefault,
            ownerID: "slow-owner")
        slowGroup.leave()
    }
    expect(slowBackend.entered.wait(timeout: .now() + 1) == .success,
           "slow-start fixture did not enter the backend")
    let shutdownStarted = DispatchTime.now().uptimeNanoseconds
    slowCoordinator.stopAll()
    let shutdownElapsed = DispatchTime.now().uptimeNanoseconds - shutdownStarted
    expect(shutdownElapsed < 500_000_000,
           "Runtime shutdown waited on non-cancellable backend startup")
    slowBackend.release.signal()
    expect(slowGroup.wait(timeout: .now() + 1) == .success,
           "late backend startup did not reconcile after shutdown")

    let slowStopBackend = SlowStopBackend()
    let slowStopDirectory = directory.appendingPathComponent("slow-stop", isDirectory: true)
    try FileManager.default.createDirectory(at: slowStopDirectory,
        withIntermediateDirectories: true)
    let slowStopCoordinator = RuntimeSessionCoordinator(backend: slowStopBackend,
        socketDirectory: slowStopDirectory)
    let slowStopSession = try slowStopCoordinator.startCapture(sourceID: "slow-stop",
        format: .runtimeDefault, ownerID: "slow-stop-owner")
    let slowStopGroup = DispatchGroup()
    slowStopGroup.enter()
    DispatchQueue.global().async {
        _ = try? slowStopCoordinator.stopCapture(sessionID: slowStopSession.id,
            ownerID: "slow-stop-owner")
        slowStopGroup.leave()
    }
    expect(slowStopBackend.entered.wait(timeout: .now() + 1) == .success,
           "slow-stop fixture did not enter backend teardown")
    let stopShutdownStarted = DispatchTime.now().uptimeNanoseconds
    slowStopCoordinator.stopAll()
    expect(DispatchTime.now().uptimeNanoseconds - stopShutdownStarted < 500_000_000,
           "Runtime shutdown blocked behind backend teardown")
    slowStopBackend.release.signal()
    expect(slowStopGroup.wait(timeout: .now() + 1) == .success,
           "slow backend teardown did not finish after release")

    let lateCaptureBackend = SlowStartStopBackend()
    let lateCaptureDirectory = directory.appendingPathComponent("late-capture", isDirectory: true)
    try FileManager.default.createDirectory(at: lateCaptureDirectory,
        withIntermediateDirectories: true)
    let lateCaptureCoordinator = RuntimeSessionCoordinator(backend: lateCaptureBackend,
        socketDirectory: lateCaptureDirectory)
    let lateCaptureGroup = DispatchGroup()
    lateCaptureGroup.enter()
    DispatchQueue.global().async {
        _ = try? lateCaptureCoordinator.startCapture(sourceID: "late", format: .runtimeDefault,
            ownerID: "late")
        lateCaptureGroup.leave()
    }
    expect(lateCaptureBackend.startEntered.wait(timeout: .now() + 1) == .success,
           "late capture fixture did not enter startup")
    lateCaptureCoordinator.stopAll()
    lateCaptureBackend.startRelease.signal()
    expect(lateCaptureBackend.stopEntered.wait(timeout: .now() + 1) == .success,
           "late capture session did not reconcile")
    let captureQueueProbe = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        _ = lateCaptureCoordinator.diagnostics(); captureQueueProbe.signal()
    }
    expect(captureQueueProbe.wait(timeout: .now() + 1) == .success,
           "late capture teardown blocked coordinator state")
    lateCaptureBackend.stopRelease.signal()
    expect(lateCaptureGroup.wait(timeout: .now() + 1) == .success,
           "late capture teardown did not finish")

    let lateOutputBackend = SlowStartStopOutputBackend()
    let lateOutputDirectory = directory.appendingPathComponent("late-output", isDirectory: true)
    try FileManager.default.createDirectory(at: lateOutputDirectory,
        withIntermediateDirectories: true)
    let lateOutputCoordinator = RuntimeOutputCoordinator(backend: lateOutputBackend,
        socketDirectory: lateOutputDirectory)
    let lateOutputGroup = DispatchGroup()
    lateOutputGroup.enter()
    DispatchQueue.global().async {
        _ = try? lateOutputCoordinator.startOutput(destinationID: "default",
            format: .runtimeDefault, ownerID: "late")
        lateOutputGroup.leave()
    }
    expect(lateOutputBackend.startEntered.wait(timeout: .now() + 1) == .success,
           "late output fixture did not enter startup")
    lateOutputCoordinator.stopAll()
    lateOutputBackend.startRelease.signal()
    expect(lateOutputBackend.stopEntered.wait(timeout: .now() + 1) == .success,
           "late output session did not reconcile")
    let outputQueueProbe = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        _ = lateOutputCoordinator.diagnostics(); outputQueueProbe.signal()
    }
    expect(outputQueueProbe.wait(timeout: .now() + 1) == .success,
           "late output teardown blocked coordinator state")
    lateOutputBackend.stopRelease.signal()
    expect(lateOutputGroup.wait(timeout: .now() + 1) == .success,
           "late output teardown did not finish")

    let contenders = [
        SonexisRuntimeServer(socketDirectory: directory, backend: FakeBackend()),
        SonexisRuntimeServer(socketDirectory: directory, backend: FakeBackend()),
    ]
    let contenderLock = NSLock()
    let contenderGate = DispatchSemaphore(value: 0)
    let contenderGroup = DispatchGroup()
    var contenderResults: [Bool] = []
    for contender in contenders {
        contenderGroup.enter()
        DispatchQueue.global().async {
            var started = false
            do { try contender.start(); started = true }
            catch let error as RuntimeErrorDTO where error.code == "already_running" { }
            catch { }
            contenderLock.lock(); contenderResults.append(started); contenderLock.unlock()
            contenderGate.wait()
            if started { contender.stop() }
            contenderGroup.leave()
        }
    }
    for _ in 0..<1_000 {
        contenderLock.lock(); let complete = contenderResults.count == 2; contenderLock.unlock()
        if complete { break }
        usleep(1_000)
    }
    contenderGate.signal(); contenderGate.signal(); contenderGroup.wait()
    expect(contenderResults.filter { $0 }.count == 1,
           "concurrent Runtime startup did not elect exactly one owner")

    let restartDirectory = directory.appendingPathComponent("restart-monitor", isDirectory: true)
    let restartBackend = FakeBackend()
    restartBackend.setDiscoveryFailure(true)
    let restartServer = SonexisRuntimeServer(socketDirectory: restartDirectory,
        backend: restartBackend, outputBackend: FakeOutputBackend(),
        handshakeTimeoutMilliseconds: 100)
    try restartServer.start()
    let restartClientA = SonexisRuntimeClient(
        controlSocketPath: restartServer.paths.controlSocketPath)
    try restartClientA.connect()
    var sawInitialFailure = false
    for _ in 0..<50 where !sawInitialFailure {
        sawInitialFailure = (try restartClientA.runtimeStatus()
            .totalSourceMonitorFailures ?? 0) > 0
        if !sawInitialFailure { usleep(10_000) }
    }
    expect(sawInitialFailure, "initial monitor failure was not accounted")
    restartBackend.setDiscoveryFailure(false)
    var sawInitialRecovery = false
    for _ in 0..<150 where !sawInitialRecovery {
        sawInitialRecovery = (try restartClientA.runtimeStatus()
            .sourceMonitorRecoveries ?? 0) > 0
        if !sawInitialRecovery { usleep(10_000) }
    }
    expect(sawInitialRecovery, "initial monitor failure did not recover")
    let restartClientB = SonexisRuntimeClient(
        controlSocketPath: restartServer.paths.controlSocketPath)
    try restartClientB.connect()
    restartServer.stop()
    try restartServer.start()
    let restartClientC = SonexisRuntimeClient(
        controlSocketPath: restartServer.paths.controlSocketPath)
    try restartClientC.connect()
    let restartedStatus = try restartClientC.runtimeStatus()
    expect((restartedStatus.totalControlClientsAccepted ?? 0)
            - (restartedStatus.totalControlClientsDisconnected ?? 0)
            == UInt64(restartedStatus.activeClients),
           "control accounting did not reconcile across in-process restart")
    restartClientC.disconnect()
    restartServer.stop()

    let staleSeed = directory.appendingPathComponent("stale-seed.sock").path
    let stalePath = directory.appendingPathComponent(
        "i-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()).sock").path
    let staleListener = UnixSocketListener(path: staleSeed,
        queue: DispatchQueue(label: "RuntimeIntegration.StaleSocket"))
    try staleListener.start { $0.close() }
    expect(rename(staleSeed, stalePath) == 0, "could not prepare stale session socket")
    staleListener.stop()
    var staleStatus = stat()
    expect(lstat(stalePath, &staleStatus) == 0, "stale socket fixture was not created")

    try server.start()
    expect(lstat(stalePath, &staleStatus) != 0 && errno == ENOENT,
           "Runtime startup did not reap its stale session socket")
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
    expect(client.handshake?.capabilities.contains("output_destination_events") == true,
           "handshake did not advertise destination lifecycle events")
    expect(client.handshake?.capabilities.contains("exact_uint64_mirrors") == true,
           "handshake did not advertise exact UInt64 mirrors")
    let sources = try client.listSources()
    expect(sources.map(\.id) == ["app.test.audio"], "source enumeration failed")

    do {
        let duplicate = SonexisRuntimeServer(socketDirectory: directory, backend: FakeBackend())
        try duplicate.start()
        duplicate.stop()
        fatalError("a second runtime replaced the live control socket")
    } catch let error as RuntimeErrorDTO where error.code == "already_running" {
        // Expected: the directory ownership lock serializes live Runtime startup.
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

    let idleBeforeHandshake = try UnixSocketSystem.connect(path: server.paths.controlSocketPath)
    usleep(250_000)
    do {
        _ = try idleBeforeHandshake.read()
        fatalError("idle pre-handshake client was not disconnected")
    } catch { }
    idleBeforeHandshake.close()

    let slowHandshake = try UnixSocketSystem.connect(path: server.paths.controlSocketPath)
    try slowHandshake.write(Data("{".utf8))
    usleep(60_000)
    // A receive timeout alone is inactivity-based. This second byte must not
    // extend the absolute hello deadline.
    try slowHandshake.write(Data(" ".utf8))
    usleep(100_000)
    do {
        _ = try slowHandshake.read()
        fatalError("slow partial handshake retained a control slot past its deadline")
    } catch { }
    slowHandshake.close()

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

        let diagnostics = Process()
        let diagnosticsOutput = Pipe()
        diagnostics.executableURL = URL(fileURLWithPath: cliPath)
        diagnostics.arguments = ["diagnostics", "--json", "--socket",
            server.paths.controlSocketPath]
        diagnostics.standardOutput = diagnosticsOutput
        diagnostics.standardError = diagnosticsOutput
        try diagnostics.run()
        diagnostics.waitUntilExit()
        let diagnosticsData = diagnosticsOutput.fileHandleForReading.readDataToEndOfFile()
        let diagnosticsJSON = try JSONSerialization.jsonObject(with: diagnosticsData) as? [String: Any]
        expect(diagnostics.terminationStatus == 0 && diagnosticsJSON?["schema_version"] as? Int == 1,
               "sonexisctl diagnostics did not produce its versioned JSON bundle")
        let allowedBundleKeys: Set<String> = ["schema_version", "generated_at",
            "generated_at_unix_milliseconds", "protocol_version", "runtime_version",
            "runtime_instance_id", "capabilities", "limits", "status"]
        expect(Set(diagnosticsJSON?.keys.map { $0 } ?? []) == allowedBundleKeys
                && diagnosticsJSON?["generated_at"] is String
                && diagnosticsJSON?["generated_at_unix_milliseconds"] is NSNumber
                && diagnosticsJSON?["generated_at_nanoseconds"] == nil,
               "diagnostic bundle schema leaked fields or used unsafe epoch nanoseconds")

        let bundlePath = directory.appendingPathComponent("support-bundle.json").path
        let bundle = Process()
        let bundleOutput = Pipe()
        bundle.executableURL = URL(fileURLWithPath: cliPath)
        bundle.arguments = ["diagnostics", "--output", bundlePath, "--socket",
            server.paths.controlSocketPath]
        bundle.standardOutput = bundleOutput
        bundle.standardError = bundleOutput
        try bundle.run()
        bundle.waitUntilExit()
        var bundleStatus = stat()
        expect(bundle.terminationStatus == 0 && lstat(bundlePath, &bundleStatus) == 0
                && bundleStatus.st_mode & S_IFMT == S_IFREG
                && bundleStatus.st_mode & 0o777 == 0o600,
               "diagnostic bundle was not written as a private regular file")
        let bundleData = try Data(contentsOf: URL(fileURLWithPath: bundlePath))
        let bundleText = String(decoding: bundleData, as: UTF8.self)
        expect(!bundleText.contains("data_socket_path") && !bundleText.contains("api_key"),
               "diagnostic bundle contained a socket capability or credential field")
        let bundleTarget = directory.appendingPathComponent("bundle-target.json")
        let bundleLink = directory.appendingPathComponent("bundle-link.json")
        try FileManager.default.createSymbolicLink(at: bundleLink,
            withDestinationURL: bundleTarget)
        let symlinkBundle = Process()
        let symlinkOutput = Pipe()
        symlinkBundle.executableURL = URL(fileURLWithPath: cliPath)
        symlinkBundle.arguments = ["diagnostics", "--output", bundleLink.path,
            "--socket", server.paths.controlSocketPath]
        symlinkBundle.standardOutput = symlinkOutput
        symlinkBundle.standardError = symlinkOutput
        try symlinkBundle.run()
        symlinkBundle.waitUntilExit()
        expect(symlinkBundle.terminationStatus != 0
                && !FileManager.default.fileExists(atPath: bundleTarget.path),
               "diagnostic bundle followed a symbolic-link output")

        let unavailable = Process()
        let unavailableOutput = Pipe()
        unavailable.executableURL = URL(fileURLWithPath: cliPath)
        unavailable.arguments = ["status", "--json", "--socket",
            directory.appendingPathComponent("missing.sock").path]
        unavailable.standardOutput = unavailableOutput
        unavailable.standardError = unavailableOutput
        try unavailable.run()
        unavailable.waitUntilExit()
        let unavailableData = unavailableOutput.fileHandleForReading.readDataToEndOfFile()
        let unavailableJSON = try JSONSerialization.jsonObject(with: unavailableData) as? [String: Any]
        let unavailableError = unavailableJSON?["error"] as? [String: Any]
        expect(unavailable.terminationStatus != 0
                && unavailableError?["code"] as? String == "runtime_unavailable",
               "sonexisctl --json failure did not produce a structured JSON envelope")
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

    let monitorSubscription = try client.subscribeEvents([.runtimeWarning])
    let monitorEvents = try UnixSocketSystem.connect(path: monitorSubscription.eventSocketPath)
    usleep(20_000)
    captureBackend.setDiscoveryFailure(true)
    let monitorFailure = try RuntimeProtocolCodec.decodeLine(RuntimeEventDTO.self,
        from: monitorEvents.read())
    expect(monitorFailure.error?.code == "source_discovery_failed",
           "source monitor failure event was not structured")
    captureBackend.setDiscoveryFailure(false)
    let monitorRecovery = try RuntimeProtocolCodec.decodeLine(RuntimeEventDTO.self,
        from: monitorEvents.read())
    expect(monitorRecovery.message == "Source discovery recovered",
           "source monitor recovery was not observable")
    monitorEvents.close()
    try client.unsubscribeEvents(id: monitorSubscription.id)

    let runtimeStatus = try client.runtimeStatus()
    expect(runtimeStatus.runtimeVersion == RuntimeProtocolInfo.runtimeVersion,
        "runtime status omitted version")
    expect(runtimeStatus.totalSessionsStarted >= 10, "runtime session counter did not advance")
    expect((runtimeStatus.totalCaptureDeliveryDroppedFrames ?? 0) >= 21,
           "capture teardown did not preserve final backend drop metrics")
    expect((runtimeStatus.totalControlClientsAccepted ?? 0) >= 5,
           "accepted control clients were not accounted")
    expect((runtimeStatus.totalControlErrors ?? 0) >= 4,
           "control errors were not accounted")
    expect((runtimeStatus.totalMalformedControlMessages ?? 0) >= 1,
           "malformed control messages were not accounted")
    expect((runtimeStatus.totalControlHandshakeTimeouts ?? 0) >= 1,
           "pre-handshake timeout was not accounted")
    expect((runtimeStatus.totalSourceMonitorFailures ?? 0) >= 1
            && (runtimeStatus.sourceMonitorRecoveries ?? 0) >= 1
            && (runtimeStatus.sourceMonitorConsecutiveFailures ?? 1) == 0,
           "source monitor failure/recovery diagnostics were incorrect")
    expect((runtimeStatus.residentMemoryBytes ?? 0) > 0
            && (runtimeStatus.openFileDescriptors ?? 0) > 0
            && (runtimeStatus.threadCount ?? 0) > 0,
           "process resource diagnostics were unavailable")
    expect(runtimeStatus.exactCounters?.count == 41
            && runtimeStatus.exactCounters?["total_output_conversion_nanoseconds"] != nil
            && runtimeStatus.exactCounters?["source_monitor_last_success_nanoseconds"] != nil,
           "exact diagnostic mirrors did not cover every UInt64 status field")

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

    let destinationSubscription = try client.subscribeEvents([
        .outputDestinationAdded, .outputDestinationRemoved, .outputDestinationUpdated,
        .outputDefaultChanged,
    ])
    let destinationEvents = try UnixSocketSystem.connect(
        path: destinationSubscription.eventSocketPath)
    usleep(20_000)
    let changedDefault = RuntimeOutputDestinationDTO(id: "default", kind: .playback,
        name: "Synthetic Output", isAvailable: true, isDefault: true,
        followsSystemDefault: true, activeDeviceID: "coreaudio:synthetic-b",
        activeDeviceName: "Synthetic B")
    let loopback = RuntimeOutputDestinationDTO(id: "coreaudio:loopback",
        kind: .virtualInput, name: "Synthetic Loopback", isAvailable: true,
        activeDeviceID: "coreaudio:loopback", activeDeviceName: "Synthetic Loopback")
    outputBackend.replaceDestinations([changedDefault, loopback])
    let firstDestinationEvent = try RuntimeProtocolCodec.decodeLine(RuntimeEventDTO.self,
        from: destinationEvents.read())
    let secondDestinationEvent = try RuntimeProtocolCodec.decodeLine(RuntimeEventDTO.self,
        from: destinationEvents.read())
    expect([firstDestinationEvent.type, secondDestinationEvent.type]
        == [.outputDestinationAdded, .outputDefaultChanged],
        "destination add/default events were not deterministic")
    expect(firstDestinationEvent.outputDestinationID == loopback.id
            && firstDestinationEvent.outputDestination == loopback,
           "destination add event omitted typed identity")
    expect(secondDestinationEvent.outputDestination?.activeDeviceID
            == "coreaudio:synthetic-b",
           "default change event omitted stable resolved device ID")
    outputBackend.replaceDestinations([changedDefault])
    let removedDestinationEvent = try RuntimeProtocolCodec.decodeLine(RuntimeEventDTO.self,
        from: destinationEvents.read())
    expect(removedDestinationEvent.type == .outputDestinationRemoved
            && removedDestinationEvent.outputDestinationID == loopback.id,
           "destination removal event was not delivered")
    destinationEvents.close()
    try client.unsubscribeEvents(id: destinationSubscription.id)

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
    expect((outputRuntimeStatus.totalOutputFramesFlushed ?? 0) >= 160,
           "intentional output flush was not accounted separately")
    expect(outputRuntimeStatus.totalOutputFramesDropped
            == (outputRuntimeStatus.totalOutputFramesLost ?? 0)
                &+ (outputRuntimeStatus.totalOutputFramesFlushed ?? 0),
           "legacy output discarded total no longer equals lost plus flushed")

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

    // Freeze delivery, fill admission capacity, and reject a newer packet.
    // Reflection controls the private queue without adding a production test API.
    let orderedPlane = RuntimeDataPlane(
        path: directory.appendingPathComponent("ordered-drops.sock").path, streamID: UUID())
    try orderedPlane.start()
    let orderedClient = try UnixSocketSystem.connect(path: orderedPlane.path)
    defer { orderedClient.close(); orderedPlane.stop() }
    try orderedClient.setReceiveTimeout(milliseconds: 1000)
    for _ in 0..<100 where orderedPlane.metrics().connectedClients != 1 { usleep(1_000) }
    expect(orderedPlane.metrics().connectedClients == 1, "ordered-drop subscriber did not attach")
    let deliveryQueue = Mirror(reflecting: orderedPlane).children
        .first { $0.label == "queue" }!.value as! DispatchQueue
    let orderedConnections = Mirror(reflecting: orderedPlane).children
        .first { $0.label == "clients" }!.value as! [UUID: UnixSocketConnection]
    let orderedFD = Mirror(reflecting: orderedConnections.values.first!).children
        .first { $0.label == "descriptor" }!.value as! Int32
    var sendBuffer: Int32 = 262_144
    expect(setsockopt(orderedFD, SOL_SOCKET, SO_SNDBUF, &sendBuffer,
                     socklen_t(MemoryLayout<Int32>.size)) == 0, "cannot size test socket buffer")
    let enteredDelivery = DispatchSemaphore(value: 0)
    let releaseDelivery = DispatchSemaphore(value: 0)
    deliveryQueue.async { enteredDelivery.signal(); releaseDelivery.wait() }
    expect(enteredDelivery.wait(timeout: .now() + 1) == .success, "delivery queue did not pause")
    let orderedFormat = RuntimePCMFormatDTO(sampleRate: 16_000, channelCount: 1)
    func offerOrdered(_ sequence: UInt64, upstreamDrops: UInt32 = 0) {
        orderedPlane.offer(RuntimeBackendAudioFrame(payload: Data(repeating: 0, count: 32),
            sequence: sequence, timestampNanoseconds: sequence * 1_000_000,
            frameCount: 16, format: orderedFormat, droppedFramesBefore: upstreamDrops))
    }
    for sequence in UInt64(0)..<64 { offerOrdered(sequence) }
    offerOrdered(64, upstreamDrops: 8)
    releaseDelivery.signal()
    deliveryQueue.sync {}
    var orderedDecoder = RuntimePCMStreamDecoder(expectedStreamID: orderedPlane.streamID)
    for sequence in UInt64(0)..<64 {
        let bytes = try orderedClient.readExactly(64)
        let header = try RuntimePCMFrameCodec.decodeHeader(bytes)
        let payload = try orderedClient.readExactly(Int(header.payloadByteCount))
        expect(header.sequence == sequence && !header.flags.contains(.discontinuity)
               && header.droppedFramesBefore == 0, "loss was attributed to an earlier queued packet")
        _ = try orderedDecoder.append(bytes + payload)
    }
    offerOrdered(65)
    deliveryQueue.sync {}
    let recoveredBytes = try orderedClient.readExactly(64)
    let recoveredHeader = try RuntimePCMFrameCodec.decodeHeader(recoveredBytes)
    let recoveredPayload = try orderedClient.readExactly(Int(recoveredHeader.payloadByteCount))
    expect(recoveredHeader.sequence == 65 && recoveredHeader.flags.contains(.discontinuity)
           && recoveredHeader.droppedFramesBefore == 24,
           "first accepted packet after loss must include local and upstream drops")
    _ = try orderedDecoder.append(recoveredBytes + recoveredPayload)

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
