import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

do {
    let id = AudioSource.applicationID(bundleIdentifier: "com.example.player")
    let first = AudioSource(id: id, kind: .application, name: "Player",
        bundleIdentifier: "com.example.player", processIdentifiers: [400, 200], state: .active)
    let restarted = AudioSource(id: id, kind: .application, name: "Player",
        bundleIdentifier: "com.example.player", processIdentifiers: [900], state: .active)
    expect(first.id == restarted.id, "application source identity changed with PID")
    expect(first.processIdentifiers == [200, 400], "source PIDs were not normalized")

    let normalizer = try RuntimeAudioNormalizer(sampleRate: 48_000, channels: 2)
    let nativeFrames: UInt32 = 4_800
    var samples = [Float](repeating: 0, count: Int(nativeFrames) * 2)
    for frame in 0..<Int(nativeFrames) {
        let value = sin(Float(frame) * 2 * .pi * 440 / 48_000) * 0.5
        samples[frame * 2] = value
        samples[frame * 2 + 1] = value
    }
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
    let outputFrames = pcm.count / RuntimePCMFormat.pcm16Mono16kHz.bytesPerFrame
    expect((1_590...1_610).contains(outputFrames), "normalizer did not preserve 100 ms duration")
    expect(pcm.count % 2 == 0, "PCM16 output was not sample aligned")
    expect(!pcm.allSatisfy { $0 == 0 }, "normalizer emitted silence for a tone")

    print("Runtime core tests passed")
} catch {
    fatalError("Runtime core test failed: \(error)")
}
