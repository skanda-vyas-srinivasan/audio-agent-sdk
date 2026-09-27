#!/usr/bin/env python3
"""Capture independent labeled application streams without mixing identity."""

import argparse
import asyncio

from sonexis import Sonexis, SonexisError


async def run(specifications, maximum_packets: int) -> None:
    async with Sonexis() as client:
        async with client.session() as session:
            for specification in specifications:
                label, separator, selector = specification.partition("=")
                if not separator or not label or not selector:
                    raise ValueError("each source must be LABEL=SOURCE")
                await session.add(label, selector)
            packets = 0
            async for item in session.frames():
                print(item.label, item.source.name, item.timestamp_ns,
                      item.frame.frame_count)
                packets += 1
                if maximum_packets and packets >= maximum_packets:
                    break


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sources", nargs="+", metavar="LABEL=SOURCE")
    parser.add_argument("--packets", type=int, default=0,
                        help="stop after this many packets (zero runs until interrupted)")
    arguments = parser.parse_args()
    try:
        asyncio.run(run(arguments.sources, arguments.packets))
    except KeyboardInterrupt:
        return
    except (OSError, SonexisError, ValueError) as error:
        parser.exit(1, f"capture failed: {error}\n")


if __name__ == "__main__":
    main()
