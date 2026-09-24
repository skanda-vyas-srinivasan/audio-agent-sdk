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

private func descriptorCount() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
}

private func peakRSS() -> Int64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int64(usage.ru_maxrss)
}

let directory = URL(fileURLWithPath: "/tmp/sx-stress-\(UUID().uuidString)", isDirectory: true)
let server = SonexisRuntimeServer(socketDirectory: directory, backend: SilentBackend())
let startingFDs = descriptorCount()
let startingRSS = peakRSS()
let started = DispatchTime.now().uptimeNanoseconds

do {
    try server.start()
    defer {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }
    let client = SonexisRuntimeClient(controlSocketPath: server.paths.controlSocketPath)
    try client.connect(clientName: "stress")

    for _ in 0..<1_000 {
        let session = try client.startCapture(sourceID: "app.stress")
        _ = try client.stopCapture(sessionID: session.id)
        _ = try client.stopCapture(sessionID: session.id)
    }

    for _ in 0..<200 {
        let transient = SonexisRuntimeClient(controlSocketPath: server.paths.controlSocketPath)
        try transient.connect(clientName: "churn")
        _ = try transient.listSources()
        transient.disconnect()
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
    expect(status.totalSessionsStarted >= 1_016, "session counter lost updates")
    client.disconnect()
    usleep(100_000)

    let fdGrowth = descriptorCount() - startingFDs
    expect(fdGrowth <= 8, "file descriptors grew by \(fdGrowth)")
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
    print("Runtime stress passed: cycles=1000 connections=200 parallel_sessions=16 elapsed_seconds=\(String(format: "%.3f", elapsed)) fd_growth=\(fdGrowth) peak_rss_bytes=\(peakRSS()) baseline_peak_rss_bytes=\(startingRSS)")
} catch {
    server.stop()
    try? FileManager.default.removeItem(at: directory)
    fatalError("Runtime stress failed: \(error)")
}
