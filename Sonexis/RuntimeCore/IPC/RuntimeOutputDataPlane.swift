import Foundation

public struct RuntimeOutputDataPlaneMetrics: Equatable, Sendable {
    public let packetsReceived: UInt64
    public let inputFramesReceived: UInt64
    public let inputBytesReceived: UInt64
    public let discontinuitiesReceived: UInt64
    public let producerConnected: Bool
}

/// A single-producer client-to-Runtime PCM stream. Socket parsing and backend
/// delivery run on a dedicated non-realtime queue; the audio callback never
/// enters this type.
public final class RuntimeOutputDataPlane: @unchecked Sendable {
    public let path: String
    public let streamID: UUID
    public let format: RuntimePCMFormatDTO

    private let listenerQueue: DispatchQueue
    private let readerQueue: DispatchQueue
    private let listener: UnixSocketListener
    private let maximumPacketMilliseconds: UInt32
    private let onFrame: @Sendable (RuntimePCMFrame) throws -> Void
    private let onEndOfStream: @Sendable () -> Void
    private let onFailure: @Sendable (RuntimeErrorDTO) -> Void
    private let stateLock = NSLock()
    private var connection: UnixSocketConnection?
    private var running = false
    private var sawEndOfStream = false
    private var packetsReceived: UInt64 = 0
    private var framesReceived: UInt64 = 0
    private var bytesReceived: UInt64 = 0
    private var discontinuities: UInt64 = 0

    public init(path: String, streamID: UUID, format: RuntimePCMFormatDTO,
                maximumPacketMilliseconds: UInt32 = 200,
                onFrame: @escaping @Sendable (RuntimePCMFrame) throws -> Void,
                onEndOfStream: @escaping @Sendable () -> Void,
                onFailure: @escaping @Sendable (RuntimeErrorDTO) -> Void) {
        self.path = path
        self.streamID = streamID
        self.format = format
        self.maximumPacketMilliseconds = maximumPacketMilliseconds
        self.onFrame = onFrame
        self.onEndOfStream = onEndOfStream
        self.onFailure = onFailure
        listenerQueue = DispatchQueue(label: "com.sonexis.runtime.output-listener.\(streamID.uuidString)")
        readerQueue = DispatchQueue(label: "com.sonexis.runtime.output-reader.\(streamID.uuidString)")
        listener = UnixSocketListener(path: path, queue: listenerQueue)
    }

    public func start() throws {
        stateLock.lock()
        guard !running else { stateLock.unlock(); return }
        running = true
        stateLock.unlock()
        do {
            try listener.start { [weak self] candidate in
                self?.accept(candidate)
            }
        } catch {
            stateLock.lock()
            running = false
            stateLock.unlock()
            throw error
        }
    }

    public func stop() {
        stateLock.lock()
        guard running || connection != nil else { stateLock.unlock(); return }
        running = false
        let active = connection
        connection = nil
        stateLock.unlock()
        listener.stop()
        active?.close()
    }

    public func metrics() -> RuntimeOutputDataPlaneMetrics {
        stateLock.lock()
        defer { stateLock.unlock() }
        return RuntimeOutputDataPlaneMetrics(packetsReceived: packetsReceived,
            inputFramesReceived: framesReceived, inputBytesReceived: bytesReceived,
            discontinuitiesReceived: discontinuities,
            producerConnected: connection != nil)
    }

    private func accept(_ candidate: UnixSocketConnection) {
        stateLock.lock()
        guard running, connection == nil else {
            stateLock.unlock()
            candidate.close()
            return
        }
        connection = candidate
        sawEndOfStream = false
        stateLock.unlock()
        readerQueue.async { [weak self, weak candidate] in
            guard let self, let candidate else { return }
            self.receive(connection: candidate)
        }
    }

    private func receive(connection candidate: UnixSocketConnection) {
        var decoder = RuntimePCMStreamDecoder(expectedStreamID: streamID)
        var receivedAnyPacket = false
        var terminalError: RuntimeErrorDTO?
        do {
            while isCurrentConnection(candidate) {
                let bytes = try candidate.read(maximumBytes: 64 * 1024)
                for frame in try decoder.append(bytes) {
                    if !receivedAnyPacket, frame.header.sequence != 0 {
                        throw RuntimeErrorDTO(code: "invalid_output_sequence",
                            message: "The first output packet sequence must be zero")
                    }
                    receivedAnyPacket = true
                    if frame.header.flags.contains(.endOfStream) {
                        stateLock.lock()
                        sawEndOfStream = true
                        stateLock.unlock()
                        try decoder.finish(requireEndOfStream: true)
                        finishConnection(candidate)
                        onEndOfStream()
                        return
                    }
                    try validate(frame)
                    stateLock.lock()
                    packetsReceived &+= 1
                    framesReceived &+= UInt64(frame.header.frameCount)
                    bytesReceived &+= UInt64(frame.payload.count)
                    if frame.header.flags.contains(.discontinuity) { discontinuities &+= 1 }
                    stateLock.unlock()
                    try onFrame(frame)
                }
            }
        } catch UnixSocketError.disconnected {
            if shouldReportUnexpectedEnd(candidate) {
                terminalError = RuntimeErrorDTO(code: "output_stream_truncated",
                    message: "Output producer disconnected without an end-of-stream packet",
                    retryable: true)
            }
        } catch let error as RuntimeErrorDTO {
            if shouldReportFailure(candidate) { terminalError = error }
        } catch {
            if shouldReportFailure(candidate) {
                terminalError = RuntimeErrorDTO(code: "output_stream_failed",
                    message: String(describing: error), retryable: true)
            }
        }
        finishConnection(candidate)
        if let terminalError { onFailure(terminalError) }
    }

    private func validate(_ frame: RuntimePCMFrame) throws {
        let header = frame.header
        guard header.sampleRate == format.sampleRate,
              header.channelCount == format.channelCount,
              header.sampleFormat == format.sampleFormat else {
            throw RuntimeErrorDTO(code: "output_format_mismatch",
                message: "Output packet format differs from the negotiated session format")
        }
        let durationProduct = UInt64(header.frameCount) * 1_000
        guard durationProduct <= UInt64(maximumPacketMilliseconds) * UInt64(header.sampleRate) else {
            throw RuntimeErrorDTO(code: "output_packet_too_long",
                message: "Output packets may contain at most \(maximumPacketMilliseconds) ms of audio")
        }
    }

    private func isCurrentConnection(_ candidate: UnixSocketConnection) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running && connection === candidate
    }

    private func shouldReportUnexpectedEnd(_ candidate: UnixSocketConnection) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running && connection === candidate && !sawEndOfStream
    }

    private func shouldReportFailure(_ candidate: UnixSocketConnection) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running && connection === candidate
    }

    private func finishConnection(_ candidate: UnixSocketConnection) {
        stateLock.lock()
        if connection === candidate { connection = nil }
        let shouldStopListener = sawEndOfStream
        if shouldStopListener { running = false }
        stateLock.unlock()
        candidate.close()
        if shouldStopListener { listener.stop() }
    }
}

