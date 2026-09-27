# Sonexis Runtime v0.9 Report

## Summary

Sonexis Runtime v0.9 is the public-beta and API-freeze candidate. It preserves
the v0.8 capture, playback, duplex, event, diagnostics, provider-adapter, CLI,
and MCP behavior while making the supported surface explicit, closing
cross-language precision and developer-experience gaps, and producing
independently verifiable local release artifacts.

The Runtime and CLI remain local macOS developer products. This release does
not claim Developer ID distribution, notarization, or an installer suitable for
unattended public deployment.

## Public API decisions

The authoritative inventory is `docs/runtime-api-stability.md`.

- Protocol v2, its request/response envelope, capture/output commands, SXPC v2
  frame layout, structured errors, and capability negotiation are stable
  candidates.
- Python and TypeScript capture, playback, event, diagnostics, multi-source,
  and duplex APIs are stable candidates.
- Provider adapters and MCP remain experimental integrations above the stable
  provider-neutral Runtime.
- Core Audio identifiers, private socket names, queue implementations, and
  Swift server internals are not public APIs.
- Human CLI output is descriptive. Documented `--json` shapes and error codes
  are the machine interface.

## Compatibility

`docs/runtime-compatibility.md` defines the semantic-versioning, protocol,
capability, deprecation, and support policies. Runtime and SDK package versions
need not match exactly when both negotiate protocol v2 and the required
capabilities. Reconnect never silently recreates audio sessions, because doing
so would change source/output ownership semantics.

Candidate minimums are macOS 14.4, Python 3.9 for the provider-neutral SDK,
Python 3.10 for optional integrations, and Node.js 18.

## Protocol precision

Protocol v2 continues to encode legacy numeric UInt64 fields for backward
compatibility. v0.9 adds decimal-string mirrors for every long-lived value an
ECMAScript client may need after it exceeds `Number.MAX_SAFE_INTEGER`:

- Runtime aggregate counters;
- capture/output session start timestamps;
- capture/output metrics;
- event sequence, drop, and timestamp fields.

Binary SXPC sequence and timestamp fields continue to use native `bigint` in
TypeScript. The additive mirrors avoid a protocol-v3 break.

## SDK and naming policy

Python public names remain snake case. TypeScript methods and enriched frame
objects are idiomatic camel case; protocol DTO snapshots intentionally retain
wire field names so diagnostics can be compared directly with CLI JSON. That
choice is documented instead of performing a breaking cosmetic rewrite at the
freeze boundary.

Standalone playback uses a provider-neutral format compatible with generic
capture unless the caller explicitly supplies a model/provider preset. Duplex
continues to default output to its negotiated input format. Existing queue
configuration names retain compatibility aliases where a clearer packet-based
name is available.

## Release artifacts

`Scripts/build-runtime-artifacts.sh` consumes a clean, signed universal Release
build and creates a versioned local directory containing:

- signed universal `sonexis-runtime`;
- signed universal `sonexisctl`;
- Python wheel and source distribution;
- TypeScript package tarball;
- `manifest.json` with source commit, platform, architecture, signing, size,
  and SHA-256 metadata;
- `SHA256SUMS`.

`Scripts/verify-runtime-artifacts.sh` independently checks hashes, manifest
membership, versions, architectures, signatures, bundle identifiers, capture
permission metadata, and SDK package contents. Artifacts are generated below
ignored `.build/` paths and are not committed or published.

## Documentation

`docs/runtime-documentation.md` is the product-oriented entry point. The
Runtime guide, SDK READMEs, security policy, and root README distinguish the
Sonexis application version from the Runtime version and provide exact paths
from checkout to capture, playback, duplex, CLI, MCP, and diagnostics.

`CHANGELOG.md` records capability evolution from v0.1 through v0.9 without
duplicating commit history.

## Testing

Focused validation during implementation:

- Runtime protocol v2 round-trip and malformed-frame tests;
- Runtime capture and output core tests;
- Runtime socket integration tests;
- Python SDK tests;
- TypeScript compile and test suite;
- version-consistency and diff checks.

Release-gate results, artifact paths, and exact aggregate test counts are
recorded here after the final clean gate rather than predicted.

## Independent reviews

Three read-only v0.9 reviews were performed before the freeze work:

- API inventory found JavaScript UInt64 precision gaps, mixed TypeScript DTO
  conventions, accidental lifecycle visibility, incomplete typed-error parity,
  and machine-output documentation gaps.
- External developer review found unsafe generic playback defaults, stale
  current-version docs, queue terminology ambiguity, first-run permission and
  PATH friction, and missing lifecycle/error parity.
- Release/docs review found no persistent artifact set, manifest, checksums,
  compatibility policy, public inventory, changelog, or Runtime-specific
  security coverage.

Credible findings were addressed without changing the audio data planes or
breaking protocol v2. A final follow-up review is part of the release gate.

## Security and privacy

The Runtime remains local-only and same-UID. Control and data sockets live in a
private per-user directory; compatibility discovery does not weaken ownership
checks. Capture and audio injection are both sensitive operations. The MCP
surface stays control-only, mutations are opt-in, no PCM flows through MCP, and
audio content is never included in diagnostic bundles by default.

Development signatures are verified in artifacts. They are not a substitute
for Developer ID signing and notarization.

## Known limitations

- Signed Process Tap capture still requires macOS user consent and live manual
  validation for each relevant installation identity.
- Physical output, AirPods route changes, BlackHole routing into third-party
  applications, authenticated providers, and a real MCP host require manual or
  credentialed validation.
- Provider adapters track upstream APIs and remain experimental.
- The legacy `/tmp/sonexis-runtime-$UID` compatibility endpoint remains during
  migration; the private per-user endpoint is canonical.
- No first-party HAL virtual device is shipped; supported installed loopback
  devices such as BlackHole are discovered as destinations.
- Public distribution still needs Developer ID credentials, notarization, and
  an accepted installer/service design.

## Manual validation status

- Previously authenticated Chrome -> Process Tap -> Runtime -> Python SDK ->
  Gemini Live semantic understanding: **PASSED** during v0.3.
- Signed live Process Tap capture and listenable Spotify PCM: **PASSED** during
  v0.2/v0.3 validation.
- v0.9 clean install identity permission prompt: **NOT RUN**.
- v0.9 physical playback and device switching: **NOT RUN**.
- v0.9 BlackHole -> Discord/Zoom: **NOT RUN**.
- v0.9 authenticated OpenAI/Gemini round trip: **NOT RUN**.
- MCP host interoperability: **NOT RUN**.

## Commits

- `021c41d` — plan v0.9 public beta.
- `f76de29` — define v0.9 public beta artifacts and policy.
- `3b31113` — preserve exact session and event counters.

The final checkpoint commit is recorded after the release report is complete.

## Next milestone

v1.0 should freeze scope, triage release blockers, run a clean-room build and
the complete test matrix, verify development signing, perform final security
and external-developer reviews, and produce the final manual-validation guide
and handoff. It should not add speculative audio features.
