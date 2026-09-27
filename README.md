# Sonexis Runtime standalone candidate

This local repository candidate contains Sonexis Runtime, `sonexisctl`, the
public SDKs/examples, and an exact snapshot of the extracted
`SonexisAudioEngine` Swift package. It contains no Sonexis consumer App, UI,
DSP graph, presets, recording, or workspace code.

Build both command-line products from a clean checkout:

```bash
swift build -c release
swift test --package-path SonexisAudioEngine
```

The local engine declaration in `Package.swift` is intentional for this
pre-hosting candidate. `ENGINE_PROVENANCE.json` pins the exact source commit
and Git tree copied into this repository; `Scripts/check-engine-provenance.py`
fails if the committed snapshot drifts.

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

Python SDK:

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -e SDKs/python
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
