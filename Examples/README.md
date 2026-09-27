# Sonexis Runtime examples

All examples import only the public `sonexis` package. Install the local SDK
before running them.

| Concept | Example |
| --- | --- |
| one source | `capture-one-source.py "Google Chrome"` |
| labeled independent sources | `capture-multiple-sources.py conversation=Discord media=Spotify` |
| Runtime-owned playback | `playback.py response.wav --destination default` |
| input/output ownership | `duplex.py Discord --destination default` |
| minimal provider response playback | `provider-output.py Discord` |
| agent policy over two labeled sources | `multi-source-agent.py Discord Spotify` |
| Gemini or OpenAI | `audio-agent/audio_agent.py --help` |
| MCP control | `python -m sonexis.mcp_server --help` |

The duplex example uses matching 16 kHz input/output and echoes captured audio
only to make data flow visible. Use headphones. Provider adapters declare their
own output format and should not blindly echo capture bytes.

Examples requiring live capture need macOS Screen & System Audio Recording
permission for the signed Runtime. Provider examples additionally need their
optional SDK dependency and an environment-provided API key. `--help`, import,
and mock-provider tests do not use credentials.
