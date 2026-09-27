# Runtime Public API and Stability

This inventory defines the Sonexis Runtime v0.9 API-freeze candidate. Anything
not listed here is internal even when its source declaration is visible in this
monorepo. “Stable candidate” means intended for the 1.0 compatibility promise;
v0.9 itself remains a public beta.

## Protocol v2

| Surface | Classification | Notes |
|---|---|---|
| NDJSON envelope, request/response IDs, `hello`, `ping` | Stable candidate | Unknown commands and unsupported versions return structured errors. |
| `list_sources`, `start_capture`, `stop_capture`, `session_status` | Stable candidate | Capture identity is source/session/stream ID, never Core Audio object ID. |
| `runtime_status` | Stable candidate | New fields remain additive and capability-gated. Exact UInt64 mirrors are decimal strings. |
| `subscribe_events`, `unsubscribe_events` | Stable candidate | Events are ordered per subscription; loss is explicit, global cross-stream ordering is not promised. |
| `list_output_destinations`, `start_output`, `output_status`, `flush_output`, `stop_output` | Stable candidate | Flush rotates stream epoch; stop is terminal. |
| SXPC v2 input/output binary frame header | Stable candidate | Magic/version/header size, byte order, IDs, sequence, timestamps, format, drop/discontinuity/EOS semantics are frozen candidates. |
| Capability strings and resource limits | Stable candidate | Clients must ignore unknown capabilities and fields. |
| Error envelope (`code`, `message`, `retryable`, `details`) | Stable candidate | Codes may be added; existing meanings will not be silently repurposed. Human messages are not machine contracts. |
| Unix-socket filenames and compatibility alias | Compatibility bridge | Discover through SDK/default configuration; do not parse private data-socket names. The `/tmp` alias is transitional. |
| Core Audio IDs, Process Tap objects, aggregate devices, IOProc details | Internal | Never public protocol. |

Stable event names are the source, capture, output, device, client-warning, and
Runtime lifecycle names documented in `sonexis-runtime.md`. Events may gain
optional metadata. Signal-level activity remains an SDK primitive rather than a
guaranteed Runtime event.

## Python

The names in `sonexis.__all__` are the public package surface. The 1.0 stable
candidate core is:

- `Sonexis` / compatibility alias `SonexisClient`;
- `AudioSource`, `CaptureSession`, `AudioFrame`, `CaptureInfo`, `SessionMetrics`;
- `AudioOutputDestination`, `AudioOutput`, `OutputInfo`, `OutputMetrics`;
- `EventSubscription`, `RuntimeEvent`, `RuntimeStatus`, `Handshake`;
- `AudioFormat`, `SampleFormat`, source/output selector aliases;
- `DuplexSession`, `MultiSourceSession`, `LabeledAudioFrame`;
- typed `SonexisError` subclasses, including ambiguity, availability,
  permission, limits, slow-consumer, protocol, connection, capture, and output;
- activity/VAD primitives, latency tracker/receipts, and deterministic replay.

Provider adapters under `sonexis.providers` and the control-only MCP server are
**experimental integrations**. Their dependency SDKs and upstream wire behavior
can change independently. They use stable Sonexis streams but are not required
to capture, play, or build duplex applications.

Underscore-prefixed attributes/modules and raw protocol helpers are internal.
Applications must not depend on a data socket path, pending-request map, queue
implementation, or provider client's private object.

## TypeScript

Exported capture/output/source/event/status/format/error types, `Sonexis`,
`CaptureStream`, `AudioOutput`, `DuplexSession`, `MultiSourceSession`, activity
primitives, selector helpers, `AudioFormats`, and async iteration/EventEmitter
behavior are stable candidates. Low-level `encodeOutputFrame`, `decodeFrame`,
and `decodeEvent` are **advanced stable candidates** for transport testing and
custom SDK work; callers remain responsible for stream correlation and limits.

No package-private method, pending map, socket object, queue, or wire-only helper
is public even if present in generated JavaScript. Node 18+ is the candidate
minimum.

## CLI

Stable-candidate commands are `sources`, `status`, `diagnostics`, `capture`,
`stop`, `watch`, `outputs`, `play`, `output-status`, `output-stop`, `version`,
and `help`. `--json` is the machine-readable surface; human table/text layout is
not frozen. Exit zero means success. Failures are nonzero, and JSON mode emits a
structured error envelope. `SONEXIS_RUNTIME_SOCKET` is the stable explicit
endpoint override; `SONEXIS_RUNTIME_DIR` is the server directory override.

Development lifecycle scripts and their `SONEXIS_DEV_PREFIX`,
`SONEXIS_RUNTIME_STATE_DIR`, and signing-team variables are supported developer
tooling, not Runtime protocol APIs.

## MCP

The control-only tools `sonexis_runtime_info`, `sonexis_list_sources`,
`sonexis_get_source`, `sonexis_get_diagnostics`, and
`sonexis_list_output_destinations` are experimental. Opt-in mutation additionally
exposes session listing/query/start/stop. MCP never carries PCM and is not a
replacement for a Python/TypeScript data-plane client.

## Compatibility aliases and deprecation candidates

- `SonexisClient` remains a source-compatible Python alias for `Sonexis`.
- `total_output_frames_dropped` remains the legacy lost-plus-flushed total;
  use the two explicit counters in new code.
- `/tmp/sonexis-runtime-$UID/control.sock` is a migration alias, not the future
  canonical default.

Removal of a compatibility bridge requires a documented deprecation spanning at
least one minor release after 1.0. No bridge is removed in v0.9.
