# Sonexis Runtime

## Purpose

Sonexis Runtime is a local macOS process that exposes application-audio capture without requiring clients to use Core Audio. A client can enumerate running application sources, start a capture session, receive normalized PCM, inspect or stop the session, and disconnect cleanly.

The prototype is local-only. It does not open a TCP port or provide cloud, authentication, transcription, provider, or virtual-device features.

## Build and run

```sh
xcodebuild \
  -project Sonexis.xcodeproj \
  -scheme sonexis-runtime \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project Sonexis.xcodeproj \
  -scheme sonexisctl \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Start the Runtime:

```sh
.build/DerivedData/Build/Products/Debug/sonexis-runtime
```

In another terminal:

```sh
.build/DerivedData/Build/Products/Debug/sonexisctl sources
.build/DerivedData/Build/Products/Debug/sonexisctl capture app.com.example.audio --output /tmp/example.pcm --debug
```

The capture command prints its session ID. While it is running, another client can inspect or stop it:

```sh
.build/DerivedData/Build/Products/Debug/sonexisctl status SESSION_ID
.build/DerivedData/Build/Products/Debug/sonexisctl stop SESSION_ID
```

Use `SONEXIS_RUNTIME_DIR` to choose the Runtime socket directory. Use `SONEXIS_RUNTIME_SOCKET` or append `--socket PATH` to a command, for example `sonexisctl sources --socket PATH`, to select a control socket.

## Architecture

```text
NSWorkspace + Core Audio HAL
            │
            ▼
   AudioSourceRegistry
            │
            ▼
 AudioCaptureManager / AudioCaptureSession
            │ native Float32 at device rate/channels
            ▼
 preallocated SPSC C ring (HAL callback boundary)
            │ capture worker
            ▼
 AVAudioConverter → PCM16 mono 16 kHz AudioFrame
            │ bounded delivery
            ▼
 RuntimeSessionCoordinator
       ├── NDJSON control.sock
       └── framed PCM capture-SESSION.sock
```

The reusable capture source layer lives under `Sonexis/RuntimeCore/Capture`. It has no SwiftUI dependency. The existing app shares `AudioSourceRegistry`, `TapCaptureEngine`, Core Audio helpers, and the realtime ring. Its proven DSP/output lifecycle remains separate from the new capture-only session owner.

The IPC/client layer lives under `Sonexis/RuntimeCore/IPC`. It is compiled into the Runtime and CLI targets. It is an internal reusable source layer, not a packaged public Swift SDK.

## Source model

An application source contains:

- a bundle-stable ID in the form `app.<bundle-identifier>`;
- source kind, currently `application`;
- name and bundle identifier;
- all current process IDs known for the application;
- active/running state;
- optional `isProducingAudio` heuristic;
- optional prospective native format.

PID is metadata rather than identity, so an application retains the same source ID after restart. `isProducingAudio` currently means a process is present in the HAL audio-process list; it is not a measured signal-level guarantee. Native format is the current default-output format; the authoritative format is established when the tap starts.

The kind enum reserves microphone, system-mix, remote, and virtual values without implementing those source types.

## Capture lifecycle

`AudioCaptureManager.startCapture` creates a session with its frame handler installed before capture starts. The session resolves the source again, creates an inclusive private Process Tap, a private aggregate device, an IOProc, and a preallocated ring. The Runtime uses an unmuted tap; the existing app keeps its capture-and-replay mute behavior.

The session state sequence is `starting → running → stopping → stopped`, with `failed` as a terminal error state. Stop is idempotent. Source-process and default-output changes trigger a serialized rebuild without changing the external session ID. An empty application selection fails or remains empty; it is never broadened into global system capture.

Teardown stops and destroys the IOProc before releasing its ring. The HAL callback owns an explicit retain until IOProc destruction succeeds; a failed destruction deliberately retains the small callback owner rather than risking a late callback use-after-free.

## Control protocol

The control endpoint is `/tmp/sonexis-runtime-UID/control.sock` by default. Its directory is mode `0700`; sockets are mode `0600`. A live socket is never replaced. Stale sockets owned by the current user may be removed.

Messages are UTF-8 JSON followed by `\n`, limited to 64 KiB. Requests use these fields:

```json
{"version":1,"requestID":"UUID","command":"list_sources"}
{"version":1,"requestID":"UUID","command":"start_capture","sourceID":"app.com.example.audio"}
{"version":1,"requestID":"UUID","command":"session_status","sessionID":"UUID"}
{"version":1,"requestID":"UUID","command":"stop_capture","sessionID":"UUID"}
```

Supported commands are `ping`, `list_sources`, `start_capture`, `session_status`, and `stop_capture`. A response repeats `version` and `requestID`, sets `ok`, and includes `sources`, `session`, `message`, or an error `{code,message}`. Oversized and malformed input receives a typed error; severe framing errors close that client only.

The control connection owns sessions it starts. Unexpected control disconnect stops and removes those sessions. Up to 128 terminal session snapshots are retained for status/idempotent-stop behavior while a client remains connected.

## Audio data framing

`start_capture` returns a `dataSocketPath`. Connecting to it begins a binary stream. Every packet has a 44-byte big-endian header followed by PCM payload:

| Offset | Type | Meaning |
| ---: | --- | --- |
| 0 | `u32` | magic `SXPC` (`0x53585043`) |
| 4 | `u16` | version `1` |
| 6 | `u16` | reserved flags, currently `0` |
| 8 | `u32` | header size, `44` |
| 12 | `u32` | payload bytes |
| 16 | `u64` | packet sequence |
| 24 | `u64` | first-sample timestamp in stream-relative nanoseconds |
| 32 | `u32` | sample rate |
| 36 | `u32` | PCM frame count |
| 40 | `u16` | channel count |
| 42 | `u16` | bits per channel |

Version 1 output is signed little-endian PCM16, mono, 16,000 Hz. The payload size must equal `frameCount × channels × bits/8`. EOF ends the stream. A slow subscriber is disconnected rather than blocking capture; delivery queues are bounded and drops are counted in session diagnostics.

## Example client

The dependency-free example uses the same sockets as the CLI:

```sh
python3 Examples/python-runtime-client.py
python3 Examples/python-runtime-client.py app.com.example.audio
```

It lists sources, chooses one, starts capture, parses 50 PCM packets, prints frame metadata, and stops cleanly. An explicitly requested unknown source is an error rather than a fallback.

## Diagnostics

The capture session tracks native frames, normalized frames/bytes, ring drops, delivery drops, ring backlog, conversion batch count, and total conversion time. The data plane tracks forwarded and dropped PCM sample frames. No continuous diagnostic logging occurs on the HAL callback.

`sonexisctl capture --debug` prints received frames, bytes, and wall-clock stream duration when the stream ends. `status` reports Runtime-side forwarded and dropped sample frames.

## Realtime constraints

- The HAL IOProc performs only a write into the preallocated SPSC C ring.
- No allocation, lock, conversion, logging, file access, or socket call occurs in the IOProc.
- AVAudioConverter runs on the capture worker.
- Consumer callbacks run on a separate bounded delivery queue.
- Socket framing and writes run on the data-plane queue.
- The ring has exactly one producer and one consumer.
- IOProc destruction must succeed before callback state can be released.

## Known limitations

- Real Process Tap capture and the Runtime executable's independent Screen & System Audio Recording permission require a signed/manual macOS validation. Offline tests use a synthetic backend.
- Version 1 has no data-socket attach token or explicit EOS packet; filesystem permissions and an unguessable session UUID protect the per-session socket, and EOF indicates termination.
- Capture timestamps are derived from normalized sample position rather than preserved HAL host time.
- Multiple captures of the same source are not deduplicated; Core Audio may impose practical limits.
- Output-device changes rebuild the tap and may produce a gap.
- The application shares discovery and low-level capture machinery, but its DSP playback lifecycle does not use `AudioCaptureSession`.
- RuntimeCore is not yet distributed as a public library or SDK.

Future SDKs should package the DTO, codec, and `SonexisRuntimeClient` subset while treating protocol versioning and error codes as compatibility boundaries.
