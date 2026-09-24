import AppKit
import CoreAudio
import Foundation

enum AudioSourceRegistryError: Error, CustomStringConvertible {
    case sourceNotFound(String)
    case unsupportedSourceKind(AudioSourceKind)

    var description: String {
        switch self {
        case .sourceNotFound(let id):
            return "Audio source not found: \(id)"
        case .unsupportedSourceKind(let kind):
            return "Audio source kind is not supported yet: \(kind.rawValue)"
        }
    }
}

/// Discovers application sources without relying on SwiftUI or application UI state.
/// NSWorkspace supplies application metadata; Core Audio is used only to determine
/// which running application processes currently have an audio process object.
final class AudioSourceRegistry {
    func availableSources() throws -> [AudioSource] {
        let audioPIDs = try currentAudioProcessIDs()
        let nativeFormat = try? defaultOutputFormat()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownBundleID = Bundle.main.bundleIdentifier
        var applicationsByBundleID: [String: [NSRunningApplication]] = [:]

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  app.processIdentifier != ownPID,
                  let bundleID = app.bundleIdentifier,
                  bundleID != ownBundleID else { continue }
            applicationsByBundleID[bundleID, default: []].append(app)
        }

        return applicationsByBundleID.map { bundleID, applications in
            let sortedApplications = applications.sorted { $0.processIdentifier < $1.processIdentifier }
            let processIDs = sortedApplications.map(\.processIdentifier)
            let isProducingAudio = processIDs.contains { audioPIDs.contains($0) }
            let representative = sortedApplications[0]
            return AudioSource(
                id: AudioSource.applicationID(bundleIdentifier: bundleID),
                kind: .application,
                name: representative.localizedName ?? bundleID,
                bundleIdentifier: bundleID,
                bundlePath: representative.bundleURL?.path,
                processIdentifiers: processIDs,
                state: .active,
                isProducingAudio: isProducingAudio,
                nativeFormat: nativeFormat
            )
        }.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    func source(id: String) throws -> AudioSource {
        guard let source = try availableSources().first(where: { $0.id == id }) else {
            throw AudioSourceRegistryError.sourceNotFound(id)
        }
        return source
    }

    private func currentAudioProcessIDs() throws -> Set<pid_t> {
        let objectIDs = try CoreAudioSupport.readAudioObjectIDArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList,
            operation: "Read audio process list for source discovery"
        )
        return Set(objectIDs.compactMap { objectID in
            try? CoreAudioSupport.readScalar(
                objectID: objectID,
                selector: kAudioProcessPropertyPID,
                defaultValue: pid_t(0),
                operation: "Read audio source process PID"
            )
        }.filter { $0 > 0 })
    }

    private func defaultOutputFormat() throws -> AudioStreamDescription? {
        let deviceID = try CoreAudioSupport.defaultOutputDevice()
        guard let streamID = try CoreAudioSupport.outputStreamIDs(deviceID).first else { return nil }
        let format = try CoreAudioSupport.streamVirtualFormat(streamID)
        return AudioStreamDescription(
            sampleRate: format.mSampleRate,
            channelCount: format.mChannelsPerFrame,
            bitsPerChannel: format.mBitsPerChannel,
            isFloat: (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
            isInterleaved: (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        )
    }
}

extension AudioCaptureTarget {
    init(source: AudioSource) throws {
        guard source.kind == .application,
              let bundleID = source.bundleIdentifier else {
            throw AudioSourceRegistryError.unsupportedSourceKind(source.kind)
        }
        self.init(bundleID: bundleID, name: source.name, bundlePath: source.bundlePath ?? "")
    }
}
