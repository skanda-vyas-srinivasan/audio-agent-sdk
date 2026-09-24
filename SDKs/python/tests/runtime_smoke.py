"""Cross-language smoke test invoked by the Swift Runtime integration harness."""

import asyncio
import sys

from sonexis import AudioFormat, Sonexis


async def main(socket_path):
    async with Sonexis(socket_path, client_name="python-integration") as client:
        sources = await client.sources()
        assert sources and sources[0].id == "app.test.audio"
        async with await client.capture(sources[0], format=AudioFormat(24_000, 1)) as stream:
            frames = []
            async for frame in stream:
                frames.append(frame)
                if len(frames) == 3:
                    break
        assert all(frame.format.sample_rate == 24_000 for frame in frames)
        status = await client.status()
        assert status.total_sessions_started > 0
    print("Python SDK real-Runtime smoke passed")


asyncio.run(main(sys.argv[1]))
