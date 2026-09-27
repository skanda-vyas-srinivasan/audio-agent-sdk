import Darwin
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

private final class SilentSession: RuntimeBackendCaptureSession, @unchecked Sendable {
    let outputFormat: RuntimePCMFormatDTO
    private let lock = NSLock()
    private var ended = false
    private let onEnded: @Sendable (RuntimeErrorDTO?) -> Void
    init(format: RuntimePCMFormatDTO, onEnded: @escaping @Sendable (RuntimeErrorDTO?) -> Void) {
        outputFormat = format
        self.onEnded = onEnded
    }
    func stop() {
        lock.lock()
        guard !ended else { lock.unlock(); return }
        ended = true
        lock.unlock()
        onEnded(nil)
    }
}

private final class SilentBackend: RuntimeCaptureBackend, @unchecked Sendable {
    func availableSources() throws -> [RuntimeSourceDTO] {
        [RuntimeSourceDTO(id: "app.stress", processID: 1, bundleIdentifier: "stress",
            name: "Stress", isActive: true)]
    }
    func startCapture(sourceID: String, format: RuntimePCMFormatDTO,
        onFrame: @escaping @Sendable (RuntimeBackendAudioFrame) -> Void,
        onDeviceChanged: @escaping @Sendable () -> Void,
        onEnded: @escaping @Sendable (RuntimeErrorDTO?) -> Void) throws -> RuntimeBackendCaptureSession {
        guard sourceID == "app.stress" else {
            throw RuntimeErrorDTO(code: "source_not_found", message: "missing")
        }
        return SilentSession(format: format, onEnded: onEnded)
    }
}

private final class SilentOutputSession: RuntimeBackendOutputSession, @unchecked Sendable {
    let inputFormat: RuntimePCMFormatDTO
    let destination = RuntimeOutputDestinationDTO(id: "default", kind: .playback,
        name: "Stress Output", isAvailable: true, isDefault: true)
    init(format: RuntimePCMFormatDTO) { inputFormat = format }
    func write(_ frame: RuntimePCMFrame) throws {}
    func finish() {}
    func flush() throws {}
    func stop() {}
    func metrics() -> RuntimeOutputMetricsDTO { .init() }
}

private final class SilentOutputBackend: RuntimeOutputBackend, @unchecked Sendable {
    func availableOutputDestinations() throws -> [RuntimeOutputDestinationDTO] {
        [RuntimeOutputDestinationDTO(id: "default", kind: .playback,
            name: "Stress Output", isAvailable: true, isDefault: true)]
    }
    func startOutput(destinationID: String, format: RuntimePCMFormatDTO,
                     targetBufferMilliseconds: UInt32,
                     onEvent: @escaping @Sendable (RuntimeOutputBackendEvent) -> Void,
                     onEnded: @escaping @Sendable (RuntimeErrorDTO?) -> Void)
        throws -> RuntimeBackendOutputSession {
        SilentOutputSession(format: format)
    }
}

private func descriptorCount() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
}

private func peakRSS() -> Int64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int64(usage.ru_maxrss)
}

private func currentRSS() -> UInt64 {
    var task = proc_taskinfo()
    let size = MemoryLayout<proc_taskinfo>.size
    let result = withUnsafeMutablePointer(to: &task) {
        proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, $0, Int32(size))
    }
    return result == Int32(size) ? task.pti_resident_size : 0
}

private func configuredCount(_ name: String, default fallback: Int,
                             maximum: Int = 1_000_000) -> Int {
    guard let raw = ProcessInfo.processInfo.environment[name],
          let value = Int(raw), value >= 0, value <= maximum else { return fallback }
    return value
}

let captureCycles = configuredCount("SONEXIS_STRESS_CAPTURE_CYCLES", default: 1_000)
let outputCycles = configuredCount("SONEXIS_STRESS_OUTPUT_CYCLES", default: 1_000)
let connectionCycles = configuredCount("SONEXIS_STRESS_CONNECTION_CYCLES", default: 200)
let pcmBurstCycles = configuredCount("SONEXIS_STRESS_PCM_BURST_CYCLES", default: 100)

let directory = URL(fileURLWithPath: "/tmp/sx-stress-\(UUID().uuidString)", isDirectory: true)
let server = SonexisRuntimeServer(socketDirectory: directory, backend: SilentBackend(),
    outputBackend: SilentOutputBackend())
let startingFDs = descriptorCount()
let startingRSS = peakRSS()
let startingCurrentRSS = currentRSS()
let started = DispatchTime.now().uptimeNanoseconds

do {
    try server.start()
    defer {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }
    let client = SonexisRuntimeClient(controlSocketPath: server.paths.controlSocketPath)
    try client.connect(clientName: "stress")

    for _ in 0..<captureCycles {
        let session = try client.startCapture(sourceID: "app.stress")
        _ = try client.stopCapture(sessionID: session.id)
        _ = try client.stopCapture(sessionID: session.id)
    }

    for _ in 0..<outputCycles {
        let output = try client.startOutput()
        _ = try client.stopOutput(outputSessionID: output.id)
        _ = try client.stopOutput(outputSessionID: output.id)
    }

    for _ in 0..<connectionCycles {
        let transient = SonexisRuntimeClient(controlSocketPath: server.paths.controlSocketPath)
        try transient.connect(clientName: "churn")
        _ = try transient.listSources()
        transient.disconnect()
    }

    for index in 0..<pcmBurstCycles {
        let output = try client.startOutput()
        let writer = try client.outputWriter(session: output)
        for packet in 0..<(1 + index % 8) {
            try writer.write(Data(repeating: UInt8(truncatingIfNeeded: packet), count: 320),
                discontinuity: packet == 0 && index % 7 == 0)
        }
        writer.cancel()
        _ = try client.stopOutput(outputSessionID: output.id)
    }

    let group = DispatchGroup()
    let errorLock = NSLock()
    var parallelErrors: [Error] = []
    for index in 0..<4 {
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                let parallel = SonexisRuntimeClient(controlSocketPath: server.paths.controlSocketPath)
                try parallel.connect(clientName: "parallel-\(index)")
                var sessions: [RuntimeSessionDTO] = []
                for _ in 0..<4 { sessions.append(try parallel.startCapture(sourceID: "app.stress")) }
                usleep(20_000)
                for session in sessions { _ = try parallel.stopCapture(sessionID: session.id) }
                parallel.disconnect()
            } catch {
                errorLock.lock(); parallelErrors.append(error); errorLock.unlock()
            }
        }
    }
    group.wait()
    expect(parallelErrors.isEmpty, "parallel session stress failed: \(parallelErrors)")

    let status = try client.runtimeStatus()
    expect(status.activeSessions == 0, "stress left active sessions")
    expect(status.totalSessionsStarted >= UInt64(captureCycles + 16),
           "session counter lost updates")
    expect((status.totalOutputSessionsStarted ?? 0) >= UInt64(outputCycles + pcmBurstCycles),
           "output session counter lost updates")
    expect((status.totalControlClientsAccepted ?? 0) >= UInt64(connectionCycles + 5),
           "control connection accounting lost updates")
    expect((status.connectedCaptureSubscribers ?? 0) == 0
            && (status.connectedOutputProducers ?? 0) == 0,
           "stress left data-plane clients attached")
    client.disconnect()
    usleep(100_000)

    let fdGrowth = descriptorCount() - startingFDs
    expect(fdGrowth <= 8, "file descriptors grew by \(fdGrowth)")
    let retainedRSSGrowth = currentRSS() > startingCurrentRSS
        ? currentRSS() - startingCurrentRSS : 0
    expect(retainedRSSGrowth <= 64 * 1_024 * 1_024,
           "current resident memory grew by \(retainedRSSGrowth) bytes")
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
    print("Runtime stress passed: capture_cycles=\(captureCycles) output_cycles=\(outputCycles) pcm_burst_cycles=\(pcmBurstCycles) connections=\(connectionCycles) parallel_sessions=16 elapsed_seconds=\(String(format: "%.3f", elapsed)) fd_growth=\(fdGrowth) current_rss_bytes=\(currentRSS()) baseline_current_rss_bytes=\(startingCurrentRSS) retained_rss_growth_bytes=\(retainedRSSGrowth) peak_rss_bytes=\(peakRSS()) baseline_peak_rss_bytes=\(startingRSS)")
} catch {
    server.stop()
    try? FileManager.default.removeItem(at: directory)
    fatalError("Runtime stress failed: \(error)")
}
