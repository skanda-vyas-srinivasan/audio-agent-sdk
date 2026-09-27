#!/usr/bin/env python3
"""Public-API duplex example with a deliberately simple passthrough model."""

import argparse
import asyncio

from sonexis import AudioFormat, Sonexis


async def run(source: str, destination: str, maximum_packets: int) -> None:
    audio_format = AudioFormat.speech_16k()
    async with Sonexis() as client:
        async with client.duplex(
            source,
            output_destination=destination,
            input_format=audio_format,
            output_format=audio_format,
        ) as duplex:
            packets = 0
            async for frame in duplex.input:
                # Replace this passthrough with a model that returns audio_format.
                await duplex.output.write(frame.data)
                packets += 1
                if maximum_packets and packets >= maximum_packets:
                    break


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source")
    parser.add_argument("--destination", default="default")
    parser.add_argument("--packets", type=int, default=100)
    arguments = parser.parse_args()
    print("Use headphones: this example does not provide acoustic echo cancellation.")
    asyncio.run(run(arguments.source, arguments.destination, arguments.packets))


if __name__ == "__main__":
    main()
