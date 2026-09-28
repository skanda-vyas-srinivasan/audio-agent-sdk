# Virtual audio input design

## Current decision

AudioPlane supports installed Core Audio loopback devices as first-class
`virtual_input` output destinations when they expose both output and input
streams and their name or UID identifies a loopback device. This was
live-tested with `BlackHole 2ch`: Runtime accepted 24 kHz mono PCM, converted it
to the device's 48 kHz stereo format, rendered the exact expected frame count,
and reported zero drops.

The repository now also includes a source-built developer preview of the
first-party `AudioPlane Input` HAL driver. It starts from Apple's complete
minimal AudioServerPlugIn property model and adds a bounded lock-free loopback
transport. Runtime discovers and writes to it through normal Core Audio, using
the same output path as BlackHole. There is no private Runtime/driver protocol.

The driver builds and passes bundle, factory, property, realtime ring, loopback,
and Thread Sanitizer tests without installation. System installation, Audio
MIDI Setup enumeration, and receipt by Discord or Zoom remain manual tests and
are not claimed as passed. BlackHole remains the live-validated fallback.

The `virtual_input` kind is an advisory name/UID plus input-stream heuristic,
not an authorization or connectivity guarantee. Any local process able to open
a loopback device's input can read injected audio, and any process able to open
its output can inject audio. Runtime supports single-output-stream, one- or
two-channel destinations; more complex aggregate or multistream layouts are
rejected.

## Mechanisms considered

### Normal HAL playback

Runtime renders to the default or a fixed output device with
`AudioDeviceCreateIOProcID`. This is the correct mechanism for speakers,
headphones, and the output side of a loopback driver. It cannot make a new
microphone device appear by itself.

### Aggregate device

`AudioHardwareCreateAggregateDevice` combines streams from existing devices.
It does not create a transport and therefore cannot replace a loopback driver.
Wrapping an installed loopback only changes presentation and adds lifecycle
complexity.

### AudioServerPlugIn HAL driver

Apple's supported virtual-device sample publishes a `.driver` plug-in with
Float32 two-channel input/output at 44.1 and 48 kHz. AudioPlane uses this
architecture:

```text
Runtime --HAL writes--> AudioPlane injection output
                              |
                    driver-owned bounded ring
                              |
application <--HAL reads-- AudioPlane Input
```

Using the normal HAL write path avoids custom Runtime-to-driver sockets or
shared-memory IPC. The driver's realtime callbacks use a preallocated SPSC
ring, return silence on underrun, drop newest frames on overflow, never block,
and never allocate or log. The device remains safe and silent when Runtime is
absent.

### DriverKit audio extension

Apple recommends AudioServerPlugIn for virtual devices. Its AudioDriverKit
sample targets hardware-backed drivers and adds DriverKit entitlements,
provisioning, an app host, and an activation lifecycle. That is disproportionate
for this virtual-only loopback.

## Implemented developer-preview boundary

The repository includes:

- Apple's complete sample HAL object/property model, branded stable UIDs, and
  two-channel Float32 input/output at 44.1/48 kHz;
- a fixed-capacity, allocation-free SPSC ring;
- multi-client StartIO/StopIO ownership and lock-free zero timestamps;
- silence on underrun and bounded drop-newest overflow;
- universal arm64/x86_64 builds and Apple Development signing discovery;
- explicit target-specific install/uninstall scripts with bundle and symlink
  validation;
- contract tests that load the built bundle and verify write-to-read sample
  identity;
- standalone ring tests and Thread Sanitizer coverage.

Production work still includes Developer ID/notarized packaging, installed
Intel validation, exposed driver metrics, deeper device unload/restart stress,
and interactive Audio MIDI Setup, Discord, Zoom, and browser validation.

The injection output is discoverable. Its name is not a security boundary.
Physical microphone passthrough, automatic device switching, and acoustic echo
cancellation are separate higher-level features and are not implemented in the
driver.

## Installation safety

The installer prints its exact target, invokes administrator authorization
explicitly, verifies the bundle ID and signature before copying, rejects
symlinks, never deletes wildcard paths, and leaves unrelated HAL plug-ins
untouched. The uninstaller only removes the exact AudioPlane bundle after
revalidating its identifier.

Build and test without changing system state:

```bash
./Scripts/build-audioplane-input-dev.sh
```

Installation is a separate explicit step:

```bash
./Scripts/install-audioplane-input.sh
```

The script does not restart Core Audio or change any default device. After a
reboot, use `audioplane outputs` or `sonexisctl outputs --json` and select
`coreaudio:com.audioplane.input.device`. Exact steps and unrun test status are
in [AudioPlane Input manual validation](audioplane-input-manual-validation.md).

## References

- Apple, [Creating an Audio Server Driver Plug-in](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)
- Apple, [Building an Audio Server Plug-in and Driver Extension](https://developer.apple.com/documentation/coreaudio/building-an-audio-server-plug-in-and-driver-extension)
- Apple, [AudioHardwareAggregateDevice](https://developer.apple.com/documentation/coreaudio/audiohardwareaggregatedevice)
- Apple, [AudioHardwareCreateAggregateDevice](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateaggregatedevice(_:_:))
- [BlackHole](https://github.com/ExistentialAudio/BlackHole), used only as an
  installed compatibility target; no BlackHole code is copied into AudioPlane.
