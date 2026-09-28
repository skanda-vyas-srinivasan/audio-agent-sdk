# Sonexis Runtime changelog

This changelog summarizes developer-visible Runtime and SDK milestones. It is
not a dump of repository commits. Sonexis Runtime versions are independent of
the native Sonexis application's 2.x release line.

## Unreleased

- Added physical Core Audio input discovery and capture through the existing
  protocol-v2 source/session/data-plane model, including stable device-UID IDs,
  default-input metadata, microphone permission text, and SDK resolution.
- Added bounded Python microphone passthrough and `audioplane mic-through`, so
  a physical microphone and independently injected speech/model audio can feed
  AudioPlane Input concurrently without changing system device selections.
- Added a two-callback virtual-input read cushion to reduce scheduling jitter;
  reinstall/reboot validation of the updated driver remains manual.

## 1.0.0 — Production release candidate

- Promoted the provider-neutral protocol v2, Python/TypeScript capture,
  playback, duplex, events, diagnostics, and documented CLI JSON surfaces from
  stable candidates to the 1.0 compatibility policy.
- Retained provider adapters and MCP as explicitly experimental integrations;
  no protocol or realtime data-plane redesign was introduced at the freeze.
- Added final release-blocker, security/privacy, and external-developer review,
  a complete manual-validation matrix, and an autonomous release handoff.
- Reverified clean SDK packages, signed universal local-development binaries,
  1,000-cycle stress, fuzz, TSan, application regressions, and adversarial
  artifact validation. Public distribution still requires Developer ID signing
  and notarization.

## 0.9.0 — Public beta / API-freeze candidate

- Classified protocol, Python, TypeScript, CLI, and MCP surfaces as stable
  candidates, experimental integrations, compatibility bridges, or internal.
- Defined semantic-versioning, protocol/SDK compatibility, and deprecation
  policy ahead of 1.0.
- Added exact decimal-string mirrors for long-lived session, event, metric, and
  Runtime counters/timestamps while retaining protocol-v2 numeric fields.
- Added reproducible local Runtime, CLI, Python, and TypeScript artifacts with
  a version manifest, checksums, and verification tooling. No package is
  published externally.
- Reorganized public documentation around getting started, concepts, capture,
  output, duplex, SDKs, operations, security, and troubleshooting.

## 0.8.0 — Reliability and observability

- Moved the default socket below macOS's private per-user temporary directory,
  added same-UID validation, startup ownership locking, bounded handshake/send
  deadlines, and guarded stale-socket cleanup.
- Added comprehensive resource, control, capture, output, endpoint-monitor,
  memory, descriptor, and thread diagnostics plus privacy-safe support bundles.
- Hardened cancellation, late-start teardown, endpoint monitoring, reconnects,
  and legacy protocol-v2 endpoint compatibility.
- Added deterministic long-soak, fault, TSan, security, and lifecycle coverage.

## 0.7.0 — Agent I/O platform

- Added provider-neutral activity edges, optional speech-detector extension,
  resilient labeled multi-source sessions, and provider-neutral duplex defaults.
- Unified stream correlation and cancellation behavior across OpenAI Realtime
  and Gemini Live adapters; hardened multi-turn parsing and provider errors.
- Matured the control-only MCP surface and public-only agent/framework examples.

## 0.6.0 — Endpoint and routing maturity

- Made output destinations typed resources with stable identity, discovery,
  exact ambiguity-safe resolution, wait helpers, and lifecycle events.
- Hardened route/format changes and expanded capture/output conversion tests.
- Chose installed third-party loopback support over shipping a first-party HAL
  driver in the 1.0 line; Sonexis never silently selects an ambiguous device.

## 0.5.0 — Developer distribution

- Added synchronized Runtime/CLI/SDK versions and drift checks.
- Added signed universal local products, safe per-user development
  install/uninstall, explicit foreground/background lifecycle tooling, and a
  zero-to-audio quickstart.
- Added local Python wheel/sdist and TypeScript package consumer validation,
  focused public examples, and actionable common errors.

## 0.4.0 — Bidirectional audio

- Added a bounded client-to-Runtime PCM plane, Core Audio playback, jitter and
  backpressure policy, output destinations/sessions/events/diagnostics, and
  deterministic WAV/raw playback.
- Added Python and TypeScript output/duplex APIs with drain, flush, cancel, and
  barge-in primitives shared by Gemini and OpenAI response audio.
- Added routing to an already installed loopback device. Sonexis does not ship
  or install its own virtual microphone.

## 0.3.0 — Source-aware AI infrastructure

- Added ergonomic and ambiguity-safe source resolution, delayed-source wait,
  source-aware frames, labeled multi-source sessions, replay, activity/VAD
  extension points, and latency accounting.
- Added optional OpenAI Realtime and Gemini Live adapters, reference apps, and a
  control-only MCP server; Runtime core remained provider-neutral.
- Added Gemini hybrid local/server VAD turn finalization and output
  transcription. Authenticated Chrome-to-Gemini semantic input was manually
  validated with zero dropped input frames.

## 0.2.0 — Versioned developer Runtime

- Introduced protocol v2 handshake/capabilities, structured IDs and errors,
  typed source/session/event/diagnostic models, negotiated PCM16/Float32
  formats, and timestamped binary framing.
- Added bounded multi-client/multi-session behavior, observable backpressure,
  async Python and typed TypeScript clients, CLI diagnostics, and
  integration/stress/fuzz/security/benchmark coverage.

## 0.1.0 — Runtime prototype

- Extracted headless source discovery and reusable Process Tap capture from UI
  concerns while preserving the Sonexis application's DSP path.
- Added bundle-stable application sources, start/stop capture sessions,
  realtime-safe ring buffering, AVAudioConverter normalization to PCM16 mono
  16 kHz, local Unix-socket control/binary planes, and `sonexisctl`.
