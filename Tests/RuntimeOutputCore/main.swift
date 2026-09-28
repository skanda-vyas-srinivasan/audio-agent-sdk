import CoreAudio
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

private final class DiscoveryBackend: RuntimeOutputBackend, @unchecked Sendable {
    var destinations: [RuntimeOutputDestinationDTO]

    init(_ destinations: [RuntimeOutputDestinationDTO]) {
        self.destinations = destinations
    }

    func availableOutputDestinations() throws -> [RuntimeOutputDestinationDTO] { destinations }

    func startOutput(destinationID: String, format: RuntimePCMFormatDTO,
                     targetBufferMilliseconds: UInt32,
                     onEvent: @escaping @Sendable (RuntimeOutputBackendEvent) -> Void,
                     onEnded: @escaping @Sendable (RuntimeErrorDTO?) -> Void)
        throws -> RuntimeBackendOutputSession {
        throw RuntimeErrorDTO(code: "unused", message: "Discovery test does not start output")
    }
}

private func expectDiscoveryError(_ expected: String,
                                  _ destinations: [RuntimeOutputDestinationDTO],
                                  maximum: Int = 32) {
    let backend = DiscoveryBackend(destinations)
    let coordinator = RuntimeOutputCoordinator(backend: backend,
        socketDirectory: URL(fileURLWithPath: "/tmp/sxr-discovery-test"),
        limits: RuntimeResourceLimitsDTO(maximumOutputDestinations: maximum))
    do {
        _ = try coordinator.availableDestinations()
        fatalError("expected destination discovery error \(expected)")
    } catch let error as RuntimeErrorDTO {
        expect(error.code == expected, "expected \(expected), got \(error.code)")
    } catch {
        fatalError("unexpected destination discovery error: \(error)")
    }
}

do {
    let defaultDestination = RuntimeOutputDestinationDTO(id: "default", kind: .playback,
        name: "System Default", isAvailable: true, isDefault: true,
        followsSystemDefault: true)
    let speakers = RuntimeOutputDestinationDTO(id: "coreaudio:speakers", kind: .playback,
        name: "Speakers", isAvailable: true)
    let discovery = RuntimeOutputCoordinator(backend: DiscoveryBackend([speakers, defaultDestination]),
        socketDirectory: URL(fileURLWithPath: "/tmp/sxr-discovery-valid"))
    let validatedDestinations = try discovery.availableDestinations()
    expect(validatedDestinations.map(\.id) == ["default", "coreaudio:speakers"],
        "validated destination discovery was not deterministic")
    expectDiscoveryError("duplicate_output_destination", [speakers, speakers])
    expectDiscoveryError("invalid_output_destination", [
        RuntimeOutputDestinationDTO(id: "", kind: .playback, name: "Missing ID",
            isAvailable: true),
    ])
    expectDiscoveryError("invalid_output_destination", [
        RuntimeOutputDestinationDTO(id: "default", kind: .playback, name: "Bad Default",
            isAvailable: true),
    ])
    expectDiscoveryError("output_destination_limit_exceeded",
        [defaultDestination, speakers], maximum: 1)

    func deviceFormat(rate: Double, channels: UInt32,
                      nonInterleaved: Bool = false) -> AudioStreamBasicDescription {
        let bytes = nonInterleaved ? UInt32(4) : UInt32(4 * channels)
        return AudioStreamBasicDescription(mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | (nonInterleaved ? kAudioFormatFlagIsNonInterleaved : 0),
            mBytesPerPacket: bytes, mFramesPerPacket: 1,
            mBytesPerFrame: bytes, mChannelsPerFrame: channels,
            mBitsPerChannel: 32, mReserved: 0)
    }

    for rate in [8_000.0, 44_100.0, 48_000.0, 96_000.0, 192_000.0] {
        for channels: UInt32 in [1, 2] {
            for planar in [false, true] {
                let validated = try RuntimeHALPlaybackBackend.validatedDeviceFormat(
                    deviceFormat(rate: rate, channels: channels, nonInterleaved: planar))
                expect(validated.sampleRate == UInt32(rate) && validated.channels == channels,
                       "valid HAL layout was rejected")
            }
        }
    }
    for invalid in [7_999.0, 192_001.0] {
        do {
            _ = try RuntimeHALPlaybackBackend.validatedDeviceFormat(
                deviceFormat(rate: invalid, channels: 1))
            fatalError("out-of-range HAL sample rate was accepted")
        } catch is RuntimeErrorDTO {}
    }
    var malformedStride = deviceFormat(rate: 48_000, channels: 2)
    malformedStride.mBytesPerFrame = 4
    do {
        _ = try RuntimeHALPlaybackBackend.validatedDeviceFormat(malformedStride)
        fatalError("malformed interleaved HAL stride was accepted")
    } catch is RuntimeErrorDTO {}
    var malformedPacket = deviceFormat(rate: 48_000, channels: 1)
    malformedPacket.mFramesPerPacket = 2
    do {
        _ = try RuntimeHALPlaybackBackend.validatedDeviceFormat(malformedPacket)
        fatalError("malformed HAL packet layout was accepted")
    } catch is RuntimeErrorDTO {}

    expect(RuntimeHALPlaybackBackend.classifyDestination(
        name: "BlackHole 2ch", uid: "BlackHole2ch_UID", hasInput: true) == .virtualInput,
        "BlackHole was not classified as a virtual input")
    expect(RuntimeHALPlaybackBackend.classifyDestination(
        name: "AudioPlane Input", uid: "com.audioplane.input.device", hasInput: true)
        == .virtualInput, "AudioPlane Input was not classified as a virtual input")
    expect(RuntimeHALPlaybackBackend.classifyDestination(
        name: "BlackHole 2ch", uid: "BlackHole2ch_UID", hasInput: false) == .playback,
        "output-only device was classified as a virtual input")
    expect(RuntimeHALPlaybackBackend.classifyDestination(
        name: "USB Headset", uid: "usb-headset", hasInput: true) == .playback,
        "ordinary duplex hardware was classified as loopback")

    var invalidDeviceFormat = AudioStreamBasicDescription()
    invalidDeviceFormat.mFormatID = kAudioFormatLinearPCM
    invalidDeviceFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        | kAudioFormatFlagIsNonInterleaved
    invalidDeviceFormat.mBitsPerChannel = 32
    invalidDeviceFormat.mBytesPerFrame = 4
    invalidDeviceFormat.mFramesPerPacket = 1
    invalidDeviceFormat.mBytesPerPacket = 4
    invalidDeviceFormat.mChannelsPerFrame = 2
    invalidDeviceFormat.mSampleRate = .infinity
    do {
        _ = try RuntimeHALPlaybackBackend.validatedDeviceFormat(invalidDeviceFormat)
        fatalError("infinite HAL sample rate was accepted")
    } catch let error as RuntimeErrorDTO {
        expect(error.code == "unsupported_output_device_format",
               "invalid HAL format returned the wrong structured error")
    }
    invalidDeviceFormat.mSampleRate = 48_000
    invalidDeviceFormat.mChannelsPerFrame = 128
    do {
        _ = try RuntimeHALPlaybackBackend.validatedDeviceFormat(invalidDeviceFormat)
        fatalError("extreme HAL channel count was accepted")
    } catch let error as RuntimeErrorDTO {
        expect(error.code == "unsupported_output_device_format",
               "extreme HAL channel count returned the wrong error")
    }

    let ring = try RealtimeRingBuffer(capacityFrames: 100, channels: 1)
    ring.setReadEnabled(false)
    let input = (0..<120).map { Float($0) / 120 }
    let firstWrite = input.withUnsafeBufferPointer {
        ring.writeInterleaved($0.baseAddress!, frames: 40)
    }
    expect(firstWrite == 40 && ring.fillFrames == 40, "ring did not accept initial burst")
    var output = [Float](repeating: -1, count: 20)
    let gatedRead = output.withUnsafeMutableBufferPointer {
        ring.readInterleaved($0.baseAddress!, frames: 20)
    }
    expect(gatedRead == 0 && output.allSatisfy { $0 == 0 },
           "gated output did not render silence")
    ring.setReadEnabled(true)
    let read = output.withUnsafeMutableBufferPointer {
        ring.readInterleaved($0.baseAddress!, frames: 20)
    }
    expect(read == 20 && ring.fillFrames == 20, "ring did not render queued frames")
    expect(ring.renderedFrames == 20, "ring did not count non-silent callback output frames")
    expect(ring.flush() == 20 && ring.fillFrames == 0, "ring flush did not discard backlog")
    let overflowWrite = input.withUnsafeBufferPointer {
        ring.writeInterleaved($0.baseAddress!, frames: 120)
    }
    expect(overflowWrite == 100 && ring.droppedFrames == 20,
           "ring did not bound and account overflow")
    expect(ring.writableFrames == 0, "ring writable capacity was incorrect")

    let formats: [RuntimePCMFormatDTO] = [
        .runtimeDefault,
        RuntimePCMFormatDTO(sampleRate: 24_000, channelCount: 1),
        RuntimePCMFormatDTO(sampleRate: 48_000, channelCount: 1),
        RuntimePCMFormatDTO(sampleRate: 48_000, channelCount: 2),
        RuntimePCMFormatDTO(sampleRate: 48_000, channelCount: 1, sampleFormat: .float32LE),
        RuntimePCMFormatDTO(sampleRate: 48_000, channelCount: 2, sampleFormat: .float32LE),
    ]
    for format in formats {
        let frameCount = format.sampleRate / 100
        var payload: Data
        if format.sampleFormat == .pcmS16LE {
            let samples = [Int16](repeating: 4_096,
                count: Int(frameCount) * Int(format.channelCount))
            payload = samples.withUnsafeBytes { Data($0) }
        } else {
            let samples = [Float](repeating: 0.125,
                count: Int(frameCount) * Int(format.channelCount))
            payload = samples.withUnsafeBytes { Data($0) }
        }
        let header = RuntimePCMFrameHeader(payloadByteCount: UInt32(payload.count),
            streamID: UUID(), sequence: 0, timestampNanoseconds: 0,
            sampleRate: format.sampleRate, frameCount: frameCount,
            channelCount: format.channelCount, sampleFormat: format.sampleFormat)
        let converter = try RuntimePlaybackConverter(input: format,
            deviceSampleRate: 48_000, deviceChannels: 2)
        let converted = try converter.convert(RuntimePCMFrame(header: header, payload: payload))
        expect((470...490).contains(Int(converted.1)),
               "converter produced \(converted.1) frames for 10 ms of \(format)")
        if format.sampleRate == 48_000 {
            expect(converted.1 == frameCount,
                   "same-rate conversion retained or truncated frames for \(format)")
        }
        let sampleCount = Int(converted.1) * 2
        let values = UnsafeBufferPointer(start: converted.0, count: sampleCount)
        expect(values.contains { abs($0) > 0.01 }, "converter emitted silence for \(format)")
    }

    let resampleFormat = RuntimePCMFormatDTO(sampleRate: 24_000, channelCount: 1)
    let resampler = try RuntimePlaybackConverter(input: resampleFormat,
        deviceSampleRate: 48_000, deviceChannels: 2)
    var resampledFrames: UInt32 = 0
    for sequence in 0..<3 {
        let inputFrames: UInt32 = sequence < 2 ? 4_800 : 2_400
        let samples = [Int16](repeating: 2_048, count: Int(inputFrames))
        let payload = samples.withUnsafeBytes { Data($0) }
        let header = RuntimePCMFrameHeader(payloadByteCount: UInt32(payload.count),
            streamID: UUID(), sequence: UInt64(sequence), timestampNanoseconds: 0,
            sampleRate: 24_000, frameCount: inputFrames, channelCount: 1)
        resampledFrames &+= try resampler.convert(
            RuntimePCMFrame(header: header, payload: payload)).1
    }
    resampledFrames &+= try resampler.drain().1
    expect(resampledFrames == 24_000,
           "converter drain did not preserve a 500 ms 24-to-48 kHz stream: \(resampledFrames)")

    for inputRate: UInt32 in [16_000, 24_000, 48_000] {
        for inputChannels: UInt16 in [1, 2] {
            let inputFormat = RuntimePCMFormatDTO(sampleRate: inputRate,
                channelCount: inputChannels)
            let converter = try RuntimePlaybackConverter(input: inputFormat,
                deviceSampleRate: 44_100, deviceChannels: 2)
            let inputFrames = inputRate / 2
            var consumed: UInt32 = 0
            var outputFrames: UInt32 = 0
            var sequence: UInt64 = 0
            while consumed < inputFrames {
                let frames = min(inputRate / 50, inputFrames - consumed)
                let samples = [Int16](repeating: 1_024,
                    count: Int(frames) * Int(inputChannels))
                let payload = samples.withUnsafeBytes { Data($0) }
                let header = RuntimePCMFrameHeader(payloadByteCount: UInt32(payload.count),
                    streamID: UUID(), sequence: sequence, timestampNanoseconds: 0,
                    sampleRate: inputRate, frameCount: frames,
                    channelCount: inputChannels)
                outputFrames &+= try converter.convert(
                    RuntimePCMFrame(header: header, payload: payload)).1
                consumed &+= frames
                sequence &+= 1
            }
            outputFrames &+= try converter.drain().1
            expect(outputFrames == 22_050,
                   "converter did not preserve 500 ms \(inputRate) Hz/\(inputChannels)ch to 44.1 kHz: \(outputFrames)")
        }
    }

    let unsafeFloatFormat = RuntimePCMFormatDTO(sampleRate: 48_000,
        channelCount: 1, sampleFormat: .float32LE)
    let unsafeFloatConverter = try RuntimePlaybackConverter(input: unsafeFloatFormat,
        deviceSampleRate: 48_000, deviceChannels: 1)
    let unsafeSamples: [Float] = [.nan, .infinity, -.infinity, 2, -2, 0.5]
    let unsafePayload = unsafeSamples.withUnsafeBytes { Data($0) }
    let unsafeHeader = RuntimePCMFrameHeader(payloadByteCount: UInt32(unsafePayload.count),
        streamID: UUID(), sequence: 0, timestampNanoseconds: 0,
        sampleRate: 48_000, frameCount: UInt32(unsafeSamples.count),
        channelCount: 1, sampleFormat: .float32LE)
    let safeOutput = try unsafeFloatConverter.convert(
        RuntimePCMFrame(header: unsafeHeader, payload: unsafePayload))
    let safeSamples = UnsafeBufferPointer(start: safeOutput.0, count: Int(safeOutput.1))
    expect(safeSamples.allSatisfy { $0.isFinite && (-1...1).contains($0) },
           "non-finite or out-of-range Float32 samples reached the playback ring")

    let stereoFormat = RuntimePCMFormatDTO(sampleRate: 48_000, channelCount: 2)
    let stereoPayload = [Int16(16_384), Int16(-16_384)].withUnsafeBytes { Data($0) }
    let stereoHeader = RuntimePCMFrameHeader(payloadByteCount: UInt32(stereoPayload.count),
        streamID: UUID(), sequence: 0, timestampNanoseconds: 0,
        sampleRate: 48_000, frameCount: 1, channelCount: 2)
    let stereoFrame = RuntimePCMFrame(header: stereoHeader, payload: stereoPayload)
    let downmix = try RuntimePlaybackConverter(input: stereoFormat,
        deviceSampleRate: 48_000, deviceChannels: 1).convert(stereoFrame)
    expect(abs(downmix.0[0]) < 0.0001, "stereo downmix did not average left and right")
    let preserve = try RuntimePlaybackConverter(input: stereoFormat,
        deviceSampleRate: 48_000, deviceChannels: 2).convert(stereoFrame)
    expect(preserve.0[0] > 0.49 && preserve.0[1] < -0.49,
        "stereo conversion did not preserve channel identity")

    for inputFormat in RuntimePCMFormatDTO.supportedOutputFormats {
        let inputFrames = inputFormat.sampleRate / 10
        let sampleCount = Int(inputFrames) * Int(inputFormat.channelCount)
        let matrixPayload: Data
        if inputFormat.sampleFormat == .pcmS16LE {
            matrixPayload = [Int16](repeating: 3_000, count: sampleCount)
                .withUnsafeBytes { Data($0) }
        } else {
            matrixPayload = [Float](repeating: 0.125, count: sampleCount)
                .withUnsafeBytes { Data($0) }
        }
        let matrixHeader = RuntimePCMFrameHeader(
            payloadByteCount: UInt32(matrixPayload.count), streamID: UUID(), sequence: 0,
            timestampNanoseconds: 0, sampleRate: inputFormat.sampleRate,
            frameCount: inputFrames, channelCount: inputFormat.channelCount,
            sampleFormat: inputFormat.sampleFormat)
        let matrixFrame = RuntimePCMFrame(header: matrixHeader, payload: matrixPayload)
        for deviceRate in [44_100.0, 48_000.0, 96_000.0] {
            for deviceChannels: UInt32 in [1, 2] {
                let converter = try RuntimePlaybackConverter(input: inputFormat,
                    deviceSampleRate: deviceRate, deviceChannels: deviceChannels)
                let body = try converter.convert(matrixFrame)
                let tail = try converter.drain()
                let expected = UInt32((Double(inputFrames) * deviceRate
                    / Double(inputFormat.sampleRate)).rounded())
                expect(body.1 + tail.1 == expected,
                    "format matrix duration changed for \(inputFormat) -> \(deviceRate)/\(deviceChannels)")
                let bodySamples = UnsafeBufferPointer(start: body.0,
                    count: Int(body.1) * Int(deviceChannels))
                expect(bodySamples.allSatisfy { $0.isFinite && (-1...1).contains($0) },
                    "format matrix emitted invalid samples")
            }
        }
    }

    print("Runtime output core tests passed")
} catch {
    fatalError("Runtime output core test failed: \(error)")
}
