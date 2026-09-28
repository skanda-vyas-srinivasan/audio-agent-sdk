import CoreAudio
import Foundation

public struct CoreAudioError: Error, CustomStringConvertible {
    public let operation: String
    public let status: OSStatus

    public init(operation: String, status: OSStatus) {
        self.operation = operation
        self.status = status
    }

    public var description: String {
        "\(operation) failed: \(status.osStatusDescription)"
    }
}

public struct SonexisError: Error, CustomStringConvertible {
    public let message: String

    public init(message: String) { self.message = message }
    public var description: String { message }
}

public struct NoDefaultOutputDeviceError: Error, CustomStringConvertible {
    public init() {}
    public var description: String {
        "No default output device is available"
    }
}

public struct NoDefaultInputDeviceError: Error, CustomStringConvertible {
    public init() {}
    public var description: String {
        "No default input device is available"
    }
}

public func checkOSStatus(_ status: OSStatus, operation: String) throws {
    guard status == noErr else {
        throw CoreAudioError(operation: operation, status: status)
    }
}

public func printCleanupResult(_ label: String, status: OSStatus) {
    if status == noErr {
        print("Cleanup: \(label).")
    } else {
        print("Cleanup warning: \(label) returned \(status.osStatusDescription).")
    }
}

extension OSStatus {
    public var osStatusDescription: String {
        let code = fourCharacterCode
        if code.isEmpty {
            return "\(self)"
        }
        return "\(self) ('\(code)')"
    }

    private var fourCharacterCode: String {
        let value = UInt32(bitPattern: self).bigEndian
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]

        guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else {
            return ""
        }
        return String(bytes: bytes, encoding: .macOSRoman) ?? ""
    }
}

public enum CoreAudioSupport {
    public static func readScalar<T>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        defaultValue: T,
        operation: String
    ) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var value = defaultValue
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return kAudioHardwareUnspecifiedError
            }
            return AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &size,
                baseAddress
            )
        }
        try checkOSStatus(status, operation: operation)
        return value
    }

    public static func readAudioObjectIDArray(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        operation: String
    ) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        try checkOSStatus(status, operation: "\(operation) size")

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var values = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        status = values.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return kAudioHardwareUnspecifiedError
            }
            return AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &size,
                baseAddress
            )
        }
        try checkOSStatus(status, operation: operation)
        return values
    }

    public static func readString(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        operation: String
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutableBytes(of: &value) { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return kAudioHardwareUnspecifiedError
            }
            return AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &size,
                baseAddress
            )
        }
        try checkOSStatus(status, operation: operation)

        guard let value else {
            throw SonexisError(message: "\(operation) returned nil")
        }
        return value.takeRetainedValue() as String
    }

    public static func defaultOutputDevice() throws -> AudioDeviceID {
        let deviceID: AudioDeviceID = try readScalar(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            defaultValue: kAudioObjectUnknown,
            operation: "Read default output device"
        )

        guard deviceID != kAudioObjectUnknown else {
            throw NoDefaultOutputDeviceError()
        }
        return deviceID
    }

    public static func defaultInputDevice() throws -> AudioDeviceID {
        let deviceID: AudioDeviceID = try readScalar(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultInputDevice,
            defaultValue: AudioDeviceID(kAudioObjectUnknown),
            operation: "Read default input device"
        )
        guard deviceID != kAudioObjectUnknown else {
            throw NoDefaultInputDeviceError()
        }
        return deviceID
    }

    public static func audioDeviceIDs() throws -> [AudioDeviceID] {
        try readAudioObjectIDArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices,
            operation: "Read audio device list"
        )
    }

    public static func deviceID(forUID uid: String) throws -> AudioDeviceID? {
        for deviceID in try audioDeviceIDs() where (try? deviceUID(deviceID)) == uid {
            return deviceID
        }
        return nil
    }

    public static func deviceName(_ deviceID: AudioDeviceID) throws -> String {
        try readString(
            objectID: deviceID,
            selector: kAudioObjectPropertyName,
            operation: "Read device name"
        )
    }

    public static func deviceUID(_ deviceID: AudioDeviceID) throws -> String {
        try readString(
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceUID,
            operation: "Read output device UID"
        )
    }

    public static func deviceSummary(_ deviceID: AudioDeviceID) throws -> AudioDeviceSummary {
        let name = try deviceName(deviceID)
        let uid = try deviceUID(deviceID)
        return AudioDeviceSummary(id: deviceID, name: name, uid: uid)
    }

    public static func outputStreamIDs(_ deviceID: AudioDeviceID) throws -> [AudioObjectID] {
        try readAudioObjectIDArray(
            objectID: deviceID,
            selector: kAudioDevicePropertyStreams,
            scope: kAudioDevicePropertyScopeOutput,
            operation: "Read output stream list"
        )
    }

    public static func inputStreamIDs(_ deviceID: AudioDeviceID) throws -> [AudioObjectID] {
        try readAudioObjectIDArray(
            objectID: deviceID,
            selector: kAudioDevicePropertyStreams,
            scope: kAudioDevicePropertyScopeInput,
            operation: "Read input stream list"
        )
    }

    public static func processObjectID(forPID pid: pid_t) throws -> AudioObjectID? {
        let processIDs = try readAudioObjectIDArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList,
            operation: "Read Core Audio process object list"
        )

        for processID in processIDs {
            let processPID: pid_t = try readScalar(
                objectID: processID,
                selector: kAudioProcessPropertyPID,
                defaultValue: 0,
                operation: "Read process PID"
            )
            if processPID == pid {
                return processID
            }
        }

        return nil
    }

    public static func tapUID(_ tapID: AudioObjectID) throws -> String {
        try readString(
            objectID: tapID,
            selector: kAudioTapPropertyUID,
            operation: "Read process tap UID"
        )
    }

    public static func tapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        try readScalar(
            objectID: tapID,
            selector: kAudioTapPropertyFormat,
            defaultValue: AudioStreamBasicDescription(),
            operation: "Read process tap format"
        )
    }

    public static func tapDescription(_ tapID: AudioObjectID) throws -> CATapDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CATapDescription>?
        var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        let status = withUnsafeMutableBytes(of: &value) { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return kAudioHardwareUnspecifiedError
            }
            return AudioObjectGetPropertyData(
                tapID,
                &address,
                0,
                nil,
                &size,
                baseAddress
            )
        }
        try checkOSStatus(status, operation: "Read process tap description")

        guard let value else {
            throw SonexisError(message: "Read process tap description returned nil")
        }
        return value.takeRetainedValue()
    }

    public static func streamVirtualFormat(_ streamID: AudioObjectID) throws -> AudioStreamBasicDescription {
        try readScalar(
            objectID: streamID,
            selector: kAudioStreamPropertyVirtualFormat,
            defaultValue: AudioStreamBasicDescription(),
            operation: "Read output stream virtual format"
        )
    }
}

public struct AudioDeviceSummary: CustomStringConvertible {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String

    public init(id: AudioDeviceID, name: String, uid: String) {
        self.id = id
        self.name = name
        self.uid = uid
    }

    public var description: String {
        "\(name) [AudioObjectID \(id), UID \(uid)]"
    }
}

extension AudioStreamBasicDescription {
    public var isFloat32LinearPCM: Bool {
        mFormatID == kAudioFormatLinearPCM &&
            (mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
            mBitsPerChannel == 32
    }

    public var isNonInterleaved: Bool {
        (mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    }

    public func isPlaybackCompatible(with other: AudioStreamBasicDescription) -> Bool {
        isFloat32LinearPCM &&
            other.isFloat32LinearPCM &&
            mChannelsPerFrame == other.mChannelsPerFrame &&
            abs(mSampleRate - other.mSampleRate) < 1.0
    }

    public var formatSummary: String {
        let flags = String(mFormatFlags, radix: 16)
        let layout = isNonInterleaved ? "non-interleaved" : "interleaved"
        return "sampleRate=\(mSampleRate), channels=\(mChannelsPerFrame), bytesPerFrame=\(mBytesPerFrame), bitsPerChannel=\(mBitsPerChannel), flags=0x\(flags), \(layout)"
    }
}
