# Sonexis Runtime 1.0 Release Plan

## Scope freeze

Runtime 1.0 is a release-hardening milestone, not a feature milestone. It
promotes the v0.9 public-beta surface to a documented compatibility promise and
ships the strongest responsible local macOS release candidate that can be
produced without Developer ID/notarization credentials or interactive manual
audio validation.

Included:

- source-aware application capture, destination-aware output, and optional
  duplex composition;
- protocol v2, bounded binary data planes, structured events/errors,
  diagnostics, resource limits, and local same-user security controls;
- Python and TypeScript SDKs, CLI, control-only MCP, deterministic replay, and
  experimental OpenAI/Gemini adapters;
- signed universal development binaries and reproducible local SDK artifacts;
- compatibility, security, manual-validation, and operational documentation.

Explicitly deferred:

- protocol v3, new audio transports, Windows/Linux, SoundMux, cloud services,
  a first-party HAL virtual device, public package publication, and consumer AI
  product features;
- Developer ID signing, notarization, and public installer acceptance until the
  required external Apple credentials and release decision are available.

## Starting point

The v0.9 checkpoint is `f6c2817cb762759b3f4b5aef4fea7fc5719e2dfb`.
Its final full release gate passed capture/output/duplex regressions, fuzz,
1,000-cycle stress, TSan, all 85 Python tests, all 27 TypeScript tests, clean
SDK package installs, signed universal builds, development installation, and
adversarial artifact verification. Existing manual validations remain evidence
for the exact older builds on which they ran, not claims about the 1.0 binary.

## Release work

1. Bump Runtime, CLI, SDK, MCP, Xcode target, package, documentation, and
   manifest versions to `1.0.0` without changing the Sonexis application
   version (`2.1.0`).
2. Promote the v0.9 stable-candidate inventory to the 1.0 stable surface while
   retaining documented experimental provider/MCP integrations and
   compatibility bridges.
3. Audit release-relevant TODO/FIXME/force operations, skipped tests, warnings,
   error paths, and version copies; fix credible safety issues only.
4. Refine the root quickstart and product documentation so capture, playback,
   duplex, security boundaries, package ownership, and manual permissions are
   understandable without reading implementation code.
5. Produce the final manual-validation matrix, post-1.0 roadmap, release report,
   and autonomous handoff. Never mark interactive or credentialed tests passed
   unless they actually ran.
6. Incorporate independent security/privacy, external-developer, and
   release-blocker reviews, then rerun focused tests after each credible fix.

## Compatibility policy

Protocol v2 remains unchanged. Stable 1.0 protocol/SDK/CLI behavior follows
`runtime-api-stability.md` and `runtime-compatibility.md`. Additive protocol-v2
fields remain permitted; breaking meanings, required-field changes, or binary
layout changes require a future major protocol migration. Reconnect never
silently recreates streams. Experimental provider and MCP integrations remain
outside the provider-neutral core compatibility promise.

## Release artifacts and signing

The local artifact set remains two signed universal macOS binaries, Python
wheel/source distribution, TypeScript tarball, checksums, and a versioned
manifest. Verification must prove architecture, deployment target, stable
bundle identifiers, capture usage text, configured Apple Development signing,
SDK package inventory, source revision, and exact hashes. No debug entitlement,
build tree, credentials, captured audio, or generated dependency directory may
ship.

Apple Development signing is sufficient for local engineering validation. It
is not described as public distribution. Developer ID, notarization, and an
accepted installer/service design remain explicit external release work.

## Automated release gate

The final candidate must pass from a clean committed state:

- Sonexis application Debug build and all offline application regressions;
- Runtime protocol/core/output/integration, fuzz, lifecycle, and security tests;
- 1,000+ capture/output cycles, reconnects, parallel sessions, and bounded
  resource-accounting checks;
- output-ring concurrency and focused application tests under TSan;
- all Python and TypeScript tests, compiles, package clean installs, and example
  smoke tests;
- signed universal Runtime/CLI Release builds and development
  install/start/status/restart/stop/uninstall;
- reproducible artifact creation, independent verification, and adversarial
  tamper/inventory/manifest/symlink rejection;
- documentation link/version consistency and `git diff --check`.

P0/P1 correctness or security findings block the candidate. Manual physical
audio, provider credentials, TCC consent, loopback application routing, and MCP
host tests are tracked separately and do not become fictional automated passes.

## Checkpoints

Commit the scope plan first, then version/public-contract changes, credible
review fixes, final documentation/report, and the tested release checkpoint.
Create `runtime-v1.0.0-rc1` only after the final worktree is clean and the full
automated gate passes. Never merge or push during this effort.
