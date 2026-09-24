# Overnight report: Sonexis Runtime prototype

## Result

Sonexis now builds a separate `sonexis-runtime` process and `sonexisctl` client. The Runtime discovers running applications independently of SwiftUI, starts capture-only Core Audio Process Tap sessions, normalizes native Float32 audio to mono 16 kHz PCM16 off the realtime callback, and streams framed PCM over local Unix-domain sockets. Capture can be written to a raw `.pcm` file and stopped from the capture terminal or another CLI process.

The existing Sonexis app builds with the shared source registry, tap engine, Core Audio helpers, and realtime ring. Its DSP, routing, recording, and output ownership remain intact.

Offline unit/integration coverage passes. Live signed Process Tap/TCC validation was not performed; that manual boundary is explicit below.

## Architecture

- `AudioSource` and `AudioSourceRegistry`: bundle-stable source identity plus current PID/activity/format metadata.
- `AudioCaptureManager` and `AudioCaptureSession`: serialized capture-only ownership, idempotent stop, route/source rebuild, bounded delivery, and metrics.
- `RuntimeAudioNormalizer`: AVAudioConverter boundary from native Float32 to PCM16 mono 16 kHz.
- `SonexisRuntimeServer` and `RuntimeSessionCoordinator`: client/session ownership and typed control errors.
- `RuntimeDataPlane`: per-session binary socket with a bounded 64-packet queue.
- `SonexisRuntimeClient`: common transport used by `sonexisctl`.

The HAL callback writes only to the preallocated C ring. Conversion, callbacks, framing, and socket I/O occur on non-realtime queues.

## Example

```sh
xcodebuild -project Sonexis.xcodeproj -scheme sonexis-runtime -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Sonexis.xcodeproj -scheme sonexisctl -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build

.build/DerivedData/Build/Products/Debug/sonexis-runtime
```

In another terminal:

```sh
.build/DerivedData/Build/Products/Debug/sonexisctl sources
.build/DerivedData/Build/Products/Debug/sonexisctl capture SOURCE_ID \
  --output /tmp/sonexis-capture.pcm --debug
.build/DerivedData/Build/Products/Debug/sonexisctl stop SESSION_ID
```

The raw output is signed little-endian PCM16, mono, 16 kHz. The example client is:

```sh
python3 Examples/python-runtime-client.py SOURCE_ID
```

## Files changed

- `Sonexis/RuntimeCore/Capture/`: source model/registry, capture manager/session, frames, normalization, metrics.
- `Sonexis/RuntimeCore/IPC/`: protocol, framing, Unix sockets, server, coordinator/data plane, client.
- `Tools/sonexis-runtime` and `Tools/sonexisctl`: executable entry points.
- `Examples/python-runtime-client.py`: external consumer example.
- `Tests/Runtime*` and `Scripts/test-runtime-*`: unit and real-socket synthetic integration coverage.
- `AudioCaptureTarget.swift` / `AudioCaptureTargetUI.swift`: UI-independent model/discovery split.
- `TapCaptureEngine.swift`: configurable capture-only behavior and safer callback ownership.
- Xcode project/shared schemes: Runtime and CLI products.
- `docs/runtime-plan.md` and `docs/sonexis-runtime.md`: plan and concrete protocol/operation reference.

## Tests

Passed during implementation:

```text
xcodebuild ... -scheme sonexis-runtime ... build
xcodebuild ... -scheme sonexisctl ... build
xcodebuild ... -scheme Sonexis ... build
Scripts/test-group.sh runtime
Scripts/test-concurrency-tsan.sh
Scripts/test-all.sh
.build/DerivedData/Build/Products/Debug/sonexis-runtime
.build/DerivedData/Build/Products/Debug/sonexisctl sources
```

The runtime group verifies source identity, normalization duration/alignment, NDJSON fragmentation/coalescing/malformed limits, binary frame encoding, actual Unix sockets, actual `sonexisctl sources` as a child process, PCM delivery, invalid IDs, idempotent stop, rapid repeated sessions, bounded terminal history, owner-disconnect cleanup, duplicate-runtime refusal, multiple clients, and concurrent sessions.

The concurrency checks passed, including the graph and Audio Unit lifecycle checks. The final full offline suite passed after the review fixes: lifecycle/capture, graph/routing, DSP, persistence/workspace, recording, UI logic, and Runtime. A final real-process smoke test started the Runtime, enumerated the current applications through `sonexisctl`, and verified clean socket removal on shutdown.

## Performance

The realtime IOProc remains a preallocated ring write. Capture diagnostics measure ring backlog/drops, delivery drops, normalized frames/bytes, and conversion batches/time without logging from the callback. The synthetic integration data plane remained bounded during rapid session churn; a reviewer stress run of 50,000 explicit start/stops peaked near 9.4 MB RSS after terminal-history pruning, versus roughly 24 MB at 10,000 before the fix.

No live-device conversion latency or Runtime-to-client throughput number is claimed because live capture was not run.

## Reviews

### Realtime/concurrency

Found callback lifetime risk after failed IOProc teardown, server lifecycle races, an unsynchronized session snapshot, unbounded session retention, descriptor close/I/O reuse, a non-cancellable blocked control request, consumer work on the capture lifecycle queue, and an unbounded hop before the nominal data-plane bound.

Fixes include an explicit HAL-owned retain released only after successful IOProc destruction, listener generations, queue-confined snapshots, bounded terminal records, coordinated descriptor shutdown/close, independently closable client connections, bounded consumer delivery, and direct bounded data-plane handoff.

### Architecture/API

Found source enrichment failure affecting the app picker, lost multi-PID metadata, ambiguous frame metrics, insufficient payload validation, generic capture errors, and documentation claims ahead of the actual v1 protocol.

Fixes preserve NSWorkspace discovery when HAL enrichment fails, expose all PIDs, count PCM sample frames, validate header/payload consistency, translate initialization failures, and document the implemented protocol and app-reuse seam precisely.

### Adversarial testing

Found a reproducible CLI crash, live-socket replacement, listener cleanup deleting another Runtime's socket, oversized-input silent close, terminal-session memory growth, Python EOF/selection bugs, slow-control-client starvation, and a stale-test-binary hazard.

All were fixed or bounded: safe CLI formatting, live-socket probing, listener path ownership, typed oversize errors, 128-record history, exact-read example behavior, idle-client eviction with a 32-client limit, and unconditional incremental CLI builds in integration tests.

## Known limitations

- Live signed capture/TCC permission, target termination/restart, and physical output-device switching still require manual macOS validation.
- Data streams use EOF rather than an explicit EOS frame and do not have attach tokens in protocol v1.
- Timestamps are sample-position-derived, not HAL host timestamps.
- `isProducingAudio` is a HAL-registration heuristic and native format is prospective default-output metadata.
- Same-source captures are independent rather than shared.
- The app shares discovery/tap/ring primitives but not the new capture-only session owner.
- The source/client layer is not yet a packaged public SDK.

## Problems discovered

Core Audio callback ownership must survive teardown errors; ordinary Swift object lifetime is insufficient when an IOProc destroy can fail. A bare Runtime executable also has its own TCC identity, so unsigned offline compilation cannot prove permission UX. Finally, blocking one worker per control socket needs explicit admission control; a future production transport should use nonblocking per-connection state machines.

## Recommended next milestone

Package the protocol DTO/codec/client as a small versioned Swift SDK and complete signed live-acceptance validation first. That milestone should add attach tokens, explicit EOS/discontinuity flags, HAL host-time propagation, shared same-source fan-out, and a nonblocking control connection state machine before adding any AI-provider adapter.
