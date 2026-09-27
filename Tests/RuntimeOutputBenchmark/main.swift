import Foundation

private func elapsedSeconds(_ started: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
}

private func benchmarkConversion(input: RuntimePCMFormatDTO, deviceRate: Double,
                                 deviceChannels: UInt32, iterations: Int) throws {
    let frameCount = input.sampleRate / 50 // 20 ms
    let sampleCount = Int(frameCount) * Int(input.channelCount)
    let payload: Data
    if input.sampleFormat == .pcmS16LE {
        payload = [Int16](repeating: 4_096, count: sampleCount).withUnsafeBytes { Data($0) }
    } else {
        payload = [Float](repeating: 0.125, count: sampleCount).withUnsafeBytes { Data($0) }
    }
    let streamID = UUID()
    let converter = try RuntimePlaybackConverter(input: input,
        deviceSampleRate: deviceRate, deviceChannels: deviceChannels)
    var produced: UInt64 = 0
    let started = DispatchTime.now().uptimeNanoseconds
    for sequence in 0..<iterations {
        let header = RuntimePCMFrameHeader(payloadByteCount: UInt32(payload.count),
            streamID: streamID, sequence: UInt64(sequence),
            timestampNanoseconds: UInt64(sequence) * 20_000_000,
            sampleRate: input.sampleRate, frameCount: frameCount,
            channelCount: input.channelCount, sampleFormat: input.sampleFormat)
        produced &+= UInt64(try converter.convert(
            RuntimePCMFrame(header: header, payload: payload)).1)
    }
    produced &+= UInt64(try converter.drain().1)
    let wall = elapsedSeconds(started)
    let audioSeconds = Double(iterations) * 0.02
    print("conversion input=\(input.sampleFormat.rawValue)/\(input.sampleRate)/\(input.channelCount) "
        + "device=\(Int(deviceRate))/\(deviceChannels) audio_seconds=\(audioSeconds) "
        + "wall_seconds=\(String(format: "%.6f", wall)) "
        + "realtime_factor=\(String(format: "%.1f", audioSeconds / wall)) "
        + "device_frames=\(produced)")
}

private func benchmarkRing(iterations: Int) throws {
    let frames: UInt32 = 480
    let samples = [Float](repeating: 0.125, count: Int(frames) * 2)
    var output = [Float](repeating: 0, count: samples.count)
    let ring = try RealtimeRingBuffer(capacityFrames: 960, channels: 2)
    let started = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations {
        let written = samples.withUnsafeBufferPointer {
            ring.writeInterleaved($0.baseAddress!, frames: frames)
        }
        let read = output.withUnsafeMutableBufferPointer {
            ring.readInterleaved($0.baseAddress!, frames: frames)
        }
        precondition(written == frames && read == frames)
    }
    let wall = elapsedSeconds(started)
    let audioSeconds = Double(iterations) * 0.01
    print("ring channels=2 audio_seconds=\(audioSeconds) "
        + "wall_seconds=\(String(format: "%.6f", wall)) "
        + "realtime_factor=\(String(format: "%.1f", audioSeconds / wall)) "
        + "frames=\(UInt64(iterations) * UInt64(frames))")
}

do {
    print("runtime_output_benchmark os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    try benchmarkConversion(input: RuntimePCMFormatDTO(sampleRate: 24_000, channelCount: 1),
        deviceRate: 48_000, deviceChannels: 2, iterations: 10_000)
    try benchmarkConversion(input: RuntimePCMFormatDTO(sampleRate: 48_000, channelCount: 2),
        deviceRate: 48_000, deviceChannels: 2, iterations: 10_000)
    try benchmarkConversion(input: RuntimePCMFormatDTO(sampleRate: 48_000, channelCount: 1,
        sampleFormat: .float32LE), deviceRate: 44_100, deviceChannels: 2, iterations: 10_000)
    try benchmarkRing(iterations: 20_000)
} catch {
    fatalError("Runtime output benchmark failed: \(error)")
}
