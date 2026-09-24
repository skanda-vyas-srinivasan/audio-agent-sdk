import Darwin
import Foundation

public enum UnixSocketError: LocalizedError, Sendable {
    case pathTooLong
    case pathOccupied(String)
    case systemCall(String, Int32)
    case disconnected

    public var errorDescription: String? {
        switch self {
        case .pathTooLong: return "Unix socket path is too long"
        case .pathOccupied(let path): return "Refusing to replace a non-socket file at \(path)"
        case .systemCall(let name, let code): return "\(name) failed: \(String(cString: strerror(code)))"
        case .disconnected: return "Unix socket disconnected"
        }
    }
}

public final class UnixSocketConnection: @unchecked Sendable {
    private let stateLock = NSLock()
    private var descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
        var enabled: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
    }

    deinit { close() }

    public func close() {
        stateLock.lock()
        let fd = descriptor
        descriptor = -1
        stateLock.unlock()
        if fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            _ = Darwin.close(fd)
        }
    }

    public func read(maximumBytes: Int = 16 * 1024) throws -> Data {
        guard maximumBytes > 0 else { return Data() }
        let fd = currentDescriptor()
        guard fd >= 0 else { throw UnixSocketError.disconnected }
        var storage = [UInt8](repeating: 0, count: maximumBytes)
        while true {
            let count = Darwin.recv(fd, &storage, storage.count, 0)
            if count > 0 { return Data(storage.prefix(count)) }
            if count == 0 { throw UnixSocketError.disconnected }
            if errno == EINTR { continue }
            throw UnixSocketError.systemCall("recv", errno)
        }
    }

    public func readExactly(_ byteCount: Int) throws -> Data {
        guard byteCount >= 0 else { throw RuntimeErrorDTO(code: "invalid_read", message: "Negative read length") }
        var result = Data(capacity: byteCount)
        while result.count < byteCount {
            result.append(try read(maximumBytes: byteCount - result.count))
        }
        return result
    }

    public func write(_ data: Data) throws {
        let fd = currentDescriptor()
        guard fd >= 0 else { throw UnixSocketError.disconnected }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < rawBuffer.count {
                let count = Darwin.send(fd, base.advanced(by: sent), rawBuffer.count - sent, 0)
                if count > 0 { sent += count; continue }
                if count < 0, errno == EINTR { continue }
                throw UnixSocketError.systemCall("send", errno)
            }
        }
    }

    private func currentDescriptor() -> Int32 {
        stateLock.lock(); defer { stateLock.unlock() }
        return descriptor
    }
}

public final class UnixSocketListener: @unchecked Sendable {
    public let path: String
    private let queue: DispatchQueue
    private let acceptedConnectionsNonBlocking: Bool
    private let stateLock = NSLock()
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?

    public init(path: String, queue: DispatchQueue, acceptedConnectionsNonBlocking: Bool = false) {
        self.path = path
        self.queue = queue
        self.acceptedConnectionsNonBlocking = acceptedConnectionsNonBlocking
    }

    deinit { stop() }

    public func start(onAccept: @escaping @Sendable (UnixSocketConnection) -> Void) throws {
        let fd = try UnixSocketSystem.makeSocket()
        do {
            try UnixSocketSystem.prepareSocketPath(path)
            try UnixSocketSystem.bind(fd, path: path)
            guard Darwin.listen(fd, 16) == 0 else { throw UnixSocketError.systemCall("listen", errno) }
        } catch {
            _ = Darwin.close(fd)
            throw error
        }

        stateLock.lock()
        guard descriptor < 0 else {
            stateLock.unlock(); _ = Darwin.close(fd)
            throw RuntimeErrorDTO(code: "already_running", message: "Socket listener is already running")
        }
        descriptor = fd
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source = readSource
        stateLock.unlock()

        readSource.setEventHandler { [weak self] in
            guard self != nil else { return }
            while true {
                let client = Darwin.accept(fd, nil, nil)
                if client >= 0 {
                    if self?.acceptedConnectionsNonBlocking == true {
                        UnixSocketSystem.setNonBlocking(client)
                    } else {
                        UnixSocketSystem.setBlocking(client)
                    }
                    onAccept(UnixSocketConnection(descriptor: client))
                    continue
                }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                break
            }
        }
        readSource.setCancelHandler { _ = Darwin.close(fd) }
        UnixSocketSystem.setNonBlocking(fd)
        readSource.resume()
    }

    public func stop() {
        stateLock.lock()
        let oldSource = source
        source = nil
        descriptor = -1
        stateLock.unlock()
        oldSource?.cancel()
        if let status = try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType,
           status == .typeSocket { try? FileManager.default.removeItem(atPath: path) }
    }
}

public enum UnixSocketSystem {
    public static func connect(path: String) throws -> UnixSocketConnection {
        let fd = try makeSocket()
        do {
            var address = try socketAddress(path: path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socketAddressLength(path: path))
                }
            }
            guard result == 0 else { throw UnixSocketError.systemCall("connect", errno) }
            return UnixSocketConnection(descriptor: fd)
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
    }

    fileprivate static func makeSocket() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.systemCall("socket", errno) }
        return fd
    }

    fileprivate static func bind(_ fd: Int32, path: String) throws {
        var address = try socketAddress(path: path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socketAddressLength(path: path))
            }
        }
        guard result == 0 else { throw UnixSocketError.systemCall("bind", errno) }
        guard Darwin.chmod(path, S_IRUSR | S_IWUSR) == 0 else { throw UnixSocketError.systemCall("chmod", errno) }
    }

    fileprivate static func prepareSocketPath(_ path: String) throws {
        var status = stat()
        if lstat(path, &status) == 0 {
            guard status.st_mode & S_IFMT == S_IFSOCK else { throw UnixSocketError.pathOccupied(path) }
            guard unlink(path) == 0 else { throw UnixSocketError.systemCall("unlink", errno) }
        } else if errno != ENOENT {
            throw UnixSocketError.systemCall("lstat", errno)
        }
    }

    fileprivate static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
    }

    fileprivate static func setBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
    }

    private static func socketAddress(path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8CString)
        var address = sockaddr_un()
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw UnixSocketError.pathTooLong }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(socketAddressLength(path: path))
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
                _ = bytes.withUnsafeBufferPointer { source in memcpy(destination, source.baseAddress!, bytes.count) }
            }
        }
        return address
    }

    private static func socketAddressLength(path: String) -> socklen_t {
        socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
    }
}
