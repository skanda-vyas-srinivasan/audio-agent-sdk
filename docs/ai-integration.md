# Building AI audio applications with Sonexis

## Boundary

Sonexis supplies local, source-aware audio infrastructure. It discovers macOS
applications, captures them with Process Taps, normalizes PCM, preserves source
identity, and delivers bounded realtime streams. It does not transcribe audio,
run a model, remember conversations, synthesize speech, or send data to a cloud
service unless application code explicitly adds a provider adapter.

```text
application audio -> Sonexis Runtime -> public SDK -> optional provider adapter
```

Provider code never enters the capture core or Runtime protocol.

## Quickstart

Build and start the signed Runtime as documented in
[`sonexis-runtime.md`](sonexis-runtime.md), then install the Python SDK:

```sh
cd ~/Sonexis
/usr/bin/python3 -m venv --system-site-packages .venv
. .venv/bin/activate
python -m pip install --no-deps --no-build-isolation -e SDKs/python
```

```python
import asyncio
from sonexis import Sonexis

async def main():
    async with Sonexis() as sx:
        async with await sx.capture("Spotify") as stream:
            async for frame in stream:
                print(frame.source.name, frame.sequence, len(frame.data))

asyncio.run(main())
```

Selectors may be an `AudioSource`, Runtime source ID, bundle identifier, PID
passed as an integer, or exact application name. Numeric strings remain string
selectors. Sonexis never fuzzy-picks an ambiguous name.

## Source-aware frames

Each Python frame exposes source, session, and stream IDs; application name and
bundle identifier; sequence; session-relative timestamp; format; SDK receipt
time; discontinuity; and known drops. Source metadata is resolved once at
capture start and attached in the SDK, so variable strings are not duplicated
in the 64-byte realtime header.

`estimated_capture_at_ns` combines Runtime session-start and media position for
coarse monotonic ordering. It is not a HAL host timestamp. Independent taps are
not guaranteed to be sample-accurately synchronized.

## Multiple labeled sources

```python
async with Sonexis() as sx:
    async with sx.session(max_queue_frames=128) as group:
        await group.add("conversation", "Discord")
        await group.add("media", "Spotify")
        async for item in group.frames():
            print(item.label, item.source.name, item.timestamp_ns)
```

The streams retain independent sessions, sequences, timestamps, buffers,
metrics, and lifecycle. Each label has a bounded, fairly drained packet queue.
A full label queue drops new frames and increments aggregate and per-label
PCM-sample-frame counters; the next retained labeled frame reports local
discontinuity. Runtime-side drops remain visible on each frame/session. No
anonymous mix is produced.

Run `Examples/multi-source-runtime.py Discord Spotify` for a live demonstration.

## OpenAI GPT-Live

Install the optional official SDK and keep the API key in the environment:

```sh
python -m pip install -e 'SDKs/python[openai]'
export OPENAI_API_KEY='...'
python Examples/audio-agent/audio_agent.py --provider openai --source Discord
```

`AudioFormat.openai_realtime()` requests mono PCM16LE at 24 kHz. The adapter
base64-encodes complete PCM samples and uses the official SDK's GPT-Live
`session.input_audio.append` interface. The current implementation follows the
official server WebSocket guide:
<https://developers.openai.com/api/docs/guides/voice-websockets>.

## Gemini Live

```sh
python -m pip install -e 'SDKs/python[gemini]'
export GEMINI_API_KEY='...'
export GEMINI_LIVE_MODEL='gemini-3.8-live'  # optional/current model selection
python Examples/audio-agent/audio_agent.py --provider gemini --source Discord
```

`AudioFormat.gemini_live()` requests raw mono PCM16LE at 16 kHz. The adapter
uses `send_realtime_input` with `audio/pcm;rate=16000`, matching Google's Live
API capability guide: <https://ai.google.dev/gemini-api/docs/live-api/capabilities>.

Both adapters require Python 3.10+, accept one ordered source stream per sink,
and accept injected sessions/transports for credential-free tests.
Provider connection, availability, quota, response latency, and model behavior
still require manual validation with the developer's account.

## Reference audio agent

`Examples/audio-agent/audio_agent.py` is an external application importing only
public SDK APIs. It selects and switches sources, sends frames to OpenAI,
Gemini, or an offline mock, prints provider events and stream/drop/latency
statistics, watches source/runtime lifecycle events, optionally writes PCM/WAV,
and shuts down cleanly. Its README contains exact commands.

## Replay and activity

`ReplayStream.from_wav` and `.from_pcm` generate deterministic source-aware
frames with sequence and timestamps. Realtime pacing is optional. Replay tests
SDK consumers and adapters without requesting macOS capture permission; the
existing Runtime integration harness separately tests real protocol-v2 binary
framing with synthetic PCM.

`measure_activity(frame)` computes normalized RMS/peak outside the realtime
callback. Its `active` flag means non-silent signal, not speech. Applications
may supply a real VAD through the `VoiceActivityDetector` protocol; Sonexis does
not ship an unvalidated speech detector.

## MCP control plane

Install `SDKs/python[mcp]` under Python 3.10+ and run:

```sh
python -m sonexis.mcp_server
```

The tools list/resolve sources and query Runtime/session diagnostics. Starting
or stopping capture requires `--allow-capture`; this makes accidental agent
mutation harder. The result tells a consumer to call
`await sx.attach_capture(session_id)` with the SDK. Audio never passes through
MCP. The MCP control connection continues to own that session and must remain
alive until capture stops.

## Latency and failure semantics

`LatencyTracker` computes bounded p50/p95/p99 estimates from the Runtime
presentation coordinate to SDK receipt. Provider send receipts add the local
send time. They exclude network/model response latency, and the presentation
estimate is not true Process Tap latency.

Structured SDK errors distinguish source not found/ambiguous/unavailable,
permission denial, unsupported format, session limits, slow consumers,
terminal capture failure, Runtime connection/protocol failure, and provider
failure. `retryable` is advisory. Reconnection never silently restarts captures
or rebinds a relaunched application.

## Privacy and security

- Runtime and MCP are local-only; Runtime authenticates the peer UID.
- The macOS user account is the trust boundary. Same-UID unsandboxed processes
  can use Runtime's granted capture permission.
- MCP mutation is disabled by default.
- Provider keys stay in environment/process configuration and are never logged.
- Audio is not persisted unless the application explicitly chooses an output.
- Example/CLI recordings use mode `0600` and refuse symbolic links; they remain
  sensitive files and are not automatically deleted or excluded from Git.
- Diagnostics contain counters and metadata, not PCM payloads.
- Source names may reveal which applications are running; treat diagnostic
  output as private local data.
