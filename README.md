# AudioPlane

**Programmable application-level audio I/O for macOS.**

AudioPlane lets local software capture labeled audio from individual desktop
applications and send realtime PCM back to speakers, headphones, or installed
loopback devices. It hides Core Audio Process Taps, device callbacks, format
conversion, socket framing, jitter buffering, and teardown behind typed Python
and TypeScript APIs.

```text
Chrome / Discord / Spotify          Generated audio
             |                            |
             v                            v
      source-aware capture         bounded playback
             |                            |
             +------ AudioPlane ----------+
                         |
                         v
                Python / TypeScript / MCP
```

AudioPlane is local infrastructure, not an AI assistant or transcription
service. Provider adapters for Gemini Live and OpenAI Realtime live above the
Runtime and use the same public audio APIs as any other client.

## What works

- Per-application capture through macOS Core Audio Process Taps
- Stable source identity with application name, bundle identifier, and PID
- PCM16 and Float32; mono or stereo; 16, 24, and 48 kHz
- Timestamped, sequenced binary PCM frames with discontinuity/drop metadata
- Multiple simultaneous sources, sessions, and clients
- Default-device, physical-device, and installed loopback playback
- Buildable first-party `AudioPlane Input` virtual microphone (manual install)
- Bounded capture, playback, jitter, and backpressure queues
- Source, capture, output, device, and Runtime lifecycle events
- Python async SDK, typed TypeScript SDK, CLI, and control-only MCP server
- Gemini Live and OpenAI Realtime adapters with provider-neutral audio APIs
- Diagnostics, deterministic replay, fuzzing, stress tests, and TSan coverage

## Requirements

- macOS 14.4 or newer
- Xcode command-line tools and Swift 5.9 or newer
- An Apple Development signing identity for live Process Tap permission
- Python 3.9 or newer for the Python SDK and `audioplane` CLI
- Node.js 18 or newer only when using the TypeScript SDK

The repository builds without the Sonexis consumer application or any sibling
checkout. Some internal Swift executable and module names retain the earlier
`Sonexis` prefix for v1.0 compatibility; they are ordinary source code owned by
this standalone repository, not links to another product.

## Quickstart

Clone the repository:

```bash
git clone https://github.com/skanda-vyas-srinivasan/audioplane.git
cd audioplane
```

Configure your Apple Development identity in Xcode, then build and install the
signed development Runtime:

```bash
./Scripts/setup-runtime-dev.sh
./Scripts/runtime-dev.sh start
```

The installer is user-local and does not use `sudo` or create a persistent
LaunchAgent. On first live capture, macOS should request application-audio
permission for the stable Runtime identity `com.sonexis.runtime`.

Install the developer CLI with `pipx`:

```bash
pipx install \
  "git+https://github.com/skanda-vyas-srinivasan/audioplane.git#subdirectory=SDKs/python"

audioplane version
audioplane doctor
audioplane sources
audioplane outputs
audioplane status
```

`pipx` installs the Python client tools, not the signed native Runtime. The
Runtime must be built and started separately because macOS grants Process Tap
permission to that signed executable.

## Capture an application

Install the SDK in a virtual environment:

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install \
  "git+https://github.com/skanda-vyas-srinivasan/audioplane.git#subdirectory=SDKs/python"
```

Then capture an application by exact name, source ID, bundle identifier, PID,
or typed source object:

```python
import asyncio

from audioplane import AudioPlane


async def main() -> None:
    async with AudioPlane() as audio:
        async with await audio.capture("Google Chrome") as stream:
            async for frame in stream:
                print(
                    frame.source.name,
                    frame.timestamp_ns,
                    frame.format.sample_rate,
                    len(frame.data),
                )


asyncio.run(main())
```

Human-readable names are accepted only when they resolve uniquely. AudioPlane
returns a structured ambiguity error instead of silently choosing a process.

For raw PCM validation, use the installed native diagnostic CLI:

```bash
export PATH="$HOME/Library/Application Support/SonexisRuntime/dev/bin:$PATH"

sonexisctl sources
sonexisctl capture SOURCE_ID --output /tmp/capture.pcm --debug
```

Press `Ctrl-C` to stop the foreground capture cleanly.

## Play audio

AudioPlane also accepts realtime client-to-Runtime PCM:

```python
from audioplane import AudioFormat, AudioPlane


async def play(chunks) -> None:
    async with AudioPlane() as audio:
        async with await audio.playback(
            destination="default",
            format=AudioFormat.openai_realtime_output(),
            target_buffer_milliseconds=60,
        ) as output:
            async for chunk in chunks:
                await output.write(chunk)
```

`write()` applies socket backpressure and splits large writes into bounded
protocol packets. `flush()` supports interruption/barge-in while retaining the
session; `cancel()` immediately discards buffered output.

To play a deterministic WAV file through the native CLI:

```bash
sonexisctl outputs
sonexisctl play /path/to/audio.wav --destination default --debug
```

To make generated audio appear as a microphone input to Discord, Zoom, or
another application, build AudioPlane's first-party virtual device:

```bash
./Scripts/build-audioplane-input-dev.sh
./Scripts/install-audioplane-input.sh
```

Installation is an explicit system change: the script visibly invokes `sudo`
to copy the exact signed bundle into `/Library/Audio/Plug-Ins/HAL`, but never
changes the default input/output device or restarts Core Audio. Restart the Mac,
select **AudioPlane Input** inside the receiving application, then locate its
exact destination ID:

```bash
audioplane outputs
sonexisctl play /path/to/audio.wav \
  --destination coreaudio:com.audioplane.input.device --debug
```

BlackHole remains supported as a fallback. The first-party driver is currently
a source-built developer preview and still requires the documented manual
end-to-end validation before a packaged release.

## Multiple labeled sources

Independent streams retain their identity and are never mixed automatically:

```python
async with AudioPlane() as audio:
    async with audio.session() as session:
        await session.add("conversation", "Discord")
        await session.add("media", "Spotify")

        async for item in session.frames():
            print(item.label, item.source.name, item.timestamp_ns)
```

AudioPlane preserves timestamps for each stream but does not claim
sample-accurate synchronization between independent application processes.

## Components

| Component | Purpose |
|---|---|
| `sonexis-runtime` | Signed native Runtime owning capture, playback, sessions, and local IPC |
| `sonexisctl` | Native diagnostics, capture, playback, event watching, and raw file validation |
| `audioplane` | `pipx`-installable developer CLI for discovery and Runtime health |
| `audioplane-mcp` | Optional low-bandwidth MCP control server; PCM never travels through MCP |
| `SDKs/python` | Primary async SDK, provider adapters, replay, activity/VAD, and duplex APIs |
| `SDKs/typescript` | Typed Node.js client with capture, output, events, and duplex APIs |
| `SonexisAudioEngine` | Repository-owned low-level Swift capture engine used by the Runtime |
| `AudioPlaneHALDriver` | First-party `AudioPlane Input` virtual microphone driver |

The previous `sonexis` Python import remains available as a compatibility alias.
New applications should use:

```python
from audioplane import AudioPlane
```

## Runtime architecture

The Runtime exposes two local-only Unix-domain-socket planes:

- **Control plane:** protocol-v2 JSON requests, responses, errors, capability
  negotiation, events, session lifecycle, and diagnostics.
- **Data plane:** compact binary PCM frames for capture and playback, including
  stream ID, sequence, timestamp, format, payload length, drop/discontinuity
  state, and EOS.

Realtime Core Audio callbacks never perform socket I/O, disk I/O, synchronous
logging, or unbounded allocation. Bounded ring buffers isolate callbacks from
conversion and client delivery. Slow consumers cause observable frame drops or
disconnection according to the documented queue policy rather than unbounded
memory growth.

See [Runtime architecture and protocol](docs/sonexis-runtime.md) and
[output audio](docs/output-audio.md) for wire formats and lifecycle rules.

## AI integrations

Optional adapters are installed explicitly:

```bash
python -m pip install -e "SDKs/python[gemini]"
python -m pip install -e "SDKs/python[openai]"
```

Reference examples live in [`Examples/audio-agent`](Examples/audio-agent) and
use only public SDK APIs. Provider credentials are read from environment
configuration and are never embedded in the Runtime. See
[AI integration](docs/ai-integration.md) for Gemini hybrid-VAD turn handling,
OpenAI Realtime, response playback, and source-aware multi-stream examples.

## Runtime lifecycle

```bash
./Scripts/runtime-dev.sh status
./Scripts/runtime-dev.sh logs
./Scripts/runtime-dev.sh stop
./Scripts/runtime-dev.sh foreground
./Scripts/uninstall-runtime-dev.sh
```

The development install lives under:

```text
~/Library/Application Support/SonexisRuntime/dev
```

## Development and tests

Build the native products and engine package:

```bash
swift build -c release
swift test --package-path SonexisAudioEngine
```

Run focused SDK/package tests:

```bash
./Scripts/test-python-sdk.sh
./Scripts/test-runtime-packages.sh
```

Run the complete automated release gate:

```bash
./Scripts/test-runtime-release.sh
```

The release gate covers Runtime protocol/core/output/integration/fuzz/stress
tests, Thread Sanitizer, Python tests and packaging, TypeScript tests and
packaging, embedded permission metadata, stable identifiers, and development
signing. Live Process Tap capture and audible physical-device output still
require manual macOS validation.

## Security and privacy

AudioPlane binds only to private, same-user Unix sockets and never exposes a
public network listener. The local macOS account is the trust boundary: another
unsandboxed process running as the same user can use the Runtime's granted
capture permission or inject audio into an output session. Do not run the
Runtime as root or relocate its sockets into a shared directory.

Audio is not logged or persisted by default. CLI recording is explicit, uses
private regular files, and rejects symbolic-link targets. Provider adapters
redact common credential forms from errors.

See the full [security model](docs/sonexis-runtime.md#security-and-trust-model).

## Current limitations

- macOS only; no Windows or Linux backend
- Development-signed source build rather than a notarized installer
- Python and TypeScript packages are not published to public registries yet
- The Runtime/CLI Swift executable names still use compatibility-era naming
- No built-in acoustic echo cancellation
- `AudioPlane Input` requires explicit system-wide installation and a reboot;
  BlackHole remains the validated fallback
- Live TCC, physical playback, and provider tests require manual interaction or
  external credentials

## Documentation

- [Runtime architecture, protocol, CLI, and troubleshooting](docs/sonexis-runtime.md)
- [Python/AI integration](docs/ai-integration.md)
- [Output and duplex audio](docs/output-audio.md)
- [AudioPlane Input design](docs/audioplane-input-design.md)
- [AudioPlane Input manual validation](docs/audioplane-input-manual-validation.md)
- [Benchmarks](docs/runtime-benchmarks.md)
- [Manual validation](docs/runtime-v1.0-manual-validation.md)
- [Runtime 1.0 report](RUNTIME_V1_0_REPORT.md)
- [Post-1.0 roadmap](docs/runtime-post-1.0-roadmap.md)

## License

AudioPlane is licensed under GPL-2.0-or-later. See [LICENSE](LICENSE).
