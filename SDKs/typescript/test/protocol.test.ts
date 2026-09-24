import assert from "node:assert/strict";
import test from "node:test";
import { decodeFrame, SonexisError } from "../src/index.js";

test("decodes a protocol v2 PCM fixture", () => {
  const streamId = "00112233-4455-6677-8899-aabbccddeeff";
  const packet = Buffer.alloc(68);
  packet.writeUInt32BE(0x53585043, 0);
  packet.writeUInt16BE(2, 4);
  packet.writeUInt16BE(1, 6);
  packet.writeUInt32BE(64, 8);
  packet.writeUInt32BE(4, 12);
  Buffer.from(streamId.replaceAll("-", ""), "hex").copy(packet, 16);
  packet.writeBigUInt64BE(7n, 32);
  packet.writeBigUInt64BE(100n, 40);
  packet.writeUInt32BE(16000, 48);
  packet.writeUInt32BE(2, 52);
  packet.writeUInt16BE(1, 56);
  packet.writeUInt16BE(1, 58);
  packet.writeUInt32BE(3, 60);
  const frame = decodeFrame(packet, streamId);
  assert.equal(frame.sequence, 7n);
  assert.equal(frame.droppedFramesBefore, 3);
  assert.equal(frame.data.length, 4);
});

test("rejects a wrong stream", () => {
  const packet = Buffer.alloc(64);
  packet.writeUInt32BE(0x53585043, 0);
  packet.writeUInt16BE(2, 4);
  packet.writeUInt32BE(64, 8);
  packet.writeUInt16BE(1, 58);
  assert.throws(() => decodeFrame(packet, "00112233-4455-6677-8899-aabbccddeeff"), SonexisError);
});
