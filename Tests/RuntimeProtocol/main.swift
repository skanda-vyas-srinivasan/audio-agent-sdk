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

    print("Runtime protocol v2 tests passed")
} catch {
    fatalError("Runtime protocol test failed: \(error)")
}
