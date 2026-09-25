# Sonexis Runtime v0.3 implementation plan

## Current architecture

Runtime v0.2 is a signed, local macOS process with protocol-v2 NDJSON control,
separate bounded event sockets, and per-capture binary PCM sockets. The reusable
capture core owns application discovery, Core Audio Process Taps, realtime-safe
rings, AVAudioConverter normalization, lifecycle recovery, and diagnostics.
Python and TypeScript clients expose typed sources, sessions, events, and framed
audio without exposing Core Audio concepts.

The wire model already preserves the essential identity relationship: a capture
response associates source, session, and stream IDs, while each fixed-size PCM
header carries stream ID, sequence, stream-relative timestamp, format,
discontinuity, and known loss. The Runtime intentionally uses one independent
tap and bounded delivery path per capture. The local trust boundary is the
current macOS user account.

## Gaps for AI applications

- `capture(str)` currently treats every string as a Runtime source ID. Human
  names, bundle identifiers, and PIDs require application-side boilerplate.
- Frames retain stream and format fields but not their resolved source or
  session context in the public SDK object.
- There is no small abstraction for multiple labeled, independently timed
  streams.
- Provider examples would currently duplicate format selection, base64/message
  encoding, cancellation, and error translation.
- There is no deterministic replay stream for provider and agent testing.
- Diagnostics stop at Runtime transmission; SDK receive and provider-send times
  are not represented.
- No agent-friendly control adapter exists. Realtime PCM must not be routed
  through a low-bandwidth tool protocol.
- Failure classes do not yet distinguish source ambiguity, provider failures,
  or clean end-of-stream from unexpected transport termination at the public
  API level.

## Proposed v0.3 architecture

```text
macOS applications
        │
        ▼
capture core ──► Runtime protocol v2 ──► Python / TypeScript SDK
                                             │
                         ┌───────────────────┼──────────────────┐
                         ▼                   ▼                  ▼
                 labeled sessions     replay streams     MCP control
                         │                                      │
                         ▼                                      └─ no PCM
                RealtimeAudioSink
                   ┌─────┴─────┐
                   ▼           ▼
             OpenAI adapter  Gemini adapter
```

Protocol v2 remains compatible. Source resolution, metadata enrichment,
multi-source orchestration, provider format presets, replay, and provider
tracing are SDK concerns. Runtime changes are allowed only for concrete missing
control/diagnostic primitives and must be additive.

The primary Python API stays compact:

```python
async with Sonexis() as sx:
    async with await sx.capture("Discord") as stream:
        async for frame in stream:
            print(frame.source.name, frame.session_id, frame.timestamp_ns)
```

Strings resolve in this order: exact source ID, exact bundle identifier, exact
application name, then case-insensitive exact application name. PIDs and
`AudioSource` values are explicit alternatives. A result must be unique;
ambiguity is a structured error rather than a guess. `find_sources`,
`get_source`, and `wait_for_source` share the same matching rules.

`MultiSourceSession` owns independent capture sessions and pump tasks. Each
output is labeled and retains its `AudioSource`; streams are never implicitly
mixed. Its application queue is bounded and accounts local drops. Independent
stream-relative timestamps are exposed as-is. Sonexis does not promise
sample-accurate alignment across applications.

## Provider abstraction

`RealtimeAudioSink` is a deliberately thin optional interface: connect, send an
`AudioFrame`, receive provider events, and close. Provider packages live under
the Python SDK's optional adapter namespace and never enter the Runtime or
capture core. Each adapter validates the negotiated Sonexis format, reads
credentials only from environment/configuration, translates provider failures
to structured exceptions, and accepts an injectable transport/session for
network-free tests.

Format presets live in the SDK (`speech_16k`, `openai_realtime`, and
`gemini_live`) and compile to ordinary protocol-v2 `AudioFormat` values. The
Runtime advertises and validates the actual supported combinations; adapters do
not override it.

## Agent-facing abstraction

A small optional stdio MCP server exposes only low-bandwidth source, session,
and diagnostic control. Tool arguments are validated and errors remain
structured. It uses the public Python SDK and shares its same-user Unix-socket
trust model. Audio sockets and PCM bytes are never returned through MCP. A
capture started by MCP remains owned by the MCP process; an audio consumer must
use the SDK/data plane.

## Stream and trace semantics

SDK `AudioFrame` values add immutable source and session context resolved once
when capture starts. This does not enlarge wire frames. They also record SDK
receive monotonic time. A trace sample may contain:

- Runtime session start plus stream-relative audio timestamp (an estimate, not
  a preserved HAL host timestamp);
- SDK receipt time measured with the local monotonic clock;
- provider-send time measured immediately before transport submission.

Percentiles are computed off the audio path from bounded trace samples. Live
application-to-client latency still requires preserved HAL host timestamps and
external measurement; documentation must not relabel estimates as capture
latency.

## Replay and activity

`ReplayStream` reads PCM/WAV into normal source-aware `AudioFrame` objects with
deterministic sequence and timestamps. Realtime pacing is optional so tests can
run quickly. It exercises SDK consumers and provider adapters without Core
Audio, but is not presented as a Process Tap test.

Lightweight RMS/peak activity analysis may run in consumers or worker tasks. It
must not enter the HAL callback. v0.3 will expose a pluggable VAD protocol and
an activity helper; it will not market a hand-written energy threshold as
speech recognition.

## Testing strategy

- Python unit tests: every source selector, ambiguity, wait/timeout/relaunch,
  source-aware frames, presets, replay, activity, trace percentiles, failure
  mapping, cancellation, and bounded multi-stream behavior.
- Provider tests: injected fake transports/sessions, exact audio messages,
  format validation, remote errors, receive events, cancellation, and cleanup.
- MCP tests: initialize/tool schemas, invalid inputs, Runtime unavailable,
  source/diagnostic calls, capture lifecycle, and proof that no tool returns
  PCM.
- Runtime integration: existing protocol/core/fuzz/stress suites plus a
  deterministic AI-consumer soak with pauses, reconnects, drops, descriptors,
  tasks, and session cleanup.
- TypeScript: compile and run tests when Node tooling is locally available;
  extend source resolution and source-aware frame fixtures without adding
  runtime dependencies.
- Full Sonexis offline regression after focused tests. Live provider calls are
  manual unless credentials are explicitly supplied; no secret is logged or
  persisted.

## Performance goals

- No change to the HAL callback or native capture/DSP path.
- SDK and multi-stream queues remain explicitly bounded.
- Metadata enrichment performs no per-frame source lookup or control request.
- Adapter encoding sustains at least four 48 kHz streams faster than realtime
  in deterministic benchmarks.
- Trace collection uses bounded storage and is disabled or inexpensive by
  default.
- AI-consumer soak shows bounded RSS, descriptors, tasks, and Runtime sessions.

## Major risks

- Friendly-name resolution can become surprising; exact matching and explicit
  ambiguity errors are mandatory.
- A source relaunch can preserve a bundle-stable ID while changing PIDs. Waiting
  resolves a fresh source snapshot rather than reusing stale process metadata.
- Independent Process Taps do not share a clock contract exposed by protocol
  v2. Cross-source timestamps may be compared for coarse ordering only.
- Breaking from async iteration must clean up pump tasks, sockets, and Runtime
  sessions even under cancellation.
- Provider APIs evolve independently. Adapters isolate message schemas, use
  optional dependencies, and require mock tests plus clearly labeled manual
  network validation.
- Starting capture through an agent tool grants access to sensitive local
  audio. MCP stays same-user/local, never returns samples, requires explicit
  source selection, and does not persist audio or credentials.
- The project file and working tree contain unrelated AutoPitch/VoxCent/UI
  changes. v0.3 changes must be staged by explicit path/hunk and must never
  reset, stash, reformat, or commit those changes.
