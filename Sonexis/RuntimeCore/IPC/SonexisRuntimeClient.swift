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
