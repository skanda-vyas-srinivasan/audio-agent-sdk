import Foundation

public struct RuntimePCMFrameHeader: Equatable, Sendable {
    public static let magic: UInt32 = 0x5358_5043 // "SXPC"
    public static let version: UInt16 = 1
    public static let encodedSize = 44
    public static let maximumPayloadBytes = 4 * 1024 * 1024

    public let payloadByteCount: UInt32
    public let sequence: UInt64
    public let timestampNanoseconds: UInt64
    public let sampleRate: UInt32
    public let frameCount: UInt32
    public let channelCount: UInt16
    public let bitsPerChannel: UInt16

    public init(payloadByteCount: UInt32, sequence: UInt64, timestampNanoseconds: UInt64,
                sampleRate: UInt32, frameCount: UInt32, channelCount: UInt16,
                bitsPerChannel: UInt16) {
        self.payloadByteCount = payloadByteCount
        self.sequence = sequence
        self.timestampNanoseconds = timestampNanoseconds
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.channelCount = channelCount
        self.bitsPerChannel = bitsPerChannel
    }
}

public struct RuntimePCMFrame: Equatable, Sendable {
    public let header: RuntimePCMFrameHeader
    public let payload: Data
    public init(header: RuntimePCMFrameHeader, payload: Data) { self.header = header; self.payload = payload }
}

public enum RuntimePCMFrameCodec {
    public static func encode(header: RuntimePCMFrameHeader, payload: Data) throws -> Data {
        guard payload.count == Int(header.payloadByteCount), payload.count <= RuntimePCMFrameHeader.maximumPayloadBytes else {
            throw RuntimeErrorDTO(code: "invalid_pcm_payload", message: "PCM payload length does not match its header")
        }
        var result = Data(capacity: RuntimePCMFrameHeader.encodedSize + payload.count)
        append(RuntimePCMFrameHeader.magic, to: &result)
        append(RuntimePCMFrameHeader.version, to: &result)
        append(UInt16(0), to: &result) // reserved flags
        append(UInt32(RuntimePCMFrameHeader.encodedSize), to: &result)
        append(header.payloadByteCount, to: &result)
        append(header.sequence, to: &result)
        append(header.timestampNanoseconds, to: &result)
        append(header.sampleRate, to: &result)
        append(header.frameCount, to: &result)
        append(header.channelCount, to: &result)
        append(header.bitsPerChannel, to: &result)
        result.append(payload)
        return result
    }

    public static func decodeHeader(_ data: Data) throws -> RuntimePCMFrameHeader {
        guard data.count == RuntimePCMFrameHeader.encodedSize else {
            throw RuntimeErrorDTO(code: "invalid_pcm_header", message: "PCM header must be exactly \(RuntimePCMFrameHeader.encodedSize) bytes")
        }
        var cursor = 0
        let magic: UInt32 = read(data, cursor: &cursor)
        let version: UInt16 = read(data, cursor: &cursor)
        let _: UInt16 = read(data, cursor: &cursor)
        let headerSize: UInt32 = read(data, cursor: &cursor)
        let payloadSize: UInt32 = read(data, cursor: &cursor)
        let sequence: UInt64 = read(data, cursor: &cursor)
        let timestamp: UInt64 = read(data, cursor: &cursor)
        let sampleRate: UInt32 = read(data, cursor: &cursor)
        let frameCount: UInt32 = read(data, cursor: &cursor)
        let channels: UInt16 = read(data, cursor: &cursor)
        let bits: UInt16 = read(data, cursor: &cursor)
        guard magic == RuntimePCMFrameHeader.magic, version == RuntimePCMFrameHeader.version,
              headerSize == RuntimePCMFrameHeader.encodedSize,
              payloadSize <= RuntimePCMFrameHeader.maximumPayloadBytes,
              sampleRate > 0, frameCount > 0, channels > 0, bits > 0 else {
            throw RuntimeErrorDTO(code: "invalid_pcm_header", message: "PCM frame header contains unsupported or invalid values")
        }
        return RuntimePCMFrameHeader(payloadByteCount: payloadSize, sequence: sequence,
            timestampNanoseconds: timestamp, sampleRate: sampleRate, frameCount: frameCount,
            channelCount: channels, bitsPerChannel: bits)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func read<T: FixedWidthInteger>(_ data: Data, cursor: inout Int) -> T {
        let size = MemoryLayout<T>.size
        let value = data[cursor..<(cursor + size)].reduce(T.zero) { ($0 << 8) | T($1) }
        cursor += size
        return value
    }
}

/// Bounded incremental decoder for PCM socket streams.
public struct RuntimePCMStreamDecoder {
    private var buffer = Data()
    private var pendingHeader: RuntimePCMFrameHeader?
    public init() {}

    public mutating func append(_ bytes: Data) throws -> [RuntimePCMFrame] {
        let maximumBuffered = RuntimePCMFrameHeader.maximumPayloadBytes + RuntimePCMFrameHeader.encodedSize
        guard buffer.count <= maximumBuffered - bytes.count else {
            buffer.removeAll(keepingCapacity: true); pendingHeader = nil
            throw RuntimeErrorDTO(code: "pcm_buffer_overflow", message: "PCM stream exceeded the frame size limit")
        }
        buffer.append(bytes)
        var frames: [RuntimePCMFrame] = []
        while true {
            if pendingHeader == nil {
                guard buffer.count >= RuntimePCMFrameHeader.encodedSize else { break }
                pendingHeader = try RuntimePCMFrameCodec.decodeHeader(Data(buffer.prefix(RuntimePCMFrameHeader.encodedSize)))
                buffer.removeFirst(RuntimePCMFrameHeader.encodedSize)
            }
            guard let header = pendingHeader, buffer.count >= Int(header.payloadByteCount) else { break }
            let payload = Data(buffer.prefix(Int(header.payloadByteCount)))
            buffer.removeFirst(Int(header.payloadByteCount))
            pendingHeader = nil
            frames.append(RuntimePCMFrame(header: header, payload: payload))
        }
        return frames
    }
}
