# AudioPlane

AudioPlane is a programmable, source-aware audio I/O Runtime and SDK for macOS.
It captures individual application audio streams and routes realtime generated
audio to local output destinations without requiring clients to implement Core
Audio.

The repository still contains internal `SonexisRuntime`, `sonexisctl`, and
`SonexisAudioEngine` identifiers for v1.0 compatibility. Those are ordinary
source code owned by this standalone repository—not links or dependencies on
the Sonexis App repository. This repository contains no Sonexis consumer App,
UI, DSP graph, presets, recording, or workspace code.

Build both command-line products from a clean checkout:

```bash
swift build -c release
swift test --package-path SonexisAudioEngine
```

The local engine declaration in `Package.swift` is intentional. Runtime and
its engine evolve together in this repository and build without any sibling
checkout or external source dependency.

For real Process Tap capture, configure an Apple Development identity in Xcode,
then build/install the signed development products. The SwiftPM Runtime embeds
the stable `com.sonexis.runtime` Info.plist and capture usage description; the
script signs it with the first available Apple Development identity (or
`SONEXIS_SIGNING_IDENTITY`):

```bash
./Scripts/setup-runtime-dev.sh
./Scripts/runtime-dev.sh start
"$HOME/Library/Application Support/SonexisRuntime/dev/bin/sonexisctl" sources
```

This installs only to the current user's Application Support directory. It
does not use `sudo`, install a launch agent, or modify system audio components.

Install the Python CLI in an isolated environment directly from GitHub:

```bash
pipx install \
  "git+https://github.com/skanda-vyas-srinivasan/audioplane.git#subdirectory=SDKs/python"
audioplane version
audioplane doctor
audioplane sources
```

`pipx` installs the Python client, not the signed native Runtime. The Runtime
must be built and started first using the commands above.

Python SDK for checkout development:

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -e SDKs/python
```

```python
from audioplane import AudioPlane

async with AudioPlane() as audio:
    sources = await audio.sources()
```

Run the self-contained regression/release gate with:

```bash
./Scripts/test-runtime-release.sh
```

It covers the engine package, Runtime protocol/core/output/integration/fuzz/
stress tests, Thread Sanitizer, Python tests/examples/packaging, TypeScript
tests/packaging, embedded TCC metadata, stable identifiers, and development
signing. Live capture still requires interactive macOS permission and audible
source validation.

No package has been published and no remote has been configured.
