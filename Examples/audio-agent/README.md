# Sonexis audio agent

This terminal reference application consumes only the public `sonexis` Python API. It can send one live application stream to OpenAI Realtime or Gemini Live, or exercise the same source-aware flow entirely offline with a mock provider and recorded audio.

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
python Examples/audio-agent/audio_agent.py --provider gemini --source Discord
```

Provider modes select their required Sonexis format preset automatically. No credential or captured audio is logged or stored unless `--output` is explicitly supplied. Recordings are created as private regular files (`0600`), and symbolic-link targets are refused.

For deterministic offline development, replay a matching PCM16 WAV:

```sh
python Examples/audio-agent/audio_agent.py \
  --provider mock \
  --replay sample-16k-mono.wav \
  --realtime-replay \
  --non-interactive
```

Use `--help` for socket, raw PCM, sample-rate, and channel options. Live OpenAI/Gemini network behavior still depends on the installed provider SDK, valid credentials, model availability, and the provider's current service API.
