import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

private func expectError(_ code: String, _ work: () throws -> Void) {
    do {
        try work()
        fatalError("expected \(code)")
    } catch let error as RuntimeErrorDTO {
        expect(error.code == code, "expected \(code), got \(error.code)")
    } catch {
        fatalError("unexpected error: \(error)")
    }
}

do {
    let command = RuntimeCommand(requestID: "request-1", command: .hello,
        supportedProtocolVersions: [2], clientName: "tests", clientVersion: "1")
    let line = try RuntimeProtocolCodec.encodeLine(command)
    expect(line.last == 0x0A, "control messages must be newline terminated")
    expect(String(decoding: line, as: UTF8.self).contains("\"protocol_version\":2"),
           "wire keys are not snake_case")
    let decodedCommand = try RuntimeProtocolCodec.decodeLine(RuntimeCommand.self, from: line)
    expect(decodedCommand == command,
           "control command did not round trip")

    let outputCommand = RuntimeCommand(requestID: "output-1", command: .startOutput,
        format: RuntimePCMFormatDTO(sampleRate: 24_000, channelCount: 1),
        destinationID: "default", targetBufferMilliseconds: 80)
    let decodedOutputCommand = try RuntimeProtocolCodec.decodeLine(RuntimeCommand.self,
        from: RuntimeProtocolCodec.encodeLine(outputCommand))
    expect(decodedOutputCommand == outputCommand, "output command did not round trip")

    let outputSession = RuntimeOutputSessionDTO(id: "output-session", streamID: UUID().uuidString,
        destinationID: "default", state: .ready,
        format: RuntimePCMFormatDTO(sampleRate: 24_000, channelCount: 1),
        dataSocketPath: "/tmp/output.sock", startedAtNanoseconds: 1,
        targetBufferMilliseconds: 80,
        metrics: RuntimeOutputMetricsDTO(packetsReceived: 2, inputFramesReceived: 480,
            inputBytesReceived: 960, deviceFramesEnqueued: 960,
            deviceFramesRendered: 720, queueDepthFrames: 240,
            bufferedMilliseconds: 5, targetBufferMilliseconds: 80,
            producerConnected: true))
    let decodedOutput = try RuntimeProtocolCodec.decodeLine(RuntimeOutputSessionDTO.self,
        from: RuntimeProtocolCodec.encodeLine(outputSession))
    expect(decodedOutput == outputSession, "output session did not round trip")

    let largeCounter = UInt64(9_007_199_254_740_993)
    let preciseStatus = RuntimeStatusDTO(runtimeVersion: "0.8.0",
        runtimeInstanceID: "instance", uptimeNanoseconds: largeCounter,
        activeClients: 1, activeSessions: 0, eventSubscribers: 0,
        totalSessionsStarted: largeCounter, totalFramesForwarded: largeCounter,
        totalDroppedFrames: 0, totalBytesTransmitted: largeCounter,
        totalEventsDropped: 0,
        exactCounters: ["total_sessions_started": String(largeCounter)])
    let decodedPreciseStatus = try RuntimeProtocolCodec.decodeLine(RuntimeStatusDTO.self,
        from: RuntimeProtocolCodec.encodeLine(preciseStatus))
    expect(decodedPreciseStatus.exactCounters?["total_sessions_started"]
            == "9007199254740993",
           "exact diagnostic counter did not survive protocol round trip")

    let oldDefault = RuntimeOutputDestinationDTO(id: "default", kind: .playback,
        name: "Default Output", isAvailable: true, isDefault: true,
        followsSystemDefault: true, activeDeviceID: "coreaudio:built-in",
        activeDeviceName: "Built-in Output")
    let newDefault = RuntimeOutputDestinationDTO(id: "default", kind: .playback,
        name: "Default Output", isAvailable: true, isDefault: true,
        followsSystemDefault: true, activeDeviceID: "coreaudio:headphones",
        activeDeviceName: "Headphones")
    let loopback = RuntimeOutputDestinationDTO(id: "coreaudio:blackhole", kind: .virtualInput,
        name: "BlackHole 2ch", isAvailable: true)
    let diff = RuntimeOutputDestinationDiff(
        previous: [oldDefault.id: oldDefault],
        current: [newDefault.id: newDefault, loopback.id: loopback])
    expect(diff.added == [loopback], "destination addition was not detected")
    expect(diff.removed.isEmpty, "destination removal was invented")
    expect(diff.updated.isEmpty, "default route change also emitted a generic update")
    expect(diff.defaultChanged == newDefault, "default route change was not detected")

    let renamedLoopback = RuntimeOutputDestinationDTO(id: loopback.id, kind: .virtualInput,
        name: "BlackHole Stereo", isAvailable: true)
    let metadataDiff = RuntimeOutputDestinationDiff(
        previous: [loopback.id: loopback], current: [renamedLoopback.id: renamedLoopback])
    expect(metadataDiff.updated == [renamedLoopback] && metadataDiff.defaultChanged == nil,
        "destination metadata update was not isolated")

    let destinationEvent = RuntimeEventDTO(type: .outputDefaultChanged,
        outputDestination: newDefault)
    let decodedDestinationEvent = try RuntimeProtocolCodec.decodeLine(RuntimeEventDTO.self,
        from: RuntimeProtocolCodec.encodeLine(destinationEvent))
    expect(decodedDestinationEvent == destinationEvent,
        "output destination event did not round trip")

    let removal = RuntimeOutputDestinationDiff(
        previous: [oldDefault.id: oldDefault, loopback.id: loopback],
        current: [oldDefault.id: oldDefault])
    expect(removal.removed == [loopback], "destination removal was not detected")

    let source = RuntimeSourceDTO(id: "app.example", processID: 42,
        bundleIdentifier: "com.example", name: "Example")
    let sourceLine = try RuntimeProtocolCodec.encodeLine(source)
    let sourceJSON = String(decoding: sourceLine, as: UTF8.self)
    expect(sourceJSON.contains("\"process_ids\""), "source process_ids wire key is missing")
    expect(!sourceJSON.contains("process_i_ds"), "source uses an unstable acronym key")
    let decodedSource = try RuntimeProtocolCodec.decodeLine(RuntimeSourceDTO.self, from: sourceLine)
    expect(decodedSource == source, "source did not round trip: \(sourceJSON) decoded=\(decodedSource)")

    for split in 0...line.count {
        var parser = RuntimeNDJSONParser()
        let first = try parser.append(line.prefix(split))
        let second = try parser.append(line.suffix(from: split))
        expect(first.count + second.count == 1, "fragmented line failed at \(split)")
    }
    var twoLines = line
    twoLines.append(line)
    var coalesced = RuntimeNDJSONParser()
    let coalescedLines = try coalesced.append(twoLines)
    expect(coalescedLines.count == 2, "coalesced lines were not separated")
    var tinyLines = RuntimeNDJSONParser()
    let tinyLineValues = try tinyLines.append(Data(repeating: 0x0A, count: 10_000))
    expect(tinyLineValues.count == 10_000,
           "packed tiny control lines were not parsed in one cursor-based pass")

    expectError("message_too_large") {
        var oversized = RuntimeNDJSONParser()
        _ = try oversized.append(Data(repeating: 0x61,
            count: RuntimeProtocolCodec.maximumControlMessageBytes + 1))
    }
    expectError("malformed_json") {
        _ = try RuntimeProtocolCodec.decodeLine(RuntimeCommand.self, from: Data([0xff, 0x0a]))
    }
    expectError("malformed_json") {
        _ = try RuntimeProtocolCodec.decodeLine(RuntimeCommand.self,
            from: Data("{\"protocol_version\":\"two\"}\n".utf8))
    }

    let streamID = UUID()
    for format in RuntimePCMFormatDTO.supported {
        let frameCount: UInt32 = 7
        let payload = Data(repeating: 0x3c, count: Int(frameCount) * format.bytesPerFrame)
        let header = RuntimePCMFrameHeader(flags: [.discontinuity],
            payloadByteCount: UInt32(payload.count), streamID: streamID, sequence: 42,
            timestampNanoseconds: 99, sampleRate: format.sampleRate, frameCount: frameCount,
            channelCount: format.channelCount, sampleFormat: format.sampleFormat,
            droppedFramesBefore: 11)
        let encoded = try RuntimePCMFrameCodec.encode(header: header, payload: payload)
        expect(encoded.count == 64 + payload.count, "encoded PCM length is wrong")
        let decodedHeader = try RuntimePCMFrameCodec.decodeHeader(Data(encoded.prefix(64)))
        expect(decodedHeader == header,
               "PCM header did not round trip for \(format)")

        for split in 0...encoded.count {
            var decoder = RuntimePCMStreamDecoder(expectedStreamID: streamID)
            let first = try decoder.append(encoded.prefix(split))
            let second = try decoder.append(encoded.suffix(from: split))
            expect(first + second == [RuntimePCMFrame(header: header, payload: payload)],
                   "fragmented PCM failed at \(split)")
            try decoder.finish()
        }
    }

    let payload = Data(repeating: 1, count: 4)
    let firstHeader = RuntimePCMFrameHeader(payloadByteCount: 4, streamID: streamID,
        sequence: 1, timestampNanoseconds: 0, sampleRate: 16_000, frameCount: 2,
        channelCount: 1)
    let gapHeader = RuntimePCMFrameHeader(payloadByteCount: 4, streamID: streamID,
        sequence: 3, timestampNanoseconds: 125_000, sampleRate: 16_000, frameCount: 2,
        channelCount: 1)
    var sequenceDecoder = RuntimePCMStreamDecoder(expectedStreamID: streamID)
    _ = try sequenceDecoder.append(RuntimePCMFrameCodec.encode(header: firstHeader, payload: payload))
    expectError("unmarked_pcm_gap") {
        _ = try sequenceDecoder.append(RuntimePCMFrameCodec.encode(header: gapHeader, payload: payload))
    }

    let encoded = try RuntimePCMFrameCodec.encode(header: firstHeader, payload: payload)
    var truncated = RuntimePCMStreamDecoder(expectedStreamID: streamID)
    _ = try truncated.append(encoded.dropLast())
    expectError("truncated_pcm_stream") { try truncated.finish() }

    var wrongStream = RuntimePCMStreamDecoder(expectedStreamID: UUID())
    expectError("stream_id_mismatch") { _ = try wrongStream.append(encoded) }

    let eos = RuntimePCMFrameHeader(flags: [.endOfStream], payloadByteCount: 0,
        streamID: streamID, sequence: 2, timestampNanoseconds: 125_000,
        sampleRate: 0, frameCount: 0, channelCount: 0)
    var complete = RuntimePCMStreamDecoder(expectedStreamID: streamID)
    _ = try complete.append(encoded)
    _ = try complete.append(RuntimePCMFrameCodec.encode(header: eos, payload: Data()))
    try complete.finish(requireEndOfStream: true)

    var packed = Data()
    for sequence in 0..<900 {
        let tinyHeader = RuntimePCMFrameHeader(payloadByteCount: 2, streamID: streamID,
            sequence: UInt64(sequence), timestampNanoseconds: UInt64(sequence) * 62_500,
            sampleRate: 16_000, frameCount: 1, channelCount: 1)
        packed.append(try RuntimePCMFrameCodec.encode(
            header: tinyHeader, payload: Data([0, 0])))
    }
    var packedDecoder = RuntimePCMStreamDecoder(expectedStreamID: streamID)
    let packedFrames = try packedDecoder.append(packed)
    expect(packedFrames.count == 900,
           "packed tiny frames were not decoded in one cursor-based pass")
    try packedDecoder.finish()

    print("Runtime protocol v2 tests passed")
} catch {
    fatalError("Runtime protocol test failed: \(error)")
}
