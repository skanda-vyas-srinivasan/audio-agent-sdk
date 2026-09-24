import Foundation

struct RuntimePCMFormat: Codable, Equatable, Sendable {
    let sampleRate: UInt32
    let channelCount: UInt16
    let bitsPerChannel: UInt16
    let isSignedInteger: Bool
    let isLittleEndian: Bool

    static let pcm16Mono16kHz = RuntimePCMFormat(
        sampleRate: 16_000,
        channelCount: 1,
        bitsPerChannel: 16,
        isSignedInteger: true,
        isLittleEndian: true
    )

    var bytesPerFrame: Int {
        Int(channelCount) * Int(bitsPerChannel / 8)
    }
}

/// One immutable, normalized PCM packet. `timestampNanoseconds` is relative to
/// session start and advances according to the delivered output sample count.
struct AudioFrame: Sendable {
    let sequence: UInt64
    let timestampNanoseconds: UInt64
    let frameCount: UInt32
    let format: RuntimePCMFormat
    let pcm: Data
}

