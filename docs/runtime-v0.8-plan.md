# Sonexis Runtime v0.8 plan: reliability and observability

## Starting point

The immutable v0.7 checkpoint `600b4af` (recorded by `de09c2c`) provides the
complete v0.1-v0.7 feature set: signed application-aware capture, bounded
playback and loopback routing, Python and TypeScript SDKs, provider-neutral
activity and duplex primitives, OpenAI and Gemini adapters, control-only MCP,
packaging, lifecycle tooling, and deterministic stress/fuzz coverage. Protocol
v2 and both binary PCM planes are stable.

All v0.8 work remains in `/Users/skandavyas/Sonexis-runtime-v04` on
`runtime-v0.4-bidirectional-audio`. The original Sonexis worktree remains out
of scope.

## Product boundary

v0.8 makes the existing product safe and diagnosable for all-day development
use. It does not add audio features, provider semantics, a protocol v3, or an
always-on telemetry service. Diagnostics are local, bounded, explicit, and do
not contain PCM, transcript text, credentials, or environment-variable values.

## Reliability and accounting

Extend the protocol-v2 status response additively with process-lifetime
control-plane counters where they make failures explainable, including accepted,
disconnected, and rejected clients; requests; malformed messages; control
errors; and source/destination monitor failures. Existing capture, output,
queue, drop, underrun, overrun, latency, and active-session metrics remain the
authoritative audio-plane accounting.

Counters are guarded by the Runtime's existing state ownership. They are never
updated from a Core Audio callback and never cause callback logging, allocation,
or actor hops. SDKs treat newly added fields as optional/defaulted so older
protocol-v2 runtimes remain compatible.

## Safe diagnostic trace

Add an opt-in support snapshot that composes existing low-bandwidth control
responses and local binary metadata. It must be bounded and redact socket paths
or other local capabilities where appropriate. It must never capture audio,
provider payloads, transcript text, secrets, or the process environment.

The trace is a point-in-time diagnostic artifact, not background telemetry. It
must fail clearly when Runtime is unavailable and be safe to share after the
documented source/application metadata privacy warning.

## Soak and fault injection

Make stress parameters configurable while retaining fast release defaults.
Add a repeatable soak wrapper that exercises capture, output, duplex-like
parallelism, connection churn, cancellation, and provider-style burst/pause
patterns while sampling RSS and descriptors. Assert bounded live resources and
zero surviving Runtime sessions rather than assuming an RSS high-water mark
will shrink.

Expand adversarial coverage for partial/oversized/malformed control and binary
frames, non-reading peers, client death, stale sockets, Runtime termination,
resource-limit rejection, and endpoint-monitor failures at available seams.
Fault injection remains synthetic and may not alter the user's live devices or
start real capture/playback.

## Performance

Repeat the capture framing, converter/ring, AI serialization, and lifecycle
stress benchmarks on the release checkpoint. Record host/toolchain assumptions,
wall time, throughput, RSS, descriptor growth, and bounded-queue behavior.
Do not attribute provider/network or physical HAL latency to Sonexis. Optimize
only a measured or review-confirmed bottleneck.

## Reviews

Use independent passes for:

- observability and resource accounting;
- fault injection and lifecycle behavior;
- local security/privacy and realtime/concurrency safety; and
- final public diagnostics usability.

Credible findings receive focused regressions and fixes before the checkpoint.
No P0/P1 correctness, privacy, or realtime issue may remain open.

## Compatibility

- Runtime/SDK version advances together to `0.8.0`; protocol remains v2.
- Status additions are optional and additive on the wire.
- Existing CLI commands and SDK constructors remain source compatible.
- PCM framing, format negotiation, queue policies, and Core Audio callbacks do
  not change unless a demonstrated correctness defect requires it.
- Same-UID local-process trust remains explicit; v0.8 does not invent an
  authorization product.

## Test and release gate

1. Add focused status-counter, compatibility, trace-redaction, and fault tests.
2. Run configurable long deterministic soak and record resource bounds.
3. Run all v0.1-v0.7 protocol, core, integration, fuzz, stress, application,
   SDK, adapter, MCP, package, distribution, signing, and TSan gates.
4. Rerun repeatable benchmarks and publish honest v0.8 measurements.
5. Complete independent security, privacy, realtime, concurrency, fault, and
   developer-diagnostics reviews and fix credible findings.
6. Update Runtime, diagnostics, security, benchmark, and troubleshooting docs.
7. Create `RUNTIME_V0_8_REPORT.md`, record the exact checkpoint commit, and
   leave a clean worktree before beginning v0.9.

Manual live Process Tap, audible device, provider-network, and graphical MCP
host checks remain explicitly **NOT RUN** unless a human actually performs
them. Their absence does not excuse any automatable release gate.

