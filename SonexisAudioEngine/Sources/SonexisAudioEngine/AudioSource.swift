import Foundation

public enum AudioSourceKind: String, Codable, Sendable {
    case application
    case microphone
    case systemMix
    case remote
    case virtual
}

public enum AudioSourceState: String, Codable, Sendable {
    case active
    case inactive
}

public struct AudioStreamDescription: Codable, Equatable, Sendable {
    public let sampleRate: Double
    public let channelCount: UInt32
    public let bitsPerChannel: UInt32
    public let isFloat: Bool
    public let isInterleaved: Bool

    public init(sampleRate: Double, channelCount: UInt32, bitsPerChannel: UInt32,
                isFloat: Bool, isInterleaved: Bool) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitsPerChannel = bitsPerChannel
        self.isFloat = isFloat
        self.isInterleaved = isInterleaved
    }
}

/// A serializable source identity. Application IDs are based on the bundle ID,
/// not a PID, so a client can retain a selection across application restarts.
public struct AudioSource: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: AudioSourceKind
    public let name: String
    public let bundleIdentifier: String?
    public let bundlePath: String?
    public let processIdentifiers: [Int32]
    public let state: AudioSourceState
    public let isProducingAudio: Bool?
    public let nativeFormat: AudioStreamDescription?

    public init(
        id: String,
        kind: AudioSourceKind,
        name: String,
        bundleIdentifier: String? = nil,
        bundlePath: String? = nil,
        processIdentifiers: [Int32] = [],
        state: AudioSourceState,
        isProducingAudio: Bool? = nil,
        nativeFormat: AudioStreamDescription? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.processIdentifiers = processIdentifiers.sorted()
        self.state = state
        self.isProducingAudio = isProducingAudio
        self.nativeFormat = nativeFormat
    }

    public static func applicationID(bundleIdentifier: String) -> String {
        "app.\(bundleIdentifier)"
    }
}
