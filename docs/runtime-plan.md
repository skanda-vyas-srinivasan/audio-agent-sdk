# Sonexis Runtime implementation plan

## Current architecture

Sonexis captures macOS output with a Core Audio Process Tap. `TapCaptureEngine` owns the tap, private aggregate device, IOProc, and a preallocated single-producer/single-consumer C ring buffer. The IOProc only copies Float32 samples into that ring. `ProcessTapProcessingWorker` drains it on a serial worker queue, and `ProcessTapDSPApp` couples the captured stream to graph processing, a second playback ring, the current output device, route recovery, and sleep/wake recovery. `MultiChainAudioEngine` creates one such pipeline per routing chain and serializes lifecycle work away from the main thread.

Application selection is presently represented by `AudioCaptureTarget` (bundle identifier, name, and bundle path). It discovers regular applications with `NSWorkspace`, then separately resolves each target to current Core Audio process objects, including embedded helpers. The same file also contains persistence, an `AudioEngine` adapter, and SwiftUI menu code.

The native path is interleaved Float32 at the tap/output device sample rate and channel count. The product path deliberately requires tap and output formats to match because it captures, processes, and replays audio. Recording observes the post-processing app path. There is no capture-only owner, normalized stream, IPC boundary, or external session model.

## Reuse blockers

- Source discovery/model and SwiftUI presentation are physically coupled.
- `ProcessTapDSPApp` always owns playback and app-specific recovery behavior; it cannot serve a headless capture-only consumer.
- The tap has a hard-coded mute policy and playback-format compatibility check.
- Existing source identity is bundle-stable but does not expose current PIDs, activity, native format, or future source kinds.
- PCM delivery is an internal Float pointer callback without timestamps or sequence numbers.
- The app executable is the only build product and the only TCC identity.
- There is no local transport, bounded client backpressure, or externally visible state/error model.

## Proposed architecture

```text
AudioSourceRegistry ──► AudioSource
                             │
                             ▼
AudioCaptureManager ──► AudioCaptureSession
                             │ native Float32
                    lock-free capture ring
                             │ worker queue
                             ▼
                    AVAudioConverter
                             │ 16 kHz mono PCM16 AudioFrame
                             ▼
RuntimeCoordinator ──► bounded stream queue ──► Unix socket data connection
        │
        └──── NDJSON control connection ◄──── Runtime client / sonexisctl
```

The reusable core is Foundation/AppKit/CoreAudio/AVFoundation code with no SwiftUI or `AudioEngine` dependency. It reuses the existing Process Tap owner and realtime ring. Native capture remains Float32; normalization is a downstream worker concern, so the Sonexis graph remains in its native format.

`AudioSource` has a typed kind and a stable application ID based on bundle identity. PIDs and Core Audio object IDs are transient registry/session data, not identity. The shape allows later microphone, system-mix, remote, and virtual kinds without implementing them now.

`AudioCaptureSession` owns exactly one tap, aggregate device, IOProc, ring consumer, converter, and frame callback. Lifecycle work is serialized. Stop is idempotent and shutdown order is: prevent new work, stop IOProc, destroy IOProc, destroy aggregate, destroy tap, stop the consumer, then release buffers. The IOProc retains no session-owned object beyond this ordering.

The Runtime listens only on per-user Unix-domain sockets. Control messages are bounded newline-delimited JSON. Audio uses a separate per-session socket and a fixed binary header plus PCM payload. Each session has bounded pending output and reports capture/client drops rather than blocking capture.

## Protocol outline

Control requests carry protocol version, request ID, command type, and command-specific identifiers. Version 1 supports `ping`, `list_sources`, `start_capture`, `session_status`, and `stop_capture`. Responses either carry a typed result or a stable error code and readable message.

Runtime output is fixed initially at signed 16-bit little-endian PCM, mono, 16 kHz. Binary frames carry magic/version, a reserved flags field, sequence, monotonic stream-relative timestamp, frame count, payload size, sample rate, channels, and bit depth. Socket EOF terminates the stream in version 1.

## Migration plan

1. Split source model/discovery from SwiftUI and keep an app adapter for current selection behavior.
2. Generalize the tap owner only where capture-only behavior differs (mute policy and playback compatibility), preserving product defaults.
3. Add capture manager/session and normalization; cover model, conversion, and state transitions offline.
4. Add Runtime/CLI executable targets and protocol/socket layers.
5. Add an injected synthetic backend for full IPC integration tests without invoking live capture.
6. Update the app to consume shared discovery/source primitives where practical, while leaving its proven DSP/output orchestration intact.
7. Build all products, run offline and sanitizer suites, then perform independent realtime, architecture, and adversarial reviews.

## Concurrency and realtime risks

- The Core Audio IOProc must remain a bounded ring write only: no allocation, locks, conversion, logging, JSON, or socket I/O.
- The ring is SPSC. Fan-out happens only after the single consumer normalizes a packet.
- `Unmanaged.passUnretained` is safe only if stop/destroy completes before the tap owner or ring is released.
- Converter and socket queues need bounded buffers; a slow client must cause accounted drops or session failure, never unbounded memory growth.
- Lifecycle callbacks and disconnect handlers can race. A serial coordinator and session generation/state checks must reject stale completions.
- Source disappearance must never turn an empty inclusive selection into an all-system tap.
- Route changes require rebuilding capture against the new default-device UID while preserving external session identity.
- Bare command-line executables have a separate Screen & System Audio Recording permission identity; live TCC behavior requires signed manual validation.
- Callback timestamps are not currently propagated. Version 1 uses monotonic delivery/sample timing and marks discontinuities; preserving HAL host time is a follow-up if the initial tap seam cannot carry it safely.
