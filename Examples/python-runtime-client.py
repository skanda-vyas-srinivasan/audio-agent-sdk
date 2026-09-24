#!/usr/bin/env python3
"""Small compatibility example built entirely on the public Sonexis SDK."""

import asyncio
import sys
from pathlib import Path

try:
    from sonexis import Sonexis
except ImportError:
    sys.path.insert(0, str(Path(__file__).parents[1] / "SDKs/python/src"))
    from sonexis import Sonexis


async def main():
    requested = sys.argv[1] if len(sys.argv) > 1 else None
    async with Sonexis(client_name="sonexis-example") as client:
        sources = await client.sources()
        for source in sources:
            print(f"{source.id}\t{source.name}")
        source = next((item for item in sources if item.id == requested), None) if requested else (
            sources[0] if sources else None)
        if source is None:
            raise SystemExit("requested source is unavailable" if requested else "no sources available")
        async with await client.capture(source) as stream:
            count = 0
            async for frame in stream:
                print(f"sequence={frame.sequence} timestamp_ns={frame.timestamp_ns} "
                      f"frames={frame.frame_count} bytes={len(frame.data)}")
                count += 1
                if count == 50:
                    break


if __name__ == "__main__":
    asyncio.run(main())
