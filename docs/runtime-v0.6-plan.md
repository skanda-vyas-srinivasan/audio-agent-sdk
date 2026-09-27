# Sonexis Runtime v0.6 plan: endpoint and routing maturity

## Starting point

The clean v0.5 checkpoint at `8779c93` distributes and validates Runtime v0.5
without changing v0.4 audio semantics. Capture sources are stable semantic
resources with lifecycle polling/events. Output destinations are typed snapshots
returned on demand, while active HAL sessions independently watch their current
device. This asymmetry makes destination discovery harder to build against:
clients must poll, names cannot be resolved safely, and device/default changes
outside an active output session are invisible.

Existing strengths to preserve:

- input sources and output destinations remain distinct public concepts;
- protocol v2 has additive capability negotiation and typed structured errors;
- `default` follows the macOS default output while `coreaudio:<UID>` fixes a
  stable HAL device identity;
- active sessions already handle default-device/format changes and fixed-device
  liveness;
- every advertised Runtime PCM format converts through a worker-owned
  `AVAudioConverter` or prepared direct path;
- client and Runtime queues are bounded and HAL rendering remains a C callback;
- installed loopback devices use the same output plane as physical devices.

## Gaps

- no resource-level destination added/removed/updated/default-change events;
- destination name/kind resolution is repeated by each developer;
- playback accepts a human name syntactically but Runtime interprets it as an
  ID, producing an avoidable unavailable error;
- SDKs do not expose destination filtering, ambiguity, or delayed availability
  with source-like ergonomics;
- capture/output supported-format roles are not described as separate policy;
- generic loopback classification is useful but advisory semantics and
  ambiguity need stronger public APIs;
- duplex feedback risk is documented but not represented in diagnostics;
- deterministic destination churn and routing tests are narrower than source
  lifecycle tests.

## v0.6 architecture

### Distinct, consistent endpoint resources

Keep `AudioSource` and `AudioOutputDestination` separate rather than forcing
unlike lifecycle semantics into one union. Align their developer-facing shape:

- stable ID;
- semantic kind;
- display name;
- availability;
- native format when meaningful; and
- explicitly supported Runtime formats.

Add SDK helpers equivalent to:

```python
await sx.find_output_destinations(query="blackhole", kind="virtual_input")
await sx.get_output_destination("BlackHole 2ch")
await sx.wait_for_output_destination(kind="virtual_input")
```

Resolution accepts a destination object, exact stable ID, exact name, or an
explicit kind filter. It never chooses between multiple candidates. Ambiguity
and timeout remain structured errors. `playback()` and duplex output use the
same resolver, so public examples do not need Core Audio UIDs.

### Destination registry and events

Extend the existing non-realtime Runtime monitor to snapshot destinations at a
bounded cadence. Diff stable IDs and publish additive protocol-v2 events:

- `output_destination_added`
- `output_destination_removed`
- `output_destination_updated`
- `output_default_changed`

Events include the relevant typed destination snapshot. Initial discovery is a
snapshot, not an event burst. Active session route-change events remain
separate: a resource default may change even with no session, while
`output_destination_changed` describes one active session following or
rebuilding its route.

Polling is deliberate for v0.6: it reuses the backend abstraction and makes
the registry deterministic under mock backends. HAL property listeners remain
inside active playback sessions. A future native registry can replace polling
without changing protocol/SDK semantics.

### Format policy

Retain the protocol-v2 default format list for compatibility. Document and
expose capture/output policy separately in SDK helpers and destination
snapshots. Validate the requested output format against the resolved
destination before opening its binary stream. Keep conversion off the HAL
callback and benchmark every advertised combination: PCM16/Float32, mono/stereo,
16/24/48 kHz where supported.

### Routing and feedback

Preserve exact routing rules:

- `default` follows the system default and rebuilds on device/format change;
- a fixed UID never silently falls back to another device;
- fixed-device loss fails retryably and requires an explicit new session;
- destination resolution never guesses among multiple loopback devices.

Loopback output is intentionally explicit. SDK duplex/session diagnostics will
surface a feedback-risk warning when a virtual input is selected. This is not
acoustic echo cancellation or proof of a digital loop. Runtime will not mute,
duck, or reconnect automatically.

## Virtual-device decision

v0.6 will make a final 1.0 scope decision in
`docs/virtual-audio-device-design.md`. The current recommendation is **not to
ship a first-party HAL driver for 1.0**. A safe driver requires a separate
AudioServerPlugIn implementation, privileged installer, driver-specific
signing/notarization, Intel/Apple Silicon testing, system-audio crash recovery,
and interactive Discord/Zoom/browser validation. Those prerequisites exceed a
responsible Runtime release branch. Excellent BlackHole and generic installed
loopback support provides the required routing contract without pretending an
untested driver is safe.

## Compatibility

- Runtime version advances to `0.6.0`; protocol remains v2.
- New event enum values, event payload fields, and capabilities are additive.
- Legacy wildcard subscriptions retain their original event set. Current SDKs
  opt in explicitly to new destination events.
- Existing stable destination IDs and `default` semantics do not change.
- Existing direct ID-based `playback()` calls remain valid.
- No capture, output framing, callback, ring, or socket format changes are
  planned.

## Testing strategy

Deterministic tests will cover:

- destination snapshot add/remove/update/default-device diffs;
- no initial event burst and no duplicate unchanged events;
- typed event encoding/decoding in Swift, Python, and TypeScript;
- exact ID/name/case-insensitive/kind resolution and ambiguity;
- wait-for-destination success, timeout, disappearance, and cancellation;
- playback/duplex resolution through only public SDK APIs;
- unsupported destination-format errors before stream creation;
- fixed loss versus default-follow behavior using mock backends;
- every advertised conversion combination and exact EOS duration;
- multiple loopback ambiguity and feedback-risk diagnostics;
- existing input/output stress, fuzz, TSan, package, distribution, and full app
  regressions.

Manual tests remain explicit for AirPods attach/detach, physical default-device
switching, BlackHole installation/removal, and receiving injected audio in
Discord/Zoom.

## Realtime and concurrency risks

- Destination polling and event serialization must stay off HAL callbacks.
- Registry refresh must not overlap shutdown or publish after event sockets are
  stopped.
- Active-session listener teardown must remain ordered before route resources
  are released.
- Format validation must not add device queries to the render callback.
- New SDK waits and event consumers need bounded cancellation and must not leak
  subscriptions.
- Resource snapshots can race real device removal; start must still return a
  retryable structured error rather than assuming the snapshot is current.

## Staged implementation

1. Advance and gate the synchronized `0.6.0` version.
2. Add destination lifecycle protocol models, monitoring, and deterministic
   Runtime tests.
3. Add Python and TypeScript resolution/wait APIs and destination-aware events.
4. Route playback/duplex through unambiguous resolution and add feedback-risk
   diagnostics.
5. Expand format/routing/stress/adversarial tests and benchmarks.
6. Complete independent architecture, realtime, and routing reviews.
7. Update output/Runtime/virtual-device docs and create
   `RUNTIME_V0_6_REPORT.md` only after the full release gate passes.

## Release gate

v0.6 is complete only when all v0.5 gates still pass, destination lifecycle and
resolution tests pass in both SDKs, the output conversion matrix passes,
input/output stress and both TSan suites pass, no serious review finding
remains, the first-party virtual-device decision is explicit, manual items are
honestly classified, and a clean committed checkpoint is recorded.
