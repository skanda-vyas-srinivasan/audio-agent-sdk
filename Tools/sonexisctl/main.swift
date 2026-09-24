import Darwin
import Foundation

private struct Arguments {
    let command: String
    let value: String?
    let output: String?
    let debug: Bool
    let json: Bool
    let socketPath: String
    let format: RuntimePCMFormatDTO

    init(_ values: [String]) throws {
        guard let command = values.first else { throw RuntimeErrorDTO(code: "usage", message: Self.usage) }
        self.command = command
        var positional: [String] = []
        var output: String?
        var socketPath = ProcessInfo.processInfo.environment["SONEXIS_RUNTIME_SOCKET"]
            ?? RuntimeSocketPaths.userDefault.controlSocketPath
        var debug = false
        var json = false
        var sampleRate: UInt32 = 16_000
        var channels: UInt16 = 1
        var sampleFormat = RuntimeSampleFormatDTO.pcmS16LE
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
            case "--sample-rate":
                index += 1
                guard index < values.count, let value = UInt32(values[index]) else {
                    throw RuntimeErrorDTO(code: "usage", message: "--sample-rate requires an integer")
                }
                sampleRate = value
            case "--channels":
                index += 1
                guard index < values.count, let value = UInt16(values[index]) else {
                    throw RuntimeErrorDTO(code: "usage", message: "--channels requires an integer")
                }
                channels = value
            case "--sample-format":
                index += 1
                guard index < values.count, let value = RuntimeSampleFormatDTO(rawValue: values[index]) else {
                    throw RuntimeErrorDTO(code: "usage", message: "--sample-format must be pcm_s16le or float32_le")
                }
                sampleFormat = value
            case "--debug": debug = true
            case "--json": json = true
            default:
                if values[index].hasPrefix("-") {
                    throw RuntimeErrorDTO(code: "usage", message: "Unknown option: \(values[index])")
                }
                positional.append(values[index])
            }
            index += 1
        }
        guard positional.count <= 1 else { throw RuntimeErrorDTO(code: "usage", message: Self.usage) }
        value = positional.first
        self.output = output
        self.debug = debug
        self.json = json
        self.socketPath = socketPath
        format = RuntimePCMFormatDTO(sampleRate: sampleRate, channelCount: channels,
            sampleFormat: sampleFormat)
    }

    static let usage = """
    Usage:
      sonexisctl sources [--json]
      sonexisctl status [session-id] [--json]
      sonexisctl capture <source-id> [--sample-rate Hz] [--channels 1|2] \
        [--sample-format pcm_s16le|float32_le] [--output file.pcm] [--debug]
      sonexisctl stop <session-id> [--json]
      sonexisctl watch [--json]
      append --socket PATH to any command
    """
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let line = try RuntimeProtocolCodec.encodeLine(value)
    FileHandle.standardOutput.write(line)
}

private func printSession(_ session: RuntimeSessionDTO) {
    print("session=\(session.id) stream=\(session.streamID) state=\(session.state.rawValue) source=\(session.sourceID) format=\(session.format.sampleFormat.rawValue)/\(session.format.sampleRate)Hz/\(session.format.channelCount)ch frames=\(session.metrics.framesForwarded) dropped=\(session.metrics.droppedFrames)")
}

do {
    let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
    if ["help", "--help", "-h"].contains(arguments.command) {
        print(Arguments.usage)
        exit(EXIT_SUCCESS)
    }
    let client = SonexisRuntimeClient(controlSocketPath: arguments.socketPath)
    try client.connect(clientName: "sonexisctl")

    switch arguments.command {
    case "sources":
        let sources = try client.listSources()
        if arguments.json { try printJSON(sources); break }
        print("\("ID".padding(toLength: 42, withPad: " ", startingAt: 0))  \("STATUS".padding(toLength: 8, withPad: " ", startingAt: 0))  APP")
        for source in sources {
            print("\(source.id.padding(toLength: 42, withPad: " ", startingAt: 0))  \((source.isAvailable ? "active" : "inactive").padding(toLength: 8, withPad: " ", startingAt: 0))  \(source.name)")
        }
    case "capture":
        guard let sourceID = arguments.value else { throw RuntimeErrorDTO(code: "usage", message: Arguments.usage) }
        let session = try client.startCapture(sourceID: sourceID, format: arguments.format)
        if arguments.json { try printJSON(session) } else { printSession(session) }
        let handle: FileHandle?
        if let path = arguments.output {
            guard FileManager.default.createFile(atPath: path, contents: nil) else {
                throw RuntimeErrorDTO(code: "output_error", message: "Could not create \(path)")
            }
            handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        } else { handle = nil }
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
        var dropped: UInt64 = 0
        let started = DispatchTime.now().uptimeNanoseconds
        try client.receiveFrames(session: session) { frame in
            try handle?.write(contentsOf: frame.payload)
            frames &+= UInt64(frame.header.frameCount)
            bytes &+= UInt64(frame.payload.count)
            dropped &+= UInt64(frame.header.droppedFramesBefore)
            return true
        }
        if arguments.debug {
            let duration = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            fputs("received_frames=\(frames) received_bytes=\(bytes) dropped_frames=\(dropped) duration_seconds=\(String(format: "%.3f", duration))\n", stderr)
        }
    case "stop":
        guard let id = arguments.value else { throw RuntimeErrorDTO(code: "usage", message: Arguments.usage) }
        let session = try client.stopCapture(sessionID: id)
        if arguments.json { try printJSON(session) } else { printSession(session) }
    case "status":
        if let id = arguments.value {
            let session = try client.sessionStatus(sessionID: id)
            if arguments.json { try printJSON(session) } else { printSession(session) }
        } else {
            let status = try client.runtimeStatus()
            if arguments.json { try printJSON(status) }
            else {
                print("runtime=\(status.runtimeVersion) instance=\(status.runtimeInstanceID)")
                print("uptime_seconds=\(String(format: "%.3f", Double(status.uptimeNanoseconds) / 1e9)) clients=\(status.activeClients) sessions=\(status.activeSessions) event_subscribers=\(status.eventSubscribers)")
                print("sessions_started=\(status.totalSessionsStarted) frames=\(status.totalFramesForwarded) dropped=\(status.totalDroppedFrames) bytes=\(status.totalBytesTransmitted) events_dropped=\(status.totalEventsDropped)")
            }
        }
    case "watch":
        let subscription = try client.subscribeEvents()
        defer { try? client.unsubscribeEvents(id: subscription.id) }
        try client.receiveEvents(subscription: subscription) { event in
            if arguments.json { try printJSON(event) }
            else {
                let sequence = event.eventSequence.map(String.init) ?? "-"
                let missed = event.droppedEventsBefore ?? 0
                print("\(event.timestampNanoseconds) seq=\(sequence) missed=\(missed) \(event.type.rawValue) source=\(event.sourceID ?? "-") session=\(event.sessionID ?? "-") \(event.message ?? "")")
            }
            return true
        }
    default:
        throw RuntimeErrorDTO(code: "usage", message: Arguments.usage)
    }
} catch {
    fputs("sonexisctl: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
