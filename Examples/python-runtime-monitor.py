#!/usr/bin/env python3
"""Interactive Sonexis capture monitor using only the public Python SDK."""

import argparse
import asyncio
import os
import signal
import stat
import time
import wave
from contextlib import nullcontext
from pathlib import Path

from sonexis import AudioFormat, SampleFormat, Sonexis


def secure_output(path: Path):
    flags = os.O_WRONLY | os.O_CREAT
    if hasattr(os, "O_NONBLOCK"):
        flags |= os.O_NONBLOCK
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    status = os.fstat(descriptor)
    if not stat.S_ISREG(status.st_mode) or status.st_uid != os.geteuid():
        os.close(descriptor)
        raise ValueError("Output must be a regular file owned by the current user")
    os.fchmod(descriptor, 0o600)
    os.ftruncate(descriptor, 0)
    return os.fdopen(descriptor, "wb")


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", help="Runtime source ID; prompts when omitted")
    parser.add_argument("--output", type=Path, help="optional .pcm or PCM16 .wav output")
    parser.add_argument("--sample-rate", type=int, default=16_000)
    parser.add_argument("--channels", type=int, choices=(1, 2), default=1)
    parser.add_argument("--sample-format", choices=[item.value for item in SampleFormat],
                        default=SampleFormat.PCM_S16LE.value)
    parser.add_argument("--socket", help="Runtime control socket")
    return parser.parse_args()


async def choose_source(client, requested):
    sources = await client.sources()
    if requested:
        return next((source for source in sources if source.id == requested), None)
    for index, source in enumerate(sources, 1):
        print(f"{index:2d}. {source.name} ({source.id})")
    if not sources:
        return None
    selection = await asyncio.to_thread(input, "Source number: ")
    try:
        return sources[int(selection) - 1]
    except (ValueError, IndexError):
        return None


async def main():
    args = arguments()
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for name in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(name, stop.set)

    async with Sonexis(args.socket, client_name="sonexis-runtime-monitor") as client:
        source = await choose_source(client, args.source)
        if source is None:
            raise SystemExit("No matching source selected")
        audio_format = AudioFormat(args.sample_rate, args.channels,
                                   SampleFormat(args.sample_format))
        if client.handshake and audio_format not in client.handshake.supported_formats:
            raise SystemExit(f"Runtime does not advertise {audio_format}")

        event_stream = await client.events(["source_removed", "capture_failed", "runtime_shutting_down"])

        async def watch_events():
            async with event_stream:
                async for event in event_stream:
                    print(f"event: {event.type}: {event.message or ''}")
                    if event.type == "runtime_shutting_down" or event.source_id == source.id:
                        stop.set()

        watcher = asyncio.create_task(watch_events())
        output = None
        wav = None
        if args.output:
            if args.output.suffix.lower() == ".wav":
                if audio_format.sample_format is not SampleFormat.PCM_S16LE:
                    raise SystemExit("WAV output currently requires pcm_s16le")
                wav = wave.open(secure_output(args.output), "wb")
                wav.setnchannels(audio_format.channels)
                wav.setsampwidth(2)
                wav.setframerate(audio_format.sample_rate)
            else:
                output = secure_output(args.output)

        frames = bytes_received = dropped = 0
        started = last_report = time.monotonic()
        try:
            async with await client.capture(source, format=audio_format) as stream:
                print(f"capturing {source.name}; session={stream.info.id} stream={stream.info.stream_id}")
                async for frame in stream:
                    if stop.is_set():
                        break
                    frames += frame.frame_count
                    bytes_received += len(frame.data)
                    dropped += frame.dropped_frames_before
                    if wav:
                        wav.writeframesraw(frame.data)
                    elif output:
                        output.write(frame.data)
                    now = time.monotonic()
                    if now - last_report >= 1:
                        print(f"seconds={now-started:.1f} frames={frames} bytes={bytes_received} "
                              f"dropped={dropped}")
                        last_report = now
        finally:
            stop.set()
            watcher.cancel()
            await asyncio.gather(watcher, return_exceptions=True)
            if wav:
                wav.close()
            if output:
                output.close()
            print(f"final frames={frames} bytes={bytes_received} dropped={dropped} "
                  f"duration={time.monotonic()-started:.3f}s")


if __name__ == "__main__":
    asyncio.run(main())
