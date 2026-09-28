# audioplane SDK

This repository contains Sonexis Runtime, `sonexisctl`, the public SDKs and
examples, and Runtime's own `SonexisAudioEngine` Swift package. The engine name
is product branding: it is ordinary source code owned by this repository, not
a link, submodule, or dependency on the Sonexis App repository. This repository
contains no Sonexis consumer App, UI, DSP graph, presets, recording, or
workspace code.

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
