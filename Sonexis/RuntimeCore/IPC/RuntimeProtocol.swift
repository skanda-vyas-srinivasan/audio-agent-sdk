import Foundation

public enum RuntimeProtocolInfo {
    public static let protocolVersion = 2
    public static let runtimeVersion = "0.2.0"
    public static let capabilities = [
        "application_sources", "capture_sessions", "event_stream", "format_negotiation",
        "multiple_sessions", "pcm_v2", "runtime_diagnostics",
    ]
}

public enum RuntimeSourceKindDTO: String, Codable, Sendable {
    case application
    case microphone
    case systemMix = "system_mix"
    case remote
    case virtual
}

public enum RuntimeSourceProcessStateDTO: String, Codable, Sendable {
    case running
    case stopped
    case unknown
}

public enum RuntimeSampleFormatDTO: String, Codable, CaseIterable, Sendable {
    case pcmS16LE = "pcm_s16le"
    case float32LE = "float32_le"

    public var code: UInt16 { self == .pcmS16LE ? 1 : 2 }
    public var bitsPerChannel: UInt16 { self == .pcmS16LE ? 16 : 32 }
    public static func from(code: UInt16) -> Self? { allCases.first { $0.code == code } }
}

public struct RuntimePCMFormatDTO: Codable, Equatable, Hashable, Sendable {
    public let sampleRate: UInt32
    public let channelCount: UInt16
    public let sampleFormat: RuntimeSampleFormatDTO
    public let interleaved: Bool

    public init(sampleRate: UInt32, channelCount: UInt16,
                sampleFormat: RuntimeSampleFormatDTO = .pcmS16LE,
                interleaved: Bool = true) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.sampleFormat = sampleFormat
        self.interleaved = interleaved
    }

    public var bitsPerChannel: UInt16 { sampleFormat.bitsPerChannel }
    public var bytesPerFrame: Int { Int(channelCount) * Int(bitsPerChannel / 8) }

    public static let runtimeDefault = Self(sampleRate: 16_000, channelCount: 1)
    public static let supported: [Self] = [
        .runtimeDefault,
        Self(sampleRate: 24_000, channelCount: 1),
        Self(sampleRate: 48_000, channelCount: 1),
        Self(sampleRate: 48_000, channelCount: 2),
        Self(sampleRate: 48_000, channelCount: 1, sampleFormat: .float32LE),
        Self(sampleRate: 48_000, channelCount: 2, sampleFormat: .float32LE),
    ]
    public var isSupported: Bool { Self.supported.contains(self) }
}

public struct RuntimeSourceDTO: Codable, Equatable, Sendable {
    public let id: String
    public let kind: RuntimeSourceKindDTO
    public let processID: Int32?
    public let processIDs: [Int32]
    public let bundleIdentifier: String?
    public let name: String
    public let processState: RuntimeSourceProcessStateDTO
    public let isAvailable: Bool
    public let isProducingAudio: Bool?
    public let nativeFormat: RuntimePCMFormatDTO?

    public init(id: String, kind: RuntimeSourceKindDTO = .application, processID: Int32? = nil,
                processIDs: [Int32] = [], bundleIdentifier: String? = nil, name: String,
                isActive: Bool = true, isAvailable: Bool? = nil,
                isProducingAudio: Bool? = nil, nativeFormat: RuntimePCMFormatDTO? = nil) {
        self.id = id
        self.kind = kind
        self.processID = processID ?? processIDs.sorted().first
        self.processIDs = processIDs.isEmpty ? processID.map { [$0] } ?? [] : processIDs.sorted()
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        processState = isActive ? .running : .stopped
        self.isAvailable = isAvailable ?? isActive
        self.isProducingAudio = isProducingAudio
        self.nativeFormat = nativeFormat
    }

    public var isActive: Bool { processState == .running }

    // JSONEncoder's built-in snake-case strategy renders acronym plurals as
    // `process_i_ds`. Pin this one public wire key to the documented spelling.
    private enum EncodingKeys: String, CodingKey {
        case id, kind, processID, processIDs = "process_ids", bundleIdentifier, name
        case processState, isAvailable, isProducingAudio, nativeFormat
    }
    private enum DecodingKeys: String, CodingKey {
        case id, kind, processID, processIDs, bundleIdentifier, name
        case processState, isAvailable, isProducingAudio, nativeFormat
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(RuntimeSourceKindDTO.self, forKey: .kind)
        processID = try container.decodeIfPresent(Int32.self, forKey: .processID)
        processIDs = try container.decode([Int32].self, forKey: .processIDs)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        name = try container.decode(String.self, forKey: .name)
        processState = try container.decode(RuntimeSourceProcessStateDTO.self, forKey: .processState)
        isAvailable = try container.decode(Bool.self, forKey: .isAvailable)
        isProducingAudio = try container.decodeIfPresent(Bool.self, forKey: .isProducingAudio)
        nativeFormat = try container.decodeIfPresent(RuntimePCMFormatDTO.self, forKey: .nativeFormat)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: EncodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(processID, forKey: .processID)
        try container.encode(processIDs, forKey: .processIDs)
        try container.encodeIfPresent(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(name, forKey: .name)
        try container.encode(processState, forKey: .processState)
        try container.encode(isAvailable, forKey: .isAvailable)
        try container.encodeIfPresent(isProducingAudio, forKey: .isProducingAudio)
        try container.encodeIfPresent(nativeFormat, forKey: .nativeFormat)
    }
}

public enum RuntimeSessionStateDTO: String, Codable, Sendable {
    case starting
    case capturing
    case stopped
    case failed
}

public struct RuntimeSessionMetricsDTO: Codable, Equatable, Sendable {
    public let captureCallbacks: UInt64
    public let nativeFramesReceived: UInt64
    public let normalizedFramesDelivered: UInt64
    public let ringDroppedFrames: UInt64
    public let deliveryDroppedFrames: UInt64
    public let conversionBatches: UInt64
    public let conversionNanoseconds: UInt64
    public let ringBacklogFrames: UInt32
    public let framesForwarded: UInt64
    public let queueDroppedFrames: UInt64
    public let noSubscriberFrames: UInt64
    public let slowConsumerDisconnects: UInt64
    public let bytesTransmitted: UInt64
    public let connectedSubscribers: Int
    public let dataQueueHighWaterMark: Int

    public init(captureCallbacks: UInt64 = 0, nativeFramesReceived: UInt64 = 0,
                normalizedFramesDelivered: UInt64 = 0, ringDroppedFrames: UInt64 = 0,
                deliveryDroppedFrames: UInt64 = 0, conversionBatches: UInt64 = 0,
                conversionNanoseconds: UInt64 = 0, ringBacklogFrames: UInt32 = 0,
                framesForwarded: UInt64 = 0, queueDroppedFrames: UInt64 = 0,
                noSubscriberFrames: UInt64 = 0, slowConsumerDisconnects: UInt64 = 0,
                bytesTransmitted: UInt64 = 0, connectedSubscribers: Int = 0,
                dataQueueHighWaterMark: Int = 0) {
        self.captureCallbacks = captureCallbacks
        self.nativeFramesReceived = nativeFramesReceived
        self.normalizedFramesDelivered = normalizedFramesDelivered
        self.ringDroppedFrames = ringDroppedFrames
        self.deliveryDroppedFrames = deliveryDroppedFrames
        self.conversionBatches = conversionBatches
        self.conversionNanoseconds = conversionNanoseconds
        self.ringBacklogFrames = ringBacklogFrames
        self.framesForwarded = framesForwarded
        self.queueDroppedFrames = queueDroppedFrames
        self.noSubscriberFrames = noSubscriberFrames
        self.slowConsumerDisconnects = slowConsumerDisconnects
        self.bytesTransmitted = bytesTransmitted
        self.connectedSubscribers = connectedSubscribers
        self.dataQueueHighWaterMark = dataQueueHighWaterMark
    }

    public var droppedFrames: UInt64 {
        ringDroppedFrames + deliveryDroppedFrames + queueDroppedFrames + noSubscriberFrames
    }

    public var averageConversionMicroseconds: Double {
        conversionBatches == 0 ? 0 : Double(conversionNanoseconds) / Double(conversionBatches) / 1_000
    }
}

public struct RuntimeCaptureMetricsDTO: Equatable, Sendable {
    public let captureCallbacks: UInt64
    public let nativeFramesReceived: UInt64
    public let normalizedFramesDelivered: UInt64
    public let ringDroppedFrames: UInt64
    public let deliveryDroppedFrames: UInt64
    public let conversionBatches: UInt64
    public let conversionNanoseconds: UInt64
    public let ringBacklogFrames: UInt32

    public init(captureCallbacks: UInt64 = 0, nativeFramesReceived: UInt64 = 0,
                normalizedFramesDelivered: UInt64 = 0, ringDroppedFrames: UInt64 = 0,
                deliveryDroppedFrames: UInt64 = 0, conversionBatches: UInt64 = 0,
                conversionNanoseconds: UInt64 = 0, ringBacklogFrames: UInt32 = 0) {
        self.captureCallbacks = captureCallbacks
        self.nativeFramesReceived = nativeFramesReceived
        self.normalizedFramesDelivered = normalizedFramesDelivered
        self.ringDroppedFrames = ringDroppedFrames
        self.deliveryDroppedFrames = deliveryDroppedFrames
        self.conversionBatches = conversionBatches
        self.conversionNanoseconds = conversionNanoseconds
        self.ringBacklogFrames = ringBacklogFrames
    }
}

public struct RuntimeSessionDTO: Codable, Equatable, Sendable {
    public let id: String
    public let streamID: String
    public let sourceID: String
    public let state: RuntimeSessionStateDTO
    public let format: RuntimePCMFormatDTO
    public let dataSocketPath: String
    public let startedAtNanoseconds: UInt64
    public let metrics: RuntimeSessionMetricsDTO
    public let error: RuntimeErrorDTO?

    public init(id: String, streamID: String, sourceID: String, state: RuntimeSessionStateDTO,
                format: RuntimePCMFormatDTO, dataSocketPath: String,
                startedAtNanoseconds: UInt64, metrics: RuntimeSessionMetricsDTO = .init(),
                error: RuntimeErrorDTO? = nil) {
        self.id = id
        self.streamID = streamID
        self.sourceID = sourceID
        self.state = state
        self.format = format
        self.dataSocketPath = dataSocketPath
        self.startedAtNanoseconds = startedAtNanoseconds
        self.metrics = metrics
        self.error = error
    }

    public var framesForwarded: UInt64 { metrics.framesForwarded }
    public var droppedFrames: UInt64 { metrics.droppedFrames }
}

public struct RuntimeResourceLimitsDTO: Codable, Equatable, Sendable {
    public let maximumControlClients: Int
    public let maximumSessions: Int
    public let maximumSessionsPerClient: Int
    public let maximumSubscribersPerStream: Int
    public let maximumControlMessageBytes: Int
    public let maximumEventSubscriptions: Int
    public let maximumEventSubscriptionsPerClient: Int

    public init(maximumControlClients: Int = 32, maximumSessions: Int = 16,
                maximumSessionsPerClient: Int = 8, maximumSubscribersPerStream: Int = 4,
                maximumControlMessageBytes: Int = 64 * 1024,
                maximumEventSubscriptions: Int = 32,
                maximumEventSubscriptionsPerClient: Int = 4) {
        self.maximumControlClients = maximumControlClients
        self.maximumSessions = maximumSessions
        self.maximumSessionsPerClient = maximumSessionsPerClient
        self.maximumSubscribersPerStream = maximumSubscribersPerStream
        self.maximumControlMessageBytes = maximumControlMessageBytes
        self.maximumEventSubscriptions = maximumEventSubscriptions
        self.maximumEventSubscriptionsPerClient = maximumEventSubscriptionsPerClient
    }
}

public struct RuntimeHandshakeDTO: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let runtimeVersion: String
    public let runtimeInstanceID: String
    public let capabilities: [String]
    public let supportedFormats: [RuntimePCMFormatDTO]
    public let limits: RuntimeResourceLimitsDTO
}

public struct RuntimeStatusDTO: Codable, Equatable, Sendable {
    public let runtimeVersion: String
    public let runtimeInstanceID: String
    public let uptimeNanoseconds: UInt64
    public let activeClients: Int
    public let activeSessions: Int
    public let eventSubscribers: Int
    public let totalSessionsStarted: UInt64
    public let totalFramesForwarded: UInt64
    public let totalDroppedFrames: UInt64
    public let totalBytesTransmitted: UInt64
    public let totalEventsDropped: UInt64
}

public enum RuntimeEventTypeDTO: String, Codable, CaseIterable, Sendable {
    case sourceAdded = "source_added"
    case sourceRemoved = "source_removed"
    case sourceUpdated = "source_updated"
    case captureStarted = "capture_started"
    case captureStopped = "capture_stopped"
    case captureFailed = "capture_failed"
    case clientWarning = "client_warning"
    case deviceChanged = "device_changed"
    case runtimeWarning = "runtime_warning"
    case runtimeShuttingDown = "runtime_shutting_down"
}

public struct RuntimeEventDTO: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let eventID: String
    /// Monotonic per-subscription sequence for successfully delivered events.
    public let eventSequence: UInt64?
    /// Events discarded for this subscription immediately before this event.
    public let droppedEventsBefore: UInt64?
    public let type: RuntimeEventTypeDTO
    public let timestampNanoseconds: UInt64
    public let sourceID: String?
    public let sessionID: String?
    public let streamID: String?
    public let source: RuntimeSourceDTO?
    public let session: RuntimeSessionDTO?
    public let message: String?
    public let error: RuntimeErrorDTO?
    public let droppedFrames: UInt64?

    public init(type: RuntimeEventTypeDTO,
                eventID: String = UUID().uuidString.lowercased(),
                eventSequence: UInt64? = nil, droppedEventsBefore: UInt64? = nil,
                timestampNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
                sourceID: String? = nil, sessionID: String? = nil, streamID: String? = nil,
                source: RuntimeSourceDTO? = nil, session: RuntimeSessionDTO? = nil,
                message: String? = nil, error: RuntimeErrorDTO? = nil,
                droppedFrames: UInt64? = nil) {
        protocolVersion = RuntimeProtocolInfo.protocolVersion
        self.eventID = eventID
        self.eventSequence = eventSequence
        self.droppedEventsBefore = droppedEventsBefore
        self.type = type
        self.timestampNanoseconds = timestampNanoseconds
        self.sourceID = sourceID
        self.sessionID = sessionID
        self.streamID = streamID
        self.source = source
        self.session = session
        self.message = message
        self.error = error
        self.droppedFrames = droppedFrames
    }

    public func delivered(sequence: UInt64, droppedEventsBefore: UInt64) -> Self {
        Self(type: type, eventID: eventID, eventSequence: sequence,
            droppedEventsBefore: droppedEventsBefore == 0 ? nil : droppedEventsBefore,
            timestampNanoseconds: timestampNanoseconds, sourceID: sourceID,
            sessionID: sessionID, streamID: streamID, source: source, session: session,
            message: message, error: error, droppedFrames: droppedFrames)
    }
}

public struct RuntimeEventSubscriptionDTO: Codable, Equatable, Sendable {
    public let id: String
    public let eventSocketPath: String
    public let eventTypes: [RuntimeEventTypeDTO]
}

public enum RuntimeCommandName: String, Codable, Sendable {
    case hello
    case listSources = "list_sources"
    case startCapture = "start_capture"
    case stopCapture = "stop_capture"
    case sessionStatus = "session_status"
    case runtimeStatus = "runtime_status"
    case subscribeEvents = "subscribe_events"
    case unsubscribeEvents = "unsubscribe_events"
    case ping
    case unknown

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One JSON object followed by a newline. The first command on a connection must be `hello`.
public struct RuntimeCommand: Codable, Equatable, Sendable {
    public static let currentVersion = RuntimeProtocolInfo.protocolVersion
    public let messageType: String
    public let protocolVersion: Int
    public let requestID: String
    public let command: RuntimeCommandName
    public let sourceID: String?
    public let sessionID: String?
    public let subscriptionID: String?
    public let format: RuntimePCMFormatDTO?
    public let supportedProtocolVersions: [Int]?
    public let clientName: String?
    public let clientVersion: String?
    public let eventTypes: [RuntimeEventTypeDTO]?

    public init(protocolVersion: Int = currentVersion,
                requestID: String = UUID().uuidString.lowercased(),
                command: RuntimeCommandName, sourceID: String? = nil, sessionID: String? = nil,
                subscriptionID: String? = nil, format: RuntimePCMFormatDTO? = nil,
                supportedProtocolVersions: [Int]? = nil, clientName: String? = nil,
                clientVersion: String? = nil, eventTypes: [RuntimeEventTypeDTO]? = nil) {
        messageType = "request"
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.command = command
        self.sourceID = sourceID
        self.sessionID = sessionID
        self.subscriptionID = subscriptionID
        self.format = format
        self.supportedProtocolVersions = supportedProtocolVersions
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.eventTypes = eventTypes
    }
}

public struct RuntimeErrorDTO: Codable, Equatable, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public let retryable: Bool
    public let details: [String: String]?

    public init(code: String, message: String, retryable: Bool = false,
                details: [String: String]? = nil) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.details = details
    }

    public var errorDescription: String? { "\(code): \(message)" }
}

public struct RuntimeResponse: Codable, Equatable, Sendable {
    public let messageType: String
    public let protocolVersion: Int
    public let responseID: String
    public let requestID: String
    public let ok: Bool
    public let handshake: RuntimeHandshakeDTO?
    public let sources: [RuntimeSourceDTO]?
    public let session: RuntimeSessionDTO?
    public let status: RuntimeStatusDTO?
    public let subscription: RuntimeEventSubscriptionDTO?
    public let message: String?
    public let error: RuntimeErrorDTO?

    private init(requestID: String, ok: Bool, handshake: RuntimeHandshakeDTO? = nil,
                 sources: [RuntimeSourceDTO]? = nil, session: RuntimeSessionDTO? = nil,
                 status: RuntimeStatusDTO? = nil, subscription: RuntimeEventSubscriptionDTO? = nil,
                 message: String? = nil, error: RuntimeErrorDTO? = nil) {
        messageType = "response"
        protocolVersion = RuntimeProtocolInfo.protocolVersion
        responseID = UUID().uuidString.lowercased()
        self.requestID = requestID
        self.ok = ok
        self.handshake = handshake
        self.sources = sources
        self.session = session
        self.status = status
        self.subscription = subscription
        self.message = message
        self.error = error
    }

    public init(requestID: String, handshake: RuntimeHandshakeDTO) {
        self.init(requestID: requestID, ok: true, handshake: handshake)
    }
    public init(requestID: String, sources: [RuntimeSourceDTO]) {
        self.init(requestID: requestID, ok: true, sources: sources)
    }
    public init(requestID: String, session: RuntimeSessionDTO) {
        self.init(requestID: requestID, ok: true, session: session)
    }
    public init(requestID: String, status: RuntimeStatusDTO) {
        self.init(requestID: requestID, ok: true, status: status)
    }
    public init(requestID: String, subscription: RuntimeEventSubscriptionDTO) {
        self.init(requestID: requestID, ok: true, subscription: subscription)
    }
    public init(requestID: String, message: String) {
        self.init(requestID: requestID, ok: true, message: message)
    }
    public init(requestID: String, error: RuntimeErrorDTO) {
        self.init(requestID: requestID, ok: false, error: error)
    }
}

public enum RuntimeProtocolCodec {
    public static let maximumControlMessageBytes = 64 * 1024

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { path in
            let snake = path.last!.stringValue
            let pieces = snake.split(separator: "_")
            var camel = pieces.first.map(String.init) ?? snake
            for piece in pieces.dropFirst() {
                camel += piece.prefix(1).uppercased() + piece.dropFirst()
            }
            if camel.hasSuffix("Ids") {
                camel.removeLast(3)
                camel += "IDs"
            } else if camel.hasSuffix("Id") {
                camel.removeLast(2)
                camel += "ID"
            }
            return RuntimeCodingKey(stringValue: camel)!
        }
        return decoder
    }

    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let payload = try encoder().encode(value)
        // The advertised limit includes the trailing NDJSON newline.
        guard payload.count < maximumControlMessageBytes else {
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
        guard !body.isEmpty, !body.contains(0), String(data: Data(body), encoding: .utf8) != nil else {
            throw RuntimeErrorDTO(code: "malformed_json", message: "Control message is not valid UTF-8 JSON")
        }
        do { return try decoder().decode(type, from: Data(body)) }
        catch { throw RuntimeErrorDTO(code: "malformed_json", message: "Control message is not valid JSON: \(error.localizedDescription)") }
    }
}

private struct RuntimeCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}

/// Incremental bounded parser for stream-oriented sockets.
public struct RuntimeNDJSONParser {
    private var buffer = Data()
    public init() {}

    public mutating func append(_ data: Data) throws -> [Data] {
        guard data.count <= RuntimeProtocolCodec.maximumControlMessageBytes,
              buffer.count <= RuntimeProtocolCodec.maximumControlMessageBytes - data.count else {
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
