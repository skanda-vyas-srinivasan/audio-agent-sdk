import Foundation

enum CaptureClock {
    /// Compute the full product before division; intermediate UInt64 overflow
    /// occurs after days, well before a nanosecond timestamp becomes too large.
    static func nanoseconds(frames: UInt64, sampleRate: UInt32) -> UInt64 {
        precondition(sampleRate > 0)
        let product = frames.multipliedFullWidth(by: 1_000_000_000)
        let rate = UInt64(sampleRate)
        guard product.high < rate else { return UInt64.max }
        return rate.dividingFullWidth(product).quotient
    }
}

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
