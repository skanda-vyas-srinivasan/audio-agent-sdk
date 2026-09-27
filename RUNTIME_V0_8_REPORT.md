# Sonexis Runtime v0.8 Report

## Executive summary

Runtime v0.8 is the reliability and observability checkpoint. It preserves the
v0.1-v0.7 capture, playback, duplex, provider-adapter, SDK, CLI, and MCP
surfaces while making long-running resource use and failure behavior visible.
The wire protocol remains version 2 and all additions are capability-gated.

Implementation checkpoints:

- `6b6e9e9` — v0.8 plan
- `3113444` — reliability diagnostics and soak infrastructure
- `5ef9c0a` — independent-review hardening
- `37cd98a` — cross-Python cancellation-fixture correction

## Reliability changes

- One owner lock serializes each Runtime socket directory.
- The default endpoint is in macOS's private per-user temporary directory.
  A same-UID, mode-0700 legacy compatibility listener keeps v0.7 protocol-v2
  clients working; a live legacy Runtime prevents a second default Runtime.
- Hello uses an absolute five-second deadline. Control responses have bounded
  sends, preventing slowloris and non-reading peers from retaining all slots.
- Capture/output late starts and blocking backend stops never execute on a
  coordinator state queue.
- Monitor installation is generation-checked across concurrent shutdown.
- Mutating SDK request cancellation closes the owner connection and reconciles
  possibly-created resources. Python flush cancellation no longer deadlocks;
  TypeScript close invalidates in-flight connection attempts.
- Stale session sockets are reaped only with the owner lock held and only when
  their strict filename, type, ownership, and connection failure prove stale.

## Diagnostics and observability

Handshake capability `runtime_diagnostics_v2` advertises the additive status
schema. Runtime status now includes:

- control accepted/disconnected/rejected/request/error/malformed/timeout totals;
- capture ring, delivery, queue, and no-subscriber drops;
- output lost versus intentionally flushed frames, late frames, underruns,
  overruns, route changes, conversion work, producers, and retained records;
- endpoint monitor failures, consecutive failures, recoveries, and last success;
- current/peak RSS, open descriptors, threads, active/reserved resources;
- decimal-string mirrors for every UInt64 counter.

`sonexisctl diagnostics --json` and `--output FILE` produce a versioned,
private support snapshot. It contains no PCM, transcript/provider text,
credentials, source metadata, or data-plane socket capabilities. File output
is a same-user `0600` regular file and refuses symbolic links. Generation time
uses RFC 3339 plus JSON-safe epoch milliseconds.

Verbose Process Tap lifecycle logging is opt-in with
`SONEXIS_AUDIO_DEBUG=1`; realtime callbacks still do not log.

## Stress and performance

The deterministic extended soak completed:

- 10,000 capture start/stop cycles;
- 10,000 output start/stop cycles;
- 2,000 PCM burst sessions;
- 2,000 control connect/disconnect cycles;
- 16 parallel sessions;
- 13.020 seconds elapsed;
- file-descriptor growth: 2;
- retained RSS growth: 5,799,936 bytes.

The standard 1,000/1,000/100/200-cycle stress gate also passes. Bounded queues,
slow-consumer disconnects, session ownership cleanup, and retained-record caps
remain enforced. Detailed codec, normalization, output-conversion, and v0.3 AI
pipeline measurements are in `docs/runtime-benchmarks.md`.

## Independent review

### Diagnostics/accounting

The reviewer found unsafe JSON precision, incomplete exact mirrors, forced
disconnect accounting, initial-monitor recovery loss, warning spam, stale docs,
and a default-socket migration break. Fixes include exhaustive decimal mirrors,
safe bundle time, edge-based monitor outage state, restart invariants, updated
docs, and the guarded legacy listener.

### Realtime/concurrency

The reviewer found a Python flush-cancellation deadlock, TypeScript
connect/close race, monitor-install race, blocked control writes, late-start
teardown on serial queues, and final-metric loss. All were fixed with focused
regressions. Capture remains a lock-free ring write on the Core Audio callback;
playback remains in the C ring-buffer IOProc without Swift allocation, locks,
logging, or socket I/O.

### Adversarial

The reviewer reproduced a 32-client partial-hello slowloris, the v0.7 default
socket discovery failure, and backend stop/accounting edge cases. Absolute
deadlines, bounded sends, compatibility discovery, and combined slow-start /
slow-stop tests close those gaps. Protocol fuzz and integration corpora passed.

## Automated validation

Passed during the v0.8 gate:

- complete Sonexis offline regression suite;
- Runtime protocol, core, output-core, integration, fuzz, and stress suites;
- Python SDK: 83 tests on both the development interpreter and the repository's
  Xcode Python path;
- TypeScript SDK: compile plus 24 tests;
- Runtime output/ring Thread Sanitizer stress;
- existing Sonexis application Thread Sanitizer checks;
- Python wheel/sdist and TypeScript package construction;
- signed universal Release Runtime/CLI verification and development
  install/restart/uninstall flow.

No authenticated provider call or audible live capture/playback was repeated
for v0.8 because the milestone did not change those data paths. Historical live
Gemini capture validation remains recorded in the v0.3 report; v0.4 retains its
manual output guide.

## Security and privacy

Only same-UID Unix peers are accepted; SDKs authenticate or validate the local
peer and socket directory. No TCP listener exists. Limits cover control clients,
messages, sessions, subscriptions, stream consumers, queues, and PCM packets.
Diagnostic output is metadata-only and private. Sonexis still trusts the local
macOS account: another unsandboxed process under the same UID can use Runtime's
capture permission and inject output. This boundary is explicit and unchanged.

## Known limitations

- The legacy discovery alias is transitional and exists only for the default
  socket directory. Custom deployments must configure clients explicitly.
- A bounded control send can disconnect a very slow local management client;
  clients should continue reading responses.
- Process RSS/thread/descriptor values are point-in-time process measurements,
  not an allocation profiler.
- Python preserves zero defaults for additive pre-v0.8 status fields for source
  compatibility; callers must gate v0.8 semantics on
  `runtime_diagnostics_v2`.
- Physical audio, TCC, Bluetooth/device churn, and authenticated provider calls
  remain manual validations.

## Next milestone

v0.9 should inventory and classify every public protocol/SDK/CLI/MCP surface,
align cross-language names, write the compatibility policy, organize product
documentation, and create reproducible signed/package artifacts as the API
freeze candidate. It should avoid new audio features.

