import Darwin
import Foundation

private final class RuntimeCaptureSessionAdapter: RuntimeBackendCaptureSession, @unchecked Sendable {
    let session: AudioCaptureSession
    let outputFormat: RuntimePCMFormatDTO

    init(session: AudioCaptureSession, outputFormat: RuntimePCMFormatDTO) {
        self.session = session
        self.outputFormat = outputFormat
    }

    func stop() {
        session.stop()
    }

    func metrics() -> RuntimeCaptureMetricsDTO {
        let value = session.metrics()
        return RuntimeCaptureMetricsDTO(captureCallbacks: value.captureCallbacks,
            nativeFramesReceived: value.nativeFramesReceived,
            normalizedFramesDelivered: value.normalizedFramesDelivered,
            ringDroppedFrames: value.ringDroppedFrames,
            deliveryDroppedFrames: value.deliveryDroppedFrames,
            conversionBatches: value.conversionBatches,
            conversionNanoseconds: value.conversionNanoseconds,
            ringBacklogFrames: value.ringBacklogFrames)
    }
}

private final class SonexisCaptureBackend: RuntimeCaptureBackend, @unchecked Sendable {
    private let registry = AudioSourceRegistry()
    private let manager = AudioCaptureManager()

    func availableSources() throws -> [RuntimeSourceDTO] {
        try registry.availableSources().map { source in
            RuntimeSourceDTO(
                id: source.id,
                kind: .application,
                processID: source.processIdentifiers.first,
                processIDs: source.processIdentifiers,
                bundleIdentifier: source.bundleIdentifier,
                name: source.name,
                isActive: source.state == .active,
                isProducingAudio: source.isProducingAudio,
                // The registry's format is the prospective default-output format,
                // not an application-native fact. The capture session's negotiated
                // output format is authoritative, so do not mislabel this source.
                nativeFormat: nil
            )
        }
    }

    func startCapture(
        sourceID: String,
        format: RuntimePCMFormatDTO,
        onFrame: @escaping @Sendable (RuntimeBackendAudioFrame) -> Void,
        onDeviceChanged: @escaping @Sendable () -> Void,
        onEnded: @escaping @Sendable (RuntimeErrorDTO?) -> Void
    ) throws -> RuntimeBackendCaptureSession {
        let source: AudioSource
        do {
            source = try registry.source(id: sourceID)
        } catch {
            throw RuntimeErrorDTO(code: "source_unavailable", message: "Audio source is not active: \(sourceID)")
        }
        guard source.state == .active else {
            throw RuntimeErrorDTO(code: "source_unavailable", message: "Audio source is not active: \(sourceID)")
        }
        let session: AudioCaptureSession
        do {
            let coreFormat = RuntimePCMFormat(sampleRate: format.sampleRate,
                channelCount: format.channelCount,
                sampleFormat: format.sampleFormat == .pcmS16LE ? .pcmS16LE : .float32LE)
            session = try manager.startCapture(source: source, outputFormat: coreFormat) { frame in
                onFrame(RuntimeBackendAudioFrame(
                    payload: frame.pcm,
                    sequence: frame.sequence,
                    timestampNanoseconds: frame.timestampNanoseconds,
                    frameCount: frame.frameCount,
                    format: format,
                    discontinuity: frame.discontinuity,
                    droppedFramesBefore: frame.droppedFramesBefore
                ))
            }
        } catch AudioCaptureError.sourceUnavailable {
            throw RuntimeErrorDTO(code: "source_unavailable", message: "Audio source disappeared before capture began")
        } catch {
            throw RuntimeErrorDTO(
                code: "capture_initialization_failed",
                message: String(describing: error)
            )
        }
        session.onStateChange { state, error in
            switch state {
            case .stopped:
                onEnded(nil)
            case .failed:
                onEnded(RuntimeErrorDTO(
                    code: "capture_failed",
                    message: error.map(String.init(describing:)) ?? "Capture failed"
                ))
            default:
                break
            }
        }
        session.onEnvironmentChange(onDeviceChanged)
        return RuntimeCaptureSessionAdapter(session: session, outputFormat: format)
    }
}

private func socketDirectory(arguments: [String]) throws -> URL {
    if let index = arguments.firstIndex(of: "--socket-dir") {
        guard arguments.indices.contains(index + 1) else {
            throw RuntimeErrorDTO(code: "invalid_argument", message: "--socket-dir requires a path")
        }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }
    if let configured = ProcessInfo.processInfo.environment["SONEXIS_RUNTIME_DIR"], !configured.isEmpty {
        return URL(fileURLWithPath: configured, isDirectory: true)
    }
    return RuntimeSocketPaths.userDefault.directory
}

do {
    let directory = try socketDirectory(arguments: CommandLine.arguments)
    let server = SonexisRuntimeServer(socketDirectory: directory,
        backend: SonexisCaptureBackend(), outputBackend: RuntimeHALPlaybackBackend())
    try server.start()
    print("Sonexis Runtime listening at \(server.paths.controlSocketPath)")

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let shutdown = {
        server.stop()
        exit(EXIT_SUCCESS)
    }
    interrupt.setEventHandler(handler: shutdown)
    terminate.setEventHandler(handler: shutdown)
    interrupt.resume()
    terminate.resume()
    dispatchMain()
} catch {
    fputs("sonexis-runtime: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
