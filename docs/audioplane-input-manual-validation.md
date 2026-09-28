# AudioPlane Input manual validation

The automated suite builds, signs, loads, and contract-tests the driver bundle
without changing system audio. The following steps are intentionally manual
because installing a HAL driver is a privileged system change and selecting a
microphone inside third-party applications is interactive.

## Status

- Bundle build and ad-hoc signature: **PASSED**
- arm64/x86_64 universal binary inspection: **PASSED**
- factory/property/loopback contract test using the real bundle: **PASSED**
- lock-free ring tests and Thread Sanitizer: **PASSED**
- initial system installation and Core Audio enumeration: **PASSED**
- corrected `AudioPlane Input` data-source label after reinstall: **NOT RUN**
- v0.1.2 callback-jitter cushion after reinstall: **NOT RUN**
- physical microphone passthrough and concurrent speech mixing: **NOT RUN**
- Discord/Zoom microphone reception: **NOT RUN**
- uninstall/reboot recovery: **NOT RUN**

The first installed build loaded successfully and appeared as a virtual
microphone in an application device picker. That validation exposed the Apple
sample placeholder label `Data Source Item 0 (Virtual)`. Driver version 0.1.1
replaces the placeholder with the stable `AudioPlane Input` data-source name;
driver version 0.1.2 also adds bounded two-callback priming to prevent scheduling
jitter from splicing silence into active audio. Both changes still require
reinstall/reboot confirmation.

## 1. Build without installing

From the repository root:

```bash
make -C AudioPlaneHALDriver clean all test test-tsan inspect
```

For a development-signed build, find the exact identity and rebuild:

```bash
./Scripts/build-audioplane-input-dev.sh
```

## 2. Install explicitly

Review the script, then run:

```bash
./Scripts/install-audioplane-input.sh --check
./Scripts/install-audioplane-input.sh
```

The script validates the bundle ID and signature, refuses symlink targets, and
refuses ad-hoc signing. It only replaces
`/Library/Audio/Plug-Ins/HAL/AudioPlaneInput.driver`, invokes `sudo` visibly,
and does not restart Core Audio or alter any default device.

Restart the Mac. Open Audio MIDI Setup and verify:

- device name is **AudioPlane Input**;
- two input channels and two output channels are present;
- nominal sample rate defaults to 48 kHz.

## 3. Verify Runtime discovery

Start the signed Runtime and inspect destinations:

```bash
./Scripts/runtime-dev.sh start
audioplane outputs
```

Expected destination:

```text
coreaudio:com.audioplane.input.device  AudioPlane Input  virtual_input
```

## 4. Send deterministic audio

Select **AudioPlane Input** as the microphone inside Discord, Zoom, QuickTime
Player's New Audio Recording, or another receiving application. Do not change
the macOS default input unless that is independently desired.

Play a known WAV through AudioPlane:

```bash
export PATH="$HOME/Library/Application Support/SonexisRuntime/dev/bin:$PATH"
sonexisctl play /absolute/path/to/test.wav \
  --destination coreaudio:com.audioplane.input.device --debug
```

Confirm the receiving application sees meter activity and records intelligible
audio. Verify Runtime diagnostics report no dropped output frames.

## 5. Verify microphone plus injected-audio mixing

The signed Runtime build now exposes physical microphones through `audioplane
sources`. The first capture may trigger a separate macOS Microphone permission
prompt for `com.sonexis.runtime`.

Keep the receiving application set to **AudioPlane Input**. In one terminal:

```bash
audioplane sources
audioplane mic-through
```

Speak and confirm the receiving application hears the current default physical
microphone. In a second terminal, run:

```bash
audioplane speak
```

Enter several lines while speaking. Confirm both signals remain intelligible,
`Ctrl-C` stops only microphone passthrough, and neither command changes any
system or application device selection. If the desired physical input is not
the macOS default, pass its exact ID or name with `--source`.

## 6. Failure and recovery checks

While no test audio is being sent:

1. stop the Runtime and confirm the receiving application gets silence;
2. restart the Runtime and repeat playback;
3. stop playback mid-file and confirm buffered audio terminates cleanly;
4. confirm physical speakers, headphones, and microphone still work normally;
5. confirm no system default device changed.

## 7. Uninstall safely

```bash
./Scripts/uninstall-audioplane-input.sh
```

Restart the Mac. Confirm **AudioPlane Input** is gone from Audio MIDI Setup and
the third-party application's previous physical microphone can be selected.

The uninstaller refuses to delete a symlink, non-directory, or bundle whose ID
is not exactly `com.audioplane.input.driver`.
