# Sonexis TypeScript SDK

The dependency-free `@sonexis/runtime` client targets Node.js 18+ and Sonexis
Runtime protocol v2. Version 0.6 is locally packageable for external consumers
and includes typed, bounded client-to-Runtime audio output, source-aware capture,
AI format presets, and labeled multi-source APIs.

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

Available helpers are `speech16k()`, `openAIRealtime()`,
`openAIRealtimeOutput()`, `geminiLive()`, `geminiLiveOutput()`,
`pcm48kMono()`, and `pcm48kStereo()`. They return new mutable format values, so
changing one request cannot modify a later request.

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

## Realtime playback

The Runtime owns the selected macOS device. Node sends ordered PCM over the dedicated binary data
plane; audio never travels in control-plane JSON.

```ts
const destinations = await sx.outputDestinations();
console.log(destinations.map((destination) => destination.name));

const loopback = await sx.waitForOutputDestination(undefined, {
  kind: "virtual_input",
  timeoutMs: 30_000,
  signal: abortController.signal,
});

const output = await sx.playback({
  destination: loopback, // or "default", an exact ID, or exact name
  format: AudioFormats.openAIRealtimeOutput(),
  targetBufferMilliseconds: 60,
});

try {
  for await (const pcm of modelAudio) {
    await output.write(pcm); // Buffer or Uint8Array
  }
  await output.close();      // sends EOS and waits briefly for Runtime drain
} catch (error) {
  await output.cancel();     // barge-in: discard buffered playback, no EOS
  throw error;
}
```

`write()` validates complete interleaved sample frames, serializes concurrent callers, splits large
chunks into packets no longer than 200 ms, and awaits Node's Unix-socket `drain` signal. The SDK
does not add an unbounded queue. Optional `timestampNs`, `discontinuity`, and `signal` values can be
passed with each write:

```ts
await output.write(pcm, {
  timestampNs: 2_000_000_000n,
  discontinuity: true,
  signal: abortController.signal,
});
```

`await output.refresh()` returns current `OutputInfo` and `OutputMetrics`, including rendered,
dropped, late, underrun, overrun, queue-depth, buffered-duration, conversion, route-change, and
producer-connection state, and refreshes `output.destination` after route changes.
`findOutputDestinations()`, `getOutputDestination()`, and
`waitForOutputDestination()` share exact, ambiguity-safe resolution rules.
`await output.flush()` discards Runtime-buffered audio, reconnects to a
fresh stream epoch, and resets sequence/timestamp numbering. `cancel()` is the immediate barge-in
primitive. Closing the owning `Sonexis` client cancels every output it created before closing the
control connection.

`default` follows the current system default output device. Fixed HAL outputs use
stable `coreaudio:<UID>` IDs. Recognized installed loopback devices are exposed
as `virtual_input`; Sonexis 1.0 will not install a first-party HAL driver.
Output APIs fail with `unsupported_capability` against a pre-v0.4 Runtime.

For ownership convenience, `await sx.duplex(source, options)` creates one
capture and one output. It does not choose a model or turn policy:

```ts
const duplex = await sx.duplex("Discord", {
  inputFormat: AudioFormats.geminiLive(),
  output: { format: AudioFormats.geminiLiveOutput(), destination: "default" },
});
try {
  for await (const frame of duplex.input) {
    // Send input to a model and write returned PCM to duplex.output.
  }
} finally {
  await duplex.close(); // pass false to discard buffered output during barge-in
}
```

Input and output formats are independent. A passthrough/fake-model test must
set both to the same format before writing `frame.data` directly; model response
PCM must match `output.format`.

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
npm run build
npm test
```

For an external local project, build first and install the repository package
without publishing it, for example `npm install /absolute/path/to/SDKs/typescript`.

Binary audio sequence/timestamp fields and local frame receipt timestamps are `bigint`.
Protocol-v2 JSON nanosecond timestamps and lifetime counters remain JSON numbers, so JavaScript
cannot preserve integer precision above `2^53`; do not use those control-plane values for
long-running sample-accurate arithmetic.
