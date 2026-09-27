import Foundation

public struct RuntimePCMFrameFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let discontinuity = Self(rawValue: 1 << 0)
    public static let endOfStream = Self(rawValue: 1 << 1)
    public static let known: Self = [.discontinuity, .endOfStream]
}

public struct RuntimePCMFrameHeader: Equatable, Sendable {
    public static let magic: UInt32 = 0x5358_5043 // "SXPC"
    public static let version: UInt16 = 2
    public static let encodedSize = 64
    public static let maximumPayloadBytes = 512 * 1024

    public let flags: RuntimePCMFrameFlags
    public let payloadByteCount: UInt32
    public let streamID: UUID
    public let sequence: UInt64
    public let timestampNanoseconds: UInt64
    public let sampleRate: UInt32
    public let frameCount: UInt32
    public let channelCount: UInt16
    public let sampleFormat: RuntimeSampleFormatDTO
    public let droppedFramesBefore: UInt32

    public init(flags: RuntimePCMFrameFlags = [], payloadByteCount: UInt32, streamID: UUID,
                sequence: UInt64, timestampNanoseconds: UInt64, sampleRate: UInt32,
                frameCount: UInt32, channelCount: UInt16,
                sampleFormat: RuntimeSampleFormatDTO = .pcmS16LE,
                droppedFramesBefore: UInt32 = 0) {
        self.flags = flags
        self.payloadByteCount = payloadByteCount
        self.streamID = streamID
        self.sequence = sequence
        self.timestampNanoseconds = timestampNanoseconds
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.channelCount = channelCount
        self.sampleFormat = sampleFormat
        self.droppedFramesBefore = droppedFramesBefore
    }

    public var bitsPerChannel: UInt16 { sampleFormat.bitsPerChannel }
}

public struct RuntimePCMFrame: Equatable, Sendable {
    public let header: RuntimePCMFrameHeader
    public let payload: Data
    public init(header: RuntimePCMFrameHeader, payload: Data) {
        self.header = header
        self.payload = payload
    }
}

public enum RuntimePCMFrameCodec {
    public static func encode(header: RuntimePCMFrameHeader, payload: Data) throws -> Data {
        try validate(header: header, payloadCount: payload.count)
        var result = Data(capacity: RuntimePCMFrameHeader.encodedSize + payload.count)
        append(RuntimePCMFrameHeader.magic, to: &result)
        append(RuntimePCMFrameHeader.version, to: &result)
        append(header.flags.rawValue, to: &result)
        append(UInt32(RuntimePCMFrameHeader.encodedSize), to: &result)
        append(header.payloadByteCount, to: &result)
        var uuid = header.streamID.uuid
        withUnsafeBytes(of: &uuid) { result.append(contentsOf: $0) }
        append(header.sequence, to: &result)
        append(header.timestampNanoseconds, to: &result)
        append(header.sampleRate, to: &result)
        append(header.frameCount, to: &result)
        append(header.channelCount, to: &result)
        append(header.sampleFormat.code, to: &result)
        append(header.droppedFramesBefore, to: &result)
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
        let rawFlags: UInt16 = read(data, cursor: &cursor)
        let headerSize: UInt32 = read(data, cursor: &cursor)
        let payloadSize: UInt32 = read(data, cursor: &cursor)
        let uuidBytes = Array(data[cursor..<(cursor + 16)])
        cursor += 16
        let streamID = UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        ))
        let sequence: UInt64 = read(data, cursor: &cursor)
        let timestamp: UInt64 = read(data, cursor: &cursor)
        let sampleRate: UInt32 = read(data, cursor: &cursor)
        let frameCount: UInt32 = read(data, cursor: &cursor)
        let channels: UInt16 = read(data, cursor: &cursor)
        let sampleFormatCode: UInt16 = read(data, cursor: &cursor)
        let droppedFrames: UInt32 = read(data, cursor: &cursor)
        let flags = RuntimePCMFrameFlags(rawValue: rawFlags)

        guard magic == RuntimePCMFrameHeader.magic,
              version == RuntimePCMFrameHeader.version,
              headerSize == RuntimePCMFrameHeader.encodedSize,
              flags.subtracting(.known).isEmpty,
              let sampleFormat = RuntimeSampleFormatDTO.from(code: sampleFormatCode) else {
            throw RuntimeErrorDTO(code: "invalid_pcm_header", message: "PCM frame header contains unsupported values")
        }
        let header = RuntimePCMFrameHeader(flags: flags, payloadByteCount: payloadSize,
            streamID: streamID, sequence: sequence, timestampNanoseconds: timestamp,
            sampleRate: sampleRate, frameCount: frameCount, channelCount: channels,
            sampleFormat: sampleFormat, droppedFramesBefore: droppedFrames)
        try validate(header: header, payloadCount: Int(payloadSize))
        return header
    }

    private static func validate(header: RuntimePCMFrameHeader, payloadCount: Int) throws {
        guard payloadCount == Int(header.payloadByteCount),
              payloadCount <= RuntimePCMFrameHeader.maximumPayloadBytes,
              header.flags.subtracting(.known).isEmpty else {
            throw RuntimeErrorDTO(code: "invalid_pcm_payload", message: "PCM payload or flags are invalid")
        }
        if header.flags.contains(.endOfStream) {
            guard payloadCount == 0, header.frameCount == 0 else {
                throw RuntimeErrorDTO(code: "invalid_pcm_payload", message: "End-of-stream frames cannot contain PCM")
            }
            return
        }
        let bytesPerSample = UInt64(header.sampleFormat.bitsPerChannel / 8)
        let expected = UInt64(header.frameCount) * UInt64(header.channelCount) * bytesPerSample
        guard header.sampleRate > 0, header.frameCount > 0, header.channelCount > 0,
              expected <= UInt64(RuntimePCMFrameHeader.maximumPayloadBytes),
              expected == UInt64(payloadCount) else {
            throw RuntimeErrorDTO(code: "invalid_pcm_payload", message: "PCM format and payload length are inconsistent")
        }
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

/// Bounded incremental decoder for one PCM stream.
public struct RuntimePCMStreamDecoder {
    private var buffer = Data()
    private var readOffset = 0
    private var pendingHeader: RuntimePCMFrameHeader?
    private var lastSequence: UInt64?
    private let expectedStreamID: UUID?
    private var ended = false

    public init(expectedStreamID: UUID? = nil) { self.expectedStreamID = expectedStreamID }

    public mutating func append(_ bytes: Data) throws -> [RuntimePCMFrame] {
        guard !ended else {
            throw RuntimeErrorDTO(code: "pcm_after_eos", message: "PCM bytes arrived after end-of-stream")
        }
        let maximumBuffered = RuntimePCMFrameHeader.maximumPayloadBytes + RuntimePCMFrameHeader.encodedSize
        compactIfNeeded(force: buffer.count + bytes.count > maximumBuffered)
        let bufferedBytes = buffer.count - readOffset
        guard bytes.count <= maximumBuffered,
              bufferedBytes <= maximumBuffered - bytes.count else {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
            pendingHeader = nil
            throw RuntimeErrorDTO(code: "pcm_buffer_overflow", message: "PCM stream exceeded the frame size limit")
        }
        buffer.append(bytes)
        var frames: [RuntimePCMFrame] = []
        while true {
            if pendingHeader == nil {
                guard buffer.count - readOffset >= RuntimePCMFrameHeader.encodedSize else { break }
                let headerRange = readOffset..<(readOffset + RuntimePCMFrameHeader.encodedSize)
                let header = try RuntimePCMFrameCodec.decodeHeader(Data(buffer[headerRange]))
                if let expectedStreamID, header.streamID != expectedStreamID {
                    throw RuntimeErrorDTO(code: "stream_id_mismatch", message: "PCM frame belongs to a different stream")
                }
                if let lastSequence {
                    guard header.sequence > lastSequence else {
                        throw RuntimeErrorDTO(code: "invalid_pcm_sequence", message: "PCM sequence did not advance")
                    }
                    if header.sequence != lastSequence &+ 1,
                       !header.flags.contains(.discontinuity) {
                        throw RuntimeErrorDTO(code: "unmarked_pcm_gap", message: "PCM sequence gap lacks a discontinuity flag")
                    }
                }
                pendingHeader = header
                readOffset += RuntimePCMFrameHeader.encodedSize
            }
            guard let header = pendingHeader,
                  buffer.count - readOffset >= Int(header.payloadByteCount) else { break }
            let payloadEnd = readOffset + Int(header.payloadByteCount)
            let payload = Data(buffer[readOffset..<payloadEnd])
            readOffset = payloadEnd
            pendingHeader = nil
            lastSequence = header.sequence
            frames.append(RuntimePCMFrame(header: header, payload: payload))
            if header.flags.contains(.endOfStream) {
                ended = true
                if buffer.count != readOffset {
                    throw RuntimeErrorDTO(code: "pcm_after_eos", message: "PCM bytes followed end-of-stream")
                }
                break
            }
        }
        compactIfNeeded(force: readOffset == buffer.count)
        return frames
    }

    public mutating func finish(requireEndOfStream: Bool = false) throws {
        guard buffer.count == readOffset, pendingHeader == nil else {
            throw RuntimeErrorDTO(code: "truncated_pcm_stream", message: "PCM stream ended mid-frame")
        }
        if requireEndOfStream, !ended {
            throw RuntimeErrorDTO(code: "unexpected_pcm_eof", message: "PCM stream ended without an end-of-stream frame")
        }
    }

    private mutating func compactIfNeeded(force: Bool = false) {
        guard readOffset > 0,
              force || readOffset >= 64 * 1_024 || readOffset * 2 >= buffer.count else { return }
        if readOffset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
        } else {
            buffer.removeSubrange(0..<readOffset)
        }
        readOffset = 0
    }
}
