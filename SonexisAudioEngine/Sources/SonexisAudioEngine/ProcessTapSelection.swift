import CoreAudio

/// A resolved capture partition. Multi-chain routing resolves all partitions
/// together; individual pipelines must not discover or broaden their own scope.
public struct ProcessTapSelection: Equatable {
    public let isExclusive: Bool
    public let processIDs: [AudioObjectID]

    public init(isExclusive: Bool, processIDs: [AudioObjectID]) {
        self.isExclusive = isExclusive
        self.processIDs = processIDs
    }

    public static func allAudio(excluding ids: Set<AudioObjectID>) -> Self {
        Self(isExclusive: true, processIDs: ids.sorted())
    }

    public static func only(_ ids: Set<AudioObjectID>) -> Self {
        Self(isExclusive: false, processIDs: ids.sorted())
    }

    public func safeProcessIDs(ownProcessID: AudioObjectID) -> [AudioObjectID] {
        var ids = Set(processIDs.filter { $0 != kAudioObjectUnknown })
        if isExclusive { ids.insert(ownProcessID) } else { ids.remove(ownProcessID) }
        return ids.sorted()
    }
}
