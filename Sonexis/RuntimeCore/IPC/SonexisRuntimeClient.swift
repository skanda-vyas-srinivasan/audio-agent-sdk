import Foundation

public final class SonexisRuntimeClient: @unchecked Sendable {
    public let controlSocketPath: String
    public private(set) var handshake: RuntimeHandshakeDTO?
    private let requestLock = NSLock()
    private let connectionLock = NSLock()
    private var controlConnection: UnixSocketConnection?
    private var responseParser = RuntimeNDJSONParser()
    private var pendingResponses: [Data] = []

    public init(controlSocketPath: String = RuntimeSocketPaths.userDefault.controlSocketPath) {
        self.controlSocketPath = controlSocketPath
    }

    deinit { disconnect() }

    public func connect(clientName: String = "sonexis-swift-client",
                        clientVersion: String = RuntimeProtocolInfo.runtimeVersion) throws {
        connectionLock.lock()
        if controlConnection != nil { connectionLock.unlock(); return }
        do {
            controlConnection = try UnixSocketSystem.connect(path: controlSocketPath)
            connectionLock.unlock()
        } catch {
            connectionLock.unlock()
            throw error
        }
        do {
            let response = try request(RuntimeCommand(command: .hello,
                supportedProtocolVersions: [RuntimeProtocolInfo.protocolVersion],
                clientName: clientName, clientVersion: clientVersion))
            guard let handshake = response.handshake,
                  handshake.protocolVersion == RuntimeProtocolInfo.protocolVersion else {
                throw RuntimeErrorDTO(code: "invalid_handshake", message: "Runtime omitted a valid handshake")
            }
            self.handshake = handshake
        } catch {
            disconnect()
            throw error
        }
    }

    public func disconnect() {
        connectionLock.lock()
        let connection = controlConnection
        controlConnection = nil
        handshake = nil
        connectionLock.unlock()
        connection?.close()
        requestLock.lock()
        responseParser = RuntimeNDJSONParser()
        pendingResponses.removeAll()
        requestLock.unlock()
    }

    public func listSources() throws -> [RuntimeSourceDTO] {
        try request(RuntimeCommand(command: .listSources)).sources ?? []
    }

    public func startCapture(sourceID: String,
                             format: RuntimePCMFormatDTO = .runtimeDefault) throws -> RuntimeSessionDTO {
        let response = try request(RuntimeCommand(command: .startCapture,
            sourceID: sourceID, format: format))
        guard let session = response.session else {
            throw RuntimeErrorDTO(code: "invalid_response", message: "Runtime omitted the capture session")
        }
        return session
    }

    public func stopCapture(sessionID: String) throws -> RuntimeSessionDTO {
        let response = try request(RuntimeCommand(command: .stopCapture, sessionID: sessionID))
        guard let session = response.session else {
            throw RuntimeErrorDTO(code: "invalid_response", message: "Runtime omitted the capture session")
        }
        return session
    }

    public func sessionStatus(sessionID: String) throws -> RuntimeSessionDTO {
        let response = try request(RuntimeCommand(command: .sessionStatus, sessionID: sessionID))
        guard let session = response.session else {
            throw RuntimeErrorDTO(code: "invalid_response", message: "Runtime omitted the capture session")
        }
        return session
    }

    public func runtimeStatus() throws -> RuntimeStatusDTO {
        let response = try request(RuntimeCommand(command: .runtimeStatus))
        guard let status = response.status else {
            throw RuntimeErrorDTO(code: "invalid_response", message: "Runtime omitted diagnostics")
        }
        return status
    }

    public func listOutputDestinations() throws -> [RuntimeOutputDestinationDTO] {
        try request(RuntimeCommand(command: .listOutputDestinations)).outputDestinations ?? []
    }

    public func startOutput(destinationID: String = "default",
                            format: RuntimePCMFormatDTO = .runtimeDefault,
                            targetBufferMilliseconds: UInt32 = 60) throws -> RuntimeOutputSessionDTO {
        let response = try request(RuntimeCommand(command: .startOutput,
            format: format, destinationID: destinationID,
            targetBufferMilliseconds: targetBufferMilliseconds))
        guard let session = response.outputSession else {
            throw RuntimeErrorDTO(code: "invalid_response",
                message: "Runtime omitted the output session")
        }
        return session
    }

    public func outputStatus(outputSessionID: String) throws -> RuntimeOutputSessionDTO {
        let response = try request(RuntimeCommand(command: .outputStatus,
            outputSessionID: outputSessionID))
        guard let session = response.outputSession else {
            throw RuntimeErrorDTO(code: "invalid_response",
                message: "Runtime omitted the output session")
        }
        return session
    }

    public func flushOutput(outputSessionID: String) throws -> RuntimeOutputSessionDTO {
        let response = try request(RuntimeCommand(command: .flushOutput,
            outputSessionID: outputSessionID))
        guard let session = response.outputSession else {
            throw RuntimeErrorDTO(code: "invalid_response",
                message: "Runtime omitted the flushed output session")
        }
        return session
    }

    public func stopOutput(outputSessionID: String) throws -> RuntimeOutputSessionDTO {
        let response = try request(RuntimeCommand(command: .stopOutput,
            outputSessionID: outputSessionID))
        guard let session = response.outputSession else {
            throw RuntimeErrorDTO(code: "invalid_response",
                message: "Runtime omitted the stopped output session")
        }
        return session
    }

    public func outputWriter(session: RuntimeOutputSessionDTO) throws -> RuntimeOutputWriter {
        try RuntimeOutputWriter(session: session)
    }

    public func subscribeEvents(_ types: [RuntimeEventTypeDTO]? = nil) throws -> RuntimeEventSubscriptionDTO {
        let response = try request(RuntimeCommand(command: .subscribeEvents, eventTypes: types))
        guard let subscription = response.subscription else {
            throw RuntimeErrorDTO(code: "invalid_response", message: "Runtime omitted the event subscription")
        }
        return subscription
    }

    public func unsubscribeEvents(id: String) throws {
        _ = try request(RuntimeCommand(command: .unsubscribeEvents, subscriptionID: id))
    }

    public func receiveEvents(subscription: RuntimeEventSubscriptionDTO,
                              onEvent: (RuntimeEventDTO) throws -> Bool) throws {
        let connection = try UnixSocketSystem.connect(path: subscription.eventSocketPath)
        defer { connection.close() }
        var parser = RuntimeNDJSONParser()
        while true {
            let bytes: Data
            do { bytes = try connection.read() }
            catch UnixSocketError.disconnected { return }
            for line in try parser.append(bytes) {
                let event = try RuntimeProtocolCodec.decodeLine(RuntimeEventDTO.self, from: line)
                if try !onEvent(event) { return }
            }
        }
    }

    /// Blocks until EOS or `onFrame` returns false. Control requests remain
    /// available from another thread while this method is running.
    public func receiveFrames(session: RuntimeSessionDTO,
                              onFrame: (RuntimePCMFrame) throws -> Bool) throws {
        guard let streamID = UUID(uuidString: session.streamID) else {
            throw RuntimeErrorDTO(code: "invalid_stream_id", message: "Session has an invalid stream UUID")
        }
        let connection = try UnixSocketSystem.connect(path: session.dataSocketPath)
        defer { connection.close() }
        var decoder = RuntimePCMStreamDecoder(expectedStreamID: streamID)
        while true {
            let bytes: Data
            do {
                bytes = try connection.read(maximumBytes: 64 * 1024)
            } catch UnixSocketError.disconnected {
                try decoder.finish(requireEndOfStream: true)
                return
            }
            for frame in try decoder.append(bytes) {
                if frame.header.flags.contains(.endOfStream) { return }
                if try !onFrame(frame) { return }
            }
        }
    }

    private func request(_ command: RuntimeCommand) throws -> RuntimeResponse {
        requestLock.lock(); defer { requestLock.unlock() }
        connectionLock.lock()
        let connection = controlConnection
        connectionLock.unlock()
        guard let connection else {
            throw RuntimeErrorDTO(code: "not_connected", message: "Connect to Sonexis Runtime first")
        }
        try connection.write(RuntimeProtocolCodec.encodeLine(command))
        let line = try nextResponseLine(connection: connection)
        let response = try RuntimeProtocolCodec.decodeLine(RuntimeResponse.self, from: line)
        guard response.requestID == command.requestID else {
            throw RuntimeErrorDTO(code: "mismatched_response", message: "Runtime response request ID did not match")
        }
        if let error = response.error { throw error }
        guard response.ok else {
            throw RuntimeErrorDTO(code: "invalid_response", message: "Runtime returned an unsuccessful response without an error")
        }
        return response
    }

    private func nextResponseLine(connection: UnixSocketConnection) throws -> Data {
        if !pendingResponses.isEmpty { return pendingResponses.removeFirst() }
        while true {
            let lines = try responseParser.append(connection.read())
            if let first = lines.first {
                pendingResponses.append(contentsOf: lines.dropFirst())
                return first
            }
        }
    }
}

/// Blocking Swift output producer used by sonexisctl and native integrations.
/// Socket backpressure occurs on the caller's non-realtime thread.
public final class RuntimeOutputWriter: @unchecked Sendable {
    public let session: RuntimeOutputSessionDTO
    private let connection: UnixSocketConnection
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var sequence: UInt64 = 0
    private var nextTimestampNanoseconds: UInt64 = 0
    private var closed = false

    init(session: RuntimeOutputSessionDTO) throws {
        guard UUID(uuidString: session.streamID) != nil else {
            throw RuntimeErrorDTO(code: "invalid_stream_id",
                message: "Output session has an invalid stream UUID")
        }
        self.session = session
        connection = try UnixSocketSystem.connect(path: session.dataSocketPath)
    }

    deinit { cancel() }

    public func write(_ pcm: Data, timestampNanoseconds: UInt64? = nil,
                      discontinuity: Bool = false) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        stateLock.lock()
        let isClosed = closed
        stateLock.unlock()
        guard !isClosed else {
            throw RuntimeErrorDTO(code: "output_closed", message: "Output writer is closed")
        }
        let format = session.format
        guard !pcm.isEmpty, pcm.count % format.bytesPerFrame == 0 else {
            throw RuntimeErrorDTO(code: "invalid_output_audio",
                message: "Output PCM must contain complete non-empty sample frames")
        }
        var offset = 0
        let maximumFrames = max(1, Int(format.sampleRate) / 5)
        let maximumBytes = maximumFrames * format.bytesPerFrame
        var timestamp = timestampNanoseconds ?? nextTimestampNanoseconds
        var first = true
        let streamID = UUID(uuidString: session.streamID)!
        while offset < pcm.count {
            let byteCount = min(maximumBytes, pcm.count - offset)
            let payload = pcm.subdata(in: offset..<(offset + byteCount))
            let frameCount = UInt32(byteCount / format.bytesPerFrame)
            let flags: RuntimePCMFrameFlags = discontinuity && first ? [.discontinuity] : []
            let header = RuntimePCMFrameHeader(flags: flags,
                payloadByteCount: UInt32(payload.count), streamID: streamID,
                sequence: sequence, timestampNanoseconds: timestamp,
                sampleRate: format.sampleRate, frameCount: frameCount,
                channelCount: format.channelCount, sampleFormat: format.sampleFormat)
            try connection.write(RuntimePCMFrameCodec.encode(header: header, payload: payload))
            sequence &+= 1
            timestamp &+= UInt64(frameCount) * 1_000_000_000 / UInt64(format.sampleRate)
            offset += byteCount
            first = false
        }
        nextTimestampNanoseconds = timestamp
    }

    public func finish() throws {
        writeLock.lock(); defer { writeLock.unlock() }
        stateLock.lock()
        guard !closed else { stateLock.unlock(); return }
        closed = true
        stateLock.unlock()
        defer { connection.close() }
        let header = RuntimePCMFrameHeader(flags: [.endOfStream], payloadByteCount: 0,
            streamID: UUID(uuidString: session.streamID)!, sequence: sequence,
            timestampNanoseconds: nextTimestampNanoseconds, sampleRate: 0,
            frameCount: 0, channelCount: 0)
        try connection.write(RuntimePCMFrameCodec.encode(header: header, payload: Data()))
    }

    public func cancel() {
        stateLock.lock()
        guard !closed else { stateLock.unlock(); return }
        closed = true
        stateLock.unlock()
        // Closing outside writeLock deliberately interrupts a blocking socket
        // write. The writer then fails instead of delaying cancellation.
        connection.close()
    }
}
