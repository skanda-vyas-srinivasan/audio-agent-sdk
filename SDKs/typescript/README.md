# Sonexis TypeScript SDK

This dependency-free runtime client targets Node.js 18+ and Sonexis Runtime protocol v2.

```sh
npm install
npm run build
```

```ts
import { Sonexis } from "@sonexis/runtime";

const sx = await Sonexis.connect();
try {
  const sources = await sx.sources();
  const stream = await sx.capture(sources[0]);
  for await (const frame of stream) {
    console.log(frame.timestampNs, frame.data.length);
  }
} finally {
  await sx.close();
}
```

Capture sessions are never silently recreated after reconnect. The current repository environment does not contain Node/npm/TypeScript, so v0.2 validates this package through shared protocol fixtures and source review; consumers should run `npm test` on a Node-equipped host.

Breaking from an async audio/event loop closes its Runtime resource. EventEmitter-only consumers are supported without filling the iterator queue; listen for `streamError` and call `close()` during application shutdown.

Binary audio sequence/timestamp fields are exposed as `bigint`. Protocol-v2 JSON nanosecond timestamps and lifetime counters are currently JSON numbers, so JavaScript cannot preserve integer precision above `2^53`; do not use those control-plane values for long-running sample-accurate arithmetic.
