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

function audioFormat(sampleRate: number, channelCount: number,
                     sampleFormat: SampleFormat = "pcm_s16le"): AudioFormat {
  return { sample_rate: sampleRate, channel_count: channelCount, sample_format: sampleFormat,
    interleaved: true };
}

/** Known-good format requests for common realtime audio consumers. */
export const AudioFormats = Object.freeze({
  speech16k: (): AudioFormat => audioFormat(16000, 1),
  openAIRealtime: (): AudioFormat => audioFormat(24000, 1),
  geminiLive: (): AudioFormat => audioFormat(16000, 1),
  pcm48kMono: (): AudioFormat => audioFormat(48000, 1),
  pcm48kStereo: (): AudioFormat => audioFormat(48000, 2),
});

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

export type SourceSelector = AudioSource | string | number;

export interface SourceFilter {
  /** Case-insensitive substring matched against ID, bundle ID, and name. */
  query?: string;
  sourceId?: string;
  bundleIdentifier?: string;
  pid?: number;
  name?: string;
  availableOnly?: boolean;
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
  error?: RuntimeErrorInfo;
}
export interface RuntimeErrorInfo {
  code: string;
  message: string;
  retryable: boolean;
  details?: Record<string, string>;
}
export interface DecodedAudioFrame {
  streamId: string;
  sequence: bigint;
  timestampNs: bigint;
  frameCount: number;
  format: AudioFormat;
  data: Buffer;
  discontinuity: boolean;
  droppedFramesBefore: number;
}

/** A decoded PCM frame enriched with capture-session and source identity. */
export interface AudioFrame extends DecodedAudioFrame {
  source: AudioSource;
  sourceId: string;
  sourceName: string;
  bundleIdentifier?: string;
  sessionId: string;
  /** Local monotonic receipt time, separate from the Runtime stream timestamp. */
  receivedAtNs: bigint;
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
  event_sequence?: number;
  dropped_events_before?: number;
  source?: AudioSource;
  session?: CaptureInfo;
  error?: RuntimeErrorInfo;
}
export interface RuntimeStatus {
  runtime_version: string;
  runtime_instance_id: string;
  uptime_nanoseconds: number;
  active_clients: number;
  active_sessions: number;
  event_subscribers: number;
  total_sessions_started: number;
  total_frames_forwarded: number;
  total_dropped_frames: number;
  total_bytes_transmitted: number;
  total_events_dropped: number;
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

export class SourceNotFoundError extends SonexisError {
  constructor(message: string, code = "source_not_found",
              details: Record<string, string> = {}) {
    super(code, message, true, details);
    this.name = "SourceNotFoundError";
  }
}

export class AmbiguousSourceError extends SonexisError {
  constructor(message: string, details: Record<string, string>) {
    super("ambiguous_source", message, false, details);
    this.name = "AmbiguousSourceError";
  }
}

/** Filter an already-fetched source snapshot without another Runtime request. */
export function filterSources(sources: readonly AudioSource[], filter: SourceFilter = {}): AudioSource[] {
  const availableOnly = filter.availableOnly ?? true;
  const query = filter.query?.toLowerCase();
  return sources.filter((source) => {
    if (availableOnly && !source.is_available) return false;
    if (filter.sourceId !== undefined && source.id !== filter.sourceId) return false;
    if (filter.bundleIdentifier !== undefined
        && source.bundle_identifier !== filter.bundleIdentifier) return false;
    if (filter.pid !== undefined && !source.process_ids.includes(filter.pid)) return false;
    if (filter.name !== undefined && source.name !== filter.name) return false;
    if (query !== undefined && ![source.id, source.bundle_identifier ?? "", source.name]
      .some((value) => value.toLowerCase().includes(query))) return false;
    return true;
  });
}

/** Resolve an ID, bundle ID, PID, exact app name, or source object uniquely. */
export function resolveSource(sources: readonly AudioSource[], selector: SourceSelector): AudioSource {
  const available = sources.filter((source) => source.is_available);
  let candidates: AudioSource[];
  if (typeof selector === "number") {
    candidates = available.filter((source) => source.process_ids.includes(selector));
  } else if (typeof selector !== "string") {
    candidates = available.filter((source) => source.id === selector.id);
  } else {
    candidates = available.filter((source) => source.id === selector);
    if (!candidates.length) {
      candidates = available.filter((source) => source.bundle_identifier === selector);
    }
    if (!candidates.length) {
      candidates = available.filter((source) => source.name === selector);
    }
    if (!candidates.length) {
      const folded = selector.toLowerCase();
      candidates = available.filter((source) => source.name.toLowerCase() === folded);
    }
  }
  if (!candidates.length) {
    throw new SourceNotFoundError(`No available audio source matches ${formatSelector(selector)}`);
  }
  if (candidates.length > 1) {
    const details = Object.fromEntries(candidates.map((source, index) =>
      [`candidate_${index + 1}`, source.id]));
    throw new AmbiguousSourceError(
      `Audio source selector ${formatSelector(selector)} is ambiguous`, details);
  }
  return candidates[0];
}

function formatSelector(selector: SourceSelector): string {
  if (typeof selector === "string") return JSON.stringify(selector);
  if (typeof selector === "number") return String(selector);
  return JSON.stringify(selector.id);
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
    const socket = await openSocket(this.socketPath);
    this.socket = socket;
    socket.on("data", (chunk) => this.consumeControl(chunk));
    socket.on("close", () => this.handleDisconnect(socket, new SonexisError(
      "disconnected", "Runtime closed the control socket", true)));
    socket.on("error", (error) => this.handleDisconnect(socket, error));
    try {
      const response = await this.request("hello", {
        supported_protocol_versions: [2], client_name: "sonexis-typescript", client_version: "0.3.0",
      });
      const handshake = response.handshake as Handshake;
      if (handshake?.protocol_version !== 2) {
        throw new SonexisError("invalid_handshake", "Runtime did not select protocol v2");
      }
      this.handshake = handshake;
      return handshake;
    } catch (error) {
      await this.close();
      throw error;
    }
  }

  async close(): Promise<void> {
    const socket = this.socket;
    this.socket = undefined;
    this.handshake = undefined;
    this.controlBuffer = Buffer.alloc(0);
    this.failPending(new SonexisError("disconnected", "Client closed", true));
    if (socket && !socket.destroyed) await new Promise<void>((resolve) => {
      socket.once("close", resolve);
      socket.destroy();
    });
  }

  async sources(): Promise<AudioSource[]> {
    return (await this.request("list_sources")).sources as AudioSource[];
  }

  /** Search a fresh Runtime snapshot. A string query is a case-insensitive substring search. */
  async findSources(queryOrFilter: string | SourceFilter = {}): Promise<AudioSource[]> {
    const filter = typeof queryOrFilter === "string"
      ? { query: queryOrFilter } : queryOrFilter;
    return filterSources(await this.sources(), filter);
  }

  /** Resolve a source selector exactly; ambiguous names are never chosen silently. */
  async getSource(selector: SourceSelector): Promise<AudioSource> {
    return resolveSource(await this.sources(), selector);
  }

  /** Poll fresh source snapshots until an exact selector becomes available. */
  async waitForSource(selector: SourceSelector, options: {
    timeoutMs?: number; pollIntervalMs?: number; signal?: AbortSignal;
  } = {}): Promise<AudioSource> {
    const pollIntervalMs = options.pollIntervalMs ?? 250;
    if (pollIntervalMs <= 0) throw new RangeError("pollIntervalMs must be positive");
    if (options.timeoutMs !== undefined && options.timeoutMs < 0) {
      throw new RangeError("timeoutMs must not be negative");
    }
    const deadline = options.timeoutMs === undefined ? undefined : Date.now() + options.timeoutMs;
    while (true) {
      if (options.signal?.aborted) throw abortError();
      try {
        return await this.getSource(selector);
      } catch (error) {
        if (!(error instanceof SourceNotFoundError)) throw error;
        const remaining = deadline === undefined ? undefined : deadline - Date.now();
        if (remaining !== undefined && remaining <= 0) {
          throw new SourceNotFoundError(
            `Timed out waiting for audio source ${formatSelector(selector)}`, "source_wait_timeout");
        }
        await delay(remaining === undefined ? pollIntervalMs : Math.min(pollIntervalMs, remaining),
          options.signal);
      }
    }
  }

  async status(): Promise<RuntimeStatus>;
  async status(sessionId: string): Promise<CaptureInfo>;
  async status(sessionId?: string): Promise<RuntimeStatus | CaptureInfo> {
    const response = await this.request(sessionId ? "session_status" : "runtime_status",
      sessionId ? { session_id: sessionId } : {});
    return (sessionId ? response.session : response.status) as RuntimeStatus | CaptureInfo;
  }

  async capture(source: SourceSelector,
                format: AudioFormat = AudioFormats.speech16k()): Promise<CaptureStream> {
    const resolved = await this.getSource(source);
    const response = await this.request("start_capture", { source_id: resolved.id, format });
    const info = response.session as CaptureInfo;
    try { return await CaptureStream.open(this, info, resolved); }
    catch (error) {
      try { await this.cleanupCapture(info.id); } catch { /* bounded cleanup */ }
      throw error;
    }
  }

  async stop(sessionId: string): Promise<CaptureInfo> {
    return (await this.request("stop_capture", { session_id: sessionId })).session as CaptureInfo;
  }

  async events(eventTypes?: string[]): Promise<EventStream> {
    const response = await this.request("subscribe_events",
      eventTypes ? { event_types: eventTypes } : {});
    const subscription = response.subscription as {
      id: string; event_socket_path: string; event_types: string[];
    };
    try { return await EventStream.open(this, subscription); }
    catch (error) {
      try { await this.cleanupSubscription(subscription.id); } catch { }
      throw error;
    }
  }

  /** Own multiple independent captures while preserving a stable label for each frame. */
  session(options: { maxQueueFrames?: number } = {}): MultiSourceSession {
    return new MultiSourceSession(this, options.maxQueueFrames ?? 128);
  }

  private async request(command: string, fields: Record<string, unknown> = {}): Promise<WireResponse> {
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
      if (newline + 1 > 65536) {
        const error = new SonexisError("message_too_large", "Response exceeds 64 KiB");
        this.failPending(error); this.socket?.destroy(); return;
      }
      const line = this.controlBuffer.subarray(0, newline);
      this.controlBuffer = this.controlBuffer.subarray(newline + 1);
      let response: WireResponse;
      try {
        response = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(line)) as WireResponse;
      } catch {
        this.failPending(new SonexisError("malformed_json", "Runtime sent invalid JSON"));
        this.socket?.destroy(); return;
      }
      if ((response as Record<string, unknown>).message_type !== "response"
          || (response as Record<string, unknown>).protocol_version !== 2
          || typeof (response as Record<string, unknown>).response_id !== "string"
          || typeof response.request_id !== "string" || typeof response.ok !== "boolean") {
        this.failPending(new SonexisError("invalid_response", "Runtime sent an invalid response envelope"));
        this.socket?.destroy(); return;
      }
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

  private handleDisconnect(socket: Socket, error: Error): void {
    if (this.socket !== socket) return;
    this.socket = undefined;
    this.handshake = undefined;
    this.controlBuffer = Buffer.alloc(0);
    this.failPending(error);
  }

  async unsubscribe(subscriptionId: string): Promise<void> {
    await this.request("unsubscribe_events", { subscription_id: subscriptionId });
  }

  async cleanupCapture(sessionId: string): Promise<void> {
    await boundedCleanup(this.stop(sessionId));
  }

  async cleanupSubscription(subscriptionId: string): Promise<void> {
    await boundedCleanup(this.unsubscribe(subscriptionId));
  }
}

export class CaptureStream extends EventEmitter implements AsyncIterable<AudioFrame> {
  private buffer = Buffer.alloc(0);
  private queue: AudioFrame[] = [];
  private waiters: Array<{ resolve: (value: IteratorResult<AudioFrame>) => void;
    reject: (error: Error) => void }> = [];
  private ended = false;
  private cleaned = false;
  private terminalError?: Error;
  private closing = false;
  private sawEndOfStream = false;
  private previousSequence?: bigint;

  private constructor(private readonly client: Sonexis, readonly info: CaptureInfo,
                      readonly source: AudioSource, private readonly socket: Socket) { super(); }

  static async open(client: Sonexis, info: CaptureInfo,
                    source: AudioSource): Promise<CaptureStream> {
    const socket = await openSocket(info.data_socket_path);
    const stream = new CaptureStream(client, info, source, socket);
    socket.on("data", (chunk) => stream.consume(chunk));
    socket.on("close", () => {
      const truncated = !stream.closing && !stream.sawEndOfStream
        ? new SonexisError("truncated_pcm_stream", "Audio stream closed without EOS") : undefined;
      if (truncated) stream.emit("streamError", truncated);
      stream.finish(truncated); void stream.cleanupRuntime();
    });
    socket.on("error", (error) => { stream.emit("streamError", error); stream.finish(error); });
    return stream;
  }

  async close(): Promise<void> {
    this.closing = true;
    this.socket.destroy();
    this.finish();
    await this.cleanupRuntime();
  }


  async *[Symbol.asyncIterator](): AsyncIterator<AudioFrame> {
    try {
      while (true) {
        if (this.queue.length) {
          const frame = this.queue.shift()!;
          if (this.queue.length < 32) this.socket.resume();
          yield frame;
        }
        else if (this.ended) {
          if (this.terminalError) throw this.terminalError;
          return;
        }
        else {
          const result = await new Promise<IteratorResult<AudioFrame>>((resolve, reject) =>
            this.waiters.push({ resolve, reject }));
          if (result.done) return;
          yield result.value;
        }
      }
    } finally {
      await this.close();
    }
  }

  private consume(chunk: Buffer): void {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (this.buffer.length >= 64) {
      const payloadSize = this.buffer.readUInt32BE(12);
      if (payloadSize > 512 * 1024) {
        const error = new SonexisError("invalid_pcm", "Payload too large");
        this.emit("streamError", error); this.socket.destroy(); this.finish(error); return;
      }
      if (this.buffer.length < 64 + payloadSize) return;
      const packet = this.buffer.subarray(0, 64 + payloadSize);
      this.buffer = this.buffer.subarray(64 + payloadSize);
      let decoded: DecodedAudioFrame;
      try { decoded = decodeFrame(packet, this.info.stream_id, this.previousSequence); }
      catch (error) {
        this.emit("streamError", error);
        this.socket.destroy();
        this.finish(error instanceof Error ? error : new Error(String(error)));
        return;
      }
      const frame: AudioFrame = {
        ...decoded,
        source: this.source,
        sourceId: this.source.id,
        sourceName: this.source.name,
        bundleIdentifier: this.source.bundle_identifier,
        sessionId: this.info.id,
        receivedAtNs: process.hrtime.bigint(),
      };
      this.previousSequence = frame.sequence;
      if (frame.frameCount === 0) { this.sawEndOfStream = true; this.finish(); return; }
      this.emit("audio", frame);
      const waiter = this.waiters.shift();
      if (waiter) waiter.resolve({ value: frame, done: false });
      else if (this.listenerCount("audio") === 0) {
        this.queue.push(frame);
        if (this.queue.length >= 64) this.socket.pause();
      }
    }
  }

  private finish(error?: Error): void {
    if (this.ended) return;
    this.ended = true;
    this.terminalError = error;
    for (const waiter of this.waiters.splice(0)) {
      if (error) waiter.reject(error);
      else waiter.resolve({ value: undefined, done: true });
    }
  }

  private async cleanupRuntime(): Promise<void> {
    if (this.cleaned) return;
    this.cleaned = true;
    try { await this.client.cleanupCapture(this.info.id); } catch { /* control teardown is authoritative */ }
  }
}

export interface LabeledAudioFrame {
  label: string;
  frame: AudioFrame;
  source: AudioSource;
  sessionId: string;
  streamId: string;
  timestampNs: bigint;
}

interface MultiSourceEnd {
  label: string;
  error?: Error;
}

/** Bounded orchestration for independent, labeled capture streams. */
export class MultiSourceSession {
  readonly maxQueueFrames: number;
  droppedFrames = 0;
  private readonly captures = new Map<string, CaptureStream>();
  private readonly pumps = new Map<string, Promise<void>>();
  private readonly pendingLabels = new Set<string>();
  private readonly queue: LabeledAudioFrame[] = [];
  private readonly ends: MultiSourceEnd[] = [];
  private readonly waiters: Array<() => void> = [];
  private closed = false;
  private iteratorActive = false;
  private closePromise?: Promise<void>;

  constructor(private readonly client: Sonexis, maxQueueFrames = 128) {
    if (!Number.isInteger(maxQueueFrames) || maxQueueFrames < 1) {
      throw new RangeError("maxQueueFrames must be a positive integer");
    }
    this.maxQueueFrames = maxQueueFrames;
  }

  get labels(): readonly string[] {
    return [...this.captures.keys()];
  }

  async add(label: string, source: SourceSelector,
            format: AudioFormat = AudioFormats.speech16k()): Promise<CaptureStream> {
    if (this.closed) throw new SonexisError("session_closed", "Multi-source session is closed");
    if (!label || this.captures.has(label) || this.pendingLabels.has(label)) {
      throw new SonexisError("invalid_label", "Capture label must be non-empty and unique");
    }
    this.pendingLabels.add(label);
    try {
      const capture = await this.client.capture(source, format);
      if (this.closed) {
        await capture.close();
        throw new SonexisError("session_closed", "Multi-source session closed during capture");
      }
      this.captures.set(label, capture);
      const pump = this.pump(label, capture);
      this.pumps.set(label, pump);
      return capture;
    } finally {
      this.pendingLabels.delete(label);
    }
  }

  async remove(label: string): Promise<void> {
    const capture = this.captures.get(label);
    const pump = this.pumps.get(label);
    this.captures.delete(label);
    this.pumps.delete(label);
    if (capture) await capture.close();
    if (pump) await pump;
    this.wake();
  }

  async *frames(): AsyncIterableIterator<LabeledAudioFrame> {
    if (this.iteratorActive) {
      throw new SonexisError("consumer_exists", "Multi-source frames already have a consumer");
    }
    this.iteratorActive = true;
    try {
      while (!this.closed) {
        const frame = this.queue.shift();
        if (frame) {
          yield frame;
          continue;
        }
        const end = this.ends.shift();
        if (end?.error) throw end.error;
        if (!this.captures.size) return;
        await new Promise<void>((resolve) => this.waiters.push(resolve));
      }
    } finally {
      this.iteratorActive = false;
      await this.close();
    }
  }

  close(): Promise<void> {
    this.closePromise ??= this.finishClose();
    return this.closePromise;
  }

  private async finishClose(): Promise<void> {
    this.closed = true;
    this.pendingLabels.clear();
    const captures = [...this.captures.values()];
    this.captures.clear();
    await Promise.allSettled(captures.map((capture) => capture.close()));
    await Promise.allSettled([...this.pumps.values()]);
    this.pumps.clear();
    for (const waiter of this.waiters.splice(0)) waiter();
  }

  private async pump(label: string, capture: CaptureStream): Promise<void> {
    let error: Error | undefined;
    try {
      for await (const frame of capture) {
        if (this.closed || this.captures.get(label) !== capture) break;
        if (this.queue.length >= this.maxQueueFrames) {
          const dropped = this.queue.shift();
          this.droppedFrames += dropped?.frame.frameCount ?? 0;
        }
        this.queue.push({ label, frame, source: frame.source, sessionId: frame.sessionId,
          streamId: frame.streamId, timestampNs: frame.timestampNs });
        this.wake();
      }
    } catch (caught) {
      error = caught instanceof Error ? caught : new Error(String(caught));
    } finally {
      if (this.captures.get(label) === capture) this.captures.delete(label);
      this.pumps.delete(label);
      this.ends.push({ label, error });
      this.wake();
    }
  }

  private wake(): void {
    this.waiters.shift()?.();
  }
}

export class EventStream extends EventEmitter implements AsyncIterable<RuntimeEvent> {
  private buffer = Buffer.alloc(0);
  private queue: RuntimeEvent[] = [];
  private waiters: Array<{ resolve: (value: IteratorResult<RuntimeEvent>) => void;
    reject: (error: Error) => void }> = [];
  private ended = false;
  private cleaned = false;
  private terminalError?: Error;
  private closing = false;

  private constructor(private readonly client: Sonexis, readonly id: string,
                      private readonly socket: Socket) { super(); }
  static async open(client: Sonexis, value: { id: string; event_socket_path: string }): Promise<EventStream> {
    const socket = await openSocket(value.event_socket_path);
    const events = new EventStream(client, value.id, socket);
    socket.on("data", (chunk) => events.consume(chunk));
    socket.on("close", () => {
      const truncated = !events.closing && events.buffer.length > 0
        ? new SonexisError("truncated_event_stream", "Event stream closed mid-message") : undefined;
      if (truncated) events.emit("streamError", truncated);
      events.finish(truncated); void events.cleanupRuntime();
    });
    socket.on("error", (error) => { events.emit("streamError", error); events.finish(error); });
    return events;
  }
  async close(): Promise<void> {
    this.closing = true;
    this.socket.destroy(); this.finish();
    await this.cleanupRuntime();
  }
  async *[Symbol.asyncIterator](): AsyncIterator<RuntimeEvent> {
    try {
      while (true) {
        if (this.queue.length) {
          const event = this.queue.shift()!;
          if (this.queue.length < 128) this.socket.resume();
          yield event;
        }
        else if (this.ended) {
          if (this.terminalError) throw this.terminalError;
          return;
        }
        else {
          const result = await new Promise<IteratorResult<RuntimeEvent>>((resolve, reject) =>
            this.waiters.push({ resolve, reject }));
          if (result.done) return;
          yield result.value;
        }
      }
    } finally {
      await this.close();
    }
  }
  private consume(chunk: Buffer): void {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    if (this.buffer.length > 65536 && this.buffer.indexOf(0x0a) < 0) {
      const error = new SonexisError("message_too_large", "Event exceeds 64 KiB");
      this.emit("streamError", error); this.socket.destroy(); this.finish(error); return;
    }
    let newline: number;
    while ((newline = this.buffer.indexOf(0x0a)) >= 0) {
      let event: RuntimeEvent;
      if (newline + 1 > 65536) {
        const error = new SonexisError("message_too_large", "Event exceeds 64 KiB");
        this.emit("streamError", error); this.socket.destroy(); this.finish(error); return;
      }
      try { event = JSON.parse(this.buffer.subarray(0, newline).toString("utf8")) as RuntimeEvent; }
      catch (error) {
        this.emit("streamError", error);
        this.socket.destroy();
        this.finish(error instanceof Error ? error : new Error(String(error)));
        return;
      }
      this.buffer = this.buffer.subarray(newline + 1);
      this.emit("event", event);
      const waiter = this.waiters.shift();
      if (waiter) waiter.resolve({ value: event, done: false });
      else if (this.listenerCount("event") === 0) {
        this.queue.push(event);
        if (this.queue.length >= 256) this.socket.pause();
      }
    }
  }
  private finish(error?: Error): void {
    if (this.ended) return;
    this.ended = true;
    this.terminalError = error;
    for (const waiter of this.waiters.splice(0)) {
      if (error) waiter.reject(error);
      else waiter.resolve({ value: undefined, done: true });
    }
  }
  private async cleanupRuntime(): Promise<void> {
    if (this.cleaned) return;
    this.cleaned = true;
    try { await this.client.cleanupSubscription(this.id); } catch { }
  }
}

export function decodeFrame(packet: Buffer, expectedStreamId: string,
                            previousSequence?: bigint): DecodedAudioFrame {
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

function abortError(): SonexisError {
  return new SonexisError("cancelled", "Operation was cancelled");
}

function delay(milliseconds: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(abortError());
      return;
    }
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, milliseconds);
    const onAbort = (): void => {
      clearTimeout(timer);
      reject(abortError());
    };
    signal?.addEventListener("abort", onAbort, { once: true });
    if (signal?.aborted) onAbort();
  });
}

async function boundedCleanup(promise: Promise<unknown>, timeoutMs = 1000): Promise<void> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    await Promise.race([
      promise,
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new SonexisError(
          "cleanup_timeout", "Runtime cleanup timed out", true)), timeoutMs);
      }),
    ]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}
