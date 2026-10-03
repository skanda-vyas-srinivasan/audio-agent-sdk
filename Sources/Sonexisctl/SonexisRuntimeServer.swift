import Darwin
import Foundation

private final class RuntimeInstanceLock {
    private var descriptor: Int32

    init(directory: URL) throws {
        let path = directory.appendingPathComponent("instance.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw UnixSocketError.systemCall("open", errno) }
        var status = stat()
        guard fstat(fd, &status) == 0 else {
            let code = errno
            close(fd)
            throw UnixSocketError.systemCall("fstat", code)
        }
        guard status.st_mode & S_IFMT == S_IFREG, status.st_uid == getuid() else {
            close(fd)
            throw RuntimeErrorDTO(code: "unsafe_instance_lock",
                message: "Runtime instance lock must be a same-user regular file")
        }
        guard fchmod(fd, mode_t(0o600)) == 0 else {
            let code = errno
            close(fd)
            throw UnixSocketError.systemCall("fchmod", code)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK {
                throw RuntimeErrorDTO(code: "already_running",
                    message: "Another Sonexis Runtime owns this socket directory")
            }
            throw UnixSocketError.systemCall("flock", code)
        }
        descriptor = fd
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}

public struct RuntimeSocketPaths: Equatable, Sendable {
    public let directory: URL
    public var controlSocketPath: String { directory.appendingPathComponent("control.sock").path }

    public init(directory: URL) { self.directory = directory }

    public static var userDefault: RuntimeSocketPaths {
        RuntimeSocketPaths(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("sx-\(getuid())", isDirectory: true))
    }

    /// v0.1-v0.7 discovery location. v0.8 prefers the per-user Darwin temp
    /// directory but keeps a guarded compatibility listener during migration.
    public static var legacyUserDefault: RuntimeSocketPaths {
        RuntimeSocketPaths(directory: URL(fileURLWithPath:
            "/tmp/sonexis-runtime-\(getuid())", isDirectory: true))
    }

    public static var compatibleControlSocketPath: String {
        let current = userDefault.controlSocketPath
        if FileManager.default.fileExists(atPath: current) { return current }
        let legacy = legacyUserDefault.controlSocketPath
        return FileManager.default.fileExists(atPath: legacy) ? legacy : current
    }

    public func prepareDirectory() throws {
        let compactID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let sessionNames = ["i-\(compactID).sock", "o-\(compactID).sock", "e-\(compactID).sock"]
        do {
            for name in ["control.sock"] + sessionNames {
                try UnixSocketSystem.validatePath(directory.appendingPathComponent(name).path)
            }
        } catch UnixSocketError.pathTooLong {
            let maximumDirectoryBytes = UnixSocketSystem.maximumPathBytes
                - sessionNames[0].utf8.count - 1
            throw RuntimeErrorDTO(code: "invalid_socket_directory",
                message: "Runtime socket directory is too long for PCM/event sockets. "
                    + "Choose a shorter directory (at most \(maximumDirectoryBytes) UTF-8 bytes).")
        }
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

    fileprivate func removeStaleSessionSockets() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where Self.isSessionSocketName(name) {
            let path = directory.appendingPathComponent(name).path
            var status = stat()
            guard lstat(path, &status) == 0,
                  status.st_mode & S_IFMT == S_IFSOCK,
                  status.st_uid == getuid() else { continue }
            do {
                let live = try UnixSocketSystem.connect(path: path)
                live.close()
            } catch UnixSocketError.systemCall("connect", let code)
                where code == ECONNREFUSED || code == ENOENT {
                _ = unlink(path)
            } catch {
                // Preserve anything that cannot be positively identified as stale.
            }
        }
    }

    private static func isSessionSocketName(_ name: String) -> Bool {
        guard name.hasSuffix(".sock") else { return false }
        for prefix in ["stream-", "output-", "events-"] where name.hasPrefix(prefix) {
            let start = name.index(name.startIndex, offsetBy: prefix.count)
            let end = name.index(name.endIndex, offsetBy: -5)
            return UUID(uuidString: String(name[start..<end])) != nil
        }
        for prefix in ["i-", "o-", "e-"] where name.hasPrefix(prefix) {
            let start = name.index(name.startIndex, offsetBy: prefix.count)
            let end = name.index(name.endIndex, offsetBy: -5)
            let identifier = name[start..<end]
            return identifier.count == 32 && identifier.allSatisfy { $0.isHexDigit }
        }
        return false
    }
}

public final class SonexisRuntimeServer: @unchecked Sendable {
    public let paths: RuntimeSocketPaths
    public let limits: RuntimeResourceLimitsDTO
    public let runtimeInstanceID = UUID().uuidString.lowercased()
    private let coordinator: RuntimeSessionCoordinator
    private let outputCoordinator: RuntimeOutputCoordinator
    private let eventHub: RuntimeEventHub
    private let handshakeTimeoutMilliseconds: Int
    private let acceptQueue = DispatchQueue(label: "com.sonexis.runtime.control.accept")
    private let clientQueue = DispatchQueue(label: "com.sonexis.runtime.control.clients", attributes: .concurrent)
    private let monitorQueue = DispatchQueue(label: "com.sonexis.runtime.endpoint-monitor")
    private let stateLock = NSLock()
    private let startedAt = DispatchTime.now().uptimeNanoseconds
    private var clients: [String: UnixSocketConnection] = [:]
    private var listener: UnixSocketListener?
    private var legacyListener: UnixSocketListener?
    private var instanceLock: RuntimeInstanceLock?
    private var endpointTimer: DispatchSourceTimer?
    private var sourceSnapshot: [String: RuntimeSourceDTO] = [:]
    private var destinationSnapshot: [String: RuntimeOutputDestinationDTO] = [:]
    private var sourceMonitorError: String?
    private var destinationMonitorError: String?
    private var totalControlClientsAccepted: UInt64 = 0
    private var totalControlClientsDisconnected: UInt64 = 0
    private var totalControlClientsRejected: UInt64 = 0
    private var totalControlRequests: UInt64 = 0
    private var totalControlErrors: UInt64 = 0
    private var totalMalformedControlMessages: UInt64 = 0
    private var totalControlHandshakeTimeouts: UInt64 = 0
    private var totalSourceMonitorFailures: UInt64 = 0
    private var totalDestinationMonitorFailures: UInt64 = 0
    private var sourceMonitorConsecutiveFailures: UInt64 = 0
    private var destinationMonitorConsecutiveFailures: UInt64 = 0
    private var sourceMonitorRecoveries: UInt64 = 0
    private var destinationMonitorRecoveries: UInt64 = 0
    private var sourceMonitorLastSuccessNanoseconds: UInt64 = 0
    private var destinationMonitorLastSuccessNanoseconds: UInt64 = 0
    private var generation: UInt64 = 0

    public init(socketDirectory: URL = RuntimeSocketPaths.userDefault.directory,
                backend: RuntimeCaptureBackend,
                outputBackend: RuntimeOutputBackend = UnavailableRuntimeOutputBackend(),
                limits: RuntimeResourceLimitsDTO = .init(),
                handshakeTimeoutMilliseconds: Int = 5_000) {
        paths = RuntimeSocketPaths(directory: socketDirectory)
        self.limits = limits
        self.handshakeTimeoutMilliseconds = max(100, handshakeTimeoutMilliseconds)
        let hub = RuntimeEventHub(directory: socketDirectory, limits: limits)
        eventHub = hub
        coordinator = RuntimeSessionCoordinator(backend: backend, socketDirectory: socketDirectory,
            limits: limits, eventHandler: { event in hub.publish(event) })
        outputCoordinator = RuntimeOutputCoordinator(backend: outputBackend,
            socketDirectory: socketDirectory, limits: limits,
            eventHandler: { event in hub.publish(event) })
    }

    public func start() throws {
        try paths.prepareDirectory()
        stateLock.lock()
        if listener != nil { stateLock.unlock(); return }
        stateLock.unlock()
        let acquiredLock = try RuntimeInstanceLock(directory: paths.directory)
        paths.removeStaleSessionSockets()
        coordinator.resume()
        outputCoordinator.resume()
        stateLock.lock()
        guard listener == nil else {
            stateLock.unlock()
            acquiredLock.release()
            return
        }
        let newListener = UnixSocketListener(path: paths.controlSocketPath, queue: acceptQueue)
        generation &+= 1
        let listenerGeneration = generation
        listener = newListener
        instanceLock = acquiredLock
        do {
            try newListener.start { [weak self, weak newListener] connection in
                guard let self, let newListener else { connection.close(); return }
                self.accept(connection, listener: newListener, generation: listenerGeneration)
            }
        } catch {
            listener = nil
            instanceLock = nil
            generation &+= 1
            stateLock.unlock()
            throw error
        }
        stateLock.unlock()
        do {
            try startLegacyCompatibilityListener(generation: listenerGeneration)
        } catch {
            stop()
            throw error
        }
        startSourceMonitor(generation: listenerGeneration)
    }

    public func stop() {
        coordinator.prepareForShutdown()
        outputCoordinator.prepareForShutdown()
        stateLock.lock()
        let oldListener = listener
        let oldLegacyListener = legacyListener
        let oldInstanceLock = instanceLock
        listener = nil
        legacyListener = nil
        instanceLock = nil
        generation &+= 1
        let activeClients = Array(clients.values)
        totalControlClientsDisconnected &+= UInt64(clients.count)
        clients.removeAll()
        stateLock.unlock()
        oldListener?.stop()
        oldLegacyListener?.stop()
        // Event sockets are independent of the control socket. Publish before
        // closing owners so subscribers deterministically see shutdown.
        eventHub.publish(RuntimeEventDTO(type: .runtimeShuttingDown,
            message: "Runtime is shutting down"))
        activeClients.forEach { $0.close() }
        monitorQueue.sync {
            endpointTimer?.setEventHandler {}
            endpointTimer?.cancel()
            endpointTimer = nil
            sourceSnapshot.removeAll()
            destinationSnapshot.removeAll()
            sourceMonitorError = nil
            destinationMonitorError = nil
        }
        coordinator.stopAll()
        outputCoordinator.stopAll()
        eventHub.stopAll()
        oldInstanceLock?.release()
    }

    private func accept(_ connection: UnixSocketConnection,
                        listener acceptedListener: UnixSocketListener,
                        generation acceptedGeneration: UInt64) {
        let ownerID = UUID().uuidString.lowercased()
        stateLock.lock()
        guard (listener === acceptedListener || legacyListener === acceptedListener),
              generation == acceptedGeneration else {
            stateLock.unlock()
            connection.close()
            return
        }
        guard clients.count < limits.maximumControlClients else {
            totalControlClientsRejected &+= 1
            stateLock.unlock()
            let error = RuntimeErrorDTO(code: "client_limit_exceeded",
                message: "Runtime control client limit reached", retryable: true)
            try? connection.write(RuntimeProtocolCodec.encodeLine(
                RuntimeResponse(requestID: "unknown", error: error)))
            connection.close()
            return
        }
        clients[ownerID] = connection
        totalControlClientsAccepted &+= 1
        stateLock.unlock()
        let handshakeDeadline = DispatchTime.now().uptimeNanoseconds
            &+ UInt64(handshakeTimeoutMilliseconds) * 1_000_000
        do {
            try connection.setReceiveTimeout(milliseconds: handshakeTimeoutMilliseconds)
            try connection.setSendTimeout(milliseconds: handshakeTimeoutMilliseconds)
        }
        catch {
            stateLock.lock()
            clients.removeValue(forKey: ownerID)
            totalControlClientsDisconnected &+= 1
            totalControlErrors &+= 1
            stateLock.unlock()
            connection.close()
            return
        }
        clientQueue.async { [weak self] in
            self?.serve(connection: connection, ownerID: ownerID,
                        handshakeDeadline: handshakeDeadline)
        }
    }

    private func startLegacyCompatibilityListener(generation expectedGeneration: UInt64) throws {
        guard paths.directory.standardizedFileURL
                == RuntimeSocketPaths.userDefault.directory.standardizedFileURL else { return }
        let legacyPaths = RuntimeSocketPaths.legacyUserDefault
        do {
            // Refuse an attacker-owned path. An existing live v0.7 Runtime also
            // makes listener startup fail safely, leaving the v0.8 endpoint live.
            try legacyPaths.prepareDirectory()
            let candidate = UnixSocketListener(path: legacyPaths.controlSocketPath,
                queue: acceptQueue)
            stateLock.lock()
            guard listener != nil, generation == expectedGeneration,
                  legacyListener == nil else {
                stateLock.unlock()
                return
            }
            legacyListener = candidate
            do {
                try candidate.start { [weak self, weak candidate] connection in
                    guard let self, let candidate else { connection.close(); return }
                    self.accept(connection, listener: candidate,
                                generation: expectedGeneration)
                }
                stateLock.unlock()
            } catch UnixSocketError.pathOccupied {
                legacyListener = nil
                stateLock.unlock()
                candidate.stop()
                throw RuntimeErrorDTO(code: "already_running",
                    message: "A legacy Sonexis Runtime already owns the default socket")
            } catch {
                legacyListener = nil
                stateLock.unlock()
                candidate.stop()
            }
        } catch {
            if let runtimeError = error as? RuntimeErrorDTO,
               runtimeError.code == "already_running" { throw runtimeError }
            // Compatibility is best effort. The secure primary endpoint remains
            // authoritative and is never weakened by a hostile legacy path.
        }
    }

    private func serve(connection: UnixSocketConnection, ownerID: String,
                       handshakeDeadline: UInt64) {
        defer {
            coordinator.stopSessions(ownerID: ownerID)
            outputCoordinator.stopSessions(ownerID: ownerID)
            eventHub.removeSubscriptions(ownerID: ownerID)
            stateLock.lock()
            if clients.removeValue(forKey: ownerID) != nil {
                totalControlClientsDisconnected &+= 1
            }
            stateLock.unlock()
            connection.close()
        }
        var parser = RuntimeNDJSONParser()
        var handshaken = false
        var handshakeTimeoutCleared = false
        while true {
            do {
                if !handshaken {
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard now < handshakeDeadline else {
                        stateLock.lock()
                        totalControlHandshakeTimeouts &+= 1
                        totalControlErrors &+= 1
                        stateLock.unlock()
                        return
                    }
                    let remainingMilliseconds = max(1,
                        Int((handshakeDeadline - now + 999_999) / 1_000_000))
                    try connection.setReceiveTimeout(milliseconds: remainingMilliseconds)
                }
                let bytes = try connection.read()
                let lines: [Data]
                do {
                    lines = try parser.append(bytes)
                } catch let error as RuntimeErrorDTO {
                    recordControlError(malformed: true)
                    try? connection.write(RuntimeProtocolCodec.encodeLine(
                        RuntimeResponse(requestID: "unknown", error: error)))
                    return
                }
                for line in lines {
                    stateLock.lock()
                    totalControlRequests &+= 1
                    stateLock.unlock()
                    let response: RuntimeResponse
                    var malformed = false
                    do {
                        let command = try RuntimeProtocolCodec.decodeLine(RuntimeCommand.self, from: line)
                        response = execute(command, ownerID: ownerID, handshaken: &handshaken)
                    } catch let error as RuntimeErrorDTO {
                        malformed = true
                        response = RuntimeResponse(requestID: "unknown", error: error)
                    } catch {
                        malformed = true
                        response = RuntimeResponse(requestID: "unknown", error: RuntimeErrorDTO(
                            code: "internal_error", message: "Runtime could not process the request"))
                    }
                    if response.error != nil { recordControlError(malformed: malformed) }
                    try connection.write(RuntimeProtocolCodec.encodeLine(response))
                    if handshaken && !handshakeTimeoutCleared {
                        try connection.setReceiveTimeout(milliseconds: 0)
                        handshakeTimeoutCleared = true
                    }
                }
            } catch UnixSocketError.systemCall("recv", let code)
                where !handshaken && (code == EAGAIN || code == EWOULDBLOCK) {
                stateLock.lock()
                totalControlHandshakeTimeouts &+= 1
                totalControlErrors &+= 1
                stateLock.unlock()
                return
            } catch { return }
        }
    }

    private func recordControlError(malformed: Bool) {
        stateLock.lock()
        totalControlErrors &+= 1
        if malformed { totalMalformedControlMessages &+= 1 }
        stateLock.unlock()
    }

    private func execute(_ command: RuntimeCommand, ownerID: String,
                         handshaken: inout Bool) -> RuntimeResponse {
        guard command.messageType == "request", !command.requestID.isEmpty,
              command.requestID.utf8.count <= 128 else {
            return RuntimeResponse(requestID: "unknown", error: RuntimeErrorDTO(
                code: "invalid_request", message: "request_id must contain 1...128 UTF-8 bytes"))
        }
        guard command.protocolVersion == RuntimeProtocolInfo.protocolVersion else {
            return RuntimeResponse(requestID: command.requestID, error: RuntimeErrorDTO(
                code: "unsupported_protocol_version", message: "Protocol version is unsupported",
                details: ["supported_versions": "2"]))
        }
        if !handshaken, command.command != .hello {
            return RuntimeResponse(requestID: command.requestID, error: RuntimeErrorDTO(
                code: "handshake_required", message: "hello must be the first command"))
        }
        do {
            switch command.command {
            case .hello:
                guard !handshaken else {
                    throw RuntimeErrorDTO(code: "already_handshaken", message: "hello was already completed")
                }
                guard command.supportedProtocolVersions?.contains(RuntimeProtocolInfo.protocolVersion) == true else {
                    throw RuntimeErrorDTO(code: "unsupported_protocol_version",
                        message: "Client does not support protocol version 2",
                        details: ["supported_versions": "2"])
                }
                handshaken = true
                return RuntimeResponse(requestID: command.requestID, handshake: RuntimeHandshakeDTO(
                    protocolVersion: RuntimeProtocolInfo.protocolVersion,
                    runtimeVersion: RuntimeProtocolInfo.runtimeVersion,
                    runtimeInstanceID: runtimeInstanceID,
                    capabilities: RuntimeProtocolInfo.capabilities,
                    supportedFormats: RuntimePCMFormatDTO.supportedCaptureFormats,
                    limits: limits))
            case .listSources:
                return RuntimeResponse(requestID: command.requestID,
                    sources: try coordinator.availableSources())
            case .startCapture:
                guard let sourceID = command.sourceID else {
                    throw RuntimeErrorDTO(code: "missing_source_id", message: "start_capture requires source_id")
                }
                return RuntimeResponse(requestID: command.requestID,
                    session: try coordinator.startCapture(sourceID: sourceID,
                        format: command.format ?? .runtimeDefault, ownerID: ownerID))
            case .stopCapture:
                let sessionID = try requiredSessionID(command)
                return RuntimeResponse(requestID: command.requestID,
                    session: try coordinator.stopCapture(sessionID: sessionID, ownerID: ownerID))
            case .sessionStatus:
                let sessionID = try requiredSessionID(command)
                return RuntimeResponse(requestID: command.requestID,
                    session: try coordinator.session(sessionID: sessionID, ownerID: ownerID))
            case .runtimeStatus:
                return RuntimeResponse(requestID: command.requestID, status: runtimeStatus())
            case .subscribeEvents:
                return RuntimeResponse(requestID: command.requestID,
                    subscription: try eventHub.subscribe(ownerID: ownerID, eventTypes: command.eventTypes))
            case .unsubscribeEvents:
                guard let subscriptionID = command.subscriptionID,
                      subscriptionID.utf8.count <= 128 else {
                    throw RuntimeErrorDTO(code: "missing_subscription_id",
                        message: "unsubscribe_events requires subscription_id")
                }
                try eventHub.unsubscribe(id: subscriptionID, ownerID: ownerID)
                return RuntimeResponse(requestID: command.requestID, message: "unsubscribed")
            case .listOutputDestinations:
                return RuntimeResponse(requestID: command.requestID,
                    outputDestinations: try outputCoordinator.availableDestinations())
            case .startOutput:
                guard let destinationID = command.destinationID else {
                    throw RuntimeErrorDTO(code: "missing_output_destination",
                        message: "start_output requires destination_id")
                }
                return RuntimeResponse(requestID: command.requestID,
                    outputSession: try outputCoordinator.startOutput(
                        destinationID: destinationID,
                        format: command.format ?? .runtimeDefault,
                        targetBufferMilliseconds: command.targetBufferMilliseconds ?? 60,
                        ownerID: ownerID))
            case .outputStatus:
                return RuntimeResponse(requestID: command.requestID,
                    outputSession: try outputCoordinator.session(
                        outputSessionID: try requiredOutputSessionID(command), ownerID: ownerID))
            case .flushOutput:
                return RuntimeResponse(requestID: command.requestID,
                    outputSession: try outputCoordinator.flush(
                        outputSessionID: try requiredOutputSessionID(command), ownerID: ownerID))
            case .stopOutput:
                return RuntimeResponse(requestID: command.requestID,
                    outputSession: try outputCoordinator.stopOutput(
                        outputSessionID: try requiredOutputSessionID(command), ownerID: ownerID))
            case .ping:
                return RuntimeResponse(requestID: command.requestID, message: "pong")
            case .unknown:
                throw RuntimeErrorDTO(code: "unsupported_command",
                    message: "The requested command is not supported")
            }
        } catch let error as RuntimeErrorDTO {
            return RuntimeResponse(requestID: command.requestID, error: error)
        } catch {
            return RuntimeResponse(requestID: command.requestID,
                error: RuntimeErrorDTO(code: "runtime_error", message: String(describing: error)))
        }
    }

    private func requiredSessionID(_ command: RuntimeCommand) throws -> String {
        guard let sessionID = command.sessionID, !sessionID.isEmpty,
              sessionID.utf8.count <= 128 else {
            throw RuntimeErrorDTO(code: "missing_session_id", message: "A valid session_id is required")
        }
        return sessionID
    }

    private func requiredOutputSessionID(_ command: RuntimeCommand) throws -> String {
        guard let sessionID = command.outputSessionID, !sessionID.isEmpty,
              sessionID.utf8.count <= 128 else {
            throw RuntimeErrorDTO(code: "missing_output_session_id",
                message: "A valid output_session_id is required")
        }
        return sessionID
    }

    private func runtimeStatus() -> RuntimeStatusDTO {
        let metrics = coordinator.diagnostics()
        let outputMetrics = outputCoordinator.diagnostics()
        let processMetrics = Self.processMetrics()
        stateLock.lock()
        let clientCount = clients.count
        let controlClientsAccepted = totalControlClientsAccepted
        let controlClientsDisconnected = totalControlClientsDisconnected
        let controlClientsRejected = totalControlClientsRejected
        let controlRequests = totalControlRequests
        let controlErrors = totalControlErrors
        let malformedControlMessages = totalMalformedControlMessages
        let controlHandshakeTimeouts = totalControlHandshakeTimeouts
        let sourceMonitorFailures = totalSourceMonitorFailures
        let destinationMonitorFailures = totalDestinationMonitorFailures
        let sourceMonitorConsecutive = sourceMonitorConsecutiveFailures
        let destinationMonitorConsecutive = destinationMonitorConsecutiveFailures
        let sourceRecoveries = sourceMonitorRecoveries
        let destinationRecoveries = destinationMonitorRecoveries
        let sourceLastSuccess = sourceMonitorLastSuccessNanoseconds
        let destinationLastSuccess = destinationMonitorLastSuccessNanoseconds
        stateLock.unlock()
        let uptime = DispatchTime.now().uptimeNanoseconds - startedAt
        let exactCounters = [
            "uptime_nanoseconds": String(uptime),
            "total_sessions_started": String(metrics.totalSessionsStarted),
            "total_frames_forwarded": String(metrics.frames),
            "total_dropped_frames": String(metrics.dropped),
            "total_bytes_transmitted": String(metrics.bytes),
            "total_events_dropped": String(eventHub.totalDroppedEvents),
            "total_capture_ring_dropped_frames": String(metrics.ringDropped),
            "total_capture_delivery_dropped_frames": String(metrics.deliveryDropped),
            "total_capture_queue_dropped_frames": String(metrics.queueDropped),
            "total_capture_no_subscriber_frames": String(metrics.noSubscriber),
            "total_output_sessions_started": String(outputMetrics.totalSessionsStarted),
            "total_output_frames_received": String(outputMetrics.received),
            "total_output_frames_rendered": String(outputMetrics.rendered),
            "total_output_frames_dropped": String(outputMetrics.dropped),
            "total_output_frames_lost": String(outputMetrics.lost),
            "total_output_frames_flushed": String(outputMetrics.flushed),
            "total_output_frames_late": String(outputMetrics.late),
            "total_output_underrun_frames": String(outputMetrics.underrunFrames),
            "total_output_underrun_events": String(outputMetrics.underrunEvents),
            "total_output_overrun_events": String(outputMetrics.overrunEvents),
            "total_output_route_changes": String(outputMetrics.routeChanges),
            "total_output_conversion_batches": String(outputMetrics.conversionBatches),
            "total_output_conversion_nanoseconds": String(outputMetrics.conversionNanoseconds),
            "total_output_bytes_received": String(outputMetrics.bytes),
            "total_control_clients_accepted": String(controlClientsAccepted),
            "total_control_clients_disconnected": String(controlClientsDisconnected),
            "total_control_clients_rejected": String(controlClientsRejected),
            "total_control_requests": String(controlRequests),
            "total_control_errors": String(controlErrors),
            "total_malformed_control_messages": String(malformedControlMessages),
            "total_control_handshake_timeouts": String(controlHandshakeTimeouts),
            "total_source_monitor_failures": String(sourceMonitorFailures),
            "total_destination_monitor_failures": String(destinationMonitorFailures),
            "source_monitor_consecutive_failures": String(sourceMonitorConsecutive),
            "destination_monitor_consecutive_failures": String(destinationMonitorConsecutive),
            "source_monitor_recoveries": String(sourceRecoveries),
            "destination_monitor_recoveries": String(destinationRecoveries),
            "source_monitor_last_success_nanoseconds": String(sourceLastSuccess),
            "destination_monitor_last_success_nanoseconds": String(destinationLastSuccess),
            "resident_memory_bytes": String(processMetrics.residentBytes),
            "peak_resident_memory_bytes": String(processMetrics.peakResidentBytes),
        ]
        return RuntimeStatusDTO(runtimeVersion: RuntimeProtocolInfo.runtimeVersion,
            runtimeInstanceID: runtimeInstanceID,
            uptimeNanoseconds: uptime,
            activeClients: clientCount, activeSessions: metrics.activeSessions,
            eventSubscribers: eventHub.count, totalSessionsStarted: metrics.totalSessionsStarted,
            totalFramesForwarded: metrics.frames, totalDroppedFrames: metrics.dropped,
            totalBytesTransmitted: metrics.bytes, totalEventsDropped: eventHub.totalDroppedEvents,
            activeOutputSessions: outputMetrics.activeSessions,
            totalOutputSessionsStarted: outputMetrics.totalSessionsStarted,
            totalOutputFramesReceived: outputMetrics.received,
            totalOutputFramesRendered: outputMetrics.rendered,
            totalOutputFramesDropped: outputMetrics.dropped,
            totalOutputBytesReceived: outputMetrics.bytes,
            totalCaptureRingDroppedFrames: metrics.ringDropped,
            totalCaptureDeliveryDroppedFrames: metrics.deliveryDropped,
            totalCaptureQueueDroppedFrames: metrics.queueDropped,
            totalCaptureNoSubscriberFrames: metrics.noSubscriber,
            connectedCaptureSubscribers: metrics.connectedSubscribers,
            retainedCaptureSessions: metrics.retainedTerminalRecords,
            reservedCaptureStarts: metrics.reservedStarts,
            totalOutputFramesLost: outputMetrics.lost,
            totalOutputFramesFlushed: outputMetrics.flushed,
            totalOutputFramesLate: outputMetrics.late,
            totalOutputUnderrunFrames: outputMetrics.underrunFrames,
            totalOutputUnderrunEvents: outputMetrics.underrunEvents,
            totalOutputOverrunEvents: outputMetrics.overrunEvents,
            totalOutputRouteChanges: outputMetrics.routeChanges,
            totalOutputConversionBatches: outputMetrics.conversionBatches,
            totalOutputConversionNanoseconds: outputMetrics.conversionNanoseconds,
            connectedOutputProducers: outputMetrics.connectedProducers,
            retainedOutputSessions: outputMetrics.retainedTerminalRecords,
            reservedOutputStarts: outputMetrics.reservedStarts,
            totalControlClientsAccepted: controlClientsAccepted,
            totalControlClientsDisconnected: controlClientsDisconnected,
            totalControlClientsRejected: controlClientsRejected,
            totalControlRequests: controlRequests,
            totalControlErrors: controlErrors,
            totalMalformedControlMessages: malformedControlMessages,
            totalControlHandshakeTimeouts: controlHandshakeTimeouts,
            totalSourceMonitorFailures: sourceMonitorFailures,
            totalDestinationMonitorFailures: destinationMonitorFailures,
            sourceMonitorConsecutiveFailures: sourceMonitorConsecutive,
            destinationMonitorConsecutiveFailures: destinationMonitorConsecutive,
            sourceMonitorRecoveries: sourceRecoveries,
            destinationMonitorRecoveries: destinationRecoveries,
            sourceMonitorLastSuccessNanoseconds: sourceLastSuccess,
            destinationMonitorLastSuccessNanoseconds: destinationLastSuccess,
            residentMemoryBytes: processMetrics.residentBytes,
            peakResidentMemoryBytes: processMetrics.peakResidentBytes,
            openFileDescriptors: processMetrics.openDescriptors,
            threadCount: processMetrics.threadCount,
            exactCounters: exactCounters)
    }

    private static func processMetrics() -> (residentBytes: UInt64, peakResidentBytes: UInt64,
                                               openDescriptors: Int, threadCount: Int) {
        var task = proc_taskinfo()
        let taskSize = MemoryLayout<proc_taskinfo>.size
        let taskResult = withUnsafeMutablePointer(to: &task) {
            proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, $0, Int32(taskSize))
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return (taskResult == Int32(taskSize) ? task.pti_resident_size : 0,
                UInt64(max(0, usage.ru_maxrss)),
                (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0,
                taskResult == Int32(taskSize) ? Int(task.pti_threadnum) : 0)
    }

    private func startSourceMonitor(generation expectedGeneration: UInt64) {
        monitorQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let shouldStart = self.listener != nil && self.generation == expectedGeneration
            self.stateLock.unlock()
            guard shouldStart else { return }
            self.refreshSources(publishChanges: false)
            self.refreshDestinations(publishChanges: false)
            self.stateLock.lock()
            let stillCurrent = self.listener != nil && self.generation == expectedGeneration
            self.stateLock.unlock()
            guard stillCurrent else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.monitorQueue)
            timer.schedule(deadline: .now() + 1, repeating: .seconds(1), leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                self?.refreshSources(publishChanges: true)
                self?.refreshDestinations(publishChanges: true)
            }
            self.endpointTimer = timer
            timer.resume()
        }
    }

    private func refreshSources(publishChanges: Bool) {
        do {
            let next = Dictionary(uniqueKeysWithValues: try coordinator.availableSources().map { ($0.id, $0) })
            if publishChanges {
                for (id, source) in next where sourceSnapshot[id] == nil {
                    eventHub.publish(RuntimeEventDTO(type: .sourceAdded, sourceID: id, source: source))
                }
                for (id, _) in sourceSnapshot where next[id] == nil {
                    // Do not attach the stale running/available snapshot to a
                    // removal event. Clients should evict the source by ID.
                    eventHub.publish(RuntimeEventDTO(type: .sourceRemoved, sourceID: id))
                }
                for (id, source) in next where sourceSnapshot[id] != nil && sourceSnapshot[id] != source {
                    eventHub.publish(RuntimeEventDTO(type: .sourceUpdated, sourceID: id, source: source))
                }
            }
            sourceSnapshot = next
            let recovered = sourceMonitorError != nil
            sourceMonitorError = nil
            stateLock.lock()
            if recovered { sourceMonitorRecoveries &+= 1 }
            sourceMonitorConsecutiveFailures = 0
            sourceMonitorLastSuccessNanoseconds = DispatchTime.now().uptimeNanoseconds
            stateLock.unlock()
            if publishChanges && recovered {
                eventHub.publish(RuntimeEventDTO(type: .runtimeWarning,
                    message: "Source discovery recovered"))
            }
        } catch {
            let description = String(describing: error)
            let firstFailure = sourceMonitorError == nil
            sourceMonitorError = description
            stateLock.lock()
            totalSourceMonitorFailures &+= 1
            sourceMonitorConsecutiveFailures &+= 1
            stateLock.unlock()
            guard publishChanges, firstFailure else { return }
            eventHub.publish(RuntimeEventDTO(type: .runtimeWarning,
                message: "Source discovery failed", error: RuntimeErrorDTO(
                    code: "source_discovery_failed", message: description, retryable: true)))
        }
    }

    private func refreshDestinations(publishChanges: Bool) {
        do {
            let destinations = try outputCoordinator.availableDestinations()
            let next = Dictionary(uniqueKeysWithValues: destinations.map { ($0.id, $0) })
            if publishChanges {
                let diff = RuntimeOutputDestinationDiff(
                    previous: destinationSnapshot, current: next)
                for destination in diff.added {
                    eventHub.publish(RuntimeEventDTO(type: .outputDestinationAdded,
                        outputDestinationID: destination.id, outputDestination: destination))
                }
                for destination in diff.removed {
                    eventHub.publish(RuntimeEventDTO(type: .outputDestinationRemoved,
                        outputDestinationID: destination.id, outputDestination: destination))
                }
                for destination in diff.updated {
                    eventHub.publish(RuntimeEventDTO(type: .outputDestinationUpdated,
                        outputDestinationID: destination.id, outputDestination: destination))
                }
                if let destination = diff.defaultChanged {
                    eventHub.publish(RuntimeEventDTO(type: .outputDefaultChanged,
                        outputDestinationID: destination.id, outputDestination: destination))
                }
            }
            destinationSnapshot = next
            let recovered = destinationMonitorError != nil
            destinationMonitorError = nil
            stateLock.lock()
            if recovered { destinationMonitorRecoveries &+= 1 }
            destinationMonitorConsecutiveFailures = 0
            destinationMonitorLastSuccessNanoseconds = DispatchTime.now().uptimeNanoseconds
            stateLock.unlock()
            if publishChanges && recovered {
                eventHub.publish(RuntimeEventDTO(type: .runtimeWarning,
                    message: "Output destination discovery recovered"))
            }
        } catch {
            let description = String(describing: error)
            let firstFailure = destinationMonitorError == nil
            destinationMonitorError = description
            stateLock.lock()
            totalDestinationMonitorFailures &+= 1
            destinationMonitorConsecutiveFailures &+= 1
            stateLock.unlock()
            guard publishChanges, firstFailure else { return }
            eventHub.publish(RuntimeEventDTO(type: .runtimeWarning,
                message: "Output destination discovery failed", error: RuntimeErrorDTO(
                    code: "output_destination_discovery_failed", message: description,
                    retryable: true)))
        }
    }
}
