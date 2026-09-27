# Sonexis output audio

## Overview

Runtime v0.4 accepts realtime PCM from local clients and renders it through a
macOS Core Audio output device. Capture and output remain independent; the
optional SDK duplex helper only owns one of each. Provider adapters do not own
playback and the Runtime has no OpenAI- or Gemini-specific behavior.

```text
model / file / realtime producer
        │ PCM + sequence + timestamp
        ▼
Python, TypeScript, or sonexisctl
        │ output-UUID.sock (binary SXPC v2)
        ▼
RuntimeOutputDataPlane ── format conversion ── bounded SPSC ring
                                                │ HAL IOProc
                                                ▼
                          default/specific output or loopback device
```

The output HAL callback only reads preallocated Float32 samples from the C
ring. It does not allocate, lock, log, convert formats, or perform IPC.

## Destinations

`list_output_destinations` and SDK `output_destinations()` enumerate:

- `default`, which follows the current macOS default output device; and
- `coreaudio:<device UID>` for each currently available HAL output device.

Known loopback devices are classified as `virtual_input` only when Core Audio
also reports a real input stream; the semantic `default` destination always
remains `playback`. All destinations are selectable by ID. Device UIDs are
stable Core Audio identifiers, not transient
`AudioObjectID` values. A fixed destination fails with
`output_destination_disconnected` when its device reports that it is no longer
alive. A `default` session rebuilds its route when the default device changes
and emits `output_destination_changed`. Sessions also rebuild when the active
device changes its nominal sample rate or output-stream virtual format without
changing device identity.

The `virtual_input` classification is advisory: it is based on an input stream
plus a recognized loopback name/UID. It does not prove that a particular
receiving application has opened the input side. v0.4 intentionally accepts
only one-stream, one- or two-channel output devices at 8–192 kHz; aggregate or
multi-stream devices fail with a structured unsupported-device error instead
of being routed incorrectly.

Runtime accepts every advertised Runtime PCM format: PCM16 mono at 16, 24, or
48 kHz; PCM16 stereo at 48 kHz; and Float32 mono/stereo at 48 kHz. The worker
uses AVAudioConverter for sample-rate conversion. Same-rate PCM/sample/channel
conversion uses a prepared allocation owned by the worker. Converter tail
samples are drained and trimmed to the exact expected duration at EOS.

## Lifecycle and control plane

Protocol v2 gained additive capabilities and commands; v0.3 clients continue
to work:

- `list_output_destinations`
- `start_output` with destination, format, and target buffer duration
- `output_status`
- `flush_output`
- `stop_output`

An output has a session UUID and an independently rotated stream UUID. States
are `starting`, `ready`, `draining`, `stopped`, `cancelled`, and `failed`.
Normal EOS enters `draining`; stop/cancel discards buffered samples. Stop is
idempotent while the terminal record remains available. Disconnecting the
owning control connection cancels and removes its output sessions.

Flush is the barge-in primitive that preserves the logical session. Runtime
discards its ring, expires the old data socket, returns a new stream UUID and
socket, and resets sequence/timestamp state. A stale producer cannot write into
the new epoch. Only the control connection that created an active output may
rotate it; account-wide status/stop remain available for `sonexisctl` cleanup.

## Client-to-Runtime framing

Output reuses the documented 64-byte SXPC v2 binary header in the reverse
direction. The start response associates the stream UUID with output session
and destination, so those strings are not repeated per packet. Integers are
network byte order and PCM samples are little-endian.

Output-specific validation is strict:

- the first sequence is zero and every later sequence advances;
- a gap requires the discontinuity flag;
- stream UUID and negotiated format must match;
- payload is at most 512 KiB, at least 1 ms, and at most 200 ms;
- payload size must equal frame count × channels × bytes per sample;
- EOS is empty and final; and
- disconnect without EOS fails that stream as truncated.

Timestamps are producer-supplied stream-relative presentation coordinates.
When omitted, SDKs derive contiguous timestamps. Runtime renders packets in
arrival order and counts decreasing timestamps as late; it does not wait for an
absolute wall clock or claim synchronization with independent capture streams.

## Backpressure and jitter policy

All queues are bounded:

1. SDK writes are serialized, split to at most 200 ms, and await Unix-socket
   flow control.
2. Runtime reads from one producer on a non-realtime queue.
3. The device-rate SPSC ring holds 500 ms.
4. The reader waits up to two seconds for ring capacity. If a device remains
   stalled, only the newest tail that cannot fit is dropped and counted.

The target buffer is configurable from 20–250 ms (60 ms by default). Playback
starts only after that target is available. After an underrun empties the ring,
rendering returns silence and re-primes to the target before resuming. This
absorbs ordinary model packet jitter without unbounded latency. EOS overrides
the start gate so a short response still drains. Runtime bounds EOS drain to
two seconds.

Metrics expose input packets/frames/bytes, device frames enqueued/rendered,
drops, flushes, late frames, underrun/overrun counts, queue depth/high-water,
buffered milliseconds, conversion batches/time, route changes, producer
attachment, session uptime, active device format, and an estimate combining
software queue time with Core Audio latency/safety-offset frames. That estimate
does not include acoustic, Bluetooth codec, or provider latency. Runtime totals
appear in `sonexisctl status`.

## Python

```python
from sonexis import AudioFormat, Sonexis

async with Sonexis() as sx:
    async with await sx.playback(
        destination="default",
        format=AudioFormat.gemini_live_output(),
        target_buffer_milliseconds=60,
    ) as output:
        async for chunk in model_audio:
            await output.write(chunk)
```

`await output.flush()` discards pending response audio and creates a fresh
stream epoch. `await output.cancel()` stops immediately. `await output.aclose()`
sends EOS and drains. `sx.duplex(...)` is only an ownership convenience; the
application still decides model, feedback, turn-taking, and barge-in policy.
Flush quiesces an in-flight ring read before advancing the software cursor, but
cannot retract the current device quantum already handed to Core Audio.

## TypeScript

```typescript
const sx = await Sonexis.connect();
const output = await sx.playback({
  destination: "default",
  format: AudioFormats.openAIRealtimeOutput(),
  targetBufferMilliseconds: 60,
});
await output.write(responsePcm);
await output.close();
```

Writes accept an `AbortSignal`. `flush()`, `cancel()`, metrics, destination
enumeration, and `sx.duplex(...)` match the Python lifecycle.

## CLI replay

```sh
sonexisctl outputs
sonexisctl play response.wav --destination default --debug
sonexisctl play response.wav --destination 'coreaudio:BlackHole2ch_UID' --debug
sonexisctl output-status SESSION --json
sonexisctl output-stop SESSION
```

`flush()` is intentionally an in-process SDK operation: it rotates the producer
stream epoch and reconnects the owning SDK object. A separate CLI process cannot
resume another producer's rotated stream, so `sonexisctl` does not expose a
misleading cross-process flush command.

WAV accepts interleaved PCM16 or Float32 in an advertised combination. Raw PCM
requires explicit `--sample-rate`, `--channels`, and `--sample-format`. The CLI
rejects files over 256 MiB before reading them; long-running producers should
use an SDK stream instead of loading a large recording into the CLI.

## Feedback and echo

Process Tap capture is process-specific. Audio rendered by the Runtime process
is not digitally inserted into a Chrome or Discord process tap, so ordinary
speaker playback does not create an internal Sonexis loop. Sonexis does not
provide acoustic echo cancellation: a physical microphone may hear speakers,
and a remote participant may retransmit audio injected through a loopback
device. Applications should prefer headphones, select sources deliberately,
and use `flush()`/`cancel()` for barge-in. Muting, ducking, and conversational
turn policy remain above Runtime.

## Security

Output sockets inherit Runtime's private `0700` directory, `0600` socket mode,
same-UID peer check, packet/session/client limits, and symlink-safe listener
creation. The local user account remains the trust boundary: any unsandboxed
same-UID process can inject audio into available destinations. Runtime never
opens TCP and never records output PCM. A virtual input can make injected audio
available to any local process that opens that device's input stream, so users
must explicitly select and trust that destination.
