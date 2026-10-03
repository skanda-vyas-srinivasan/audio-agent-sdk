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

    func testCaptureDropsFollowRetainedAudioAndSplitAtTheGap() throws {
        let ring = try RealtimeRingBuffer(capacityFrames: 4, channels: 1, trackCaptureDrops: true)
        func write(_ samples: [Float]) {
            samples.withUnsafeBufferPointer {
                _ = ring.writeInterleaved($0.baseAddress!, frames: UInt32(samples.count))
            }
        }
        func read(_ requested: UInt32) -> (samples: [Float], drops: UInt64) {
            var drops: UInt64 = 0
            var samples = [Float](repeating: 0, count: Int(requested))
            let count = samples.withUnsafeMutableBufferPointer {
                ring.readCaptureInterleaved($0.baseAddress!, frames: requested,
                                            droppedFramesBefore: &drops)
            }
            return (Array(samples.prefix(Int(count))), drops)
        }
        write([1, 2, 3, 4, 5, 6]) // Retain 1..4; reject the newer 5..6.
        XCTAssertEqual(ring.droppedFrames, 2)
        let first = read(2)
        XCTAssertEqual(first.samples, [1, 2])
        XCTAssertEqual(first.drops, 0, "newer rejected audio must not precede old samples")
        write([7, 8]) // Ring now contains pre-gap 3..4 followed by post-gap 7..8.
        let before = read(4)
        XCTAssertEqual(before.samples, [3, 4], "a packet must not straddle a native gap")
        XCTAssertEqual(before.drops, 0)
        let after = read(4)
        XCTAssertEqual(after.samples, [7, 8])
        XCTAssertEqual(after.drops, 2)
        write([9])
        XCTAssertEqual(read(4).drops, 0, "a gap must be reported exactly once")
        write([10, 11, 12, 13, 14])
        write([15, 16]) // Fully rejected; no new retained packet exists yet.
        XCTAssertEqual(read(4).samples, [10, 11, 12, 13])
        let empty = read(4)
        XCTAssertEqual(empty.samples, [])
        XCTAssertEqual(empty.drops, 0, "empty reads must not consume a future gap")
        write([17, 18])
        let resumed = read(4)
        XCTAssertEqual(resumed.samples, [17, 18])
        XCTAssertEqual(resumed.drops, 3)
    }
}
