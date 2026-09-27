# Sonexis Runtime Post-1.0 Roadmap

Runtime 1.0 deliberately freezes a coherent local macOS core. Work after 1.0
should be driven by validated developer demand and must preserve protocol-v2
compatibility unless a migration is genuinely unavoidable.

## Distribution

- Developer ID signing, Hardened Runtime policy, notarization, and an accepted
  explicit service installer/uninstaller;
- published Python and npm packages with provenance, external trust anchors,
  reproducible-build evidence, and upgrade/rollback guidance;
- permission onboarding that explains the Runtime's separate capture identity
  without hiding macOS consent.

## Authorization

- optional per-client/session grants beyond the current same-UID account trust
  boundary;
- attach capabilities for sensitive capture/output streams;
- explicit policy around MCP capture mutation and audio injection;
- privacy-preserving audit records that never contain PCM or transcripts by
  default.

## Audio endpoints

- richer microphone and system-mix source types behind the existing source
  model;
- evaluated first-party virtual-input device only if maintenance, signing,
  installer, and system-audio crash risks justify replacing excellent
  third-party loopback support;
- remote SoundMux sources/sinks as a distinct authenticated transport;
- optional platform-provided echo-control integration, never a homemade claim
  of full acoustic echo cancellation.

## Ecosystem

- package publication and generated API references;
- focused LiveKit or Pipecat adapters above the provider-neutral SDK;
- Rust/C++ SDKs where protocol consumers need them;
- broader MCP-host validation while keeping realtime PCM off MCP;
- Windows and Linux backends that preserve semantic source/session/output
  concepts without pretending their capture APIs match Core Audio.

## Operations and protocol

- migrate the transitional `/tmp` compatibility endpoint after the documented
  deprecation window;
- consider a nonblocking control connection state machine if profiling shows
  bounded worker threads are an operational constraint;
- protocol v3 only for changes impossible to express through additive v2
  capabilities, with dual-version migration and recorded fixtures;
- longer signed-device soak and fleet-style observability after a distributable
  service exists.

Cloud relay, accounts, billing, web dashboards, custom speech/LLM models, and a
consumer assistant are not automatic Runtime roadmap items. Sonexis remains the
local programmable audio I/O layer.
