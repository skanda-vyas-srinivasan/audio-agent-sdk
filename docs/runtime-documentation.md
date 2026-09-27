# Sonexis Runtime Documentation

Sonexis Runtime is programmable application-level audio I/O for macOS. Start
here instead of reading Runtime implementation files.

## Getting started

- [Runtime guide and zero-to-audio quickstart](sonexis-runtime.md)
- [Focused public examples](../Examples/README.md)
- [Python SDK](../SDKs/python/README.md)
- [TypeScript SDK](../SDKs/typescript/README.md)

## Concepts and architecture

- [Protocol, capture/output lifecycle, framing, backpressure, and security](sonexis-runtime.md)
- [Public API stability inventory](runtime-api-stability.md)
- [Compatibility and support policy](runtime-compatibility.md)
- [Measured performance](runtime-benchmarks.md)

## Capture, output, and duplex

- Capture/source/session/frame concepts: [Runtime guide](sonexis-runtime.md)
- Playback, jitter, destinations, loopback, and barge-in: [Output audio](output-audio.md)
- Multi-source and AI duplex use: [AI integration](ai-integration.md)

## Integrations and control

- [Provider-neutral AI integration, OpenAI, Gemini, MCP](ai-integration.md)
- CLI command reference: [Runtime guide](sonexis-runtime.md#cli-and-diagnostics)
- External agent framework boundary: [Agent framework integration](agent-framework-integration.md)

## Operations

- Diagnostics, trust model, and troubleshooting: [Runtime guide](sonexis-runtime.md)
- Current human/device/provider checks: [1.0 manual validation](runtime-v1.0-manual-validation.md)
- v0.6 routing validation: [manual guide](runtime-v0.6-manual-validation.md)
- Bidirectional live validation: [v0.4 manual guide](runtime-v0.4-manual-validation.md)
- Virtual device decision: [design record](virtual-audio-device-design.md)

## Release records

Plans and reports record what was actually built and tested; they are not API
specifications. Use `RUNTIME_V1_0_REPORT.md` for current automated evidence,
the [post-1.0 roadmap](runtime-post-1.0-roadmap.md) for deferred work, and
`CHANGELOG.md` for the concise evolution history.
