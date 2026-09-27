# Sonexis Runtime v0.6 report

## Result

Runtime v0.6 makes output destinations first-class, bounded Sonexis resources
without changing protocol version 2 or the PCM data planes. It preserves the
v0.1-v0.5 capture, playback, duplex, provider, packaging, signing, and
distribution behavior while adding:

- stable resolved Core Audio device identity on destination snapshots;
- typed destination add/remove/update/default-change events;
- exact, ambiguity-safe destination resolution in Python, TypeScript, and CLI;
- cancellable wait-for-destination APIs;
- explicit capture/output format policies and exhaustive output conversion
  coverage;
- safer HAL route rebuild, callback quiescence, and teardown retry behavior;
- bounded and structurally validated destination discovery; and
- an explicit decision not to ship a first-party HAL driver in the 1.0 line.

The original `/Users/skandavyas/Sonexis` worktree was not modified. All work
was performed in `/Users/skandavyas/Sonexis-runtime-v04` on
`runtime-v0.4-bidirectional-audio`.

## Endpoint model

Input sources and output destinations remain distinct public concepts because
their lifecycle semantics differ. Output discovery returns:

- `default`, a semantic alias that follows the system default;
- fixed `coreaudio:<UID>` destinations that never silently fall back; and
- `virtual_input` for devices with an input stream and a recognized loopback
  name or UID.

Snapshots expose display name, availability, default/follow semantics, native
format, supported Runtime formats, and `active_device_id`/
`active_device_name`. The stable ID never exposes a transient `AudioObjectID`.
If macOS has no default output, Runtime retains an unavailable `default` alias
and continues listing usable fixed devices.

Discovery is capped at 32 destinations and rejects empty/duplicate IDs,
incoherent default semantics, invalid format advertisements, and oversized
identity fields. This validation is shared by control responses and the event
monitor, so malformed backend output cannot bypass registry invariants.

## Destination lifecycle

The existing non-realtime endpoint monitor refreshes once per second and emits:

- `output_destination_added`
- `output_destination_removed`
- `output_destination_updated`
- `output_default_changed`

Initial discovery does not emit a burst. Events are sorted by stable ID for
determinism. A default-change event is keyed by the resolved stable device UID,
not the display name. Removal carries the last-known snapshot; the event type,
not that stale snapshot's availability bit, is authoritative.

Global registry events and active-session `output_destination_changed` events
are intentionally independent and have no cross-plane total ordering. The
latter reports one session rebuilding its HAL route and counts frames discarded
by the transition.

## SDK and CLI behavior

Python adds `find_output_destinations()`, `get_output_destination()`, and
`wait_for_output_destination()`. TypeScript provides the camelCase equivalents.
Resolution tries stable ID, exact case-sensitive name, then exact
case-insensitive name. `loopback`/`virtual_input` resolves only one unique
virtual destination. Ambiguity reports candidate IDs instead of guessing.

Wait helpers validate finite timeouts/poll intervals and TypeScript honors
pre-aborted and in-wait `AbortSignal` cancellation. Both SDKs strictly parse
destination event metadata and reject nested/top-level ID disagreement.

`AudioOutput.destination` retains typed route context. `output.refresh()` now
refreshes both session metrics and destination metadata, allowing duplex
feedback warnings to reflect a default route that changed to or from a
loopback device. Event-driven applications can refresh immediately after a
destination event.

`sonexisctl play --destination` accepts an exact stable ID, exact name, or an
unambiguous kind alias. Its output identifies the resolved route. Existing
direct-ID calls remain compatible.

## Format and routing correctness

Capture and output supported-format policies are represented separately inside
Runtime while retaining the additive protocol-v2 handshake. Output supports:

- PCM16 mono at 16, 24, and 48 kHz;
- PCM16 stereo at 48 kHz; and
- Float32 mono/stereo at 48 kHz.

The matrix test covers every advertised ingress format against 44.1, 48, and
96 kHz mono/stereo destinations and verifies exact duration, channel conversion,
Float32 sanitization, and converter-tail handling. HAL ASBD validation accepts
only packed Float32, one frame per packet, valid planar/interleaved strides,
one or two channels, and finite 8-192 kHz sample rates.

Default-device and stream-format notifications are coalesced for 75 ms. Route
teardown/rebuild runs under the non-realtime ingest lock; the C render callback
continues to see only its retained ring. Writers cannot observe the intentional
nil-route gap.

## Realtime and concurrency hardening

Independent review confirmed that the render callback performs no Swift work,
allocation, lock, logging, socket I/O, or conversion. The production C IOProc
is now exercised under TSan with interleaved and planar `AudioBufferList`
layouts while producer and flush work race.

The review found a callback-lifetime proof gap and ignored HAL teardown status.
The ring now registers an active reader before checking its read gate and has a
control-thread quiescence barrier. After successful IOProc destruction,
teardown closes the gate, waits for in-flight readers, and only then releases
the retained ring. Stop/destroy failures are surfaced; a failed destroy retains
the complete route and IOProc handle so later cleanup can retry rather than
discarding an unrecoverable callback registration.

Writer backpressure remains bounded to two seconds. Stop marks the route
non-writable before waiting for the ingest lock, causing a blocked writer to
observe cancellation on its 2 ms polling cadence. A route rebuild may wait for
the bounded writer deadline; no unbounded wait or realtime blocking is added.

## Loopback and feedback decision

Sonexis Runtime 1.0 will not ship a first-party AudioServerPlugIn/HAL driver.
Doing so responsibly requires a privileged installer, separate
signing/notarization lifecycle, Intel and Apple Silicon coverage, system-audio
failure recovery, and application-level validation whose blast radius is much
larger than the user Runtime process.

Installed loopback support is instead first-class: stable discovery, exact
name/kind resolution, events, native format metadata, wait helpers, and
advisory duplex warnings. These warnings are not acoustic echo cancellation
and do not prove which application selected a loopback input.

## Security

The trust boundary remains the local macOS UID. Runtime binds no TCP port;
control/data/event sockets remain under a private `0700` directory with `0600`
socket modes. Destination discovery and control responses are bounded. No
audio content, provider credential, recording, virtual environment, package
cache, or generated build product is committed.

Same-UID clients can still capture and inject audio. This is explicit local
developer infrastructure, not a per-client authorization product. External
applications must obtain user consent and avoid logging/persisting private
audio by default.

## Performance

On the Apple M4 development host (macOS 27.0 build 26A428), the repeatable
converter/ring microbenchmark reported:

| Path | Represented audio | Wall time | Realtime factor |
| --- | ---: | ---: | ---: |
| PCM16 24 kHz mono -> Float32 48 kHz stereo | 200 s | 0.030395 s | 6,580.1x |
| PCM16 48 kHz stereo -> Float32 48 kHz stereo | 200 s | 0.008726 s | 22,921.2x |
| Float32 48 kHz mono -> Float32 44.1 kHz stereo | 200 s | 0.027140 s | 7,369.3x |
| two-channel ring write/read | 200 s | 0.017763 s | 11,259.1x |

These measurements exclude live HAL route and physical/Bluetooth latency. The
75 ms value is a deliberate notification-coalescing window, not measured audio
latency. Full methodology and historical comparisons are in
`docs/runtime-benchmarks.md`.

## Automated validation

The v0.6 release gate ran on 2026-09-27 with Xcode 27.0, the macOS 27 SDK,
system Python 3.9.6, and the installed Node/npm toolchain. It passed:

- Debug Sonexis application build and the complete application regressions;
- Runtime protocol/core/integration/data-plane/fuzz suites;
- 1,000 capture and 1,000 output start/stop cycles, 200 connection cycles, and
  16 parallel sessions;
- output ring/IOProc TSan and full application concurrency TSan;
- 66 Python SDK tests and 20 TypeScript SDK tests;
- public example smoke tests;
- clean Python wheel/sdist and TypeScript package consumer tests;
- signed universal Release Runtime/CLI builds and metadata checks; and
- install/reinstall/start/status/crash-recovery/stop/uninstall lifecycle tests.

The final non-TSan stress run completed in 1.390 seconds with one descriptor of
in-scope growth and 11,288,576 bytes peak RSS. The TSan stress run completed in
3.950 seconds with the same descriptor bound and 88,358,912 bytes peak RSS.
These are test-process peak values, not live Core Audio latency measurements.

The signed Runtime retains identifier `com.sonexis.runtime`, Apple Development
Team `7934D5M686`, and `NSAudioCaptureUsageDescription`. Signing and install
remain local-development distribution, not Developer ID/notarized delivery.

## Independent reviews

Architecture/API review found unstable resolved-device identity, duplicate-ID
traps, no-default behavior, imprecise native interleaving, unclear event
semantics, and insufficient loopback scope. These were fixed with stable active
IDs, structural validation, an unavailable default alias, accurate ASBD
metadata, documented event ordering, and the explicit 1.0 driver decision.

Test review found missing lifecycle diffs, conversion coverage, ASBD bounds,
resolver tests, loopback classification, and production IOProc exercise. All
were added. Live Core Audio device-change behavior remains a manual test rather
than being misrepresented by a fake backend.

Adversarial SDK/protocol review found a broken TypeScript kind-only wait,
non-finite polling inputs, permissive Python parsing, stale feedback snapshots,
unbounded/duplicated discovery, and inconsistent nested event identity. These
were fixed and regression-tested.

Realtime review found no callback-path realtime regression or lock inversion.
It identified ignored teardown status and an unproven callback quiescence edge;
both were fixed as described above. Core Audio property-listener removal still
depends on HAL honoring its removal API; failures cannot be injected without a
HAL seam, and live churn remains in the manual guide.

## Manual validation

- v0.4 real HAL playback to headphones and BlackHole: **PASSED 2026-09-26**;
  not rerun after v0.6 route lifecycle changes.
- v0.3 authenticated Chrome -> Runtime -> Gemini understanding: **PASSED**;
  not rerun because capture/provider behavior did not change.
- v0.6 default output switching during playback: **NOT RUN**.
- v0.6 AirPods connect/disconnect and same-device format change: **NOT RUN**.
- v0.6 fixed-device removal during playback: **NOT RUN**.
- v0.6 BlackHole receipt in Discord/Zoom: **NOT RUN**.

Exact commands and expected events are in
`docs/runtime-v0.6-manual-validation.md`.

## Known limitations

- Destination registry polling has up to roughly one second of observation
  delay; active sessions use direct HAL notifications.
- Registry and session events are not globally ordered.
- A destination snapshot can race removal; `start_output` is authoritative.
- Output supports one compatible HAL output stream and one/two channels only.
- A route rebuild can wait for the existing bounded writer deadline.
- No acoustic echo cancellation, automatic muting, or first-party virtual
  input driver is provided.
- Same-UID local access remains the authorization boundary.
- Live device churn, TCC prompts, physical audibility, and receiving-app
  loopback selection require human validation.

## Commits

- `a1ff08e` - plan v0.6 endpoint maturity
- `43ec14a` - implement destination lifecycle and public endpoint APIs
- `519dffb` - harden routing and format safety
- `ef78474` - close independent review gaps

The documentation/final checkpoint commit follows this report. Its immutable
hash is recorded by a final documentation-only checkpoint before v0.7 begins.

## Next milestone

v0.7 should refine the provider-neutral duplex API, align activity/turn events,
remove duplicated provider adapter mechanics, harden the control-only MCP
surface, and produce one small public-API reference agent plus a source-aware
multi-stream example. It should not add a first-party driver or turn Runtime
into an agent framework.
