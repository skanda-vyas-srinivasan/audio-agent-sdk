import CoreAudio
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

do {
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
        let sampleCount = Int(converted.1) * 2
        let values = UnsafeBufferPointer(start: converted.0, count: sampleCount)
        expect(values.contains { abs($0) > 0.01 }, "converter emitted silence for \(format)")
    }

    print("Runtime output core tests passed")
} catch {
    fatalError("Runtime output core test failed: \(error)")
}
