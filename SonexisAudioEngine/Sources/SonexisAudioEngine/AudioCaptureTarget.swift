import AppKit
import CoreAudio

public struct AudioCaptureTarget: Codable, Equatable, Identifiable {
    public let bundleID: String
    public let name: String
    public let bundlePath: String
    public var id: String { bundleID }
    public static let storageKey = "Sonexis.AudioCaptureTarget"

    public init(bundleID: String, name: String, bundlePath: String) {
        self.bundleID = bundleID
        self.name = name
        self.bundlePath = bundlePath
    }

    public static func restore() -> AudioCaptureTarget? {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let target = try? JSONDecoder().decode(Self.self, from: data),
              target.bundleID != Bundle.main.bundleIdentifier else { return nil }
        return target
    }

    public static func runningApps() -> [Self] {
        (try? AudioSourceRegistry().availableSources().compactMap { source in
            try? Self(source: source)
        }) ?? []
    }

    public func contains(bundleID processBundleID: String, bundlePath processPath: String?, executablePath: String? = nil) -> Bool {
        if processBundleID == bundleID { return true }
        // Include embedded audio helpers, without matching unrelated bundle-ID prefixes.
        let embeddedPrefix = bundlePath + "/Contents/"
        return [processPath, executablePath].compactMap { $0 }.contains { $0.hasPrefix(embeddedPrefix) }
    }

    public func containsOwnedHelper(isRegularApplication: Bool, responsibleBundleID: String?) -> Bool {
        // Responsibility also follows app launches. A separately launchable app
        // must retain its own audio even when another app launched it.
        guard !isRegularApplication, let responsibleBundleID,
              !responsibleBundleID.isEmpty else { return false }
        return responsibleBundleID == bundleID
    }

    public func processObjectIDs(excluding ownID: AudioObjectID) throws -> [AudioObjectID] {
        let objects = try CoreAudioSupport.readAudioObjectIDArray(
            objectID: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList,
            operation: "Read audio processes")
        return objects.filter { object in
            guard object != ownID,
                  let pid: pid_t = try? CoreAudioSupport.readScalar(objectID: object,
                    selector: kAudioProcessPropertyPID, defaultValue: pid_t(0), operation: "Read audio process PID"),
                  pid != ProcessInfo.processInfo.processIdentifier else { return false }
            let app = NSRunningApplication(processIdentifier: pid)
            let id = (try? CoreAudioSupport.readString(objectID: object,
                selector: kAudioProcessPropertyBundleID, operation: "Read audio process bundle")) ?? app?.bundleIdentifier ?? ""
            if contains(bundleID: id, bundlePath: app?.bundleURL?.path) { return true }
            // Headless/sandboxed audio helpers may not be represented by
            // NSRunningApplication. Resolve their executable without trusting
            // a bundle-ID prefix, which could include a different app.
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            let executable = length > 0 ? String(cString: path) : nil
            if contains(bundleID: id, bundlePath: nil, executablePath: executable) { return true }
            guard app?.activationPolicy != .regular else { return false }
            return containsOwnedHelper(isRegularApplication: false,
                responsibleBundleID: ProcessResponsibility.bundleID(for: pid))
        }.sorted()
    }
}

/// Shared helpers can live outside their client app's bundle and have launchd
/// as their Unix parent. This optional private macOS SPI identifies the
/// responsible application. Resolve dynamically: unavailable/failed attribution
/// must never broaden an app's capture to unrelated processes.
private enum ProcessResponsibility {
    typealias Lookup = @convention(c) (pid_t) -> pid_t
    private static let lookup: Lookup? = {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: Lookup.self)
    }()

    static func bundleID(for pid: pid_t) -> String? {
        guard let lookup else { return nil }
        let owner = lookup(pid)
        guard owner > 1, owner != pid, owner != ProcessInfo.processInfo.processIdentifier else { return nil }
        return NSRunningApplication(processIdentifier: owner)?.bundleIdentifier
    }
}
