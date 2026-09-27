# Sonexis Runtime v0.5 plan: developer distribution

## Starting point

v0.4 at `43f060c` provides signed application capture, bidirectional protocol-v2
PCM streams, Core Audio playback, Python and TypeScript SDKs, provider adapters,
CLI diagnostics, bounded buffering, stress/fuzz tests, and generic installed
loopback-device support. Development currently assumes repository knowledge:
developers must know Xcode schemes, Derived Data paths, socket environment
variables, package subdirectories, and which examples match which concept.

This milestone changes distribution and developer experience, not audio
semantics. Protocol v2 remains compatible and capture/output callbacks remain
unchanged unless a release audit finds a correctness issue.

## Friction audit

- Runtime and CLI are standalone signed Mach-O products inside a Derived Data
  tree, with no coherent local install prefix or version manifest.
- A previously running Runtime is detected only as a socket conflict; users do
  not get a supported start/status/stop development-service workflow.
- Runtime, CLI, Python, TypeScript, and protocol versions are repeated in
  several files and can drift.
- Python editable installs work, but wheel/sdist contents and a clean virtual
  environment are not release-gated.
- TypeScript compiles and tests, but local `npm pack` contents are not gated.
- Root documentation primarily describes the GUI application rather than a
  zero-to-audio Runtime path.
- Examples overlap and do not form a deliberately named, smoke-testable set.
- Connection and permission failures are structured internally but often lack
  an immediately actionable developer hint.
- The standard socket path is deterministic, but SDK/CLI discovery and an
  explicitly installed development layout are not documented as one contract.

## Proposed v0.5 architecture

### Build and local installation

Add one repository script that builds signed Debug Runtime/CLI products and
installs copies into an explicit per-user development prefix. Default prefix:

```text
~/Library/Application Support/SonexisRuntime/dev/
  bin/sonexis-runtime
  bin/sonexisctl
  manifest.plist
```

The script will accept an override for tests, stage into a sibling temporary
directory, verify code signatures and embedded Runtime permission metadata,
then atomically replace only the named Sonexis development directory. It will
never use `sudo`, modify `/usr/local`, install a launch agent implicitly, or
delete wildcard paths. Uninstall will require the exact expected manifest and
remove only files owned by this development layout.

### Lifecycle tooling

Keep the Runtime executable foreground-first. Add explicit development scripts
for opt-in background start/status/stop rather than silently installing
persistence. The scripts will:

- use a per-user Runtime state directory with private permissions;
- reject or report a healthy existing instance instead of replacing it;
- validate PID identity before signalling;
- distinguish a stale PID/socket from a live Runtime;
- capture bounded metadata logs without audio content;
- perform bounded graceful shutdown and report failure clearly.

A launchd agent is intentionally deferred until its install/update ownership
and signing behavior can be treated as a product rather than a shell shortcut.

### SDK artifacts

Python will produce a wheel and sdist with typed package data and no repository
internals. A fresh virtual environment will install the wheel without network
dependencies and run import/public-API smoke tests. Optional provider extras
remain separate.

TypeScript will build declarations/ES modules, run tests, and create a local
`.tgz`. Package-content tests will reject source tests, credentials, caches,
and generated files outside the declared `files` list.

### Examples and documentation

Create small public-API examples for:

- one source capture;
- labeled multi-source capture;
- playback;
- duplex;
- Gemini;
- OpenAI; and
- control-only MCP.

Offline smoke mode or compile/import checks will cover examples that otherwise
need TCC, audio hardware, or provider credentials. The root Runtime quickstart
will separate automated setup from manual permission and live-audio checks.

### Error UX

Public SDKs and CLI will preserve structured error codes while adding concise
actions for common local failures: Runtime absent, incompatible version,
permission denial, missing/ambiguous source, unavailable output, missing
loopback, unsupported format, and missing provider dependency. Credentials and
audio content must never appear in hints or logs.

## Compatibility and versioning

v0.5 keeps protocol version 2. Runtime/CLI/SDK artifact versions advance to
`0.5.0`; the handshake continues to accept v0.4 protocol-v2 clients. Add a
machine-readable version manifest generated from one checked-in release value
or verified for equality during the release gate. No reconnect magic or
background auto-start is added to SDK calls.

## Testing strategy

- focused shell tests use an isolated temporary install prefix and socket;
- lifecycle tests start a synthetic or real Runtime only in a private temporary
  directory and never signal unrelated processes;
- uninstall tests prove unrelated sentinel files survive;
- Python wheel/sdist build and clean-environment import tests run offline;
- TypeScript build/test/pack and tarball-content assertions run locally;
- examples receive syntax/import/public-API smoke coverage;
- existing protocol, integration, fuzz, stress, TSan, Python, TypeScript, and
  full Sonexis regressions remain release gates;
- signed Runtime/CLI identity and `NSAudioCaptureUsageDescription` are verified.

## Security and privacy

Installation is per-user and never privileged. Background mode is opt-in and
does not widen the same-UID Runtime trust boundary. PID files are metadata, not
authorization; scripts validate executable path and live protocol status before
signalling. Socket and log directories remain private. Logs exclude PCM,
transcripts, provider responses, environment dumps, and credentials.

## Release gate

v0.5 completes only when:

1. Runtime and CLI build and sign cleanly.
2. Install/start/status/stop/uninstall pass in an isolated prefix.
3. A fresh Python environment installs built artifacts and runs SDK smoke tests.
4. TypeScript builds, tests, packs, and passes package-content checks.
5. All examples pass their available automated smoke checks.
6. Full Runtime and Sonexis regressions, fuzz, stress, and TSan pass.
7. An independent developer-experience review has no unresolved serious issue.
8. Documentation and `RUNTIME_V0_5_REPORT.md` record exact automated and manual
   status.
9. The worktree is clean at a committed v0.5 checkpoint before v0.6 begins.

## Explicit non-goals

- no launch agent installed without an explicit later product decision;
- no system-wide installer, privileged helper, notarization upload, or package
  publication;
- no Runtime audio-path redesign;
- no first-party virtual audio driver;
- no automatic provider credential discovery beyond documented environment
  variables.
