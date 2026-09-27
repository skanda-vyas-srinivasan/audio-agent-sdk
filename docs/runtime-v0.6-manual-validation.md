# Runtime v0.6 manual endpoint validation

These tests change audible routing and require a person. Automated fake-device
tests do not count as live HAL validation.

## Preparation

```sh
./Scripts/setup-runtime-dev.sh
./Scripts/runtime-dev.sh start
CTL="$HOME/Library/Application Support/SonexisRuntime/dev/bin/sonexisctl"
$CTL outputs --json
$CTL watch --json
```

In a third terminal, create a 30-second supported fixture:

```sh
ffmpeg -hide_banner -loglevel error \
  -f lavfi -i 'sine=frequency=330:duration=30' \
  -ar 24000 -ac 1 -c:a pcm_s16le -y /tmp/sonexis-route-change.wav
chmod 600 /tmp/sonexis-route-change.wav
```

## Default route change — NOT RUN for v0.6

```sh
$CTL play /tmp/sonexis-route-change.wav --destination default --debug
```

While it plays, change the macOS output from built-in output to headphones or
AirPods. Confirm:

- `output_default_changed` carries `output_destination.active_device_id`;
- the active session emits `output_destination_changed` at most once for the
  coalesced change and reports any discarded frames;
- playback continues instead of failing with `output_not_writable`;
- `route_changes` increments; and
- final state is `stopped`, or a failed rebuild returns the retryable
  `output_device_change_failed` error without hanging.

## Fixed destination removal — NOT RUN for v0.6

Start by exact display name or the returned stable ID, then disconnect it:

```sh
$CTL play /tmp/sonexis-route-change.wav --destination 'Exact Device Name' --debug
```

Confirm `output_destination_removed` appears and the session fails retryably
with `output_destination_disconnected`. Reconnecting the device must not revive
the old session automatically; start a new one.

## Loopback ambiguity and receipt — NOT RUN for v0.6

With a trusted loopback driver installed, verify `outputs --json` reports
`kind: "virtual_input"`. If more than one exists, `--destination loopback` must
fail with candidate IDs. Use one exact name or ID:

```sh
$CTL play /tmp/sonexis-route-change.wav \
  --destination 'BlackHole 2ch' --debug
```

Select that device as Discord/Zoom input and confirm its meter or a private
test call receives audio. Use headphones and deliberate source selection to
avoid feedback. Sonexis does not provide acoustic echo cancellation.

## Previously established live evidence

PASSED on 2026-09-26: the v0.4 native Runtime rendered deterministic 24 kHz
mono PCM through real HAL to the 44.1 kHz headphone default and the installed
48 kHz BlackHole destination with exact converted frame counts and zero
drops/overruns. That proves the underlying output route but does not substitute
for the v0.6 device-change cases above.
