# Sonexis Runtime roadmap after v0.3

Runtime v0.3 establishes Sonexis as a source-aware local audio input layer for
AI software. The next milestone should make that layer installable and
bidirectional without expanding into an AI product.

## Recommended v0.4: installed service and controlled audio output

1. Ship a signed/notarized per-user Runtime service with install, update,
   uninstall, restart, permission UX, and supportable logs.
2. Preserve HAL host timestamps through capture and validate live p50/p95/p99
   latency under one, two, and four Process Taps.
3. Add an explicit authorization/consent layer finer than the current same-UID
   trust boundary before broad agent-tool distribution.
4. Design bidirectional output as a separate capability, beginning with a
   reviewed virtual-microphone or application-output contract rather than
   coupling model playback to capture sessions.
5. Publish versioned Python wheels and npm packages only after CI covers the
   supported interpreter/compiler matrix and compatibility fixtures.

## Later cohesive milestones

- SoundMux remote sources behind an authenticated transport.
- Microphone and system-mix source kinds with explicit permission behavior.
- Windows and Linux capture backends.
- LiveKit, Pipecat, and richer agent-framework adapters above the SDK.
- Rust/C++ SDKs and production Node package distribution.
- Shared same-source taps only if measured live resource data justifies their
  added ownership complexity.

Do not combine these into a speculative platform rewrite. Preserve the local
protocol boundary, source/session identity, bounded queues, and provider-neutral
Runtime core.
