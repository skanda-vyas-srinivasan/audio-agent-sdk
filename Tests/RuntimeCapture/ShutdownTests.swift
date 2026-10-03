import Foundation
import XCTest
@testable import SonexisRuntime

final class ShutdownTests: XCTestCase {
    func testShutdownKeepsMainRunLoopAvailableToDiscovery() {
        let monitor = DispatchQueue(label: "ShutdownTests.Monitor")
        let beginLookup = DispatchSemaphore(value: 0)
        let lookupDone = DispatchSemaphore(value: 0)
        let stopped = expectation(description: "shutdown completed")
        monitor.async {
            beginLookup.wait()
            DispatchQueue.main.sync {} // The production NSWorkspace lookup boundary.
            lookupDone.signal()
        }
        let request = {
            performRuntimeShutdown(stop: {
                beginLookup.signal()
                // Bound the failing reproduction instead of hanging the runner.
                XCTAssertEqual(lookupDone.wait(timeout: .now() + 1), .success,
                    "shutdown blocked the main run loop needed by discovery")
            }, completed: { stopped.fulfill() })
        }
        if Thread.isMainThread { request() }
        else { DispatchQueue.main.sync(execute: request) }
        wait(for: [stopped], timeout: 2)
    }
}
