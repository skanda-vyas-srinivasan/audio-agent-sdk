import Foundation

public struct RuntimeDataPlaneMetrics: Equatable, Sendable {
    public let framesForwarded: UInt64
    public let droppedFrames: UInt64
    public let connectedClients: Int
}

public final class RuntimeDataPlane: @unchecked Sendable {
    public let path: String
    private let queue: DispatchQueue
    private let listener: UnixSocketListener
    private let capacity = DispatchSemaphore(value: 64)
    private var clients: [UUID: UnixSocketConnection] = [:]
    private var running = false
    private var forwarded: UInt64 = 0
    private var dropped: UInt64 = 0

    public init(path: String) {
        self.path = path
        queue = DispatchQueue(label: "com.sonexis.runtime.data.\(UUID().uuidString)")
        listener = UnixSocketListener(path: path, queue: queue, acceptedConnectionsNonBlocking: true)
    }

    public func start() throws {
        try queue.sync {
            guard !running else { return }
            try listener.start { [weak self] connection in
                guard let self else { connection.close(); return }
                self.clients[UUID()] = connection
            }
            running = true
        }
    }

    /// Enqueues at most 64 frames. A full queue drops the newest frame instead of
    /// allowing an arbitrarily slow client to consume unbounded memory.
    public func offer(_ frame: RuntimeBackendAudioFrame) {
        guard capacity.wait(timeout: .now()) == .success else {
            queue.async { [weak self] in self?.dropped &+= 1 }
            return
        }
        queue.async { [weak self] in
            defer { self?.capacity.signal() }
            guard let self, self.running else { return }
            do {
                guard frame.payload.count <= Int(UInt32.max) else { self.dropped &+= 1; return }
                let header = RuntimePCMFrameHeader(payloadByteCount: UInt32(frame.payload.count),
                    sequence: frame.sequence, timestampNanoseconds: frame.timestampNanoseconds,
                    sampleRate: frame.format.sampleRate, frameCount: frame.frameCount,
                    channelCount: frame.format.channelCount, bitsPerChannel: frame.format.bitsPerChannel)
                let encoded = try RuntimePCMFrameCodec.encode(header: header, payload: frame.payload)
                var dead: [UUID] = []
                for (id, client) in self.clients {
                    do { try client.write(encoded) } catch { dead.append(id); client.close() }
                }
                dead.forEach { self.clients.removeValue(forKey: $0) }
                if self.clients.isEmpty { self.dropped &+= 1 } else { self.forwarded &+= 1 }
            } catch {
                self.dropped &+= 1
            }
        }
    }

    public func stop() {
        queue.sync {
            guard running else { return }
            running = false
            listener.stop()
            clients.values.forEach { $0.close() }
            clients.removeAll()
        }
    }

    public func metrics() -> RuntimeDataPlaneMetrics {
        queue.sync { RuntimeDataPlaneMetrics(framesForwarded: forwarded, droppedFrames: dropped, connectedClients: clients.count) }
    }
}
