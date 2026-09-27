#!/usr/bin/env python3
"""Capture one unambiguous application through the public Sonexis SDK."""

import argparse
import asyncio

from sonexis import Sonexis


async def run(source: str, maximum_frames: int) -> None:
    received = 0
    async with Sonexis() as client:
        async with await client.capture(source) as stream:
            print(f"capturing {stream.source.name} ({stream.source.id})")
            async for frame in stream:
                received += frame.frame_count
                print(frame.timestamp_ns, frame.sequence, frame.frame_count)
                if maximum_frames and received >= maximum_frames:
                    break


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", help="Runtime source ID, bundle ID, PID, or exact app name")
    parser.add_argument("--frames", type=int, default=0,
                        help="stop after this many PCM frames (zero runs until interrupted)")
    arguments = parser.parse_args()
    asyncio.run(run(arguments.source, arguments.frames))


if __name__ == "__main__":
    main()
