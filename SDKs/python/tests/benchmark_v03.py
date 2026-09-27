"""Repeatable offline replay/provider-pipeline benchmark; no live capture or network."""

import argparse
import asyncio
import json
import platform
import resource
import sys
import tempfile
import time
import tracemalloc
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "src"))

from sonexis import AudioFormat, ReplayStream
from sonexis.providers import (GeminiLiveSink, GeminiTurnDetectionConfig,
                               OpenAIRealtimeSink)


class _DiscardingOpenAIInput:
    def __init__(self):
        self.frames = 0
        self.bytes = 0

    async def append(self, *, audio):
        self.frames += 1
        self.bytes += len(audio)


class _OpenAISession:
    def __init__(self):
        self.input_audio = _DiscardingOpenAIInput()

    async def close(self):
        pass


class _OpenAIConnection:
    def __init__(self):
        self.session = _OpenAISession()


class _GeminiSession:
    def __init__(self):
        self.frames = 0
        self.bytes = 0

    async def send_realtime_input(self, **value):
        audio = value.get("audio")
        if isinstance(audio, dict):
            self.frames += 1
            self.bytes += len(audio["data"])


def _maximum_rss_bytes():
    value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return value if sys.platform == "darwin" else value * 1024


async def _run_pipeline(path, audio_format, chunk_frames, sink=None):
    frame_count = 0
    payload_bytes = 0
    started = time.perf_counter_ns()
    async with ReplayStream.from_pcm(
        path, format=audio_format, chunk_frames=chunk_frames
    ) as replay:
        async for frame in replay:
            frame_count += 1
            payload_bytes += len(frame.data)
            if sink is not None:
                await sink.send_audio(frame)
    elapsed_ns = time.perf_counter_ns() - started
    if sink is not None:
        await sink.aclose()
    return {
        "frames": frame_count,
        "payload_bytes": payload_bytes,
        "elapsed_ms": elapsed_ns / 1_000_000,
        "audio_seconds": payload_bytes /
            (audio_format.sample_rate * audio_format.channels
             * audio_format.sample_format.bytes_per_sample),
        "payload_mib_per_second": payload_bytes / (1024 * 1024) /
            max(elapsed_ns / 1_000_000_000, 1e-9),
    }


async def _bounded_slow_consumer(path, frames, chunk_frames):
    queue = asyncio.Queue(maxsize=8)
    dropped = 0
    high_water = 0
    consumed = 0

    async def produce():
        nonlocal dropped, high_water
        async with ReplayStream.from_pcm(
            path, format=AudioFormat.speech_16k(), chunk_frames=chunk_frames
        ) as replay:
            async for frame in replay:
                try:
                    queue.put_nowait(frame)
                except asyncio.QueueFull:
                    dropped += 1
                high_water = max(high_water, queue.qsize())
        await queue.put(None)

    async def consume():
        nonlocal consumed
        while True:
            frame = await queue.get()
            if frame is None:
                return
            consumed += 1
            if consumed % 4 == 0:
                await asyncio.sleep(0.001)

    started = time.perf_counter_ns()
    await asyncio.gather(produce(), consume())
    return {
        "produced_frames": frames,
        "consumed_frames": consumed,
        "dropped_frames": dropped,
        "queue_capacity": queue.maxsize,
        "queue_high_water_mark": high_water,
        "elapsed_ms": (time.perf_counter_ns() - started) / 1_000_000,
    }


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames", type=int, default=4000)
    parser.add_argument("--chunk-frames", type=int, default=160)
    arguments = parser.parse_args()
    if arguments.frames < 1 or arguments.chunk_frames < 1:
        parser.error("--frames and --chunk-frames must be positive")

    tracemalloc.start()
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "synthetic.pcm"
        path.write_bytes(b"\0\0" * arguments.frames * arguments.chunk_frames)

        replay = await _run_pipeline(
            path, AudioFormat.speech_16k(), arguments.chunk_frames)

        openai_connection = _OpenAIConnection()
        openai = await _run_pipeline(
            path, AudioFormat.openai_realtime(), arguments.chunk_frames,
            OpenAIRealtimeSink(openai_connection))
        openai["encoded_bytes"] = openai_connection.session.input_audio.bytes

        gemini_session = _GeminiSession()
        gemini = await _run_pipeline(
            path, AudioFormat.gemini_live(), arguments.chunk_frames,
            GeminiLiveSink(
                gemini_session, blob_factory=lambda **value: value,
                turn_detection=GeminiTurnDetectionConfig(enabled=False)))
        gemini["submitted_bytes"] = gemini_session.bytes

        slow = await _bounded_slow_consumer(
            path, arguments.frames, arguments.chunk_frames)

    _, peak_bytes = tracemalloc.get_traced_memory()
    tracemalloc.stop()
    print(json.dumps({
        "scope": "offline replay and mocked provider send only; excludes Core Audio and network",
        "environment": {
            "python": platform.python_version(),
            "platform": platform.platform(),
        },
        "configuration": {
            "frames": arguments.frames,
            "chunk_frames": arguments.chunk_frames,
        },
        "cases": {
            "replay": replay,
            "openai_base64_adapter": openai,
            "gemini_blob_adapter": gemini,
            "bounded_slow_consumer": slow,
        },
        "process": {
            "tracemalloc_peak_bytes": peak_bytes,
            "maximum_resident_set_bytes": _maximum_rss_bytes(),
        },
    }, indent=2, sort_keys=True))


if __name__ == "__main__":
    asyncio.run(main())
