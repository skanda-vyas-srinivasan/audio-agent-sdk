import { EventEmitter } from "node:events";
import { existsSync } from "node:fs";
import { lstat } from "node:fs/promises";
import { tmpdir } from "node:os";
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
  openAIRealtimeOutput: (): AudioFormat => audioFormat(24000, 1),
  geminiLive: (): AudioFormat => audioFormat(16000, 1),
  geminiLiveOutput: (): AudioFormat => audioFormat(24000, 1),
  pcm48kMono: (): AudioFormat => audioFormat(48000, 1),
  pcm48kStereo: (): AudioFormat => audioFormat(48000, 2),
});

/** Every event understood by this SDK version. Supplying the explicit list
 * opts v0.4 clients into output events while preserving Runtime v0.3 defaults. */
export const RuntimeEventTypes = Object.freeze([
  "source_added", "source_removed", "source_updated", "capture_started",
  "capture_stopped", "capture_failed", "client_warning", "device_changed",
  "runtime_warning", "runtime_shutting_down", "output_started", "output_stopped",
  "output_cancelled", "output_failed", "output_underrun", "output_overrun",
  "output_dropped", "output_destination_changed", "output_destination_added",
  "output_destination_removed", "output_destination_updated", "output_default_changed",
] as const);

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
export type OutputDestinationKind = "playback" | "virtual_input";
export interface AudioOutputDestination {
  id: string;
  kind: OutputDestinationKind;
  name: string;
  is_available: boolean;
  is_default: boolean;
  follows_system_default: boolean;
  active_device_id?: string;
  active_device_name?: string;
  native_format?: AudioFormat;
  supported_formats: AudioFormat[];
}
export interface OutputMetrics {
  packets_received: number;
  input_frames_received: number;
  input_bytes_received: number;
  device_frames_enqueued: number;
  device_frames_rendered: number;
  dropped_frames: number;
  flushed_frames: number;
  late_frames: number;
  underrun_frames: number;
  underrun_events: number;
  overrun_events: number;
  queue_depth_frames: number;
  queue_high_water_frames: number;
  buffered_milliseconds: number;
  target_buffer_milliseconds: number;
  conversion_batches: number;
  conversion_nanoseconds: number;
  route_changes: number;
  producer_connected: boolean;
  device_sample_rate?: number;
  device_channel_count?: number;
  estimated_output_latency_milliseconds?: number;
  uptime_nanoseconds?: number;
}
export type OutputSessionState =
  "starting" | "ready" | "draining" | "stopped" | "cancelled" | "failed";
export interface OutputInfo {
  id: string;
  stream_id: string;
  destination_id: string;
  state: OutputSessionState;
  format: AudioFormat;
  data_socket_path: string;
  started_at_nanoseconds: number;
  target_buffer_milliseconds: number;
  metrics: OutputMetrics;
  error?: RuntimeErrorInfo;
}
export interface OutputOptions {
  destination?: string | AudioOutputDestination;
  format?: AudioFormat;
  targetBufferMilliseconds?: number;
}
export type OutputDestinationSelector = string | AudioOutputDestination;
export interface OutputDestinationFilter {
  /** Case-insensitive substring matched against ID, name, and active device name. */
  query?: string;
  destinationId?: string;
  name?: string;
  kind?: OutputDestinationKind;
  availableOnly?: boolean;
}
export interface OutputWriteOptions {
  timestampNs?: bigint | number;
  discontinuity?: boolean;
  signal?: AbortSignal;
}
export interface DuplexOptions {
  inputFormat?: AudioFormat;
  output?: OutputOptions;
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
  endOfStream: boolean;
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

export interface AudioActivity {
  rms: number;
  peak: number;
  active: boolean;
}

export interface ActivityDetectionOptions {
  activityStartThreshold?: number;
  activityEndThreshold?: number;
  minimumActivityMs?: number;
  silenceDurationMs?: number;
}

export interface VoiceActivityDetector {
  isSpeech(frame: AudioFrame): boolean;
}

export interface ActivityEvent {
  type: "activity_started" | "activity_ended";
  timestampNs: bigint;
  sequence: bigint;
  sourceId: string;
  sessionId: string;
  streamId: string;
}

/** Measure signal energy. Active means non-silent signal, not necessarily speech. */
export function measureActivity(frame: AudioFrame, threshold = 0.01): AudioActivity {
  if (!Number.isFinite(threshold) || threshold < 0 || threshold > 1) {
    throw new RangeError("threshold must be finite and between zero and one");
  }
  let sum = 0;
  let peak = 0;
  const samples = frame.frameCount * frame.format.channel_count;
  if (samples < 1 || frame.data.length === 0) return { rms: 0, peak: 0, active: false };
  for (let index = 0; index < samples; index++) {
    const value = frame.format.sample_format === "pcm_s16le"
      ? frame.data.readInt16LE(index * 2) / 32768
      : frame.data.readFloatLE(index * 4);
    const finite = Number.isFinite(value) ? value : 0;
    peak = Math.max(peak, Math.abs(finite));
    sum += finite * finite;
  }
  const rms = Math.sqrt(sum / samples);
  return { rms, peak, active: rms >= threshold };
}

/** Consumer-side hysteresis/debounce for provider-neutral signal activity. */
export class AudioActivityDetector {
  readonly options: Required<ActivityDetectionOptions>;
  private activityState: "idle" | "starting" | "active" = "idle";
  private candidateMs = 0;
  private silenceMs = 0;
  private streamId?: string;

  constructor(options: ActivityDetectionOptions = {},
              readonly voiceActivityDetector?: VoiceActivityDetector) {
    this.options = {
      activityStartThreshold: options.activityStartThreshold ?? 0.015,
      activityEndThreshold: options.activityEndThreshold ?? 0.008,
      minimumActivityMs: options.minimumActivityMs ?? 250,
      silenceDurationMs: options.silenceDurationMs ?? 1200,
    };
    const o = this.options;
    if (![o.activityStartThreshold, o.activityEndThreshold,
      o.minimumActivityMs, o.silenceDurationMs].every(Number.isFinite)
      || o.activityEndThreshold < 0
      || o.activityEndThreshold > o.activityStartThreshold
      || o.activityStartThreshold > 1
      || o.minimumActivityMs <= 0 || o.minimumActivityMs > 5000
      || o.silenceDurationMs <= 0 || o.silenceDurationMs > 30000) {
      throw new RangeError("invalid activity detection options");
    }
  }

  get active(): boolean { return this.activityState === "active"; }
  get state(): "idle" | "starting" | "active" { return this.activityState; }

  reset(): void {
    this.activityState = "idle";
    this.candidateMs = 0;
    this.silenceMs = 0;
  }

  observe(frame: AudioFrame): ActivityEvent | undefined {
    if (this.streamId === undefined) this.streamId = frame.streamId;
    else if (this.streamId !== frame.streamId) {
      throw new SonexisError("activity_stream_mismatch",
        "Use one AudioActivityDetector per Sonexis stream");
    }
    if (frame.discontinuity) this.reset();
    const durationMs = frame.frameCount * 1000 / frame.format.sample_rate;
    const threshold = this.active
      ? this.options.activityEndThreshold : this.options.activityStartThreshold;
    const frameActive = this.voiceActivityDetector !== undefined
      ? Boolean(this.voiceActivityDetector.isSpeech(frame))
      : measureActivity(frame, threshold).active;
    if (!this.active) {
      if (!frameActive) { this.reset(); return undefined; }
      this.activityState = "starting";
      this.candidateMs += durationMs;
      if (this.candidateMs < this.options.minimumActivityMs) return undefined;
      this.activityState = "active";
      this.candidateMs = 0;
      this.silenceMs = 0;
      return this.event("activity_started", frame);
    }
    if (frameActive) { this.silenceMs = 0; return undefined; }
    this.silenceMs += durationMs;
    if (this.silenceMs < this.options.silenceDurationMs) return undefined;
    this.reset();
    return this.event("activity_ended", frame);
  }

  private event(type: ActivityEvent["type"], frame: AudioFrame): ActivityEvent {
    return { type, timestampNs: frame.timestampNs, sequence: frame.sequence,
      sourceId: frame.sourceId, sessionId: frame.sessionId, streamId: frame.streamId };
  }
}
export interface RuntimeEvent {
  protocol_version: 2;
  event_id: string;
  type: string;
  timestamp_nanoseconds: number;
  source_id?: string;
  session_id?: string;
  stream_id?: string;
  output_destination_id?: string;
  message?: string;
  dropped_frames?: number;
  event_sequence?: number;
  dropped_events_before?: number;
  source?: AudioSource;
  session?: CaptureInfo;
  output_session?: OutputInfo;
  output_destination?: AudioOutputDestination;
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
  active_output_sessions?: number;
  total_output_sessions_started?: number;
  total_output_frames_received?: number;
  total_output_frames_rendered?: number;
  total_output_frames_dropped?: number;
  total_output_bytes_received?: number;
  total_capture_ring_dropped_frames?: number;
  total_capture_delivery_dropped_frames?: number;
  total_capture_queue_dropped_frames?: number;
  total_capture_no_subscriber_frames?: number;
  connected_capture_subscribers?: number;
  retained_capture_sessions?: number;
  reserved_capture_starts?: number;
  total_output_frames_lost?: number;
  total_output_frames_flushed?: number;
  total_output_frames_late?: number;
  total_output_underrun_frames?: number;
  total_output_underrun_events?: number;
  total_output_overrun_events?: number;
  total_output_route_changes?: number;
  total_output_conversion_batches?: number;
  total_output_conversion_nanoseconds?: number;
  connected_output_producers?: number;
  retained_output_sessions?: number;
  reserved_output_starts?: number;
  total_control_clients_accepted?: number;
  total_control_clients_disconnected?: number;
  total_control_clients_rejected?: number;
  total_control_requests?: number;
  total_control_errors?: number;
  total_malformed_control_messages?: number;
  total_control_handshake_timeouts?: number;
  total_source_monitor_failures?: number;
  total_destination_monitor_failures?: number;
  source_monitor_consecutive_failures?: number;
  destination_monitor_consecutive_failures?: number;
  source_monitor_recoveries?: number;
  destination_monitor_recoveries?: number;
  source_monitor_last_success_nanoseconds?: number;
  destination_monitor_last_success_nanoseconds?: number;
  resident_memory_bytes?: number;
  peak_resident_memory_bytes?: number;
  open_file_descriptors?: number;
  thread_count?: number;
  /** Exact decimal mirrors for UInt64 counters that may exceed Number.MAX_SAFE_INTEGER. */
  exact_counters?: Record<string, string>;
}
export interface Handshake {
  protocol_version: 2;
  runtime_version: string;
  runtime_instance_id: string;
  capabilities: string[];
  supported_formats: AudioFormat[];
  supported_output_formats?: AudioFormat[];
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

export class OutputDestinationNotFoundError extends SonexisError {
  constructor(message: string, code = "output_destination_not_found",
              details: Record<string, string> = {}) {
    super(code, message, true, details);
    this.name = "OutputDestinationNotFoundError";
  }
}

export class AmbiguousOutputDestinationError extends SonexisError {
  constructor(message: string, details: Record<string, string>) {
    super("ambiguous_output_destination", message, false, details);
    this.name = "AmbiguousOutputDestinationError";
  }
}

export class CaptureFailedError extends SonexisError {
  constructor(message: string, code = "capture_failed", retryable = false,
              details: Record<string, string> = {}) {
    super(code, message, retryable, details);
    this.name = "CaptureFailedError";
  }
}

export class OutputFailedError extends SonexisError {
  constructor(message: string, code = "output_failed", retryable = false,
              details: Record<string, string> = {}) {
    super(code, message, retryable, details);
    this.name = "OutputFailedError";
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

/** Filter an already-fetched output-destination snapshot. */
export function filterOutputDestinations(destinations: readonly AudioOutputDestination[],
                                         filter: OutputDestinationFilter = {})
  : AudioOutputDestination[] {
  const availableOnly = filter.availableOnly ?? true;
  const query = filter.query?.toLowerCase();
  return destinations.filter((destination) => {
    if (availableOnly && !destination.is_available) return false;
    if (filter.destinationId !== undefined && destination.id !== filter.destinationId) return false;
    if (filter.name !== undefined && destination.name !== filter.name) return false;
    if (filter.kind !== undefined && destination.kind !== filter.kind) return false;
    if (query !== undefined && ![destination.id, destination.name,
      destination.active_device_name ?? ""].some((value) => value.toLowerCase().includes(query))) {
      return false;
    }
    return true;
  });
}

/** Resolve an exact ID, exact name, kind alias, or typed destination uniquely. */
export function resolveOutputDestination(destinations: readonly AudioOutputDestination[],
                                         selector?: OutputDestinationSelector,
                                         kind?: OutputDestinationKind): AudioOutputDestination {
  const available = destinations.filter((destination) => destination.is_available);
  let candidates: AudioOutputDestination[];
  if (selector === undefined) {
    candidates = available;
  } else if (typeof selector !== "string") {
    candidates = available.filter((destination) => destination.id === selector.id);
  } else {
    candidates = available.filter((destination) => destination.id === selector);
    if (!candidates.length) candidates = available.filter((destination) => destination.name === selector);
    if (!candidates.length) {
      const folded = selector.toLowerCase();
      candidates = available.filter((destination) => destination.name.toLowerCase() === folded);
    }
    if (!candidates.length && ["loopback", "virtual_input"].includes(selector.toLowerCase())) {
      candidates = available.filter((destination) => destination.kind === "virtual_input");
    }
  }
  if (kind !== undefined) candidates = candidates.filter((destination) => destination.kind === kind);
  if (!candidates.length) {
    throw new OutputDestinationNotFoundError(
      `No available output destination matches ${JSON.stringify(selector)}`);
  }
  if (candidates.length > 1) {
    const details = Object.fromEntries(candidates.map((destination, index) =>
      [`candidate_${index + 1}`, destination.id]));
    throw new AmbiguousOutputDestinationError(
      `Output destination selector ${JSON.stringify(selector)} is ambiguous`, details);
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

async function openSocket(path: string): Promise<Socket> {
  const slash = path.lastIndexOf("/");
  const directory = slash > 0 ? path.slice(0, slash) : ".";
  const uid = typeof process.getuid === "function" ? process.getuid() : undefined;
  let directoryStatus;
  let before;
  try {
    directoryStatus = await lstat(directory);
    before = await lstat(path);
  } catch (error) {
    const value = error as NodeJS.ErrnoException;
    throw new SonexisError("runtime_unavailable",
      `Cannot connect to Sonexis Runtime at ${path}. Start the local sonexis-runtime process `
        + `or verify SONEXIS_RUNTIME_SOCKET. (${value.code ?? value.message})`, true,
      { socket_path: path, cause_code: value.code ?? "socket_error" });
  }
  if (!directoryStatus.isDirectory() || uid === undefined || directoryStatus.uid !== uid
      || (directoryStatus.mode & 0o022) !== 0 || !before.isSocket() || before.uid !== uid) {
    throw new SonexisError("untrusted_socket_path",
      "Sonexis sockets must be owned by the current user in a private directory");
  }
  const socket = await new Promise<Socket>((resolve, reject) => {
    const socket = createConnection(path);
    socket.once("connect", () => resolve(socket));
    socket.once("error", (error: NodeJS.ErrnoException) => reject(new SonexisError(
      "runtime_unavailable",
      `Cannot connect to Sonexis Runtime at ${path}. Start the local sonexis-runtime process `
        + `or verify SONEXIS_RUNTIME_SOCKET. (${error.code ?? error.message})`,
      true,
      { socket_path: path, cause_code: error.code ?? "socket_error" },
    )));
  });
  try {
    const after = await lstat(path);
    if (!after.isSocket() || after.uid !== uid
        || before.dev !== after.dev || before.ino !== after.ino) {
      throw new SonexisError("untrusted_socket_path",
        "Sonexis socket changed while connecting", true);
    }
    return socket;
  } catch (error) {
    socket.destroy();
    throw error;
  }
}

function defaultSocketPath(): string {
  const configured = process.env.SONEXIS_RUNTIME_SOCKET;
  if (configured) return configured;
  if (typeof process.getuid !== "function") {
    throw new SonexisError("unsupported_platform", "Sonexis Runtime requires macOS/Unix sockets");
  }
  const current = `${tmpdir().replace(/\/$/, "")}/sx-${process.getuid()}/control.sock`;
  const legacy = `/tmp/sonexis-runtime-${process.getuid()}/control.sock`;
  return !existsSync(current) && existsSync(legacy) ? legacy : current;
}

const MutatingControlCommands = new Set([
  "start_capture", "subscribe_events", "start_output", "flush_output",
]);

export class Sonexis extends EventEmitter {
  readonly socketPath: string;
  handshake?: Handshake;
  private socket?: Socket;
  private controlBuffer = Buffer.alloc(0);
  private connectPromise?: Promise<Handshake>;
  private connectionGeneration = 0;
  private readonly discardedRequestIds = new Set<string>();
  private readonly pending = new Map<string, {
    resolve: (value: WireResponse) => void; reject: (error: Error) => void;
  }>();
  private readonly captures = new Set<CaptureStream>();
  private readonly eventStreams = new Set<EventStream>();
  private readonly outputs = new Set<AudioOutput>();

  constructor(socketPath = defaultSocketPath()) {
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
    this.connectPromise ??= this.finishConnect();
    try { return await this.connectPromise; }
    finally { this.connectPromise = undefined; }
  }

  private async finishConnect(): Promise<Handshake> {
    const generation = this.connectionGeneration;
    const socket = await openSocket(this.socketPath);
    if (generation !== this.connectionGeneration) {
      socket.destroy();
      throw new SonexisError("connection_cancelled", "Connection was closed while opening", true);
    }
    this.socket = socket;
    socket.on("data", (chunk) => this.consumeControl(chunk));
    socket.on("close", () => this.handleDisconnect(socket, new SonexisError(
      "disconnected", "Runtime closed the control socket", true)));
    socket.on("error", (error) => this.handleDisconnect(socket, error));
    try {
      const response = await this.request("hello", {
        supported_protocol_versions: [2], client_name: "sonexis-typescript", client_version: "0.9.0",
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
    this.connectionGeneration++;
    await Promise.allSettled([
      ...[...this.captures].map((capture) => capture.close()),
      ...[...this.eventStreams].map((events) => events.close()),
      ...[...this.outputs].map((output) => output.cancel()),
    ]);
    const socket = this.socket;
    this.socket = undefined;
    this.handshake = undefined;
    this.controlBuffer = Buffer.alloc(0);
    this.discardedRequestIds.clear();
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
    if (!Number.isFinite(pollIntervalMs) || pollIntervalMs <= 0) {
      throw new RangeError("pollIntervalMs must be finite and positive");
    }
    if (options.timeoutMs !== undefined
        && (!Number.isFinite(options.timeoutMs) || options.timeoutMs < 0)) {
      throw new RangeError("timeoutMs must be finite and nonnegative");
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

  /** Enumerate Runtime-owned destinations for client-provided PCM. */
  async outputDestinations(): Promise<AudioOutputDestination[]> {
    this.requireOutputCapability();
    const response = await this.request("list_output_destinations");
    if (!Array.isArray(response.output_destinations)) {
      throw new SonexisError(
        "invalid_output_destinations", "Runtime omitted output destinations");
    }
    return response.output_destinations.map(parseOutputDestination);
  }

  async findOutputDestinations(filter: OutputDestinationFilter = {})
    : Promise<AudioOutputDestination[]> {
    return filterOutputDestinations(await this.outputDestinations(), filter);
  }

  async getOutputDestination(selector: OutputDestinationSelector | undefined = "default",
                             kind?: OutputDestinationKind): Promise<AudioOutputDestination> {
    return resolveOutputDestination(await this.outputDestinations(), selector, kind);
  }

  async waitForOutputDestination(selector?: OutputDestinationSelector,
                                 options: { kind?: OutputDestinationKind; timeoutMs?: number;
                                   pollIntervalMs?: number; signal?: AbortSignal } = {})
    : Promise<AudioOutputDestination> {
    const pollIntervalMs = options.pollIntervalMs ?? 250;
    if (!Number.isFinite(pollIntervalMs) || pollIntervalMs <= 0) {
      throw new RangeError("pollIntervalMs must be finite and positive");
    }
    if (options.timeoutMs !== undefined
        && (!Number.isFinite(options.timeoutMs) || options.timeoutMs < 0)) {
      throw new RangeError("timeoutMs must be finite and nonnegative");
    }
    const deadline = options.timeoutMs === undefined ? undefined : Date.now() + options.timeoutMs;
    while (true) {
      if (options.signal?.aborted) throw abortError();
      try {
        const destinations = await this.outputDestinations();
        if (options.signal?.aborted) throw abortError();
        return resolveOutputDestination(destinations, selector, options.kind);
      }
      catch (error) {
        if (!(error instanceof OutputDestinationNotFoundError)) throw error;
        const remaining = deadline === undefined ? undefined : deadline - Date.now();
        if (remaining !== undefined && remaining <= 0) {
          throw new OutputDestinationNotFoundError(
            `Timed out waiting for output destination ${JSON.stringify(selector)}`,
            "output_destination_wait_timeout");
        }
        await delay(remaining === undefined ? pollIntervalMs : Math.min(pollIntervalMs, remaining),
          options.signal);
      }
    }
  }

  /** Create and attach a bounded client-to-Runtime PCM output stream. */
  async createOutput(options: OutputOptions = {}): Promise<AudioOutput> {
    this.requireOutputCapability();
    const targetBufferMilliseconds = options.targetBufferMilliseconds ?? 60;
    if (!Number.isInteger(targetBufferMilliseconds)
        || targetBufferMilliseconds < 20 || targetBufferMilliseconds > 250) {
      throw new RangeError("targetBufferMilliseconds must be an integer between 20 and 250");
    }
    const destination = await this.getOutputDestination(options.destination ?? "default");
    const format = options.format ?? AudioFormats.openAIRealtimeOutput();
    if (destination.supported_formats.length
        && !destination.supported_formats.some((candidate) => sameAudioFormat(candidate, format))) {
      throw new SonexisError("unsupported_output_format",
        `${destination.name} does not advertise support for the requested format`, false,
        { destination_id: destination.id });
    }
    const response = await this.request("start_output", {
      destination_id: destination.id,
      format,
      target_buffer_milliseconds: targetBufferMilliseconds,
    });
    let info: OutputInfo;
    try { info = parseOutputInfo(response.output_session); }
    catch (error) {
      throw new SonexisError("invalid_output_session", "Runtime sent a malformed output session",
        false, { cause: error instanceof Error ? error.message : String(error) });
    }
    try {
      const output = await AudioOutput.open(this, info, destination);
      this.outputs.add(output);
      return output;
    } catch (error) {
      await this.cleanupOutput(info.id);
      throw error;
    }
  }

  /** Convenience alias for createOutput(). */
  playback(options: OutputOptions = {}): Promise<AudioOutput> {
    return this.createOutput(options);
  }

  /** Compose one independent capture and one output without imposing agent policy. */
  duplex(source: SourceSelector, options: DuplexOptions = {}): Promise<DuplexSession> {
    return DuplexSession.open(this, source, options);
  }

  async outputStatus(outputSessionId: string): Promise<OutputInfo> {
    this.requireOutputCapability();
    const response = await this.request("output_status", { output_session_id: outputSessionId });
    try { return parseOutputInfo(response.output_session); }
    catch (error) {
      throw new SonexisError("invalid_output_session", "Runtime sent a malformed output session",
        false, { cause: error instanceof Error ? error.message : String(error) });
    }
  }

  async stopOutput(outputSessionId: string): Promise<OutputInfo> {
    this.requireOutputCapability();
    const response = await this.request("stop_output", { output_session_id: outputSessionId });
    try { return parseOutputInfo(response.output_session); }
    catch (error) {
      throw new SonexisError("invalid_output_session", "Runtime sent a malformed output session",
        false, { cause: error instanceof Error ? error.message : String(error) });
    }
  }

  async events(eventTypes?: string[]): Promise<EventStream> {
    const response = await this.request("subscribe_events",
      { event_types: eventTypes ?? [...RuntimeEventTypes] });
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
  session(options: { maxQueueFrames?: number; failFast?: boolean } = {}): MultiSourceSession {
    return new MultiSourceSession(this, options.maxQueueFrames ?? 128,
      options.failFast ?? true);
  }

  private async request(command: string, fields: Record<string, unknown> = {},
                        timeoutMs = 10_000): Promise<WireResponse> {
    if (!this.socket) throw new SonexisError("not_connected", "Connect first");
    const requestId = randomUUID();
    const request = { message_type: "request", protocol_version: 2,
      request_id: requestId, command, ...fields };
    const payload = Buffer.from(`${JSON.stringify(request)}\n`);
    if (payload.length > 65536) throw new SonexisError("message_too_large", "Request exceeds 64 KiB");
    const response = new Promise<WireResponse>((resolve, reject) => {
      const timer = setTimeout(() => {
        if (!this.pending.delete(requestId)) return;
        this.discardedRequestIds.add(requestId);
        if (this.discardedRequestIds.size > 1024) {
          const oldest = this.discardedRequestIds.values().next().value as string | undefined;
          if (oldest !== undefined) this.discardedRequestIds.delete(oldest);
        }
        reject(new SonexisError("request_timeout", `${command} timed out`, true));
        // A timed-out mutating request may have completed remotely. Protocol v2
        // reconciles that ambiguity by closing the owner socket, which causes
        // Runtime to stop all resources created by this client.
        if (MutatingControlCommands.has(command)) this.socket?.destroy();
      }, timeoutMs);
      this.pending.set(requestId, {
        resolve: (value) => { clearTimeout(timer); resolve(value); },
        reject: (error) => { clearTimeout(timer); reject(error); },
      });
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
      if (!pending && this.discardedRequestIds.delete(response.request_id)) continue;
      if (!pending) {
        this.failPending(new SonexisError("unknown_response", "Unknown response ID"));
        this.socket?.destroy();
        return;
      }
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
    this.discardedRequestIds.clear();
    this.failPending(error);
    for (const capture of [...this.captures]) capture.runtimeDisconnected(error);
    for (const events of [...this.eventStreams]) events.runtimeDisconnected(error);
    for (const output of [...this.outputs]) output.runtimeDisconnected(error);
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

  async flushOutput(outputSessionId: string): Promise<OutputInfo> {
    this.requireOutputCapability();
    const response = await this.request("flush_output", { output_session_id: outputSessionId });
    try { return parseOutputInfo(response.output_session); }
    catch (error) {
      throw new SonexisError("invalid_output_session", "Runtime sent a malformed output session",
        false, { cause: error instanceof Error ? error.message : String(error) });
    }
  }

  async cleanupOutput(outputSessionId: string): Promise<void> {
    if (!this.socket) return;
    await boundedCleanup(this.stopOutput(outputSessionId));
  }

  untrackOutput(output: AudioOutput): void {
    this.outputs.delete(output);
  }

  trackCapture(capture: CaptureStream): void { this.captures.add(capture); }
  untrackCapture(capture: CaptureStream): void { this.captures.delete(capture); }
  trackEventStream(events: EventStream): void { this.eventStreams.add(events); }
  untrackEventStream(events: EventStream): void { this.eventStreams.delete(events); }

  private requireOutputCapability(): void {
    if (!this.handshake) throw new SonexisError("not_connected", "Connect first");
    if (!this.handshake.capabilities.includes("output_sessions")) {
      throw new SonexisError("unsupported_capability",
        "This Runtime does not support client-to-Runtime audio output; Runtime v0.4 is required");
    }
  }
}

/** Runtime-owned, bounded client-to-device audio stream. */
export class AudioOutput extends EventEmitter {
  private static readonly MAX_PACKET_MILLISECONDS = 200;
  private socket: Socket;
  private sequence = 0n;
  private nextTimestampNs = 0n;
  private operationTail: Promise<void> = Promise.resolve();
  private closePromise?: Promise<void>;
  private closing = false;
  private resolvingStreamFailure = false;
  private terminalError?: Error;
  private rotatingSocket?: Socket;

  private constructor(private readonly client: Sonexis, public info: OutputInfo,
                      private currentDestination: AudioOutputDestination, socket: Socket) {
    super();
    this.socket = socket;
    this.observeSocket(socket);
  }

  static async open(client: Sonexis, info: OutputInfo,
                    destination: AudioOutputDestination): Promise<AudioOutput> {
    uuidToBytes(info.stream_id);
    return new AudioOutput(client, info, destination,
      await openSocket(info.data_socket_path));
  }

  get closed(): boolean { return this.closing; }
  get metrics(): OutputMetrics { return this.info.metrics; }
  get destination(): AudioOutputDestination { return this.currentDestination; }

  /**
   * Write whole interleaved PCM frames. Large writes are split into packets no
   * longer than 200 ms, and each socket `drain` is awaited before proceeding.
   */
  async write(data: Buffer | Uint8Array, options: OutputWriteOptions = {}): Promise<void> {
    if (this.closing) throw new SonexisError("output_closed", "Audio output is already closed");
    if (options.signal?.aborted) throw abortError();
    const bytes = Buffer.isBuffer(data)
      ? data : Buffer.from(data.buffer, data.byteOffset, data.byteLength);
    if (!bytes.length) return;
    const frameSize = bytesPerFrame(this.info.format);
    if (bytes.length % frameSize !== 0) {
      throw new RangeError("Audio payload must contain whole interleaved sample frames");
    }
    if (bytes.length / frameSize < Math.max(1, Math.floor(this.info.format.sample_rate / 1000))) {
      throw new RangeError("Audio writes must contain at least one millisecond of PCM");
    }
    const explicitTimestamp = options.timestampNs === undefined
      ? undefined : timestampToBigInt(options.timestampNs);

    try {
      await this.runExclusive(async () => {
        if (this.closing) {
          throw new SonexisError("output_closed", "Audio output is already closed");
        }
        const format = this.info.format;
        const maximumFrames = Math.max(1,
          Math.floor(format.sample_rate * AudioOutput.MAX_PACKET_MILLISECONDS / 1000));
        const maximumBytes = maximumFrames * frameSize;
        let offset = 0;
        let framesWritten = 0n;
        const firstTimestamp = explicitTimestamp ?? this.nextTimestampNs;
        while (offset < bytes.length) {
          if (options.signal?.aborted) throw abortError();
          const byteCount = Math.min(maximumBytes, bytes.length - offset);
          const frameCount = byteCount / frameSize;
          const timestampNs = firstTimestamp
            + framesWritten * 1_000_000_000n / BigInt(format.sample_rate);
          const packet = encodeOutputFrame({
            streamId: this.info.stream_id,
            sequence: this.sequence,
            timestampNs,
            format,
            frameCount,
            data: bytes.subarray(offset, offset + byteCount),
            discontinuity: !!options.discontinuity && offset === 0,
          });
          await writeWithBackpressure(this.socket, packet, options.signal);
          this.sequence += 1n;
          framesWritten += BigInt(frameCount);
          this.nextTimestampNs = timestampNs
            + BigInt(frameCount) * 1_000_000_000n / BigInt(format.sample_rate);
          offset += byteCount;
        }
      }, options.signal);
    } catch (error) {
      if (error instanceof RangeError || (error instanceof SonexisError
          && (error.code === "output_closed" || error.code === "cancelled"))) {
        if (error instanceof SonexisError && error.code === "cancelled") await this.cancel();
        throw error;
      }
      const failure = error instanceof SonexisError ? error
        : await this.resolveStreamFailure(error);
      this.emit("outputError", failure);
      await this.cancel();
      throw failure;
    }
  }

  /** Refresh this output session's Runtime state and metrics. */
  async refresh(): Promise<OutputInfo> {
    this.info = await this.client.outputStatus(this.info.id);
    if (this.info.state === "failed") throw outputFailure(this.info);
    this.currentDestination = await this.client.getOutputDestination(this.info.destination_id);
    return this.info;
  }

  /** Discard queued audio and reconnect to the fresh stream epoch. */
  async flush(): Promise<OutputInfo> {
    if (this.closing) throw new SonexisError("output_closed", "Audio output is already closed");
    return this.runExclusive(async () => {
      if (this.closing) throw new SonexisError("output_closed", "Audio output is already closed");
      const oldSocket = this.socket;
      this.rotatingSocket = oldSocket;
      let info: OutputInfo;
      try {
        info = await this.client.flushOutput(this.info.id);
      } catch (error) {
        this.rotatingSocket = undefined;
        throw error;
      }
      try {
        const socket = await openSocket(info.data_socket_path);
        this.info = info;
        this.socket = socket;
        this.sequence = 0n;
        this.nextTimestampNs = 0n;
        this.observeSocket(socket);
        oldSocket.destroy();
        this.rotatingSocket = undefined;
        this.emit("flushed", info);
        return info;
      } catch (error) {
        this.rotatingSocket = undefined;
        oldSocket.destroy();
        this.closing = true;
        await this.client.cleanupOutput(info.id);
        this.client.untrackOutput(this);
        throw error;
      }
    });
  }

  /** Barge-in primitive: discard Runtime-buffered audio and stop immediately. */
  cancel(): Promise<void> {
    return this.close({ drain: false });
  }

  /** Send EOS and drain by default, or stop immediately with `drain: false`. */
  close(options: { drain?: boolean } = {}): Promise<void> {
    if (!this.closePromise) {
      const drain = options.drain ?? true;
      this.closing = true;
      if (!drain) this.socket.destroy();
      this.closePromise = this.finishClose(drain);
    }
    return this.closePromise;
  }

  runtimeDisconnected(error: Error): void {
    if (this.closing) return;
    this.closing = true;
    this.terminalError = error;
    this.socket.destroy();
    this.client.untrackOutput(this);
    this.emit("outputError", error);
    this.closePromise = Promise.resolve();
  }

  private async finishClose(drain: boolean): Promise<void> {
    try {
      if (drain) {
        await this.runExclusive(async () => {
          const packet = encodeOutputFrame({
            streamId: this.info.stream_id,
            sequence: this.sequence,
            timestampNs: this.nextTimestampNs,
            format: this.info.format,
            frameCount: 0,
            data: Buffer.alloc(0),
            endOfStream: true,
          });
          await writeWithBackpressure(this.socket, packet);
          this.socket.end();
        });
        await this.waitForRuntimeDrain();
      } else {
        await this.runExclusive(async () => undefined);
        await this.client.cleanupOutput(this.info.id);
      }
    } catch (error) {
      if (drain) await this.client.cleanupOutput(this.info.id);
      if (!this.terminalError) {
        this.terminalError = error instanceof Error ? error : new Error(String(error));
      }
      throw this.terminalError;
    } finally {
      this.socket.destroy();
      this.client.untrackOutput(this);
      this.emit("closed", this.info);
    }
  }

  private async waitForRuntimeDrain(): Promise<void> {
    const deadline = Date.now() + 3000;
    while (Date.now() < deadline) {
      let info: OutputInfo;
      try { info = await this.client.outputStatus(this.info.id); }
      catch (error) {
        if (error instanceof SonexisError
            && ["session_not_found", "output_not_found", "output_session_not_found"]
              .includes(error.code)) return;
        throw error;
      }
      this.info = info;
      if (info.state === "failed") throw outputFailure(info);
      if (info.state === "stopped" || info.state === "cancelled") return;
      await delay(20);
    }
    await this.client.cleanupOutput(this.info.id);
  }

  private observeSocket(socket: Socket): void {
    socket.on("error", (error) => {
      if (this.socket !== socket || this.rotatingSocket === socket || this.closing) return;
      this.terminalError = error;
    });
    socket.on("close", () => {
      if (this.socket !== socket || this.rotatingSocket === socket || this.closing) return;
      void this.handleUnexpectedStreamClose(this.terminalError);
    });
  }

  private async handleUnexpectedStreamClose(transportError?: Error): Promise<void> {
    if (this.closing || this.resolvingStreamFailure) return;
    this.resolvingStreamFailure = true;
    const error = await this.resolveStreamFailure(transportError);
    if (this.closing) return;
    this.closing = true;
    this.terminalError = error;
    this.client.untrackOutput(this);
    this.emit("outputError", error);
    this.emit("closed", this.info);
    this.closePromise = Promise.resolve();
    await this.client.cleanupOutput(this.info.id);
  }

  private async resolveStreamFailure(transportError: unknown): Promise<Error> {
    const deadline = Date.now() + 400;
    try {
      while (Date.now() < deadline) {
        const info = await this.client.outputStatus(this.info.id);
        this.info = info;
        if (info.error) return outputFailure(info);
        if (info.state === "stopped" || info.state === "cancelled") break;
        await delay(20);
      }
    } catch { /* Control connection failure falls through to transport error. */ }
    return new SonexisError("output_stream_closed",
      transportError instanceof Error ? transportError.message
        : "Runtime closed the output stream unexpectedly", true);
  }

  private async runExclusive<T>(operation: () => Promise<T>, signal?: AbortSignal): Promise<T> {
    const previous = this.operationTail;
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    this.operationTail = previous.catch(() => undefined).then(() => gate);
    try {
      await waitForPromise(previous, signal);
      if (signal?.aborted) throw abortError();
      return await operation();
    } finally {
      release();
    }
  }
}

interface OutputFrameInput {
  streamId: string;
  sequence: bigint;
  timestampNs: bigint;
  format: AudioFormat;
  frameCount: number;
  data: Buffer | Uint8Array;
  discontinuity?: boolean;
  endOfStream?: boolean;
}

/** Encode one client-to-Runtime protocol-v2 SXPC packet. */
export function encodeOutputFrame(input: OutputFrameInput): Buffer {
  if (input.sequence < 0n || input.sequence > 0xffff_ffff_ffff_ffffn
      || input.timestampNs < 0n || input.timestampNs > 0xffff_ffff_ffff_ffffn) {
    throw new RangeError("Output sequence and timestamp must fit unsigned 64-bit fields");
  }
  if (!Number.isSafeInteger(input.frameCount) || input.frameCount < 0
      || input.frameCount > 0xffff_ffff) {
    throw new RangeError("Output frameCount must fit an unsigned 32-bit field");
  }
  const data = Buffer.isBuffer(input.data) ? input.data
    : Buffer.from(input.data.buffer, input.data.byteOffset, input.data.byteLength);
  if (data.length > 512 * 1024) {
    throw new RangeError("Output PCM payload exceeds 512 KiB");
  }
  const endOfStream = !!input.endOfStream;
  if (endOfStream) {
    if (data.length || input.frameCount) {
      throw new RangeError("An output EOS packet cannot contain PCM frames");
    }
  } else if (!input.frameCount || data.length !== input.frameCount * bytesPerFrame(input.format)) {
    throw new RangeError("Output PCM payload and frame count are inconsistent");
  }
  const header = Buffer.alloc(64);
  header.writeUInt32BE(0x53585043, 0);
  header.writeUInt16BE(2, 4);
  header.writeUInt16BE((input.discontinuity ? 1 : 0) | (endOfStream ? 2 : 0), 6);
  header.writeUInt32BE(64, 8);
  header.writeUInt32BE(data.length, 12);
  uuidToBytes(input.streamId).copy(header, 16);
  header.writeBigUInt64BE(input.sequence, 32);
  header.writeBigUInt64BE(input.timestampNs, 40);
  if (!endOfStream) {
    header.writeUInt32BE(input.format.sample_rate, 48);
    header.writeUInt32BE(input.frameCount, 52);
    header.writeUInt16BE(input.format.channel_count, 56);
  }
  // Swift validates the format code before applying the special EOS rules;
  // EOS zeros rate/frame/channel fields but retains its negotiated format code.
  header.writeUInt16BE(input.format.sample_format === "pcm_s16le" ? 1 : 2, 58);
  return data.length ? Buffer.concat([header, data]) : header;
}

function parseOutputDestination(value: unknown): AudioOutputDestination {
  const record = asRecord(value, "output destination");
  const kind = stringField(record, "kind");
  if (kind !== "playback" && kind !== "virtual_input") {
    throw new TypeError(`Unknown output destination kind ${JSON.stringify(kind)}`);
  }
  const formats = record.supported_formats;
  if (!Array.isArray(formats)) throw new TypeError("supported_formats must be an array");
  return {
    id: stringField(record, "id"),
    kind,
    name: stringField(record, "name"),
    is_available: booleanField(record, "is_available"),
    is_default: booleanField(record, "is_default"),
    follows_system_default: booleanField(record, "follows_system_default"),
    active_device_id: optionalStringField(record, "active_device_id"),
    active_device_name: optionalStringField(record, "active_device_name"),
    native_format: record.native_format === undefined || record.native_format === null
      ? undefined : parseAudioFormat(record.native_format),
    supported_formats: formats.map(parseAudioFormat),
  };
}

function sameAudioFormat(left: AudioFormat, right: AudioFormat): boolean {
  return left.sample_rate === right.sample_rate
    && left.channel_count === right.channel_count
    && left.sample_format === right.sample_format
    && left.interleaved === right.interleaved;
}

function parseOutputInfo(value: unknown): OutputInfo {
  const record = asRecord(value, "output session");
  const state = stringField(record, "state");
  if (!["starting", "ready", "draining", "stopped", "cancelled", "failed"].includes(state)) {
    throw new TypeError(`Unknown output session state ${JSON.stringify(state)}`);
  }
  const streamId = stringField(record, "stream_id");
  uuidToBytes(streamId);
  return {
    id: stringField(record, "id"),
    stream_id: streamId,
    destination_id: stringField(record, "destination_id"),
    state: state as OutputSessionState,
    format: parseAudioFormat(record.format),
    data_socket_path: stringField(record, "data_socket_path"),
    started_at_nanoseconds: numericField(record, "started_at_nanoseconds"),
    target_buffer_milliseconds: numericField(record, "target_buffer_milliseconds"),
    metrics: parseOutputMetrics(record.metrics),
    error: record.error === undefined || record.error === null
      ? undefined : parseRuntimeError(record.error),
  };
}

function parseOutputMetrics(value: unknown): OutputMetrics {
  const record = value === undefined || value === null ? {} : asRecord(value, "output metrics");
  const integerFields = [
    "packets_received", "input_frames_received", "input_bytes_received",
    "device_frames_enqueued", "device_frames_rendered", "dropped_frames", "flushed_frames",
    "late_frames", "underrun_frames", "underrun_events", "overrun_events",
    "queue_depth_frames", "queue_high_water_frames", "target_buffer_milliseconds",
    "conversion_batches", "conversion_nanoseconds", "route_changes",
  ] as const;
  const result: Record<string, number | boolean> = {};
  for (const field of integerFields) result[field] = optionalNumericField(record, field, 0);
  result.buffered_milliseconds = optionalNumericField(record, "buffered_milliseconds", 0);
  result.producer_connected = optionalBooleanField(record, "producer_connected", false);
  for (const field of ["device_sample_rate", "device_channel_count",
    "estimated_output_latency_milliseconds", "uptime_nanoseconds"] as const) {
    if (record[field] !== undefined && record[field] !== null) {
      result[field] = optionalNumericField(record, field, 0);
    }
  }
  return result as unknown as OutputMetrics;
}

function parseAudioFormat(value: unknown): AudioFormat {
  const record = asRecord(value, "audio format");
  const sampleFormat = stringField(record, "sample_format");
  if (sampleFormat !== "pcm_s16le" && sampleFormat !== "float32_le") {
    throw new TypeError(`Unknown sample format ${JSON.stringify(sampleFormat)}`);
  }
  const sampleRate = numericField(record, "sample_rate");
  const channelCount = numericField(record, "channel_count");
  if (!Number.isInteger(sampleRate) || sampleRate <= 0
      || !Number.isInteger(channelCount) || channelCount <= 0) {
    throw new TypeError("Audio format sample rate and channel count must be positive integers");
  }
  return { sample_rate: sampleRate, channel_count: channelCount,
    sample_format: sampleFormat, interleaved: booleanField(record, "interleaved") };
}

function parseRuntimeError(value: unknown): RuntimeErrorInfo {
  const record = asRecord(value, "Runtime error");
  const details = record.details;
  if (details !== undefined && (details === null || typeof details !== "object"
      || Array.isArray(details))) throw new TypeError("Runtime error details must be an object");
  return { code: stringField(record, "code"), message: stringField(record, "message"),
    retryable: booleanField(record, "retryable"),
    details: details as Record<string, string> | undefined };
}

function asRecord(value: unknown, name: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError(`${name} must be an object`);
  }
  return value as Record<string, unknown>;
}

function stringField(record: Record<string, unknown>, name: string): string {
  const value = record[name];
  if (typeof value !== "string") throw new TypeError(`${name} must be a string`);
  return value;
}

function optionalStringField(record: Record<string, unknown>, name: string): string | undefined {
  const value = record[name];
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "string") throw new TypeError(`${name} must be a string`);
  return value;
}

function booleanField(record: Record<string, unknown>, name: string): boolean {
  const value = record[name];
  if (typeof value !== "boolean") throw new TypeError(`${name} must be a boolean`);
  return value;
}

function optionalBooleanField(record: Record<string, unknown>, name: string,
                              fallback: boolean): boolean {
  const value = record[name];
  if (value === undefined) return fallback;
  if (typeof value !== "boolean") throw new TypeError(`${name} must be a boolean`);
  return value;
}

function numericField(record: Record<string, unknown>, name: string): number {
  const value = record[name];
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
    throw new TypeError(`${name} must be a non-negative finite number`);
  }
  return value;
}

function optionalNumericField(record: Record<string, unknown>, name: string,
                              fallback: number): number {
  return record[name] === undefined ? fallback : numericField(record, name);
}

function bytesPerFrame(format: AudioFormat): number {
  if (!Number.isInteger(format.sample_rate) || format.sample_rate <= 0
      || !Number.isInteger(format.channel_count) || format.channel_count <= 0
      || format.interleaved !== true) {
    throw new RangeError("Output format must be positive-rate interleaved PCM");
  }
  return format.channel_count * (format.sample_format === "pcm_s16le" ? 2
    : format.sample_format === "float32_le" ? 4
      : (() => { throw new RangeError("Unsupported output sample format"); })());
}

function timestampToBigInt(value: bigint | number): bigint {
  if (typeof value === "bigint") {
    if (value < 0n) throw new RangeError("timestampNs must not be negative");
    return value;
  }
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new RangeError("Numeric timestampNs must be a non-negative safe integer; use bigint otherwise");
  }
  return BigInt(value);
}

function uuidToBytes(value: string): Buffer {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)) {
    throw new TypeError("Stream ID must be a UUID");
  }
  return Buffer.from(value.replaceAll("-", ""), "hex");
}

async function writeWithBackpressure(socket: Socket, packet: Buffer,
                                     signal?: AbortSignal): Promise<void> {
  if (signal?.aborted) throw abortError();
  if (socket.destroyed || !socket.writable) {
    throw new SonexisError("output_stream_closed", "Output data socket is closed", true);
  }
  if (socket.write(packet)) return;
  await new Promise<void>((resolve, reject) => {
    const cleanup = (): void => {
      socket.removeListener("drain", onDrain);
      socket.removeListener("error", onError);
      socket.removeListener("close", onClose);
      signal?.removeEventListener("abort", onAbort);
    };
    const finish = (action: () => void): void => { cleanup(); action(); };
    const onDrain = (): void => finish(resolve);
    const onError = (error: Error): void => finish(() => reject(error));
    const onClose = (): void => finish(() => reject(new SonexisError(
      "output_stream_closed", "Output data socket closed during backpressure", true)));
    const onAbort = (): void => finish(() => reject(abortError()));
    socket.once("drain", onDrain);
    socket.once("error", onError);
    socket.once("close", onClose);
    signal?.addEventListener("abort", onAbort, { once: true });
    if (signal?.aborted) onAbort();
  });
}

async function waitForPromise(promise: Promise<void>, signal?: AbortSignal): Promise<void> {
  if (!signal) return promise;
  if (signal.aborted) throw abortError();
  let onAbort!: () => void;
  try {
    await Promise.race([
      promise,
      new Promise<never>((_, reject) => {
        onAbort = () => reject(abortError());
        signal.addEventListener("abort", onAbort, { once: true });
      }),
    ]);
  } finally {
    signal.removeEventListener("abort", onAbort);
  }
}

function outputFailure(info: OutputInfo): OutputFailedError {
  return new OutputFailedError(info.error?.message ?? "Audio output failed",
    info.error?.code ?? "output_failed", info.error?.retryable ?? false,
    info.error?.details ?? {});
}

export class CaptureStream extends EventEmitter implements AsyncIterable<AudioFrame> {
  private buffer = Buffer.alloc(0);
  private queue: AudioFrame[] = [];
  private waiters: Array<{ resolve: (value: IteratorResult<AudioFrame>) => void;
    reject: (error: Error) => void }> = [];
  private ended = false;
  private cleanupPromise?: Promise<void>;
  private terminalError?: Error;
  private closing = false;
  private sawEndOfStream = false;
  private previousSequence?: bigint;
  private iteratorActive = false;

  private constructor(private readonly client: Sonexis, readonly info: CaptureInfo,
                      readonly source: AudioSource, private readonly socket: Socket) { super(); }

  static async open(client: Sonexis, info: CaptureInfo,
                    source: AudioSource): Promise<CaptureStream> {
    const socket = await openSocket(info.data_socket_path);
    const stream = new CaptureStream(client, info, source, socket);
    client.trackCapture(stream);
    socket.on("data", (chunk) => stream.consume(chunk));
    socket.on("close", () => {
      const truncated = !stream.closing && !stream.sawEndOfStream
        ? new SonexisError("truncated_pcm_stream", "Audio stream closed without EOS") : undefined;
      if (truncated) stream.emit("streamError", truncated);
      if (!stream.sawEndOfStream) {
        stream.finish(truncated);
        void stream.cleanupRuntime();
      }
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

  runtimeDisconnected(error: Error): void {
    this.closing = true;
    this.socket.destroy();
    this.finish(error);
    this.client.untrackCapture(this);
  }


  async *[Symbol.asyncIterator](): AsyncIterator<AudioFrame> {
    if (this.iteratorActive) {
      throw new SonexisError("consumer_exists", "Audio stream already has an iterator");
    }
    this.iteratorActive = true;
    try {
      while (true) {
        if (this.queue.length) {
          const frame = this.queue.shift()!;
          if (this.queue.length < 32) {
            this.socket.resume();
            this.consume(Buffer.alloc(0));
          }
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
      this.iteratorActive = false;
      await this.close();
    }
  }

  private consume(chunk: Buffer): void {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (this.buffer.length >= 64) {
      if (this.queue.length >= 64 && this.waiters.length === 0) {
        this.socket.pause();
        return;
      }
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
      if (frame.endOfStream) {
        this.sawEndOfStream = true;
        this.socket.pause();
        void this.finishFromEndOfStream();
        return;
      }
      this.emit("audio", frame);
      const waiter = this.waiters.shift();
      if (waiter) waiter.resolve({ value: frame, done: false });
      else if (this.listenerCount("audio") === 0 || this.iteratorActive) {
        this.queue.push(frame);
        if (this.queue.length >= 64) this.socket.pause();
      }
    }
  }

  private async finishFromEndOfStream(): Promise<void> {
    try {
      const status = await this.client.status(this.info.id);
      if (status.state === "failed") {
        const failure = status.error;
        this.finish(new CaptureFailedError(
          failure?.message ?? "Capture failed", failure?.code ?? "capture_failed",
          failure?.retryable ?? false, failure?.details ?? {}));
      } else this.finish();
    } catch (error) {
      this.finish(error instanceof Error ? error : new Error(String(error)));
    } finally {
      void this.cleanupRuntime();
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

  private cleanupRuntime(): Promise<void> {
    this.cleanupPromise ??= (async () => {
      try { await this.client.cleanupCapture(this.info.id); }
      catch { /* control teardown is authoritative */ }
      finally { this.client.untrackCapture(this); }
    })();
    return this.cleanupPromise;
  }
}

export interface LabeledAudioFrame {
  label: string;
  frame: AudioFrame;
  source: AudioSource;
  sessionId: string;
  streamId: string;
  timestampNs: bigint;
  localDroppedFramesBefore: number;
  discontinuity: boolean;
}

/** Convenience ownership boundary for one input and one independent output. */
export class DuplexSession {
  private closed = false;
  private closePromise?: Promise<void>;

  private constructor(readonly input: CaptureStream, readonly output: AudioOutput) {}

  /** Advisory only: true for an installed loopback/virtual-input destination. */
  get feedbackRisk(): boolean { return this.output.destination.kind === "virtual_input"; }

  get feedbackWarning(): string | undefined {
    return this.feedbackRisk
      ? "Output targets a virtual input. Prevent generated audio from feeding the capture source."
      : undefined;
  }

  static async open(client: Sonexis, source: SourceSelector,
                    options: DuplexOptions = {}): Promise<DuplexSession> {
    const inputFormat = options.inputFormat ?? AudioFormats.speech16k();
    const input = await client.capture(source, inputFormat);
    try {
      const output = await client.playback({
        ...options.output,
        format: options.output?.format ?? inputFormat,
      });
      return new DuplexSession(input, output);
    } catch (error) {
      await input.close();
      throw error;
    }
  }

  /** Drain response audio on normal shutdown; pass false for barge-in. */
  async close(drainOutput = true): Promise<void> {
    this.closePromise ??= this.finishClose(drainOutput);
    return this.closePromise;
  }

  private async finishClose(drainOutput: boolean): Promise<void> {
    this.closed = true;
    const results = await Promise.allSettled([
      this.output.close({ drain: drainOutput }),
      this.input.close(),
    ]);
    const failure = results.find((result): result is PromiseRejectedResult =>
      result.status === "rejected");
    if (failure) throw failure.reason;
  }
}

interface MultiSourceEnd {
  label: string;
  error?: Error;
}

/** Bounded orchestration for independent, labeled capture streams. */
export class MultiSourceSession {
  readonly maxQueueFrames: number;
  droppedFrames = 0;
  readonly droppedFramesByLabel = new Map<string, number>();
  readonly errorsByLabel = new Map<string, Error>();
  private readonly captures = new Map<string, CaptureStream>();
  private readonly pumps = new Map<string, Promise<void>>();
  private readonly pendingLabels = new Set<string>();
  private readonly queues = new Map<string, LabeledAudioFrame[]>();
  private readonly pendingDrops = new Map<string, number>();
  private readonly ends = new Map<string, MultiSourceEnd>();
  private readonly waiters: Array<() => void> = [];
  private closed = false;
  private iteratorActive = false;
  private closePromise?: Promise<void>;

  constructor(private readonly client: Sonexis, maxQueueFrames = 128,
              readonly failFast = true) {
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
      this.queues.set(label, []);
      this.pendingDrops.set(label, 0);
      this.droppedFramesByLabel.set(label, 0);
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
    this.queues.delete(label);
    this.pendingDrops.delete(label);
    this.ends.delete(label);
    this.wake();
  }

  async *frames(): AsyncIterableIterator<LabeledAudioFrame> {
    if (this.iteratorActive) {
      throw new SonexisError("consumer_exists", "Multi-source frames already have a consumer");
    }
    this.iteratorActive = true;
    try {
      while (!this.closed) {
        for (const [label] of this.captures) {
          const frame = this.queues.get(label)?.shift();
          if (frame) yield frame;
        }

        for (const [label, end] of [...this.ends]) {
          if (this.queues.get(label)?.length) continue;
          this.ends.delete(label);
          this.captures.delete(label);
          this.pumps.delete(label);
          this.queues.delete(label);
          this.pendingDrops.delete(label);
          if (end.error) {
            this.errorsByLabel.set(label, end.error);
            if (this.failFast) throw end.error;
          }
        }
        if (!this.captures.size) return;
        await new Promise<void>((resolve) => {
          this.waiters.push(resolve);
          if (this.hasReadyItem()) this.wake();
        });
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
    this.queues.clear();
    this.pendingDrops.clear();
    this.ends.clear();
    for (const waiter of this.waiters.splice(0)) waiter();
  }

  private async pump(label: string, capture: CaptureStream): Promise<void> {
    let error: Error | undefined;
    try {
      for await (const frame of capture) {
        if (this.closed || this.captures.get(label) !== capture) break;
        const queue = this.queues.get(label);
        if (!queue) break;
        if (queue.length >= this.maxQueueFrames) {
          this.droppedFrames += frame.frameCount;
          this.droppedFramesByLabel.set(
            label, (this.droppedFramesByLabel.get(label) ?? 0) + frame.frameCount);
          this.pendingDrops.set(label, (this.pendingDrops.get(label) ?? 0) + frame.frameCount);
          continue;
        }
        const localDroppedFramesBefore = this.pendingDrops.get(label) ?? 0;
        this.pendingDrops.set(label, 0);
        const forwarded = localDroppedFramesBefore > 0
          ? { ...frame, discontinuity: true }
          : frame;
        queue.push({ label, frame: forwarded, source: forwarded.source,
          sessionId: forwarded.sessionId,
          streamId: forwarded.streamId, timestampNs: forwarded.timestampNs,
          localDroppedFramesBefore,
          discontinuity: frame.discontinuity || localDroppedFramesBefore > 0 });
        this.wake();
      }
    } catch (caught) {
      error = caught instanceof Error ? caught : new Error(String(caught));
    } finally {
      if (error && !this.failFast) this.errorsByLabel.set(label, error);
      if (this.captures.get(label) === capture) this.ends.set(label, { label, error });
      this.wake();
    }
  }

  private wake(): void {
    this.waiters.shift()?.();
  }

  private hasReadyItem(): boolean {
    return this.closed || !this.captures.size || this.ends.size > 0
      || [...this.queues.values()].some((queue) => queue.length > 0);
  }
}

export class EventStream extends EventEmitter implements AsyncIterable<RuntimeEvent> {
  private buffer = Buffer.alloc(0);
  private queue: RuntimeEvent[] = [];
  private waiters: Array<{ resolve: (value: IteratorResult<RuntimeEvent>) => void;
    reject: (error: Error) => void }> = [];
  private ended = false;
  private cleanupPromise?: Promise<void>;
  private terminalError?: Error;
  private closing = false;
  private iteratorActive = false;

  private constructor(private readonly client: Sonexis, readonly id: string,
                      private readonly socket: Socket) { super(); }
  static async open(client: Sonexis, value: { id: string; event_socket_path: string }): Promise<EventStream> {
    const socket = await openSocket(value.event_socket_path);
    const events = new EventStream(client, value.id, socket);
    client.trackEventStream(events);
    socket.on("data", (chunk) => events.consume(chunk));
    socket.on("close", () => {
      const error = !events.closing
        ? new SonexisError(
          events.buffer.length > 0 ? "truncated_event_stream" : "event_stream_closed",
          events.buffer.length > 0
            ? "Event stream closed mid-message" : "Runtime event stream closed unexpectedly",
          true)
        : undefined;
      if (error) events.emit("streamError", error);
      events.finish(error); void events.cleanupRuntime();
    });
    socket.on("error", (error) => { events.emit("streamError", error); events.finish(error); });
    return events;
  }
  async close(): Promise<void> {
    this.closing = true;
    this.socket.destroy(); this.finish();
    await this.cleanupRuntime();
  }
  runtimeDisconnected(error: Error): void {
    this.closing = true;
    this.socket.destroy();
    this.finish(error);
    this.client.untrackEventStream(this);
  }
  async *[Symbol.asyncIterator](): AsyncIterator<RuntimeEvent> {
    if (this.iteratorActive) {
      throw new SonexisError("consumer_exists", "Event stream already has an iterator");
    }
    this.iteratorActive = true;
    try {
      while (true) {
        if (this.queue.length) {
          const event = this.queue.shift()!;
          if (this.queue.length < 128) {
            this.socket.resume();
            this.consume(Buffer.alloc(0));
          }
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
      this.iteratorActive = false;
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
      if (this.queue.length >= 256 && this.waiters.length === 0) {
        this.socket.pause();
        return;
      }
      let event: RuntimeEvent;
      if (newline + 1 > 65536) {
        const error = new SonexisError("message_too_large", "Event exceeds 64 KiB");
        this.emit("streamError", error); this.socket.destroy(); this.finish(error); return;
      }
      try { event = decodeEvent(this.buffer.subarray(0, newline)); }
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
      else if (this.listenerCount("event") === 0 || this.iteratorActive) {
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
  private cleanupRuntime(): Promise<void> {
    this.cleanupPromise ??= (async () => {
      try { await this.client.cleanupSubscription(this.id); } catch { }
      finally { this.client.untrackEventStream(this); }
    })();
    return this.cleanupPromise;
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
  if (payloadSize > 512 * 1024) {
    throw new SonexisError("invalid_pcm_payload", "PCM payload exceeds 512 KiB");
  }
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
  const endOfStream = !!(flags & 2);
  if (endOfStream
    ? payloadSize !== 0 || frameCount !== 0 || sampleRate !== 0 || channels !== 0
    : payloadSize !== expected || frameCount === 0 || sampleRate === 0 || channels === 0) {
    throw new SonexisError("invalid_pcm_payload", "PCM payload and format are inconsistent");
  }
  if (packet.length !== 64 + payloadSize) throw new SonexisError("truncated_pcm_stream", "Truncated PCM packet");
  return { streamId, sequence, timestampNs, frameCount,
    format: { sample_rate: sampleRate, channel_count: channels, sample_format: sampleFormat,
      interleaved: true }, data: packet.subarray(64), discontinuity: !!(flags & 1),
    droppedFramesBefore: packet.readUInt32BE(60), endOfStream };
}

export function decodeEvent(line: Buffer): RuntimeEvent {
  let value: unknown;
  try { value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(line)); }
  catch { throw new SonexisError("invalid_event", "Runtime sent invalid event JSON"); }
  if (!value || typeof value !== "object") {
    throw new SonexisError("invalid_event", "Runtime event must be an object");
  }
  const event = value as Record<string, unknown>;
  if (event.protocol_version !== 2 || typeof event.event_id !== "string"
      || typeof event.type !== "string" || typeof event.timestamp_nanoseconds !== "number"
      || !Number.isFinite(event.timestamp_nanoseconds)
      || event.timestamp_nanoseconds < 0) {
    throw new SonexisError("invalid_event", "Runtime sent an invalid event envelope");
  }
  if (event.event_sequence !== undefined && (typeof event.event_sequence !== "number"
      || !Number.isFinite(event.event_sequence) || event.event_sequence < 0)) {
    throw new SonexisError("invalid_event", "Runtime sent an invalid event sequence");
  }
  const decoded = event as unknown as RuntimeEvent;
  if (event.output_session !== undefined && event.output_session !== null) {
    decoded.output_session = parseOutputInfo(event.output_session);
  }
  if (event.output_destination !== undefined && event.output_destination !== null) {
    decoded.output_destination = parseOutputDestination(event.output_destination);
    if (event.output_destination_id !== undefined
        && event.output_destination_id !== decoded.output_destination.id) {
      throw new SonexisError("invalid_event",
        "Runtime event destination ID does not match its destination snapshot");
    }
    decoded.output_destination_id = decoded.output_destination.id;
  }
  return decoded;
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
