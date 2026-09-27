#!/usr/bin/env python3
"""List sources and capture a short stream through the public Sonexis SDK."""

import argparse
import asyncio

from sonexis import Sonexis


async def run(requested, packet_limit):
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
                if count == packet_limit:
                    break


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", help="source ID; defaults to the first source")
    parser.add_argument("--packets", type=int, default=50)
    arguments = parser.parse_args()
    asyncio.run(run(arguments.source, arguments.packets))


if __name__ == "__main__":
    main()
