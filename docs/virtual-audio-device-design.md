# Virtual audio input design

## v0.6 decision for the 1.0 line

Runtime v0.6 supports installed Core Audio loopback devices as first-class
`virtual_input` output destinations when they expose both output and input
streams and their name/UID identifies a loopback/virtual device. It was live-tested with `BlackHole 2ch`:
Sonexis accepted 24 kHz mono PCM, converted it to the device's 48 kHz stereo
format, rendered the exact expected device-frame count, and reported zero
drops. This validates Runtime's output half of the loopback path. Selecting the
device as a microphone and confirming receipt in another application remains a
separate manual validation.

The `virtual_input` label is an advisory name/UID plus input-stream heuristic,
not an authorization or connectivity guarantee. Any local process able to open
the loopback device's input stream can read audio injected there. v0.4 supports
only single-output-stream, one- or two-channel devices; more complex aggregate
or multi-stream layouts are rejected.

Sonexis Runtime 1.0 will **not** install a first-party Sonexis HAL driver.
Shipping an unreviewed
driver merely to claim completion would put the system audio service at risk.
Apple's supported sample is a 4,000-plus-line AudioServerPlugIn with a large HAL
property surface; its null device does not provide Sonexis's required loopback
transport. Installation requires administrator authorization, placement in
`/Library/Audio/Plug-Ins/HAL`, and a reboot. Production distribution also
requires a driver-specific signing/notarization/installer lifecycle that is not
covered by the Runtime's executable signing identity.

This is a deliberate 1.0 product boundary, not a claim that macOS cannot implement
the device. Generic destination support ships and validates the
Runtime-to-installed-loopback output path without coupling Runtime to a
particular driver. It does not by itself prove receipt by Discord, Zoom, or a
browser.

The v0.6 endpoint APIs remove the main usability penalty of this decision:
installed loopback devices have stable IDs, exact-name/kind resolution,
add/remove/update events, wait helpers, native-format metadata, and advisory
duplex feedback warnings. Owning a driver would still require a separate
installer/signing/recovery program and would increase the blast radius from one
user process to system audio. That trade is not responsible before the Runtime
API, distribution, and long-soak behavior reach 1.0.

## Mechanisms considered

### Normal HAL playback

The Runtime can render to the default or a fixed output device with
`AudioDeviceCreateIOProcID`. It is the correct mechanism for speakers,
headphones, and the output side of a loopback driver. It cannot make a new
microphone device appear by itself.

### Aggregate device

`AudioHardwareCreateAggregateDevice` combines streams from existing devices.
It does not create a new transport and therefore cannot replace a loopback
driver. Wrapping an installed loopback only changes presentation and adds
lifecycle complexity.

### AudioServerPlugIn HAL driver

Apple's supported virtual-device sample publishes a `.driver` plug-in with
Float32 two-channel input/output at 44.1/48 kHz. This is the appropriate basis
for a future `Sonexis Agent Input`. The safe architecture is:

```text
Runtime --HAL writes--> hidden/injection output stream
                              │
                    driver-owned bounded ring
                              │
application <--HAL reads-- visible Sonexis Agent Input
```

Using the normal HAL write path avoids custom Runtime-to-driver socket or
shared-memory IPC. The driver's realtime callbacks index a preallocated ring by
HAL sample time, return silence on underrun, never block, and never allocate or
log. The device can remain loaded while Runtime is absent.

### DriverKit audio extension

Apple's AudioServerPlugIn + DriverKit sample targets hardware-backed drivers and
requires DriverKit entitlements/provisioning (or disabling SIP for ad-hoc local
testing). That is disproportionate for a virtual-only loopback. A conventional
AudioServerPlugIn is the narrower design for the first Sonexis virtual device.

## Required branded-driver work

A production-quality future driver must implement and independently validate:

- a complete HAL object/property model and correct stream formats;
- a visible input and private injection output with stable UIDs;
- an allocation-free, lock-free, sample-time-indexed ring;
- multi-client StartIO/StopIO ownership and zero timestamps;
- format/rate changes, device unload, Runtime absence/restart, and stale audio;
- underrun/overrun counters without realtime logging;
- signed Debug and Developer ID distribution identities;
- an idempotent privileged installer and target-specific uninstaller;
- reboot/coreaudiod lifecycle instructions and recovery from a bad install;
- Apple Silicon and Intel testing plus Audio MIDI Setup, Discord, Zoom, and
  browser validation.

If a future driver exposes a private injection output alongside the public
microphone input, that output also needs an explicit access-control and
discoverability design. A hidden-looking Core Audio stream is not a security
boundary.

The installer must print its exact target, require an explicit confirmation or
administrator invocation, verify bundle ID/signature before copying, never
delete wildcard paths, and leave unrelated HAL plug-ins untouched.

## Current development flow

Install a trusted, signed loopback driver using that driver's own installer.
Do not copy third-party bundles with a Sonexis script. Start Runtime, run
`sonexisctl outputs --json`, and select the returned `virtual_input` ID. The
Runtime does not need to restart when it enumerates a device, but a newly
installed HAL driver normally requires the vendor/Apple-prescribed reboot.

No Sonexis install/uninstall script is included because there is no Sonexis
driver artifact to install. Exact current validation is in
`runtime-v0.4-manual-validation.md`.

## References

- Apple, [Creating an Audio Server Driver Plug-in](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)
- Apple, [Building an Audio Server Plug-in and Driver Extension](https://developer.apple.com/documentation/coreaudio/building-an-audio-server-plug-in-and-driver-extension)
- Apple, [AudioHardwareAggregateDevice](https://developer.apple.com/documentation/coreaudio/audiohardwareaggregatedevice)
- Apple, [AudioHardwareCreateAggregateDevice](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateaggregatedevice(_:_:))
- [BlackHole](https://github.com/ExistentialAudio/BlackHole), used only as an
  installed compatibility target; no BlackHole code is copied into Sonexis.
