# Sonexis Runtime v0.2 report

## Summary

Sonexis Runtime v0.2 is a local, headless macOS application-audio developer platform. A separate process can negotiate protocol v2, discover application sources, start multiple independent captures, consume timestamped PCM from bounded binary streams, observe lifecycle/source/runtime events, inspect diagnostics, and stop cleanly without importing Core Audio code.

The default remains PCM16 mono at 16 kHz. Negotiated outputs also include PCM16 mono at 24/48 kHz, PCM16 stereo at 48 kHz, and Float32 mono/stereo at 48 kHz. The existing Sonexis application continues to share the registry, tap engine, Core Audio helpers, and realtime ring without moving its DSP/output path through Runtime normalization.

The repository now includes an async Python SDK, a typed TypeScript/Node client, an SDK-only Python monitor application, a useful CLI, synthetic integration/stress/fuzz tests, repeatable offline benchmarks, and explicit security/backpressure policies.

## Architecture

```text
Core Audio Process Tap
        |
        v
preallocated SPSC ring -- HAL callback does no locks/allocation/I/O/logging
        |
        v
capture worker -- AVAudioConverter -- bounded delivery queue
        |
        v
RuntimeDataPlane -- PCM v2 framing -- per-session Unix socket
        |
        +--> Python SDK / TypeScript client / sonexisctl / external application

AudioSourceRegistry --> source-diff monitor --> bounded event sockets
Runtime control socket --> handshake, requests, sessions, status, subscriptions
```

Every capture has distinct session and stream UUIDs, buffering, sequence/timestamp state, drop counters, data socket, normalizer, and Process Tap. Capturing the same source twice intentionally creates independent taps in v0.2; this is simpler and safer than unmeasured shared-tap multiplexing.

## Protocol

- Mandatory `hello` selects protocol version 2 and returns Runtime version `0.2.0`, instance UUID, capabilities, formats, and limits.
- Requests have `request_id`; responses have an independent `response_id`, echo the request ID, and return a typed payload or `{code,message,retryable,details}` error.
- Control and event messages are bounded 64 KiB NDJSON on separate Unix sockets.
- Unknown commands return `unsupported_command`; malformed types/JSON and oversized messages fail safely.
- Events have UUID, monotonic timestamp, per-subscription delivery sequence, and `dropped_events_before`. Typed source/session/error payloads are included where applicable.
- PCM uses a documented fixed 64-byte big-endian header followed by little-endian samples. It carries stream UUID, packet sequence, sample-relative nanoseconds, format, frame/payload sizes, discontinuity/EOS flags, and known prior drop count.
- Runtime v2 is a developer-preview contract finalized by this milestone. Later incompatible wire changes must use a new protocol version.

## SDKs

Python:

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

The Python package supports Python 3.9+, concurrent correlated requests, typed models/errors/events, async iteration/context management, explicit reconnect, cancellation-safe late-response discard, bounded cleanup, and rollback when data/event socket attachment fails.

TypeScript:

```typescript
const sx = await Sonexis.connect();
try {
  const sources = await sx.sources();
  const stream = await sx.capture(sources[0]);
  for await (const frame of stream) console.log(frame.timestampNs, frame.data.length);
} finally {
  await sx.close();
}
```

The dependency-free runtime client provides typed sources/sessions/status/events/errors, promises, async iterators, EventEmitter delivery, bounded queues, truncation detection, and bounded Runtime cleanup. Package output paths were corrected and separate build/test TypeScript configurations were added. Node/npm/tsc are not installed on the validation host, so the package received source/protocol review but not an executed TypeScript build.

`Examples/python-runtime-monitor.py` is the substantial external reference application. It uses only public Python SDK APIs, selects a source, watches events, displays stream statistics, and optionally writes raw PCM or PCM16 WAV.

## Concurrency

- The HAL IOProc only writes to preallocated ring storage and relaxed atomic counters.
- AVAudioConverter, Swift allocation/ARC work, framing, event publication, logging, disk output, and socket syscalls run off the realtime callback.
- Capture lifecycle is serialized per session; backend startup is registered before it can synchronously terminate.
- Runtime shutdown first blocks and quiesces in-flight starts, tears sessions down, then publishes the terminal shutdown event.
- Capture stop is idempotent and waits for previously accepted delivery callbacks except during safe reentrant stop.
- Unread native ring backlog during teardown/rebuild is counted as loss and advances the normalized timeline.
- Source monitor startup is generation-checked so start/stop races cannot leave an orphan timer.

## Backpressure

- Native ring: approximately two seconds; drop newest native frames when full.
- Capture delivery: 32 frames; drop newest and mark the next delivered frame discontinuous.
- Runtime data plane: 64 packets; drop newest when full.
- Data subscriber writes are nonblocking. A partial write or `EAGAIN` closes that subscriber to preserve framing for others.
- Maximum four subscribers per stream.
- Event delivery: 256 messages. Overflow and pre-attach loss are counted; the next delivered event reports the loss.
- Event subscriptions: maximum 32 globally and four per control client.
- Client iterator queues are bounded. TypeScript EventEmitter-only consumers do not also accumulate an unused iterator queue.

PCM/session diagnostics expose ring, delivery, queue, and no-subscriber drops separately, plus slow-client disconnects and queue high-water marks. Runtime lifetime totals remain monotonic after session cleanup/pruning.

## Testing

Commands executed successfully:

```sh
Scripts/test-runtime-core.sh
Scripts/test-runtime-protocol.sh
Scripts/test-runtime-integration.sh
Scripts/test-runtime-fuzz.sh
Scripts/test-runtime-stress.sh
Scripts/test-python-sdk.sh
Scripts/test-concurrency-tsan.sh
Scripts/test-all.sh
Scripts/benchmark-runtime.sh

xcodebuild -project Sonexis.xcodeproj -scheme sonexis-runtime \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/RuntimeV02Final CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Sonexis.xcodeproj -scheme sonexisctl \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/RuntimeV02Final CODE_SIGNING_ALLOWED=NO build
```

The complete offline regression matrix passed, including lifecycle/capture, graph/routing, DSP, persistence/workspace, recording, UI logic, and Runtime groups. The app also built with Thread Sanitizer enabled; focused engine lifecycle checks passed without a TSan report. The unrelated AutoPitch/VoxCent/UI working-tree changes were neither staged nor committed by this work.

A real-process smoke test started the built headless Runtime on a temporary socket, used the built CLI to enumerate live application sources and query JSON status, sent SIGINT, and verified the socket node was removed. It deliberately did not start private audio capture.

## Stress testing

The final synthetic run completed:

- 1,000 capture start/stop/idempotent-stop cycles;
- 200 full connect/handshake/disconnect cycles;
- 16 simultaneous sessions across four clients;
- descriptor growth of 1 while still inside deferred Runtime shutdown scope;
- 10,223,616-byte peak RSS versus 6,356,992-byte process baseline peak;
- no active sessions after churn.

Integration/adversarial coverage includes multiple formats and clients, same-source independent sessions, same-UID cross-process stop, owner-disconnect cleanup, duplicate stop, terminal-history pruning, event subscription limits/loss, non-reading data consumers, invalid sources/formats/versions/commands/IDs, oversized/malformed UTF-8/JSON, fragmented/truncated/corrupt PCM, source absence, and repeated server start/stop.

## Security

- Runtime binds only `AF_UNIX`; no TCP listener exists.
- The per-user directory is a real same-owner directory forced to `0700`; socket nodes are `0600`.
- Accepted peers must pass `getpeereid` with the Runtime UID; descriptors use `FD_CLOEXEC`.
- A live socket is never replaced. Shutdown removes only the exact filesystem socket node originally bound, using path device/inode identity.
- Control messages, PCM payloads, clients, sessions, stream subscribers, event subscriptions, and application queues are bounded.
- The trust boundary is the local macOS account. Session IDs are intentionally same-UID bearer handles so a separate `sonexisctl stop SESSION` works. The creating connection still owns automatic disconnect cleanup and per-client quota accounting.
- The Runtime must not run privileged or place its socket directory in a shared multi-user location.

## Performance

On a MacBook Pro `Mac16,1` with Apple M4, 16 GB RAM, macOS 27.0 build 26A428, and Xcode 27.0 build 27A266a, 85.333 seconds of synthetic 48 kHz stereo input normalized between 6,912.7× and 19,900.5× realtime across advertised formats in the final run. PCM framing completed 100,000 encode/header-decode operations in 0.195959 seconds (about 510,311 packets/s and 196.0 MB/s including headers).

These are optimized offline microbenchmarks, not live latency measurements. Full methodology and per-format results are in `docs/runtime-benchmarks.md`.

## Reviews

Architecture/API review found the `process_i_ds` acronym encoding bug, unbounded event subscriptions, silent event loss, decreasing lifetime totals, startup event reversal, socket inode cleanup error, SDK attach leaks, broken TypeScript entry points/lifecycle behavior, missing typed event models, message-size inconsistency, stale source-removal metadata, and ambiguous session management. The implementation now pins `process_ids`, caps/signals events, archives counters, serializes startup events, tracks the path inode, rolls resources back, corrects packaging/typed APIs, aligns the 64 KiB limit, omits stale removal snapshots, and explicitly documents same-UID bearer management.

Realtime/concurrency review confirmed the HAL callback path and SPSC ring invariants, then found SDK cancellation/cleanup races, TypeScript dual-delivery stalls, unbounded event overflow bookkeeping, in-flight shutdown starts, teardown backlog accounting, and stale socket state. These were fixed with bounded synchronous accounting, cleanup state machines/timeouts, consumption-mode-aware queues, start quiescence, backlog drop accounting, and disconnect state transitions.

Adversarial review reproduced cross-client management, 300-subscription descriptor growth before limits, stale socket nodes, reversed synchronous-end events, decreasing totals, backward EOS acceptance, and SDK/parser failure paths. Post-fix probes confirmed four-per-client subscription enforcement, clean socket unlink, single correctly ordered failure events, monotonic totals, 1,000 immediate server restart cycles, backward-EOS rejection, and passing protocol/integration/stress suites.

The cross-client result was retained intentionally under the same-UID trust model rather than presented as connection-scoped authorization. A future stronger boundary needs explicit management/attach tokens, not a change that silently makes standalone CLI stop unusable.

The final post-fix review found and closed one last Python cancellation/EOF cleanup leak. Shielded persistent cleanup tasks now provide exactly-once stop/unsubscribe even if `aclose()` is cancelled, retries await the same cleanup, event EOF unsubscribes, and reconnect waits for client cleanup. The final reviewer reran all nine Python SDK tests with and without `PYTHONASYNCIODEBUG=1`, Runtime integration, and Runtime stress, and reported no remaining realtime/concurrency release blocker.

## Known limitations

- Signed Process Tap/TCC behavior, target application termination/restart, physical device switching, sleep/wake, and sustained live multi-application capture still need manual validation.
- Activity is a HAL registration heuristic, not signal-level detection.
- Timestamps are stream-relative sample time, not original HAL host time.
- Same-source captures use independent Process Taps and may hit practical Core Audio limits not measurable offline.
- Runtime uses one bounded blocking worker per control connection.
- Event/data sockets use private per-user paths without attach-token prefaces.
- The existing app shares low-level capture infrastructure but not the capture-only session owner.
- SDKs are repository-local and unpublished.
- TypeScript execution was not validated on this host. JSON nanosecond/counter values also lose JavaScript integer precision beyond `2^53`; binary PCM timestamps correctly use `bigint`.

## Manual validation remaining

On a signed/notarized Runtime identity with Screen & System Audio Recording permission:

1. Capture audible Discord/Spotify/Chrome streams in every advertised format and verify PCM/WAV duration and channel mapping.
2. Measure Process Tap callback-to-client and application-to-client p50/p95/p99 latency using preserved HAL host timestamps.
3. Run sustained one-, two-, and four-application captures while measuring CPU, RSS, descriptors, drops, and device-change gaps.
4. Terminate/restart targets, switch physical output devices, sleep/wake, deny/revoke permission, crash clients, and restart the Runtime.
5. Establish practical limits for independent same-source Process Taps.

No live capture was initiated during automated work, so the report does not claim these platform/TCC results.

## Commits

- `fe22a10` — docs: plan Sonexis Runtime v0.2
- `c361727` — feat: evolve Sonexis Runtime protocol v2
- `2c25a0e` — feat: add Sonexis Python and TypeScript SDKs
- `bf12a1c` — fix: harden Runtime v0.2 lifecycle and SDKs
- `0d80d1a` — docs: complete Runtime v0.2 milestone
- Final cancellation-safety/report refresh — the commit containing this version of the report.

## Next milestone

The next cohesive milestone should be a signed/notarized per-user Runtime service with explicit permission UX, installation/update/uninstall flow, crash restart/log collection, preserved HAL host timestamps, live latency/soak acceptance, and CI/package validation for Python and TypeScript. Broader source types, virtual microphone output, SoundMux, MCP, other operating systems, and optional provider adapters should remain later independent milestones.
