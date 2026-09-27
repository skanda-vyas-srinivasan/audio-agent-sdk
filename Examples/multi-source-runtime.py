#!/usr/bin/env python3
"""Demonstrate two independent, labeled Sonexis application audio streams."""

import argparse
import asyncio
import signal
import sys
import time
from dataclasses import dataclass
from typing import Dict, Optional

from sonexis import AudioFormat, LabeledAudioFrame, Sonexis, SonexisError


@dataclass
class SourceStats:
    name: str
    source_id: str
    session_id: str
    stream_id: str
    packets: int = 0
    frames: int = 0
    bytes: int = 0
    dropped: int = 0
    first_timestamp_ns: Optional[int] = None
    latest_timestamp_ns: Optional[int] = None

    def observe(self, item: LabeledAudioFrame) -> None:
        frame = item.frame
        self.packets += 1
        self.frames += frame.frame_count
        self.bytes += len(frame.data)
        self.dropped += frame.dropped_frames_before
        if self.first_timestamp_ns is None:
            self.first_timestamp_ns = frame.timestamp_ns
        self.latest_timestamp_ns = frame.timestamp_ns

    def line(self, label: str) -> str:
        timestamp = self.latest_timestamp_ns / 1_000_000_000 if self.latest_timestamp_ns else 0
        return (f"{label}: source={self.name!r} packets={self.packets} frames={self.frames} "
                f"bytes={self.bytes} dropped={self.dropped} source_time={timestamp:.3f}s")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("conversation", nargs="?", help="first source selector")
    parser.add_argument("media", nargs="?", help="second source selector")
    parser.add_argument("--socket", help="Runtime control socket")
    parser.add_argument("--duration", type=float, default=30.0,
                        help="seconds to run; 0 runs until interrupted")
    return parser.parse_args()


async def select_two(client: Sonexis, first: Optional[str], second: Optional[str]):
    if first and second:
        return await client.get_source(first), await client.get_source(second)
    sources = [source for source in await client.sources() if source.available]
    if len(sources) < 2:
        raise RuntimeError("At least two available application sources are required")
    print("Available sources:")
    for index, source in enumerate(sources, 1):
        print(f"  [{index}] {source.name} ({source.id})")
    if not first:
        first = (await console_input("Conversation source number: ")).strip()
        try:
            conversation = sources[int(first) - 1]
        except (ValueError, IndexError) as error:
            raise RuntimeError("Invalid conversation source") from error
    else:
        conversation = await client.get_source(first)
    if not second:
        second = (await console_input("Media source number: ")).strip()
        try:
            media = sources[int(second) - 1]
        except (ValueError, IndexError) as error:
            raise RuntimeError("Invalid media source") from error
    else:
        media = await client.get_source(second)
    if conversation.id == media.id:
        raise RuntimeError("Choose two different sources to demonstrate source identity")
    return conversation, media


async def console_input(prompt: str) -> str:
    """Read without leaving an uncancellable executor thread during shutdown."""
    print(prompt, end="", flush=True)
    loop = asyncio.get_running_loop()
    future = loop.create_future()
    descriptor = sys.stdin.fileno()

    def readable() -> None:
        loop.remove_reader(descriptor)
        if not future.done():
            future.set_result(sys.stdin.readline())

    loop.add_reader(descriptor, readable)
    try:
        return await future
    finally:
        loop.remove_reader(descriptor)


async def reporter(stats: Dict[str, SourceStats], session, done: asyncio.Event) -> None:
    while not done.is_set():
        try:
            await asyncio.wait_for(done.wait(), timeout=2.0)
        except asyncio.TimeoutError:
            print("\nIndependent stream state:")
            for label in ("conversation", "media"):
                print("  " + stats[label].line(label))
            print(f"  merge-queue dropped frames={session.dropped_frames}")


async def consume(session, stats: Dict[str, SourceStats], done: asyncio.Event) -> None:
    async for item in session.frames():
        stats[item.label].observe(item)
        if done.is_set():
            return
    done.set()


async def watch_lifecycle(client: Sonexis, source_labels: Dict[str, str],
                          done: asyncio.Event) -> None:
    events = await client.events([
        "source_removed", "capture_failed", "capture_stopped", "runtime_shutting_down",
    ])
    async with events:
        async for event in events:
            label = source_labels.get(event.source_id or "")
            if label:
                print(f"\nLifecycle: {label} received {event.type} ({event.message or 'no detail'})")
            elif event.type == "runtime_shutting_down":
                print("\nLifecycle: Runtime is shutting down")
                done.set()
                return


async def main() -> None:
    args = parse_args()
    done = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, done.set)
    if args.duration > 0:
        loop.call_later(args.duration, done.set)

    async with Sonexis(args.socket, client_name="sonexis-multi-source-demo") as client:
        conversation, media = await select_two(client, args.conversation, args.media)
        audio_format = AudioFormat.speech_16k()
        stats: Dict[str, SourceStats] = {}
        started = time.monotonic()
        async with client.session(max_queue_frames=128, fail_fast=False) as session:
            conversation_capture = await session.add(
                "conversation", conversation, format=audio_format)
            media_capture = await session.add("media", media, format=audio_format)
            stats["conversation"] = SourceStats(
                conversation.name, conversation.id, conversation_capture.info.id,
                conversation_capture.info.stream_id)
            stats["media"] = SourceStats(
                media.name, media.id, media_capture.info.id, media_capture.info.stream_id)

            print("Two independent captures started:")
            for label in ("conversation", "media"):
                value = stats[label]
                print(f"  {label}: source={value.source_id} session={value.session_id} "
                      f"stream={value.stream_id}")

            tasks = [
                asyncio.create_task(consume(session, stats, done)),
                asyncio.create_task(reporter(stats, session, done)),
                asyncio.create_task(watch_lifecycle(
                    client,
                    {conversation.id: "conversation", media.id: "media"},
                    done)),
                asyncio.create_task(done.wait()),
            ]
            try:
                completed, _ = await asyncio.wait(
                    tasks, return_when=asyncio.FIRST_COMPLETED)
                for task in completed:
                    if not task.cancelled() and task.exception() is not None:
                        raise task.exception()
            finally:
                done.set()
                for task in tasks:
                    if not task.done():
                        task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)

        print(f"\nStopped cleanly after {time.monotonic() - started:.1f}s")
        for label in ("conversation", "media"):
            print("  " + stats[label].line(label))
        for label, error in session.errors_by_label.items():
            print(f"  {label} ended with {type(error).__name__}: {error}")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except (OSError, RuntimeError, SonexisError) as error:
        raise SystemExit(f"error: {error}") from error
