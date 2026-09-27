import Foundation

public enum RuntimeProtocolInfo {
    public static let protocolVersion = 2
    public static let runtimeVersion = "0.7.0"
    public static let capabilities = [
        "application_sources", "capture_sessions", "event_stream", "format_negotiation",
        "multiple_sessions", "pcm_v2", "runtime_diagnostics", "output_sessions",
        "output_destinations", "output_pcm_v2", "output_backpressure", "output_flush",
        "default_device_playback", "output_destination_events",
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
    public static let supportedCaptureFormats: [Self] = [
        .runtimeDefault,
        Self(sampleRate: 24_000, channelCount: 1),
        Self(sampleRate: 48_000, channelCount: 1),
        Self(sampleRate: 48_000, channelCount: 2),
        Self(sampleRate: 48_000, channelCount: 1, sampleFormat: .float32LE),
        Self(sampleRate: 48_000, channelCount: 2, sampleFormat: .float32LE),
    ]
    public static let supportedOutputFormats = supportedCaptureFormats
    /// Compatibility alias for the original capture-format policy.
    public static let supported = supportedCaptureFormats
    public var isSupported: Bool { Self.supportedCaptureFormats.contains(self) }
    public var isSupportedOutput: Bool { Self.supportedOutputFormats.contains(self) }
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
    /// Optional for protocol-v2 compatibility with v0.3 Runtime handshakes.
    public let maximumOutputSessions: Int?
    public let maximumOutputSessionsPerClient: Int?
    public let maximumOutputPacketMilliseconds: Int?
    public let maximumOutputDestinations: Int?

    public init(maximumControlClients: Int = 32, maximumSessions: Int = 16,
                maximumSessionsPerClient: Int = 8, maximumSubscribersPerStream: Int = 4,
                maximumControlMessageBytes: Int = 64 * 1024,
                maximumEventSubscriptions: Int = 32,
                maximumEventSubscriptionsPerClient: Int = 4,
                maximumOutputSessions: Int? = 8,
                maximumOutputSessionsPerClient: Int? = 4,
                maximumOutputPacketMilliseconds: Int? = 200,
                maximumOutputDestinations: Int? = 32) {
        self.maximumControlClients = maximumControlClients
        self.maximumSessions = maximumSessions
        self.maximumSessionsPerClient = maximumSessionsPerClient
        self.maximumSubscribersPerStream = maximumSubscribersPerStream
        self.maximumControlMessageBytes = maximumControlMessageBytes
        self.maximumEventSubscriptions = maximumEventSubscriptions
        self.maximumEventSubscriptionsPerClient = maximumEventSubscriptionsPerClient
        self.maximumOutputSessions = maximumOutputSessions
        self.maximumOutputSessionsPerClient = maximumOutputSessionsPerClient
        self.maximumOutputPacketMilliseconds = maximumOutputPacketMilliseconds
        self.maximumOutputDestinations = maximumOutputDestinations
    }
}

public struct RuntimeHandshakeDTO: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let runtimeVersion: String
    public let runtimeInstanceID: String
    public let capabilities: [String]
    public let supportedFormats: [RuntimePCMFormatDTO]
    /// Additive protocol-v2 field. Nil when decoding a v0.3 handshake.
    public let supportedOutputFormats: [RuntimePCMFormatDTO]?
    public let limits: RuntimeResourceLimitsDTO

    public init(protocolVersion: Int, runtimeVersion: String, runtimeInstanceID: String,
                capabilities: [String], supportedFormats: [RuntimePCMFormatDTO],
                supportedOutputFormats: [RuntimePCMFormatDTO]?
                    = RuntimePCMFormatDTO.supportedOutputFormats,
                limits: RuntimeResourceLimitsDTO) {
        self.protocolVersion = protocolVersion
        self.runtimeVersion = runtimeVersion
        self.runtimeInstanceID = runtimeInstanceID
        self.capabilities = capabilities
        self.supportedFormats = supportedFormats
        self.supportedOutputFormats = supportedOutputFormats
        self.limits = limits
    }
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
    /// Additive output diagnostics; nil when decoding a v0.3 status response.
    public let activeOutputSessions: Int?
    public let totalOutputSessionsStarted: UInt64?
    public let totalOutputFramesReceived: UInt64?
    public let totalOutputFramesRendered: UInt64?
    public let totalOutputFramesDropped: UInt64?
    public let totalOutputBytesReceived: UInt64?

    public init(runtimeVersion: String, runtimeInstanceID: String, uptimeNanoseconds: UInt64,
                activeClients: Int, activeSessions: Int, eventSubscribers: Int,
                totalSessionsStarted: UInt64, totalFramesForwarded: UInt64,
                totalDroppedFrames: UInt64, totalBytesTransmitted: UInt64,
                totalEventsDropped: UInt64, activeOutputSessions: Int? = nil,
                totalOutputSessionsStarted: UInt64? = nil,
                totalOutputFramesReceived: UInt64? = nil,
                totalOutputFramesRendered: UInt64? = nil,
                totalOutputFramesDropped: UInt64? = nil,
                totalOutputBytesReceived: UInt64? = nil) {
        self.runtimeVersion = runtimeVersion
        self.runtimeInstanceID = runtimeInstanceID
        self.uptimeNanoseconds = uptimeNanoseconds
        self.activeClients = activeClients
        self.activeSessions = activeSessions
        self.eventSubscribers = eventSubscribers
        self.totalSessionsStarted = totalSessionsStarted
        self.totalFramesForwarded = totalFramesForwarded
        self.totalDroppedFrames = totalDroppedFrames
        self.totalBytesTransmitted = totalBytesTransmitted
        self.totalEventsDropped = totalEventsDropped
        self.activeOutputSessions = activeOutputSessions
        self.totalOutputSessionsStarted = totalOutputSessionsStarted
        self.totalOutputFramesReceived = totalOutputFramesReceived
        self.totalOutputFramesRendered = totalOutputFramesRendered
        self.totalOutputFramesDropped = totalOutputFramesDropped
        self.totalOutputBytesReceived = totalOutputBytesReceived
    }
}

public enum RuntimeOutputDestinationKindDTO: String, Codable, Sendable {
    case playback
    case virtualInput = "virtual_input"
}

public struct RuntimeOutputDestinationDTO: Codable, Equatable, Sendable {
    public let id: String
    public let kind: RuntimeOutputDestinationKindDTO
    public let name: String
    public let isAvailable: Bool
    public let isDefault: Bool
    public let followsSystemDefault: Bool
    /// Stable semantic endpoint ID for the device currently backing an alias.
    /// This deliberately never exposes an AudioObjectID.
    public let activeDeviceID: String?
    public let activeDeviceName: String?
    public let nativeFormat: RuntimePCMFormatDTO?
    public let supportedFormats: [RuntimePCMFormatDTO]

    public init(id: String, kind: RuntimeOutputDestinationKindDTO, name: String,
                isAvailable: Bool, isDefault: Bool = false,
                followsSystemDefault: Bool = false, activeDeviceID: String? = nil,
                activeDeviceName: String? = nil,
                nativeFormat: RuntimePCMFormatDTO? = nil,
                supportedFormats: [RuntimePCMFormatDTO]
                    = RuntimePCMFormatDTO.supportedOutputFormats) {
        self.id = id
        self.kind = kind
        self.name = name
        self.isAvailable = isAvailable
        self.isDefault = isDefault
        self.followsSystemDefault = followsSystemDefault
        self.activeDeviceID = activeDeviceID
        self.activeDeviceName = activeDeviceName
        self.nativeFormat = nativeFormat
        self.supportedFormats = supportedFormats
    }
}

/// A deterministic, non-realtime diff used by the Runtime's endpoint monitor.
/// Removed destinations retain their last known snapshot so clients can present
/// useful context while evicting them from their current registry.
struct RuntimeOutputDestinationDiff: Equatable, Sendable {
    let added: [RuntimeOutputDestinationDTO]
    let removed: [RuntimeOutputDestinationDTO]
    let updated: [RuntimeOutputDestinationDTO]
    let defaultChanged: RuntimeOutputDestinationDTO?

    init(previous: [String: RuntimeOutputDestinationDTO],
         current: [String: RuntimeOutputDestinationDTO]) {
        added = current.values.filter { previous[$0.id] == nil }.sorted { $0.id < $1.id }
        removed = previous.values.filter { current[$0.id] == nil }.sorted { $0.id < $1.id }
        let oldDefault = previous["default"]
        let newDefault = current["default"]
        let routeChanged = oldDefault?.activeDeviceID != newDefault?.activeDeviceID
            && oldDefault != nil && newDefault != nil
        updated = current.values.filter {
            guard let old = previous[$0.id] else { return false }
            return old != $0 && !($0.id == "default" && routeChanged)
        }.sorted { $0.id < $1.id }

        defaultChanged = routeChanged
            ? newDefault
            : nil
    }
}

public enum RuntimeOutputSessionStateDTO: String, Codable, Sendable {
    case starting
    case ready
    case draining
    case stopped
    case cancelled
    case failed
}

public struct RuntimeOutputMetricsDTO: Codable, Equatable, Sendable {
    public let packetsReceived: UInt64
    public let inputFramesReceived: UInt64
    public let inputBytesReceived: UInt64
    public let deviceFramesEnqueued: UInt64
    public let deviceFramesRendered: UInt64
    public let droppedFrames: UInt64
    public let flushedFrames: UInt64
    public let lateFrames: UInt64
    public let underrunFrames: UInt64
    public let underrunEvents: UInt64
    public let overrunEvents: UInt64
    public let queueDepthFrames: UInt32
    public let queueHighWaterFrames: UInt32
    public let bufferedMilliseconds: Double
    public let targetBufferMilliseconds: UInt32
    public let conversionBatches: UInt64
    public let conversionNanoseconds: UInt64
    public let routeChanges: UInt64
    public let producerConnected: Bool
    public let deviceSampleRate: UInt32?
    public let deviceChannelCount: UInt16?
    public let estimatedOutputLatencyMilliseconds: Double?
    public let uptimeNanoseconds: UInt64?

    public init(packetsReceived: UInt64 = 0, inputFramesReceived: UInt64 = 0,
                inputBytesReceived: UInt64 = 0, deviceFramesEnqueued: UInt64 = 0,
                deviceFramesRendered: UInt64 = 0, droppedFrames: UInt64 = 0,
                flushedFrames: UInt64 = 0, lateFrames: UInt64 = 0,
                underrunFrames: UInt64 = 0, underrunEvents: UInt64 = 0,
                overrunEvents: UInt64 = 0, queueDepthFrames: UInt32 = 0,
                queueHighWaterFrames: UInt32 = 0, bufferedMilliseconds: Double = 0,
                targetBufferMilliseconds: UInt32 = 60, conversionBatches: UInt64 = 0,
                conversionNanoseconds: UInt64 = 0, routeChanges: UInt64 = 0,
                producerConnected: Bool = false, deviceSampleRate: UInt32? = nil,
                deviceChannelCount: UInt16? = nil,
                estimatedOutputLatencyMilliseconds: Double? = nil,
                uptimeNanoseconds: UInt64? = nil) {
        self.packetsReceived = packetsReceived
        self.inputFramesReceived = inputFramesReceived
        self.inputBytesReceived = inputBytesReceived
        self.deviceFramesEnqueued = deviceFramesEnqueued
        self.deviceFramesRendered = deviceFramesRendered
        self.droppedFrames = droppedFrames
        self.flushedFrames = flushedFrames
        self.lateFrames = lateFrames
        self.underrunFrames = underrunFrames
        self.underrunEvents = underrunEvents
        self.overrunEvents = overrunEvents
        self.queueDepthFrames = queueDepthFrames
        self.queueHighWaterFrames = queueHighWaterFrames
        self.bufferedMilliseconds = bufferedMilliseconds
        self.targetBufferMilliseconds = targetBufferMilliseconds
        self.conversionBatches = conversionBatches
        self.conversionNanoseconds = conversionNanoseconds
        self.routeChanges = routeChanges
        self.producerConnected = producerConnected
        self.deviceSampleRate = deviceSampleRate
        self.deviceChannelCount = deviceChannelCount
        self.estimatedOutputLatencyMilliseconds = estimatedOutputLatencyMilliseconds
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    public var averageConversionMicroseconds: Double {
        conversionBatches == 0
            ? 0
            : Double(conversionNanoseconds) / Double(conversionBatches) / 1_000
    }
}

public struct RuntimeOutputSessionDTO: Codable, Equatable, Sendable {
    public let id: String
    public let streamID: String
    public let destinationID: String
    public let state: RuntimeOutputSessionStateDTO
    public let format: RuntimePCMFormatDTO
    public let dataSocketPath: String
    public let startedAtNanoseconds: UInt64
    public let targetBufferMilliseconds: UInt32
    public let metrics: RuntimeOutputMetricsDTO
    public let error: RuntimeErrorDTO?

    public init(id: String, streamID: String, destinationID: String,
                state: RuntimeOutputSessionStateDTO, format: RuntimePCMFormatDTO,
                dataSocketPath: String, startedAtNanoseconds: UInt64,
                targetBufferMilliseconds: UInt32,
                metrics: RuntimeOutputMetricsDTO = .init(), error: RuntimeErrorDTO? = nil) {
        self.id = id
        self.streamID = streamID
        self.destinationID = destinationID
        self.state = state
        self.format = format
        self.dataSocketPath = dataSocketPath
        self.startedAtNanoseconds = startedAtNanoseconds
        self.targetBufferMilliseconds = targetBufferMilliseconds
        self.metrics = metrics
        self.error = error
    }
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
    case outputStarted = "output_started"
    case outputStopped = "output_stopped"
    case outputCancelled = "output_cancelled"
    case outputFailed = "output_failed"
    case outputUnderrun = "output_underrun"
    case outputOverrun = "output_overrun"
    case outputDropped = "output_dropped"
    case outputDestinationChanged = "output_destination_changed"
    case outputDestinationAdded = "output_destination_added"
    case outputDestinationRemoved = "output_destination_removed"
    case outputDestinationUpdated = "output_destination_updated"
    case outputDefaultChanged = "output_default_changed"
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
    public let outputDestinationID: String?
    public let source: RuntimeSourceDTO?
    public let session: RuntimeSessionDTO?
    public let message: String?
    public let error: RuntimeErrorDTO?
    public let droppedFrames: UInt64?
    public let outputSession: RuntimeOutputSessionDTO?
    public let outputDestination: RuntimeOutputDestinationDTO?

    public init(type: RuntimeEventTypeDTO,
                eventID: String = UUID().uuidString.lowercased(),
                eventSequence: UInt64? = nil, droppedEventsBefore: UInt64? = nil,
                timestampNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
                sourceID: String? = nil, sessionID: String? = nil, streamID: String? = nil,
                outputDestinationID: String? = nil,
                source: RuntimeSourceDTO? = nil, session: RuntimeSessionDTO? = nil,
                message: String? = nil, error: RuntimeErrorDTO? = nil,
                droppedFrames: UInt64? = nil,
                outputSession: RuntimeOutputSessionDTO? = nil,
                outputDestination: RuntimeOutputDestinationDTO? = nil) {
        protocolVersion = RuntimeProtocolInfo.protocolVersion
        self.eventID = eventID
        self.eventSequence = eventSequence
        self.droppedEventsBefore = droppedEventsBefore
        self.type = type
        self.timestampNanoseconds = timestampNanoseconds
        self.sourceID = sourceID
        self.sessionID = sessionID
        self.streamID = streamID
        self.outputDestinationID = outputDestination?.id ?? outputDestinationID
        self.source = source
        self.session = session
        self.message = message
        self.error = error
        self.droppedFrames = droppedFrames
        self.outputSession = outputSession
        self.outputDestination = outputDestination
    }

    public func delivered(sequence: UInt64, droppedEventsBefore: UInt64) -> Self {
        Self(type: type, eventID: eventID, eventSequence: sequence,
            droppedEventsBefore: droppedEventsBefore == 0 ? nil : droppedEventsBefore,
            timestampNanoseconds: timestampNanoseconds, sourceID: sourceID,
            sessionID: sessionID, streamID: streamID,
            outputDestinationID: outputDestinationID,
            source: source, session: session,
            message: message, error: error, droppedFrames: droppedFrames,
            outputSession: outputSession, outputDestination: outputDestination)
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
    case listOutputDestinations = "list_output_destinations"
    case startOutput = "start_output"
    case outputStatus = "output_status"
    case flushOutput = "flush_output"
    case stopOutput = "stop_output"
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
    public let destinationID: String?
    public let outputSessionID: String?
    public let targetBufferMilliseconds: UInt32?

    public init(protocolVersion: Int = currentVersion,
                requestID: String = UUID().uuidString.lowercased(),
                command: RuntimeCommandName, sourceID: String? = nil, sessionID: String? = nil,
                subscriptionID: String? = nil, format: RuntimePCMFormatDTO? = nil,
                supportedProtocolVersions: [Int]? = nil, clientName: String? = nil,
                clientVersion: String? = nil, eventTypes: [RuntimeEventTypeDTO]? = nil,
                destinationID: String? = nil, outputSessionID: String? = nil,
                targetBufferMilliseconds: UInt32? = nil) {
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
        self.destinationID = destinationID
        self.outputSessionID = outputSessionID
        self.targetBufferMilliseconds = targetBufferMilliseconds
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
    public let outputDestinations: [RuntimeOutputDestinationDTO]?
    public let outputSession: RuntimeOutputSessionDTO?
    public let message: String?
    public let error: RuntimeErrorDTO?

    private init(requestID: String, ok: Bool, handshake: RuntimeHandshakeDTO? = nil,
                 sources: [RuntimeSourceDTO]? = nil, session: RuntimeSessionDTO? = nil,
                 status: RuntimeStatusDTO? = nil, subscription: RuntimeEventSubscriptionDTO? = nil,
                 outputDestinations: [RuntimeOutputDestinationDTO]? = nil,
                 outputSession: RuntimeOutputSessionDTO? = nil,
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
        self.outputDestinations = outputDestinations
        self.outputSession = outputSession
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
    public init(requestID: String, outputDestinations: [RuntimeOutputDestinationDTO]) {
        self.init(requestID: requestID, ok: true, outputDestinations: outputDestinations)
    }
    public init(requestID: String, outputSession: RuntimeOutputSessionDTO) {
        self.init(requestID: requestID, ok: true, outputSession: outputSession)
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
    private var readOffset = 0
    public init() {}

    public mutating func append(_ data: Data) throws -> [Data] {
        compact(force: buffer.count + data.count > RuntimeProtocolCodec.maximumControlMessageBytes)
        let bufferedBytes = buffer.count - readOffset
        guard data.count <= RuntimeProtocolCodec.maximumControlMessageBytes,
              bufferedBytes <= RuntimeProtocolCodec.maximumControlMessageBytes - data.count else {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
            throw RuntimeErrorDTO(code: "message_too_large", message: "Control message has no newline within the size limit")
        }
        buffer.append(data)
        var lines: [Data] = []
        while readOffset < buffer.count,
              let newline = buffer[readOffset...].firstIndex(of: 0x0A) {
            let end = buffer.index(after: newline)
            lines.append(Data(buffer[readOffset..<end]))
            readOffset = end
        }
        compact(force: readOffset == buffer.count)
        return lines
    }

    private mutating func compact(force: Bool = false) {
        guard readOffset > 0,
              force || readOffset >= 32 * 1_024 || readOffset * 2 >= buffer.count else { return }
        if readOffset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
        } else {
            buffer.removeSubrange(0..<readOffset)
        }
        readOffset = 0
    }
}
