# AudioPlane realtime agent

This terminal reference application is installed as `audioplane agent` and
consumes only public AudioPlane Python APIs. It can send one live application
or microphone stream to OpenAI Realtime or Gemini Live, or exercise the same
source-aware flow entirely offline with a mock provider and recorded audio.
`audio_agent.py` remains a thin compatibility wrapper around the packaged
implementation.

From the repository root, install the SDK in a virtual environment:

```sh
/usr/bin/python3 -m venv --system-site-packages .venv
. .venv/bin/activate
python -m pip install --no-deps --no-build-isolation -e SDKs/python
```

Start `sonexis-runtime`, then run the credential-free path:

```sh
audioplane agent --provider mock
```

Choose a source by number. While capturing, enter `s` to switch sources or `q` to stop. The application prints stream/drop/latency statistics, watches for source removal and Runtime shutdown, and cleans up its capture on exit. `--output capture.wav` writes PCM16 audio for inspection.
The mock provider emits its deterministic response after five seconds of input
audio, so a shorter replay or capture intentionally produces no response.

Provider modes are optional and keep credentials in the environment:

Provider extras require Python 3.10 or newer; the offline mock and core SDK
remain compatible with Python 3.9. Create and activate a 3.10+ environment (for
example, `python3.10 -m venv .venv-ai`) before the provider install commands.

```sh
python -m pip install -e 'SDKs/python[openai]'
export OPENAI_API_KEY='...'
audioplane agent --provider openai --source Spotify

python -m pip install -e 'SDKs/python[gemini]'
export GEMINI_API_KEY='...'
audioplane agent \
  --provider gemini --source 'Google Chrome' \
  --response-output default --debug
```

Gemini mode keeps Gemini's automatic VAD enabled and adds local end detection.
After at least 250 ms of meaningful activity, 1,200 ms below the end threshold
sends one `audio_stream_end`; additional silence is suppressed until meaningful
activity begins again. `--debug` reports local activity edges, stream-end sends,
Gemini response starts/turn completion, and raw returned-audio byte counts.
Readable output transcription is printed normally. Tune application audio with:

```sh
audioplane agent \
  --provider gemini --source 'Google Chrome' --debug \
  --gemini-start-threshold 0.015 \
  --gemini-end-threshold 0.008 \
  --gemini-min-activity-ms 250 \
  --gemini-silence-ms 1200
```

The start/end thresholds are normalized PCM RMS values. Raise them when steady
background audio opens turns; lower them when quiet speech is missed. Keep the
end threshold below the start threshold. A custom `VoiceActivityDetector` can
be supplied to `GeminiLiveSink` when energy thresholds are insufficient.

The reference app defaults to `gemini-3.1-flash-live-preview` so each finalized
application-audio turn requests a response. Select another model explicitly
with `--gemini-model MODEL` or `GEMINI_LIVE_MODEL`. Models with proactive audio
may intentionally stay silent for passive commentary even after a valid turn.

The live reference path keeps capture reading independently of provider sends
through a bounded 32-packet, drop-oldest queue. If Gemini stalls, current audio
replaces stale audio and the next delivered frame carries a discontinuity plus
the exact dropped-frame count. While a non-interruptible Gemini response is
active, new input is intentionally discarded so turns cannot accumulate tens
of seconds behind the response. `--gemini-barge-in` disables that suppression
and allows new activity to interrupt the active response. An interruption also
discards queued model speech and flushes Runtime's render buffer, so stale bot
audio does not continue playing after the barge-in. Stream diagnostics report
input shedding separately as `provider_dropped` and `provider_queue_hwm`.

`--response-output DESTINATION` routes returned provider PCM through Sonexis
Runtime's bounded output plane. `--play-response` is shorthand for destination
`default`. This works for both Gemini and OpenAI and never imports a Python
playback library. Provider receive and output playback run independently: a
slow destination cannot freeze the model event stream, and a bounded queue
fails explicitly instead of growing without limit. Provider PCM is coalesced
into 50 ms output packets, paced to at most 150 ms ahead of realtime, and a
sub-millisecond final tail is silence-padded to Runtime's legal packet minimum.
This prevents bursty model delivery from overflowing Runtime's render queue.
Use `sonexisctl outputs` to select a fixed speaker/headphone or an installed
loopback device. Raw returned-audio byte diagnostics stay behind `--debug`.

Provider modes select their required Sonexis format preset automatically. No
credential or raw captured PCM is logged or stored unless `--output` is
explicitly supplied. Provider text/transcription and source/session identifiers
are printed to the terminal and may contain sensitive context. Recordings are
created as private regular files (`0600`), and symbolic-link targets are
refused.

For deterministic offline development, replay a matching PCM16 WAV:

```sh
audioplane agent \
  --provider mock \
  --replay /path/to/pcm16-mono-16khz.wav \
  --realtime-replay \
  --non-interactive
```

Use `--help` for socket, raw PCM, sample-rate, and channel options. Live OpenAI/Gemini network behavior still depends on the installed provider SDK, valid credentials, model availability, and the provider's current service API.

To exercise live capture, a deterministic mock response, and Runtime-owned
speaker output without provider credentials, use headphones and run:

```sh
audioplane agent \
  --provider mock \
  --source "Google Chrome" \
  --response-output default \
  --non-interactive
```

For an authenticated stability run, add `--validate-live`. AudioPlane prints a
privacy-safe PASS/WARN line for each completed turn and a final summary without
retaining PCM, credentials, or transcript text. `--validation-json PATH`
writes the same metadata to a private (`0600`) regular file:

```sh
audioplane agent \
  --provider gemini \
  --source "Google Chrome" \
  --response-output coreaudio:com.audioplane.input.device \
  --gemini-barge-in \
  --validate-live \
  --validation-json /tmp/audioplane-live-validation.json \
  --debug
```

`--debug` can print provider transcription and is therefore not privacy-safe
for shared logs. Validation JSON never contains transcript or PCM content.

Graceful `q`, Ctrl+C and SIGTERM persist validation metadata even if provider or
output cleanup fails. Cleanup waits are bounded (provider close: 7 seconds,
trailing events: 1 second, player close: 8 seconds, output client: 5 seconds;
SDK capture/input cleanup has its own bounded waits). Setup/source-selection
waits are also cancellable. SIGKILL, power loss, or a forcibly killed shell
cannot guarantee a final report. The terminal can lose its final summary when
plain `tee` exits on Ctrl+C; use `tee -i` to keep it alive through agent cleanup.
The JSON report does not depend on stdout remaining open.

Local activity segments are timing candidates, not provider turn IDs. Server
VAD can answer before a local end; these responses have no finalized-input
latency. Multiple candidate segments are reported as ambiguous, and segments
may receive no response. A single candidate's interval measures time since
local finalization; it does not prove provider causality. Validation summaries
include `correlation` and candidate segment indices and never substitute zero
for unknown or negative timing.
