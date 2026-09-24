import Foundation

public final class SonexisRuntimeClient: @unchecked Sendable {
    public let controlSocketPath: String
    private let requestLock = NSLock()
    private var controlConnection: UnixSocketConnection?
    private var responseParser = RuntimeNDJSONParser()
    private var pendingResponses: [Data] = []

    public init(controlSocketPath: String = RuntimeSocketPaths.userDefault.controlSocketPath) {
        self.controlSocketPath = controlSocketPath
    }

    deinit { disconnect() }

    public func connect() throws {
        requestLock.lock(); defer { requestLock.unlock() }
        guard controlConnection == nil else { return }
        controlConnection = try UnixSocketSystem.connect(path: controlSocketPath)
    }

    public func disconnect() {
        requestLock.lock()
        let connection = controlConnection
        controlConnection = nil
        responseParser = RuntimeNDJSONParser()
        pendingResponses.removeAll()
        requestLock.unlock()
        connection?.close()
    }

    public func listSources() throws -> [RuntimeSourceDTO] {
        let response = try request(RuntimeCommand(command: .listSources))
        return response.sources ?? []
    }

    public func startCapture(sourceID: String) throws -> RuntimeSessionDTO {
        let response = try request(RuntimeCommand(command: .startCapture, sourceID: sourceID))
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

    /// Blocks until the stream closes or `onFrame` returns false. Control-plane
    /// requests remain available from another thread while this method is running.
    public func receiveFrames(session: RuntimeSessionDTO,
                              onFrame: (RuntimePCMFrame) throws -> Bool) throws {
        let connection = try UnixSocketSystem.connect(path: session.dataSocketPath)
        defer { connection.close() }
        var decoder = RuntimePCMStreamDecoder()
        while true {
            let bytes: Data
            do { bytes = try connection.read(maximumBytes: 64 * 1024) }
            catch UnixSocketError.disconnected { return }
            for frame in try decoder.append(bytes) {
                if try !onFrame(frame) { return }
            }
        }
    }

    private func request(_ command: RuntimeCommand) throws -> RuntimeResponse {
        requestLock.lock(); defer { requestLock.unlock() }
        guard let connection = controlConnection else {
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
