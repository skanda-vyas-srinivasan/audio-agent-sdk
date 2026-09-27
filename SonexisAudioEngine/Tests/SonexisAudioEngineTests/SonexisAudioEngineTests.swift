import CoreAudio
import XCTest
@testable import SonexisAudioEngine

final class SonexisAudioEngineTests: XCTestCase {
    func testPackageBoundaryBuildsIndependently() {
        _ = SonexisAudioEngineModule.self
    }

    func testSourceIdentityAndPIDOrderingRemainStable() {
        let source = AudioSource(
            id: AudioSource.applicationID(bundleIdentifier: "com.example.Player"),
            kind: .application,
            name: "Player",
            bundleIdentifier: "com.example.Player",
            processIdentifiers: [42, 7, 19],
            state: .active
        )

        XCTAssertEqual(source.id, "app.com.example.Player")
        XCTAssertEqual(source.processIdentifiers, [7, 19, 42])
    }

    func testProcessSelectionPreservesSelfExclusionRules() {
        XCTAssertEqual(
            ProcessTapSelection.only([3, 2, 0, 3]).safeProcessIDs(ownProcessID: 2),
            [3]
        )
        XCTAssertEqual(
            ProcessTapSelection.allAudio(excluding: [9, 4]).safeProcessIDs(ownProcessID: 7),
            [4, 7, 9]
        )
    }

    func testRealtimeRingPreservesOrderingAndBoundedCapacity() throws {
        let ring = try RealtimeRingBuffer(capacityFrames: 4, channels: 1)
        let input: [Float] = [0.25, -0.5, 0.75, -1]
        let written = input.withUnsafeBufferPointer {
            ring.writeInterleaved($0.baseAddress!, frames: 4)
        }
        XCTAssertEqual(written, 4)
        XCTAssertEqual(ring.fillFrames, 4)

        var output = [Float](repeating: 0, count: 4)
        let read = output.withUnsafeMutableBufferPointer {
            ring.readInterleaved($0.baseAddress!, frames: 4)
        }
        XCTAssertEqual(read, 4)
        XCTAssertEqual(output, input)
        XCTAssertEqual(ring.fillFrames, 0)
        XCTAssertEqual(ring.writtenFrames, 4)
        XCTAssertEqual(ring.readFrames, 4)
    }
}
