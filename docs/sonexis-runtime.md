# Sonexis Runtime v0.2

## Purpose

Sonexis Runtime is a local macOS audio service for developer tools. A separate process can discover running application sources, negotiate an output format, start independent capture sessions, receive framed realtime PCM, observe lifecycle events and diagnostics, and stop cleanly without using Core Audio.

The Runtime is audio infrastructure. It does not provide transcription, models, cloud transport, authentication, accounts, or virtual devices, and it never opens a TCP port.

## Build and run

```sh
xcodebuild -project Sonexis.xcodeproj -scheme sonexis-runtime \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Sonexis.xcodeproj -scheme sonexisctl \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build

.build/DerivedData/Build/Products/Debug/sonexis-runtime
```

In another terminal:

```sh
.build/DerivedData/Build/Products/Debug/sonexisctl sources
.build/DerivedData/Build/Products/Debug/sonexisctl status
.build/DerivedData/Build/Products/Debug/sonexisctl watch
.build/DerivedData/Build/Products/Debug/sonexisctl capture app.com.example.audio \
  --sample-rate 24000 --channels 1 --sample-format pcm_s16le \
  --output /tmp/example.pcm --debug
```

Append `--socket PATH` to a CLI command or set `SONEXIS_RUNTIME_SOCKET`. Set `SONEXIS_RUNTIME_DIR` when starting the Runtime to move all of its sockets.

The Runtime executable has its own Screen & System Audio Recording permission identity. An unsigned command-line build can enumerate applications and run synthetic tests, but live capture needs macOS permission and normally a stable signed identity.

## Architecture

```text
NSWorkspace + Core Audio HAL
            │
            ▼
   AudioSourceRegistry ── 1 s source diff monitor ── event hub
            │                                        │
            ▼                                        └─ events-UUID.sock (NDJSON)
 AudioCaptureManager / independent AudioCaptureSession
            │ native interleaved Float32
            ▼
 preallocated atomic SPSC C ring  ← HAL callback boundary
            │ capture worker
            ▼
 AVAudioConverter → negotiated AudioFrame
            │ bounded delivery (32)
            ▼
 RuntimeSessionCoordinator
       ├── control.sock (bounded NDJSON)
       └── RuntimeDataPlane (64 packets) ── stream-UUID.sock (binary PCM)
```

The HAL IOProc only writes to preallocated ring storage and increments relaxed atomics. Conversion, event publication, framing, logging, and socket I/O occur off the callback. The existing Sonexis app shares the registry, Process Tap owner, Core Audio helpers, and ring while retaining its separate DSP/output lifecycle.

Each capture request owns an independent Process Tap, converter, buffers, stream socket, counters, and lifecycle—even when two clients select the same source. This maximizes isolation and avoids a shared-tap lifetime/multiplexing layer before practical Core Audio limits are measured. Runtime limits are 16 active sessions globally, eight per control client, four data subscribers per stream, 32 control clients, 32 event subscriptions globally, and four event subscriptions per client.

## Protocol handshake and versioning

Control messages are UTF-8 JSON followed by `\n`, limited to 64 KiB. External keys are lower snake case. The first request on every connection must be `hello`:

```json
{"message_type":"request","protocol_version":2,"request_id":"UUID","command":"hello","supported_protocol_versions":[2],"client_name":"example","client_version":"1.0"}
```

A successful response includes a distinct response ID and the negotiated platform description:

```json
{
  "message_type": "response",
  "protocol_version": 2,
  "response_id": "UUID",
  "request_id": "UUID",
  "ok": true,
  "handshake": {
    "protocol_version": 2,
    "runtime_version": "0.2.0",
    "runtime_instance_id": "UUID",
    "capabilities": ["application_sources", "capture_sessions", "event_stream", "format_negotiation", "multiple_sessions", "pcm_v2", "runtime_diagnostics"],
    "supported_formats": [
      {"sample_rate": 16000, "channel_count": 1, "sample_format": "pcm_s16le", "interleaved": true}
    ],
    "limits": {
      "maximum_control_clients": 32,
      "maximum_sessions": 16,
      "maximum_sessions_per_client": 8,
      "maximum_subscribers_per_stream": 4,
      "maximum_control_message_bytes": 65536,
      "maximum_event_subscriptions": 32,
      "maximum_event_subscriptions_per_client": 4
    }
  }
}
```

Protocol version 2 is mandatory in v0.2. Additive optional fields and capabilities may appear without a protocol bump; removing fields or changing semantics requires a later protocol version. Runtime SemVer is independent of protocol version. Request IDs must contain 1–128 UTF-8 bytes. Responses echo the request ID, have their own UUID, and carry exactly the result relevant to the command.

Supported commands:

- `hello`
- `ping`
- `list_sources`
- `start_capture` with `source_id` and optional `format`
- `session_status` with `session_id`
- `stop_capture` with `session_id`
- `runtime_status`
- `subscribe_events` with an optional `event_types` array
- `unsubscribe_events` with `subscription_id`

Errors are `{code, message, retryable, details?}`. Stable examples include `handshake_required`, `unsupported_protocol_version`, `source_unavailable`, `unsupported_format`, `session_not_found`, `session_limit_exceeded`, `message_too_large`, and `malformed_json`. Malformed input terminates only the offending connection when framing cannot safely continue.

## Source model

An application source contains a bundle-stable ID (`app.<bundle identifier>`), kind, application name, bundle identifier, all current PIDs, process state, availability, and an optional audio-production heuristic. PID is transient metadata and never source identity. Core Audio object IDs and bundle paths are not exposed.

`is_producing_audio` means that one current PID appears in the HAL audio-process list; it is not signal-level detection. `native_format` is currently null because discovery only knows the default-output format, not an authoritative application-native format. The capture response contains the authoritative negotiated Runtime output format.

The source-kind enum reserves application, microphone, system mix, remote, and virtual values. Only application sources are implemented.

## Capture sessions and format negotiation

The default is PCM16 little-endian, mono, 16 kHz. The handshake advertises the exact supported set:

- PCM16 mono at 16, 24, or 48 kHz;
- PCM16 stereo at 48 kHz;
- Float32 little-endian mono or stereo at 48 kHz.

Formats are interleaved. Requests must match one advertised combination exactly; otherwise `unsupported_format` includes a compact supported-format list. Conversion uses AVAudioConverter on the capture worker and does not alter the Sonexis app’s native DSP path.

A capture has distinct session and stream UUIDs. The session owns capture lifecycle; the stream identifies binary packets. Session states are `starting`, `capturing`, `stopped`, and `failed`. Stop is idempotent. Control disconnect stops and removes that client’s captures. A source/process or default-output change rebuilds the capture pipeline with the external session ID preserved and marks the next PCM packet discontinuous. Failure is terminal and carries a structured error.

## Runtime events

`subscribe_events` creates a separate `events-UUID.sock`; connecting to it yields bounded NDJSON events. Separating events from control responses avoids asynchronous writer interleaving and lets request traffic remain usable when a watcher is slow.

Implemented event types:

- `source_added`, `source_removed`, and `source_updated`, based on serialized registry snapshot diffs;
- `capture_started`, `capture_stopped`, and `capture_failed`;
- `device_changed` after a capture successfully rebuilds for a default-output-device change;
- `client_warning` and `runtime_warning` when emitted by the corresponding subsystem;
- `runtime_shutting_down`, delivered best-effort before sockets close.

Permission-change and signal-level audio-start/stop events are deliberately not advertised because the Runtime cannot determine those transitions reliably. Each delivered event includes an event UUID, monotonic timestamp, per-subscription `event_sequence`, and relevant typed source/session/error data. `dropped_events_before` reports events lost before that delivery, including the subscribe-to-data-socket attach window. Subscriptions are capped, owned by their control connection, and disappear on disconnect.

## PCM v2 framing

Every packet begins with this fixed 64-byte, network-byte-order header. PCM payload samples are little-endian.

| Offset | Size | Type | Meaning |
| ---: | ---: | --- | --- |
| 0 | 4 | `u32` | magic `SXPC` (`0x53585043`) |
| 4 | 2 | `u16` | frame protocol version `2` |
| 6 | 2 | `u16` | flags: bit 0 discontinuity, bit 1 EOS |
| 8 | 4 | `u32` | header size `64` |
| 12 | 4 | `u32` | payload byte count |
| 16 | 16 | bytes | RFC-4122 stream UUID |
| 32 | 8 | `u64` | packet sequence |
| 40 | 8 | `u64` | first-sample stream-relative nanoseconds |
| 48 | 4 | `u32` | sample rate |
| 52 | 4 | `u32` | PCM frame count |
| 56 | 2 | `u16` | channel count |
| 58 | 2 | `u16` | format: `1` PCM16 LE, `2` Float32 LE |
| 60 | 4 | `u32` | PCM frames dropped before this packet |

For an audio packet, payload bytes must equal `frame_count × channels × bytes_per_sample` and may not exceed 512 KiB. Sequence increases for every produced packet. A gap must have the discontinuity flag. `dropped_frames_before` accounts for known loss before the packet, saturating at `UInt32.max`. EOS has zero payload/frame count and is the final packet. EOF before EOS or mid-frame is a protocol error in the SDKs.

The start response associates stream UUID with session and source IDs, avoiding variable source strings in every audio packet. Timestamps are derived from negotiated sample position and include estimated known ring/delivery loss. They are not HAL host timestamps.

## Backpressure

Memory growth is bounded at every application layer:

- the native SPSC ring holds approximately two seconds of device-rate audio and drops new native frames when full;
- capture-to-consumer delivery holds 32 frames and drops the newest frame when full;
- each data plane holds 64 packets and drops the newest packet when full;
- data sockets are nonblocking; any partial write or `EAGAIN` disconnects that slow subscriber because its byte stream can no longer be trusted;
- each stream accepts at most four subscribers;
- event delivery holds 256 messages, counts overflow/attach-window loss, and disconnects a stalled socket on write failure;
- Python relies on `asyncio` transport flow control, and the TypeScript client pauses its socket at 64 queued audio frames/256 queued events.

The next successful PCM packet after a known drop carries discontinuity and drop count. Session status separates ring drops, delivery drops, data-queue drops, frames produced with no subscriber, slow-consumer disconnects, queue high-water, connected subscribers, and bytes transmitted. One stuck consumer cannot grow Runtime heap without bound or block the HAL callback.

## Python SDK

The supported public package is under `SDKs/python`, requires Python 3.9+, and has no runtime dependencies:

```sh
/usr/bin/python3 -m venv --system-site-packages .venv
. .venv/bin/activate
python -m pip install --no-deps --no-build-isolation -e SDKs/python
```

```python
from sonexis import AudioFormat, Sonexis

async with Sonexis() as sx:
    sources = await sx.sources()
    async with await sx.capture(
        sources[0], format=AudioFormat(sample_rate=24_000, channels=1)
    ) as stream:
        async for frame in stream:
            print(frame.sequence, frame.timestamp_ns, len(frame.data))
```

Public types include `Sonexis`/`SonexisClient`, `AudioSource`, `AudioFormat`, `CaptureSession`, `CaptureInfo`, `AudioFrame`, `RuntimeEvent`, `RuntimeStatus`, `SessionMetrics`, `RuntimeErrorInfo`, and structured `SonexisError` subclasses. Control requests are correlated by ID through one reader task, so concurrent requests are safe. Capture and event streams are async iterators/context managers. Cancellation discards late responses without corrupting the connection. Failed data-socket attachment rolls the Runtime resource back. `reconnect()` creates a fresh control connection; it never pretends that terminated captures resumed.

Run SDK tests with `Scripts/test-python-sdk.sh`. `Examples/python-runtime-monitor.py` is the SDK-only reference application; it selects a source, watches lifecycle events, displays statistics, and optionally writes PCM or PCM16 WAV. `Examples/python-runtime-client.py` is a smaller compatibility example that also uses only public SDK APIs.

## TypeScript SDK

`SDKs/typescript` contains a dependency-free-at-runtime Node 18+ client with typed sources, formats, sessions, errors, events, async audio iteration, EventEmitter hooks, bounded SDK queues, and cleanup. On a Node-equipped machine:

```sh
cd SDKs/typescript
npm install
npm run build
npm test
```

The current validation host has no Node, npm, or TypeScript compiler. The source and shared byte fixtures are reviewed, but this milestone does not claim an executed TypeScript build.

## CLI and diagnostics

```sh
sonexisctl sources [--json]
sonexisctl status [session-id] [--json]
sonexisctl watch [--json]
sonexisctl capture SOURCE [--sample-rate Hz] [--channels 1|2] \
  [--sample-format pcm_s16le|float32_le] [--output FILE] [--debug]
sonexisctl stop SESSION [--json]
```

Runtime status reports version/instance, uptime, active clients/sessions/event subscriptions, sessions started, lifetime PCM frames forwarded/dropped, bytes transmitted, and event drops. Session status additionally reports capture callback count, native and normalized frames, ring/delivery/data drops, conversion batches/time, ring backlog, queue high-water, subscriber count, and transmitted bytes. Counters are sampled off the realtime callback.

## Security and trust model

- The Runtime uses only `AF_UNIX`; it does not bind TCP or public-network interfaces.
- The socket directory must be a real directory owned by the current UID and is forced to mode `0700`; sockets are mode `0600`.
- Accepted peers must have the same effective UID (`getpeereid`). Descriptors use `FD_CLOEXEC`.
- Existing live sockets are never replaced. Stale sockets are removed only for the same owner, and shutdown unlinks only the device/inode originally bound by that listener.
- Control messages, PCM packets, clients, sessions, event subscriptions, stream subscribers, and in-process queues have explicit limits.
- v0.2 trusts the local macOS account. Any accepted same-UID client may query or stop a session by ID; the creating connection owns automatic cleanup and quota accounting. This intentional account-wide management policy keeps `sonexisctl stop SESSION` usable. Any unsandboxed process running as the same user is within the trust boundary and can use the Runtime’s granted audio permission. Do not run the Runtime privileged or place its sockets in a shared multi-user directory.

## Troubleshooting

- `connect failed: No such file or directory`: start `sonexis-runtime` or pass the matching socket path.
- `handshake_required`: the first control command must be protocol-v2 `hello`; use an SDK or current CLI.
- `unsupported_format`: select one of `handshake.supported_formats`.
- `source_unavailable`: enumerate again; the application may have terminated between discovery and capture.
- `session_limit_exceeded`: stop captures or wait for another client to disconnect.
- `unexpected_pcm_eof`/`truncated_pcm_stream`: the Runtime or socket ended without a clean EOS; discard the partial packet and reconnect explicitly.
- No audio despite a running source: verify Screen & System Audio Recording permission for the Runtime executable’s identity.

## Known limitations

- Signed live Process Tap/TCC, target termination/restart, and physical output-device switching still require manual macOS acceptance testing.
- Source/audio activity is a HAL-registration heuristic, not level detection.
- Timestamps are stream-relative sample time, not preserved HAL host time; live end-to-end latency is not yet measurable from frames alone.
- Same-source captures use independent Process Taps and are not deduplicated.
- Event sockets and data sockets rely on private per-user filesystem paths rather than a separate attach-token preface.
- The server uses one bounded blocking worker per control client; limits prevent exhaustion, but a future service transport should use nonblocking connection state machines.
- The existing app shares low-level capture infrastructure but does not use the capture-only Runtime session owner.
- SDK packages are repository-local and unpublished. The TypeScript package was not executable-tested on this host.
- JSON event/control nanoseconds and large counters are JavaScript `number`s and lose integer precision after `2^53`; binary PCM timestamps are `bigint`. A later protocol should encode JSON `u64` fields as decimal strings.
- Protocol v2 is the first developer-preview contract. Fields were finalized within this milestone; future incompatible changes require a new protocol version rather than adding required v2 fields.

See [runtime benchmarks](runtime-benchmarks.md) for measured offline performance and remaining live measurements.
