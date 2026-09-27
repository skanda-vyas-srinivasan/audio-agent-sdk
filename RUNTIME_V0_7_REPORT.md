# Sonexis Runtime v0.7 report

## Executive summary

Runtime v0.7 matures Sonexis as an agent I/O substrate without changing
protocol v2 or either PCM data plane. Capture, playback, endpoint routing,
backpressure, signed distribution, and the v0.1-v0.6 compatibility surface are
unchanged. The release adds provider-neutral activity edges, correlated and
normalized provider events, safer multi-turn adapters, resilient labeled
multi-source policy, provider-neutral duplex defaults, a stricter control-only
MCP surface, and public-only reference bridges.

All work remained in `/Users/skandavyas/Sonexis-runtime-v04` on
`runtime-v0.4-bidirectional-audio`. The original worktree was not modified.

## Public activity and stream model

Python and TypeScript now provide a stream-affine `AudioActivityDetector` with:

- separate start/end thresholds;
- sustained-on and sustained-silence debounce;
- `idle`/`starting`/`active` state;
- edge-triggered source/session/stream-aware events;
- discontinuity reset; and
- optional application-provided speech classification.

Built-in classification is energy activity, not speech recognition. One
detector is required per Sonexis stream. Local multi-source queue loss marks the
forwarded frame discontinuous while the wrapper retains the separate local
drop count, avoiding both hidden resets and double accounting.

`MultiSourceSession(fail_fast=False)` lets one labeled capture fail while
healthy members continue. Terminal member errors remain observable even when
shutdown races the aggregate iterator.

## Provider adapters

OpenAI and Gemini use a shared composition helper for payload/format validation,
one-stream affinity, sequence ordering, and event correlation. Validation,
transport send, and sequence commit are serialized together. Cancellation
after provider dispatch makes the send epoch terminal because remote acceptance
is ambiguous; replaying the same frame cannot duplicate audio.

Provider events add normalized `response_started`/`response_completed` flags
and input source/session/stream identity while preserving raw provider event
types for compatibility. `raw` remains explicitly unstable.

Gemini now re-enters its turn-bounded receive iterator for multiple responses,
closes an active segment on a stream discontinuity, clears pre-gap onset
candidates, and retains server-side automatic VAD plus the existing local
hybrid finalization. Exactly-once end behavior and output transcription remain
covered. OpenAI rejects malformed output-audio base64 instead of presenting it
as text.

Provider errors remove unsanitized exception causes before propagation, so
standard traceback formatting cannot reveal common API-key/authorization forms.

## Duplex and examples

Python duplex startup/close has an explicit lifecycle and shared cleanup task.
Python and TypeScript default output format to the selected input format rather
than an OpenAI-specific preset. Both close input/output concurrently; barge-in
output discard is not delayed behind capture cleanup. Concurrent close callers
join the same work.

The reference audio agent creates one provider connection per selected source,
so interactive source switching cannot violate provider stream affinity.
Unexpected child-task failures cancel and join siblings. Its offline mock emits
a bounded deterministic tone, validates stream/sequence semantics like real
adapters, and proves capture -> mock -> Sonexis output without credentials.

Added examples:

- `Examples/provider-output.py` — compact public-API OpenAI input/output bridge;
- `Examples/multi-source-agent.py` — label-aware conversation/media policy; and
- `docs/agent-framework-integration.md` — the minimal Sonexis boundary for
  LiveKit, Pipecat, or a custom pipeline without adding framework dependencies.

## MCP control maturity

MCP remains stdio-only and never opens an audio data socket or carries PCM.
The default server registers only:

- Runtime compatibility/policy metadata;
- source listing/resolution;
- diagnostics; and
- output-destination discovery.

`--allow-capture` additionally registers list/get/start/stop capture tools.
They can inspect or mutate only sessions created by that MCP process. Results
omit `data_socket_path`; the session ID is the SDK attachment capability.
Start/stop bookkeeping resolves cancellation after dispatch so a sensitive
capture cannot become an untracked ghost. Failed stops retain ownership.

The official MCP 2.2.0 client validated server version/instructions, distinct
read-only and mutable inventories, non-null output schemas and annotations, and
bounded JSON error text without traceback logging. The current MCP Python SDK
represents tool failures as text with `isError=true`, not typed
`structuredContent`; this limitation is documented rather than hidden.

## Realtime and concurrency review

v0.7 changes are SDK consumer-task/provider-task work only; no Core Audio
callback or Runtime PCM plane changed. Independent review found and the release
fixed:

- provider validation outside the send lock, which allowed concurrent sequence
  regression or cross-stream mixing;
- reusable provider state after an ambiguously cancelled send;
- a Gemini discontinuity leaving a remote segment open;
- non-joinable TypeScript duplex close;
- delayed Python barge-in teardown;
- multi-source terminal errors lost during shutdown; and
- reference tasks escaping cleanup after an exception.

The full production output-ring and application TSan gates passed after these
fixes.

## Security and privacy review

The local trust boundary remains the macOS UID. Runtime binds no TCP port and
retains private Unix-socket permissions and peer checks. MCP mutation is absent
by default and process-owned when enabled. Provider credentials are read only
from explicit arguments/environment and sanitized causes cannot leak through
tracebacks.

Raw PCM is not logged by default. The reference agent does print provider
transcription/text and source/session identifiers; documentation now identifies
that derived text/metadata as sensitive terminal output. Optional recording
remains explicit, private `0600`, regular-file-only, and symlink-refusing.

## Automated validation

The full v0.7 gate passed on 2026-09-27 with Xcode 27.0/macOS 27 SDK:

- Debug Sonexis application build and every offline application regression;
- Runtime protocol, capture core, output core, integration, and fuzz suites;
- 1,000 capture starts/stops, 1,000 output starts/stops, 200 connection cycles,
  and 16 parallel sessions;
- production C output-ring stress under TSan and full app concurrency TSan;
- 80 Python SDK tests on the supported system Python 3.9;
- 23 TypeScript compile/runtime tests;
- every public example syntax/import/help smoke;
- Python wheel and sdist clean installs;
- TypeScript package, clean consumer import, and artifact-content checks;
- signed universal Release Runtime and CLI builds; and
- idempotent install/reinstall, foreground/background lifecycle, crash
  recovery, status, stop, and uninstall.

The official MCP v2 stdio conformance smoke passed separately in an isolated
temporary environment. It exercised both tool inventories and Runtime-unavailable
structured JSON error semantics.

## Stress and performance

The non-TSan stress run completed in 1.399 seconds with one descriptor of scoped
growth, 11,223,040 bytes peak RSS, and a 6,455,296-byte baseline. The TSan run
completed in 3.936 seconds with the same descriptor bound, 88,375,296 bytes peak
RSS, and a 53,264,384-byte baseline. No monotonic session/task leak was found.

v0.7 does not alter Runtime conversion, capture, or playback hot paths, so the
v0.6 converter/ring measurements in `docs/runtime-benchmarks.md` remain the
applicable performance baseline. No network/provider latency is attributed to
Sonexis.

## Independent reviews

- Provider/API audit found one-turn Gemini receive, partial-send cancellation,
  duplicated validation, provider-specific duplex defaults, and broken
  reference source switching. All correctness findings were fixed.
- External-developer audit found missing activity edges, aggregate failure
  policy, incomplete offline output proof, response correlation gaps, and
  confusing examples. Public primitives, resilient mode, mock audio, typed
  events, and focused examples were added.
- MCP audit found generic expected errors, null schemas/annotations, sensitive
  socket-path exposure, default mutation advertisement, and cross-client
  session control. The server now has explicit metadata/schema/policy and
  process-owned opt-in mutation.
- Realtime/concurrency review found provider ordering/cancellation races,
  discontinuity teardown, multi-source error loss, duplex close races, and task
  leaks. Focused regressions cover every fix.
- Security/privacy review found exception-chain credential leakage and MCP
  mutation ownership races. Both were fixed and regression-tested. It also
  clarified the MCP SDK's text-error limitation and derived-text privacy.

No unresolved P0/P1 issue remains in v0.7 scope.

## Manual validation

- Historical authenticated Chrome -> Sonexis -> Gemini semantic understanding,
  hybrid finalization, readable transcription, and zero input drops: **PASSED**
  during v0.3 validation; not rerun for v0.7.
- Historical real HAL playback/headphones/BlackHole: **PASSED** during v0.4;
  not rerun for v0.7.
- v0.7 authenticated multi-turn Gemini/OpenAI response playback: **NOT RUN**
  because no provider credential was used by this gate.
- v0.7 live capture -> mock -> physical playback: **NOT RUN**.
- third-party graphical MCP host: **NOT RUN**; official SDK stdio transport
  passed.

## Known limitations

- Sonexis does not provide acoustic echo cancellation or conversational policy.
- Activity means energy unless an application supplies a speech detector.
- One detector and one provider sink are required per independent input stream.
- Python has first-party provider adapters; TypeScript v0.7 provides the audio
  primitives but no bundled OpenAI/Gemini adapter or runnable provider example.
- LiveKit/Pipecat interoperability is documented at the type/lifecycle boundary,
  not network-validated against those frameworks.
- MCP tool errors are bounded JSON text because the current MCP SDK does not
  support typed structured error content.
- Same-UID processes remain trusted to capture and inject local audio.

## Exact quickstart

```sh
cd /Users/skandavyas/Sonexis-runtime-v04
Scripts/setup-runtime-dev.sh
Scripts/runtime-dev.sh start
sonexisctl sources
```

Install the SDK and exercise the credential-free agent/output path:

```sh
python3 -m venv .venv-runtime
. .venv-runtime/bin/activate
python -m pip install -e SDKs/python
python Examples/audio-agent/audio_agent.py \
  --provider mock \
  --source "Google Chrome" \
  --response-output default \
  --non-interactive
```

Use headphones to prevent acoustic feedback. For Gemini, install the `gemini`
extra, set `GEMINI_API_KEY`, and replace `--provider mock` with
`--provider gemini`.

## Commits

- `74907db` — plan v0.7 agent I/O maturity
- `5d577ef` — mature Python agent I/O primitives and MCP
- `4a05658` — align TypeScript activity/duplex/multi-source primitives
- `b1ee03a` — add agent integration documentation and examples
- `4152c52` — isolate stream activity and propagate reference failures
- `da63d05` — close independent review gaps
- `600b4af` — finalize the v0.7 report and release checkpoint

The clean v0.7 release checkpoint is
`600b4afec7ef259ef33f599c8584f7abf99f0b5b`.

## Next milestone

v0.8 should focus on all-day reliability and observability: long deterministic
soak, resource accounting, structured status/trace bundles without PCM or
transcripts, fault injection, measured multi-stream/duplex scaling, and another
independent security/realtime audit. It should not add a protocol v3 or new AI
framework unless reliability work exposes a concrete requirement.
