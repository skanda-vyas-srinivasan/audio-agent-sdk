# Sonexis audio agent

This terminal reference application consumes only the public `sonexis` Python API. It can send one live application or microphone stream to OpenAI Realtime or Gemini Live, or exercise the same source-aware flow entirely offline with a mock provider and recorded audio.

From the repository root, install the SDK in a virtual environment:

```sh
/usr/bin/python3 -m venv --system-site-packages .venv
. .venv/bin/activate
python -m pip install --no-deps --no-build-isolation -e SDKs/python
```

Start `sonexis-runtime`, then run the credential-free path:

```sh
python Examples/audio-agent/audio_agent.py --provider mock
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
python Examples/audio-agent/audio_agent.py --provider openai --source Spotify

python -m pip install -e 'SDKs/python[gemini]'
export GEMINI_API_KEY='...'
python Examples/audio-agent/audio_agent.py \
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
python Examples/audio-agent/audio_agent.py \
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

`--response-output DESTINATION` routes returned provider PCM through Sonexis
Runtime's bounded output plane. `--play-response` is shorthand for destination
`default`. This works for both Gemini and OpenAI and never imports a Python
playback library. Use `sonexisctl outputs` to select a fixed speaker/headphone
or an installed loopback device. Raw returned-audio byte diagnostics stay
behind `--debug`.

Provider modes select their required Sonexis format preset automatically. No
credential or raw captured PCM is logged or stored unless `--output` is
explicitly supplied. Provider text/transcription and source/session identifiers
are printed to the terminal and may contain sensitive context. Recordings are
created as private regular files (`0600`), and symbolic-link targets are
refused.

For deterministic offline development, replay a matching PCM16 WAV:

```sh
python Examples/audio-agent/audio_agent.py \
  --provider mock \
  --replay /path/to/pcm16-mono-16khz.wav \
  --realtime-replay \
  --non-interactive
```

Use `--help` for socket, raw PCM, sample-rate, and channel options. Live OpenAI/Gemini network behavior still depends on the installed provider SDK, valid credentials, model availability, and the provider's current service API.

To exercise live capture, a deterministic mock response, and Runtime-owned
speaker output without provider credentials, use headphones and run:

```sh
python Examples/audio-agent/audio_agent.py \
  --provider mock \
  --source "Google Chrome" \
  --response-output default \
  --non-interactive
```
