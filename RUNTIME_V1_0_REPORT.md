# Sonexis Runtime 1.0 Release Candidate Report

## 1. Executive summary

Sonexis Runtime 1.0 is a local programmable application-audio I/O release
candidate for macOS. It lets another same-user process discover labeled desktop
applications, receive normalized realtime PCM, observe lifecycle events, and
send bounded realtime PCM to physical or installed loopback destinations
without implementing Core Audio.

This is an engineering-complete local candidate, not a publicly distributable
Apple product. The repository produces Apple Development-signed universal
binaries and local SDK packages. Developer ID signing, notarization, package
publication, and an accepted public installer remain external distribution
work.

## 2. Product thesis

Sonexis is the local programmable audio I/O layer for AI and conventional
software. Its stable core exposes sources, streams, sessions, frames, outputs,
destinations, events, and diagnostics. Models, agents, provider SDKs, remote
transport, and conversational policy remain above that core.

```text
macOS applications -> source-aware Sonexis capture -> software / AI
software / AI -> bounded Sonexis output -> speakers / headphones / loopback
```

## 3. Supported capabilities

- process-specific application discovery and Core Audio Process Tap capture;
- stable source identity, ergonomic exact/ambiguity-safe resolution, and
  `wait_for_source` / `waitForSource`;
- PCM16 or Float32, mono/stereo, 16/24/48 kHz negotiated output;
- timestamped, sequenced, source-aware frames with explicit discontinuity and
  drop accounting;
- multi-client, multi-capture, labeled multi-source sessions;
- bounded client-to-Runtime PCM and Core Audio playback with jitter buffering,
  backpressure, flush/cancel, destination lifecycle, and metrics;
- independent capture/output plus optional duplex composition;
- protocol-v2 events, structured errors, capabilities, diagnostics, and limits;
- async Python and typed ESM TypeScript SDKs;
- CLI capture/playback/diagnostics, deterministic replay, control-only MCP, and
  experimental OpenAI Realtime/Gemini Live adapters.

## 4. Supported platform

- macOS 14.4 or later on Apple Silicon or Intel x86_64;
- Xcode 16 and a macOS 14.4 SDK or newer for local builds;
- CPython 3.9+ for the dependency-free SDK core and 3.10+ for provider/MCP
  extras;
- Node.js 18+ for the ESM TypeScript SDK.

## 5. Architecture

The headless capture core owns Process Taps, aggregate-device/IOProc lifetime,
lock-free callback handoff, off-realtime conversion, and capture sessions. The
output core owns device resolution, conversion, a bounded jitter/ring path, and
a C render callback. Runtime control uses bounded NDJSON over a same-UID Unix
socket. Each capture, output, or event subscription uses a separate private Unix
socket and the fixed SXPC v2 binary envelope. SwiftUI is outside every Runtime
layer.

## 6. Capture

Capture callbacks perform only bounded ring writes and atomic accounting.
Normalization and socket delivery run off the HAL thread. Runtime 1.0 adds
explicit finite 8-192 kHz and 1-8 channel native-format limits before numeric
conversion or ring/converter allocation, preventing malformed virtual-device
formats from causing traps or unbounded per-session memory.

Core Audio does not reliably expose every Process Tap denial as a distinct
permission status. Missing permission can therefore surface as the actionable
`capture_initialization_failed`; SDK `PermissionDeniedError` remains the typed
mapping when a backend supplies explicit `permission_denied`.

## 7. Output

Clients negotiate an output format on the control plane, then send ordered SXPC
frames over a dedicated binary socket. Runtime queues are bounded. The device
render callback never performs socket I/O, logging, allocation, conversion, or
Swift concurrency hops. Slow producers generate observable underruns; fast
producers experience socket backpressure and bounded drop/overrun behavior.

## 8. Duplex

Duplex is an ownership convenience around one independent capture and one
independent output. It does not impose turn-taking, model behavior, mixing,
ducking, or echo cancellation. `flush` rotates the output stream epoch for
barge-in while retaining the logical output session; `cancel` discards buffered
output and tears down immediately.

## 9. SDKs

Python exposes concise async context managers for capture, playback, events,
multi-source, replay, and duplex. TypeScript exposes matching typed async
iteration/EventEmitter semantics and exact `bigint` timing. Both use packet
terminology for bounded multi-source queues, retain compatibility aliases, and
document the one-millisecond minimum output write.

The TypeScript package strips SDK lifecycle hooks from generated declarations;
the release test inspects the packed `.d.ts` so implementation cooperation
cannot accidentally become public 1.0 API.

## 10. AI integrations

OpenAI Realtime and Gemini Live adapters consume only public source-aware SDK
streams and emit provider responses above the Runtime core. Gemini keeps server
VAD and adds edge-triggered local hybrid finalization for application audio.
Provider audio routes through the same Sonexis output API as any other client.
Both integrations remain experimental because their upstream APIs evolve
outside Sonexis compatibility control.

## 11. MCP

MCP is experimental and control-only. It never transports PCM or returns binary
data-socket capabilities. Capture mutation is absent unless the operator passes
`--allow-capture`; the MCP process tracks and cleans only captures it owns.
Runtime 1.0 also bounds MCP selectors, format names, and session identifiers.

## 12. CLI

Stable commands cover sources, capture/stop, status/diagnostics, event watch,
outputs, playback/output status/stop, version, and help. Human formatting is
descriptive; documented `--json` shapes and structured error codes are the
machine interface.

## 13. Protocol

Protocol v2 is the stable 1.0 wire contract. The NDJSON envelope, request and
response IDs, errors, capability negotiation, limits, command meanings, event
ordering/loss semantics, and 64-byte SXPC input/output layout are covered by the
compatibility policy. Decimal-string mirrors preserve exact long-lived UInt64
values for JavaScript without a protocol-v3 break.

## 14. Realtime architecture

Input and output callbacks use preallocated storage and bounded atomic/ring
operations. Converter work, JSON, allocation, socket I/O, disk I/O, logging,
events, and diagnostics stay off realtime threads. Teardown stops callbacks
before releasing callback-visible ownership. TSan and concurrent ring
flush/read/write coverage remain release gates.

## 15. Backpressure

Every queue has an explicit bound. Capture delivery drops complete oldest/new
packets according to the documented layer and marks the next delivered frame
with discontinuity/drop counts. Output writers await Unix-socket pressure;
Runtime input, jitter, and device queues remain bounded and expose late,
dropped, underrun, overrun, depth, high-water, and buffered-duration metrics.

## 16. Security and privacy

Runtime binds only AF_UNIX endpoints in a private per-user directory, validates
same-UID peers, limits clients/messages/sessions/subscriptions, and never runs
privileged. The trust boundary is the local macOS account: any unsandboxed
same-UID process can use the Runtime's granted capture authority or inject
audio. Capture and output are therefore sensitive capabilities.

Diagnostics omit PCM, transcripts, credentials, and private stream paths by
default. Recordings are explicit, private regular files and reject symlink
targets. Provider credential patterns are redacted from bounded diagnostics.
Development lifecycle state rejects writable/foreign directories and uses an
unpredictable private PID staging file.

Artifact verification does not execute candidate binaries and bounds metadata,
archive inventory, and expansion. Hashes prove bundle consistency, not
publisher authenticity. A copied bundle must be anchored with an out-of-band
`SONEXIS_EXPECTED_MANIFEST_SHA256`; this binds the manifest, package hashes, and
declared source revision before package metadata is inspected. Expected
team/source values are supplemental checks and cannot authenticate SDKs alone.
Without the digest anchor, verification is for trusted local build output rather
than adversarial bundles. Apple Development signing does not replace Developer
ID/notarization.

## 17. Performance

The 1.0 audio data planes intentionally retain the measured v0.8/v0.9 design;
no speculative DSP or protocol rewrite was introduced. The final automated
gate measurements are recorded below after the clean candidate run. Physical
capture-to-speaker and provider/network latency remain manual measurements and
are not attributed to Sonexis.

## 18. Stress and automated test results

Focused 1.0 qualification before the final gate passed:

- Runtime protocol and capture-core tests;
- 86 Python SDK tests;
- 27 TypeScript SDK tests;
- Python wheel/sdist and TypeScript tarball clean-install tests;
- packed TypeScript public-declaration inspection;
- TypeScript public duplex example compilation;
- version, documentation-link, shell-syntax, and diff checks.

The final clean full-gate counts, stress timing, RSS/descriptor accounting,
TSan result, signed build result, and artifact result are added only after that
gate runs against a committed candidate.

## 19. Independent review

The release-blocker review found and prompted fixes for leaked TypeScript
lifecycle declarations, stale Python beta metadata, unvalidated MCP server
version metadata, and inaccurate permission/protocol wording. The
security/privacy review found and prompted native capture-format bounds,
lifecycle-state hardening, MCP input bounds, non-executing bounded artifact
verification, and explicit artifact trust semantics. The external-developer
review prompted a validated TypeScript duplex example, canonical queue names,
minimum-write and fail-fast documentation, explicit fixture paths, and clearer
ESM/local-build instructions.

Follow-up reviewers confirmed those code/documentation findings were closed.
Public distribution remains intentionally blocked on external signing,
notarization, publication, and installer work.

## 20. Known limitations

- local artifacts are Apple Development-signed and not notarized or publicly
  distributed;
- SDK packages are built locally, not published to PyPI/npm;
- same-UID account trust is not per-client authorization;
- no first-party virtual microphone is shipped; installed loopback devices are
  supported as destinations;
- no acoustic echo cancellation, automatic ducking, or conversational policy;
- same-source captures use independent Process Taps;
- cross-application timestamps are not sample-accurately synchronized;
- provider adapters and MCP remain experimental;
- the legacy guarded `/tmp` protocol-v2 endpoint remains a compatibility bridge.

## 21. Manual validation remaining

Every 1.0 interactive check is currently **NOT RUN**. Exact commands and pass
criteria are in `docs/runtime-v1.0-manual-validation.md`. Historical Chrome,
Spotify, Gemini semantic, and HAL validations are preserved only as evidence
for the earlier builds on which they ran.

## 22. Distribution limitations

A public macOS release still requires Developer ID Application signing,
Hardened Runtime/entitlement review, notarization, installer/service acceptance,
package publication/provenance, and clean-machine permission testing. No 1.0
engineering claim implies those credentials or external approvals were used.

## 23. Public API guarantees

`docs/runtime-api-stability.md` is authoritative. Stable protocol/SDK/CLI
surfaces follow semantic versioning and the deprecation policy in
`docs/runtime-compatibility.md`. Experimental provider/MCP surfaces may track
upstream APIs but cannot break the provider-neutral core. Human CLI prose,
private Swift types, socket filenames, Core Audio IDs, queue implementation,
and package-private SDK hooks are not public contracts.

## 24. Milestone commits

Runtime 1.0 started from v0.9 checkpoint
`f6c2817cb762759b3f4b5aef4fea7fc5719e2dfb`.

- `684c1c7` — scope and release plan;
- `0b972cc` — promote and harden the 1.0 public surface.

Final documentation and release-gate checkpoint commits are appended after
they exist.

## 25. Final HEAD

Pending the clean automated release-gate checkpoint.

## 26. Exact quickstart

```sh
git clone https://github.com/skanda-vyas-srinivasan/Sonexis.git
cd Sonexis
./Scripts/setup-runtime-dev.sh
./Scripts/runtime-dev.sh start
export PATH="$HOME/Library/Application Support/SonexisRuntime/dev/bin:$PATH"
sonexisctl sources

/usr/bin/python3 -m venv --system-site-packages .venv-runtime
. .venv-runtime/bin/activate
python -m pip install --no-deps --no-build-isolation -e SDKs/python
python Examples/capture-one-source.py "Google Chrome" --frames 16000
```

The first live capture may require granting the separately signed Runtime under
**System Settings > Privacy & Security > Screen & System Audio Recording** and
restarting it.

## 27. Future roadmap

`docs/runtime-post-1.0-roadmap.md` records distribution, authorization, endpoint,
ecosystem, and protocol possibilities. The next cohesive human milestone should
be Developer ID/notarized distribution plus clean-machine permission/install
validation, not another speculative audio feature.
