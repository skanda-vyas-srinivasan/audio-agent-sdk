import AVFoundation
import CoreAudio
import Foundation

private func runtimePlaybackIOProc(
    _ inDevice: AudioObjectID,
    _ inNow: UnsafePointer<AudioTimeStamp>,
    _ inInputData: UnsafePointer<AudioBufferList>,
    _ inInputTime: UnsafePointer<AudioTimeStamp>,
    _ outOutputData: UnsafeMutablePointer<AudioBufferList>,
    _ inOutputTime: UnsafePointer<AudioTimeStamp>,
    _ inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let inClientData else { return noErr }
    let context = Unmanaged<RuntimePlaybackCallbackContext>
        .fromOpaque(inClientData).takeUnretainedValue()
    context.render(outputData: outOutputData)
    return noErr
}

/// Immutable callback-visible owner. HAL retains it explicitly until an IOProc
/// is successfully destroyed; no session property lookup or lock occurs on the
/// realtime thread.
private final class RuntimePlaybackCallbackContext {
    let ring: RealtimeRingBuffer
    init(ring: RealtimeRingBuffer) { self.ring = ring }
    func render(outputData: UnsafeMutablePointer<AudioBufferList>) {
        _ = ring.read(outputData: outputData)
    }
}

final class RuntimePlaybackConverter {
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let inputBuffer: AVAudioPCMBuffer
    private let outputBuffer: AVAudioPCMBuffer
    private let maximumInputFrames: AVAudioFrameCount

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
    }

    func convert(_ frame: RuntimePCMFrame) throws -> (UnsafePointer<Float>, UInt32) {
        guard frame.header.frameCount <= maximumInputFrames else {
            throw RuntimeErrorDTO(code: "output_packet_too_long",
                message: "Output packet exceeded the prepared converter capacity")
        }
        inputBuffer.frameLength = AVAudioFrameCount(frame.header.frameCount)
        guard let inputData = inputBuffer.mutableAudioBufferList.pointee.mBuffers.mData else {
            throw RuntimeErrorDTO(code: "output_conversion_failed",
                message: "Playback input buffer is unavailable")
        }
        frame.payload.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { inputData.copyMemory(from: base, byteCount: bytes.count) }
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
        return (UnsafePointer(outputData.assumingMemoryBound(to: Float.self)),
                UInt32(outputBuffer.frameLength))
    }

    func reset() { converter.reset() }
}

public final class RuntimeHALPlaybackBackend: RuntimeOutputBackend, @unchecked Sendable {
    public init() {}

    public func availableOutputDestinations() throws -> [RuntimeOutputDestinationDTO] {
        let defaultID = try CoreAudioSupport.defaultOutputDevice()
        var destinations: [RuntimeOutputDestinationDTO] = []
        if let value = try destination(deviceID: defaultID, id: "default",
                                       name: "Default macOS Output", isDefault: true,
                                       followsSystemDefault: true) {
            destinations.append(value)
        }
        let devices = try CoreAudioSupport.audioDeviceIDs()
        for deviceID in devices where deviceID != defaultID {
            guard let summary = try? CoreAudioSupport.deviceSummary(deviceID),
                  let value = try? destination(deviceID: deviceID,
                    id: "coreaudio:\(summary.uid)", name: summary.name,
                    isDefault: false, followsSystemDefault: false) else { continue }
            destinations.append(value)
        }
        return destinations
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
        guard let stream = streams.first else { return nil }
        let summary = try CoreAudioSupport.deviceSummary(deviceID)
        let native = try CoreAudioSupport.streamVirtualFormat(stream)
        let nativeFormat = RuntimePCMFormatDTO(sampleRate: UInt32(native.mSampleRate.rounded()),
            channelCount: UInt16(clamping: native.mChannelsPerFrame), sampleFormat: .float32LE)
        let signature = "\(summary.name) \(summary.uid)".lowercased()
        let looksVirtual = signature.contains("sonexis") || signature.contains("blackhole")
            || signature.contains("loopback") || signature.contains("virtual")
        return RuntimeOutputDestinationDTO(id: id,
            kind: looksVirtual ? .virtualInput : .playback,
            name: name, isAvailable: true, isDefault: isDefault,
            followsSystemDefault: followsSystemDefault, activeDeviceName: summary.name,
            nativeFormat: nativeFormat)
    }
}

private final class RuntimeHALPlaybackSession: RuntimeBackendOutputSession, @unchecked Sendable {
    private final class Route {
        let deviceID: AudioDeviceID
        let deviceName: String
        let deviceSampleRate: Double
        let ring: RealtimeRingBuffer
        let converter: RuntimePlaybackConverter
        let ioProcID: AudioDeviceIOProcID
        let callbackOpaque: UnsafeMutableRawPointer
        let targetFillFrames: UInt32
        var primed = false

        init(deviceID: AudioDeviceID, deviceName: String, deviceSampleRate: Double,
             ring: RealtimeRingBuffer, converter: RuntimePlaybackConverter,
             ioProcID: AudioDeviceIOProcID, callbackOpaque: UnsafeMutableRawPointer,
             targetFillFrames: UInt32) {
            self.deviceID = deviceID
            self.deviceName = deviceName
            self.deviceSampleRate = deviceSampleRate
            self.ring = ring
            self.converter = converter
            self.ioProcID = ioProcID
            self.callbackOpaque = callbackOpaque
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
    private let routeLock = NSLock()
    private var route: Route?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var fixedDeviceListener: AudioObjectPropertyListenerBlock?
    private var fixedDeviceID: AudioDeviceID?
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
        let signature = "\(summary.name) \(summary.uid)".lowercased()
        let looksVirtual = signature.contains("sonexis") || signature.contains("blackhole")
            || signature.contains("loopback") || signature.contains("virtual")
        destination = RuntimeOutputDestinationDTO(id: destinationID,
            kind: looksVirtual ? .virtualInput : .playback,
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
                teardownRoute()
            }
            throw error
        }
    }

    func write(_ frame: RuntimePCMFrame) throws {
        routeLock.lock()
        guard running, !finishing, let route else {
            routeLock.unlock()
            throw RuntimeErrorDTO(code: "output_not_writable",
                message: "Playback session is not accepting audio")
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let converted: (UnsafePointer<Float>, UInt32)
        do { converted = try route.converter.convert(frame) }
        catch { routeLock.unlock(); throw error }
        // Backpressure the socket reader while a bounded burst drains. This is
        // never reached from the HAL callback. The timeout prevents a stalled
        // device from pinning a client forever; any remaining tail is dropped
        // explicitly by the bounded ring.
        let writableDeadline = DispatchTime.now() + .seconds(2)
        while route.ring.writableFrames < converted.1,
              DispatchTime.now() < writableDeadline {
            usleep(2_000)
        }
        let written = route.ring.writeInterleaved(converted.0, frames: converted.1)
        let fill = route.ring.fillFrames
        queueHighWater = max(queueHighWater, fill)
        if !route.primed, fill >= route.targetFillFrames {
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
            self.routeLock.lock()
            guard self.running, !self.finishing else {
                self.routeLock.unlock()
                return
            }
            self.finishing = true
            self.drainDeadline = .now() + .seconds(2)
            if let route = self.route, route.ring.fillFrames > 0 {
                route.primed = true
                route.ring.setReadEnabled(true)
            }
            self.routeLock.unlock()
            self.checkDrain()
        }
    }

    func flush() throws {
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
        let rendered = archivedRendered &+ (current?.ring.readFrames ?? 0)
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
            conversionNanoseconds: conversionNanoseconds, routeChanges: routeChanges)
        routeLock.unlock()
        return snapshot
    }

    private func buildRoute() throws {
        let deviceID = try Self.resolveDevice(destinationID)
        let summary = try CoreAudioSupport.deviceSummary(deviceID)
        let streams = try CoreAudioSupport.outputStreamIDs(deviceID)
        guard let streamID = streams.first else {
            throw RuntimeErrorDTO(code: "output_device_unavailable",
                message: "Default output device has no output stream", retryable: true)
        }
        let format = try CoreAudioSupport.streamVirtualFormat(streamID)
        guard format.isFloat32LinearPCM, format.mSampleRate > 0,
              format.mChannelsPerFrame > 0 else {
            throw RuntimeErrorDTO(code: "unsupported_output_device_format",
                message: "Default output device does not expose Float32 linear PCM", retryable: true)
        }
        let capacityFrames = UInt32(max(format.mSampleRate * 0.5, 4_096))
        let targetFrames = UInt32(format.mSampleRate * Double(targetBufferMilliseconds) / 1_000)
        let ring = try RealtimeRingBuffer(capacityFrames: capacityFrames,
            channels: format.mChannelsPerFrame)
        ring.setTargetFillFrames(targetFrames)
        ring.setReadEnabled(false)
        let converter = try RuntimePlaybackConverter(input: inputFormat,
            deviceSampleRate: format.mSampleRate,
            deviceChannels: format.mChannelsPerFrame)
        let context = RuntimePlaybackCallbackContext(ring: ring)
        let opaque = Unmanaged.passRetained(context).toOpaque()
        var ioProc: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(deviceID, runtimePlaybackIOProc,
            opaque, &ioProc)
        guard createStatus == noErr, let ioProc else {
            Unmanaged<RuntimePlaybackCallbackContext>.fromOpaque(opaque).release()
            throw CoreAudioError(operation: "Create Runtime playback IOProc", status: createStatus)
        }
        let next = Route(deviceID: deviceID, deviceName: summary.name,
            deviceSampleRate: format.mSampleRate, ring: ring, converter: converter,
            ioProcID: ioProc, callbackOpaque: opaque, targetFillFrames: targetFrames)
        routeLock.lock()
        route = next
        lastUnderflowFrames = 0
        routeLock.unlock()
        let startStatus = AudioDeviceStart(deviceID, ioProc)
        if startStatus != noErr {
            let destroyStatus = AudioDeviceDestroyIOProcID(deviceID, ioProc)
            if destroyStatus == noErr {
                Unmanaged<RuntimePlaybackCallbackContext>.fromOpaque(opaque).release()
            }
            routeLock.lock(); route = nil; routeLock.unlock()
            throw CoreAudioError(operation: "Start Runtime playback IOProc", status: startStatus)
        }
    }

    private func teardownRoute() {
        routeLock.lock()
        guard let old = route else { routeLock.unlock(); return }
        old.ring.setReadEnabled(false)
        _ = AudioDeviceStop(old.deviceID, old.ioProcID)
        let destroyStatus = AudioDeviceDestroyIOProcID(old.deviceID, old.ioProcID)
        archivedRendered &+= old.ring.readFrames
        archivedEnqueued &+= old.ring.writtenFrames
        archivedDropped &+= old.ring.droppedFrames &+ UInt64(old.ring.fillFrames)
        archivedUnderflows &+= old.ring.underflowFrames
        route = nil
        routeLock.unlock()
        if destroyStatus == noErr {
            Unmanaged<RuntimePlaybackCallbackContext>.fromOpaque(old.callbackOpaque).release()
        }
        // On destroy failure the retained callback context deliberately owns
        // the ring forever. Leaking is safer than freeing HAL-visible memory.
    }

    private func installDefaultOutputListener() throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleRouteChange()
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

    private func handleRouteChange() {
        routeLock.lock()
        let isRunning = running
        routeLock.unlock()
        guard isRunning else { return }
        teardownRoute()
        do {
            try buildRoute()
            routeLock.lock(); routeChanges &+= 1; routeLock.unlock()
            onEvent(RuntimeOutputBackendEvent(kind: .destinationChanged,
                message: "Playback followed the current default output device"))
        } catch {
            stopInternal(notify: true, error: RuntimeErrorDTO(
                code: "output_device_change_failed", message: String(describing: error),
                retryable: true))
        }
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
            if current > lastUnderflowFrames, route.primed {
                underflowDelta = current - lastUnderflowFrames
                if route.ring.fillFrames == 0, !finishing {
                    route.primed = false
                    route.ring.setReadEnabled(false)
                }
            }
            lastUnderflowFrames = current
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
        guard running else { routeLock.unlock(); return }
        running = false
        routeLock.unlock()
        metricsTimer?.setEventHandler {}
        metricsTimer?.cancel()
        metricsTimer = nil
        removeDefaultOutputListener()
        removeFixedDeviceListener()
        teardownRoute()
        if notify, !didComplete {
            didComplete = true
            onEnded(error)
        }
    }

    private func performLifecycle(_ work: @escaping @Sendable () -> Void) {
        if DispatchQueue.getSpecific(key: lifecycleKey) != nil { work() }
        else { lifecycleQueue.sync(execute: work) }
    }
}
