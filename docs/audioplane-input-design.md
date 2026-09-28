# AudioPlane Input design

Status: implementation plan for the first-party macOS virtual input.

## Goal

`AudioPlane Input` is a local Core Audio device that accepts realtime PCM from
the existing AudioPlane Runtime output path and exposes the same samples as a
microphone-like input to applications such as Discord, Zoom, and browsers.

The first release deliberately does not change application device selections
or replace the physical microphone automatically. A user selects `AudioPlane
Input` inside the receiving application while AudioPlane is active. BlackHole
remains a supported fallback, but is no longer required when this driver is
installed.

## Data flow

```text
model / WAV / SDK client
          |
          | AudioPlane output binary data plane
          v
AudioPlane Runtime
          |
          | normal Core Audio output IOProc
          v
AudioPlane Input output stream (injection side)
          |
          | bounded in-driver realtime ring
          v
AudioPlane Input input stream (microphone side)
          |
          v
Discord / Zoom / browser / other application
```

The Runtime does not use private driver IPC. It discovers the device through
Core Audio and writes to it through the same tested HAL playback backend used
for BlackHole. This keeps the driver boundary small and allows the Runtime to
remain unaware of driver implementation details.

## Platform architecture

The device is an `AudioServerPlugIn` bundle installed in
`/Library/Audio/Plug-Ins/HAL`. Apple documents this as the supported mechanism
for virtual audio devices. AudioDriverKit is intended for physical devices and
would add an app-host, entitlement, signing, and activation lifecycle without
improving this virtual loopback path.

The implementation starts from Apple's current minimal Audio Server plug-in
sample, which is distributed under a permissive license. Retaining the sample's
complete Core Audio property model is safer than implementing only the
properties observed on one macOS version.

Stable identifiers:

- bundle ID: `com.audioplane.input.driver`
- device UID: `com.audioplane.input.device`
- model UID: `com.audioplane.input.model`
- display name: `AudioPlane Input`

## Audio format

The initial device presents one two-channel interleaved Float32 input stream and
one matching injection/output stream at 48 kHz by default, with 44.1 kHz also
available through the retained Apple property model. The Runtime already
converts supported client formats (PCM16/Float32, mono/stereo, supported sample
rates) to a destination's native format before entering its realtime IOProc.

Keeping the format surface to the two standard rates reduces state transitions
and makes the first version easier to validate. Additional formats can be
considered after the 48 kHz path is live-tested.

## Realtime boundary

The output callback copies interleaved Float32 frames into a fixed-capacity
single-producer/single-consumer ring. The input callback removes available
frames and fills any shortage with silence.

The callback path must not:

- allocate or free memory;
- acquire a mutex;
- perform file, socket, or other blocking I/O;
- log;
- invoke Swift or Objective-C code.

Overflow drops the newest frames rather than overwriting data being read.
Underrun produces silence. Both outcomes remain bounded and cannot grow memory.
The initial buffer holds two seconds of stereo 48 kHz audio; normal latency is
controlled by Core Audio's device clock and Runtime jitter buffer, not by
waiting for the ring to fill.

## Installation and recovery

Building the driver does not install it. Installation and uninstallation are
explicit scripts that:

1. resolve and validate exact source/target paths;
2. require `sudo` visibly for `/Library/Audio/Plug-Ins/HAL`;
3. refuse to remove any bundle except the exact AudioPlane bundle ID;
4. verify bundle metadata and signature before/after copying;
5. explain the required Core Audio restart or reboot.

Normal automated tests never alter system audio. A failed or absent driver does
not affect ordinary AudioPlane capture, physical playback, or BlackHole support.

## Validation sequence

1. Compile the driver with strict warnings.
2. Inspect the bundle and exported factory without installing it.
3. Unit-test the ring separately, including wrap, overflow, underrun, and
   concurrent producer/consumer stress.
4. Test Runtime destination classification for AudioPlane identifiers.
5. Run existing Runtime output and regression tests.
6. Manually install and verify enumeration in Audio MIDI Setup.
7. Send a deterministic WAV through `audioplane play` and record from
   `AudioPlane Input` in a separate application.
8. Uninstall and confirm physical audio remains unaffected.

## Deferred behavior

The following are intentionally outside the first driver slice:

- automatic per-application input switching;
- changing the macOS default input or output;
- physical microphone passthrough or microphone/model mixing;
- acoustic echo cancellation;
- automatic recovery of application-specific device preferences.

Physical microphone passthrough can later be implemented above this stable
device boundary by capturing the chosen microphone, mixing it with generated
audio outside the HAL callback, and writing the result to `AudioPlane Input`.
That work must not make the virtual device itself dependent on Runtime state.
