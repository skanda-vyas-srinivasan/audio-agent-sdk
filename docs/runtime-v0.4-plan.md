# Sonexis Runtime v0.4 implementation plan

## Worktree and baseline

Runtime v0.4 is being developed in the isolated worktree
`/Users/skandavyas/Sonexis-runtime-v04` on branch
`runtime-v0.4-bidirectional-audio`. The branch starts at `75f4383`, the final
v0.3 Gemini hybrid-VAD validation commit. The user's original Sonexis worktree
and its unrelated AutoPitch, VoxCent, and UI changes are outside this worktree
and must remain untouched.

## v0.3 architecture

v0.3 is a signed, headless macOS process with a provider-neutral capture core.
It exposes protocol v2 over private same-user Unix-domain sockets:

- newline-delimited JSON for handshake, control, diagnostics, and events;
- one binary socket per capture stream using the 64-byte `SXPC` PCM header;
- independent Process Taps, normalization, bounded delivery, and session
  ownership per control client;
- public async Python and TypeScript SDKs above that protocol; and
- optional OpenAI, Gemini, replay, MCP-control, and reference-app layers above
  the SDK rather than inside the Runtime.

Capture's HAL callback only writes to a preallocated C SPSC ring. Conversion,
framing, sockets, diagnostics, providers, and file I/O happen away from the
realtime thread. v0.4 preserves that boundary and does not change the capture
data plane.

## Bidirectional architecture

v0.4 adds output as a sibling of capture, not as a capture-session mode:

```text
SDK producer
    |
    | protocol-v2 output control + client-to-Runtime binary PCM
    v
RuntimeOutputCoordinator
    |
    +-- bounded ingest and format validation
    +-- non-realtime AVAudioConverter
    +-- bounded Float32 SPSC jitter ring
    |
    v
HAL output IOProc -> default macOS output

RuntimeOutputCoordinator -> reviewed driver transport -> Sonexis Agent Input
                                                   (development prototype)
```

Public concepts are `AudioOutputDestination`, `AudioOutputInfo`,
`AudioOutputMetrics`, and `AudioOutput`. Capture and output remain independently
usable. A small `DuplexSession` only composes the two public primitives.

## macOS output mechanisms considered

### Default-device playback

The first backend uses `AudioDeviceCreateIOProcID` and the existing lock-free C
ring-buffer design. This is preferred over scheduling `AVAudioPlayerNode`
buffers because the HAL pull callback provides a small, explicit realtime
surface, deterministic silence on underrun, bounded storage, and direct atomic
metrics. A new hardened callback owner is required; the app's legacy
`AudioOutputEngine` uses unretained callback state and is not safe to reuse as a
daemon session owner without lifecycle changes.

PCM decoding and `AVAudioConverter` work run on the ingest/lifecycle queue.
The IOProc only reads Float32 samples from preallocated storage and zero-fills
the remainder. The simplest v0.4 ownership model is one IOProc and ring per
output session, under a conservative global/session-per-client limit. HAL
performs final device mixing.

The backend observes default-device and active-device changes. A route rebuild
stops and destroys the old callback before replacing callback-visible storage,
drops incompatible queued audio with accounting, rebuilds conversion for the
new format, re-primes, and emits a destination-change event. A failed IOProc
destroy intentionally retains callback state rather than risking use-after-free.

### Virtual application input

The supported macOS virtual-device mechanism is a HAL AudioServerPlugIn bundle,
not a public-network service and not a fake microphone implemented in the app.
The design target is an input-only device named `Sonexis Agent Input`. Its
realtime callback reads a bounded shared-memory SPSC ring and emits silence if
the Runtime is absent. Installation is an explicit, sudo-visible development
operation into the system HAL plug-in location; ordinary builds and tests never
install it.

The driver is higher risk than default playback. It will be implemented only
to the point that its HAL properties, callback ownership, transport permissions,
signing, install/uninstall, and failure behavior can be reviewed honestly. Any
remaining host reload, signing, or manual application-selection requirement is
called out rather than represented as automated validation.

## Protocol changes

Protocol v2 remains wire-compatible. v0.4 adds capabilities and optional
commands rather than changing existing capture fields:

- `list_output_destinations`
- `start_output`
- `output_status`
- `stop_output`
- `flush_output`

An output response has a distinct output session ID, stream UUID, destination,
negotiated input format, producer socket path, lifecycle state, timestamps, and
metrics. Output sessions are never returned in the capture-only `session`
field. The handshake advertises supported output formats/destinations and new
resource limits.

The data plane reuses the version-2 64-byte `SXPC` frame layout in the opposite
direction. Its stream UUID binds packets to the created output session;
sequence, timestamp, length, format, discontinuity, drop count, and EOS retain
their existing meanings. Output accepts exactly one producer per stream. It
rejects mismatched formats, stream IDs, oversized/partial frames, non-advancing
sequences, unmarked gaps, data after EOS, and frames longer than the documented
packet-duration bound.

## Queue, jitter, and timing policy

There is no unbounded application queue. The data socket has the operating
system's bounded buffer and feeds a fixed-capacity native ring. The default
playback reservoir targets approximately 60 ms and has a hard capacity of
approximately 250 ms, configurable within safe limits at session creation.

When a producer outruns playback, the newest incoming tail is dropped. This
keeps already queued ordering stable and prevents old responses from growing
without bound. Partial writes are counted as output overruns and dropped sample
frames. Initial playback and recovery after a true underrun wait for the target
fill; the IOProc returns silence while gated. Arrival timestamps are diagnostic,
not a command to schedule against a globally synchronized media clock.

EOS stops ingress and drains for a bounded interval before normal completion.
`cancel` stops immediately and discards queued audio. `flush` discards queued
audio while keeping the session open and re-arms initial buffering, which is the
primitive applications use for barge-in. All operations are idempotent.

Metrics distinguish frames/bytes received, converted, queued, rendered,
overflow-dropped, flushed, late, underrun frames/events, queue high-water,
buffered duration, conversion time, route changes, and uptime. No callback
logs synchronously; events are edge-triggered and published from a non-realtime
queue.

## SDK and application design

Python is the primary public API:

```python
async with Sonexis() as sx:
    async with await sx.playback(sample_rate=24_000, channels=1) as output:
        await output.write(pcm)
        await output.drain()
```

`write` splits large aligned buffers into bounded packets, serializes writes,
and obeys socket backpressure without exposing sockets. `close` sends EOS and
performs bounded cleanup; `cancel` and `flush` map to explicit Runtime control.
The TypeScript client uses the same lifecycle and framing. Provider adapters do
not own playback: their existing `ProviderEvent.audio` chunks are routed into
the common Sonexis output session by examples.

The audio-agent example gains a response destination option used by both
Gemini and OpenAI. A duplex convenience object owns a capture stream and output
stream but introduces no model policy. The CLI lists destinations, plays WAV
or raw PCM, reports output status, and stops/flushes output sessions through the
same protocol.

## Realtime safety and ownership risks

The principal risks are callback use-after-free, freeing a ring after a failed
IOProc destroy, locks/allocations in render callbacks, converter calls from
multiple queues, queue growth hidden by socket buffering, teardown invoked from
the ingest queue, stale-format data after a route change, and EOS stopping
before queued sound renders.

The invariants are:

1. One non-realtime producer owns each SPSC ring's write side.
2. The IOProc performs only preallocated C-ring reads and atomic accounting.
3. Socket parsing, conversion, allocation, events, logging, and Swift
   concurrency never run in the IOProc.
4. Production stops before data-plane and callback storage teardown.
5. Callback context is retained until HAL confirms successful IOProc destroy.
6. Every queue, frame, client, and session has a fixed limit.

## Echo and feedback

Application Process Taps capture selected target processes, and the Runtime
process is not part of those targets, so normal Runtime playback does not
digitally re-enter a Chrome or Discord application tap. This is useful isolation,
not acoustic echo cancellation. A physical microphone can still hear speakers,
and routing `Sonexis Agent Input` into an application that is also captured can
create an intentional digital loop. v0.4 exposes `flush`/`cancel`, output
activity events, destination selection, and example-level mute-while-speaking
policy hooks. It does not claim full AEC or force one conversation policy.

## Testing strategy

- Protocol tests cover all output DTOs/commands plus fragmented, truncated,
  oversized, wrong-stream, wrong-format, sequence-gap, EOS, and post-EOS input.
- A synthetic output backend tests control/data-plane lifecycle without playing
  system audio.
- C-ring and converter tests cover burst, underflow, overflow, re-prime, flush,
  PCM16/Float32, mono/stereo, and 16/24/48 kHz.
- Integration tests cover create/write/EOS/stop, duplicate stop, disconnect
  cleanup, multiple sessions/clients, stalled writers, and Runtime shutdown.
- Python and TypeScript tests cover framing, context cleanup, cancellation,
  backpressure, flush/cancel, provider-audio loopback, and duplex ownership.
- Stress runs cover 1,000 start/stop cycles, bursts, slow/fast producers,
  descriptor/session/task leaks, and simultaneous capture/output teardown.
- All existing v0.1-v0.3 suites, signed Runtime/CLI builds, Python tests, and
  TypeScript build/tests run before completion.
- Hardware playback, route changes, headphones, provider voice loopback, and
  virtual-device application selection use an explicit manual validation guide;
  reports distinguish completed automation from pending manual checks.

## Performance goals

- fixed memory per output session;
- no realtime-thread allocation, lock, IPC, logging, or conversion;
- default buffering near 60 ms, hard buffered-audio cap near 250 ms;
- offline ingest/conversion faster than realtime for all advertised formats;
- observable zero-drop steady playback with a correctly paced producer;
- bounded behavior and explicit counters for an arbitrarily fast producer; and
- no measurable capture-path regression relative to the v0.3 offline baseline.

Measurements will report Sonexis input, provider/model, and Sonexis output
segments separately. Offline tests do not claim speaker/DAC or cloud latency.

## Security and privacy

Output injection remains local-only and same-UID authenticated. Output session,
client, packet, and buffer limits prevent resource exhaustion. Runtime socket
directories and producer sockets remain owner-only and symlink-safe. The
Runtime never logs or persists PCM. CLI file input is opened as a regular file
without following symlinks where feasible.

A virtual input materially increases risk because any application selected by
the user can consume injected audio. Installation is opt-in and visible,
transport objects are owner-restricted, the driver produces silence without an
authorized Runtime producer, and uninstall targets only the exact Sonexis
bundle. Sonexis does not hide microphone selection or auto-install a driver.

## Staged implementation

1. Add output protocol models, inbound framing, coordinator seam, synthetic
   backend, events, diagnostics, and lifecycle tests.
2. Add the hardened HAL playback backend and deterministic converter/ring tests.
3. Add Python/TypeScript APIs, CLI replay, provider loopback, and duplex helpers.
4. Stress, benchmark, fuzz, and independently review realtime, protocol,
   security, and public API behavior; fix credible findings.
5. Complete the virtual-device design and, if the reviewed HAL/signing boundary
   is responsible in this repository, add its minimal implementation and
   explicit development install/uninstall tooling.
6. Run all regressions and signed builds, then publish v0.4 documentation,
   manual validation instructions, and the final report.

