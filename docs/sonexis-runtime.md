# Sonexis Runtime v1.0

## Purpose

Sonexis Runtime is a local macOS audio service for developer and AI tools. A
separate process can discover and capture application audio and can send framed
realtime PCM back to normal or virtual macOS output devices without using Core
Audio. v0.4 adds a bounded client-to-Runtime data plane, HAL playback, output
destinations/sessions/events/diagnostics, Python and TypeScript output APIs,
duplex composition, deterministic output replay, and provider-response
playback while preserving v0.3's source-aware input APIs. v0.5 adds an explicit
per-user development install, foreground/background lifecycle tooling, locally
buildable SDK artifacts, focused examples, synchronized version checks, and
actionable connection errors without changing protocol or audio semantics.
v0.6 made output destinations first-class lifecycle resources: stable resolved
device identity, add/remove/update/default-change events, exact SDK/CLI name
resolution, wait helpers, advisory loopback feedback risk, stricter HAL format
validation, and route changes that backpressure writers instead of terminating
an otherwise healthy output session. v0.7 adds provider-neutral activity edges,
source-correlated provider responses, resilient labeled multi-source
consumption, and a safer structured MCP control surface without changing
protocol v2 or either PCM data plane. v0.8 hardens lifecycle, diagnostics,
socket migration, cancellation, and long-running resource accounting. v0.9
inventoried and froze the public surface; 1.0 promotes that provider-neutral
surface to the documented compatibility policy and retains reproducible local
release artifacts with bounded integrity and metadata verification.

The Runtime is audio infrastructure. It does not provide transcription, models,
cloud transport, authentication, accounts, or acoustic echo cancellation, and
it never opens a TCP port. It can target an installed virtual loopback device;
it does not install a Sonexis-branded driver.

## Zero-to-audio development quickstart

Configure an Apple Development signing identity in Xcode, then run from this
standalone repository:

```sh
./Scripts/setup-runtime-dev.sh
./Scripts/runtime-dev.sh start
"$HOME/Library/Application Support/SonexisRuntime/dev/bin/sonexisctl" sources

/usr/bin/python3 -m venv --system-site-packages .venv-runtime
. .venv-runtime/bin/activate
python -m pip install --no-deps --no-build-isolation -e SDKs/python
python Examples/capture-one-source.py "Google Chrome" --frames 16000
```

Optionally add the managed commands to the current shell's `PATH`:

```sh
export PATH="$HOME/Library/Application Support/SonexisRuntime/dev/bin:$PATH"
sonexis-runtime --version
sonexisctl sources
```

The installer verifies the signature, identifiers, capture usage description,
versions, and hashes before replacing its exact managed prefix. It never uses
`sudo` or installs a launch agent. `Scripts/runtime-dev.sh` supports
`start|status|stop|foreground|logs`; background start is opt-in. Override the
install location with `SONEXIS_DEV_PREFIX`, and select another trusted identity
with `SONEXIS_SIGNING_IDENTITY`.

To confirm Xcode can sign locally and use a different team:

```sh
security find-identity -v -p codesigning
SONEXIS_SIGNING_IDENTITY='Apple Development: Your Name (TEAMID)' \
  ./Scripts/setup-runtime-dev.sh
```

The value is the Apple Developer team configured under Xcode Settings >
Accounts. Setup fails without a trusted Apple Development identity instead of
falling back to an ad-hoc signature.

Stop and uninstall the managed development copy with:

```sh
./Scripts/runtime-dev.sh stop
./Scripts/uninstall-runtime-dev.sh
```

Uninstall removes only manifest-verified binaries. It intentionally retains
`~/Library/Application Support/SonexisRuntime/state`, including lifecycle logs,
so diagnostics survive an uninstall. No PCM is written there. Startup rotates
a log once it exceeds 1 MiB; a single unusually noisy Runtime process may grow
beyond that threshold until restarted.

To build signed products and run directly from the repository instead:

```sh
./Scripts/build-signed-runtime-dev.sh
.build/signed-dev/bin/sonexis-runtime
```

In another terminal:

```sh
.build/signed-dev/bin/sonexisctl sources
.build/signed-dev/bin/sonexisctl status
.build/signed-dev/bin/sonexisctl watch
.build/signed-dev/bin/sonexisctl capture app.com.example.audio \
  --sample-rate 24000 --channels 1 --sample-format pcm_s16le \
  --output /tmp/example.pcm --debug
```

Append `--socket PATH` to a CLI command or set `SONEXIS_RUNTIME_SOCKET`. Set `SONEXIS_RUNTIME_DIR` when starting the Runtime to move all of its sockets.

`SONEXIS_RUNTIME_DIR` names the server directory; client SDKs and CLI use the
full `SONEXIS_RUNTIME_SOCKET` control-socket path. With defaults, all use
`$DARWIN_USER_TEMP_DIR/sx-$UID/control.sock` (resolved through
the platform's per-user temporary directory API). During the v0.8 migration,
the default Runtime also exposes a guarded compatibility listener at
`/tmp/sonexis-runtime-$UID/control.sock` so protocol-v2 v0.7 clients continue
to work. Both directories must be same-UID private directories; an already-live
legacy Runtime prevents a second default Runtime from starting. Custom socket
directories never create this alias.

The Runtime executable embeds `NSAudioCaptureUsageDescription`, uses the stable
identifier `com.sonexis.runtime`, and is development-signed using the identity
configured in Xcode and selected by the build script. Live
capture uses that identity for macOS Screen & System Audio Recording
permission. The Sonexis application and Runtime have separate permission
identities.

The first `capture` may trigger the macOS prompt. Core Audio does not provide a
reliable permission-specific status for every Process Tap failure, so a denied
grant can surface as the actionable `capture_initialization_failed` error (or
as `permission_denied` when the platform identifies it). Open **System Settings > Privacy & Security >
Screen & System Audio Recording**, enable the signed `sonexis-runtime` entry,
then restart it with `Scripts/runtime-dev.sh stop` and `start`. Verify with an
audible source and `sonexisctl capture SOURCE --debug`; `sources` alone proves
discovery, not Process Tap permission. If a rebuilt binary is shown as another
entry, confirm its signature and stable bundle identifier, grant that entry,
and restart again.

## Architecture

```text
NSWorkspace + Core Audio HAL
            │
            ▼
 endpoint registries ── 1 s source/destination diff monitor ── event hub
            │                                        │
            ▼                                        └─ e-ID.sock (NDJSON)
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
       ├── RuntimeDataPlane (64 packets) ── i-ID.sock (binary PCM out)
       └── o-ID.sock (binary PCM in)
                    │ non-realtime conversion / bounded 500 ms ring
                    ▼
             HAL playback callback ── speakers or loopback input
```

The capture callback only writes preallocated ring storage; the playback IOProc
only reads it. Both callbacks update lock-free counters but do not convert,
publish events, frame packets, log, or perform socket I/O. The existing Sonexis
app shares the registry, Process Tap owner, Core Audio helpers, and ring while
retaining its separate DSP/output lifecycle.

Each capture request owns an independent Process Tap, converter, buffers,
stream socket, counters, and lifecycle—even when two clients select the same
source. Each output owns one producer socket, converter, device route, ring,
IOProc, jitter state, and metrics. Runtime additionally caps output sessions at
eight globally and four per control client; output packets are at most 200 ms.

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
    "runtime_version": "1.0.0",
    "runtime_instance_id": "UUID",
    "capabilities": ["application_sources", "capture_sessions", "event_stream", "format_negotiation", "multiple_sessions", "pcm_v2", "runtime_diagnostics", "runtime_diagnostics_v2", "output_sessions", "output_destinations", "output_pcm_v2", "output_backpressure", "output_flush", "default_device_playback", "output_destination_events"],
    "supported_formats": [
      {"sample_rate": 16000, "channel_count": 1, "sample_format": "pcm_s16le", "interleaved": true}
    ],
    "supported_output_formats": [
      {"sample_rate": 24000, "channel_count": 1, "sample_format": "pcm_s16le", "interleaved": true}
    ],
    "limits": {
      "maximum_control_clients": 32,
      "maximum_sessions": 16,
      "maximum_sessions_per_client": 8,
      "maximum_subscribers_per_stream": 4,
      "maximum_control_message_bytes": 65536,
      "maximum_event_subscriptions": 32,
      "maximum_event_subscriptions_per_client": 4,
      "maximum_output_sessions": 8,
      "maximum_output_sessions_per_client": 4,
      "maximum_output_packet_milliseconds": 200,
      "maximum_output_destinations": 32
    }
  }
}
```

Protocol version 2 remains mandatory in 1.0. Additive optional fields and capabilities may appear without a protocol bump; removing fields or changing semantics requires a later protocol version. Runtime SemVer is independent of protocol version. Request IDs must contain 1–128 UTF-8 bytes. Responses echo the request ID, have their own UUID, and carry exactly the result relevant to the command.

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
- `list_output_destinations`
- `start_output` with `destination_id`, `format`, and target buffering
- `output_status` with `output_session_id`
- `flush_output` with `output_session_id`
- `stop_output` with `output_session_id`

Errors are `{code, message, retryable, details?}`. Output adds errors such as
`output_destination_unavailable`, `output_session_limit_exceeded`,
`output_stream_truncated`, `output_format_mismatch`, and
`output_destination_disconnected`. Malformed input terminates only the
offending connection or output session when framing cannot safely continue.

## Source model

An application source contains a bundle-stable ID (`app.<bundle identifier>`), kind, application name, bundle identifier, all current PIDs, process state, availability, and an optional audio-production heuristic. PID is transient metadata and never source identity. Core Audio object IDs and bundle paths are not exposed.

A physical input source uses `microphone:<Core Audio device UID>`, kind
`microphone`, the device display name, an empty PID list, its compatible native
format when known, and optional `is_default` metadata. The stable UID is exposed
instead of the transient `AudioObjectID`. Microphone capture uses the same
session, normalization, binary frame, backpressure, and cleanup protocol as
application capture. The signed Runtime carries both application-audio and
microphone permission descriptions; macOS grants those permissions separately.

`is_producing_audio` means that one current PID appears in the HAL audio-process list; it is not signal-level detection. `native_format` is currently null because discovery only knows the default-output format, not an authoritative application-native format. The capture response contains the authoritative negotiated Runtime output format.

The source-kind enum supports application and microphone sources and reserves
system mix, remote, and virtual values for future backends.

## Capture sessions and format negotiation

The default is PCM16 little-endian, mono, 16 kHz. The handshake advertises the exact supported set:

- PCM16 mono at 16, 24, or 48 kHz;
- PCM16 stereo at 48 kHz;
- Float32 little-endian mono or stereo at 48 kHz.

Formats are interleaved. Requests must match one advertised combination exactly; otherwise `unsupported_format` includes a compact supported-format list. Conversion uses AVAudioConverter on the capture worker and does not alter the Sonexis app’s native DSP path.

A capture has distinct session and stream UUIDs. The session owns capture lifecycle; the stream identifies binary packets. Session states are `starting`, `capturing`, `stopped`, and `failed`. Stop is idempotent. Control disconnect stops and removes that client’s captures. A source/process or default-output change rebuilds the capture pipeline with the external session ID preserved and marks the next PCM packet discontinuous. Failure is terminal and carries a structured error.

## Output sessions

`output_destinations` exposes `default` plus fixed `coreaudio:<UID>` HAL
outputs. A fixed loopback/virtual device uses kind `virtual_input` only when it
also exposes an input stream and its name/UID matches a known loopback family.
The semantic `default` alias reports the resolved device kind and carries
`active_device_id` as `coreaudio:<UID>` plus its display name. Output supports
the same advertised PCM matrix as capture and converts to the active device
format off the realtime callback. `default` follows route changes and sessions
rebuild for same-device nominal-rate/stream-format changes; fixed devices fail
cleanly when disconnected.

Python and TypeScript expose `find_output_destinations`,
`get_output_destination`, and `wait_for_output_destination` (camelCase in
TypeScript). Resolution is exact ID, exact case-sensitive name, then exact
case-insensitive name. `loopback`/`virtual_input` are kind aliases only when one
available destination is unambiguous. CLI `play --destination` uses the same
policy. A discovery snapshot can race device removal; `start_output` remains
authoritative.

Client audio uses the same 64-byte SXPC v2 envelope in the client-to-Runtime
direction. SDKs split packets to at most 200 ms, serialize sequence numbers,
derive timestamps when needed, and apply socket flow control. Runtime validates
stream identity, sequence/discontinuity, format, payload, and EOS before
conversion. Non-EOS packets must span 1–200 ms. A 500 ms device-rate ring and configurable 20–250 ms start target
bound burst jitter. Full details, SDK examples, cancellation/flush behavior,
metrics, and feedback limitations are in [output audio](output-audio.md).

Output states are `starting`, `ready`, `draining`, `stopped`, `cancelled`, and
`failed`. EOS drains converter tail and buffered PCM. Stop/cancel discards it.
Flush rotates the stream UUID/socket and is the nonterminal barge-in primitive;
only its creating connection may perform that cooperative stream rotation.
Output events include started, stopped, failed, cancelled, underrun, overrun,
dropped, and active-session destination changed. Global destination snapshots
add `output_destination_added`, `output_destination_removed`,
`output_destination_updated`, and `output_default_changed`. The last event is
emitted only when the default alias's stable resolved device ID changes. A
removal event carries the last known destination snapshot; its event type is
authoritative. Global polling and per-session HAL callbacks use different
queues, so their cross-plane arrival order is deliberately unspecified.

## Runtime events

`subscribe_events` creates a separate `events-UUID.sock`; connecting to it yields bounded NDJSON events. Separating events from control responses avoids asynchronous writer interleaving and lets request traffic remain usable when a watcher is slow.

Implemented event types:

- `source_added`, `source_removed`, and `source_updated`, based on serialized registry snapshot diffs;
- `capture_started`, `capture_stopped`, and `capture_failed`;
- `device_changed` after a capture successfully rebuilds for a default-output-device change;
- `client_warning` and `runtime_warning` when emitted by the corresponding subsystem;
- `runtime_shutting_down`, delivered best-effort before sockets close.
- output lifecycle/backpressure events listed in the output section. v0.3
  clients using the legacy implicit event set do not receive new output event
  types unless they subscribe explicitly. The current Python and TypeScript SDKs
  explicitly request every event they understand by default.

Permission-change and signal-level audio-start/stop events are deliberately not advertised because the Runtime cannot determine those transitions reliably. Each delivered event includes an event UUID, monotonic timestamp, per-subscription `event_sequence`, and relevant typed source/session/error data. `dropped_events_before` reports events lost before that delivery, including the subscribe-to-data-socket attach window. Subscriptions are capped, owned by their control connection, and disappear on disconnect.

Ordering is defined only within a plane: control responses follow request IDs on
one control connection, and event sequence is monotonic within one subscription.
No wire-order guarantee exists between a control response and a related event on
its separate socket; correlate source/session/stream IDs instead.

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
- output SDK writes await socket flow control; Runtime's 500 ms playback ring
  waits at most two seconds for capacity before dropping and counting only the
  newest tail. No output queue grows without bound.

The next successful PCM packet after a known drop carries discontinuity and drop count. Session status separates ring drops, delivery drops, data-queue drops, frames produced with no subscriber, slow-consumer disconnects, queue high-water, connected subscribers, and bytes transmitted. One stuck consumer cannot grow Runtime heap without bound or block the HAL callback.

## Python SDK

The primary public package is under `SDKs/python`, requires Python 3.9+, and has no core runtime dependencies:

```sh
/usr/bin/python3 -m venv --system-site-packages .venv
. .venv/bin/activate
python -m pip install --no-deps --no-build-isolation -e SDKs/python
```

```python
from sonexis import Sonexis

async with Sonexis() as sx:
    async with await sx.capture("Discord") as stream:
        async for frame in stream:
            print(frame.source.name, frame.session_id, frame.timestamp_ns)
```

Strings resolve exactly by Runtime ID, bundle ID, or application name; integers resolve PIDs. Ambiguous names fail explicitly. `find_sources`, `get_source`, and `wait_for_source` support discovery and delayed launch. Frames carry their immutable source snapshot and session identity without enlarging the binary wire frame.

`sx.session()` combines independent captures into a bounded labeled iterator
without mixing their audio. `sx.playback()` creates a typed `AudioOutput`, and
`sx.duplex()` owns one capture and output without imposing agent policy. Its
provider-neutral default output format matches the input format.
Provider-specific input/output format presets prevent repetitive format
mistakes. `ReplayStream`, `measure_activity`, `AudioActivityDetector`, and
`LatencyTracker` support
deterministic development and diagnostics. Optional OpenAI/Gemini adapters and
the reference audio agent remain outside Runtime core; see
[AI integration](ai-integration.md).

Control requests are correlated by ID through one reader task, so concurrent
requests are safe. Capture and event streams are async iterators/context
managers. Cancelling an ambiguous mutating request closes the owner connection,
which makes Runtime clean up any resource that may have been created after the
caller stopped waiting. Read-only cancellation keeps the connection usable.
Failed data-socket attachment rolls the Runtime resource back. `reconnect()`
creates a fresh control connection; it never pretends that terminated captures
resumed.

Run SDK tests with `Scripts/test-python-sdk.sh`. `Examples/python-runtime-monitor.py` is the SDK-only reference application; it selects a source, watches lifecycle events, displays statistics, and optionally writes PCM or PCM16 WAV. `Examples/python-runtime-client.py` is a smaller compatibility example that also uses only public SDK APIs.

## TypeScript SDK

`SDKs/typescript` contains a dependency-free-at-runtime Node 18+ client with typed sources, formats, sessions, errors, events, async audio iteration, EventEmitter hooks, bounded SDK queues, and cleanup. On a Node-equipped machine:

```sh
cd SDKs/typescript
npm install
npm run build
npm test
```

The TypeScript client also provides destinations, bounded binary output,
EOS/drain, flush, cancellation/AbortSignal, metrics, and duplex ownership. It
is compiled, tested, packed, and imported from a clean temporary consumer by
the v0.5 release gate.

## MCP control

The optional Python MCP server exposes Runtime metadata, source lookup,
diagnostics, and output-destination discovery. Its default inventory is
read-only. `--allow-capture` additionally registers start/list/get/stop tools,
restricted to captures owned by that MCP process. Results omit private
data-socket paths and return bounded JSON error text. An external SDK attaches
by session ID over the normal binary data plane. MCP uses stdio and never
transports PCM. The server uses the official `mcp` Python package and requires
Python 3.10+.

## CLI and diagnostics

```sh
sonexisctl sources [--json]
sonexisctl status [session-id] [--json]
sonexisctl diagnostics [--json] [--output private-file.json]
sonexisctl watch [--json]
sonexisctl capture SOURCE [--sample-rate Hz] [--channels 1|2] \
  [--sample-format pcm_s16le|float32_le] [--output FILE] [--debug]
sonexisctl stop SESSION [--json]
sonexisctl outputs [--json]
sonexisctl play FILE [--destination ID] [--target-buffer-ms 20...250] [--debug]
sonexisctl output-status SESSION [--json]
sonexisctl output-stop SESSION [--json]
```

`--json` emits one UTF-8 JSON value per line with lower-snake-case keys. The
`sources` and `outputs` commands return arrays; `status`, session commands,
`play`, and `diagnostics` return the corresponding typed object; `watch` emits
one event object per line until stopped. Successful values are not wrapped in
an `ok` envelope. On failure the CLI exits nonzero and emits
`{"ok":false,"error":{"code":"...","message":"...","retryable":...}}`.
Consumers should key on `error.code`, tolerate additive fields, and not parse
human-readable output or error prose.

Runtime status additionally reports current/peak RSS, open descriptors,
threads, control-client/request/error totals, endpoint-monitor health,
retained/reserved resources, data-plane attachments, capture drop categories,
and output loss/flush/late/underrun/overrun/route/conversion categories. The
legacy `total_output_frames_dropped` means all discarded frames; use
`total_output_frames_lost` for reliability loss and
`total_output_frames_flushed` for intentional barge-in discard.
When `runtime_diagnostics_v2` is advertised, `exact_counters` contains decimal
string mirrors for every `UInt64` status field so JavaScript consumers can use
`BigInt` without losing precision. Session metrics also carry
`exact_counters`; session start time, event timestamp/sequence/drop counts, and
frame-drop totals have named decimal-string mirrors. SDK consumers talking to
an older Runtime must gate these additive exact values and other v0.8 fields on
capabilities or field presence; Python retains legacy zero defaults for source
compatibility. Uptime and endpoint last-success timestamps use the monotonic
boot clock and are nanoseconds, not wall time.
Conversion nanoseconds are cumulative work duration. Accepted minus
disconnected control clients equals active clients; rejected clients are a
separate total.

`diagnostics` creates a versioned point-in-time support snapshot. Its generation
time is both RFC 3339 text and Unix-epoch milliseconds (a JSON-safe integer),
never an epoch-nanosecond JSON number. `--output`
uses a private `0600` regular file, refuses symbolic links, and writes no PCM,
provider/transcript text, environment variables, credentials, source names, or
data-socket capabilities. JSON-mode CLI failures return a structured error
envelope and a nonzero exit status.

Output session status reports
queue depth/high-water, buffered duration, conversion time, route changes,
underruns, overruns, late frames, producer attachment, session uptime, active
device format, and estimated software-queue plus HAL latency. The estimate
excludes provider/network, Bluetooth codec, and acoustic latency. Counters are
sampled off the realtime callback.

## Security and trust model

- The Runtime uses only `AF_UNIX`; it does not bind TCP or public-network interfaces.
- The default socket directory lives below macOS's private per-user temporary
  directory. It must be a real directory owned by the current UID and is forced
  to mode `0700`; sockets are mode `0600`.
- Accepted peers must match the Runtime's real UID (`getpeereid` versus
  `getuid()`; equal to the effective UID in the supported nonprivileged launch
  model). Descriptors use `FD_CLOEXEC`.
- Swift clients reciprocally authenticate the Runtime peer UID. Python and
  TypeScript validate a same-UID socket node in a private same-UID directory
  before and after connection.
- An owner lock serializes Runtime startup. Existing live sockets are never
  replaced. Strictly named stale session sockets are reaped only while holding
  that lock, and shutdown unlinks only the device/inode originally bound by the
  listener.
- Pre-handshake clients have an absolute five-second hello deadline, so partial
  trickle input cannot retain a slot. Post-handshake reads remain idle-capable
  for long-running SDKs, while every control response has a bounded send
  deadline so a non-reading peer cannot retain a worker forever.
- Control messages, PCM packets, clients, sessions, event subscriptions, stream subscribers, and in-process queues have explicit limits.
- Sonexis Runtime trusts the local macOS account. Any accepted same-UID client may query or stop a session by ID; the creating connection owns automatic cleanup and quota accounting. This intentional account-wide management policy keeps `sonexisctl stop SESSION` usable. Any unsandboxed process running as the same user is within the trust boundary and can use the Runtime's granted capture permission or inject audio into an output session. Do not run the Runtime privileged or place its sockets in a shared multi-user directory.
- The same trust boundary applies to output injection. A same-UID client can
  render to speakers or an installed loopback input. Virtual microphone
  selection inside the receiving application is an explicit user action.
- MCP capture mutation is opt-in. Provider credentials come only from process configuration; common credential forms are redacted from provider exception diagnostics. Examples do not persist audio unless an output path is explicitly supplied. CLI/example recordings are private `0600` regular files, reject symbolic-link targets, and should still be treated as sensitive artifacts that may be committed accidentally. `sonexisctl play` rejects inputs larger than 256 MiB.
- Detailed Process Tap lifecycle logging is opt-in through
  `SONEXIS_AUDIO_DEBUG=1`; normal Runtime operation does not persist device UIDs
  or per-session audio metadata.
- `Scripts/test-runtime-release.sh` builds and executes the standalone source,
  SDK, package, stress, TSan, metadata, and Apple Development
  signing gates. The development installer verifies exact managed inventory,
  hashes, stable identifiers, versions, embedded capture metadata, and matching
  Team IDs before replacement or removal. Apple Development signatures are
  local engineering identity, not a substitute for Developer ID signing and
  notarization of a public distribution.

## Troubleshooting

- `connect failed: No such file or directory`: start `sonexis-runtime` or pass the matching socket path.
- `handshake_required`: the first control command must be protocol-v2 `hello`; use an SDK or current CLI.
- `unsupported_format`: select one of `handshake.supported_formats`.
- `source_unavailable`: enumerate again; the application may have terminated between discovery and capture.
- `session_limit_exceeded`: stop captures or wait for another client to disconnect.
- `unexpected_pcm_eof`/`truncated_pcm_stream`: the Runtime or socket ended without a clean EOS; discard the partial packet and reconnect explicitly.
- No audio despite a running source: verify Screen & System Audio Recording permission for the Runtime executable’s identity.
- `unsupported_capability` on playback: the connected Runtime predates v0.4.
- `output_destination_unavailable`: rerun `sonexisctl outputs`; a fixed device
  may have disconnected or changed UID.
- Repeated output underruns: increase `--target-buffer-ms`, reduce producer
  jitter, and inspect queue/overrun metrics before increasing it again.
- Loopback missing: install/validate it with the vendor's tooling and reboot if
  required; Sonexis does not install a HAL driver.

## Known limitations

- Signed Process Tap capture remains validated with real Spotify/Chrome audio.
  Real HAL output was exercised against the current headphone default and an
  installed BlackHole device with exact rendered-frame accounting and zero
  drops. Listening, live route changes, and receipt inside Discord/Zoom remain
  in the manual guide.
- Source/audio activity is a HAL-registration heuristic, not level detection.
- Timestamps are stream-relative sample time, not preserved HAL host time; live end-to-end latency is not yet measurable from frames alone.
- Same-source captures use independent Process Taps and are not deduplicated.
- Event sockets and data sockets rely on private per-user filesystem paths rather than a separate attach-token preface.
- The server uses one bounded blocking worker per control client; limits prevent exhaustion, but a future service transport should use nonblocking connection state machines.
- The existing app shares low-level capture infrastructure but does not use the capture-only Runtime session owner.
- SDK packages are repository-local and unpublished. Authenticated Gemini input
  and output-transcription behavior was validated in v0.3; generated response
  audio routed through the new v0.4 playback plane still requires the manual
  validation guide. The official MCP dependency was imported and its tool
  schemas were validated, but no third-party MCP host was used end to end.
- Protocol v2 retains numeric JSON values for compatibility, but every public
  nanosecond/counter field that can exceed JavaScript's safe integer range now
  has a decimal-string exact mirror. TypeScript uses those mirrors for
  `bigint`; binary PCM timestamps are already `bigint`.
- Protocol v2 began as the developer-preview contract and is now the stable
  1.0 wire contract. Future incompatible changes require a new protocol version
  rather than adding required v2 fields.
- The current Runtime has generic loopback-device routing but no bundled `Sonexis Agent Input`
  driver. See [virtual device design](virtual-audio-device-design.md).
- Sonexis prevents an internal digital loop for process-specific capture but
  does not implement acoustic echo cancellation, automatic muting, or ducking.

See [runtime benchmarks](runtime-benchmarks.md) for measured offline performance and remaining live measurements.
