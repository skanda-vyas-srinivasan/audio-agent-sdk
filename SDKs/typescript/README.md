# Sonexis TypeScript SDK

The dependency-free `@sonexis/runtime` client targets Node.js 18+ and Sonexis Runtime protocol
v2. Version 0.3 adds ergonomic source resolution, source-aware audio frames, AI format presets,
and bounded labeled multi-source capture without changing the wire protocol.

```sh
npm install
npm run build
```

```ts
import { Sonexis } from "@sonexis/runtime";

const sx = await Sonexis.connect();
try {
  // Accepts a Runtime source ID, bundle ID, PID, exact name, or AudioSource.
  const discord = await sx.capture("Discord");
  for await (const frame of discord) {
    console.log(frame.sourceName, frame.sessionId, frame.timestampNs, frame.data.length);
  }
} finally {
  await sx.close();
}
```

## Source selection

`getSource()` resolves only unambiguous exact selectors. It tries source ID, bundle identifier,
exact application name, and then an exact case-insensitive application name. A numeric selector is
a PID. It raises `SourceNotFoundError` or `AmbiguousSourceError`; it never guesses between two
matching processes.

```ts
const matches = await sx.findSources("chrome"); // discovery uses substring matching
const spotify = await sx.getSource("com.spotify.client");
const later = await sx.waitForSource("Discord", {
  timeoutMs: 30_000,
  signal: abortController.signal,
});
```

`waitForSource()` fetches fresh source snapshots and is intended for applications that may launch
after the AI consumer. A structured ambiguity error is returned immediately; only a missing source
is retried.

## Formats and source-aware frames

```ts
import { AudioFormats } from "@sonexis/runtime";

const stream = await sx.capture("Spotify", AudioFormats.openAIRealtime());
for await (const frame of stream) {
  // Identity is SDK context, not repeated in every binary packet.
  console.log(frame.source.id, frame.source.bundle_identifier);
  console.log(frame.sessionId, frame.streamId, frame.sequence);
  console.log(frame.format, frame.discontinuity, frame.droppedFramesBefore);
}
```

Available helpers are `speech16k()`, `openAIRealtime()`, `geminiLive()`, `pcm48kMono()`, and
`pcm48kStereo()`. They return new mutable format values, so changing one request cannot modify a
later request.

## Labeled multi-source capture

`MultiSourceSession` owns independent Runtime captures. It does not mix them: every frame keeps its
source, stream, session, timestamp, and caller-assigned label. Every label has a fairly drained
queue bounded to `maxQueueFrames` packets. A full label queue drops new frames;
`droppedFrames` and `droppedFramesByLabel` report lost PCM sample frames, and the next retained
labeled frame reports a local discontinuity.

```ts
const group = sx.session({ maxQueueFrames: 128 });
try {
  await group.add("conversation", "Discord");
  await group.add("media", "Spotify", AudioFormats.pcm48kStereo());

  for await (const item of group.frames()) {
    console.log(item.label, item.source.name, item.timestampNs);
  }
} finally {
  await group.close();
}
```

Timestamps remain independent Runtime stream clocks. The helper provides arrival-order
multiplexing, not sample-accurate synchronization across applications.

## Lifecycle

Capture sessions are never silently recreated after a disconnect. Breaking from an async
audio/event loop closes its Runtime resource. EventEmitter-only consumers are supported without
filling the iterator queue; listen for `streamError` and call `close()` during application
shutdown.

The package was compiled and its tests executed with a checksum-verified temporary Node 22.23.0
toolchain; nothing was installed system-wide. Re-run with any supported Node toolchain:

```sh
cd SDKs/typescript
npm install
npm test
```

Binary audio sequence/timestamp fields and local frame receipt timestamps are `bigint`.
Protocol-v2 JSON nanosecond timestamps and lifetime counters remain JSON numbers, so JavaScript
cannot preserve integer precision above `2^53`; do not use those control-plane values for
long-running sample-accurate arithmetic.
