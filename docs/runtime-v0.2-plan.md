# Sonexis Runtime v0.2 implementation plan

## Current state

Runtime v0.1 provides a headless application registry, one capture-only Process Tap per session, off-realtime AVAudioConverter normalization, bounded delivery, a local Unix-domain control socket, per-session binary data sockets, a synchronous Swift client, and CLI commands for discovery and capture lifecycle. Control messages are bounded NDJSON and PCM packets have sequence and sample-relative timestamps. The existing app shares discovery, tap, and ring-buffer primitives without replacing its proven DSP/output lifecycle.

The Runtime is local-only and its socket directory is owned by the current user with mode `0700`; socket nodes are mode `0600`. Offline integration tests inject synthetic audio and exercise real Unix sockets. Signed Process Tap permission and physical-device behavior remain manual boundaries.

## v0.1 shortcomings

- Protocol version `1` is checked per command, but there is no mandatory handshake, runtime version, capability advertisement, compatibility contract, or resource-limit discovery.
- Responses repeat request IDs but have no distinct response IDs. Errors lack retryability and structured details.
- There is no event subscription; clients must poll sources and sessions.
- Session IDs also implicitly identify streams. PCM headers do not carry a stream UUID, flags, or a drop count, and EOF during a partial frame is not diagnosed.
- Output is fixed to PCM16 mono at 16 kHz throughout the capture stack.
- Session ownership is enforced only during disconnect cleanup; a client that guesses another session UUID can inspect or stop it.
- Active sessions and data subscribers have no explicit caps. The data-plane task queue is bounded, but slow subscribers are disconnected without a client-visible reason.
- Runtime diagnostics are session-local and incomplete. The CLI has no runtime-wide status, JSON output, or event watch mode.
- Python usage is a raw socket example rather than an installable, typed SDK. There is no Node client.
- The blocking control-worker model is bounded to 32 clients but remains a scaling limitation.

## Proposed architecture

```text
application registry ── source snapshots ──► source-diff monitor ──► event hub
        │                                                        ┌──────┴──────┐
        ▼                                                        ▼             ▼
capture manager ── independent capture session ── normalizer   event.sock   control.sock
        │                                         │                             │
HAL callback ── preallocated SPSC ring             └─► bounded data plane ── stream.sock
                                                               │
                                              Python SDK / TypeScript client / CLI
```

Protocol v2 retains separate control, event, and audio planes. A control connection must complete `hello` before any other command. The handshake selects protocol version 2 and advertises runtime version, capabilities, supported audio formats, and resource limits. Event subscriptions receive bounded NDJSON on their own Unix socket so asynchronous events cannot interleave with control responses. Each capture receives distinct session and stream UUIDs.

Capture sessions remain independent, including captures of the same source. This isolates slow consumers and failures and avoids an unmeasured shared-Process-Tap lifetime problem. The creating control connection owns automatic disconnect cleanup and per-client quota accounting. Session status/stop are deliberately available to any accepted same-UID control client, making a standalone `sonexisctl stop SESSION` useful under the Runtime's account-wide trust model. Explicit global/per-owner/subscription/session-subscriber limits bound Core Audio objects, queues, timers, descriptors, and kernel socket buffers.

## Protocol v2

Control requests and responses remain newline-delimited JSON with a 64 KiB limit. Wire fields use explicit lower snake case. Requests contain `message_type`, `protocol_version`, `request_id`, `command`, and command parameters. Responses contain a new `response_id`, echo `request_id`, and contain one typed result or a structured error. The first request must be `hello` with supported versions and client metadata.

Capabilities initially include source discovery, application capture, event subscriptions, negotiated formats, PCM v2 framing, runtime diagnostics, multiple sessions, and bounded backpressure. Stable error objects contain `code`, `message`, `retryable`, and optional string-keyed details.

Events have an event UUID, monotonic timestamp, event type, and optional source/session/stream/error/metrics fields. Reliably implemented events are source add/remove/update, capture start/stop/failure, client warning, device change when observed by a capture, runtime warning, and runtime shutdown. Audio-start/stop and permission-change events are omitted until the platform state can be determined reliably; the source model retains the documented activity heuristic.

PCM v2 uses a fixed 64-byte big-endian header: magic, version, flags, header/payload sizes, 16-byte stream UUID, sequence, timestamp, sample rate, frame count, channel count, sample-format code, and `dropped_before` sample-frame count. Payload samples remain little-endian. Known flags are discontinuity and end-of-stream. The start response associates stream ID with source/session IDs, avoiding repeated variable-length source strings in every packet.

## Audio formats

The default stays PCM16 little-endian, mono, 16 kHz. v0.2 will support formats naturally handled by AVAudioConverter:

- PCM16 mono at 16, 24, and 48 kHz;
- PCM16 stereo at 48 kHz;
- Float32 little-endian mono or stereo at 48 kHz.

The handshake advertises the exact list. `start_capture` accepts one advertised format and returns `unsupported_format` for every other combination. Native capture and the Sonexis application DSP path remain unchanged.

## SDK design

The dependency-free Python package will live under `SDKs/python`, support Python 3.9+, install locally with `pip install -e`, and expose typed dataclasses/enums, `Sonexis`, `CaptureSession`, `AudioFrame`, `RuntimeEvent`, and structured exceptions. One async control reader resolves concurrent requests by request ID. Capture sessions and event subscriptions are async iterators/context managers with deterministic cancellation and cleanup. Reconnect may restore the control connection and event subscription, but never silently recreates captures.

The TypeScript client will use Node's Unix socket APIs and expose typed models, promises, async iteration/events, capture cleanup, and structured errors without runtime dependencies. The current environment has no Node/npm/TypeScript toolchain, so it can receive source-level and protocol-fixture review but cannot be claimed build-tested here.

The reference application will import only the public Python SDK, provide source selection, stream/event monitoring, statistics, optional raw PCM or WAV output, and signal-safe cleanup.

## Testing strategy

- Swift unit tests: handshake/version negotiation, capabilities, source/session models, format validation, v2 header byte layout, flags, sequence/drop behavior, malformed/truncated frames, and JSON fuzz cases.
- Swift integration tests: real Unix sockets with a synthetic backend, event subscriptions and loss reporting, runtime status, same-UID session management, owner-disconnect cleanup, independent streams, multiple clients, slow/non-reading subscribers, session/subscriber limits, abrupt disconnect, shutdown, source diffs, and repeated lifecycle churn.
- Python `unittest`: fragmented/coalesced and out-of-order responses, structured errors, handshake mismatch, concurrent requests, capture iteration, truncated/malformed frames, events, cancellation, reconnect, context cleanup, and multiple streams.
- TypeScript: protocol fixtures and source review now; execute tests when a Node toolchain is available.
- Stress/fuzz: thousands of command/session cycles, descriptor/thread/RSS sampling, invalid UTF-8/types/order/versions/IDs, oversized input, random frame corruption, and queue saturation.
- Full repository build/regression and focused concurrency checks after stabilization. No automated test initiates private live audio capture.

## Performance goals

- No allocation, locks, I/O, logging, conversion, or IPC on the HAL callback.
- All queues have explicit bounds; no sustained memory or descriptor growth during synthetic churn.
- Preserve duration and channel mapping for every advertised format.
- Sustain at least four synthetic 48 kHz stereo streams and multiple clients faster than realtime on the test host.
- Report throughput, framing overhead, conversion cost, delivery latency, RSS, descriptor counts, and slow-client behavior from repeatable synthetic benchmarks. Live capture-to-client latency remains a signed/manual measurement.

## Major risks

- Core Audio teardown and environment-change callbacks can race session failure and client cancellation.
- Source polling must distinguish reliable lifecycle changes from HAL activity heuristics.
- Events and responses must never interleave on a control writer; separate event sockets avoid that failure mode.
- JSON integers above JavaScript's safe range remain a TypeScript limitation; binary PCM timestamps use `bigint`, while a future protocol should encode control/event `u64` values as decimal strings.
- A nonblocking socket may fail after a partial packet. The client must report truncated data, and the next successful packet after a Runtime-side drop must carry a discontinuity flag/count.
- Same-user processes share the trust boundary. Directory ownership/mode checks, peer-UID checks, unpredictable socket names, owner-scoped cleanup/quotas, and resource limits reject other users and bound accidents, but session IDs are account-wide bearer handles by design.
- The dirty project file contains unrelated AutoPitch/VoxCent work. v0.2 will reuse existing Xcode source entries and avoid modifying or staging unrelated project changes.
