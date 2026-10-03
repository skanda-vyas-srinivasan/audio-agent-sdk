import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

do {
    for rate: UInt32 in [16_000, 24_000, 48_000] {
        let boundary = UInt64.max / 1_000_000_000
        for frames in [UInt64(0), UInt64(rate), boundary - 1, boundary, boundary + 1,
                       UInt64(rate) * 60 * 60 * 24 * 30] {
            let expected = (frames / UInt64(rate)) * 1_000_000_000
                + (frames % UInt64(rate)) * 1_000_000_000 / UInt64(rate)
            expect(CaptureClock.nanoseconds(frames: frames, sampleRate: rate) == expected,
                   "capture clock changed media time at \(frames) frames / \(rate) Hz")
        }
        expect(CaptureClock.nanoseconds(frames: UInt64.max, sampleRate: rate) == UInt64.max,
               "unrepresentable capture time must saturate rather than trap or wrap")
    }
    let id = AudioSource.applicationID(bundleIdentifier: "com.example.player")
    let first = AudioSource(id: id, kind: .application, name: "Player",
        bundleIdentifier: "com.example.player", processIdentifiers: [400, 200], state: .active)
    let restarted = AudioSource(id: id, kind: .application, name: "Player",
        bundleIdentifier: "com.example.player", processIdentifiers: [900], state: .active)
    expect(first.id == restarted.id, "application source identity changed with PID")
    expect(first.processIdentifiers == [200, 400], "source PIDs were not normalized")

    for (sampleRate, channels) in [
        (Double.nan, UInt32(2)), (Double.infinity, UInt32(2)),
        (7_999.0, UInt32(2)), (192_001.0, UInt32(2)),
        (48_000.0, UInt32(0)), (48_000.0, UInt32(9)),
    ] {
        do {
            _ = try RuntimeAudioNormalizer(sampleRate: sampleRate, channels: channels)
            fatalError("unsafe native capture format was accepted: \(sampleRate)/\(channels)")
        } catch AudioNormalizationError.unsupportedInputFormat {
            // Expected: reject before AVAudioConverter or ring allocation.
        }
    }
    try RuntimeAudioNormalizer.validateInputFormat(sampleRate: 8_000, channels: 1)
    try RuntimeAudioNormalizer.validateInputFormat(sampleRate: 192_000, channels: 8)

    let nativeFrames: UInt32 = 4_800
    var samples = [Float](repeating: 0, count: Int(nativeFrames) * 2)
    for frame in 0..<Int(nativeFrames) {
        let value = sin(Float(frame) * 2 * .pi * 440 / 48_000) * 0.5
        samples[frame * 2] = value
        samples[frame * 2 + 1] = value
    }
    let formats = [
        RuntimePCMFormat(sampleRate: 16_000, channelCount: 1, sampleFormat: .pcmS16LE),
        RuntimePCMFormat(sampleRate: 24_000, channelCount: 1, sampleFormat: .pcmS16LE),
        RuntimePCMFormat(sampleRate: 48_000, channelCount: 1, sampleFormat: .pcmS16LE),
        RuntimePCMFormat(sampleRate: 48_000, channelCount: 2, sampleFormat: .pcmS16LE),
        RuntimePCMFormat(sampleRate: 48_000, channelCount: 1, sampleFormat: .float32LE),
        RuntimePCMFormat(sampleRate: 48_000, channelCount: 2, sampleFormat: .float32LE),
    ]
    for format in formats {
        let normalizer = try RuntimeAudioNormalizer(sampleRate: 48_000, channels: 2, output: format)
        var pcm = Data()
        var offset = 0
        while offset < Int(nativeFrames) {
            let chunkFrames = min(2_048, Int(nativeFrames) - offset)
            try samples.withUnsafeBufferPointer { buffer in
                pcm.append(try normalizer.convert(
                    samples: buffer.baseAddress!.advanced(by: offset * 2),
                    frameCount: UInt32(chunkFrames)
                ))
            }
            offset += chunkFrames
        }
        let outputFrames = pcm.count / format.bytesPerFrame
        let expectedFrames = Int(format.sampleRate / 10)
        expect(((expectedFrames - 12)...(expectedFrames + 12)).contains(outputFrames),
               "normalizer did not preserve 100 ms duration for \(format)")
        expect(pcm.count % format.bytesPerFrame == 0, "output was not sample aligned")
        expect(!pcm.allSatisfy { $0 == 0 }, "normalizer emitted silence for a tone")
    }

    print("Runtime core tests passed")
} catch {
    fatalError("Runtime core test failed: \(error)")
}
