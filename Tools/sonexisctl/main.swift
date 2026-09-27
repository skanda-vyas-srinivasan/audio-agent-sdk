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
    let destination: String
    let targetBufferMilliseconds: UInt32

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
        var destination = "default"
        var targetBufferMilliseconds: UInt32 = 60
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
            case "--destination":
                index += 1
                guard index < values.count, !values[index].isEmpty else {
                    throw RuntimeErrorDTO(code: "usage", message: "--destination requires an ID")
                }
                destination = values[index]
            case "--target-buffer-ms":
                index += 1
                guard index < values.count, let value = UInt32(values[index]) else {
                    throw RuntimeErrorDTO(code: "usage", message: "--target-buffer-ms requires an integer")
                }
                targetBufferMilliseconds = value
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
        self.destination = destination
        self.targetBufferMilliseconds = targetBufferMilliseconds
    }

    static let usage = """
    Usage:
      sonexisctl sources [--json]
      sonexisctl status [session-id] [--json]
      sonexisctl capture <source-id> [--sample-rate Hz] [--channels 1|2] \
        [--sample-format pcm_s16le|float32_le] [--output file.pcm] [--debug]
      sonexisctl stop <session-id> [--json]
      sonexisctl watch [--json]
      sonexisctl outputs [--json]
      sonexisctl play <file.wav|file.pcm> [--destination ID] [--target-buffer-ms 20...250] \
        [--sample-rate Hz] [--channels 1|2] [--sample-format pcm_s16le|float32_le] [--debug]
      sonexisctl output-status <session-id> [--json]
      sonexisctl output-flush <session-id> [--json]
      sonexisctl output-stop <session-id> [--json]
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

private func printOutputSession(_ session: RuntimeOutputSessionDTO) {
    let metrics = session.metrics
    print("output_session=\(session.id) stream=\(session.streamID) state=\(session.state.rawValue) destination=\(session.destinationID) format=\(session.format.sampleFormat.rawValue)/\(session.format.sampleRate)Hz/\(session.format.channelCount)ch received=\(metrics.inputFramesReceived) rendered=\(metrics.deviceFramesRendered) dropped=\(metrics.droppedFrames) buffered_ms=\(String(format: "%.2f", metrics.bufferedMilliseconds))")
}

private struct AudioFilePayload {
    let format: RuntimePCMFormatDTO
    let pcm: Data
}

private func readPrivateRegularFile(path: String) throws -> Data {
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else {
        throw RuntimeErrorDTO(code: "input_error",
            message: "Could not securely open \(path): \(String(cString: strerror(errno)))")
    }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
        let savedError = errno
        close(descriptor)
        throw RuntimeErrorDTO(code: "input_error",
            message: "Input must be a regular file: \(String(cString: strerror(savedError)))")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    return try handle.readToEnd() ?? Data()
}

private func littleUInt16(_ data: Data, _ offset: Int) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
}

private func littleUInt32(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 |
        UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
}

private func loadAudioFile(path: String, rawFormat: RuntimePCMFormatDTO) throws -> AudioFilePayload {
    let data = try readPrivateRegularFile(path: path)
    guard URL(fileURLWithPath: path).pathExtension.lowercased() == "wav" else {
        guard !data.isEmpty, data.count % rawFormat.bytesPerFrame == 0 else {
            throw RuntimeErrorDTO(code: "invalid_audio_file",
                message: "Raw PCM must contain complete non-empty sample frames")
        }
        return AudioFilePayload(format: rawFormat, pcm: data)
    }
    guard data.count >= 12, Data(data[0..<4]) == Data("RIFF".utf8),
          Data(data[8..<12]) == Data("WAVE".utf8) else {
        throw RuntimeErrorDTO(code: "invalid_wav", message: "WAV file has an invalid RIFF header")
    }
    var offset = 12
    var waveFormat: RuntimePCMFormatDTO?
    var payload: Data?
    while offset + 8 <= data.count {
        let chunkID = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
        let size = Int(littleUInt32(data, offset + 4))
        let body = offset + 8
        guard size >= 0, body <= data.count, size <= data.count - body else {
            throw RuntimeErrorDTO(code: "invalid_wav", message: "WAV chunk length is invalid")
        }
        if chunkID == "fmt " {
            guard size >= 16 else {
                throw RuntimeErrorDTO(code: "invalid_wav", message: "WAV format chunk is truncated")
            }
            let encoding = littleUInt16(data, body)
            let channels = littleUInt16(data, body + 2)
            let sampleRate = littleUInt32(data, body + 4)
            let bits = littleUInt16(data, body + 14)
            let sampleFormat: RuntimeSampleFormatDTO
            if encoding == 1, bits == 16 { sampleFormat = .pcmS16LE }
            else if encoding == 3, bits == 32 { sampleFormat = .float32LE }
            else {
                throw RuntimeErrorDTO(code: "unsupported_wav",
                    message: "Only PCM16 and Float32 WAV files are supported")
            }
            waveFormat = RuntimePCMFormatDTO(sampleRate: sampleRate,
                channelCount: channels, sampleFormat: sampleFormat)
        } else if chunkID == "data" {
            payload = Data(data[body..<(body + size)])
        }
        offset = body + size + (size & 1)
    }
    guard let format = waveFormat, format.isSupported, let pcm = payload,
          !pcm.isEmpty, pcm.count % format.bytesPerFrame == 0 else {
        throw RuntimeErrorDTO(code: "unsupported_wav",
            message: "WAV format must match a Runtime-supported interleaved PCM format")
    }
    return AudioFilePayload(format: format, pcm: pcm)
}

private func secureOutputHandle(path: String) throws -> FileHandle {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
                          mode_t(0o600))
    guard descriptor >= 0 else {
        throw RuntimeErrorDTO(code: "output_error",
            message: "Could not securely open \(path): \(String(cString: strerror(errno)))")
    }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
          status.st_uid == geteuid(), fchmod(descriptor, mode_t(0o600)) == 0,
          ftruncate(descriptor, 0) == 0 else {
        let savedError = errno
        close(descriptor)
        throw RuntimeErrorDTO(code: "output_error",
            message: "Output must be a private regular file: \(String(cString: strerror(savedError)))")
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
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
            handle = try secureOutputHandle(path: path)
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
                print("output_sessions=\(status.activeOutputSessions ?? 0) output_started=\(status.totalOutputSessionsStarted ?? 0) output_received=\(status.totalOutputFramesReceived ?? 0) output_rendered=\(status.totalOutputFramesRendered ?? 0) output_dropped=\(status.totalOutputFramesDropped ?? 0) output_bytes=\(status.totalOutputBytesReceived ?? 0)")
            }
        }
    case "outputs":
        let destinations = try client.listOutputDestinations()
        if arguments.json { try printJSON(destinations); break }
        print("ID                          STATUS     DESTINATION")
        for destination in destinations {
            print("\(destination.id.padding(toLength: 27, withPad: " ", startingAt: 0)) \((destination.isAvailable ? "available" : "missing").padding(toLength: 10, withPad: " ", startingAt: 0)) \(destination.name)\(destination.activeDeviceName.map { " (\($0))" } ?? "")")
        }
    case "play":
        guard let path = arguments.value else {
            throw RuntimeErrorDTO(code: "usage", message: Arguments.usage)
        }
        let audio = try loadAudioFile(path: path, rawFormat: arguments.format)
        let session = try client.startOutput(destinationID: arguments.destination,
            format: audio.format,
            targetBufferMilliseconds: arguments.targetBufferMilliseconds)
        if !arguments.json { printOutputSession(session) }
        let writer = try client.outputWriter(session: session)
        do {
            try writer.write(audio.pcm)
            try writer.finish()
        } catch {
            writer.cancel()
            _ = try? client.stopOutput(outputSessionID: session.id)
            throw error
        }
        var final = session
        for _ in 0..<300 {
            final = try client.outputStatus(outputSessionID: session.id)
            if final.state == .stopped || final.state == .failed || final.state == .cancelled { break }
            usleep(20_000)
        }
        if final.state == .ready || final.state == .draining || final.state == .starting {
            final = try client.stopOutput(outputSessionID: session.id)
            throw RuntimeErrorDTO(code: "output_drain_timeout",
                message: "Playback did not drain within six seconds", retryable: true)
        }
        if arguments.json { try printJSON(final) }
        else if arguments.debug { printOutputSession(final) }
        if let error = final.error { throw error }
    case "output-status":
        guard let id = arguments.value else { throw RuntimeErrorDTO(code: "usage", message: Arguments.usage) }
        let session = try client.outputStatus(outputSessionID: id)
        if arguments.json { try printJSON(session) } else { printOutputSession(session) }
    case "output-flush":
        guard let id = arguments.value else { throw RuntimeErrorDTO(code: "usage", message: Arguments.usage) }
        let session = try client.flushOutput(outputSessionID: id)
        if arguments.json { try printJSON(session) } else { printOutputSession(session) }
    case "output-stop":
        guard let id = arguments.value else { throw RuntimeErrorDTO(code: "usage", message: Arguments.usage) }
        let session = try client.stopOutput(outputSessionID: id)
        if arguments.json { try printJSON(session) } else { printOutputSession(session) }
    case "watch":
        let subscription = try client.subscribeEvents(RuntimeEventTypeDTO.allCases)
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
