# Sonexis Runtime v0.9 Plan

## Goal

v0.9 is the public-beta and API-freeze candidate. It adds no new audio
architecture. It turns the tested v0.8 surface into an explicitly classified,
compatibility-governed, reproducibly packaged developer product.

## Starting point

The v0.8 checkpoint is `b34b1382e0439834d583795624c7780765757464`
(with its report hash recorded by `dc9c624`). Protocol v2 supports capture,
output, duplex, events, diagnostics, bounded data planes, provider adapters,
MCP control, and Python/TypeScript SDKs. Signed universal Runtime and CLI builds,
local packages, TSan, fuzz, stress, and complete application regressions pass.

## Public API inventory

Inventory every externally reachable element:

- protocol commands, responses, DTO fields, frame formats, events, capabilities,
  error codes, limits, and environment variables;
- Python imports, methods, types, provider adapters, MCP entry point, and extras;
- TypeScript exports, methods, types, and Node event/iteration semantics;
- CLI commands/options/output schemas and exit behavior;
- MCP tools and schemas.

Each item will be classified as stable candidate, experimental, compatibility
bridge, or internal. Experimental provider integrations and transitional socket
discovery will be labeled without weakening the stable capture/output core.

## Naming and compatibility

Use the same concepts in Swift, Python, TypeScript, CLI, and docs: source,
capture, frame, session, output, destination, event, diagnostics, and duplex.
Resolve material inconsistencies before the freeze; avoid cosmetic churn.

Document semantic versioning for Runtime/SDK packages, protocol-v2 additive
compatibility, capability gating, error evolution, deprecation, and the support
matrix. The freeze candidate targets macOS 14.4+, Python 3.9+ for the core
(3.10+ provider/MCP extras), and Node 18+.

## Documentation structure

Create a Runtime documentation index organized as:

1. Getting Started
2. Concepts and Architecture
3. Capture
4. Output and Duplex
5. AI Integration
6. Python SDK
7. TypeScript SDK
8. MCP and CLI
9. Diagnostics and Security
10. Troubleshooting and Manual Validation

Existing concrete documents remain canonical; the index should route readers
without duplicating or mixing the unrelated Sonexis application release docs.

## Reproducible local artifacts

Add one release-artifact command that consumes a clean signed Release build and
produces, without publishing:

- signed universal `sonexis-runtime` and `sonexisctl`;
- Python wheel and sdist;
- TypeScript package tarball;
- SHA-256 checksums;
- a machine-readable manifest containing version, protocol, platform,
  architectures, artifact names/sizes/checksums, and source commit.

Generated artifacts stay ignored. Verification must reject dirty version
metadata, missing signatures/permission text, wrong bundle IDs, wrong
architectures, checksum mismatches, and accidental secrets/build directories.

## Changelog and release report

Create a concise `CHANGELOG.md` covering v0.1 through v0.9 by capability, not
commit dump. Produce `RUNTIME_V0_9_REPORT.md` with public inventory decisions,
compatibility policy, artifacts, checksums/manifest validation, external-DX
review, tests, limitations, manual gates, and the checkpoint commit.

## Review and tests

- independent public API/naming review;
- external developer review using only public docs/packages/examples;
- release-artifact and checksum adversarial tests;
- docs/link/version consistency checks;
- Python and TypeScript package clean-install tests;
- complete Runtime/app regression, fuzz, stress, TSan, and signed Release gate.

## Release gate

v0.9 is complete only when the public surface is classified, compatibility
policy and support matrix are concrete, documentation is navigable, local
artifacts are reproducible and verified, `CHANGELOG.md` and the v0.9 report
exist, independent findings are resolved, all prior gates pass, and the worktree
is committed and clean.

