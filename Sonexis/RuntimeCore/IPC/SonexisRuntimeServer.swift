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
    public let limits: RuntimeResourceLimitsDTO
    public let runtimeInstanceID = UUID().uuidString.lowercased()
    private let coordinator: RuntimeSessionCoordinator
    private let outputCoordinator: RuntimeOutputCoordinator
    private let eventHub: RuntimeEventHub
    private let acceptQueue = DispatchQueue(label: "com.sonexis.runtime.control.accept")
    private let clientQueue = DispatchQueue(label: "com.sonexis.runtime.control.clients", attributes: .concurrent)
    private let monitorQueue = DispatchQueue(label: "com.sonexis.runtime.endpoint-monitor")
    private let stateLock = NSLock()
    private let startedAt = DispatchTime.now().uptimeNanoseconds
    private var clients: [String: UnixSocketConnection] = [:]
    private var listener: UnixSocketListener?
    private var endpointTimer: DispatchSourceTimer?
    private var sourceSnapshot: [String: RuntimeSourceDTO] = [:]
    private var destinationSnapshot: [String: RuntimeOutputDestinationDTO] = [:]
    private var destinationMonitorError: String?
    private var generation: UInt64 = 0

    public init(socketDirectory: URL = RuntimeSocketPaths.userDefault.directory,
                backend: RuntimeCaptureBackend,
                outputBackend: RuntimeOutputBackend = UnavailableRuntimeOutputBackend(),
                limits: RuntimeResourceLimitsDTO = .init()) {
        paths = RuntimeSocketPaths(directory: socketDirectory)
        self.limits = limits
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
        coordinator.resume()
        outputCoordinator.resume()
        stateLock.lock()
        guard listener == nil else { stateLock.unlock(); return }
        let newListener = UnixSocketListener(path: paths.controlSocketPath, queue: acceptQueue)
        generation &+= 1
        let listenerGeneration = generation
        listener = newListener
        do {
            try newListener.start { [weak self, weak newListener] connection in
                guard let self, let newListener else { connection.close(); return }
                self.accept(connection, listener: newListener, generation: listenerGeneration)
            }
            stateLock.unlock()
            startSourceMonitor(generation: listenerGeneration)
        } catch {
            listener = nil
            generation &+= 1
            stateLock.unlock()
            throw error
        }
    }

    public func stop() {
        coordinator.prepareForShutdown()
        outputCoordinator.prepareForShutdown()
        monitorQueue.sync {
            endpointTimer?.setEventHandler {}
            endpointTimer?.cancel()
            endpointTimer = nil
            sourceSnapshot.removeAll()
            destinationSnapshot.removeAll()
            destinationMonitorError = nil
        }
        coordinator.stopAll()
        outputCoordinator.stopAll()
        eventHub.publish(RuntimeEventDTO(type: .runtimeShuttingDown, message: "Runtime is shutting down"))
        stateLock.lock()
        let oldListener = listener
        listener = nil
        generation &+= 1
        let activeClients = Array(clients.values)
        clients.removeAll()
        stateLock.unlock()
        oldListener?.stop()
        activeClients.forEach { $0.close() }
        eventHub.stopAll()
    }

    private func accept(_ connection: UnixSocketConnection,
                        listener acceptedListener: UnixSocketListener,
                        generation acceptedGeneration: UInt64) {
        let ownerID = UUID().uuidString.lowercased()
        stateLock.lock()
        guard listener === acceptedListener, generation == acceptedGeneration else {
            stateLock.unlock()
            connection.close()
            return
        }
        guard clients.count < limits.maximumControlClients else {
            stateLock.unlock()
            let error = RuntimeErrorDTO(code: "client_limit_exceeded",
                message: "Runtime control client limit reached", retryable: true)
            try? connection.write(RuntimeProtocolCodec.encodeLine(
                RuntimeResponse(requestID: "unknown", error: error)))
            connection.close()
            return
        }
        clients[ownerID] = connection
        stateLock.unlock()
        clientQueue.async { [weak self] in self?.serve(connection: connection, ownerID: ownerID) }
    }

    private func serve(connection: UnixSocketConnection, ownerID: String) {
        defer {
            coordinator.stopSessions(ownerID: ownerID)
            outputCoordinator.stopSessions(ownerID: ownerID)
            eventHub.removeSubscriptions(ownerID: ownerID)
            stateLock.lock(); clients.removeValue(forKey: ownerID); stateLock.unlock()
            connection.close()
        }
        var parser = RuntimeNDJSONParser()
        var handshaken = false
        while true {
            do {
                let bytes = try connection.read()
                let lines: [Data]
                do {
                    lines = try parser.append(bytes)
                } catch let error as RuntimeErrorDTO {
                    try? connection.write(RuntimeProtocolCodec.encodeLine(
                        RuntimeResponse(requestID: "unknown", error: error)))
                    return
                }
                for line in lines {
                    let response: RuntimeResponse
                    do {
                        let command = try RuntimeProtocolCodec.decodeLine(RuntimeCommand.self, from: line)
                        response = execute(command, ownerID: ownerID, handshaken: &handshaken)
                    } catch let error as RuntimeErrorDTO {
                        response = RuntimeResponse(requestID: "unknown", error: error)
                    } catch {
                        response = RuntimeResponse(requestID: "unknown", error: RuntimeErrorDTO(
                            code: "internal_error", message: "Runtime could not process the request"))
                    }
                    try connection.write(RuntimeProtocolCodec.encodeLine(response))
                }
            } catch { return }
        }
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
        stateLock.lock()
        let clientCount = clients.count
        stateLock.unlock()
        return RuntimeStatusDTO(runtimeVersion: RuntimeProtocolInfo.runtimeVersion,
            runtimeInstanceID: runtimeInstanceID,
            uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds - startedAt,
            activeClients: clientCount, activeSessions: metrics.activeSessions,
            eventSubscribers: eventHub.count, totalSessionsStarted: metrics.totalSessionsStarted,
            totalFramesForwarded: metrics.frames, totalDroppedFrames: metrics.dropped,
            totalBytesTransmitted: metrics.bytes, totalEventsDropped: eventHub.totalDroppedEvents,
            activeOutputSessions: outputMetrics.activeSessions,
            totalOutputSessionsStarted: outputMetrics.totalSessionsStarted,
            totalOutputFramesReceived: outputMetrics.received,
            totalOutputFramesRendered: outputMetrics.rendered,
            totalOutputFramesDropped: outputMetrics.dropped,
            totalOutputBytesReceived: outputMetrics.bytes)
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
        } catch {
            eventHub.publish(RuntimeEventDTO(type: .runtimeWarning,
                message: "Source discovery failed", error: RuntimeErrorDTO(
                    code: "source_discovery_failed", message: String(describing: error), retryable: true)))
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
            destinationMonitorError = nil
        } catch {
            let description = String(describing: error)
            guard publishChanges else { return }
            guard destinationMonitorError != description else { return }
            destinationMonitorError = description
            eventHub.publish(RuntimeEventDTO(type: .runtimeWarning,
                message: "Output destination discovery failed", error: RuntimeErrorDTO(
                    code: "output_destination_discovery_failed", message: description,
                    retryable: true)))
        }
    }
}
