# Runtime v0.4 manual validation

These checks modify audio routing and may be audible. Run them interactively.
They do not install or remove a driver automatically.

## Build and start

```sh
./Scripts/build-signed-runtime-dev.sh
.build/signed-dev/bin/sonexis-runtime
```

In a second terminal:

```sh
CTL=.build/signed-dev/bin/sonexisctl
$CTL outputs
```

Generate a private deterministic half-second fixture if `ffmpeg` is installed:

```sh
ffmpeg -hide_banner -loglevel error \
  -f lavfi -i 'sine=frequency=440:duration=0.5' \
  -ar 24000 -ac 1 -c:a pcm_s16le -y /tmp/sonexis-tone-24k.wav
chmod 600 /tmp/sonexis-tone-24k.wav
```

## 1. Default output

```sh
$CTL play /tmp/sonexis-tone-24k.wav --destination default --debug
```

Confirm the tone is audible and the final line is `state=stopped`, with input
and expected converted device frames rendered and `dropped=0`.

## 2. Headphones or AirPods

Select the headphones in Control Center/System Settings, rerun `outputs`, and
repeat the default command. The destination's `active_device_name` should name
the headphones. Do not infer audibility from counters; confirm by listening.

## 3. Change default device mid-stream

Create a 30-second fixture, start it against `default`, then change the macOS
default output device:

```sh
ffmpeg -hide_banner -loglevel error \
  -f lavfi -i 'sine=frequency=330:duration=30' \
  -ar 24000 -ac 1 -c:a pcm_s16le -y /tmp/sonexis-route-change.wav
$CTL watch --json
# In another terminal:
$CTL play /tmp/sonexis-route-change.wav --destination default --debug
```

Confirm an `output_destination_changed` event, continued playback on the new
device, a nonzero route-change metric, and bounded/no drop behavior. A failed
rebuild must terminate with `output_device_change_failed`, not hang.

## 4. Gemini voice response

```sh
. .venv-ai/bin/activate
export GEMINI_API_KEY='your-key'
python Examples/audio-agent/audio_agent.py \
  --provider gemini \
  --source 'Google Chrome' \
  --response-output default \
  --debug
```

Play spoken commentary in Chrome and pause. Confirm local activity start/end,
one `audio_stream_end`, readable transcription, generated speech through the
selected output, turn completion, and zero Sonexis input/output drops.

## 5. Virtual input availability

Install a trusted loopback driver using its own signed installer and reboot if
its documentation requires it. Sonexis does not install third-party drivers.
After restart:

```sh
$CTL outputs --json
```

Confirm the loopback has both an input stream and `kind: "virtual_input"`.
The `default` alias remains `playback` even if it currently follows that
loopback device. Record the fixed device's exact returned ID.

## 6. Audio MIDI Setup and System Settings

Open Audio MIDI Setup and verify the loopback device has an input stream and an
output stream at the expected rate. It may not appear as a Sonexis-branded
device in v0.4. System Settings should expose it anywhere macOS lists audio
inputs.

## 7. Discord/Zoom selection

Inside Discord or Zoom, select the same loopback device as the microphone. Do
not set it as the system output while testing unless headphones prevent a
feedback loop.

## 8. Send deterministic speech/audio

```sh
$CTL play /tmp/sonexis-tone-24k.wav \
  --destination 'coreaudio:THE_RETURNED_DEVICE_UID' --debug
```

For a speech check, use a supported PCM16 WAV instead of the tone.

## 9. Confirm receiving application

Use the application's microphone meter or private test call. Confirm it
receives the fixture, then stop playback and confirm the signal returns to
silence. Inspect `sonexisctl status --json` for output totals and drops.

## 10. Uninstall safely

Quit applications using the device and follow the loopback vendor's exact
uninstaller. Do not recursively delete `/Library/Audio/Plug-Ins/HAL`. Reboot if
required, verify the device disappeared from Audio MIDI Setup, and confirm
`sonexisctl outputs` no longer lists it. There is no Sonexis driver to uninstall
in v0.4.

## Validation already performed

On 2026-09-26, the native Debug Runtime rendered deterministic PCM through the
real HAL to the current 44.1 kHz headphone default and the installed 48 kHz
`BlackHole 2ch` destination. Both sessions drained the exact expected converted
frame count with zero drops/overruns. Listening confirmation, device switching,
Gemini response playback, and receipt inside Discord/Zoom remain manual.
