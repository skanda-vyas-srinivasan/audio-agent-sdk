# AudioPlane Input HAL driver

`AudioPlane Input` is AudioPlane's first-party macOS virtual audio input. The
driver exposes a normal two-channel Core Audio output stream for injection and a
matching input stream that communications applications can select as a
microphone.

The implementation is based on Apple's official “Creating an Audio Server
Driver Plug-in” sample. Apple's license is preserved in
`APPLE_SAMPLE_LICENSE.txt`; AudioPlane-specific ring-buffer and build code is
part of this repository.

## Build without installing

```bash
make -C AudioPlaneHALDriver clean all test inspect
```

The default build creates a universal arm64/x86_64 bundle and signs it ad hoc:

```text
AudioPlaneHALDriver/.build/AudioPlaneInput.driver
```

For a development certificate, pass its exact identity:

```bash
make -C AudioPlaneHALDriver clean all \
  SIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
```

Building does not install or activate the driver. See
`Scripts/install-audioplane-input.sh --help` for the explicit system install
flow.

## Initial behavior

- two-channel interleaved Float32;
- 48 kHz default, with 44.1 kHz also supported by the Apple property model;
- fixed two-second transport capacity;
- drop-newest overflow policy;
- silence on underrun;
- no allocation, mutex, logging, or IPC in the sample-copy callback;
- no automatic default-device or application-device changes.

After manual installation, select **AudioPlane Input** as the microphone inside
Discord, Zoom, or another receiving application. Send audio to it through the
normal AudioPlane output API or CLI destination.
