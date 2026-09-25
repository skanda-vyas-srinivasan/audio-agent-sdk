# Sonexis Runtime v0.3 report

## 1. Executive summary

Runtime v0.3 turns the v0.2 local capture service into source-aware audio
infrastructure that an AI application can use without learning Core Audio. The
protocol-v2 Runtime remains provider-neutral. New functionality lives in the
public SDK layer: ergonomic source resolution, labeled multi-source sessions,
deterministic replay, activity primitives, latency accounting, optional OpenAI
and Gemini adapters, a control-only MCP server, and external reference apps.

The signed Process Tap path validated for v0.2 remains intact. All offline
Runtime and application regressions pass after the v0.3 changes.

## 2. Product capability now available

A developer can discover an application by Runtime ID, bundle ID, integer PID,
exact name, or `AudioSource`; wait for a source to launch; capture one or more
sources; receive source-aware PCM frames; observe lifecycle events; track local
drops and latency; replay recorded PCM; and forward a stream to an optional
realtime provider adapter. Ambiguous names fail explicitly.

Source identity is never replaced by an anonymous system mix. Independent
streams retain independent sessions, sequence spaces, timestamps, queue/drop
metrics, and lifecycle.

## 3. Architecture

```text
macOS application(s)
        |
Core Audio Process Tap / Sonexis Capture Core
        |
protocol-v2 Runtime: JSON control + events, framed binary PCM
        |
        +-- Python SDK -- labeled session -- provider adapter -- AI service
        +-- TypeScript SDK
        +-- sonexisctl
        +-- MCP control server (control only; never PCM)
```

No OpenAI, Gemini, MCP, model, or agent dependency is linked into the Runtime.
The audio callback still writes to bounded native buffering; socket I/O,
format conversion, SDK queueing, disk output, and provider work remain off the
realtime callback.

## 4. Source-aware stream model

`AudioFrame` carries the stream/session/source relationship plus sequence,
session-relative presentation timestamp, negotiated format, discontinuity,
known Runtime drops, Runtime session-start coordinate, and SDK receipt time.
Stable source strings are resolved once at capture start rather than repeated
in every 64-byte wire header.

`MultiSourceSession` assigns an application label to each independent capture.
It uses one bounded queue per label and fair draining. When a label queue is
full, new packets are dropped, PCM sample-frame counts are accumulated per
label and in aggregate, and the next retained frame reports a local
discontinuity. Independent Process Taps are not claimed to be sample-accurately
synchronized.

## 5. Python SDK

The Python SDK is the primary v0.3 developer interface. It includes:

- `find_sources`, `get_source`, and `wait_for_source`;
- source-aware capture frames and structured terminal failures;
- bounded labeled multi-source sessions;
- deterministic PCM/WAV replay;
- activity measurement and a pluggable VAD protocol;
- p50/p95/p99 local latency summaries;
- cancellation-safe async context managers and serialized connection setup;
- typed, retryability-aware Runtime and provider exceptions.

The dependency-free core supports Python 3.9+. Provider and MCP extras require
Python 3.10+ because their official dependencies do.

## 6. TypeScript status

The TypeScript client has matching source resolution, format presets,
source-aware frames, strict event/PCM parsing, terminal capture failures,
request timeouts, bounded queues, labeled multi-source sessions, and cleanup
that can be awaited. The checked-in npm lockfile makes local validation
repeatable.

Using checksum-verified Node 22.23.0, `npm run build` succeeded and all eight
Node tests passed, covering framing, EOS, event validation, wrong-stream
rejection, selectors, presets, waiting, and labeled sessions.

## 7. OpenAI integration

`OpenAIRealtimeSink` is optional and imports the official SDK only when used.
It requests the 24 kHz mono PCM16 preset, base64-encodes complete sample frames,
preserves ordered single-stream affinity, uses bounded handshake/close waits,
and surfaces provider failures separately from Runtime failures. Serialization,
format, ordering, shutdown, and mocked transport behavior are tested without
credentials.

No authenticated OpenAI network call was made during this milestone.

## 8. Gemini integration

`GeminiLiveSink` is independently optional. It requests 16 kHz mono PCM16,
sends raw audio blobs with the declared media type, handles text/transcription
and returned audio events, enforces stream affinity/order, and has the same
bounded lifecycle behavior. Mocked transport and response handling are tested.

No authenticated Gemini network call was made during this milestone; model
availability must be selected for the developer's account.

## 9. MCP status

`python -m sonexis.mcp_server` exposes six low-bandwidth control tools: list and
resolve sources, query diagnostics, query sessions, start capture, and stop
capture. Capture mutation is disabled unless the server is launched with
`--allow-capture`. PCM never flows through MCP; after a start, an SDK consumer
attaches to the returned session on the binary data plane. The MCP Runtime
connection owns captures it creates and must remain alive until they stop.

The implementation was imported against `mcp>=2,<3`; server construction and
all six generated tool schemas were validated. Tool policy and dispatch have
unit coverage. A complete third-party MCP-host session remains manual.

## 10. Multi-source behavior

The reference demo opens two captures with distinct labels, independently
reports source IDs, timestamps, sequences, bytes, and lifecycle, and never
mixes PCM. One slow label cannot grow memory without bound or starve another
label. Concurrent duplicate labels and add-vs-close races are rejected or
cleaned up deterministically.

v0.3 continues the simpler v0.2 decision to create independent Process Taps,
including for clients selecting the same source. Shared-tap multiplexing is
deferred until measurements justify its additional ownership complexity.

## 11. Latency results

`LatencyTracker` estimates time from the Runtime presentation coordinate to SDK
receipt and provider receipts add local send time. These values do not include
network/model response latency and are not HAL callback latency.

The offline benchmark processed 4,000 chunks per path:

| Path | Represented audio | Wall time | Raw throughput |
| --- | ---: | ---: | ---: |
| replay generation | 40.000 s | 488.355 ms | 2.500 MiB/s |
| OpenAI adapter/base64 | 26.667 s | 543.414 ms | 2.246 MiB/s |
| Gemini adapter/blob | 40.000 s | 582.016 ms | 2.097 MiB/s |

These are serialization/transport microbenchmarks, not cloud latency claims.
Full methodology and the v0.2 conversion baseline are in
`docs/runtime-benchmarks.md`.

## 12. Stress results

- Native Runtime: 1,000 start/stop cycles, 200 connect/disconnect cycles, and
  16 parallel sessions passed in 0.845 seconds; descriptor growth was one while
  still inside deferred Runtime shutdown, peak RSS was 10,158,080 bytes, and
  no sessions remained.
- Python AI-consumer soak: two streams, deliberate slowdowns, 30
  cancel/reconnect cycles, and task/session/descriptor assertions passed.
- Bounded SDK benchmark: an eight-packet queue accepted 2,326 of 4,000 chunks,
  accounted for 1,674 dropped chunks, and never exceeded a high-water mark of
  eight. Peak process RSS was 22,544,384 bytes; Python `tracemalloc` peaked at
  1,300,045 bytes.
- The native fuzz corpus and malformed/truncated SDK parser tests passed.

## 13. Security model

Runtime sockets are local Unix sockets in a private directory, validate peer
UID, impose command/client/session/frame limits, and never listen on TCP. The
macOS account is the v0.3 trust boundary: any unsandboxed same-UID process is
trusted to use the Runtime's granted capture permission. The Runtime must not
be run privileged or placed in a shared directory.

MCP capture mutation is opt-in. Provider secrets remain external environment or
constructor inputs and are not logged. Diagnostics never contain PCM. CLI and
example recordings use mode `0600`, refuse symlinks, require a same-owner
regular file, and avoid blocking on special files. Recordings remain sensitive
and are never created implicitly.

## 14. Test results

The final validation completed on 2026-09-25:

- Python 3.9.6: 30/30 tests passed with `PYTHONASYNCIODEBUG=1`.
- Python 3.14.7: 30/30 tests passed with `PYTHONASYNCIODEBUG=1`.
- TypeScript: build passed; 8/8 Node tests passed on Node 22.23.0.
- Runtime protocol, core, integration, fuzz, and stress suites passed.
- Signed Debug builds of `sonexis-runtime` and `sonexisctl` passed.
- The entire `Scripts/test-all.sh` matrix passed: lifecycle/capture,
  graph/routing, DSP, persistence/workspace, recording, UI logic, and Runtime.
- Runtime signature/designated requirement, embedded plist usage string,
  identifier `com.sonexis.runtime`, version `0.3.0`, and Apple Development
  authority were verified from the built executable.

## 15. Independent review findings

Five independent review roles examined the stable implementation.

- **AI SDK/developer experience:** found weak terminal errors, connection races,
  provider dependency/version ambiguity, synchronous example output, and
  insufficient provider response handling. These were fixed with structured
  EOS failures, shared handshakes, documented Python floors, nonblocking output,
  and complete adapter event extraction.
- **Realtime/concurrency:** found add/close races, unfair multi-source draining,
  terminal-marker queue hazards, replay/provider shutdown races, and lost
  pending native drop accounting. Per-label queues, separate terminal state,
  shielded cleanup, bounded shutdown, and corrected native accounting resolved
  them. The HAL callback remained free of socket/disk/provider work.
- **Protocol/distributed systems:** found permissive TypeScript validation,
  missing request timeouts, poisoned unknown responses, weak EOS handling, and
  unclear cross-plane ordering. Strict parsers, timeouts, connection failure,
  session-status lookup, and documentation were added.
- **Security/privacy:** found output symlink/mode hazards, MCP stop mutation not
  sharing the start gate, and insufficient trust/recording documentation.
  Secure output creation, a common mutation gate, and explicit privacy guidance
  were added.
- **Adversarial external developer:** identified PID typing, queue/drop units,
  provider/MCP setup, replay timing language, and ownership/lifetime ambiguity.
  Public docs, docstrings, examples, and error behavior were simplified and
  clarified.

All high- and medium-confidence findings were addressed and regressions rerun.

## 16. Known limitations

- Source audio activity is measured from consumed frames; Runtime source-list
  activity is not yet a continuously authoritative signal.
- Replay exercises public SDK/provider pipelines but is not injected as a
  discoverable Runtime source. Actual wire framing remains covered by the
  protocol-v2 synthetic integration harness.
- Capture timestamps remain session-relative media positions, not preserved HAL
  host timestamps; cross-source sample accuracy is not promised.
- Independent clients capturing the same source use independent Process Taps.
- MCP relies on the same local-account trust boundary as Runtime and does not
  add per-tool user consent.
- Python packages, npm packages, adapters, and service are repository-local and
  are not published or installed as a background service.

## 17. Manual validation still required

- Sustained signed live capture of one, two, and four simultaneous applications
  while measuring CPU, RSS, drop rate, and actual application-to-SDK latency.
- Target termination/relaunch and output-device changes during those live
  multi-source captures.
- Permission denial/revocation transitions under current macOS TCC UI.
- Authenticated OpenAI and Gemini sessions, including current model selection,
  quota failure, network interruption, response audio, and cancellation.
- End-to-end MCP host use with a real agent client.

## 18. Files and major modules added

- `SDKs/python/src/sonexis/multi.py`, `replay.py`, `activity.py`, and
  `diagnostics.py`
- `SDKs/python/src/sonexis/providers/`
- `SDKs/python/src/sonexis/mcp_control.py` and `mcp_server.py`
- TypeScript source-aware/multi-source additions in `SDKs/typescript/`
- `Examples/audio-agent/` and `Examples/multi-source-runtime.py`
- `Scripts/test-runtime-v03.sh` and `Scripts/benchmark-runtime-v03.sh`
- `docs/ai-integration.md`, `docs/runtime-v0.3-plan.md`, and
  `docs/runtime-v0.3-roadmap.md`

## 19. Commits created

- `42887e7` — plan Runtime v0.3
- `5139af3` — add source-aware AI SDK infrastructure
- `67de7d0` — sign and version Runtime 0.3
- `cd4f653` — harden SDK lifecycle, backpressure, parsing, and privacy
- final documentation/report — the commit containing this report

No unrelated AutoPitch, VoxCent, or UI work was staged or committed.

## 20. Exact quickstart

Build and start the signed Runtime:

```sh
cd ~/Sonexis
xcodebuild -project Sonexis.xcodeproj -scheme sonexis-runtime \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/RuntimeSigning build
xcodebuild -project Sonexis.xcodeproj -scheme sonexisctl \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/RuntimeSigning build
.build/RuntimeSigning/Build/Products/Debug/sonexis-runtime
```

In another terminal, inspect and capture:

```sh
cd ~/Sonexis
.build/RuntimeSigning/Build/Products/Debug/sonexisctl sources
.build/RuntimeSigning/Build/Products/Debug/sonexisctl status
export SOURCE_ID='app.com.spotify.client' # replace with an ID printed by sources
.build/RuntimeSigning/Build/Products/Debug/sonexisctl capture "$SOURCE_ID" \
  --sample-rate 16000 --channels 1 --sample-format pcm_s16le \
  --output /tmp/spotify.pcm --debug
```

The CLI intentionally requires a Runtime source ID; set `SOURCE_ID` to the ID
printed by `sources`. The Python SDK resolves exact names directly:

```sh
cd ~/Sonexis
/usr/bin/python3 -m venv --system-site-packages .venv
. .venv/bin/activate
python -m pip install --no-deps --no-build-isolation -e SDKs/python
python Examples/audio-agent/audio_agent.py --provider mock --source Spotify
python Examples/multi-source-runtime.py Discord Spotify
```

For provider or MCP extras, use Python 3.10+ and follow
`docs/ai-integration.md`; credentials are required only for authenticated
provider runs.

## 21. Recommended v0.4 milestone

Make the Runtime a signed/notarized per-user service with install/update/remove
flows and first-class permission UX; preserve HAL host timestamps for honest
live latency; add finer explicit authorization before broader agent-tool use;
and design bidirectional/virtual-microphone output as a separate reviewed
capability. Package publication should follow CI across supported Python and
Node versions rather than precede it.
