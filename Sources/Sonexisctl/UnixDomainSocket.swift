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
        case .pathOccupied(let path): return "Unix socket path is already in use: \(path)"
        case .systemCall(let name, let code): return "\(name) failed: \(String(cString: strerror(code)))"
        case .disconnected: return "Unix socket disconnected"
        }
    }
}

public final class UnixSocketConnection: @unchecked Sendable {
    private let state = NSCondition()
    private var descriptor: Int32
    private var activeOperations = 0
    private var isClosing = false

    init(descriptor: Int32) {
        self.descriptor = descriptor
        var enabled: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
    }

    deinit { close() }

    public func close() {
        state.lock()
        guard !isClosing, descriptor >= 0 else { state.unlock(); return }
        isClosing = true
        let fd = descriptor
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        while activeOperations > 0 { state.wait() }
        descriptor = -1
        state.unlock()
        _ = Darwin.close(fd)
    }

    public func read(maximumBytes: Int = 16 * 1024) throws -> Data {
        guard maximumBytes > 0 else { return Data() }
        let fd = try beginOperation()
        defer { endOperation() }
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
        let fd = try beginOperation()
        defer { endOperation() }
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

    public func isPeerClosed() -> Bool {
        guard let fd = try? beginOperation() else { return true }
        defer { endOperation() }
        var byte: UInt8 = 0
        let count = Darwin.recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if count == 0 { return true }
        if count < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR { return true }
        return false
    }

    public func setReceiveTimeout(milliseconds: Int) throws {
        let fd = try beginOperation()
        defer { endOperation() }
        var timeout = timeval(tv_sec: milliseconds > 0 ? milliseconds / 1_000 : 0,
                              tv_usec: milliseconds > 0
                                ? Int32((milliseconds % 1_000) * 1_000) : 0)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                         socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else {
            throw UnixSocketError.systemCall("setsockopt", errno)
        }
    }

    public func setSendTimeout(milliseconds: Int) throws {
        let fd = try beginOperation()
        defer { endOperation() }
        var timeout = timeval(tv_sec: milliseconds > 0 ? milliseconds / 1_000 : 0,
                              tv_usec: milliseconds > 0
                                ? Int32((milliseconds % 1_000) * 1_000) : 0)
        guard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                         socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else {
            throw UnixSocketError.systemCall("setsockopt", errno)
        }
    }

    private func beginOperation() throws -> Int32 {
        state.lock(); defer { state.unlock() }
        guard descriptor >= 0, !isClosing else { throw UnixSocketError.disconnected }
        activeOperations += 1
        return descriptor
    }

    private func endOperation() {
        state.lock()
        activeOperations -= 1
        if activeOperations == 0 { state.broadcast() }
        state.unlock()
    }
}

public final class UnixSocketListener: @unchecked Sendable {
    public let path: String
    private let queue: DispatchQueue
    private let acceptedConnectionsNonBlocking: Bool
    private let stateLock = NSLock()
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private var ownsSocketPath = false
    private var boundDevice: dev_t?
    private var boundInode: ino_t?

    public init(path: String, queue: DispatchQueue, acceptedConnectionsNonBlocking: Bool = false) {
        self.path = path
        self.queue = queue
        self.acceptedConnectionsNonBlocking = acceptedConnectionsNonBlocking
    }

    deinit { stop() }

    public func start(onAccept: @escaping @Sendable (UnixSocketConnection) -> Void) throws {
        let fd = try UnixSocketSystem.makeSocket()
        var didBind = false
        var boundStatus = stat()
        do {
            try UnixSocketSystem.prepareSocketPath(path)
            try UnixSocketSystem.bind(fd, path: path)
            didBind = true
            // Track the filesystem socket node, not the socket descriptor's
            // kernel object: their inode numbers are distinct on Darwin.
            guard lstat(path, &boundStatus) == 0 else {
                throw UnixSocketError.systemCall("lstat", errno)
            }
            guard boundStatus.st_mode & S_IFMT == S_IFSOCK else {
                throw RuntimeErrorDTO(code: "invalid_socket_path",
                    message: "Bound Runtime path is not a Unix socket")
            }
            guard Darwin.listen(fd, 16) == 0 else { throw UnixSocketError.systemCall("listen", errno) }
        } catch {
            _ = Darwin.close(fd)
            if didBind { try? FileManager.default.removeItem(atPath: path) }
            throw error
        }

        stateLock.lock()
        guard descriptor < 0 else {
            stateLock.unlock(); _ = Darwin.close(fd)
            throw RuntimeErrorDTO(code: "already_running", message: "Socket listener is already running")
        }
        descriptor = fd
        ownsSocketPath = true
        boundDevice = boundStatus.st_dev
        boundInode = boundStatus.st_ino
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source = readSource
        stateLock.unlock()

        readSource.setEventHandler { [weak self] in
            guard self != nil else { return }
            while true {
                let client = Darwin.accept(fd, nil, nil)
                if client >= 0 {
                    var peerUID = uid_t(0)
                    var peerGID = gid_t(0)
                    guard getpeereid(client, &peerUID, &peerGID) == 0,
                          peerUID == getuid() else {
                        _ = Darwin.close(client)
                        continue
                    }
                    UnixSocketSystem.setCloseOnExec(client)
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
        let shouldRemovePath = ownsSocketPath
        let expectedDevice = boundDevice
        let expectedInode = boundInode
        source = nil
        descriptor = -1
        ownsSocketPath = false
        boundDevice = nil
        boundInode = nil
        stateLock.unlock()
        oldSource?.cancel()
        var currentStatus = stat()
        if shouldRemovePath, let expectedDevice, let expectedInode,
           lstat(path, &currentStatus) == 0,
           currentStatus.st_mode & S_IFMT == S_IFSOCK,
           currentStatus.st_dev == expectedDevice,
           currentStatus.st_ino == expectedInode {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

public enum UnixSocketSystem {
    static var maximumPathBytes: Int {
        MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1 // Include terminating NUL.
    }

    static func validatePath(_ path: String) throws {
        _ = try socketAddress(path: path)
    }

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
            var peerUID = uid_t(0)
            var peerGID = gid_t(0)
            guard getpeereid(fd, &peerUID, &peerGID) == 0,
                  peerUID == getuid() else {
                throw RuntimeErrorDTO(code: "untrusted_socket_peer",
                    message: "Unix socket peer does not belong to the current user")
            }
            return UnixSocketConnection(descriptor: fd)
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
    }

    fileprivate static func makeSocket() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.systemCall("socket", errno) }
        setCloseOnExec(fd)
        return fd
    }

    fileprivate static func setCloseOnExec(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFD, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
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
            guard status.st_uid == getuid() else { throw UnixSocketError.pathOccupied(path) }
            do {
                let existing = try connect(path: path)
                existing.close()
                throw UnixSocketError.pathOccupied(path)
            } catch UnixSocketError.systemCall("connect", let code)
                where code == ECONNREFUSED || code == ENOENT {
                // The owning process is gone; remove only this stale socket.
            }
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
