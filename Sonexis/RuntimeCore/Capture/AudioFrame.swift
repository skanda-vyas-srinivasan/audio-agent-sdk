import Foundation

struct RuntimePCMFormat: Codable, Equatable, Sendable {
    enum SampleFormat: String, Codable, Sendable {
        case pcmS16LE = "pcm_s16le"
        case float32LE = "float32_le"

        var bitsPerChannel: UInt16 { self == .pcmS16LE ? 16 : 32 }
    }

    let sampleRate: UInt32
    let channelCount: UInt16
    let sampleFormat: SampleFormat

    static let pcm16Mono16kHz = RuntimePCMFormat(
        sampleRate: 16_000,
        channelCount: 1,
        sampleFormat: .pcmS16LE
    )

    var bitsPerChannel: UInt16 { sampleFormat.bitsPerChannel }

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
    let discontinuity: Bool
    let droppedFramesBefore: UInt32
}
