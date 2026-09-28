#!/usr/bin/env python3
"""Seeded pre-release torture gate for the packaged agent orchestration."""

import argparse
import asyncio
import gc
import hashlib
import random
import struct
import sys
import time
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).parents[1] / "src"))

from audioplane.agent import (ProviderInputForwarder, RuntimeResponsePlayer,
                              StreamStats)
from sonexis import AudioFormat, AudioFrame
from sonexis.providers import ProviderEvent


class StalledProvider:
    def __init__(self):
        self.started = asyncio.Event()
        self.release = asyncio.Event()
        self.frames = []

    async def send_audio(self, frame):
        if not self.frames:
            self.started.set()
            await self.release.wait()
        self.frames.append(frame)


class HashingOutput:
    info = SimpleNamespace(id="torture-output", destination_id="virtual")
    metrics = SimpleNamespace(frames_rendered=0)

    def __init__(self, *, fail_after=None):
        self.digest = hashlib.sha256()
        self.bytes = 0
        self.writes = 0
        self.flushes = 0
        self.closes = []
        self.fail_after = fail_after

    async def write(self, value):
        if self.fail_after is not None and self.writes >= self.fail_after:
            raise RuntimeError("injected output disappearance")
        if len(value) < 48 or len(value) > 2_400 or len(value) % 2:
            raise AssertionError(f"invalid Runtime packet size: {len(value)}")
        self.writes += 1
        self.bytes += len(value)
        self.digest.update(value)

    async def flush(self):
        self.flushes += 1

    async def aclose(self, *, drain):
        self.closes.append(drain)


class OutputClient:
    def __init__(self, output):
        self.output = output

    async def playback(self, *, destination, format):
        return self.output


class FakeClock:
    def __init__(self):
        self.now = 100.0
        self.slept = 0.0

    def clock(self):
        return self.now

    async def sleep(self, duration):
        self.slept += duration
        self.now += duration


def audio_frame(sequence):
    audio_format = AudioFormat.gemini_live()
    return AudioFrame(
        "stream", sequence, sequence * 10_000_000, 160,
        audio_format, b"\0\0" * 160, session_id="session")


async def stress_provider_backpressure(transitions):
    provider = StalledProvider()
    stats = StreamStats()
    forwarder = ProviderInputForwarder(
        provider, stats, max_queue_packets=32, close_timeout=0.5)
    await forwarder.send_audio(audio_frame(0))
    await provider.started.wait()
    template = audio_frame(1)
    for sequence in range(1, transitions + 1):
        await forwarder.send_audio(replace(template, sequence=sequence))
        if forwarder._queue.qsize() > 32:
            raise AssertionError("provider input queue exceeded its hard bound")
    provider.release.set()
    await forwarder.close()
    if not forwarder._worker.done():
        raise AssertionError("provider input worker leaked")
    if stats.provider_queue_high_water != 32:
        raise AssertionError("provider queue did not exercise its hard bound")
    if len(provider.frames) != 33 or not provider.frames[1].discontinuity:
        raise AssertionError("queue shedding was not reported as a discontinuity")
    expected_dropped = (transitions - 32) * 160
    if stats.provider_dropped != expected_dropped:
        raise AssertionError(
            f"drop accounting mismatch: {stats.provider_dropped} != {expected_dropped}")
    return transitions


async def stress_output_chunking(turns, seed):
    randomizer = random.Random(seed)
    output = HashingOutput()
    clock = FakeClock()
    player = RuntimeResponsePlayer(
        OutputClient(output), "virtual", debug=False,
        max_pending_bytes=32 * 1024 * 1024,
        max_pending_chunks=16_384,
        clock=clock.clock,
        sleep=clock.sleep,
    )
    expected = hashlib.sha256()
    expected_bytes = 0
    transitions = 0
    for turn in range(turns):
        frame_count = randomizer.randint(1, 12_000)
        payload = b"".join(
            struct.pack("<h", (turn * 101 + frame) % 32_767)
            for frame in range(frame_count)
        )
        offset = 0
        while offset < len(payload):
            chunk_frames = randomizer.randint(1, 2_047)
            end = min(len(payload), offset + chunk_frames * 2)
            await player.write(ProviderEvent(
                "gemini", "audio", audio=payload[offset:end],
                audio_format=AudioFormat.gemini_live_output()))
            offset = end
            transitions += 1
            if transitions % 32 == 0:
                await asyncio.sleep(0)
        await player.finish_response()
        expected.update(payload)
        expected_bytes += len(payload)
        tail = len(payload) % 2_400
        if 0 < tail < 48:
            padding = b"\0" * (48 - tail)
            expected.update(padding)
            expected_bytes += len(padding)
        transitions += 1
    await player.close()
    if not player._worker.done():
        raise AssertionError("response playback worker leaked")
    if output.bytes != expected_bytes or output.digest.digest() != expected.digest():
        raise AssertionError("randomized response PCM was lost, reordered, or corrupted")
    if output.closes != [True]:
        raise AssertionError(f"unexpected output close mode: {output.closes}")
    return transitions


async def stress_interruptions(cycles):
    output = HashingOutput()
    player = RuntimeResponsePlayer(
        OutputClient(output), "virtual", debug=False,
        max_pending_bytes=8 * 1024 * 1024,
        max_pending_chunks=8_192,
    )
    payload = b"\x01\x02" * 2_400
    for cycle in range(cycles):
        await player.write(ProviderEvent(
            "gemini", "audio", audio=payload,
            audio_format=AudioFormat.gemini_live_output()))
        await asyncio.sleep(0)
        await player.interrupt_response()
        if cycle % 16 == 0:
            await asyncio.sleep(0)
    await player.close()
    if not player._worker.done():
        raise AssertionError("interruption playback worker leaked")
    if not 1 <= output.flushes <= cycles:
        raise AssertionError("barge-in never flushed Runtime playback")
    return cycles * 2


async def stress_output_failure():
    output = HashingOutput(fail_after=1)
    failure = asyncio.Event()
    errors = []
    player = RuntimeResponsePlayer(
        OutputClient(output), "virtual", debug=False,
        on_failure=lambda error: (errors.append(error), failure.set()),
    )
    event = ProviderEvent(
        "gemini", "audio", audio=b"\x01\x02" * 2_400,
        audio_format=AudioFormat.gemini_live_output())
    await player.write(event)
    await asyncio.wait_for(failure.wait(), timeout=1.0)
    try:
        await player.write(event)
    except RuntimeError:
        pass
    else:
        raise AssertionError("terminal output failure was not surfaced")
    await asyncio.wait_for(player.close(), timeout=1.0)
    if len(errors) != 1 or "injected output disappearance" not in str(errors[0]):
        raise AssertionError("output failure callback was incorrect")
    return 2


async def run(arguments):
    baseline_tasks = len(asyncio.all_tasks())
    started = time.monotonic()
    transitions = await stress_provider_backpressure(arguments.transitions)
    transitions += await stress_output_chunking(arguments.turns, arguments.seed)
    transitions += await stress_interruptions(arguments.interruptions)
    transitions += await stress_output_failure()
    await asyncio.sleep(0)
    gc.collect()
    leaked_tasks = [task for task in asyncio.all_tasks()
                    if not task.done() and task is not asyncio.current_task()]
    if len(asyncio.all_tasks()) != baseline_tasks or leaked_tasks:
        raise AssertionError(f"agent tasks leaked: {leaked_tasks!r}")
    elapsed = time.monotonic() - started
    print(
        "agent torture passed: "
        f"seed={arguments.seed} transitions={transitions} "
        f"turns={arguments.turns} interruptions={arguments.interruptions} "
        f"elapsed={elapsed:.2f}s"
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", type=int, default=0xA710)
    parser.add_argument("--transitions", type=int, default=1_000_000)
    parser.add_argument("--turns", type=int, default=1_000)
    parser.add_argument("--interruptions", type=int, default=1_000)
    arguments = parser.parse_args()
    if min(arguments.transitions, arguments.turns, arguments.interruptions) < 1:
        parser.error("all counts must be positive")
    asyncio.run(run(arguments))


if __name__ == "__main__":
    main()
