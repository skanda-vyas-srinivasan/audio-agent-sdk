# Sonexis TypeScript SDK

This dependency-free runtime client targets Node.js 18+ and Sonexis Runtime protocol v2.

```sh
npm install
npm run build
```

```ts
import { Sonexis } from "@sonexis/runtime";

await using sx = await Sonexis.connect();
const sources = await sx.sources();
const stream = await sx.capture(sources[0]);
for await (const frame of stream) {
  console.log(frame.timestampNs, frame.data.length);
}
```

Capture sessions are never silently recreated after reconnect. The current repository environment does not contain Node/npm/TypeScript, so v0.2 validates this package through shared protocol fixtures and source review; consumers should run `npm test` on a Node-equipped host.
