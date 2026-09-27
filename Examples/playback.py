#!/usr/bin/env python3
"""Play a PCM16 WAV through a Runtime-owned output destination."""

import argparse
import asyncio
import wave

from sonexis import AudioFormat, SampleFormat, Sonexis


async def run(path: str, destination: str) -> None:
    with wave.open(path, "rb") as recording:
        if recording.getcomptype() != "NONE" or recording.getsampwidth() != 2:
            raise ValueError("example supports only uncompressed PCM16 WAV")
        audio_format = AudioFormat(recording.getframerate(), recording.getnchannels(),
                                   SampleFormat.PCM_S16LE)
        frames_per_chunk = max(1, recording.getframerate() // 50)
        async with Sonexis() as client:
            async with await client.playback(destination=destination,
                                              format=audio_format) as output:
                while data := recording.readframes(frames_per_chunk):
                    await output.write(data)
                print(await output.refresh())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wav")
    parser.add_argument("--destination", default="default",
                        help="destination ID from sonexisctl outputs")
    arguments = parser.parse_args()
    asyncio.run(run(arguments.wav, arguments.destination))


if __name__ == "__main__":
    main()
