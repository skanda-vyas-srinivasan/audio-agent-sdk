import AppKit
import Foundation

// A silent, windowless GUI application: discovery needs no audio/TCC grant.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
try String(ProcessInfo.processInfo.processIdentifier).write(
    toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { app.terminate(nil) }
app.run()
