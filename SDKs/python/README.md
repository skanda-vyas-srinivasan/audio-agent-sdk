# Sonexis Python SDK

The source-aware, bidirectional async SDK for Sonexis Runtime v0.5. It connects
only to the local Unix-domain Runtime and keeps Core Audio details out of
application code. The core package has no runtime dependencies and supports
Python 3.9+.

## Install for repository development

```sh
cd /path/to/Sonexis
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

## Play realtime audio

The Runtime, rather than the Python process, owns the selected output device:

```python
import asyncio
from sonexis import AudioFormat, Sonexis

async def play(model_audio):
    async with Sonexis() as sx:
        async with await sx.playback(
            destination="default",
            format=AudioFormat.openai_realtime_output(),
            target_buffer_milliseconds=60,
        ) as output:
            async for pcm_chunk in model_audio:
                await output.write(pcm_chunk)

# Call `await play(model_audio)` from your application's async entry point.
```

`write()` accepts `bytes`, `bytearray`, or `memoryview` containing whole,
interleaved PCM sample frames. It serializes concurrent callers and splits
large chunks into protocol packets no longer than 200 ms. Awaiting `write()`
applies Unix-socket backpressure; the SDK does not add an unbounded queue.
Supply `timestamp_ns=` when a producer has a stream-relative presentation
timestamp. Otherwise the SDK derives continuous timestamps from frames sent.

Normal context-manager exit sends EOS and waits briefly for the Runtime to
drain. `await output.cancel()` is the barge-in primitive: it closes the stream
without EOS and asks the Runtime to discard buffered playback. `flush()`
discards queued audio while keeping the logical session, attaches the new
stream epoch returned by the Runtime, and resets sequence/timestamp state.

Use `await sx.output_destinations()` to enumerate typed
`AudioOutputDestination` values. `await output.refresh()` or
`await sx.output_status(output.info.id)` returns `OutputInfo` and
`OutputMetrics`, including input/rendered/dropped frames, underruns, overruns,
queue depth, buffered duration, conversion work, route changes, and whether a
producer is attached. The `default` destination follows the current macOS
default output device. A Runtime without the v0.4 `output_sessions` capability
fails these calls with `unsupported_capability` instead of sending unsupported
commands.

Installed loopback HAL devices are returned as `virtual_input` destinations
when recognizable and can be selected by their `coreaudio:<UID>` ID. Sonexis
v0.4 does not install a virtual driver; destination enumeration is the
authoritative source of availability.

Capture and output can also be owned together without imposing agent policy:

```python
async with Sonexis() as sx:
    async with sx.duplex(
        "Discord",
        input_format=AudioFormat.gemini_live(),
        output_format=AudioFormat.gemini_live_output(),
    ) as session:
        async for frame in session.input:
            ...
            await session.output.write(response_pcm)
```

The application still decides turn-taking and feedback behavior. Call
`await session.output.flush()` to discard a partial response while keeping the
duplex session, or `cancel()` to tear output down immediately.

For a public-API-only loop with a fake passthrough model, negotiate the same
format on both sides. Real model output must instead match `output_format`:

```python
import asyncio
from sonexis import AudioFormat, Sonexis

async def main():
    format = AudioFormat.speech_16k()
    async with Sonexis() as sx:
        async with sx.duplex(
            "Discord", input_format=format, output_format=format
        ) as session:
            async for frame in session.input:
                # Replace this passthrough with a model producing `format`.
                await session.output.write(frame.data)

asyncio.run(main())
```

Use headphones for passthrough/duplex experiments; Sonexis does not implement
acoustic echo cancellation.

The output data plane uses the same 64-byte SXPC v2 PCM envelope as capture,
but in the client-to-Runtime direction. Continuous audio never travels in JSON
control requests.

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
AudioFormat.openai_realtime_output()  # PCM16 mono, 24 kHz
AudioFormat.gemini_live_output()      # PCM16 mono, 24 kHz
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
from sonexis.providers import GeminiLiveSink, GeminiTurnDetectionConfig

async with Sonexis() as sx:
    turns = GeminiTurnDetectionConfig(silence_duration_ms=1200)
    async with await GeminiLiveSink.connect(turn_detection=turns) as model:
        async with await sx.capture(
            "Google Chrome", format=AudioFormat.gemini_live()
        ) as stream:
            async for frame in stream:
                await model.send_audio(frame)
```

OpenAI reads `OPENAI_API_KEY`; Gemini reads `GEMINI_API_KEY` and optionally
`GEMINI_LIVE_MODEL`. Each sink accepts one ordered Sonexis stream; create one
sink per source label. No adapter logs or persists audio or credentials. Network
behavior must be validated with the developer's own provider account.

Gemini uses hybrid VAD by default: server automatic VAD remains enabled while
the adapter buffers a short activity onset and sends one `audio_stream_end`
after a debounced local pause. Silence after finalization is not transmitted,
and new meaningful activity reopens the stream. Configure start/end RMS,
minimum activity, and silence duration with `GeminiTurnDetectionConfig`, or
inject the SDK's `VoiceActivityDetector` extension for speech-aware detection.

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
