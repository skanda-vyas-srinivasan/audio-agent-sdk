# Sonexis Runtime roadmap after v0.2

Runtime v0.2 establishes a versioned local protocol, negotiated audio streams, events, diagnostics, bounded lifecycle behavior, and repository-local Python and TypeScript clients. The next milestone should focus on deployability and measured live behavior rather than adding unrelated platform surface.

## Recommended next milestone: signed local service and SDK distribution

1. Give the Runtime a stable signed/notarized identity and explicit Screen & System Audio Recording permission UX.
2. Add a supported per-user service installation/update/uninstall flow with crash restart and log collection.
3. Preserve HAL host timestamps through the capture ring and publish measured live p50/p95/p99 application-to-client latency.
4. Exercise one, two, and four live application captures, target restart, sleep/wake, and device changes on representative hardware.
5. Publish versioned Python wheels and npm packages only after compatibility fixtures run in CI on supported Python/Node versions.
6. Decide whether same-source consumers should share a Process Tap based on live resource measurements, not assumption.
7. Replace blocking control workers with a nonblocking connection state machine and add authenticated attach prefaces if the same-UID trust model becomes insufficient.

## Later cohesive milestones

- Richer local sources: microphones and system mix, with explicit permission and privacy behavior.
- Virtual microphone output as a separately reviewed audio-routing product feature.
- SoundMux remote sources using the same source/session abstractions but a distinct authenticated transport.
- MCP as an optional control-plane adapter; audio must remain on the binary data plane.
- Windows and Linux capture backends behind the existing source/session contract.
- Richer permission-state events when macOS provides a reliable observation path.
- Optional provider adapters, including realtime AI APIs, maintained entirely above the SDK boundary.

Do not combine these into one speculative rewrite. Each should preserve the local Runtime protocol boundary, realtime invariants, and source/session identity model.
