import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

do {
    let command = RuntimeCommand(requestID: "request-1", command: .startCapture, sourceID: "app.example.audio")
    let line = try RuntimeProtocolCodec.encodeLine(command)
    expect(line.last == 0x0A, "control messages must be newline terminated")
    let roundTripped = try RuntimeProtocolCodec.decodeLine(RuntimeCommand.self, from: line)
    expect(roundTripped == command,
           "control command did not round trip")

    var parser = RuntimeNDJSONParser()
    let split = line.count / 2
    let firstFragment = try parser.append(line.prefix(split))
    expect(firstFragment.isEmpty, "fragment should remain buffered")
    let parsed = try parser.append(line.suffix(from: split))
    expect(parsed.count == 1, "fragmented line was not reconstructed")

    var twoLines = line
    twoLines.append(line)
    var coalesced = RuntimeNDJSONParser()
    let coalescedLines = try coalesced.append(twoLines)
    expect(coalescedLines.count == 2, "coalesced lines were not separated")

    do {
        var oversized = RuntimeNDJSONParser()
        _ = try oversized.append(Data(repeating: 0x61,
            count: RuntimeProtocolCodec.maximumControlMessageBytes + 1))
        fatalError("oversized control input was accepted")
    } catch let error as RuntimeErrorDTO {
        expect(error.code == "message_too_large", "wrong oversized-input error")
    }

    let payload = Data([0x01, 0x02, 0x03, 0x04])
    let header = RuntimePCMFrameHeader(payloadByteCount: 4, sequence: 42,
        timestampNanoseconds: 99, sampleRate: 16_000, frameCount: 2,
        channelCount: 1, bitsPerChannel: 16)
    let encoded = try RuntimePCMFrameCodec.encode(header: header, payload: payload)
    expect(encoded.count == RuntimePCMFrameHeader.encodedSize + payload.count,
           "encoded PCM length is wrong")
    let decodedHeader = try RuntimePCMFrameCodec.decodeHeader(
        Data(encoded.prefix(RuntimePCMFrameHeader.encodedSize)))
    expect(decodedHeader == header,
           "PCM header did not round trip")

    var stream = RuntimePCMStreamDecoder()
    let partialFrames = try stream.append(encoded.prefix(7))
    expect(partialFrames.isEmpty, "partial header emitted a frame")
    let decoded = try stream.append(encoded.dropFirst(7))
    expect(decoded == [RuntimePCMFrame(header: header, payload: payload)],
           "fragmented PCM frame did not round trip")

    do {
        _ = try RuntimeProtocolCodec.decodeLine(RuntimeCommand.self, from: Data("not-json\n".utf8))
        fatalError("malformed JSON was accepted")
    } catch let error as RuntimeErrorDTO {
        expect(error.code == "malformed_json", "wrong malformed-input error")
    }

    print("Runtime protocol tests passed")
} catch {
    fatalError("Runtime protocol test failed: \(error)")
}
