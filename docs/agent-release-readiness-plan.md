# AudioPlane agent pre-release readiness plan

## Scope

This checkpoint hardens the existing source-aware capture, realtime-provider,
and Runtime playback path. It does not add another provider, change the Runtime
protocol, or publish a release. The deliverable is a local, recoverable
pre-release commit that can be validated with authenticated Gemini/OpenAI
sessions before a release decision.

## Current state

The Runtime already supplies bounded capture and output planes. The Python SDK
contains provider-neutral events plus Gemini Live and OpenAI Realtime adapters.
The reference agent supports source capture, hybrid Gemini activity detection,
output transcription, response playback, and optional Gemini barge-in.

Recent authenticated testing exposed three integration hazards:

1. provider sends can stall and let captured audio become stale;
2. provider audio can arrive in tiny or bursty chunks that are unsuitable for
   direct Runtime writes;
3. response playback and input activity can overlap without an explicit,
   observable interruption policy.

Those paths are now bounded, but the orchestration lives primarily in an
example script and lacks a single deterministic release gate.

## Work plan

1. Move the reusable agent orchestration into the installed Python package and
   keep the example as a public-API-only wrapper.
2. Add `audioplane agent` with lazy provider imports so the base CLI still
   works without optional AI dependencies.
3. Add structured, privacy-preserving turn diagnostics. Track local activity,
   input finalization, provider response start/completion/interruption, output
   start/flush, queue high-water marks, and dropped input. Do not persist PCM,
   credentials, or transcript text.
4. Add an opt-in live validation mode that prints concise per-turn timing and a
   final PASS/WARN/FAIL summary.
5. Build a seeded torture/fault harness covering randomized provider chunking,
   stalls, queue overflow, interruption epochs, tiny PCM tails, cancellation,
   disconnects, and rapid lifecycle churn. Provide a bounded default run and a
   million-transition release run.
6. Run Python, Runtime input/output, stress, soak, TSan, packaging, examples,
   and release gates. Fix credible failures before declaring readiness.

## Release gates

- no unbounded capture-to-provider or provider-to-output queue;
- no duplicate local finalization edge for a single activity segment;
- no Runtime packet shorter than one millisecond;
- response playback never blocks the provider receive loop;
- barge-in invalidates queued stale response audio and flushes Runtime output;
- cancellation leaves no worker tasks or sessions behind;
- queue shedding and audio drops are explicit in diagnostics;
- deterministic torture run completes at least 1,000,000 state transitions;
- existing Runtime and SDK regression suites pass;
- clean local package artifacts build and install;
- no remote push, package publication, tag, or release is performed.

## Authenticated validation remaining

Automated tests cannot prove provider/network behavior or audible routing. The
release candidate still requires two authenticated live runs, including one
Gemini barge-in run, using the documented command. These remain `NOT RUN` until
the operator performs them; automated readiness does not relabel them as passed.

