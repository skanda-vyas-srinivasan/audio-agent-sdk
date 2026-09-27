import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer, Server, Socket } from "node:net";
import test from "node:test";
import { randomUUID } from "node:crypto";
import {
  AudioFormats,
  AudioOutputDestination,
  encodeOutputFrame,
  OutputInfo,
  Sonexis,
  SonexisError,
} from "../src/index.js";

interface FakeRuntimeOptions {
  outputCapability?: boolean;
  malformedSession?: boolean;
  startError?: boolean;
  pauseData?: boolean;
}

class FakeOutputRuntime {
  readonly controlPath: string;
  readonly streamPaths: string[];
  readonly streamIds = [randomUUID(), randomUUID()];
  readonly commands: string[] = [];
  readonly requests: Array<Record<string, unknown>> = [];
  readonly packets: Buffer[][] = [[], []];
  readonly connections = new Set<Socket>();
  private controlServer?: Server;
  private readonly dataServers: Server[] = [];
  private epoch = 0;
  private state: OutputInfo["state"] = "ready";

  constructor(readonly directory: string, private readonly options: FakeRuntimeOptions = {}) {
    this.controlPath = join(directory, "control.sock");
    this.streamPaths = [join(directory, "output-0.sock"), join(directory, "output-1.sock")];
  }

  async start(): Promise<void> {
    for (let index = 0; index < this.streamPaths.length; index++) {
      const server = createServer((socket) => this.acceptData(index, socket));
      await listen(server, this.streamPaths[index]);
      this.dataServers.push(server);
    }
    this.controlServer = createServer((socket) => this.acceptControl(socket));
    await listen(this.controlServer, this.controlPath);
  }

  async close(): Promise<void> {
    for (const socket of this.connections) socket.destroy();
    await Promise.all([this.controlServer, ...this.dataServers]
      .filter((server): server is Server => !!server).map(closeServer));
  }

  private outputSession(epoch = this.epoch): Record<string, unknown> {
    if (this.options.malformedSession) return { id: "missing-fields" };
    return {
      id: "output-session",
      stream_id: this.streamIds[epoch],
      destination_id: "default",
      state: this.state,
      format: AudioFormats.openAIRealtime(),
      data_socket_path: this.streamPaths[epoch],
      started_at_nanoseconds: 100,
      target_buffer_milliseconds: 80,
      metrics: {
        packets_received: this.packets[epoch].length,
        input_frames_received: 480,
        input_bytes_received: 960,
        device_frames_enqueued: 480,
        device_frames_rendered: 240,
        dropped_frames: 3,
        flushed_frames: 0,
        late_frames: 0,
        underrun_frames: 0,
        underrun_events: 1,
        overrun_events: 0,
        queue_depth_frames: 240,
        queue_high_water_frames: 480,
        buffered_milliseconds: 10,
        target_buffer_milliseconds: 80,
        conversion_batches: 2,
        conversion_nanoseconds: 1000,
        route_changes: 0,
        producer_connected: this.state === "ready",
      },
    };
  }

  private acceptControl(socket: Socket): void {
    this.connections.add(socket);
    let buffer = Buffer.alloc(0);
    socket.on("data", (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      let newline: number;
      while ((newline = buffer.indexOf(0x0a)) >= 0) {
        const request = JSON.parse(buffer.subarray(0, newline).toString()) as Record<string, unknown>;
        buffer = buffer.subarray(newline + 1);
        this.requests.push(request);
        const command = String(request.command);
        this.commands.push(command);
        const response: Record<string, unknown> = {
          message_type: "response", protocol_version: 2, response_id: randomUUID(),
          request_id: request.request_id, ok: true,
        };
        if (command === "hello") {
          response.handshake = {
            protocol_version: 2, runtime_version: "0.4.0", runtime_instance_id: "instance",
            capabilities: this.options.outputCapability === false ? []
              : ["output_sessions", "output_destinations", "output_pcm_v2", "output_flush"],
            supported_formats: [AudioFormats.openAIRealtime()],
            limits: { maximum_output_sessions: 8 },
          };
        } else if (command === "list_output_destinations") {
          response.output_destinations = [{
            id: "default", kind: "playback", name: "System Default",
            is_available: true, is_default: true, follows_system_default: true,
            active_device_name: "Test Speakers", native_format: AudioFormats.pcm48kStereo(),
            supported_formats: [AudioFormats.openAIRealtime(), AudioFormats.pcm48kStereo()],
          }];
        } else if (command === "start_output") {
          if (this.options.startError) {
            response.ok = false;
            response.error = { code: "unsupported_format", message: "bad format", retryable: false };
          } else response.output_session = this.outputSession();
        } else if (command === "output_status") {
          response.output_session = this.outputSession();
        } else if (command === "flush_output") {
          this.epoch = 1;
          this.state = "ready";
          response.output_session = this.outputSession();
        } else if (command === "stop_output") {
          this.state = "cancelled";
          response.output_session = this.outputSession();
        } else {
          response.ok = false;
          response.error = { code: "unknown_command", message: command, retryable: false };
        }
        socket.write(`${JSON.stringify(response)}\n`);
      }
    });
    socket.on("close", () => this.connections.delete(socket));
  }

  private acceptData(index: number, socket: Socket): void {
    this.connections.add(socket);
    if (this.options.pauseData) {
      socket.pause();
      socket.on("close", () => this.connections.delete(socket));
      return;
    }
    let buffer = Buffer.alloc(0);
    socket.on("data", (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      while (buffer.length >= 64) {
        const payloadSize = buffer.readUInt32BE(12);
        if (buffer.length < 64 + payloadSize) return;
        const packet = Buffer.from(buffer.subarray(0, 64 + payloadSize));
        buffer = buffer.subarray(64 + payloadSize);
        this.packets[index].push(packet);
        if (packet.readUInt16BE(6) & 2) this.state = "stopped";
      }
    });
    socket.on("close", () => this.connections.delete(socket));
  }
}

test("encodes strict client-to-Runtime SXPC frames", () => {
  const streamId = "00112233-4455-6677-8899-aabbccddeeff";
  const packet = encodeOutputFrame({
    streamId, sequence: 7n, timestampNs: 123n, format: AudioFormats.openAIRealtime(),
    frameCount: 2, data: Buffer.from([1, 2, 3, 4]), discontinuity: true,
  });
  assert.equal(packet.length, 68);
  assert.equal(packet.readUInt32BE(0), 0x53585043);
  assert.equal(packet.readUInt16BE(4), 2);
  assert.equal(packet.readUInt16BE(6), 1);
  assert.equal(packet.readUInt32BE(12), 4);
  assert.equal(packet.subarray(16, 32).toString("hex"), streamId.replaceAll("-", ""));
  assert.equal(packet.readBigUInt64BE(32), 7n);
  assert.equal(packet.readBigUInt64BE(40), 123n);
  assert.equal(packet.readUInt32BE(48), 24000);
  assert.equal(packet.readUInt32BE(52), 2);
  assert.equal(packet.readUInt16BE(56), 1);
  assert.equal(packet.readUInt16BE(58), 1);
  assert.deepEqual(packet.subarray(64), Buffer.from([1, 2, 3, 4]));
  assert.throws(() => encodeOutputFrame({
    streamId, sequence: 0n, timestampNs: 0n, format: AudioFormats.openAIRealtime(),
    frameCount: 2, data: Buffer.alloc(2),
  }), RangeError);
});

test("enumerates typed destinations and exposes output metrics", async (context) => {
  const runtime = await startRuntime(context);
  const client = await Sonexis.connect(runtime.controlPath);
  context.after(() => client.close());
  const destinations = await client.outputDestinations();
  assert.equal(destinations.length, 1);
  const destination: AudioOutputDestination = destinations[0];
  assert.equal(destination.kind, "playback");
  assert.equal(destination.active_device_name, "Test Speakers");
  assert.equal(destination.supported_formats[1].channel_count, 2);
  const output = await client.playback({ destination });
  const status = await output.refresh();
  assert.equal(status.metrics.device_frames_rendered, 240);
  assert.equal(status.metrics.dropped_frames, 3);
  assert.equal(status.metrics.buffered_milliseconds, 10);
  await output.cancel();
});

test("splits writes at 200 ms with ordered timestamps and sends one EOS", async (context) => {
  const runtime = await startRuntime(context);
  const client = await Sonexis.connect(runtime.controlPath);
  const output = await client.playback();
  await output.write(Buffer.alloc(12_000 * 2), { discontinuity: true });
  await output.close();
  await eventually(() => runtime.packets[0].length === 4);
  const packets = runtime.packets[0];
  assert.deepEqual(packets.map((packet) => packet.readBigUInt64BE(32)), [0n, 1n, 2n, 3n]);
  assert.deepEqual(packets.slice(0, 3).map((packet) => packet.readBigUInt64BE(40)),
    [0n, 200_000_000n, 400_000_000n]);
  assert.deepEqual(packets.slice(0, 3).map((packet) => packet.readUInt32BE(52)),
    [4_800, 4_800, 2_400]);
  assert.equal(packets[0].readUInt16BE(6), 1);
  assert.equal(packets[1].readUInt16BE(6), 0);
  assert.equal(packets[3].readUInt16BE(6), 2);
  assert.equal(packets[3].readUInt32BE(12), 0);
  assert.equal(runtime.commands.filter((value) => value === "stop_output").length, 0);
  await client.close();
});

test("flush rotates the socket and resets sequence and timestamp epochs", async (context) => {
  const runtime = await startRuntime(context);
  const client = await Sonexis.connect(runtime.controlPath);
  const output = await client.createOutput();
  await output.write(Buffer.alloc(480));
  const info = await output.flush();
  assert.equal(info.stream_id, runtime.streamIds[1]);
  await output.write(Buffer.alloc(480));
  await output.close();
  await eventually(() => runtime.packets[1].length === 2);
  assert.equal(runtime.packets[0][0].readBigUInt64BE(32), 0n);
  assert.equal(runtime.packets[1][0].readBigUInt64BE(32), 0n);
  assert.equal(runtime.packets[1][0].readBigUInt64BE(40), 0n);
  assert.equal(runtime.commands.filter((value) => value === "flush_output").length, 1);
  await client.close();
});

test("cancel sends no EOS and client close cleans up every tracked output", async (context) => {
  const runtime = await startRuntime(context);
  const client = await Sonexis.connect(runtime.controlPath);
  const first = await client.playback();
  await first.write(Buffer.alloc(480));
  await first.cancel();
  assert.equal(runtime.packets[0].some((packet) => !!(packet.readUInt16BE(6) & 2)), false);
  await client.playback();
  await client.playback();
  await client.close();
  assert.equal(runtime.commands.filter((value) => value === "stop_output").length, 3);
});

test("a stalled consumer applies socket backpressure and cancellation unblocks write", async (context) => {
  const runtime = await startRuntime(context, { pauseData: true });
  const client = await Sonexis.connect(runtime.controlPath);
  const output = await client.playback();
  let settled = false;
  const write = output.write(Buffer.alloc(24_000 * 2 * 300)).finally(() => { settled = true; });
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.equal(settled, false);
  await output.cancel();
  await assert.rejects(write, SonexisError);
  await client.close();
});

test("reports capability, control, validation, and malformed-session errors", async (context) => {
  const oldRuntime = await startRuntime(context, { outputCapability: false });
  const oldClient = await Sonexis.connect(oldRuntime.controlPath);
  await assert.rejects(oldClient.playback(), (error: unknown) => {
    assert.ok(error instanceof SonexisError);
    assert.equal(error.code, "unsupported_capability");
    return true;
  });
  await oldClient.close();

  const rejected = await startRuntime(context, { startError: true });
  const rejectedClient = await Sonexis.connect(rejected.controlPath);
  await assert.rejects(rejectedClient.playback(), (error: unknown) => {
    assert.ok(error instanceof SonexisError);
    assert.equal(error.code, "unsupported_format");
    return true;
  });
  await rejectedClient.close();

  const malformed = await startRuntime(context, { malformedSession: true });
  const malformedClient = await Sonexis.connect(malformed.controlPath);
  await assert.rejects(malformedClient.playback(), (error: unknown) => {
    assert.ok(error instanceof SonexisError);
    assert.equal(error.code, "invalid_output_session");
    return true;
  });
  await malformedClient.close();

  const valid = await startRuntime(context);
  const validClient = await Sonexis.connect(valid.controlPath);
  await assert.rejects(validClient.playback({ targetBufferMilliseconds: 5 }), RangeError);
  const output = await validClient.playback();
  await assert.rejects(output.write(Buffer.alloc(3)), RangeError);
  await output.cancel();
  await validClient.close();
});

async function startRuntime(context: test.TestContext,
                            options: FakeRuntimeOptions = {}): Promise<FakeOutputRuntime> {
  const directory = await mkdtemp(join(tmpdir(), "sonexis-ts-output-"));
  const runtime = new FakeOutputRuntime(directory, options);
  await runtime.start();
  context.after(async () => {
    await runtime.close();
    await rm(directory, { recursive: true, force: true });
  });
  return runtime;
}

function listen(server: Server, path: string): Promise<void> {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(path, resolve);
  });
}

function closeServer(server: Server): Promise<void> {
  return new Promise((resolve) => server.close(() => resolve()));
}

async function eventually(predicate: () => boolean, timeoutMs = 1000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("Timed out waiting for fake Runtime");
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}
