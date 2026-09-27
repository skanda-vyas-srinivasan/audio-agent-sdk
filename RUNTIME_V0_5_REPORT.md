# Sonexis Runtime v0.5 report

## Result

Runtime v0.5 turns the repository-only v0.4 build into an explicit, recoverable
developer distribution. It preserves protocol v2 and all capture, playback,
duplex, provider, and realtime behavior while adding:

- one synchronized `0.5.0` Runtime/CLI/SDK version with a drift gate;
- signed universal Runtime and CLI Release products;
- a per-user manifest-verified development install;
- explicit foreground or opt-in background lifecycle commands;
- clean Python wheel/sdist and TypeScript tarball consumer tests;
- focused public-API examples and a zero-to-audio quickstart;
- actionable, structured connection/capture/output failures; and
- a single full release-gate entry point.

No protocol message or realtime audio path changed in v0.5. The original
`/Users/skandavyas/Sonexis` worktree was not modified.

## Developer flow

```sh
cd /Users/skandavyas/Sonexis-runtime-v04
security find-identity -v -p codesigning
./Scripts/setup-runtime-dev.sh
./Scripts/runtime-dev.sh start
"$HOME/Library/Application Support/SonexisRuntime/dev/bin/sonexisctl" sources
```

For a different configured Xcode team:

```sh
SONEXIS_DEVELOPMENT_TEAM=YOUR10CHARTEAM ./Scripts/setup-runtime-dev.sh
```

Python SDK:

```sh
/usr/bin/python3 -m venv --system-site-packages .venv-runtime
. .venv-runtime/bin/activate
python -m pip install --no-deps --no-build-isolation -e SDKs/python
python Examples/capture-one-source.py "Google Chrome" --frames 16000
```

Stop and uninstall:

```sh
./Scripts/runtime-dev.sh stop
./Scripts/uninstall-runtime-dev.sh
```

The uninstaller removes only an intact manifest-owned install. Lifecycle logs
and state remain under `~/Library/Application Support/SonexisRuntime/state`.

## Distribution and lifecycle

The default installation prefix is:

```text
~/Library/Application Support/SonexisRuntime/dev/
  bin/sonexis-runtime
  bin/sonexisctl
  manifest.plist
```

Installation is unprivileged and does not install a launch agent. It validates
regular files, Apple Development signatures, matching Team IDs, stable code
identifiers, `NSAudioCaptureUsageDescription`, versions, and SHA-256 hashes.
Replacement uses private sibling staging. Existing unmanaged, symlinked,
modified, running, or unexpectedly populated installs are preserved and
rejected.

`Scripts/runtime-dev.sh` supports `start`, `status`, `stop`, `foreground`, and
`logs`. Stop validates the stored PID, exact executable, and live Runtime
instance ID before sending `SIGTERM`; it never force-kills. Duplicate starts,
crash/stale-socket recovery, double stops, custom install paths, spaces in
paths, and unexpected live instances are handled explicitly. State/log
symlinks are rejected. Logs rotate on startup above 1 MiB, but one unusually
noisy process can exceed that threshold before restart.

## SDK artifacts and examples

The Python gate copies only tracked package sources, builds a wheel and sdist,
checks the GPL license and `py.typed`, installs each artifact into a fresh
environment, imports the public package/provider/MCP modules, and runs every
public example's help/import path against the installed wheel.

The TypeScript gate copies only tracked sources, performs `npm ci`, compiles and
runs tests, executes `prepack`, checks the five-file tarball, rejects leaked
source/test/cache directories, and imports the package from a fresh external
consumer.

Focused examples now cover one capture, labeled multi-source capture, WAV
playback, duplex ownership, Gemini/OpenAI, and MCP control. Live examples catch
normal public SDK errors and print concise failures. Decimal source arguments
in the one-source example resolve as PIDs as documented.

## Error and command UX

- Runtime and CLI expose offline `--help`/`--version` behavior.
- Runtime rejects unknown options and non-absolute socket directories.
- CLI rejects unknown commands, duplicate options, irrelevant options, and
  wrong positional counts before connecting.
- Python, TypeScript, and CLI missing-Runtime errors tell developers to start
  the local `sonexis-runtime` process without assuming a repository path.
- Python output drain now surfaces structured Runtime playback failures.
- Capture initialization retains the underlying failure and adds a truthful
  Screen & System Audio Recording permission check.

## Security and signing

Release products were built universal (`arm64`, `x86_64`) for macOS 14.4 and
strictly verified with Apple Development Team `7934D5M686`. The identifiers are
`com.sonexis.runtime` and `com.sonexis.ctl`. Release signing no longer injects
`com.apple.security.get-task-allow`. Runtime still embeds
`NSAudioCaptureUsageDescription`.

The install remains per-user. No `sudo`, persistent agent, TCP listener, API
credential, audio recording, build product, virtual environment, or npm module
directory is committed. The Runtime's documented same-UID trust model is
unchanged.

## Automated validation

Environment:

- macOS 27.0 (`26A428`)
- Xcode 27.0 (`27A266a`)
- Swift/Xcode macOS SDK 27.0
- system Python 3.9.6
- Node 26.10.0 and npm 11.19.1

`Scripts/test-runtime-release.sh` passed on 2026-09-27. It ran:

- Debug Sonexis application build: passed;
- complete `Scripts/test-all.sh` application and Runtime regression groups:
  passed;
- protocol fuzz/adversarial corpus: passed;
- Runtime stress: 1,000 capture cycles, 1,000 output cycles, 200 connections,
  16 parallel sessions, FD growth 1: passed;
- output ring concurrent write/read/flush stress under TSan: passed;
- full application concurrency TSan build/tests: passed;
- Python SDK: 61 tests passed;
- TypeScript SDK: 18 tests passed;
- public example syntax/import/help smoke: passed;
- clean Python wheel and sdist build/install/import: passed;
- clean TypeScript build/test/pack/external import: passed;
- signed universal Release Runtime and CLI builds: passed;
- Release identity, entitlement, minimum-OS, architecture, permission metadata,
  and version checks: passed; and
- install/reinstall/start/status/crash recovery/stop/uninstall and adversarial
  distribution tests: passed.

The final primary non-TSan stress run reported 1.388 seconds,
11,157,504-byte peak RSS, and one-descriptor growth. The final TSan stress run
reported 3.961 seconds, 88,342,528-byte peak RSS, and one-descriptor growth. These are test-process
peak values, not live Core Audio latency measurements.

## Independent DX review

A read-only external-developer review inspected the public docs, scripts,
packages, examples, and errors. Credible findings fixed before release:

- uninstall could remove a binary still executing under custom lifecycle
  paths: fixed with a post-stop `lsof` refusal and regression;
- raw signature verification failures bypassed actionable guidance: fixed;
- CLI typos could be masked by a connection failure: fixed with complete local
  invocation validation;
- installed SDK errors assumed a repository-relative lifecycle script: fixed;
- signing-team discovery and uninstall/state retention were unclear: documented;
- lifecycle state/log symlinks could redirect writes: rejected and tested;
- Release products carried `get-task-allow`: removed and release-gated;
- PID input and normal failure presentation in examples were inconsistent:
  fixed; and
- package tests hid TypeScript failure output: fixed.

The review agent's restricted subprocess could not access the login keychain or
bind Node test sockets. Those environment-specific failures were rechecked in
the lead environment: two valid signing identities were present, strict signed
artifact checks passed, and all 18 TypeScript tests passed.

## Manual validation status

- Previously authenticated Chrome -> Runtime -> Gemini semantic capture:
  **PASSED in v0.3; not rerun for v0.5**.
- Live Process Tap capture/TCC prompt: **NOT RUN for v0.5**; v0.5 did not alter
  capture behavior.
- Audible default/headphone playback: **NOT RUN for v0.5**; v0.5 did not alter
  playback behavior.
- BlackHole -> Discord/Zoom loopback: **NOT RUN for v0.5**.
- Authenticated OpenAI/Gemini provider calls: **NOT RUN for v0.5**.
- Developer ID notarization/public distribution: **NOT RUN**; v0.5 is a local
  Apple Development distribution.

## Known limitations

- Lifecycle tooling is repository-owned and intentionally does not install a
  persistent launch agent or global wrapper.
- The same macOS UID remains the Runtime authorization boundary.
- Lifecycle logging rotates only between process launches.
- Python's compatibility `setup.py` path emits legacy metadata/deprecation
  warnings with the system Python/pip; built artifacts pass clean install tests.
- Protocol-v2 JSON nanosecond integers remain subject to JavaScript `number`
  precision limits; binary audio timestamps use `bigint`.
- Physical audio, TCC, provider credentials, AirPods, and loopback application
  selection still require the documented manual validation paths.

## Commits

- `c478371` — plan v0.5 developer distribution
- `4a69ec4` — synchronize v0.5 versions and improve error UX
- `78df5d7` — add safe development install/lifecycle
- `fc3b6e2` — package SDKs, examples, and release gates
- `2cdfb53` — harden distribution after independent DX review
- final documentation/checkpoint commit — the commit containing this report

The complete implementation before this report is
`2cdfb5382ada72d9bcef4b65c3e3d559cbf00272`. The v0.5 checkpoint is the clean
commit containing `RUNTIME_V0_5_REPORT.md`; obtain its immutable ID with
`git rev-parse HEAD` before beginning v0.6.

## Next milestone

Proceed to v0.6 only from the clean v0.5 checkpoint. v0.6 should make output
destinations first-class lifecycle resources, add device/default-change events,
improve destination resolution and format negotiation, and document a firm
first-party virtual-device decision without changing the stable source-aware
capture model.
