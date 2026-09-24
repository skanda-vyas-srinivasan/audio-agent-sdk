import { EventEmitter } from "node:events";
import { createConnection, Socket } from "node:net";
import { randomUUID } from "node:crypto";

export type SampleFormat = "pcm_s16le" | "float32_le";
export interface AudioFormat {
  sample_rate: number;
  channel_count: number;
  sample_format: SampleFormat;
  interleaved: boolean;
}
export interface AudioSource {
  id: string;
  kind: "application" | "microphone" | "system_mix" | "remote" | "virtual";
  name: string;
  bundle_identifier?: string;
  process_ids: number[];
  process_state: "running" | "stopped" | "unknown";
  is_available: boolean;
  is_producing_audio?: boolean;
  native_format?: AudioFormat;
}
export interface SessionMetrics {
  capture_callbacks: number;
  native_frames_received: number;
  normalized_frames_delivered: number;
  ring_dropped_frames: number;
  delivery_dropped_frames: number;
  conversion_batches: number;
  conversion_nanoseconds: number;
  ring_backlog_frames: number;
  frames_forwarded: number;
  queue_dropped_frames: number;
  no_subscriber_frames: number;
  slow_consumer_disconnects: number;
  bytes_transmitted: number;
  connected_subscribers: number;
  data_queue_high_water_mark: number;
}
export interface CaptureInfo {
  id: string;
  stream_id: string;
  source_id: string;
  state: "starting" | "capturing" | "stopped" | "failed";
  format: AudioFormat;
  data_socket_path: string;
  started_at_nanoseconds: number;
  metrics: SessionMetrics;
}
export interface AudioFrame {
  streamId: string;
  sequence: bigint;
  timestampNs: bigint;
  frameCount: number;
  format: AudioFormat;
  data: Buffer;
  discontinuity: boolean;
  droppedFramesBefore: number;
}
export interface RuntimeEvent {
  protocol_version: 2;
  event_id: string;
  type: string;
  timestamp_nanoseconds: number;
  source_id?: string;
  session_id?: string;
  stream_id?: string;
  message?: string;
  dropped_frames?: number;
}
export interface Handshake {
  protocol_version: 2;
  runtime_version: string;
  runtime_instance_id: string;
  capabilities: string[];
  supported_formats: AudioFormat[];
  limits: Record<string, number>;
}

export class SonexisError extends Error {
  constructor(public readonly code: string, message: string,
              public readonly retryable = false,
              public readonly details: Record<string, string> = {},
              public readonly requestId?: string) {
    super(`${code}: ${message}`);
    this.name = "SonexisError";
  }
}

type WireResponse = Record<string, unknown> & {
  request_id: string; ok: boolean;
  error?: { code: string; message: string; retryable?: boolean; details?: Record<string, string> };
};

function openSocket(path: string): Promise<Socket> {
  return new Promise((resolve, reject) => {
    const socket = createConnection(path);
    socket.once("connect", () => resolve(socket));
    socket.once("error", reject);
  });
}

export class Sonexis extends EventEmitter {
  readonly socketPath: string;
  handshake?: Handshake;
  private socket?: Socket;
  private controlBuffer = Buffer.alloc(0);
  private readonly pending = new Map<string, {
    resolve: (value: WireResponse) => void; reject: (error: Error) => void;
  }>();

  constructor(socketPath = process.env.SONEXIS_RUNTIME_SOCKET
      ?? `/tmp/sonexis-runtime-${process.getuid()}/control.sock`) {
    super();
    this.socketPath = socketPath;
  }

  static async connect(socketPath?: string): Promise<Sonexis> {
    const client = new Sonexis(socketPath);
    await client.connect();
    return client;
  }

  async connect(): Promise<Handshake> {
    if (this.socket && this.handshake) return this.handshake;
    this.socket = await openSocket(this.socketPath);
    this.socket.on("data", (chunk) => this.consumeControl(chunk));
    this.socket.on("close", () => this.failPending(new SonexisError(
      "disconnected", "Runtime closed the control socket", true)));
    this.socket.on("error", (error) => this.failPending(error));
    const response = await this.request("hello", {
      supported_protocol_versions: [2], client_name: "sonexis-typescript", client_version: "0.2.0",
    });
    const handshake = response.handshake as Handshake;
    if (handshake?.protocol_version !== 2) {
      throw new SonexisError("invalid_handshake", "Runtime did not select protocol v2");
    }
    this.handshake = handshake;
    return handshake;
  }

  async close(): Promise<void> {
    const socket = this.socket;
    this.socket = undefined;
    this.handshake = undefined;
    if (socket) await new Promise<void>((resolve) => {
      socket.once("close", resolve);
      socket.destroy();
    });
  }

  async [Symbol.asyncDispose](): Promise<void> { await this.close(); }

  async sources(): Promise<AudioSource[]> {
    return (await this.request("list_sources")).sources as AudioSource[];
  }

  async status(sessionId?: string): Promise<Record<string, unknown>> {
    return this.request(sessionId ? "session_status" : "runtime_status",
      sessionId ? { session_id: sessionId } : {});
  }

  async capture(source: AudioSource | string,
                format: AudioFormat = { sample_rate: 16000, channel_count: 1,
                  sample_format: "pcm_s16le", interleaved: true }): Promise<CaptureStream> {
    const sourceId = typeof source === "string" ? source : source.id;
    const response = await this.request("start_capture", { source_id: sourceId, format });
    return CaptureStream.open(this, response.session as CaptureInfo);
  }

  async stop(sessionId: string): Promise<CaptureInfo> {
    return (await this.request("stop_capture", { session_id: sessionId })).session as CaptureInfo;
  }

  async events(eventTypes?: string[]): Promise<EventStream> {
    const response = await this.request("subscribe_events",
      eventTypes ? { event_types: eventTypes } : {});
    return EventStream.open(this, response.subscription as {
      id: string; event_socket_path: string; event_types: string[];
    });
  }

  async request(command: string, fields: Record<string, unknown> = {}): Promise<WireResponse> {
    if (!this.socket) throw new SonexisError("not_connected", "Connect first");
    const requestId = randomUUID();
    const request = { message_type: "request", protocol_version: 2,
      request_id: requestId, command, ...fields };
    const payload = Buffer.from(`${JSON.stringify(request)}\n`);
    if (payload.length > 65536) throw new SonexisError("message_too_large", "Request exceeds 64 KiB");
    const response = new Promise<WireResponse>((resolve, reject) => {
      this.pending.set(requestId, { resolve, reject });
    });
    this.socket.write(payload);
    return response;
  }

  private consumeControl(chunk: Buffer): void {
    this.controlBuffer = Buffer.concat([this.controlBuffer, chunk]);
    if (this.controlBuffer.length > 65536 && !this.controlBuffer.includes(0x0a)) {
      this.failPending(new SonexisError("message_too_large", "Response exceeds 64 KiB"));
      this.socket?.destroy();
      return;
    }
    let newline: number;
    while ((newline = this.controlBuffer.indexOf(0x0a)) >= 0) {
      const line = this.controlBuffer.subarray(0, newline);
      this.controlBuffer = this.controlBuffer.subarray(newline + 1);
      let response: WireResponse;
      try { response = JSON.parse(line.toString("utf8")) as WireResponse; }
      catch { this.failPending(new SonexisError("malformed_json", "Runtime sent invalid JSON")); return; }
      const pending = this.pending.get(response.request_id);
      if (!pending) { this.failPending(new SonexisError("unknown_response", "Unknown response ID")); return; }
      this.pending.delete(response.request_id);
      if (!response.ok) {
        const error = response.error;
        pending.reject(new SonexisError(error?.code ?? "runtime_error",
          error?.message ?? "Runtime request failed", error?.retryable ?? false,
          error?.details ?? {}, response.request_id));
      } else pending.resolve(response);
    }
  }

  private failPending(error: Error): void {
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
  }
}

export class CaptureStream extends EventEmitter implements AsyncIterable<AudioFrame> {
  private buffer = Buffer.alloc(0);
  private queue: AudioFrame[] = [];
  private waiters: Array<(value: IteratorResult<AudioFrame>) => void> = [];
  private ended = false;
  private previousSequence?: bigint;

  private constructor(private readonly client: Sonexis, readonly info: CaptureInfo,
                      private readonly socket: Socket) { super(); }

  static async open(client: Sonexis, info: CaptureInfo): Promise<CaptureStream> {
    const socket = await openSocket(info.data_socket_path);
    const stream = new CaptureStream(client, info, socket);
    socket.on("data", (chunk) => stream.consume(chunk));
    socket.on("close", () => stream.finish());
    socket.on("error", (error) => stream.emit("streamError", error));
    return stream;
  }

  async close(): Promise<void> {
    if (this.ended) return;
    this.socket.destroy();
    this.finish();
    try { await this.client.stop(this.info.id); } catch { /* idempotent cleanup */ }
  }

  async *[Symbol.asyncIterator](): AsyncIterator<AudioFrame> {
    while (true) {
      if (this.queue.length) {
        const frame = this.queue.shift()!;
        if (this.queue.length < 32) this.socket.resume();
        yield frame;
      }
      else if (this.ended) return;
      else {
        const result = await new Promise<IteratorResult<AudioFrame>>((resolve) => this.waiters.push(resolve));
        if (result.done) return;
        yield result.value;
      }
    }
  }

  private consume(chunk: Buffer): void {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (this.buffer.length >= 64) {
      const payloadSize = this.buffer.readUInt32BE(12);
      if (payloadSize > 512 * 1024) { this.emit("error", new SonexisError("invalid_pcm", "Payload too large")); this.close(); return; }
      if (this.buffer.length < 64 + payloadSize) return;
      const packet = this.buffer.subarray(0, 64 + payloadSize);
      this.buffer = this.buffer.subarray(64 + payloadSize);
      let frame: AudioFrame;
      try { frame = decodeFrame(packet, this.info.stream_id, this.previousSequence); }
      catch (error) {
        this.emit("streamError", error);
        this.socket.destroy();
        this.finish();
        return;
      }
      this.previousSequence = frame.sequence;
      if (frame.frameCount === 0) { this.finish(); return; }
      this.emit("audio", frame);
      const waiter = this.waiters.shift();
      if (waiter) waiter({ value: frame, done: false });
      else {
        this.queue.push(frame);
        if (this.queue.length >= 64) this.socket.pause();
      }
    }
  }

  private finish(): void {
    if (this.ended) return;
    this.ended = true;
    for (const waiter of this.waiters.splice(0)) waiter({ value: undefined, done: true });
  }
}

export class EventStream extends EventEmitter implements AsyncIterable<RuntimeEvent> {
  private buffer = "";
  private queue: RuntimeEvent[] = [];
  private waiters: Array<(value: IteratorResult<RuntimeEvent>) => void> = [];
  private ended = false;

  private constructor(private readonly client: Sonexis, readonly id: string,
                      private readonly socket: Socket) { super(); }
  static async open(client: Sonexis, value: { id: string; event_socket_path: string }): Promise<EventStream> {
    const socket = await openSocket(value.event_socket_path);
    const events = new EventStream(client, value.id, socket);
    socket.on("data", (chunk) => events.consume(chunk.toString("utf8")));
    socket.on("close", () => events.finish());
    socket.on("error", (error) => events.emit("streamError", error));
    return events;
  }
  async close(): Promise<void> {
    if (this.ended) return;
    this.socket.destroy(); this.finish();
    try { await this.client.request("unsubscribe_events", { subscription_id: this.id }); } catch { }
  }
  async *[Symbol.asyncIterator](): AsyncIterator<RuntimeEvent> {
    while (true) {
      if (this.queue.length) {
        const event = this.queue.shift()!;
        if (this.queue.length < 128) this.socket.resume();
        yield event;
      }
      else if (this.ended) return;
      else {
        const result = await new Promise<IteratorResult<RuntimeEvent>>((resolve) => this.waiters.push(resolve));
        if (result.done) return;
        yield result.value;
      }
    }
  }
  private consume(text: string): void {
    this.buffer += text;
    let newline: number;
    while ((newline = this.buffer.indexOf("\n")) >= 0) {
      let event: RuntimeEvent;
      try { event = JSON.parse(this.buffer.slice(0, newline)) as RuntimeEvent; }
      catch (error) {
        this.emit("streamError", error);
        this.socket.destroy();
        this.finish();
        return;
      }
      this.buffer = this.buffer.slice(newline + 1);
      this.emit("event", event);
      const waiter = this.waiters.shift();
      if (waiter) waiter({ value: event, done: false });
      else {
        this.queue.push(event);
        if (this.queue.length >= 256) this.socket.pause();
      }
    }
  }
  private finish(): void {
    if (this.ended) return;
    this.ended = true;
    for (const waiter of this.waiters.splice(0)) waiter({ value: undefined, done: true });
  }
}

export function decodeFrame(packet: Buffer, expectedStreamId: string,
                            previousSequence?: bigint): AudioFrame {
  if (packet.length < 64 || packet.readUInt32BE(0) !== 0x53585043
      || packet.readUInt16BE(4) !== 2 || packet.readUInt32BE(8) !== 64) {
    throw new SonexisError("invalid_pcm_header", "Invalid PCM header");
  }
  const flags = packet.readUInt16BE(6);
  if (flags & ~3) throw new SonexisError("invalid_pcm_header", "Unknown PCM flags");
  const payloadSize = packet.readUInt32BE(12);
  const streamId = uuidFromBytes(packet.subarray(16, 32));
  if (streamId !== expectedStreamId.toLowerCase()) {
    throw new SonexisError("stream_id_mismatch", "PCM frame belongs to another stream");
  }
  const sequence = packet.readBigUInt64BE(32);
  if (previousSequence !== undefined && (sequence <= previousSequence
      || (sequence !== previousSequence + 1n && !(flags & 1)))) {
    throw new SonexisError("invalid_pcm_sequence", "Invalid or unmarked PCM sequence gap");
  }
  const timestampNs = packet.readBigUInt64BE(40);
  const sampleRate = packet.readUInt32BE(48);
  const frameCount = packet.readUInt32BE(52);
  const channels = packet.readUInt16BE(56);
  const formatCode = packet.readUInt16BE(58);
  const sampleFormat: SampleFormat = formatCode === 1 ? "pcm_s16le" : formatCode === 2
    ? "float32_le" : (() => { throw new SonexisError("invalid_pcm_header", "Unknown format"); })();
  const expected = frameCount * channels * (formatCode === 1 ? 2 : 4);
  if (flags & 2 ? payloadSize !== 0 || frameCount !== 0 : payloadSize !== expected) {
    throw new SonexisError("invalid_pcm_payload", "PCM payload and format are inconsistent");
  }
  if (packet.length !== 64 + payloadSize) throw new SonexisError("truncated_pcm_stream", "Truncated PCM packet");
  return { streamId, sequence, timestampNs, frameCount,
    format: { sample_rate: sampleRate, channel_count: channels, sample_format: sampleFormat,
      interleaved: true }, data: packet.subarray(64), discontinuity: !!(flags & 1),
    droppedFramesBefore: packet.readUInt32BE(60) };
}

function uuidFromBytes(bytes: Buffer): string {
  const hex = bytes.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
