# Sonexis Runtime v0.4 report

## 1. Executive summary

Runtime v0.4 adds a bounded, realtime client-to-Runtime audio plane and makes
Sonexis bidirectional. Local SDK clients can still capture source-aware macOS
application audio, and can now create independent output sessions, stream PCM
to the Runtime, render it through the default or a fixed Core Audio output,
flush/cancel it for barge-in, and inspect output lifecycle and diagnostics.

The milestone was developed in the isolated worktree
`/Users/skandavyas/Sonexis-runtime-v04` on branch
`runtime-v0.4-bidirectional-audio`, starting at v0.3 commit `75f4383`. The
original `/Users/skandavyas/Sonexis` worktree and its AutoPitch/VoxCent/UI
changes were not modified.

## 2. What v0.4 enables

- realtime PCM playback owned by Runtime rather than an SDK process;
- a reverse binary data plane with ordered packets, timestamps, format checks,
  discontinuity, and EOS;
- default-device following and fixed-device selection by stable Core Audio UID;
- bounded jitter buffering, backpressure, drops/underruns/overruns, and drain;
- Python and TypeScript output APIs plus optional duplex ownership helpers;
- Gemini and OpenAI response audio routed through the same public Sonexis API;
- deterministic WAV/raw replay through `sonexisctl play`;
- generic routing to an already installed loopback/virtual input device;
- output events, per-session metrics, Runtime totals, stress tests, and
  deterministic benchmarks.

Sonexis remains provider-neutral. Runtime does not know about Gemini, OpenAI,
turns, agents, or conversations.

## 3. Input architecture

The v0.3 input architecture is unchanged:

```text
application process -> Core Audio Process Tap -> capture worker
                    -> normalization -> bounded PCM data socket -> SDK
```

Source IDs, source-aware frames, hybrid Gemini VAD, capture event semantics,
format negotiation, and all existing input commands remain protocol-v2
compatible.

## 4. Output architecture

```text
model / WAV / producer
        | PCM16 or Float32, sequence, timestamp
        v
Python / TypeScript / sonexisctl
        | private Unix SXPC data socket
        v
Runtime output reader -> AVAudioConverter -> bounded C SPSC ring
                                                | C HAL IOProc
                                                v
                          default/fixed output or loopback device
```

Control, conversion, socket I/O, allocation, and logging stay off the HAL
callback. The callback is a C function that only zeros the supplied buffers,
reads preallocated Float32 samples, performs bounded interpolation for the
one-frame jitter correction, updates lock-free atomics, and returns.

## 5. Protocol changes

Protocol v2 gained additive capabilities `output_sessions`,
`output_destinations`, `output_events`, `output_diagnostics`, `output_flush`,
and `duplex_sessions`. New JSON commands are:

- `list_output_destinations`
- `start_output`
- `output_status`
- `flush_output`
- `stop_output`

Output PCM uses the existing 64-byte SXPC v2 envelope in the reverse direction.
The start response binds stream UUID to output session/destination. Every packet
contains stream UUID, monotonic sequence, stream-relative timestamp, flags,
format code, frame count, dropped-frame field, and payload length. Runtime
requires sequence zero first, exact progression or a declared discontinuity,
the negotiated format, a complete sample frame, 1–200 ms of non-EOS audio, and
at most 512 KiB. EOS is empty and final. Abrupt EOF fails the session.

## 6. Python SDK changes

`Sonexis.playback()` returns a typed `AudioOutput`. It provides serialized async
`write`, `refresh`, `flush`, `aclose`, and immediate `cancel`, plus async context
manager cleanup. Writes split at 200 ms and await Unix-socket flow control;
there is no hidden unbounded SDK queue.

```python
async with Sonexis() as sx:
    async with await sx.playback(
        destination="default",
        format=AudioFormat.gemini_live_output(),
        target_buffer_milliseconds=60,
    ) as output:
        async for chunk in model_audio:
            await output.write(chunk)
```

`sx.duplex(...)` is an optional ownership convenience pairing one normal
capture and one output. It closes capture before draining output so new input
cannot extend teardown. It does not impose turn-taking, feedback, or provider
policy. Output errors are typed and expose retryability.

## 7. TypeScript SDK changes

The Node 18+ client now exposes typed destinations, output formats, sessions,
metrics, events, `playback`, and `duplex`. `AudioOutput.write` accepts `Buffer`
or `Uint8Array`, honors an `AbortSignal`, waits for socket drain, uses the
negotiated format even for EOS, and surfaces structured session failures.
`flush` rotates the stream epoch and `cancel` implements immediate teardown.

The package compiled with TypeScript and all 17 Node tests passed.

## 8. Playback sink

Runtime resolves `default` on every route build and listens for default-device
changes. Fixed devices use `coreaudio:<UID>` and a liveness listener. Nominal
sample-rate and stream virtual-format changes rebuild the converter/ring. v0.4
accepts a single output stream with one or two Float32 channels at 8–192 kHz;
complex multi-stream/aggregate layouts fail safely.

Runtime accepts every advertised PCM format and converts to the active device.
Float32 input is checked for finiteness and clamped to `[-1, 1]`. Converter EOS
is repeatedly drained and trimmed to the exact expected output duration.

## 9. Virtual input architecture

Installed loopback devices are selectable as ordinary fixed destinations. A
device is labeled `virtual_input` only when it exposes an input stream and its
name/UID matches a known virtual/loopback pattern. That label is advisory, not
proof that a receiving app opened it or an access-control boundary.

The installed `BlackHole 2ch` was enumerated and the Runtime-to-loopback output
half was exercised successfully. v0.4 does not ship a branded `Sonexis Agent
Input` HAL driver. A responsible driver requires a complete AudioServerPlugIn
property model, signed privileged installer, reboot/coreaudiod recovery,
multi-architecture testing, and an independent driver-safety program. Shipping
an unreviewed driver would put system audio stability at risk. The technically
correct design and exact remaining validation are in
`docs/virtual-audio-device-design.md`.

## 10. Gemini duplex flow

The reference application accepts `--response-output`. Gemini-generated PCM is
validated against the adapter-declared output MIME type and written only via
the public `AudioOutput` API. Capture still uses local hybrid VAD while Gemini
server-side VAD remains enabled. Default raw response-byte logging is disabled;
debug mode shows output activity and metrics.

The authenticated v0.3 Chrome-to-Gemini input/transcription path remains
validated. Gemini response-audio playback through v0.4 is implemented and
mock-tested; authenticated audible playback remains in the manual guide.

## 11. OpenAI duplex flow

OpenAI response events declare the 24 kHz mono PCM16 output preset and use the
same `RuntimeResponsePlayer` and Sonexis output session as Gemini. No
provider-specific playback stack exists. Serialization, declared format,
cancellation, error redaction, and public-API routing are unit-tested; live
provider output playback was not performed.

## 12. Feedback and echo behavior

Process Tap capture is process-specific, so audio emitted by the Runtime is not
digitally folded into a Chrome/Discord process tap by Sonexis itself. Sonexis
does not implement acoustic echo cancellation. Speakers may be heard by a
physical microphone, and a remote participant may retransmit injected loopback
audio. Headphones and deliberate source/destination selection are the safe
defaults. Automatic muting and ducking were not added because there is no
reliable current per-application-volume mechanism in this architecture.

## 13. Barge-in primitives

`flush()` discards the device ring, resets conversion, rotates stream UUID and
socket, and resets sequence/timestamp state while retaining the logical output
session. The read gate waits for an in-flight callback before advancing the
cursor. Audio already handed to Core Audio may still render for at most the
current hardware quantum. `cancel()` immediately tears down the output and
discards buffered audio. Applications choose when to invoke either primitive.

## 14. Backpressure

- SDK writes are serialized, split to 200 ms, and await socket backpressure.
- Runtime accepts only one producer connection per output epoch.
- The converted device-rate ring is capped at 500 ms.
- Playback primes to a configurable 20–250 ms target (60 ms default).
- A full ring backpressures its socket worker for at most two seconds; any
  newest tail still unable to fit is dropped and counted.
- An empty ring emits silence, counts underrun frames, and re-primes.
- EOS drains conversion and buffered output for at most two seconds.

No output path permits unbounded PCM growth.

## 15. Diagnostics

Per-output status includes input packets/frames/bytes, device frames enqueued
and actually rendered from the ring, dropped/flushed/late frames, underrun and
overrun frames/events, queue current/high-water depth, buffered duration,
conversion batches/time, route changes, producer attachment, uptime, active
device format, destination, and estimated software-plus-HAL latency. Runtime
status includes active/total output sessions and aggregate frames/bytes/drops.
Events include started, stopped, failed, cancelled, underrun, overrun, dropped,
flushed, and destination changed.

## 16. Benchmarks

Final optimized offline results on Apple M4, macOS 27.0 (26A428):

| Path (200 seconds represented) | Wall time | Realtime factor | Frames |
| --- | ---: | ---: | ---: |
| PCM16 24 kHz mono -> Float32 48 kHz stereo | 0.025717 s | 7,777.0x | 9,600,000 |
| PCM16 48 kHz stereo -> Float32 48 kHz stereo | 0.007713 s | 25,929.3x | 9,600,000 |
| Float32 48 kHz mono -> Float32 44.1 kHz stereo | 0.027031 s | 7,398.9x | 8,820,000 |
| two-channel ring write/read | 0.017768 s | 11,256.1x | 9,600,000 |

Live Runtime-to-HAL checks converted a 0.5-second 24 kHz mono fixture to the
exact expected 22,050 frames at 44.1 kHz and 24,000 frames at 48 kHz, with zero
drops/overruns. They measure delivery into HAL, not acoustic/Bluetooth latency.
Provider/model/network time is deliberately excluded from Sonexis latency.

## 17. Stress results

The non-TSan final stress run completed 1,000 capture cycles, 1,000 output
cycles, 200 connect/disconnect cycles, and 16 parallel sessions in 2.918 s,
with one descriptor of deferred server-shutdown growth, 10,403,840-byte peak
RSS, 6,488,064-byte baseline peak RSS, and no remaining sessions. Under TSan the
same workload completed in 3.782 s; a dedicated concurrent C ring test also
repeated read/write/flush and passed without a race report.

SDK tests force a non-reading output peer, prove socket backpressure is bounded,
and prove cancellation wakes the blocked producer. Protocol tests cover packed
tiny messages, partial/truncated/oversized/malformed frames, gaps, stale stream
IDs, bad formats, and bad ordering.

## 18. Security review

Runtime remains Unix-domain-only. The socket directory is `0700`, sockets are
`0600`, peer UID is checked, stale-path/symlink handling is defensive, JSON and
binary sizes are capped, session/client limits remain active, and CLI input is
bounded to 256 MiB before/during read. Provider diagnostics redact common
credential shapes. Runtime does not persist or log PCM.

The local account is the trust boundary: any unsandboxed same-UID process can
use Runtime's granted capture permission or inject output. Any process that can
open a selected loopback device's input can read its signal. Runtime must not be
run privileged or placed in a shared directory. A future private driver
injection stream needs a real access-control design.

## 19. Realtime review

Independent review found and drove fixes for:

- a flush/read cursor race (read gate plus bounded active-reader quiescence);
- a route lock held while waiting for capacity (separate ingest lock);
- writer-cancellation lock coupling (separate lifecycle/write locks);
- callback ARC/Swift crossings (the HAL IOProc moved completely into C);
- callback-context teardown (retained owner released only after successful HAL
  IOProc destruction; a failed destroy deliberately leaks rather than frees
  HAL-visible memory);
- device format changes (rate and stream-format listeners rebuild the route);
- one-shot converter drain (repeated drain to exact expected duration);
- assumptions about atomics (compile-time lock-free assertions).

No callback allocates, locks, logs, performs IPC, or invokes Swift.

## 20. Driver review

The driver-focused review rejected treating name-based classification as proof
of connectivity, required fixed enumeration of the current default device,
constrained supported stream/channel topology, and clarified loopback access.
It agreed that a branded driver without a complete HAL property/lifecycle and
installer review should be deferred. There is therefore no Sonexis driver
artifact or install/uninstall script in v0.4.

## 21. Adversarial findings

Independent protocol/API/adversarial passes found and fixed:

- repeated front-removal in packed PCM and NDJSON parsers;
- an EOS format code of zero in TypeScript;
- output metrics lost across flush epochs;
- unbounded CLI growth if a file changed while being read;
- NaN/infinite/out-of-range Float32 samples;
- minimum-duration and HAL rate/channel validation gaps;
- output error-type and unexpected-socket-failure gaps;
- event defaults that omitted v0.4 output events;
- an unusable cross-process CLI flush command;
- duplex teardown/API typing and provider MIME-validation issues.

All credible findings were fixed and their regression tests pass.

## 22. Known limitations

- no bundled Sonexis-branded virtual microphone driver;
- receiving-app loopback validation remains manual;
- no acoustic echo cancellation, automatic ducking, or implicit turn policy;
- v0.4 supports single-stream, one/two-channel HAL outputs only;
- timestamps are producer-relative, not a cross-device sample clock;
- output latency estimate excludes acoustic, codec, provider, and network time;
- SDK packages remain repository-local and unpublished;
- JSON nanoseconds/counters use JavaScript `number`; binary timestamps remain
  exact `bigint`.

## 23. Manual validation remaining

The guide `docs/runtime-v0.4-manual-validation.md` covers audible default-device
playback, headphones/AirPods, switching the default mid-stream, authenticated
Gemini response playback, Audio MIDI Setup, choosing a loopback input in
Discord/Zoom, confirming received speech, and vendor-safe uninstall. These are
not claimed complete. Live HAL delivery to physical and BlackHole destinations
was performed; listening and receiving-app confirmation were not.

## 24. Commits created

- `1222b50` — `docs: plan Runtime v0.4 bidirectional audio`
- `e2d6a07` — `feat: add Runtime bidirectional playback plane`
- `f2d1d4a` — `fix: harden Runtime v0.4 output lifecycle`
- final documentation/report commit — `docs: complete Runtime v0.4 milestone`

Nothing was pushed or merged.

## 25. Exact quickstart

Build and run the signed Runtime:

```sh
cd /Users/skandavyas/Sonexis-runtime-v04
xcodebuild -project Sonexis.xcodeproj -scheme sonexis-runtime \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/RuntimeSigning build
xcodebuild -project Sonexis.xcodeproj -scheme sonexisctl \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/RuntimeSigning build
.build/RuntimeSigning/Build/Products/Debug/sonexis-runtime
```

In another terminal:

```sh
cd /Users/skandavyas/Sonexis-runtime-v04
CTL=.build/RuntimeSigning/Build/Products/Debug/sonexisctl
$CTL sources
$CTL outputs
$CTL play /path/to/supported.wav --destination default --debug
```

Run the Gemini bidirectional reference after installing the Python SDK extras:

```sh
cd /Users/skandavyas/Sonexis-runtime-v04
. .venv-ai/bin/activate
export GEMINI_API_KEY='your-key'
python Examples/audio-agent/audio_agent.py \
  --provider gemini \
  --source 'Google Chrome' \
  --response-output default \
  --debug
```

For a loopback, use the exact `coreaudio:<UID>` returned by `$CTL outputs`.

## 26. Recommended v0.5 direction

The next cohesive milestone should be production service/distribution work and,
only with its own driver-safety program, a signed Sonexis virtual input. That
includes a launchd-owned Runtime, stable packaging/upgrades, explicit consent
and same-user authorization, Developer ID/notarization, a complete
AudioServerPlugIn with private injection policy, privileged idempotent
installer/uninstaller, recovery tooling, and receiving-app compatibility
testing. It should not expand provider or agent features until the local audio
service and driver boundary are operationally safe.
