import Darwin
import Foundation

public struct RuntimeSocketPaths: Equatable, Sendable {
    public let directory: URL
    public var controlSocketPath: String { directory.appendingPathComponent("control.sock").path }

    public init(directory: URL) { self.directory = directory }

    public static var userDefault: RuntimeSocketPaths {
        RuntimeSocketPaths(directory: URL(fileURLWithPath: "/tmp/sonexis-runtime-\(getuid())", isDirectory: true))
    }

    public func prepareDirectory() throws {
        let manager = FileManager.default
        var status = stat()
        if lstat(directory.path, &status) == 0 {
            guard status.st_mode & S_IFMT == S_IFDIR else {
                throw RuntimeErrorDTO(code: "invalid_socket_directory", message: "Runtime socket path is not a directory")
            }
            guard status.st_uid == getuid() else {
                throw RuntimeErrorDTO(code: "unsafe_socket_directory", message: "Runtime socket directory belongs to another user")
            }
        } else if errno == ENOENT {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        } else {
            throw UnixSocketError.systemCall("lstat", errno)
        }
        try manager.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directory.path)
    }
}

public final class SonexisRuntimeServer: @unchecked Sendable {
    public let paths: RuntimeSocketPaths
    private let coordinator: RuntimeSessionCoordinator
    private let acceptQueue = DispatchQueue(label: "com.sonexis.runtime.control.accept")
    private let clientQueue = DispatchQueue(label: "com.sonexis.runtime.control.clients", attributes: .concurrent)
    private let stateLock = NSLock()
    private var clients: [String: UnixSocketConnection] = [:]
    private var listener: UnixSocketListener?

    public init(socketDirectory: URL = RuntimeSocketPaths.userDefault.directory,
                backend: RuntimeCaptureBackend) {
        paths = RuntimeSocketPaths(directory: socketDirectory)
        coordinator = RuntimeSessionCoordinator(backend: backend, socketDirectory: socketDirectory)
    }

    public func start() throws {
        try paths.prepareDirectory()
        stateLock.lock()
        guard listener == nil else { stateLock.unlock(); return }
        let newListener = UnixSocketListener(path: paths.controlSocketPath, queue: acceptQueue)
        listener = newListener
        stateLock.unlock()
        do {
            try newListener.start { [weak self] connection in self?.accept(connection) }
        } catch {
            stateLock.lock(); listener = nil; stateLock.unlock()
            throw error
        }
    }

    public func stop() {
        stateLock.lock()
        let oldListener = listener
        listener = nil
        let activeClients = Array(clients.values)
        clients.removeAll()
        stateLock.unlock()
        oldListener?.stop()
        activeClients.forEach { $0.close() }
        coordinator.stopAll()
    }

    private func accept(_ connection: UnixSocketConnection) {
        let ownerID = UUID().uuidString.lowercased()
        stateLock.lock(); clients[ownerID] = connection; stateLock.unlock()
        clientQueue.async { [weak self] in self?.serve(connection: connection, ownerID: ownerID) }
    }

    private func serve(connection: UnixSocketConnection, ownerID: String) {
        defer {
            coordinator.stopSessions(ownerID: ownerID)
            stateLock.lock(); clients.removeValue(forKey: ownerID); stateLock.unlock()
            connection.close()
        }
        var parser = RuntimeNDJSONParser()
        while true {
            do {
                let bytes = try connection.read()
                for line in try parser.append(bytes) {
                    let response: RuntimeResponse
                    do {
                        let command = try RuntimeProtocolCodec.decodeLine(RuntimeCommand.self, from: line)
                        response = execute(command, ownerID: ownerID)
                    } catch let error as RuntimeErrorDTO {
                        response = RuntimeResponse(requestID: "unknown", error: error)
                    } catch {
                        response = RuntimeResponse(requestID: "unknown", error: RuntimeErrorDTO(
                            code: "internal_error", message: error.localizedDescription))
                    }
                    try connection.write(RuntimeProtocolCodec.encodeLine(response))
                }
            } catch { return }
        }
    }

    private func execute(_ command: RuntimeCommand, ownerID: String) -> RuntimeResponse {
        guard command.version == RuntimeCommand.currentVersion else {
            return RuntimeResponse(requestID: command.requestID, error: RuntimeErrorDTO(
                code: "unsupported_version", message: "Protocol version \(command.version) is unsupported"))
        }
        do {
            switch command.command {
            case .listSources:
                return RuntimeResponse(requestID: command.requestID, sources: try coordinator.availableSources())
            case .startCapture:
                guard let sourceID = command.sourceID else {
                    throw RuntimeErrorDTO(code: "missing_source_id", message: "start_capture requires sourceID")
                }
                return RuntimeResponse(requestID: command.requestID,
                    session: try coordinator.startCapture(sourceID: sourceID, ownerID: ownerID))
            case .stopCapture:
                guard let sessionID = command.sessionID else {
                    throw RuntimeErrorDTO(code: "missing_session_id", message: "stop_capture requires sessionID")
                }
                return RuntimeResponse(requestID: command.requestID,
                    session: try coordinator.stopCapture(sessionID: sessionID))
            case .sessionStatus:
                guard let sessionID = command.sessionID else {
                    throw RuntimeErrorDTO(code: "missing_session_id", message: "session_status requires sessionID")
                }
                return RuntimeResponse(requestID: command.requestID,
                    session: try coordinator.session(sessionID: sessionID))
            case .ping:
                return RuntimeResponse(requestID: command.requestID, message: "pong")
            }
        } catch let error as RuntimeErrorDTO {
            return RuntimeResponse(requestID: command.requestID, error: error)
        } catch {
            return RuntimeResponse(requestID: command.requestID,
                error: RuntimeErrorDTO(code: "runtime_error", message: error.localizedDescription))
        }
    }
}
