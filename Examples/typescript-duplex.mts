/** Public-package capture -> fake model -> Runtime output example. */
import { Sonexis, type AudioFrame } from "@sonexis/runtime";

async function fakeModel(frame: AudioFrame): Promise<Uint8Array> {
  // Replace this identity transform with a model producing the same PCM format.
  return frame.data;
}

const source = process.argv[2];
const destination = process.argv[3] ?? "default";
if (!source) {
  console.error("usage: typescript-duplex SOURCE [DESTINATION]");
  process.exitCode = 2;
} else {
  console.warn("Use headphones: this example has no acoustic echo cancellation.");
  const sx = await Sonexis.connect();
  try {
    const io = await sx.duplex(source, { output: { destination } });
    try {
      for await (const frame of io.input) {
        await io.output.write(await fakeModel(frame));
      }
    } finally {
      await io.close();
    }
  } finally {
    await sx.close();
  }
}
