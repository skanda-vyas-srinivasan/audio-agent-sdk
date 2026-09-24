import Foundation

enum AudioSourceKind: String, Codable, Sendable {
    case application
    case microphone
    case systemMix
    case remote
    case virtual
}

enum AudioSourceState: String, Codable, Sendable {
    case active
    case inactive
}

struct AudioStreamDescription: Codable, Equatable, Sendable {
    let sampleRate: Double
    let channelCount: UInt32
    let bitsPerChannel: UInt32
    let isFloat: Bool
    let isInterleaved: Bool
}

/// A serializable source identity. Application IDs are based on the bundle ID,
/// not a PID, so a client can retain a selection across application restarts.
struct AudioSource: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: AudioSourceKind
    let name: String
    let bundleIdentifier: String?
    let bundlePath: String?
    let processIdentifiers: [Int32]
    let state: AudioSourceState
    let isProducingAudio: Bool?
    let nativeFormat: AudioStreamDescription?

    init(
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

    static func applicationID(bundleIdentifier: String) -> String {
        "app.\(bundleIdentifier)"
    }
}

