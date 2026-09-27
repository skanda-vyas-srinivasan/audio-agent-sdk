# Roadmap after Runtime v0.4

Runtime v0.4 establishes a provider-neutral bidirectional local audio plane:
application capture, generated-audio playback, virtual-loopback destinations,
bounded jitter/backpressure, SDK duplex composition, and barge-in primitives.

## Recommended v0.5: distributable service and branded virtual input

Treat the next milestone as a deployment and system-audio product milestone:

1. Build the reviewed `Sonexis Agent Input` AudioServerPlugIn described in
   `virtual-audio-device-design.md`, with a hidden injection output and visible
   input backed by a sample-time-indexed realtime ring.
2. Create explicit, idempotent signed install/uninstall packages, recovery
   tooling, reboot guidance, and production notarization.
3. Add per-client authorization/consent finer than the current same-UID trust
   boundary before broad agent distribution.
4. Preserve HAL input host timestamps and add output render host timestamps for
   honest live duplex latency correlation.
5. Package the Runtime as a supervised per-user service with restart/update and
   permission UX.

## Later milestones

- acoustic echo cancellation through a reviewed system/library integration;
- optional policy-level ducking without changing Runtime defaults;
- bidirectional SoundMux remote devices;
- microphone and system-mix capture source kinds;
- published Python wheels/npm packages and compatibility CI;
- Windows and Linux backends;
- LiveKit/Pipecat adapters and Rust/C++ SDKs.

Do not combine these into an AI assistant, cloud service, or model product.
Maintain independent capture/output primitives and keep providers above the
Runtime boundary.
