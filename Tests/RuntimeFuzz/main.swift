import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

private var seed: UInt64 = 0x5a17_2020_0200_0001
private func randomByte() -> UInt8 {
    seed = seed &* 6_364_136_223_846_793_005 &+ 1
    return UInt8(truncatingIfNeeded: seed >> 32)
}

let malformedJSON: [Data] = [
    Data(), Data([0xff, 0x0a]), Data("null\n".utf8), Data("[]\n".utf8),
    Data("{}\n".utf8), Data("{\"message_type\":1}\n".utf8),
    Data("{\"protocol_version\":2,\"command\":\"unknown\"}\n".utf8),
    Data("{\"request_id\":\"\(String(repeating: "x", count: 70_000))\"}\n".utf8),
]

for data in malformedJSON {
    do {
        _ = try RuntimeProtocolCodec.decodeLine(RuntimeCommand.self, from: data)
    } catch { /* Safe rejection is the property under test. */ }
}

for length in 1...512 {
    let bytes = Data((0..<length).map { _ in randomByte() })
    do {
        _ = try RuntimeProtocolCodec.decodeLine(RuntimeCommand.self, from: bytes)
    } catch { }
}

let streamID = UUID()
let payload = Data(repeating: 0x55, count: 320)
let validHeader = RuntimePCMFrameHeader(payloadByteCount: 320, streamID: streamID,
    sequence: 0, timestampNanoseconds: 0, sampleRate: 16_000, frameCount: 160,
    channelCount: 1)
let valid = try RuntimePCMFrameCodec.encode(header: validHeader, payload: payload)

for index in 0..<RuntimePCMFrameHeader.encodedSize {
    var mutated = valid
    mutated[index] ^= 0xff
    do {
        var decoder = RuntimePCMStreamDecoder(expectedStreamID: streamID)
        _ = try decoder.append(mutated)
        try decoder.finish()
    } catch { }
}

for truncation in 0..<valid.count {
    var decoder = RuntimePCMStreamDecoder(expectedStreamID: streamID)
    _ = try? decoder.append(valid.prefix(truncation))
    do {
        try decoder.finish()
        expect(truncation == 0, "truncated frame was accepted at byte \(truncation)")
    } catch { }
}

for split in 0...valid.count {
    var decoder = RuntimePCMStreamDecoder(expectedStreamID: streamID)
    let first = try decoder.append(valid.prefix(split))
    let second = try decoder.append(valid.suffix(from: split))
    expect(first.count + second.count == 1, "valid fragmented frame failed at \(split)")
}

print("Runtime protocol fuzz/adversarial corpus passed")
