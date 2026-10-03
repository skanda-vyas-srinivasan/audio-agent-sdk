import CoreAudio
import Foundation
#if canImport(SonexisAudioEngine)
import SonexisAudioEngine
#endif

enum AudioCaptureSessionState: String, Codable, Sendable {
    case starting
    case running
    case stopping
    case stopped
    case failed
}

enum AudioCaptureError: Error, CustomStringConvertible {
    case sourceUnavailable(String)
    case unsupportedSource(AudioSourceKind)
    case invalidTapFormat(String)
    case sessionNotFound(UUID)
    case sessionFailed(String)

    var description: String {
        switch self {
        case .sourceUnavailable(let id):
            return "Audio source is no longer available: \(id)"
        case .unsupportedSource(let kind):
            return "Capturing \(kind.rawValue) sources is not supported yet"
        case .invalidTapFormat(let description):
            return "The process tap returned an unsupported format: \(description)"
        case .sessionNotFound(let id):
            return "Capture session not found: \(id.uuidString)"
        case .sessionFailed(let message):
            return "Capture session failed: \(message)"
        }
    }
}

/// Owns one process tap, its lock-free handoff ring, and the off-realtime
/// normalization worker. All lifecycle mutation is serialized on `queue`.
final class AudioCaptureSession: @unchecked Sendable {
    typealias FrameHandler = @Sendable (AudioFrame) -> Void
    typealias StateHandler = @Sendable (AudioCaptureSessionState, Error?) -> Void
    typealias EnvironmentHandler = @Sendable () -> Void

    let id: UUID
    let source: AudioSource
    let outputFormat: RuntimePCMFormat

    private let queue: DispatchQueue
    private let deliveryQueue: DispatchQueue
    private let deliveryQueueKey = DispatchSpecificKey<UInt8>()
    private let deliveryCapacity = DispatchSemaphore(value: 32)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let target: AudioCaptureTarget
    private var tapEngine: TapCaptureEngine?
    private var ringBuffer: RealtimeRingBuffer?
    private var normalizer: RuntimeAudioNormalizer?
    private var drainTimer: DispatchSourceTimer?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var inputScratch: [Float] = []
    private var currentState: AudioCaptureSessionState = .starting
    private var terminalError: Error?
    private var frameHandler: FrameHandler?
    private var stateHandler: StateHandler?
    private var environmentHandler: EnvironmentHandler?
    private var onTermination: (@Sendable (UUID) -> Void)?
    private var sequence: UInt64 = 0
    private var normalizedFramesDelivered: UInt64 = 0
    private var normalizedFramesProduced: UInt64 = 0
    private var bytesDelivered: UInt64 = 0
    private var conversionBatches: UInt64 = 0
    private var conversionNanoseconds: UInt64 = 0
    private var completedNativeFrames: UInt64 = 0
    private var completedCaptureCallbacks: UInt64 = 0
    private var completedDroppedFrames: UInt64 = 0
    private var deliveryDroppedFrames: UInt64 = 0
    private var observedRingDroppedFrames: UInt64 = 0
    private var pendingDroppedOutputFrames: UInt64 = 0
    private var pendingDiscontinuity = false
    private var nativeSampleRate: Double = 0

    init(
        id: UUID = UUID(),
        source: AudioSource,
        outputFormat: RuntimePCMFormat = .pcm16Mono16kHz,
        frameHandler: FrameHandler?,
        onTermination: (@Sendable (UUID) -> Void)?
    ) throws {
        guard source.kind == .application else {
            throw AudioCaptureError.unsupportedSource(source.kind)
        }
        self.id = id
        self.source = source
        self.outputFormat = outputFormat
        self.target = try AudioCaptureTarget(source: source)
        self.frameHandler = frameHandler
        self.onTermination = onTermination
        self.queue = DispatchQueue(label: "Sonexis.RuntimeCapture.\(id.uuidString)", qos: .userInitiated)
        self.deliveryQueue = DispatchQueue(label: "Sonexis.RuntimeCaptureDelivery.\(id.uuidString)", qos: .userInitiated)
        queue.setSpecific(key: queueKey, value: 1)
        deliveryQueue.setSpecific(key: deliveryQueueKey, value: 1)
    }

    deinit {
        performSync {
            teardownPipeline()
            removeDefaultOutputListener()
        }
    }

    var state: AudioCaptureSessionState {
        performSync { currentState }
    }

    var failure: Error? {
        performSync { terminalError }
    }

    func onAudioFrame(_ handler: @escaping FrameHandler) {
        performAsync { [weak self] in self?.frameHandler = handler }
    }

    func onStateChange(_ handler: @escaping StateHandler) {
        performAsync { [weak self] in
            guard let self else { return }
            self.stateHandler = handler
            handler(self.currentState, self.terminalError)
        }
    }

    func onEnvironmentChange(_ handler: @escaping EnvironmentHandler) {
        performAsync { [weak self] in self?.environmentHandler = handler }
    }

    func metrics() -> CaptureMetrics {
        performSync {
            CaptureMetrics(
                captureCallbacks: completedCaptureCallbacks + (ringBuffer?.writeOperations ?? 0),
                nativeFramesReceived: completedNativeFrames + (ringBuffer?.writtenFrames ?? 0),
                normalizedFramesDelivered: normalizedFramesDelivered,
                bytesDelivered: bytesDelivered,
                ringDroppedFrames: completedDroppedFrames + (ringBuffer?.droppedFrames ?? 0),
                deliveryDroppedFrames: deliveryDroppedFrames,
                conversionBatches: conversionBatches,
                conversionNanoseconds: conversionNanoseconds,
                ringBacklogFrames: ringBuffer?.fillFrames ?? 0
            )
        }
    }

    /// Safe to call repeatedly and from a frame/state callback.
    func stop() {
        performSync {
            guard currentState != .stopped, currentState != .stopping, currentState != .failed else { return }
            transition(to: .stopping)
            teardownPipeline()
            removeDefaultOutputListener()
            transition(to: .stopped)
            frameHandler = nil
            stateHandler = nil
            environmentHandler = nil
            notifyTermination()
        }
        // An external stop does not return while a previously accepted consumer
        // callback is still running. Reentrant stop from that callback skips the
        // barrier; queued deliveries observe the cleared handler and are dropped.
        if DispatchQueue.getSpecific(key: deliveryQueueKey) == nil {
            deliveryQueue.sync {}
        }
    }

    func start() throws {
        try performThrowingSync {
            guard currentState == .starting else {
                throw AudioCaptureError.sessionFailed("start requested in state \(currentState.rawValue)")
            }
            do {
                try installDefaultOutputListener()
                try buildPipeline()
                transition(to: .running)
            } catch {
                teardownPipeline()
                removeDefaultOutputListener()
                terminalError = error
                transition(to: .failed, error: error)
                throw error
            }
        }
    }

    private func buildPipeline() throws {
        let selectedProcessIDs = try target.processObjectIDs(excluding: kAudioObjectUnknown)
        guard !selectedProcessIDs.isEmpty else {
            throw AudioCaptureError.sourceUnavailable(source.id)
        }

        let outputDeviceID = try CoreAudioSupport.defaultOutputDevice()
        let outputDevice = try CoreAudioSupport.deviceSummary(outputDeviceID)
        let ownProcessID = try CoreAudioSupport.processObjectID(forPID: getpid()) ?? kAudioObjectUnknown
        let tap = TapCaptureEngine(lifecycleQueue: queue)
        tap.processSelectionDidChange = { [weak self] in
            self?.rebuildForEnvironmentChange(notifyDeviceChange: false)
        }
        tapEngine = tap

        let configuration = try tap.prepare(
            sourceDevice: outputDevice,
            ownProcessObjectID: ownProcessID,
            captureTarget: target,
            muteBehavior: CATapMuteBehavior(rawValue: 0)!
        )
        let tapFormat = configuration.tapFormat
        let isFloat32 = tapFormat.mFormatID == kAudioFormatLinearPCM
            && (tapFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && tapFormat.mBitsPerChannel == 32
        guard isFloat32 else {
            throw AudioCaptureError.invalidTapFormat(tapFormat.formatSummary)
        }
        do {
            try RuntimeAudioNormalizer.validateInputFormat(
                sampleRate: tapFormat.mSampleRate,
                channels: tapFormat.mChannelsPerFrame)
        } catch {
            throw AudioCaptureError.invalidTapFormat(tapFormat.formatSummary)
        }

        let capacityFrames = max(UInt32(tapFormat.mSampleRate * 2.0), 4_096)
        let ring = try RealtimeRingBuffer(capacityFrames: capacityFrames,
            channels: tapFormat.mChannelsPerFrame, trackCaptureDrops: true)
        ring.setGainImmediate(1)
        ring.setReadEnabled(true)
        let normalizer = try RuntimeAudioNormalizer(
            sampleRate: tapFormat.mSampleRate,
            channels: tapFormat.mChannelsPerFrame,
            output: outputFormat
        )
        inputScratch = [Float](repeating: 0, count: 2_048 * Int(tapFormat.mChannelsPerFrame))
        ringBuffer = ring
        self.normalizer = normalizer
        nativeSampleRate = tapFormat.mSampleRate
        observedRingDroppedFrames = 0

        try tap.createIOProc(ringBuffer: ring)
        startDrainTimer()
        do {
            try tap.start()
        } catch {
            teardownPipeline()
            throw error
        }
    }

    private func startDrainTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in self?.drainAvailableAudio() }
        drainTimer = timer
        timer.resume()
    }

    private func drainAvailableAudio() {
        guard currentState == .running || currentState == .starting,
              let ringBuffer, let normalizer else { return }

        var batches = 0
        while batches < 32 {
            let framesToRead = min(ringBuffer.fillFrames, 2_048)
            guard framesToRead > 0 else { return }
            var nativeDrops: UInt64 = 0
            let framesRead = inputScratch.withUnsafeMutableBufferPointer { buffer -> UInt32 in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return ringBuffer.readCaptureInterleaved(baseAddress, frames: framesToRead,
                    droppedFramesBefore: &nativeDrops)
            }
            guard framesRead > 0 else { return }
            if nativeDrops > 0 {
                observedRingDroppedFrames &+= nativeDrops
                let outputDrops = UInt64((Double(nativeDrops) * Double(outputFormat.sampleRate)
                    / nativeSampleRate).rounded())
                pendingDroppedOutputFrames &+= outputDrops
                normalizedFramesProduced &+= outputDrops
                pendingDiscontinuity = true
                normalizer.resetAfterDiscontinuity()
            }

            let startedAt = DispatchTime.now().uptimeNanoseconds
            do {
                let pcm = try inputScratch.withUnsafeBufferPointer { buffer -> Data in
                    guard let baseAddress = buffer.baseAddress else { return Data() }
                    return try normalizer.convert(samples: baseAddress, frameCount: framesRead)
                }
                conversionNanoseconds &+= DispatchTime.now().uptimeNanoseconds - startedAt
                conversionBatches &+= 1
                guard !pcm.isEmpty else {
                    batches += 1
                    continue
                }

                let outputFrames = UInt32(pcm.count / outputFormat.bytesPerFrame)
                let frame = AudioFrame(
                    sequence: sequence,
                    timestampNanoseconds: CaptureClock.nanoseconds(
                        frames: normalizedFramesProduced, sampleRate: outputFormat.sampleRate),
                    frameCount: outputFrames,
                    format: outputFormat,
                    pcm: pcm,
                    discontinuity: pendingDiscontinuity,
                    droppedFramesBefore: UInt32(clamping: pendingDroppedOutputFrames)
                )
                sequence &+= 1
                normalizedFramesProduced &+= UInt64(outputFrames)
                if enqueueForDelivery(frame) {
                    normalizedFramesDelivered &+= UInt64(outputFrames)
                    bytesDelivered &+= UInt64(pcm.count)
                    pendingDroppedOutputFrames = 0
                    pendingDiscontinuity = false
                } else {
                    deliveryDroppedFrames &+= UInt64(outputFrames)
                    pendingDroppedOutputFrames &+= UInt64(outputFrames)
                    pendingDiscontinuity = true
                }
                guard currentState == .running || currentState == .starting else { return }
            } catch {
                fail(error)
                return
            }
            batches += 1
        }
    }

    private func rebuildForEnvironmentChange(notifyDeviceChange: Bool) {
        guard currentState == .running else { return }
        do {
            pendingDiscontinuity = true
            teardownPipeline()
            try buildPipeline()
            if notifyDeviceChange { environmentHandler?() }
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        guard currentState != .failed, currentState != .stopped else { return }
        terminalError = error
        teardownPipeline()
        removeDefaultOutputListener()
        transition(to: .failed, error: error)
        frameHandler = nil
        stateHandler = nil
        environmentHandler = nil
        notifyTermination()
    }

    private func teardownPipeline() {
        drainTimer?.setEventHandler {}
        drainTimer?.cancel()
        drainTimer = nil
        tapEngine?.teardown(log: false)
        tapEngine = nil
        normalizer = nil
        if let ringBuffer {
            let unreadNativeFrames = UInt64(ringBuffer.fillFrames)
            completedNativeFrames &+= ringBuffer.writtenFrames
            completedDroppedFrames &+= ringBuffer.droppedFrames &+ unreadNativeFrames
            completedCaptureCallbacks &+= ringBuffer.writeOperations
            let discardedNativeFrames = unreadNativeFrames
                &+ (ringBuffer.droppedFrames &- observedRingDroppedFrames)
            if discardedNativeFrames > 0, nativeSampleRate > 0 {
                let unreadOutputFrames = UInt64((Double(discardedNativeFrames)
                    * Double(outputFormat.sampleRate) / nativeSampleRate).rounded())
                pendingDroppedOutputFrames &+= unreadOutputFrames
                normalizedFramesProduced &+= unreadOutputFrames
                pendingDiscontinuity = true
            }
        }
        ringBuffer = nil
        inputScratch.removeAll(keepingCapacity: false)
    }

    private func installDefaultOutputListener() throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebuildForEnvironmentChange(notifyDeviceChange: true)
        }
        try checkOSStatus(
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                listener
            ),
            operation: "Install Runtime default-output listener"
        )
        defaultOutputListener = listener
    }

    private func removeDefaultOutputListener() {
        guard let listener = defaultOutputListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener
        )
        defaultOutputListener = nil
    }

    private func transition(to state: AudioCaptureSessionState, error: Error? = nil) {
        currentState = state
        stateHandler?(state, error)
    }

    private func enqueueForDelivery(_ frame: AudioFrame) -> Bool {
        guard deliveryCapacity.wait(timeout: .now()) == .success else { return false }
        deliveryQueue.async { [weak self] in
            defer { self?.deliveryCapacity.signal() }
            guard let self else { return }
            let handler = self.performSync { () -> FrameHandler? in
                guard self.currentState == .running || self.currentState == .starting else { return nil }
                return self.frameHandler
            }
            handler?(frame)
        }
        return true
    }

    private func notifyTermination() {
        let callback = onTermination
        onTermination = nil
        callback?(id)
    }

    private func performAsync(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    private func performSync<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return work() }
        return queue.sync(execute: work)
    }

    private func performThrowingSync<T>(_ work: () throws -> T) throws -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try work() }
        return try queue.sync(execute: work)
    }
}
