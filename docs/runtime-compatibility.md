# Runtime Compatibility Policy

## Versioning

Runtime, CLI, Python, and TypeScript packages share one semantic version in this
repository. Before 1.0, minor versions may refine experimental integrations;
the surfaces marked “stable candidate” in `runtime-api-stability.md` are already
treated as compatibility-sensitive. At 1.0:

- patch: compatible fixes, diagnostics, and performance work;
- minor: backward-compatible additions and deprecations;
- major: intentional breaking public API or protocol changes.

Provider/MCP integrations marked experimental may require faster adaptation to
upstream SDKs, but cannot break the provider-neutral Runtime core.

## Runtime and SDK negotiation

Protocol version, not package version equality, determines wire compatibility.
Every connection begins with `hello`, selects protocol 2, and returns Runtime
version, capabilities, formats, limits, and instance ID. SDKs must:

1. reject an unsupported protocol;
2. gate optional operations/fields on capabilities;
3. ignore unknown additive JSON fields/capabilities/events they did not request;
4. never silently recreate capture/output streams after reconnect;
5. treat stream/session IDs from a previous Runtime instance as stale.

Protocol v2 changes are additive: optional fields, new capabilities, commands,
events, error codes, and supported formats may be added. Existing required
fields, binary layout, meanings, and ordering guarantees are frozen candidates.
A protocol v3 requires a change impossible to express additively and explicit
dual-version migration analysis.

## Deprecation

Stable API deprecation will be documented in the changelog and SDK docs, retain
a working compatibility path for at least one minor release after 1.0, and
identify the replacement. Security fixes may shorten that period when retaining
behavior would be unsafe. Human-readable CLI formatting and error prose are not
compatibility contracts; JSON keys/codes are.

## Supported platform matrix

| Component | Candidate minimum |
|---|---|
| Runtime and CLI | macOS 14.4, Apple Silicon or Intel x86_64 |
| Build | Xcode 16 with macOS 14.4 SDK or newer |
| Python core SDK | CPython 3.9 |
| Python provider/MCP extras | CPython 3.10 |
| TypeScript package | Node.js 18 |

Release artifacts are universal macOS binaries signed with the configured Apple
Development identity. Public distribution still requires Developer ID signing,
notarization, and installer acceptance; local engineering completion does not
claim those external credentials were used.

## Source and binary compatibility

Python and TypeScript promise documented source behavior, not private class
layout. Runtime/CLI binaries promise protocol and command behavior, not a C/Swift
ABI. The Unix socket is local-only and same-UID. Filesystem data-socket names,
Core Audio IDs, and implementation queues are never stable APIs.
