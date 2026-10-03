import CoreAudio
import Foundation
#if canImport(SonexisAudioEngine)
import SonexisAudioEngine
#endif
import SonexisAudioEngineC

/// Captures one physical Core Audio input device into the existing Runtime
/// capture data plane. The HAL callback only copies Float32 samples into the
/// preallocated C ring; conversion and client delivery stay on `queue`.
final class RuntimeMicrophoneCaptureSession: RuntimeBackendCaptureSession,
    @unchecked Sendable {
    let outputFormat: RuntimePCMFormatDTO

    private let deviceID: AudioDeviceID
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let onFrame: @Sendable (RuntimeBackendAudioFrame) -> Void
    private let onDeviceChanged: @Sendable () -> Void
    private let onEnded: @Sendable (RuntimeErrorDTO?) -> Void
    private var ring: RealtimeRingBuffer?
    private var normalizer: RuntimeAudioNormalizer?
    private var scratch: [Float] = []
    private var ioProcID: AudioDeviceIOProcID?
    private var callbackRingRetain: UnsafeMutableRawPointer?
    private var drainTimer: DispatchSourceTimer?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var listenerRegistrations: [(AudioObjectID, AudioObjectPropertyAddress)] = []
    private var running = false
    private var ended = false
    private var sequence: UInt64 = 0
    private var normalizedFramesProduced: UInt64 = 0
    private var normalizedFramesDelivered: UInt64 = 0
    private var conversionBatches: UInt64 = 0
    private var conversionNanoseconds: UInt64 = 0
    private var pendingDroppedOutputFrames: UInt64 = 0
    private var pendingDiscontinuity = false
    private var nativeSampleRate: Double = 0
    private var completedCallbacks: UInt64 = 0
    private var completedNativeFrames: UInt64 = 0
    private var completedDrops: UInt64 = 0

    init(deviceID: AudioDeviceID, outputFormat: RuntimePCMFormatDTO,
         onFrame: @escaping @Sendable (RuntimeBackendAudioFrame) -> Void,
         onDeviceChanged: @escaping @Sendable () -> Void,
         onEnded: @escaping @Sendable (RuntimeErrorDTO?) -> Void) {
        self.deviceID = deviceID
        self.outputFormat = outputFormat
        self.onFrame = onFrame
        self.onDeviceChanged = onDeviceChanged
        self.onEnded = onEnded
        queue = DispatchQueue(label: "com.audioplane.runtime.microphone-capture",
                              qos: .userInitiated)
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit { performSync { teardown() } }

    func start() throws {
        try performThrowingSync {
            guard !running, !ended else {
                throw RuntimeErrorDTO(code: "microphone_capture_state",
                    message: "Microphone capture cannot be started in its current state")
            }
            do {
                try buildPipeline()
                running = true
            } catch {
                teardown()
                ended = true
                throw error
            }
        }
    }

    func stop() {
        performSync {
            guard !ended else { return }
            running = false
            teardown()
            ended = true
            onEnded(nil)
        }
    }

    func metrics() -> RuntimeCaptureMetricsDTO {
        performSync {
            RuntimeCaptureMetricsDTO(
                captureCallbacks: completedCallbacks + (ring?.writeOperations ?? 0),
                nativeFramesReceived: completedNativeFrames + (ring?.writtenFrames ?? 0),
                normalizedFramesDelivered: normalizedFramesDelivered,
                ringDroppedFrames: completedDrops + (ring?.droppedFrames ?? 0),
                deliveryDroppedFrames: 0,
                conversionBatches: conversionBatches,
                conversionNanoseconds: conversionNanoseconds,
                ringBacklogFrames: ring?.fillFrames ?? 0)
        }
    }

    private func buildPipeline() throws {
        let streams = try CoreAudioSupport.inputStreamIDs(deviceID)
        guard streams.count == 1, let streamID = streams.first else {
            throw RuntimeErrorDTO(code: "unsupported_microphone_device",
                message: "Microphone devices must expose one compatible input stream",
                retryable: true)
        }
        let format = try CoreAudioSupport.streamVirtualFormat(streamID)
        let channels = format.mChannelsPerFrame
        let expectedBytesPerFrame: UInt32 = format.isNonInterleaved ? 4 : 4 * channels
        guard format.isFloat32LinearPCM,
              format.mSampleRate.isFinite,
              RuntimeAudioNormalizer.supportedInputSampleRates.contains(format.mSampleRate),
              RuntimeAudioNormalizer.supportedInputChannels.contains(channels),
              format.mFramesPerPacket == 1,
              format.mBytesPerFrame == expectedBytesPerFrame,
              format.mBytesPerPacket == expectedBytesPerFrame else {
            throw RuntimeErrorDTO(code: "unsupported_microphone_format",
                message: "Microphone input format must be packed Float32 PCM",
                retryable: true)
        }

        let coreOutput = RuntimePCMFormat(sampleRate: outputFormat.sampleRate,
            channelCount: outputFormat.channelCount,
            sampleFormat: outputFormat.sampleFormat == .pcmS16LE ? .pcmS16LE : .float32LE)
        let nextRing = try RealtimeRingBuffer(
            capacityFrames: max(UInt32(format.mSampleRate * 2), 4_096),
            channels: channels, trackCaptureDrops: true)
        nextRing.setReadEnabled(true)
        nextRing.setGainImmediate(1)
        let nextNormalizer = try RuntimeAudioNormalizer(
            sampleRate: format.mSampleRate, channels: channels, output: coreOutput)
        let nextScratch = [Float](repeating: 0, count: 2_048 * Int(channels))
        guard let ringPointer = nextRing.realtimePointer else {
            throw RuntimeErrorDTO(code: "microphone_buffer_unavailable",
                message: "Microphone capture buffer is unavailable")
        }

        let retained = Unmanaged.passRetained(nextRing).toOpaque()
        var nextIOProc: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(
            deviceID, SonexisAudioRingBufferInputIOProc,
            UnsafeMutableRawPointer(ringPointer), &nextIOProc)
        guard createStatus == noErr, let nextIOProc else {
            Unmanaged<RealtimeRingBuffer>.fromOpaque(retained).release()
            throw CoreAudioError(operation: "Create microphone input IOProc", status: createStatus)
        }

        ring = nextRing
        normalizer = nextNormalizer
        scratch = nextScratch
        ioProcID = nextIOProc
        callbackRingRetain = retained
        nativeSampleRate = format.mSampleRate
        try installDeviceListeners(streamID: streamID)
        startDrainTimer()
        let startStatus = AudioDeviceStart(deviceID, nextIOProc)
        guard startStatus == noErr else {
            teardown()
            throw CoreAudioError(operation: "Start microphone input IOProc", status: startStatus)
        }
    }

    private func startDrainTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(2),
                       leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in self?.drainAvailableAudio() }
        drainTimer = timer
        timer.resume()
    }

    private func drainAvailableAudio() {
        guard running, let ring, let normalizer else { return }
        var batches = 0
        while batches < 32 {
            let available = ring.fillFrames
            let minimumPacketFrames = max(1,
                UInt32((nativeSampleRate / 1_000).rounded(.up)))
            guard available >= minimumPacketFrames else { return }
            let framesToRead = min(available, 2_048)
            var nativeDrops: UInt64 = 0
            let framesRead = scratch.withUnsafeMutableBufferPointer { buffer -> UInt32 in
                guard let base = buffer.baseAddress else { return 0 }
                return ring.readCaptureInterleaved(base, frames: framesToRead,
                    droppedFramesBefore: &nativeDrops)
            }
            guard framesRead > 0 else { return }
            if nativeDrops > 0 {
                let outputDrops = UInt64((Double(nativeDrops) * Double(outputFormat.sampleRate)
                    / nativeSampleRate).rounded())
                pendingDroppedOutputFrames &+= outputDrops
                normalizedFramesProduced &+= outputDrops
                pendingDiscontinuity = true
                normalizer.resetAfterDiscontinuity()
            }
            let started = DispatchTime.now().uptimeNanoseconds
            do {
                let pcm = try scratch.withUnsafeBufferPointer { buffer -> Data in
                    guard let base = buffer.baseAddress else { return Data() }
                    return try normalizer.convert(samples: base, frameCount: framesRead)
                }
                conversionNanoseconds &+= DispatchTime.now().uptimeNanoseconds - started
                conversionBatches &+= 1
                guard !pcm.isEmpty else { batches += 1; continue }
                let frameCount = UInt32(pcm.count / outputFormat.bytesPerFrame)
                onFrame(RuntimeBackendAudioFrame(payload: pcm, sequence: sequence,
                    timestampNanoseconds: CaptureClock.nanoseconds(
                        frames: normalizedFramesProduced, sampleRate: outputFormat.sampleRate),
                    frameCount: frameCount, format: outputFormat,
                    discontinuity: pendingDiscontinuity,
                    droppedFramesBefore: UInt32(clamping: pendingDroppedOutputFrames)))
                sequence &+= 1
                normalizedFramesProduced &+= UInt64(frameCount)
                normalizedFramesDelivered &+= UInt64(frameCount)
                pendingDroppedOutputFrames = 0
                pendingDiscontinuity = false
            } catch {
                fail(RuntimeErrorDTO(code: "microphone_conversion_failed",
                    message: String(describing: error), retryable: true))
                return
            }
            batches += 1
        }
    }

    private func installDeviceListeners(streamID: AudioObjectID) throws {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.deviceDidChange()
        }
        deviceListener = listener
        let addresses = [
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain),
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain),
        ]
        for stored in addresses {
            var address = stored
            try checkOSStatus(AudioObjectAddPropertyListenerBlock(
                deviceID, &address, queue, listener),
                operation: "Install microphone device listener")
            listenerRegistrations.append((deviceID, stored))
        }
        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        try checkOSStatus(AudioObjectAddPropertyListenerBlock(
            streamID, &streamAddress, queue, listener),
            operation: "Install microphone format listener")
        listenerRegistrations.append((streamID, streamAddress))
    }

    private func removeDeviceListeners() {
        guard let listener = deviceListener else {
            listenerRegistrations.removeAll()
            return
        }
        for (objectID, stored) in listenerRegistrations {
            var address = stored
            _ = AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, listener)
        }
        listenerRegistrations.removeAll()
        deviceListener = nil
    }

    private func deviceDidChange() {
        guard running else { return }
        onDeviceChanged()
        fail(RuntimeErrorDTO(code: "microphone_device_changed",
            message: "Microphone device or format changed; start a fresh capture",
            retryable: true))
    }

    private func fail(_ error: RuntimeErrorDTO) {
        guard !ended else { return }
        running = false
        teardown()
        ended = true
        onEnded(error)
    }

    private func teardown() {
        drainTimer?.setEventHandler {}
        drainTimer?.cancel()
        drainTimer = nil
        removeDeviceListeners()
        if let ring {
            completedCallbacks &+= ring.writeOperations
            completedNativeFrames &+= ring.writtenFrames
            completedDrops &+= ring.droppedFrames &+ UInt64(ring.fillFrames)
        }
        if let ioProcID {
            _ = AudioDeviceStop(deviceID, ioProcID)
            let destroyed = AudioDeviceDestroyIOProcID(deviceID, ioProcID) == noErr
            if destroyed, let callbackRingRetain {
                Unmanaged<RealtimeRingBuffer>.fromOpaque(callbackRingRetain).release()
                self.callbackRingRetain = nil
            }
            // If destruction fails, preserve the retained wrapper forever;
            // a late HAL callback is safer than reclaiming its ring storage.
            if destroyed { self.ioProcID = nil }
        }
        ring = nil
        normalizer = nil
        scratch.removeAll(keepingCapacity: false)
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
