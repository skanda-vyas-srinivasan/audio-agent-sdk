import CoreAudio
import XCTest
import SonexisAudioEngine
@testable import SonexisRuntime

private struct Property: Hashable {
    let object: AudioObjectID
    let selector: AudioObjectPropertySelector
    let scope: AudioObjectPropertyScope
}

private final class Listeners {
    var properties: Set<Property> = []
    var blocks: [Property: AudioObjectPropertyListenerBlock] = [:]
    var addAttempts = 0
    var failOnAdd: Int?
    var operations: CapturePropertyListeners {
        CapturePropertyListeners(add: { object, address, _, block in
            self.addAttempts += 1
            if self.addAttempts == self.failOnAdd { return kAudioHardwareUnspecifiedError }
            let property = Property(object: object, selector: address.mSelector, scope: address.mScope)
            self.properties.insert(property)
            self.blocks[property] = block
            return noErr
        }, remove: { object, address, _, _ in
            let property = Property(object: object, selector: address.mSelector, scope: address.mScope)
            self.properties.remove(property)
            self.blocks.removeValue(forKey: property)
            return noErr
        })
    }
}

final class FormatChangeTests: XCTestCase {
    private func settle(_ queue: DispatchQueue) {
        let settled = expectation(description: "queued format callbacks settled")
        queue.asyncAfter(deadline: .now() + .milliseconds(150)) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
    }

    private func emit(_ block: AudioObjectPropertyListenerBlock) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        block(1, &address)
    }

    func testCaptureSubscribesToSameDeviceRateAndStreamFormatChanges() throws {
        let listeners = Listeners()
        let source = AudioSource(id: "app.test", kind: .application, name: "Test",
            bundleIdentifier: "com.audioplane.test", processIdentifiers: [1], state: .active)
        let capture = try AudioCaptureSession(source: source, frameHandler: nil,
            onTermination: nil, propertyListeners: listeners.operations)
        try capture.installDefaultOutputListener()
        try capture.installDeviceFormatListeners(deviceID: 77, streamIDs: [88])
        XCTAssertTrue(listeners.properties.contains(Property(object: 77,
            selector: kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeGlobal)),
            "default-device identity notifications miss a rate change on the same device")
        XCTAssertTrue(listeners.properties.contains(Property(object: 88,
            selector: kAudioStreamPropertyVirtualFormat, scope: kAudioObjectPropertyScopeGlobal)),
            "capture has no notification when its existing stream format changes")
        XCTAssertTrue(listeners.properties.contains(Property(object: 88,
            selector: kAudioStreamPropertyPhysicalFormat, scope: kAudioObjectPropertyScopeGlobal)))
        capture.stop()
        XCTAssertEqual(listeners.properties, [])
    }

    func testSameDeviceRateAndFormatBurstRequestsOneRebuild() throws {
        let queue = DispatchQueue(label: "FormatChangeTests.Burst")
        let listeners = Listeners()
        var changes = 0
        var pauses = 0
        let observer = CaptureDeviceFormatObserver(queue: queue, listeners: listeners.operations,
            willChange: { pauses += 1 }) {
            changes += 1
        }
        try queue.sync {
            try observer.install(deviceID: 77, streamIDs: [88])
            for block in listeners.blocks.values { emit(block); emit(block) }
            XCTAssertEqual(pauses, 1, "conversion must pause immediately rather than run during debounce")
            XCTAssertEqual(changes, 0)
        }
        settle(queue)
        queue.sync {
            XCTAssertEqual(changes, 1, "one device transition must not rebuild once per property")
            observer.remove()
            XCTAssertEqual(listeners.properties, [])
        }
    }

    func testRemovalAndReplacementInvalidateLateAndPendingCallbacks() throws {
        let queue = DispatchQueue(label: "FormatChangeTests.Epoch")
        let listeners = Listeners()
        var changes = 0
        let observer = CaptureDeviceFormatObserver(queue: queue, listeners: listeners.operations) {
            changes += 1
        }
        try queue.sync {
            try observer.install(deviceID: 77, streamIDs: [88])
            let old = listeners.blocks.values.first!
            emit(old) // A rebuild is pending when the device is retired.
            observer.remove()
            try observer.install(deviceID: 99, streamIDs: [100])
            emit(old) // HAL may have already queued a callback for the old device.
        }
        settle(queue)
        queue.sync { XCTAssertEqual(changes, 0) }
        queue.sync { emit(listeners.blocks.values.first!) }
        settle(queue)
        queue.sync {
            XCTAssertEqual(changes, 1)
            observer.remove()
        }
    }

    func testPartialRegistrationFailureCleansUpAndCanRetry() throws {
        let queue = DispatchQueue(label: "FormatChangeTests.Failure")
        let listeners = Listeners()
        listeners.failOnAdd = 3
        let observer = CaptureDeviceFormatObserver(queue: queue, listeners: listeners.operations) {}
        XCTAssertThrowsError(try queue.sync { try observer.install(deviceID: 77, streamIDs: [88]) })
        XCTAssertEqual(listeners.properties, [])
        XCTAssertEqual(listeners.blocks.count, 0)
        try queue.sync {
            listeners.failOnAdd = nil
            try observer.install(deviceID: 77, streamIDs: [88])
            XCTAssertEqual(listeners.properties.count, 5)
            observer.remove()
            observer.remove()
            XCTAssertEqual(listeners.properties, [])
        }
    }
}
