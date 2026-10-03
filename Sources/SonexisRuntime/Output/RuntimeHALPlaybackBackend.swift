import AVFoundation
import CoreAudio
import Foundation
#if canImport(SonexisAudioEngine)
import SonexisAudioEngine
#endif
import SonexisAudioEngineC

final class RuntimePlaybackConverter {
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let inputBuffer: AVAudioPCMBuffer
    private let outputBuffer: AVAudioPCMBuffer
    private let maximumInputFrames: AVAudioFrameCount
    private let directSamples: UnsafeMutablePointer<Float>
    private let drainSamples: UnsafeMutablePointer<Float>
    private let drainCapacityFrames: AVAudioFrameCount
    private let directConversion: Bool
    private var inputFramesReceived: UInt64 = 0
    private var outputFramesProduced: UInt64 = 0

    init(input: RuntimePCMFormatDTO, deviceSampleRate: Double,
         deviceChannels: UInt32, maximumPacketMilliseconds: UInt32 = 200) throws {
        let common: AVAudioCommonFormat = input.sampleFormat == .pcmS16LE
            ? .pcmFormatInt16 : .pcmFormatFloat32
        guard let inputFormat = AVAudioFormat(commonFormat: common,
            sampleRate: Double(input.sampleRate),
            channels: AVAudioChannelCount(input.channelCount), interleaved: true),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: deviceSampleRate, channels: AVAudioChannelCount(deviceChannels),
            interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw RuntimeErrorDTO(code: "output_converter_unavailable",
                message: "Could not create the playback format converter")
        }
        converter.primeMethod = .none
        let maximumInputFrames = AVAudioFrameCount(
            UInt64(input.sampleRate) * UInt64(maximumPacketMilliseconds) / 1_000)
        let ratio = deviceSampleRate / Double(input.sampleRate)
        let outputCapacity = AVAudioFrameCount(ceil(Double(maximumInputFrames) * ratio)) + 64
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                  frameCapacity: maximumInputFrames),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat,
                  frameCapacity: outputCapacity) else {
            throw RuntimeErrorDTO(code: "output_buffer_allocation_failed",
                message: "Could not allocate playback conversion buffers")
        }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
        self.inputBuffer = inputBuffer
        self.outputBuffer = outputBuffer
        self.maximumInputFrames = maximumInputFrames
        directConversion = abs(deviceSampleRate - Double(input.sampleRate)) < 0.5
            && deviceChannels <= 2
        directSamples = .allocate(capacity: Int(maximumInputFrames) * Int(deviceChannels))
        drainCapacityFrames = outputCapacity
        drainSamples = .allocate(capacity: Int(outputCapacity) * Int(deviceChannels))
    }

    deinit {
        directSamples.deallocate()
        drainSamples.deallocate()
    }

    func convert(_ frame: RuntimePCMFrame) throws -> (UnsafePointer<Float>, UInt32) {
        guard frame.header.frameCount <= maximumInputFrames else {
            throw RuntimeErrorDTO(code: "output_packet_too_long",
                message: "Output packet exceeded the prepared converter capacity")
        }
        if directConversion {
            convertDirect(frame)
            return (UnsafePointer(directSamples), frame.header.frameCount)
        }
        inputBuffer.frameLength = AVAudioFrameCount(frame.header.frameCount)
        guard let inputData = inputBuffer.mutableAudioBufferList.pointee.mBuffers.mData else {
            throw RuntimeErrorDTO(code: "output_conversion_failed",
                message: "Playback input buffer is unavailable")
        }
        frame.payload.withUnsafeBytes { bytes in
            if frame.header.sampleFormat == .float32LE {
                let output = inputData.assumingMemoryBound(to: Float.self)
                let sampleCount = Int(frame.header.frameCount)
                    * Int(frame.header.channelCount)
                for index in 0..<sampleCount {
                    let bits = bytes.loadUnaligned(
                        fromByteOffset: index * 4, as: UInt32.self)
                    output[index] = sanitizedSample(
                        Float(bitPattern: UInt32(littleEndian: bits)))
                }
            } else if let base = bytes.baseAddress {
                inputData.copyMemory(from: base, byteCount: bytes.count)
            }
        }
        outputBuffer.frameLength = 0
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return self.inputBuffer
        }
        guard status != .error, conversionError == nil,
              let outputData = outputBuffer.audioBufferList.pointee.mBuffers.mData else {
            throw RuntimeErrorDTO(code: "output_conversion_failed",
                message: conversionError?.localizedDescription ?? "AVAudioConverter failed")
        }
        inputFramesReceived &+= UInt64(frame.header.frameCount)
        outputFramesProduced &+= UInt64(outputBuffer.frameLength)
        return (UnsafePointer(outputData.assumingMemoryBound(to: Float.self)),
                UInt32(outputBuffer.frameLength))
    }

    func reset() {
        converter.reset()
        inputFramesReceived = 0
        outputFramesProduced = 0
    }

    func drain() throws -> (UnsafePointer<Float>, UInt32) {
        guard !directConversion else { return (UnsafePointer(directSamples), 0) }
        let expected = UInt64((Double(inputFramesReceived)
            * outputFormat.sampleRate / inputFormat.sampleRate).rounded())
        var remaining = expected > outputFramesProduced ? expected - outputFramesProduced : 0
        var collected: UInt32 = 0
        var attempts = 0
        while remaining > 0, attempts < 8 {
            attempts += 1
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) {
                _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard status != .error, conversionError == nil,
                  let outputData = outputBuffer.audioBufferList.pointee.mBuffers.mData else {
                throw RuntimeErrorDTO(code: "output_conversion_failed",
                    message: conversionError?.localizedDescription
                        ?? "AVAudioConverter failed while draining")
            }
            let available = UInt32(min(UInt64(outputBuffer.frameLength), remaining))
            guard available > 0 else { break }
            guard UInt64(collected) + UInt64(available) <= UInt64(drainCapacityFrames) else {
                throw RuntimeErrorDTO(code: "output_conversion_failed",
                    message: "Playback converter tail exceeded its prepared capacity")
            }
            let channels = Int(outputFormat.channelCount)
            drainSamples.advanced(by: Int(collected) * channels).update(
                from: outputData.assumingMemoryBound(to: Float.self),
                count: Int(available) * channels)
            collected &+= available
            remaining -= UInt64(available)
            if status == .endOfStream { break }
        }
        outputFramesProduced &+= UInt64(collected)
        return (UnsafePointer(drainSamples), collected)
    }

    private func convertDirect(_ frame: RuntimePCMFrame) {
        let inputChannels = Int(frame.header.channelCount)
        let outputChannels = Int(outputFormat.channelCount)
        frame.payload.withUnsafeBytes { bytes in
            for frameIndex in 0..<Int(frame.header.frameCount) {
                let inputBase = frameIndex * inputChannels
                let left = sample(bytes, index: inputBase, format: frame.header.sampleFormat)
                let right = inputChannels > 1
                    ? sample(bytes, index: inputBase + 1, format: frame.header.sampleFormat)
                    : left
                let outputBase = frameIndex * outputChannels
                if outputChannels == 1 {
                    directSamples[outputBase] = inputChannels == 1 ? left : (left + right) * 0.5
                } else {
                    directSamples[outputBase] = left
                    directSamples[outputBase + 1] = right
                }
            }
        }
    }

    private func sample(_ bytes: UnsafeRawBufferPointer, index: Int,
                        format: RuntimeSampleFormatDTO) -> Float {
        switch format {
        case .pcmS16LE:
            let value = bytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)
            return Float(Int16(littleEndian: value)) / 32_768
        case .float32LE:
            let bits = bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
            return sanitizedSample(Float(bitPattern: UInt32(littleEndian: bits)))
        }
    }

    private func sanitizedSample(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(1, max(-1, value))
    }
}

// Worker-side startup/re-prime policy. The HAL callback only sees readEnabled.
struct RuntimePlaybackPriming {
    private var pendingSince: UInt64?

    mutating func shouldStart(fill: UInt32, target: UInt32, sampleRate: Double,
                              now: UInt64) -> Bool {
        guard fill > 0 else { pendingSince = nil; return false }
        if pendingSince == nil { pendingSince = now }
        let wait = UInt64(Double(target) * 1_000_000_000 / sampleRate)
        if fill >= target || now - pendingSince! >= wait {
            pendingSince = nil
            return true
        }
        return false
    }

    mutating func reset() { pendingSince = nil }
}

public final class RuntimeHALPlaybackBackend: RuntimeOutputBackend, @unchecked Sendable {
    public init() {}

    public func availableOutputDestinations() throws -> [RuntimeOutputDestinationDTO] {
        var destinations: [RuntimeOutputDestinationDTO] = []
        if let defaultID = try? CoreAudioSupport.defaultOutputDevice(),
           let value = try? destination(deviceID: defaultID, id: "default",
                name: "Default macOS Output", isDefault: true,
                followsSystemDefault: true) {
            destinations.append(value)
        } else {
            destinations.append(RuntimeOutputDestinationDTO(id: "default", kind: .playback,
                name: "Default macOS Output", isAvailable: false, isDefault: true,
                followsSystemDefault: true))
        }
        let devices = try CoreAudioSupport.audioDeviceIDs()
        for deviceID in devices {
            guard let summary = try? CoreAudioSupport.deviceSummary(deviceID),
                  let value = try? destination(deviceID: deviceID,
                    id: "coreaudio:\(summary.uid)", name: summary.name,
                    isDefault: false, followsSystemDefault: false) else { continue }
            destinations.append(value)
        }
        let defaultDestination = destinations.removeFirst()
        return [defaultDestination] + destinations.sorted { $0.id < $1.id }
    }

    public func startOutput(destinationID: String, format: RuntimePCMFormatDTO,
                            targetBufferMilliseconds: UInt32,
                            onEvent: @escaping @Sendable (RuntimeOutputBackendEvent) -> Void,
                            onEnded: @escaping @Sendable (RuntimeErrorDTO?) -> Void)
        throws -> RuntimeBackendOutputSession {
        return try RuntimeHALPlaybackSession(inputFormat: format,
            destinationID: destinationID,
            targetBufferMilliseconds: targetBufferMilliseconds,
            onEvent: onEvent, onEnded: onEnded)
    }

    private func destination(deviceID: AudioDeviceID, id: String, name: String,
                             isDefault: Bool, followsSystemDefault: Bool) throws
        -> RuntimeOutputDestinationDTO? {
        let streams = try CoreAudioSupport.outputStreamIDs(deviceID)
        guard streams.count == 1, let stream = streams.first else { return nil }
        let summary = try CoreAudioSupport.deviceSummary(deviceID)
        let native = try CoreAudioSupport.streamVirtualFormat(stream)
        let deviceFormat = try Self.validatedDeviceFormat(native)
        let nativeFormat = RuntimePCMFormatDTO(sampleRate: deviceFormat.sampleRate,
            channelCount: UInt16(deviceFormat.channels), sampleFormat: .float32LE,
            interleaved: !native.isNonInterleaved)
        let hasInput = !(try CoreAudioSupport.inputStreamIDs(deviceID)).isEmpty
        return RuntimeOutputDestinationDTO(id: id,
            kind: Self.classifyDestination(name: summary.name, uid: summary.uid,
                hasInput: hasInput),
            name: name, isAvailable: true, isDefault: isDefault,
            followsSystemDefault: followsSystemDefault,
            activeDeviceID: "coreaudio:\(summary.uid)", activeDeviceName: summary.name,
            nativeFormat: nativeFormat)
    }

    static func classifyDestination(name: String, uid: String,
                                    hasInput: Bool) -> RuntimeOutputDestinationKindDTO {
        guard hasInput else { return .playback }
        let signature = "\(name) \(uid)".lowercased()
        return signature.contains("audioplane") || signature.contains("sonexis")
            || signature.contains("blackhole")
            || signature.contains("loopback") || signature.contains("soundflower")
            ? .virtualInput : .playback
    }

    static func validatedDeviceFormat(_ format: AudioStreamBasicDescription) throws
        -> (sampleRate: UInt32, channels: UInt32) {
        let channels = format.mChannelsPerFrame
        let isNonInterleaved = format.isNonInterleaved
        let expectedBytesPerFrame: UInt32 = isNonInterleaved ? 4 : 4 * channels
        guard format.isFloat32LinearPCM,
              (format.mFormatFlags & kAudioFormatFlagIsPacked) != 0,
              format.mSampleRate.isFinite,
              (8_000...192_000).contains(format.mSampleRate),
              (1...2).contains(channels),
              format.mFramesPerPacket == 1,
              format.mBytesPerFrame == expectedBytesPerFrame,
              format.mBytesPerPacket == expectedBytesPerFrame else {
            throw RuntimeErrorDTO(code: "unsupported_output_device_format",
                message: "Output device format is outside the supported realtime bounds",
                retryable: true)
        }
        return (UInt32(format.mSampleRate.rounded()), channels)
    }
}

private final class RuntimeHALPlaybackSession: RuntimeBackendOutputSession, @unchecked Sendable {
    private final class Route {
        let deviceID: AudioDeviceID
        let deviceName: String
        let deviceSampleRate: Double
        let deviceChannels: UInt32
        let hardwareLatencyMilliseconds: Double
        let ring: RealtimeRingBuffer
        let converter: RuntimePlaybackConverter
        let ioProcID: AudioDeviceIOProcID
        let retainedRingOpaque: UnsafeMutableRawPointer
        let targetFillFrames: UInt32
        var primed = false
        var priming = RuntimePlaybackPriming()

        init(deviceID: AudioDeviceID, deviceName: String, deviceSampleRate: Double,
             deviceChannels: UInt32, hardwareLatencyMilliseconds: Double,
             ring: RealtimeRingBuffer, converter: RuntimePlaybackConverter,
             ioProcID: AudioDeviceIOProcID, retainedRingOpaque: UnsafeMutableRawPointer,
             targetFillFrames: UInt32) {
            self.deviceID = deviceID
            self.deviceName = deviceName
            self.deviceSampleRate = deviceSampleRate
            self.deviceChannels = deviceChannels
            self.hardwareLatencyMilliseconds = hardwareLatencyMilliseconds
            self.ring = ring
            self.converter = converter
            self.ioProcID = ioProcID
            self.retainedRingOpaque = retainedRingOpaque
            self.targetFillFrames = targetFillFrames
        }
    }

    let inputFormat: RuntimePCMFormatDTO
    let destination: RuntimeOutputDestinationDTO
    private let targetBufferMilliseconds: UInt32
    private let destinationID: String
    private let followsSystemDefault: Bool
    private let onEvent: @Sendable (RuntimeOutputBackendEvent) -> Void
    private let onEnded: @Sendable (RuntimeErrorDTO?) -> Void
    private let lifecycleQueue = DispatchQueue(label: "com.sonexis.runtime.hal-playback")
    private let lifecycleKey = DispatchSpecificKey<UInt8>()
    private let ingestLock = NSLock()
    private let routeLock = NSLock()
    private var route: Route?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var fixedDeviceListener: AudioObjectPropertyListenerBlock?
    private var fixedDeviceID: AudioDeviceID?
    private var formatListener: AudioObjectPropertyListenerBlock?
    private var formatListenerRegistrations: [(AudioObjectID, AudioObjectPropertyAddress)] = []
    private var metricsTimer: DispatchSourceTimer?
    private var drainDeadline: DispatchTime?
    private var running = true
    private var finishing = false
    private var didComplete = false
    private var lastUnderflowFrames: UInt64 = 0
    private var archivedRendered: UInt64 = 0
    private var archivedEnqueued: UInt64 = 0
    private var archivedDropped: UInt64 = 0
    private var archivedUnderflows: UInt64 = 0
    private var flushedFrames: UInt64 = 0
    private var overrunEvents: UInt64 = 0
    private var underrunEvents: UInt64 = 0
    private var queueHighWater: UInt32 = 0
    private var conversionBatches: UInt64 = 0
    private var conversionNanoseconds: UInt64 = 0
    private var routeChanges: UInt64 = 0
    private var routeChangeScheduled = false
    private var lateFrames: UInt64 = 0
    private var lastTimestamp: UInt64?

    init(inputFormat: RuntimePCMFormatDTO, destinationID: String,
         targetBufferMilliseconds: UInt32,
         onEvent: @escaping @Sendable (RuntimeOutputBackendEvent) -> Void,
         onEnded: @escaping @Sendable (RuntimeErrorDTO?) -> Void) throws {
        self.inputFormat = inputFormat
        self.destinationID = destinationID
        followsSystemDefault = destinationID == "default"
        self.targetBufferMilliseconds = targetBufferMilliseconds
        self.onEvent = onEvent
        self.onEnded = onEnded
        lifecycleQueue.setSpecific(key: lifecycleKey, value: 1)
        let deviceID = try Self.resolveDevice(destinationID)
        let summary = try CoreAudioSupport.deviceSummary(deviceID)
        let hasInput = !(try CoreAudioSupport.inputStreamIDs(deviceID)).isEmpty
        destination = RuntimeOutputDestinationDTO(id: destinationID,
            kind: destinationID == "default" ? .playback
                : RuntimeHALPlaybackBackend.classifyDestination(
                    name: summary.name, uid: summary.uid, hasInput: hasInput),
            name: destinationID == "default" ? "Default macOS Output" : summary.name,
            isAvailable: true, isDefault: destinationID == "default",
            followsSystemDefault: destinationID == "default", activeDeviceName: summary.name)
        do {
            try lifecycleQueue.sync {
                if followsSystemDefault { try installDefaultOutputListener() }
                else { try installFixedDeviceListener(deviceID: deviceID) }
                try buildRoute()
                startMetricsTimer()
            }
        } catch {
            lifecycleQueue.sync {
                removeDefaultOutputListener()
                removeFixedDeviceListener()
                _ = try? teardownRoute()
            }
            throw error
        }
    }

    func write(_ frame: RuntimePCMFrame) throws {
        ingestLock.lock()
        defer { ingestLock.unlock() }
        routeLock.lock()
        guard running, !finishing, let route else {
            routeLock.unlock()
            throw RuntimeErrorDTO(code: "output_not_writable",
                message: "Playback session is not accepting audio")
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let converted: (UnsafePointer<Float>, UInt32)
        routeLock.unlock()
        converted = try route.converter.convert(frame)
        // Backpressure the socket reader while a bounded burst drains. This is
        // never reached from the HAL callback. The timeout prevents a stalled
        // device from pinning a client forever; any remaining tail is dropped
        // explicitly by the bounded ring.
        let writableDeadline = DispatchTime.now() + .seconds(2)
        while route.ring.writableFrames < converted.1,
              isWritable(route), DispatchTime.now() < writableDeadline {
            usleep(2_000)
        }
        guard isWritable(route) else {
            throw RuntimeErrorDTO(code: "output_not_writable",
                message: "Playback stopped while waiting for device capacity", retryable: true)
        }
        let written = route.ring.writeInterleaved(converted.0, frames: converted.1)
        let fill = route.ring.fillFrames
        routeLock.lock()
        guard running, self.route === route else {
            routeLock.unlock()
            throw RuntimeErrorDTO(code: "output_not_writable",
                message: "Playback route changed while accepting audio", retryable: true)
        }
        queueHighWater = max(queueHighWater, fill)
        if !route.primed, route.priming.shouldStart(fill: fill,
            target: route.targetFillFrames, sampleRate: route.deviceSampleRate,
            now: DispatchTime.now().uptimeNanoseconds) {
            route.primed = true
            route.ring.setReadEnabled(true)
        }
        if let lastTimestamp, frame.header.timestampNanoseconds < lastTimestamp {
            lateFrames &+= UInt64(frame.header.frameCount)
        }
        lastTimestamp = frame.header.timestampNanoseconds
        conversionBatches &+= 1
        conversionNanoseconds &+= DispatchTime.now().uptimeNanoseconds - started
        let dropped = UInt64(converted.1 - written)
        if dropped > 0 { overrunEvents &+= 1 }
        routeLock.unlock()
        if dropped > 0 {
            onEvent(RuntimeOutputBackendEvent(kind: .overrun, frames: dropped,
                message: "Playback ring was full; newest audio was dropped"))
        }
    }

    func finish() {
        performLifecycle { [weak self] in
            guard let self else { return }
            self.ingestLock.lock()
            self.routeLock.lock()
            guard self.running, !self.finishing else {
                self.routeLock.unlock()
                self.ingestLock.unlock()
                return
            }
            self.finishing = true
            self.drainDeadline = .now() + .seconds(2)
            var conversionFailure: RuntimeErrorDTO?
            var drainDropped: UInt64 = 0
            if let route = self.route {
                do {
                    let tail = try route.converter.drain()
                    if tail.1 > 0 {
                        let written = route.ring.writeInterleaved(tail.0, frames: tail.1)
                        drainDropped = UInt64(tail.1 - written)
                        if drainDropped > 0 { self.overrunEvents &+= 1 }
                    }
                } catch {
                    conversionFailure = RuntimeErrorDTO(code: "output_conversion_failed",
                        message: String(describing: error), retryable: true)
                }
                if route.ring.fillFrames > 0 {
                    route.primed = true
                    route.ring.setReadEnabled(true)
                }
            }
            self.routeLock.unlock()
            self.ingestLock.unlock()
            if let conversionFailure {
                self.stopInternal(notify: true, error: conversionFailure)
                return
            }
            if drainDropped > 0 {
                self.onEvent(RuntimeOutputBackendEvent(kind: .overrun, frames: drainDropped,
                    message: "Playback ring dropped converter tail frames during drain"))
            }
            self.checkDrain()
        }
    }

    func flush() throws {
        ingestLock.lock()
        defer { ingestLock.unlock() }
        routeLock.lock()
        defer { routeLock.unlock() }
        guard running, !finishing, let route else {
            throw RuntimeErrorDTO(code: "output_not_writable",
                message: "Playback session cannot be flushed")
        }
        route.ring.setReadEnabled(false)
        let discarded = route.ring.flush()
        route.converter.reset()
        route.primed = false
        route.priming.reset()
        lastTimestamp = nil
        flushedFrames &+= UInt64(discarded)
    }

    func stop() {
        performLifecycle { [weak self] in self?.stopInternal(notify: false, error: nil) }
    }

    func metrics() -> RuntimeOutputMetricsDTO {
        routeLock.lock()
        let current = route
        let enqueued = archivedEnqueued &+ (current?.ring.writtenFrames ?? 0)
        let rendered = archivedRendered &+ (current?.ring.renderedFrames ?? 0)
        let dropped = archivedDropped &+ (current?.ring.droppedFrames ?? 0)
        let underflow = archivedUnderflows &+ (current?.ring.underflowFrames ?? 0)
        let fill = current?.ring.fillFrames ?? 0
        let sampleRate = current?.deviceSampleRate ?? 0
        let buffered = sampleRate > 0 ? Double(fill) * 1_000 / sampleRate : 0
        let snapshot = RuntimeOutputMetricsDTO(deviceFramesEnqueued: enqueued,
            deviceFramesRendered: rendered, droppedFrames: dropped,
            flushedFrames: flushedFrames, lateFrames: lateFrames,
            underrunFrames: underflow, underrunEvents: underrunEvents,
            overrunEvents: overrunEvents, queueDepthFrames: fill,
            queueHighWaterFrames: queueHighWater, bufferedMilliseconds: buffered,
            targetBufferMilliseconds: targetBufferMilliseconds,
            conversionBatches: conversionBatches,
            conversionNanoseconds: conversionNanoseconds, routeChanges: routeChanges,
            deviceSampleRate: current.map { UInt32($0.deviceSampleRate.rounded()) },
            deviceChannelCount: current.map { UInt16($0.deviceChannels) },
            estimatedOutputLatencyMilliseconds: current.map {
                buffered + $0.hardwareLatencyMilliseconds
            })
        routeLock.unlock()
        return snapshot
    }

    private func buildRoute() throws {
        let deviceID = try Self.resolveDevice(destinationID)
        let summary = try CoreAudioSupport.deviceSummary(deviceID)
        let streams = try CoreAudioSupport.outputStreamIDs(deviceID)
        guard streams.count == 1, let streamID = streams.first else {
            throw RuntimeErrorDTO(code: "output_device_unavailable",
                message: "Output devices must expose one compatible output stream",
                retryable: true)
        }
        let format = try CoreAudioSupport.streamVirtualFormat(streamID)
        let deviceFormat = try RuntimeHALPlaybackBackend.validatedDeviceFormat(format)
        let capacityFrames = max(deviceFormat.sampleRate / 2, 4_096)
        let targetFrames = UInt32(UInt64(deviceFormat.sampleRate)
            * UInt64(targetBufferMilliseconds) / 1_000)
        let ring = try RealtimeRingBuffer(capacityFrames: capacityFrames,
            channels: deviceFormat.channels)
        ring.setTargetFillFrames(targetFrames)
        ring.setReadEnabled(false)
        let converter = try RuntimePlaybackConverter(input: inputFormat,
            deviceSampleRate: format.mSampleRate,
            deviceChannels: deviceFormat.channels)
        let latencyFrames: UInt32 = (try? CoreAudioSupport.readScalar(
            objectID: deviceID, selector: kAudioDevicePropertyLatency,
            scope: kAudioDevicePropertyScopeOutput, defaultValue: 0,
            operation: "Read output-device latency")) ?? 0
        let safetyFrames: UInt32 = (try? CoreAudioSupport.readScalar(
            objectID: deviceID, selector: kAudioDevicePropertySafetyOffset,
            scope: kAudioDevicePropertyScopeOutput, defaultValue: 0,
            operation: "Read output-device safety offset")) ?? 0
        let hardwareLatencyMilliseconds = Double(UInt64(latencyFrames) + UInt64(safetyFrames))
            * 1_000 / format.mSampleRate
        guard let ringPointer = ring.realtimePointer else {
            throw RuntimeErrorDTO(code: "output_buffer_allocation_failed",
                message: "Playback ring became unavailable")
        }
        let retainedRingOpaque = Unmanaged.passRetained(ring).toOpaque()
        var ioProc: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(deviceID,
            SonexisAudioRingBufferIOProc, UnsafeMutableRawPointer(ringPointer), &ioProc)
        guard createStatus == noErr, let ioProc else {
            Unmanaged<RealtimeRingBuffer>.fromOpaque(retainedRingOpaque).release()
            throw CoreAudioError(operation: "Create Runtime playback IOProc", status: createStatus)
        }
        let next = Route(deviceID: deviceID, deviceName: summary.name,
            deviceSampleRate: format.mSampleRate, deviceChannels: deviceFormat.channels,
            hardwareLatencyMilliseconds: hardwareLatencyMilliseconds,
            ring: ring, converter: converter,
            ioProcID: ioProc, retainedRingOpaque: retainedRingOpaque,
            targetFillFrames: targetFrames)
        routeLock.lock()
        route = next
        lastUnderflowFrames = 0
        routeLock.unlock()
        let startStatus = AudioDeviceStart(deviceID, ioProc)
        if startStatus != noErr {
            let destroyStatus = AudioDeviceDestroyIOProcID(deviceID, ioProc)
            if destroyStatus == noErr {
                ring.quiesceReads()
                Unmanaged<RealtimeRingBuffer>.fromOpaque(retainedRingOpaque).release()
                routeLock.lock(); route = nil; routeLock.unlock()
            }
            throw CoreAudioError(operation: "Start Runtime playback IOProc", status: startStatus)
        }
        try installDeviceFormatListeners(deviceID: deviceID, streamIDs: streams)
    }

    @discardableResult
    private func teardownRoute() throws -> UInt64 {
        ingestLock.lock()
        defer { ingestLock.unlock() }
        return try teardownRouteWithIngestLockHeld()
    }

    /// Tears down the HAL route while the non-realtime ingest path is paused.
    /// The realtime callback observes its retained ring until AudioDeviceStop
    /// and IOProc destruction have quiesced it.
    @discardableResult
    private func teardownRouteWithIngestLockHeld() throws -> UInt64 {
        routeLock.lock()
        guard let old = route else { routeLock.unlock(); return 0 }
        route = nil
        routeLock.unlock()
        removeDeviceFormatListeners()
        old.ring.setReadEnabled(false)
        let discarded = UInt64(old.ring.fillFrames)
        let stopStatus = AudioDeviceStop(old.deviceID, old.ioProcID)
        let destroyStatus = AudioDeviceDestroyIOProcID(old.deviceID, old.ioProcID)
        guard destroyStatus == noErr else {
            // Preserve the Route, IOProc handle and retained callback context
            // so a later stop/cleanup attempt can retry safely.
            routeLock.lock(); route = old; routeLock.unlock()
            throw CoreAudioError(operation: "Destroy Runtime playback IOProc",
                status: destroyStatus)
        }
        old.ring.quiesceReads()
        routeLock.lock()
        archivedRendered &+= old.ring.renderedFrames
        archivedEnqueued &+= old.ring.writtenFrames
        archivedDropped &+= old.ring.droppedFrames &+ discarded
        archivedUnderflows &+= old.ring.underflowFrames
        routeLock.unlock()
        Unmanaged<RealtimeRingBuffer>.fromOpaque(old.retainedRingOpaque).release()
        if stopStatus != noErr {
            throw CoreAudioError(operation: "Stop Runtime playback IOProc", status: stopStatus)
        }
        return discarded
    }

    private func installDeviceFormatListeners(deviceID: AudioDeviceID,
                                              streamIDs: [AudioObjectID]) throws {
        removeDeviceFormatListeners()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRouteChange()
        }
        var registrations: [(AudioObjectID, AudioObjectPropertyAddress)] = [
            (deviceID, AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)),
        ]
        registrations += streamIDs.map {
            ($0, AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyVirtualFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain))
        }
        for (objectID, storedAddress) in registrations {
            var address = storedAddress
            do {
                try checkOSStatus(AudioObjectAddPropertyListenerBlock(
                    objectID, &address, lifecycleQueue, listener),
                    operation: "Install Runtime output-format listener")
                formatListenerRegistrations.append((objectID, storedAddress))
            } catch {
                formatListener = listener
                removeDeviceFormatListeners()
                throw error
            }
        }
        formatListener = listener
    }

    private func removeDeviceFormatListeners() {
        guard let listener = formatListener else {
            formatListenerRegistrations.removeAll()
            return
        }
        for (objectID, storedAddress) in formatListenerRegistrations {
            var address = storedAddress
            _ = AudioObjectRemovePropertyListenerBlock(
                objectID, &address, lifecycleQueue, listener)
        }
        formatListenerRegistrations.removeAll()
        formatListener = nil
    }

    private func installDefaultOutputListener() throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRouteChange()
        }
        try checkOSStatus(AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, lifecycleQueue, listener),
            operation: "Install Runtime default-output listener")
        defaultOutputListener = listener
    }

    private func removeDefaultOutputListener() {
        guard let listener = defaultOutputListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, lifecycleQueue, listener)
        defaultOutputListener = nil
    }

    private func installFixedDeviceListener(deviceID: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleFixedDeviceStateChange()
        }
        try checkOSStatus(AudioObjectAddPropertyListenerBlock(
            deviceID, &address, lifecycleQueue, listener),
            operation: "Install Runtime output-device listener")
        fixedDeviceID = deviceID
        fixedDeviceListener = listener
    }

    private func removeFixedDeviceListener() {
        guard let deviceID = fixedDeviceID, let listener = fixedDeviceListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectRemovePropertyListenerBlock(deviceID, &address, lifecycleQueue, listener)
        fixedDeviceID = nil
        fixedDeviceListener = nil
    }

    private func handleFixedDeviceStateChange() {
        guard let deviceID = fixedDeviceID else { return }
        let alive: UInt32? = try? CoreAudioSupport.readScalar(
            objectID: deviceID, selector: kAudioDevicePropertyDeviceIsAlive,
            defaultValue: 0, operation: "Read output-device liveness")
        if alive != 1 {
            stopInternal(notify: true, error: RuntimeErrorDTO(
                code: "output_destination_disconnected",
                message: "The selected output destination disconnected", retryable: true))
        }
    }

    private func scheduleRouteChange() {
        guard !routeChangeScheduled else { return }
        routeChangeScheduled = true
        lifecycleQueue.asyncAfter(deadline: .now() + .milliseconds(75)) { [weak self] in
            guard let self else { return }
            self.routeChangeScheduled = false
            self.handleRouteChange()
        }
    }

    private func handleRouteChange() {
        routeLock.lock()
        let isRunning = running
        routeLock.unlock()
        guard isRunning else { return }
        // Writers are briefly backpressured on the non-realtime ingest lock so
        // they never observe the intentional nil route between HAL devices.
        ingestLock.lock()
        let discarded: UInt64
        do {
            discarded = try teardownRouteWithIngestLockHeld()
            try buildRoute()
            routeLock.lock(); routeChanges &+= 1; routeLock.unlock()
            ingestLock.unlock()
            onEvent(RuntimeOutputBackendEvent(kind: .destinationChanged,
                frames: discarded,
                message: followsSystemDefault
                    ? "Playback followed the current default output device"
                    : "Playback rebuilt after the selected device format changed"))
        } catch {
            ingestLock.unlock()
            stopInternal(notify: true, error: RuntimeErrorDTO(
                code: "output_device_change_failed", message: String(describing: error),
                retryable: true))
        }
    }

    private func isWritable(_ candidate: Route) -> Bool {
        routeLock.lock()
        defer { routeLock.unlock() }
        return running && !finishing && route === candidate
    }

    private static func resolveDevice(_ destinationID: String) throws -> AudioDeviceID {
        if destinationID == "default" { return try CoreAudioSupport.defaultOutputDevice() }
        let prefix = "coreaudio:"
        guard destinationID.hasPrefix(prefix) else {
            throw RuntimeErrorDTO(code: "output_destination_unavailable",
                message: "Unknown output destination: \(destinationID)", retryable: true)
        }
        let uid = String(destinationID.dropFirst(prefix.count))
        guard !uid.isEmpty, let deviceID = try CoreAudioSupport.deviceID(forUID: uid),
              !(try CoreAudioSupport.outputStreamIDs(deviceID)).isEmpty else {
            throw RuntimeErrorDTO(code: "output_destination_unavailable",
                message: "Output destination is no longer available", retryable: true)
        }
        return deviceID
    }

    private func startMetricsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: lifecycleQueue)
        timer.schedule(deadline: .now() + .milliseconds(50),
            repeating: .milliseconds(50), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.pollMetrics() }
        metricsTimer = timer
        timer.resume()
    }

    private func pollMetrics() {
        var underflowDelta: UInt64 = 0
        var shouldCheckDrain = false
        routeLock.lock()
        if let route {
            let current = route.ring.underflowFrames
            if current > lastUnderflowFrames, route.primed, !finishing {
                underflowDelta = current - lastUnderflowFrames
                if route.ring.fillFrames == 0, !finishing {
                    route.primed = false
                    route.priming.reset()
                    route.ring.setReadEnabled(false)
                }
            }
            lastUnderflowFrames = current
            if !route.primed, !finishing,
               route.priming.shouldStart(fill: route.ring.fillFrames,
                   target: route.targetFillFrames, sampleRate: route.deviceSampleRate,
                   now: DispatchTime.now().uptimeNanoseconds) {
                route.primed = true
                route.ring.setReadEnabled(true)
            }
        }
        shouldCheckDrain = finishing
        routeLock.unlock()
        if underflowDelta > 0 {
            routeLock.lock(); underrunEvents &+= 1; routeLock.unlock()
            onEvent(RuntimeOutputBackendEvent(kind: .underrun, frames: underflowDelta,
                message: "Playback produced silence while waiting for audio"))
        }
        if shouldCheckDrain { checkDrain() }
    }

    private func checkDrain() {
        routeLock.lock()
        let empty = route?.ring.fillFrames == 0
        let timedOut = drainDeadline.map { DispatchTime.now() >= $0 } ?? false
        if timedOut, let route {
            route.ring.setReadEnabled(false)
            flushedFrames &+= UInt64(route.ring.flush())
        }
        routeLock.unlock()
        if empty || timedOut { stopInternal(notify: true, error: nil) }
    }

    private func stopInternal(notify: Bool, error: RuntimeErrorDTO?) {
        routeLock.lock()
        let wasRunning = running
        guard wasRunning || route != nil else { routeLock.unlock(); return }
        running = false
        routeLock.unlock()
        metricsTimer?.setEventHandler {}
        metricsTimer?.cancel()
        metricsTimer = nil
        removeDefaultOutputListener()
        removeFixedDeviceListener()
        var completionError = error
        do {
            _ = try teardownRoute()
        } catch {
            if completionError == nil {
                completionError = RuntimeErrorDTO(code: "output_cleanup_failed",
                    message: String(describing: error), retryable: true)
            }
        }
        if notify, wasRunning, !didComplete {
            didComplete = true
            onEnded(completionError)
        }
    }

    private func performLifecycle(_ work: @escaping @Sendable () -> Void) {
        if DispatchQueue.getSpecific(key: lifecycleKey) != nil { work() }
        else { lifecycleQueue.sync(execute: work) }
    }
}
