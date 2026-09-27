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
pre-hosting candidate. See the parent extraction documentation for the
repository/versioning recommendation.

The SwiftPM build proves source independence, but it is not the signed live-TCC
distribution path: it does not embed `Distribution/Runtime-Info.plist` into the
Mach-O executable. Use the signed Xcode release build documented in
`docs/sonexis-runtime.md` for live Process Tap validation until a standalone
signed wrapper target is added.

Python SDK:

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -e SDKs/python
```

No package has been published and no remote has been configured.
