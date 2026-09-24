import Darwin
import Foundation

private struct Arguments {
    let command: String
    let value: String?
    let output: String?
    let debug: Bool
    let socketPath: String

    init(_ values: [String]) throws {
        guard let command = values.first else { throw RuntimeErrorDTO(code: "usage", message: Self.usage) }
        self.command = command
        var positional: [String] = []
        var output: String?
        var socketPath = ProcessInfo.processInfo.environment["SONEXIS_RUNTIME_SOCKET"]
            ?? RuntimeSocketPaths.userDefault.controlSocketPath
        var debug = false
        var index = 1
        while index < values.count {
            switch values[index] {
            case "--output":
                index += 1
                guard index < values.count else { throw RuntimeErrorDTO(code: "usage", message: "--output requires a path") }
                output = values[index]
            case "--socket":
                index += 1
                guard index < values.count else { throw RuntimeErrorDTO(code: "usage", message: "--socket requires a path") }
                socketPath = values[index]
            case "--debug":
                debug = true
            default:
                if values[index].hasPrefix("-") {
                    throw RuntimeErrorDTO(code: "usage", message: "Unknown option: \(values[index])")
                }
                positional.append(values[index])
            }
            index += 1
        }
        guard positional.count <= 1 else {
            throw RuntimeErrorDTO(code: "usage", message: Self.usage)
        }
        value = positional.first
        self.output = output
        self.debug = debug
        self.socketPath = socketPath
    }

    static let usage = "Usage: sonexisctl sources | capture <source-id> [--output file.pcm] [--debug] | stop <session-id> | status <session-id> [--socket path]"
}

private func printSession(_ session: RuntimeSessionDTO) {
    print("session=\(session.id) state=\(session.state.rawValue) source=\(session.sourceID) format=\(session.format.sampleRate)Hz/\(session.format.channelCount)ch/\(session.format.bitsPerChannel)bit")
}

do {
    let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
    if ["help", "--help", "-h"].contains(arguments.command) {
        print(Arguments.usage)
        exit(EXIT_SUCCESS)
    }
    let client = SonexisRuntimeClient(controlSocketPath: arguments.socketPath)
    try client.connect()

    switch arguments.command {
    case "sources":
        let sources = try client.listSources()
        print("\("ID".padding(toLength: 42, withPad: " ", startingAt: 0))  \("STATUS".padding(toLength: 8, withPad: " ", startingAt: 0))  APP")
        for source in sources {
            print("\(source.id.padding(toLength: 42, withPad: " ", startingAt: 0))  \((source.isActive ? "active" : "inactive").padding(toLength: 8, withPad: " ", startingAt: 0))  \(source.name)")
        }
    case "capture":
        guard let sourceID = arguments.value else { throw RuntimeErrorDTO(code: "usage", message: Arguments.usage) }
        let session = try client.startCapture(sourceID: sourceID)
        printSession(session)
        let handle: FileHandle?
        if let path = arguments.output {
            guard FileManager.default.createFile(atPath: path, contents: nil) else {
                throw RuntimeErrorDTO(code: "output_error", message: "Could not create \(path)")
            }
            handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        } else {
            handle = nil
        }
        defer { try? handle?.close() }

        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler {
            _ = try? client.stopCapture(sessionID: session.id)
            client.disconnect()
        }
        interrupt.resume()
        var frames: UInt64 = 0
        var bytes: UInt64 = 0
        let started = DispatchTime.now().uptimeNanoseconds
        try client.receiveFrames(session: session) { frame in
            try handle?.write(contentsOf: frame.payload)
            frames &+= UInt64(frame.header.frameCount)
            bytes &+= UInt64(frame.payload.count)
            return true
        }
        if arguments.debug {
            let duration = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            fputs("received_frames=\(frames) received_bytes=\(bytes) duration_seconds=\(String(format: "%.3f", duration))\n", stderr)
        }
    case "stop":
        guard let id = arguments.value else { throw RuntimeErrorDTO(code: "usage", message: Arguments.usage) }
        printSession(try client.stopCapture(sessionID: id))
    case "status":
        guard let id = arguments.value else { throw RuntimeErrorDTO(code: "usage", message: Arguments.usage) }
        printSession(try client.sessionStatus(sessionID: id))
    default:
        throw RuntimeErrorDTO(code: "usage", message: Arguments.usage)
    }
} catch {
    fputs("sonexisctl: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
