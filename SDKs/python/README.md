# Sonexis Python SDK

The source-aware async SDK for Sonexis Runtime v0.3. It connects only to the
local Unix-domain Runtime and keeps Core Audio details out of application code.
The core package has no runtime dependencies and supports Python 3.9+.

## Install for repository development

```sh
cd ~/Sonexis
/usr/bin/python3 -m venv --system-site-packages .venv
. .venv/bin/activate
python -m pip install --no-deps --no-build-isolation -e SDKs/python
```

For completely offline testing, installation is unnecessary:

```sh
PYTHONPATH="$PWD/SDKs/python/src" /usr/bin/python3 -m unittest discover \
  -s SDKs/python/tests -p 'test_*.py' -v
```

## Capture one application

```python
import asyncio
from sonexis import Sonexis

async def main():
    async with Sonexis() as sx:
        async with await sx.capture("Discord") as stream:
            async for frame in stream:
                print(frame.source.name, frame.timestamp_ns, len(frame.data))

asyncio.run(main())
```

`capture` accepts a Runtime source ID, bundle identifier, PID passed as a Python
`int`, exact application name, or `AudioSource`. A numeric string remains a
string selector. A name must resolve uniquely; the SDK raises
`AmbiguousSourceError` rather than guessing. Use `find_sources`, `get_source`,
or `wait_for_source` for discovery and applications that launch later.

Every delivered `AudioFrame` includes its immutable source snapshot, session and
stream IDs, sequence, format, session-relative timestamp, discontinuity/drop
state, and SDK receipt time. `estimated_capture_at_ns` is an approximate Runtime
presentation coordinate—not a preserved Core Audio host timestamp.

## Multiple labeled sources

```python
async with Sonexis() as sx:
    async with sx.session() as group:
        await group.add("conversation", "Discord")
        await group.add("media", "Spotify")

        async for item in group.frames():
            print(item.label, item.source.name, item.timestamp_ns)
```

Captures remain independent and are never mixed. Every label has a fair queue
bounded to `max_queue_frames` `AudioFrame` packets. `group.dropped_frames` and
`dropped_frames_by_label` count lost PCM sample frames; the next retained frame
reports a local discontinuity. Independent Process Taps do not promise sample-accurate
cross-application synchronization.

## Format presets

```python
from sonexis import AudioFormat

AudioFormat.speech_16k()
AudioFormat.openai_realtime()  # PCM16 mono, 24 kHz
AudioFormat.gemini_live()      # PCM16 mono, 16 kHz
```

These are convenience values. The Runtime handshake remains authoritative for
supported formats.

## Optional realtime providers

Provider adapters are isolated above the SDK and require opt-in dependencies:

The dependency-free core supports Python 3.9. Provider and MCP extras require
Python 3.10 or newer because their official upstream SDKs do. Create a separate
environment with any installed 3.10+ interpreter before installing an extra:

```sh
python3.10 -m venv .venv-ai
. .venv-ai/bin/activate
python -m pip install -e 'SDKs/python[openai]'
```

```sh
python -m pip install -e 'SDKs/python[openai]'
python -m pip install -e 'SDKs/python[gemini]'
```

```python
from sonexis import AudioFormat, Sonexis
from sonexis.providers import OpenAIRealtimeSink

async with Sonexis() as sx:
    async with await OpenAIRealtimeSink.connect() as model:
        async with await sx.capture(
            "Discord", format=AudioFormat.openai_realtime()
        ) as stream:
            async for frame in stream:
                await model.send_audio(frame)
```

OpenAI reads `OPENAI_API_KEY`; Gemini reads `GEMINI_API_KEY` and optionally
`GEMINI_LIVE_MODEL`. Each sink accepts one ordered Sonexis stream; create one
sink per source label. No adapter logs or persists audio or credentials. Network
behavior must be validated with the developer's own provider account.

## Replay, activity, and diagnostics

`ReplayStream.from_wav(...)` and `ReplayStream.from_pcm(...)` yield normal
source-aware frames, with optional realtime pacing, for deterministic adapter
tests. `measure_activity(frame)` reports RMS/peak and non-silence activity; it
does not claim to detect speech. Applications may implement the
`VoiceActivityDetector` protocol with their chosen VAD.

`LatencyTracker` keeps a bounded sample window and reports p50/p95/p99 estimates
from Runtime session presentation time to SDK receipt. These estimates exclude
provider response/network latency and are not live Process Tap capture latency.

## MCP control plane

The optional MCP server requires Python 3.10+ and the `mcp` extra:

```sh
python -m pip install -e 'SDKs/python[mcp]'
python -m sonexis.mcp_server
```

Source/session/diagnostic tools are local and low-bandwidth. Starting or stopping
capture is disabled unless the server is launched with `--allow-capture`. MCP
never carries PCM. Attach an audio process through the binary data plane:

```python
async with Sonexis() as sx:
    async with await sx.attach_capture(session_id) as stream:
        async for frame in stream:
            ...
```

The MCP process owns sessions it creates and must remain running; closing its
Runtime control connection stops those captures.

## Failure and reconnect behavior

Errors preserve a stable `code`, `message`, `retryable`, and `details` mapping.
Specialized exceptions cover missing/ambiguous/unavailable sources, permission,
formats, session limits, slow consumers, protocol failures, connection failures,
capture failures, and provider failures. `reconnect()` creates a fresh control
connection but never silently recreates captures or binds to a relaunched app.
