# Sonexis Runtime examples

All examples import only a public Sonexis SDK. Install the local Python or
TypeScript package before running the matching example.

| Concept | Example |
| --- | --- |
| one source | `python Examples/capture-one-source.py "Google Chrome"` |
| labeled independent sources | `python Examples/capture-multiple-sources.py conversation=Discord media=Spotify` |
| Runtime-owned playback | `python Examples/playback.py /path/to/response.wav --destination default` |
| input/output ownership | `python Examples/duplex.py Discord --destination default` |
| minimal provider response playback | `python Examples/provider-output.py Discord` |
| agent policy over two labeled sources | `python Examples/multi-source-agent.py Discord Spotify` |
| Gemini or OpenAI | `python Examples/audio-agent/audio_agent.py --help` |
| MCP control | `python -m sonexis.mcp_server --help` |
| TypeScript capture -> fake model -> output | `Examples/typescript-duplex.mts "Google Chrome"` |

The duplex example uses matching 16 kHz input/output and echoes captured audio
only to make data flow visible. Use headphones. Provider adapters declare their
own output format and should not blindly echo capture bytes.

The TypeScript example is a standalone ESM package consumer. In a Node 18+
project, install the packed SDK plus `typescript` and `@types/node`, then compile
the `.mts` file with `tsc --module NodeNext --moduleResolution NodeNext --target
ES2022`. Its identity fake model returns input bytes only to demonstrate the
public duplex contract.

```sh
npm init -y
npm install /absolute/path/to/sonexis-runtime-1.0.0.tgz
npm install --save-dev typescript @types/node
cp /absolute/path/to/Sonexis/Examples/typescript-duplex.mts .
npx tsc --module NodeNext --moduleResolution NodeNext --target ES2022 typescript-duplex.mts
node typescript-duplex.mjs "Google Chrome"
```

Examples requiring live capture need macOS Screen & System Audio Recording
permission for the signed Runtime. Provider examples additionally need their
optional SDK dependency and an environment-provided API key. `--help`, import,
and mock-provider tests do not use credentials.
