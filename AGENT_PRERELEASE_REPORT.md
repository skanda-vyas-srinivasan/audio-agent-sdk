# AudioPlane realtime agent pre-release report

Date: 2026-09-28

Repository: `/Users/skandavyas/audio-agent-sdk`

Branch: `main` (local commits only)

## Result

The capture -> provider -> Runtime-output reference pipeline is at an automated
pre-release checkpoint. The orchestration is installed with the Python package
and available as `audioplane agent`; the file under `Examples/audio-agent` is
now only a compatibility wrapper around that implementation.

No tag, remote push, package publication, GitHub release, or other release
action was performed.

## Agent pipeline

The packaged pipeline provides:

- live application/microphone capture or deterministic replay;
- mock, Gemini Live, and OpenAI Realtime consumers;
- bounded capture-to-provider forwarding with drop-oldest freshness policy;
- Gemini hybrid local activity detection while retaining server automatic VAD;
- optional Gemini barge-in;
- bounded, independently scheduled provider-response playback;
- 50 ms Runtime output packets with a maximum 150 ms intentional lead;
- legal padding of provider tails shorter than Runtime's 1 ms minimum;
- response-epoch invalidation plus Runtime flush on interruption;
- output transcription and opt-in raw diagnostics;
- private PCM/WAV recording only when explicitly requested.

The provider input queue is limited to 32 capture packets. A stalled provider
cannot make memory grow without bound: oldest packets are discarded, the next
delivered frame reports a discontinuity and exact dropped-frame count, and the
CLI reports both drops and queue high-water mark.

The provider output queue is limited by both item count (64 by default) and
payload bytes (4 MiB by default). Exhaustion is a visible terminal playback
failure rather than silent growth. Playback runs outside the provider receive
loop, so slow Runtime output cannot stop receipt of completion/interruption
events.

## Barge-in behavior

Gemini defaults to non-interruptible response behavior because application
audio often contains continuous sound. During that default mode, overlapping
capture is intentionally discarded rather than accumulated into a stale turn.

`--gemini-barge-in` selects Gemini's server interruption policy and keeps live
input flowing. When Gemini emits an interruption, AudioPlane:

1. advances the local response epoch;
2. discards queued stale provider speech;
3. prevents an in-flight paced chunk from writing after its wait;
4. calls the Runtime output session's `flush()` primitive;
5. accepts the next response on the new epoch.

This is digital queue cancellation, not acoustic echo cancellation. Headphones
remain recommended when physical speaker output could feed the captured source.

## Live validation

`--validate-live` adds privacy-safe per-turn diagnostics for:

- local activity start/end;
- successful input finalization;
- provider response start/completion/interruption;
- first Runtime output write;
- interruption flush;
- capture latency p95;
- Runtime and provider-input drops;
- provider queue high-water mark;
- missing, duplicate, or overlapping lifecycle edges.

`--validation-json PATH` writes the final report as a user-owned `0600` regular
file and refuses symbolic links. It contains timing/counters only—never PCM,
credentials, or transcript text. Provider transcription remains behind normal
terminal output/`--debug` and is deliberately separate.

## Automated validation

The complete automated release gate passed on 2026-09-28:

- Swift package debug build: **PASSED**
- standalone engine package tests: **4 passed**
- Runtime protocol/core/output/integration tests: **PASSED**
- Runtime malformed/fuzz corpus: **PASSED**
- Runtime capture/output stress: **1,000 + 1,000 cycles, PASSED**
- Runtime output-ring concurrent TSan stress: **PASSED**
- Python SDK/agent suite: **123 passed** during the final gate
- TypeScript suite: **29 passed**
- Python wheel and sdist clean-environment install: **PASSED**
- TypeScript tarball and external consumer typecheck: **PASSED**
- public example import/help smoke: **PASSED**
- signed Runtime/CLI metadata and signature checks: **PASSED**
- development installer lifecycle/tamper preservation: **PASSED**
- AudioPlane Input ring-buffer tests: **PASSED**
- AudioPlane Input driver contract tests: **PASSED**
- AudioPlane Input ring-buffer TSan test: **PASSED**
- universal signed HAL bundle verification: **PASSED**

The seeded agent torture gate completed **1,009,497** state transitions in
**2.76 seconds** on this development machine. It covered a fully stalled
provider, one million bounded enqueue/drop transitions, exact discontinuity
accounting, 1,000 randomized response turns, arbitrary provider chunk sizes,
PCM integrity/order, pacing bounds, 1,000 interruption cycles, output
disappearance, explicit terminal errors, and worker-task cleanup.

Observed Runtime stress retained-RSS growth remained within the existing gate:
approximately 6.2 MiB without TSan and 42.2 MiB under TSan instrumentation;
file-descriptor growth was 2 in both runs. These figures are test-process
measurements, not live provider latency claims.

## Automated commands

```bash
cd /Users/skandavyas/audio-agent-sdk
./Scripts/test-python-sdk.sh
./Scripts/test-agent-torture.sh
./Scripts/test-runtime-release.sh
```

## Authenticated manual validation

Earlier code successfully completed authenticated Chrome -> Runtime -> Gemini
semantic capture and generated response playback. The final checkpoint in this
report adds packaged CLI/diagnostics and interruption hardening after that run.
Credentials were not available to this process, so the following final-build
tests are honestly classified **NOT RUN**:

- two authenticated Gemini sessions using the packaged `audioplane agent`;
- early, middle, and late response barge-in with audible flush confirmation;
- a 20-turn authenticated conversation;
- 30-minute authenticated provider soak;
- authenticated OpenAI Realtime response playback;
- human confirmation of physical speaker/headphone audio quality.

Exact Gemini command:

```bash
cd /Users/skandavyas/audio-agent-sdk
export GEMINI_API_KEY='YOUR_KEY'

audioplane agent \
  --provider gemini \
  --source "Google Chrome" \
  --response-output coreaudio:com.audioplane.input.device \
  --gemini-barge-in \
  --validate-live \
  --validation-json /tmp/audioplane-live-validation.json \
  --debug
```

Speak/play one short turn, one long turn, interrupt Gemini near the beginning,
middle, and end of its response, and then let a final response finish. Expected:
one input-finalization edge per local segment, prompt interruption, no stale
speech after flush, no accumulating capture latency, and zero drops under
normal device conditions.

## Known limitations

- Provider/network/model response latency is external to AudioPlane and can
  vary materially even when capture latency is low.
- The default local activity detector is energy/hysteresis based, not semantic
  speech recognition. A custom `VoiceActivityDetector` remains the extension
  point for difficult music/noise environments.
- AudioPlane does not implement acoustic echo cancellation.
- AudioPlane Input must be selected by the receiving application; AudioPlane
  intentionally does not rewrite application device settings automatically.
- OpenAI and final post-hardening Gemini network paths still require the manual
  credential-backed matrix above.
- Python and TypeScript artifacts are locally buildable but remain unpublished.

## Local commits in this checkpoint

- `d7ac1aa` — define the pre-release stability gate
- `0dc1743` — package and instrument the realtime agent pipeline
- `7ba6d46` — add deterministic torture and fault gate
- `abacbd5` — harden diagnostics and release gates

The final report/package-polish commit contains this document and the branded
`audioplane.providers` import surface. All commits are local and signed.
Nothing was pushed.

## Release decision

Automated release criteria are satisfied. Release action is intentionally
paused. The recommended next human action is the authenticated Gemini barge-in
matrix above, followed by review of the generated validation JSON. Only after
that should a tag, push, registry publication, or GitHub release be considered.

## Live acceptance finding: first utterance / missing local end (2026-09-29)

The developer's subsequent microphone test showed live audio with zero Runtime
or provider-queue drops, but sometimes no response until a later utterance.
In a failed run, the visible `audio_stream_end` appeared only after Ctrl-C.
That is a failed live acceptance result; earlier automated qualification does
not prove that the conversation path is reliable in the developer's room.

An offline regression reproduced a concrete onset defect: five 200 ms voiced
intervals separated by 40 ms quieter intervals resulted in **zero bytes sent**
to Gemini, while a subsequent 400 ms sustained interval was sent. The onset
counter previously reset on every quiet packet. Separately, the legacy fixed
energy end threshold can keep an active turn open in ambient noise, which is
consistent with finalization occurring only at shutdown. The logs do not prove
which condition affected every unsuccessful live attempt.

The local fix adds bounded onset-gap tolerance and an optional WebRTC speech
classifier using the existing public VAD extension. The packaged Gemini CLI
defaults to speech classification, confirms 100 ms of speech, tolerates 100 ms
onset gaps, and finalizes after 1,200 ms of non-speech while retaining Gemini's
server automatic VAD. The direct sink API retains energy detection by default.
Debug input-level/state output is rate-limited to once per second. No Runtime
capture/data-plane or HAL implementation changed.

Validation for this fix:

- onset regression, arbitrary PCM packet boundaries, bounded sparse-noise
  buffering, noise-held-open turn prevention with injected classification,
  reopening, and optional dependency/configuration tests: **PASSED**;
- real WebRTC native classifier over 1,000 variable-size silent packets:
  **PASSED** in the developer virtual environment;
- offline macOS synthesized speech (4.03 seconds) at 16 kHz, fed in 171-sample
  packets with silence and seeded stationary noise at RMS 0.012: **PASSED**,
  one start and one end before cleanup in each case. This exercises the actual
  WebRTC library and adapter but is not an authenticated provider test;
- final microphone/Gemini retest after this fix: **NOT RUN**.

The final SDK suite in the actual developer virtual environment passed **137
tests**, with both native speech tests enabled. The existing seeded agent
torture gate passed **1,009,497 transitions**, **1,000 response turns**, and
**1,000 interruptions** in 2.88 seconds. The offline native speech test is
repeatable with `./Scripts/test-gemini-speech-vad.sh`; it synthesizes public
test words to temporary files, checks the real WebRTC classifier with silence
and seeded noise, and deletes its fixtures. No private microphone recordings
were collected for these tests.

Rerun with the same terminal's existing `GEMINI_API_KEY` and headphones selected
as the macOS output:

```sh
cd /Users/skandavyas/audio-agent-sdk
.venv/bin/audioplane agent \
  --provider gemini \
  --source 'MacBook Pro Microphone' \
  --response-output default \
  --gemini-vad webrtc \
  --gemini-barge-in \
  --validate-live \
  --validation-json /tmp/audioplane-final-validation.json \
  --debug
```
