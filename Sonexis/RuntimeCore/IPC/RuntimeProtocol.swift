import Foundation

public enum RuntimeSourceKindDTO: String, Codable, Sendable {
    case application
    case microphone
    case systemMix = "system_mix"
    case remote
    case virtual
}

public struct RuntimePCMFormatDTO: Codable, Equatable, Sendable {
    public let sampleRate: UInt32
    public let channelCount: UInt16
    public let bitsPerChannel: UInt16
    public let encoding: String
    public let interleaved: Bool

    public init(sampleRate: UInt32, channelCount: UInt16, bitsPerChannel: UInt16,
                encoding: String = "signed_integer_little_endian", interleaved: Bool = true) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitsPerChannel = bitsPerChannel
        self.encoding = encoding
        self.interleaved = interleaved
    }

    public static let runtimeDefault = Self(sampleRate: 16_000, channelCount: 1, bitsPerChannel: 16)
}

public struct RuntimeSourceDTO: Codable, Equatable, Sendable {
    public let id: String
    public let kind: RuntimeSourceKindDTO
    public let processID: Int32?
    public let processIDs: [Int32]?
    public let bundleIdentifier: String?
    public let name: String
    public let isActive: Bool
    public let isProducingAudio: Bool?
    public let nativeFormat: RuntimePCMFormatDTO?

    public init(id: String, kind: RuntimeSourceKindDTO = .application, processID: Int32? = nil,
                processIDs: [Int32] = [],
                bundleIdentifier: String? = nil, name: String, isActive: Bool,
                isProducingAudio: Bool? = nil, nativeFormat: RuntimePCMFormatDTO? = nil) {
        self.id = id
        self.kind = kind
        self.processID = processID
        self.processIDs = processIDs.isEmpty ? processID.map { [$0] } : processIDs.sorted()
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.isActive = isActive
        self.isProducingAudio = isProducingAudio
        self.nativeFormat = nativeFormat
    }
}

public enum RuntimeSessionStateDTO: String, Codable, Sendable {
    case starting
    case capturing
    case stopped
    case failed
}

public struct RuntimeSessionDTO: Codable, Equatable, Sendable {
    public let id: String
    public let sourceID: String
    public let state: RuntimeSessionStateDTO
    public let format: RuntimePCMFormatDTO
    public let dataSocketPath: String
    public let startedAtNanoseconds: UInt64
    public let framesForwarded: UInt64
    public let droppedFrames: UInt64

    public init(id: String, sourceID: String, state: RuntimeSessionStateDTO,
                format: RuntimePCMFormatDTO, dataSocketPath: String,
                startedAtNanoseconds: UInt64, framesForwarded: UInt64 = 0,
                droppedFrames: UInt64 = 0) {
        self.id = id
        self.sourceID = sourceID
        self.state = state
        self.format = format
        self.dataSocketPath = dataSocketPath
        self.startedAtNanoseconds = startedAtNanoseconds
        self.framesForwarded = framesForwarded
        self.droppedFrames = droppedFrames
    }
}

public enum RuntimeCommandName: String, Codable, Sendable {
    case listSources = "list_sources"
    case startCapture = "start_capture"
    case stopCapture = "stop_capture"
    case sessionStatus = "session_status"
    case ping
}

/// One JSON object followed by a newline. Fields irrelevant to a command must be omitted.
public struct RuntimeCommand: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public let requestID: String
    public let command: RuntimeCommandName
    public let sourceID: String?
    public let sessionID: String?

    public init(version: Int = currentVersion, requestID: String = UUID().uuidString,
                command: RuntimeCommandName, sourceID: String? = nil, sessionID: String? = nil) {
        self.version = version
        self.requestID = requestID
        self.command = command
        self.sourceID = sourceID
        self.sessionID = sessionID
    }
}

public struct RuntimeErrorDTO: Codable, Equatable, LocalizedError, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { "\(code): \(message)" }
}

public struct RuntimeResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: String
    public let ok: Bool
    public let sources: [RuntimeSourceDTO]?
    public let session: RuntimeSessionDTO?
    public let message: String?
    public let error: RuntimeErrorDTO?

    public init(requestID: String, sources: [RuntimeSourceDTO]) {
        version = RuntimeCommand.currentVersion; self.requestID = requestID; ok = true
        self.sources = sources; session = nil; message = nil; error = nil
    }

    public init(requestID: String, session: RuntimeSessionDTO) {
        version = RuntimeCommand.currentVersion; self.requestID = requestID; ok = true
        sources = nil; self.session = session; message = nil; error = nil
    }

    public init(requestID: String, message: String) {
        version = RuntimeCommand.currentVersion; self.requestID = requestID; ok = true
        sources = nil; session = nil; self.message = message; error = nil
    }

    public init(requestID: String, error: RuntimeErrorDTO) {
        version = RuntimeCommand.currentVersion; self.requestID = requestID; ok = false
        sources = nil; session = nil; message = nil; self.error = error
    }
}

public enum RuntimeProtocolCodec {
    public static let maximumControlMessageBytes = 64 * 1024

    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let payload = try JSONEncoder().encode(value)
        guard payload.count <= maximumControlMessageBytes else {
            throw RuntimeErrorDTO(code: "message_too_large", message: "Control message exceeds \(maximumControlMessageBytes) bytes")
        }
        var line = payload
        line.append(0x0A)
        return line
    }

    public static func decodeLine<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        guard !line.isEmpty, line.count <= maximumControlMessageBytes else {
            throw RuntimeErrorDTO(code: "invalid_message_size", message: "Control message is empty or too large")
        }
        let body = line.last == 0x0A ? line.dropLast() : line[...]
        guard !body.isEmpty, !body.contains(0) else {
            throw RuntimeErrorDTO(code: "malformed_json", message: "Control message is not valid JSON")
        }
        do { return try JSONDecoder().decode(type, from: Data(body)) }
        catch { throw RuntimeErrorDTO(code: "malformed_json", message: "Control message is not valid JSON: \(error.localizedDescription)") }
    }
}

/// Incremental bounded parser for stream-oriented sockets.
public struct RuntimeNDJSONParser {
    private var buffer = Data()
    public init() {}

    public mutating func append(_ data: Data) throws -> [Data] {
        guard buffer.count <= RuntimeProtocolCodec.maximumControlMessageBytes - data.count else {
            buffer.removeAll(keepingCapacity: true)
            throw RuntimeErrorDTO(code: "message_too_large", message: "Control message has no newline within the size limit")
        }
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let end = buffer.index(after: newline)
            lines.append(buffer[..<end])
            buffer.removeSubrange(..<end)
        }
        return lines
    }
}
