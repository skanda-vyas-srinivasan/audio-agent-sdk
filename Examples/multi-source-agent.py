#!/usr/bin/env python3
"""Show an agent policy that processes conversation but observes media."""

import argparse
import asyncio
import signal

from sonexis import AudioFrame, AudioFormat, Sonexis


class ConversationConsumer:
    """Replace this public boundary with a provider adapter or custom model."""

    frames = 0

    async def send_audio(self, frame: AudioFrame) -> None:
        self.frames += frame.frame_count


async def main(conversation: str, media: str, duration: float) -> None:
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    loop.call_later(duration, stop.set)
    consumer = ConversationConsumer()

    async with Sonexis(client_name="sonexis-multi-agent-example") as sx:
        async with sx.session(fail_fast=False) as inputs:
            await inputs.add("conversation", conversation,
                             format=AudioFormat.speech_16k())
            await inputs.add("media", media, format=AudioFormat.speech_16k())
            async for item in inputs.frames():
                if stop.is_set():
                    break
                if item.label == "conversation":
                    await consumer.send_audio(item.frame)
                elif item.frame.sequence % 100 == 0:
                    print(f"media observed: {item.source.name} seq={item.frame.sequence}")

            for label, error in inputs.errors_by_label.items():
                print(f"{label} ended independently: {error}")
    print(f"conversation frames forwarded by policy: {consumer.frames}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("conversation")
    parser.add_argument("media")
    parser.add_argument("--duration", type=float, default=30)
    args = parser.parse_args()
    asyncio.run(main(args.conversation, args.media, args.duration))
