# Sonexis Runtime 1.0 Manual Validation

Automated release qualification uses synthetic audio and local sockets. The
checks below require a person, macOS privacy UI, physical audio hardware,
third-party applications, or provider credentials. Never mark one passed based
only on counters when the requirement is audible or semantic behavior.

## Status summary

| Check | 1.0 candidate status |
|---|---|
| Signed live Process Tap capture | NOT RUN |
| Chrome and Spotify live capture | NOT RUN |
| Default physical output / listening | NOT RUN |
| AirPods/headphones output | NOT RUN |
| Default-device change during playback | NOT RUN |
| BlackHole into Discord | NOT RUN |
| BlackHole into Zoom | NOT RUN |
| Authenticated Gemini understanding | NOT RUN |
| Gemini response audio through Runtime | NOT RUN |
| Authenticated OpenAI duplex | NOT RUN |
| Real MCP host interoperability | NOT RUN |

Historical evidence is not silently promoted: Spotify/Chrome Process Tap audio
and authenticated Chrome -> Gemini understanding passed on earlier v0.2/v0.3
builds; real HAL frame accounting passed on the v0.4 development build. Those
results establish architecture evidence, not validation of the 1.0 binary.

## Prepare the exact candidate

From the isolated Runtime worktree:

```sh
cd /Users/skandavyas/Sonexis-runtime-v04
git status --short
cat RUNTIME_VERSION
./Scripts/setup-runtime-dev.sh
./Scripts/runtime-dev.sh start
export PATH="$HOME/Library/Application Support/SonexisRuntime/dev/bin:$PATH"
sonexis-runtime --version
sonexisctl version
sonexisctl status --json
```

Expected Runtime/CLI version is `1.0.0`, protocol is `2`, Runtime signing ID is
`com.sonexis.runtime`, and CLI signing ID is `com.sonexis.ctl`. If Xcode uses a
different local team, set `SONEXIS_DEVELOPMENT_TEAM=YOUR10CHARTEAM` only for the
setup command.

## 1. Grant Process Tap permission

Run a capture against an audible source. The first attempt may trigger macOS
**Screen & System Audio Recording** permission. Enable the signed
`sonexis-runtime` entry in System Settings, then restart it:

```sh
./Scripts/runtime-dev.sh stop
./Scripts/runtime-dev.sh start
sonexisctl sources
```

Enumeration alone does not prove permission. Core Audio does not always return
a permission-specific status; `capture_initialization_failed` with permission
guidance is expected when the grant is missing.

## 2. Chrome live capture

Play speech in Chrome, select the exact source returned by `sources`, and run:

```sh
sonexisctl capture "Google Chrome" --output /tmp/sonexis-chrome.pcm --debug
```

Let it run for at least ten seconds, stop with Control-C, and confirm nonzero
frames/bytes, monotonic sequence/timestamps, and zero drops under normal load.
Listen only after importing the raw file as signed 16-bit little-endian, mono,
16 kHz PCM. Delete the private recording when finished.

## 3. Spotify live capture

Repeat while Spotify is audibly playing:

```sh
sonexisctl capture Spotify --output /tmp/sonexis-spotify.pcm --debug
```

Confirm the capture contains Spotify rather than another application and that
stop is clean. Remove `/tmp/sonexis-spotify.pcm` after validation.

## 4. Physical output and headphones

Generate a private deterministic fixture if `ffmpeg` is installed:

```sh
ffmpeg -hide_banner -loglevel error \
  -f lavfi -i 'sine=frequency=440:duration=3' \
  -ar 24000 -ac 1 -c:a pcm_s16le -y /tmp/sonexis-tone-24k.wav
chmod 600 /tmp/sonexis-tone-24k.wav
sonexisctl outputs --json
sonexisctl play /tmp/sonexis-tone-24k.wav --destination default --debug
```

Confirm the tone is audible and the session stops with zero drops. Select wired
headphones or AirPods as the macOS default, rerun `outputs` and `play`, and
confirm both the reported active device and physical listening result.

## 5. Change the default output mid-stream

Create a 30-second fixture, start `watch`, play to `default`, then change the
macOS default output in Control Center:

```sh
ffmpeg -hide_banner -loglevel error \
  -f lavfi -i 'sine=frequency=330:duration=30' \
  -ar 24000 -ac 1 -c:a pcm_s16le -y /tmp/sonexis-route-change.wav
sonexisctl watch --json
# second terminal
sonexisctl play /tmp/sonexis-route-change.wav --destination default --debug
```

Confirm `output_destination_changed`, continued audible playback on the new
device, a route-change metric, bounded queues, and no hang. A failed rebuild
must become a structured terminal error.

## 6. BlackHole into Discord and Zoom

Install BlackHole using its trusted upstream installer; Sonexis does not ship a
HAL driver. Confirm `sonexisctl outputs --json` reports the device as
`virtual_input`. Select that same device as the microphone inside Discord or
Zoom, then send deterministic audio:

```sh
sonexisctl play /path/to/pcm16-speech.wav \
  --destination "BlackHole 2ch" --debug
```

Use each application's microphone meter or private test call to confirm receipt
and silence after stop. Never choose an ambiguous destination; use the exact
returned ID when multiple loopback devices share a name. Use headphones and a
safe route to prevent acoustic/digital feedback.

## 7. Authenticated Gemini duplex

Use Python 3.10+ and keep credentials in the environment:

```sh
python3.10 -m venv .venv-ai
. .venv-ai/bin/activate
python -m pip install -e 'SDKs/python[gemini]'
export GEMINI_API_KEY='REDACTED'
python Examples/audio-agent/audio_agent.py \
  --provider gemini \
  --source "Google Chrome" \
  --response-output default \
  --debug
```

Play spoken commentary and pause. Confirm local activity start/end, exactly one
`audio_stream_end` for the segment, response start, readable output
transcription, semantic understanding of the actual content, audible generated
speech through Sonexis output, turn completion, and zero Sonexis drops. Remove
the key from the environment afterward.

## 8. Authenticated OpenAI duplex

In a fresh Python 3.10+ environment:

```sh
python -m pip install -e 'SDKs/python[openai]'
export OPENAI_API_KEY='REDACTED'
python Examples/audio-agent/audio_agent.py \
  --provider openai \
  --source "Google Chrome" \
  --response-output default \
  --debug
```

Confirm source-aware input, readable provider response events, response audio
through the same Runtime output API, clean interruption/stop, and no credential
or PCM content in default logs.

## 9. MCP host

Install the optional MCP extra with Python 3.10+, configure a trusted local MCP
host to launch `python -m sonexis.mcp_server`, and first omit
`--allow-capture`. Verify read-only source, diagnostics, and destination tools;
capture mutation must be absent/denied. Then explicitly add `--allow-capture`,
start and stop one owned capture, and verify no PCM or data-socket path travels
through MCP. Terminating the MCP server must clean its owned session.

## 10. Cleanup

```sh
./Scripts/runtime-dev.sh stop
rm -f /tmp/sonexis-chrome.pcm /tmp/sonexis-spotify.pcm \
  /tmp/sonexis-tone-24k.wav /tmp/sonexis-route-change.wav
```

Use `./Scripts/uninstall-runtime-dev.sh` only when the per-user development
installation should be removed. Uninstall BlackHole only with its vendor's
instructions; never recursively delete `/Library/Audio/Plug-Ins/HAL`.
