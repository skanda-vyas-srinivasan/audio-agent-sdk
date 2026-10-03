import Foundation

/// Teardown can wait for discovery that needs the AppKit main run loop.
func performRuntimeShutdown(stop: @escaping () -> Void, completed: @escaping () -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        stop()
        completed()
    }
}
