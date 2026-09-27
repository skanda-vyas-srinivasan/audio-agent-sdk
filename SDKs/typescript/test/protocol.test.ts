import assert from "node:assert/strict";
import test from "node:test";
import {
  AmbiguousSourceError,
  AudioActivityDetector,
  AudioFrame,
  AudioFormats,
  AudioSource,
  CaptureStream,
  decodeEvent,
  decodeFrame,
  filterSources,
  MultiSourceSession,
  resolveSource,
  Sonexis,
  SonexisError,
  SourceNotFoundError,
} from "../src/index.js";

function activityFrame(sequence: number, amplitude: number): AudioFrame {
  const format = AudioFormats.speech16k();
  const data = Buffer.alloc(1600 * 2);
  const sample = Math.round(amplitude * 32767);
  for (let index = 0; index < 1600; index++) data.writeInt16LE(sample, index * 2);
  const value = source("app.test", "Test", "test", 1);
  return { streamId: "stream", sequence: BigInt(sequence),
    timestampNs: BigInt(sequence * 100_000_000), frameCount: 1600, format, data,
    discontinuity: false, droppedFramesBefore: 0, endOfStream: false,
    source: value, sourceId: value.id, sourceName: value.name,
    sessionId: "session", receivedAtNs: BigInt(sequence) };
}

test("activity detector emits debounced provider-neutral edges", () => {
  const detector = new AudioActivityDetector({
    activityStartThreshold: 0.02, activityEndThreshold: 0.01,
    minimumActivityMs: 200, silenceDurationMs: 300,
  });
  const edges = [0.2, 0.2, 0, 0, 0.2, 0, 0, 0]
    .map((value, index) => detector.observe(activityFrame(index + 1, value)))
    .filter((value) => value !== undefined);
  assert.deepEqual(edges.map((edge) => edge.type), ["activity_started", "activity_ended"]);
});

function source(id: string, name: string, bundle: string, pid: number,
                available = true): AudioSource {
  return { id, name, bundle_identifier: bundle, process_ids: [pid],
    kind: "application", process_state: available ? "running" : "stopped",
    is_available: available };
}

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
  assert.equal(frame.endOfStream, false);
});

test("rejects zero-length non-EOS PCM and accepts a strict EOS", () => {
  const streamId = "00112233-4455-6677-8899-aabbccddeeff";
  const packet = Buffer.alloc(64);
  packet.writeUInt32BE(0x53585043, 0);
  packet.writeUInt16BE(2, 4);
  packet.writeUInt32BE(64, 8);
  Buffer.from(streamId.replaceAll("-", ""), "hex").copy(packet, 16);
  packet.writeUInt16BE(1, 58);
  assert.throws(() => decodeFrame(packet, streamId), SonexisError);
  packet.writeUInt16BE(2, 6);
  assert.equal(decodeFrame(packet, streamId).endOfStream, true);
});

test("strictly validates Runtime event envelopes and UTF-8", () => {
  const event = decodeEvent(Buffer.from(JSON.stringify({
    protocol_version: 2,
    event_id: "event-1",
    type: "capture_started",
    timestamp_nanoseconds: 123,
    event_sequence: 1,
  })));
  assert.equal(event.type, "capture_started");
  assert.throws(() => decodeEvent(Buffer.from("{}")), SonexisError);
  assert.throws(() => decodeEvent(Buffer.from([0xff])), SonexisError);
  const destination = {
    id: "coreaudio:a", kind: "playback", name: "Speakers", is_available: true,
    is_default: false, follows_system_default: false, supported_formats: [AudioFormats.speech16k()],
  };
  const destinationEvent = decodeEvent(Buffer.from(JSON.stringify({
    protocol_version: 2, event_id: "event-2", type: "output_destination_added",
    timestamp_nanoseconds: 124, output_destination: destination,
  })));
  assert.equal(destinationEvent.output_destination_id, "coreaudio:a");
  assert.throws(() => decodeEvent(Buffer.from(JSON.stringify({
    protocol_version: 2, event_id: "event-3", type: "output_destination_updated",
    timestamp_nanoseconds: 125, output_destination_id: "coreaudio:b",
    output_destination: destination,
  }))), SonexisError);
});

test("rejects a wrong stream", () => {
  const packet = Buffer.alloc(64);
  packet.writeUInt32BE(0x53585043, 0);
  packet.writeUInt16BE(2, 4);
  packet.writeUInt32BE(64, 8);
  packet.writeUInt16BE(1, 58);
  assert.throws(() => decodeFrame(packet, "00112233-4455-6677-8899-aabbccddeeff"), SonexisError);
});

test("resolves exact source selectors without silently choosing ambiguous names", () => {
  const sources = [
    source("app.spotify", "Spotify", "com.spotify.client", 10),
    source("app.chat.one", "Chat", "example.chat.one", 20),
    source("app.chat.two", "Chat", "example.chat.two", 21),
    source("app.stopped", "Stopped", "example.stopped", 30, false),
  ];
  assert.equal(resolveSource(sources, "app.spotify").name, "Spotify");
  assert.equal(resolveSource(sources, "com.spotify.client").id, "app.spotify");
  assert.equal(resolveSource(sources, "spotify").id, "app.spotify");
  assert.equal(resolveSource(sources, 10).id, "app.spotify");
  assert.equal(resolveSource(sources, sources[0]).id, "app.spotify");
  assert.throws(() => resolveSource(sources, "Chat"), (error: unknown) => {
    assert.ok(error instanceof AmbiguousSourceError);
    assert.deepEqual(new Set(Object.values(error.details)),
      new Set(["app.chat.one", "app.chat.two"]));
    return true;
  });
  assert.throws(() => resolveSource(sources, "missing"), SourceNotFoundError);
  assert.throws(() => resolveSource(sources, "Stopped"), SourceNotFoundError);
});

test("missing Runtime reports an actionable structured connection error", async () => {
  const path = `/tmp/sonexis-not-running-${process.pid}.sock`;
  const client = new Sonexis(path);
  await assert.rejects(client.connect(), (error: unknown) => {
    assert.ok(error instanceof SonexisError);
    assert.equal(error.code, "runtime_unavailable");
    assert.match(error.message, /Start the local sonexis-runtime process/);
    assert.equal(error.details.socket_path, path);
    return true;
  });
});

test("filters source snapshots and exposes safe format presets", () => {
  const sources = [
    source("app.spotify", "Spotify", "com.spotify.client", 10),
    source("app.chat", "Chat", "example.chat", 20),
    source("app.stopped", "Stopped", "example.stopped", 30, false),
  ];
  assert.deepEqual(filterSources(sources, { query: "SPOT" }).map((value) => value.id),
    ["app.spotify"]);
  assert.deepEqual(filterSources(sources, { pid: 20 }).map((value) => value.id), ["app.chat"]);
  assert.equal(filterSources(sources, { availableOnly: false }).length, 3);
  assert.deepEqual(AudioFormats.speech16k(), {
    sample_rate: 16000, channel_count: 1, sample_format: "pcm_s16le", interleaved: true,
  });
  assert.equal(AudioFormats.openAIRealtime().sample_rate, 24000);
  assert.equal(AudioFormats.geminiLive().sample_rate, 16000);
  assert.equal(AudioFormats.pcm48kStereo().channel_count, 2);
});

test("waitForSource refreshes snapshots and reports a structured timeout", async () => {
  const client = new Sonexis("/unused");
  let snapshots = 0;
  client.sources = async () => ++snapshots < 2
    ? [] : [source("app.later", "Later", "example.later", 40)];
  const found = await client.waitForSource("Later", { timeoutMs: 100, pollIntervalMs: 1 });
  assert.equal(found.id, "app.later");

  client.sources = async () => [];
  await assert.rejects(
    client.waitForSource("Never", { timeoutMs: 1, pollIntervalMs: 1 }),
    (error: unknown) => {
      assert.ok(error instanceof SourceNotFoundError);
      assert.equal(error.code, "source_wait_timeout");
      assert.equal(error.retryable, true);
      return true;
    });
});

test("multi-source sessions preserve labels and source-aware frame context", async () => {
  const spotify = source("app.spotify", "Spotify", "com.spotify.client", 10);
  const chat = source("app.chat", "Chat", "example.chat", 20);
  const frames = new Map<string, AudioFrame>([
    ["Spotify", frame(spotify, "session-music", "00112233-4455-6677-8899-aabbccddeeff")],
    ["Chat", frame(chat, "session-chat", "10112233-4455-6677-8899-aabbccddeeff")],
  ]);
  const fakeClient = {
    capture: async (selector: string): Promise<CaptureStream> => {
      const value = frames.get(selector)!;
      return {
        close: async () => undefined,
        async *[Symbol.asyncIterator]() { yield value; },
      } as unknown as CaptureStream;
    },
  } as unknown as Sonexis;
  const group = new MultiSourceSession(fakeClient, 4);
  await group.add("media", "Spotify");
  await group.add("conversation", "Chat");
  const received = new Map<string, AudioFrame>();
  for await (const value of group.frames()) received.set(value.label, value.frame);
  assert.equal(received.get("media")?.sourceName, "Spotify");
  assert.equal(received.get("media")?.sessionId, "session-music");
  assert.equal(received.get("conversation")?.source.id, "app.chat");
  assert.deepEqual(group.labels, []);
});

function frame(audioSource: AudioSource, sessionId: string, streamId: string): AudioFrame {
  return {
    streamId,
    sequence: 1n,
    timestampNs: 100n,
    frameCount: 160,
    format: AudioFormats.speech16k(),
    data: Buffer.alloc(320),
    discontinuity: false,
    droppedFramesBefore: 0,
    endOfStream: false,
    source: audioSource,
    sourceId: audioSource.id,
    sourceName: audioSource.name,
    bundleIdentifier: audioSource.bundle_identifier,
    sessionId,
    receivedAtNs: 200n,
  };
}
