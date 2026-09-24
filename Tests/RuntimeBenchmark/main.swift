import Foundation

private func elapsedSeconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
}

let inputFrames: UInt32 = 2_048
var samples = [Float](repeating: 0, count: Int(inputFrames) * 2)
for frame in 0..<Int(inputFrames) {
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

print("conversion_format,batches,input_audio_seconds,elapsed_seconds,realtime_factor,output_megabytes")
for format in formats {
    let normalizer = try RuntimeAudioNormalizer(sampleRate: 48_000, channels: 2, output: format)
    let batches = 2_000
    var bytes = 0
    let started = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<batches {
        bytes += try samples.withUnsafeBufferPointer { buffer in
            try normalizer.convert(samples: buffer.baseAddress!, frameCount: inputFrames).count
        }
    }
    let elapsed = elapsedSeconds(since: started)
    let audioSeconds = Double(inputFrames * UInt32(batches)) / 48_000
    let name = "\(format.sampleFormat.rawValue)-\(format.sampleRate)-\(format.channelCount)ch"
    print("\(name),\(batches),\(String(format: "%.3f", audioSeconds)),\(String(format: "%.6f", elapsed)),\(String(format: "%.1f", audioSeconds / elapsed)),\(String(format: "%.3f", Double(bytes) / 1_000_000))")
}

let streamID = UUID()
let payload = Data(repeating: 0x42, count: 320)
let header = RuntimePCMFrameHeader(payloadByteCount: 320, streamID: streamID,
    sequence: 0, timestampNanoseconds: 0, sampleRate: 16_000,
    frameCount: 160, channelCount: 1)
let iterations = 100_000
var encodedBytes = 0
let codecStarted = DispatchTime.now().uptimeNanoseconds
for _ in 0..<iterations {
    let packet = try RuntimePCMFrameCodec.encode(header: header, payload: payload)
    _ = try RuntimePCMFrameCodec.decodeHeader(Data(packet.prefix(64)))
    encodedBytes += packet.count
}
let codecElapsed = elapsedSeconds(since: codecStarted)
print("frame_codec_iterations=\(iterations) elapsed_seconds=\(String(format: "%.6f", codecElapsed)) packets_per_second=\(String(format: "%.0f", Double(iterations) / codecElapsed)) throughput_megabytes_per_second=\(String(format: "%.1f", Double(encodedBytes) / codecElapsed / 1_000_000))")
