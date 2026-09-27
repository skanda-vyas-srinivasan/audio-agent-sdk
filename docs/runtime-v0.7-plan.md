# Sonexis Runtime v0.7 plan: agent I/O platform maturity

## Starting point

The clean v0.6 checkpoint `df1a8c5` (recorded by `eaa2393`) provides a signed,
locally installable Runtime with source-aware capture, bounded playback,
destination lifecycle resources, Python and TypeScript SDKs, optional OpenAI
and Gemini adapters, hybrid Gemini turn finalization, deterministic replay, and
a control-only MCP surface. Protocol v2 and both PCM data planes are stable.

The AI-facing layer already proves the complete path, but it grew in stages:
the provider adapters duplicate stream validation and affinity rules; Gemini's
useful activity state machine is adapter-private; duplex convenience is
documented more clearly than it is observable; the reference agent owns
provider/output coordination itself; and MCP exposes only the original capture
subset of Runtime resources.

## Product boundary

v0.7 will improve provider-neutral composition above Runtime. It will not add
model semantics to Runtime, stream PCM through MCP, introduce automatic model
reconnection, or turn Sonexis into an agent framework. Capture and output stay
independently usable. Provider packages remain optional.

No protocol v3 is planned. Runtime-core changes should be limited to versioning
or a correctness issue discovered by regression review.

## Public activity primitives

Extract the tested hysteresis/debounce behavior into a provider-neutral,
consumer-thread `AudioActivityDetector`:

- configurable start/end RMS thresholds;
- minimum sustained start duration;
- sustained end-silence duration;
- optional application-provided `VoiceActivityDetector`;
- edge-triggered `activity_started` and `activity_ended` transitions; and
- explicit reset/state inspection.

This object never runs on a Core Audio callback. Gemini will use it for hybrid
turn finalization while keeping server-side automatic VAD enabled. Applications
may use the same primitive without importing a provider. Runtime will not claim
semantic speech detection: the built-in measurement is signal activity unless
a real VAD is supplied.

## Provider adapters

Keep the intentionally small `RealtimeAudioSink` contract. Consolidate only the
mechanics that must be identical:

- frame-format/payload validation;
- one-Sonexis-stream affinity;
- strictly increasing sequence validation; and
- stable structured provider errors.

Do not create an inheritance hierarchy or provider plugin registry. OpenAI and
Gemini retain their own connection, protocol, turn, and shutdown behavior.
Both continue to return generated audio through `ProviderEvent`, which is
routed through the same public Sonexis output API.

## Duplex and reference flow

Review Python/TypeScript duplex naming and cleanup for consistency. Add only
small mechanisms justified by the existing reference agent, such as refreshing
destination/feedback state after route events. Do not hide capture and output
ownership or automatically reconnect either half.

Keep one polished terminal reference agent for:

```text
application -> Sonexis capture -> provider -> Sonexis output
```

Keep the existing labeled multi-source demo separate so source identity remains
obvious. Examples must use public SDK APIs only. An external-framework study
will document the minimal async-iterator/sink bridge for LiveKit or Pipecat; no
framework dependency will be added unless it materially proves interoperability.

## MCP control maturity

MCP remains stdio and low bandwidth. Extend read-only discovery to output
destinations and add typed status operations where Runtime already has a
control command. Mutating capture stays disabled by default. Any output-session
mutation must require a separate explicit opt-in; MCP will never create or
carry an output PCM stream.

Tool input is bounded and validated before reaching Runtime. Errors remain
structured and secret/audio content is never included. Test the dependency-free
dispatcher fully. If a compatible MCP host/package is unavailable, keep the
actual host handshake manual status as **NOT RUN** rather than inventing a pass.

## Compatibility

- Runtime/SDK version advances together to `0.7.0`; protocol remains v2.
- Existing provider constructors, Gemini configuration, event strings, capture,
  output, duplex, and MCP capture tools remain compatible.
- New activity types and MCP tools are additive.
- Existing server-side Gemini automatic VAD and output transcription stay on.
- Capture/output binary framing does not change.

## Testing

Add focused tests for:

- activity start/end hysteresis, short gaps, reset, custom VAD, and invalid
  configuration;
- unchanged Gemini exactly-once stream finalization through the extracted
  detector;
- shared provider validation, sequence, stream-affinity, cancellation, and
  output-audio parsing;
- duplex cleanup and refreshed feedback state;
- MCP read-only destination discovery, opt-in mutations, invalid inputs,
  Runtime-unavailable errors, and proof that tool results contain no PCM;
- reference agent mock/replay/output behavior and multi-source identity; and
- every v0.1-v0.6 regression, stress, fuzz, package, signing, and TSan gate.

Authenticated provider calls run only if credentials are safely available.
Prior Gemini validation remains historical evidence, not a substitute for new
network validation.

## Risks

- A generic activity detector can be mistaken for speech VAD. Naming/docs must
  distinguish energy activity from a supplied speech detector.
- Refactoring Gemini's candidate buffering could drop leading speech or emit
  repeated stream ends. Existing hybrid-VAD cases are release blockers.
- A convenience pipeline can obscure cancellation ownership. Prefer explicit
  tasks in the example unless a small public helper is clearly safer.
- MCP makes sensitive capture easier to trigger. Mutation remains opt-in and
  local same-UID trust must be explicit.
- Provider SDK APIs are externally versioned and cannot be live-validated
  without credentials/network; mocks must test serialization without claiming
  service compatibility.

## Stages and release gate

1. Complete public API/provider/MCP/external-developer audits.
2. Advance synchronized versioning and add provider-neutral activity edges.
3. Consolidate duplicated provider stream validation without changing wire
   behavior.
4. Mature duplex/reference examples and MCP controls.
5. Run provider mocks, SDK suites, complete regressions, stress, fuzz, TSan,
   packaging, and signed distribution gates.
6. Perform independent API, realtime/concurrency, protocol, security, and
   external-developer reviews; fix credible findings.
7. Update AI/Runtime docs and create `RUNTIME_V0_7_REPORT.md` with exact manual
   status and immutable checkpoint.

v0.7 passes only when all earlier release gates remain green, provider adapters
share the intended primitives, activity edges are independently usable, MCP is
still control-only and safe by default, examples remain public-API-only, no
serious review finding remains, and the repository is clean and committed.
