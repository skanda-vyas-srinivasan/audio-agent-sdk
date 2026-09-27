#!/usr/bin/env python3
"""Minimal public-API bridge: one app -> OpenAI -> Sonexis playback."""

import argparse
import asyncio

from sonexis import Sonexis
from sonexis.providers import OpenAIRealtimeSink


async def play_responses(sx: Sonexis, model: OpenAIRealtimeSink,
                         destination: str) -> None:
    output = None
    try:
        async for event in model.events():
            if event.text:
                print(event.text, flush=True)
            if event.audio:
                if event.audio_format is None:
                    raise RuntimeError("provider audio did not declare its format")
                if output is None:
                    output = await sx.playback(
                        destination=destination, format=event.audio_format)
                await output.write(event.audio)
    finally:
        if output is not None:
            await output.aclose(drain=True)


async def main(source: str, destination: str) -> None:
    async with Sonexis(client_name="sonexis-provider-output-example") as sx:
        model = await OpenAIRealtimeSink.connect()
        responses = asyncio.create_task(play_responses(sx, model, destination))
        sending = None
        try:
            async def send_input() -> None:
                async with await sx.capture(source, format=model.required_format) as stream:
                    async for frame in stream:
                        await model.send_audio(frame)

            sending = asyncio.create_task(send_input())
            finished, _ = await asyncio.wait(
                {sending, responses}, return_when=asyncio.FIRST_COMPLETED)
            for task in finished:
                await task  # propagate provider, playback, capture, or send failure
        finally:
            if sending is not None and not sending.done():
                sending.cancel()
                await asyncio.gather(sending, return_exceptions=True)
            # Closing provider input precedes a bounded wait for trailing events.
            await model.aclose()
            try:
                await asyncio.wait_for(asyncio.shield(responses), timeout=1.0)
            except asyncio.TimeoutError:
                responses.cancel()
                await asyncio.gather(responses, return_exceptions=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source")
    parser.add_argument("--destination", default="default")
    options = parser.parse_args()
    asyncio.run(main(options.source, options.destination))
