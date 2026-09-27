#!/usr/bin/env python3
"""Interactive source-aware Sonexis audio agent reference application."""

import argparse
import asyncio
import os
import stat
import signal
import sys
import time
import wave
from pathlib import Path
from typing import AsyncIterator, Optional

from sonexis import (
    AudioFormat,
    AudioFrame,
    AudioSendReceipt,
    LatencyTracker,
    ProviderError,
    ReplayStream,
    SampleFormat,
    Sonexis,
    SonexisError,
)
from sonexis.providers import (
    GeminiLiveSink,
    GeminiTurnDetectionConfig,
    OpenAIRealtimeSink,
    ProviderEvent,
    RealtimeAudioSink,
)


GEMINI_SYSTEM_INSTRUCTION = (
    "Respond in English. Briefly summarize or respond to the audio you just heard."
)


class MockRealtimeSink:
    """Offline sink that exercises the same flow as a network provider."""

    def __init__(self, audio_format: AudioFormat) -> None:
        self.required_format = audio_format
        self._events: "asyncio.Queue[Optional[ProviderEvent]]" = asyncio.Queue()
        self._frames = 0
        self._next_summary = audio_format.sample_rate * 5
        self._closed = False

    async def send_audio(self, frame: AudioFrame) -> AudioSendReceipt:
        if self._closed:
            raise ProviderError("provider_closed", "Mock provider is closed")
        if frame.format != self.required_format:
            raise ProviderError(
                "unsupported_provider_format",
                f"Mock provider expected {self.required_format!r}; got {frame.format!r}",
            )
        self._frames += frame.frame_count
        if self._frames >= self._next_summary:
            seconds = self._frames / self.required_format.sample_rate
            await self._events.put(ProviderEvent(
                "mock", "mock.summary",
                text=f"received {seconds:.1f} seconds from {frame.source_name or 'replay'}",
            ))
            self._next_summary += self.required_format.sample_rate * 5
        return AudioSendReceipt(
            "mock", frame.sequence, time.monotonic_ns(), len(frame.data),
            frame.estimated_sonexis_latency_ns,
        )

    async def events(self) -> AsyncIterator[ProviderEvent]:
        while True:
            event = await self._events.get()
            if event is None:
                return
            yield event

    async def aclose(self) -> None:
        if self._closed:
            return
        self._closed = True
        await self._events.put(None)


class OutputWriter:
    def __init__(self, path: Optional[Path], audio_format: AudioFormat) -> None:
        self._raw = None
        self._wav = None
        if path is None:
            return
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
        output = os.fdopen(descriptor, "wb")
        if path.suffix.lower() == ".wav":
            if audio_format.sample_format is not SampleFormat.PCM_S16LE:
                output.close()
                raise ValueError("WAV output requires PCM16 audio")
            self._wav = wave.open(output, "wb")
            self._wav.setnchannels(audio_format.channels)
            self._wav.setsampwidth(2)
            self._wav.setframerate(audio_format.sample_rate)
        else:
            self._raw = output

    def write(self, data: bytes) -> None:
        if self._wav is not None:
            self._wav.writeframesraw(data)
        elif self._raw is not None:
            self._raw.write(data)

    def close(self) -> None:
        if self._wav is not None:
            self._wav.close()
        if self._raw is not None:
            self._raw.close()


class StreamStats:
    def __init__(self) -> None:
        self.started = time.monotonic()
        self.frames = 0
        self.packets = 0
        self.bytes = 0
        self.dropped = 0
        self.latency = LatencyTracker()

    def observe(self, frame: AudioFrame) -> None:
        self.frames += frame.frame_count
        self.packets += 1
        self.bytes += len(frame.data)
        self.dropped += frame.dropped_frames_before
        self.latency.observe(frame)

    def line(self) -> str:
        elapsed = time.monotonic() - self.started
        latency = self.latency.summary()
        timing = "latency=unavailable"
        if latency is not None:
            timing = (f"latency_ms(p50/p95/p99)={latency.p50_ms:.2f}/"
                      f"{latency.p95_ms:.2f}/{latency.p99_ms:.2f}")
        return (f"wall_seconds={elapsed:.1f} packets={self.packets} frames={self.frames} "
                f"bytes={self.bytes} dropped={self.dropped} {timing}")


class RuntimeResponsePlayer:
    """Routes provider audio through the public Sonexis output API."""

    def __init__(self, client: Sonexis, destination: str, *, debug: bool) -> None:
        self._client = client
        self._destination = destination
        self._debug = debug
        self._output = None
        self._format: Optional[AudioFormat] = None

    async def write(self, event: ProviderEvent) -> None:
        if not event.audio:
            return
        if event.audio_format is None:
            raise RuntimeError(
                f"{event.provider} returned audio without a declared PCM format")
        if self._output is None:
            self._format = event.audio_format
            self._output = await self._client.playback(
                destination=self._destination,
                format=event.audio_format,
            )
            print(
                f"\nPlaying {event.provider} responses through "
                f"{self._output.info.destination_id} "
                f"(output session {self._output.info.id})")
        elif event.audio_format != self._format:
            raise RuntimeError(
                f"provider response format changed from {self._format!r} "
                f"to {event.audio_format!r}")
        await self._output.write(event.audio)
        if self._debug:
            print(f"\nOutput debug: queued {len(event.audio)} provider audio bytes")

    async def close(self) -> None:
        if self._output is None:
            return
        output, self._output = self._output, None
        await output.aclose(drain=True)
        if self._debug:
            print(f"\nOutput debug: {output.metrics!r}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Feed a source-aware Sonexis stream to a realtime AI provider.")
    parser.add_argument("--provider", choices=("mock", "openai", "gemini"), default="mock")
    parser.add_argument("--source", help="source ID, bundle ID, PID, or exact app name")
    parser.add_argument("--socket", help="Runtime control socket path")
    parser.add_argument("--output", type=Path, help="optional PCM or .wav recording")
    parser.add_argument(
        "--response-output", metavar="DESTINATION",
        help="route generated provider audio through Sonexis (for example: default)")
    parser.add_argument(
        "--play-response", action="store_const", const="default",
        dest="response_output",
        help="shorthand for --response-output default")
    parser.add_argument("--replay", type=Path, help="use a PCM16 WAV/PCM file instead of live capture")
    parser.add_argument("--sample-rate", type=int, default=16_000,
                        help="mock/raw-replay rate; provider modes use their required preset")
    parser.add_argument("--channels", type=int, choices=(1, 2), default=1,
                        help="mock/raw-replay channels")
    parser.add_argument("--realtime-replay", action="store_true",
                        help="pace replay according to recorded timestamps")
    parser.add_argument("--non-interactive", action="store_true",
                        help="disable switch/quit prompt (requires --source for live capture)")
    parser.add_argument("--debug", action="store_true",
                        help="show provider lifecycle and raw output-audio diagnostics")
    parser.add_argument("--gemini-start-threshold", type=float, default=0.015,
                        help="normalized RMS required to begin local Gemini activity")
    parser.add_argument("--gemini-end-threshold", type=float, default=0.008,
                        help="normalized RMS below which Gemini silence accumulates")
    parser.add_argument("--gemini-min-activity-ms", type=float, default=250.0,
                        help="activity required before opening a Gemini turn")
    parser.add_argument("--gemini-silence-ms", type=float, default=1_200.0,
                        help="continuous local silence required to finalize a Gemini turn")
    return parser.parse_args()


async def create_sink(args: argparse.Namespace) -> RealtimeAudioSink:
    if args.provider == "openai":
        return await OpenAIRealtimeSink.connect()
    if args.provider == "gemini":
        turn_detection = GeminiTurnDetectionConfig(
            activity_start_threshold=args.gemini_start_threshold,
            activity_end_threshold=args.gemini_end_threshold,
            minimum_activity_ms=args.gemini_min_activity_ms,
            silence_duration_ms=args.gemini_silence_ms,
        )
        debug_callback = ((lambda message: print(f"\nGemini debug: {message}"))
                          if args.debug else None)
        return await GeminiLiveSink.connect(
            system_instruction=GEMINI_SYSTEM_INSTRUCTION,
            turn_detection=turn_detection,
            debug_callback=debug_callback,
        )
    return MockRealtimeSink(AudioFormat(
        args.sample_rate, args.channels, SampleFormat.PCM_S16LE))


async def choose_source(client: Sonexis, selector: Optional[str] = None):
    if selector:
        if selector.isdecimal():
            return await client.get_source(int(selector))
        return await client.get_source(selector)
    sources = [source for source in await client.sources() if source.available]
    if not sources:
        raise RuntimeError("No available application audio sources")
    print("\nAvailable sources:\n")
    for index, source in enumerate(sources, 1):
        bundle = f" [{source.bundle_identifier}]" if source.bundle_identifier else ""
        print(f"  [{index}] {source.name}{bundle}")
    answer = (await console_input("\nSelect source: ")).strip()
    try:
        return sources[int(answer) - 1]
    except (ValueError, IndexError) as error:
        raise RuntimeError("Invalid source selection") from error


async def print_provider_events(
    sink: RealtimeAudioSink,
    done: asyncio.Event,
    *,
    debug: bool = False,
    response_player: Optional[RuntimeResponsePlayer] = None,
) -> None:
    try:
        async for event in sink.events():
            if event.text:
                print(f"\nAgent ({event.provider}): {event.text}")
            if event.audio and response_player is not None:
                await response_player.write(event)
            elif event.audio and debug:
                print(f"\nAgent ({event.provider}): received {len(event.audio)} audio bytes")
            if (debug and not event.text and not event.audio
                    and event.type not in {"session.started", "session.updated"}):
                print(f"\nProvider event: {event.type}")
    except ProviderError as error:
        print(f"\nProvider receive failed: {error.message} (retryable={error.retryable})")
        done.set()
    except (OSError, RuntimeError, SonexisError) as error:
        print(f"\nResponse playback failed: {error}")
        done.set()


async def report_stats(stats: StreamStats, done: asyncio.Event) -> None:
    while not done.is_set():
        try:
            await asyncio.wait_for(done.wait(), timeout=2.0)
        except asyncio.TimeoutError:
            print(f"\nStream: {stats.line()}")


async def console_input(prompt: str) -> str:
    """Read a terminal line without leaving an uncancellable executor thread."""
    print(prompt, end="", flush=True)
    loop = asyncio.get_running_loop()
    future = loop.create_future()
    descriptor = sys.stdin.fileno()

    def readable() -> None:
        loop.remove_reader(descriptor)
        line = sys.stdin.readline()
        if not future.done():
            future.set_result(line)

    loop.add_reader(descriptor, readable)
    try:
        return await future
    finally:
        loop.remove_reader(descriptor)


async def read_command() -> str:
    while True:
        raw = await console_input("\n[s]witch source, [q]uit: ")
        if not raw:
            return "quit"
        value = raw.strip().lower()
        if value in {"s", "switch", "q", "quit"}:
            return "switch" if value.startswith("s") else "quit"


async def watch_source(client: Sonexis, source_id: str) -> str:
    subscription = await client.events([
        "source_removed", "capture_failed", "runtime_shutting_down",
    ])
    async with subscription:
        async for event in subscription:
            if event.type == "runtime_shutting_down":
                print("\nRuntime is shutting down")
                return "quit"
            if event.source_id == source_id:
                detail = f": {event.message}" if event.message else ""
                print(f"\nSource event: {event.type}{detail}")
                return "source-ended"
    return "source-ended"


async def consume(
    stream: AsyncIterator[AudioFrame],
    sink: RealtimeAudioSink,
    output: OutputWriter,
    stats: StreamStats,
    done: asyncio.Event,
) -> str:
    try:
        async for frame in stream:
            if done.is_set():
                return "quit"
            stats.observe(frame)
            await asyncio.to_thread(output.write, frame.data)
            await sink.send_audio(frame)
    except asyncio.CancelledError:
        raise
    except ProviderError as error:
        print(f"\nProvider send failed: {error.message} (retryable={error.retryable})")
        return "quit"
    except SonexisError as error:
        print(f"\nAudio stream failed: {error.message} (retryable={error.retryable})")
        return "source-ended"
    print("\nAudio stream ended")
    return "source-ended"


async def run_live(
    args: argparse.Namespace,
    sink: RealtimeAudioSink,
    output: OutputWriter,
    done: asyncio.Event,
) -> None:
    if args.non_interactive and not args.source:
        raise RuntimeError("--non-interactive live capture requires --source")
    async with Sonexis(args.socket, client_name="sonexis-audio-agent") as client:
        selector = args.source
        while not done.is_set():
            source = await choose_source(client, selector)
            selector = None
            stats = StreamStats()
            async with await client.capture(source, format=sink.required_format) as stream:
                print(f"\nListening to {source.name} ({source.id})")
                print(f"session={stream.info.id} stream={stream.info.stream_id}")
                tasks = {
                    asyncio.create_task(consume(stream, sink, output, stats, done)),
                    asyncio.create_task(watch_source(client, source.id)),
                    asyncio.create_task(report_stats(stats, done)),
                    asyncio.create_task(done.wait()),
                }
                if not args.non_interactive:
                    tasks.add(asyncio.create_task(read_command()))
                completed, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
                result = "quit"
                for task in completed:
                    value = task.result()
                    if isinstance(value, str):
                        result = value
                        break
                for task in pending:
                    task.cancel()
                await asyncio.gather(*pending, return_exceptions=True)
            print(f"Final stream stats: {stats.line()}")
            if result == "switch":
                continue
            if result == "source-ended" and not args.non_interactive:
                answer = (await console_input(
                    "Source ended. Select another source? [y/N]: ")).strip().lower()
                if answer in {"y", "yes"}:
                    continue
            return


async def run_replay(
    args: argparse.Namespace,
    sink: RealtimeAudioSink,
    output: OutputWriter,
    done: asyncio.Event,
) -> None:
    assert args.replay is not None
    if args.replay.suffix.lower() == ".wav":
        stream = ReplayStream.from_wav(args.replay, realtime=args.realtime_replay)
    else:
        stream = ReplayStream.from_pcm(
            args.replay, format=AudioFormat(args.sample_rate, args.channels),
            realtime=args.realtime_replay)
    if stream.format != sink.required_format:
        await stream.aclose()
        raise RuntimeError(
            f"Replay format {stream.format!r} does not match {args.provider} "
            f"format {sink.required_format!r}")
    stats = StreamStats()
    async with stream:
        print(f"Replaying {args.replay} as source {stream.source.id}")
        await consume(stream, sink, output, stats, done)
    print(f"Final replay stats: {stats.line()}")


async def main() -> None:
    args = parse_args()
    done = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, done.set)

    sink = await create_sink(args)
    response_client: Optional[Sonexis] = None
    response_player: Optional[RuntimeResponsePlayer] = None
    try:
        if args.response_output:
            response_client = Sonexis(
                args.socket, client_name="sonexis-audio-agent-output")
            await response_client.connect()
            response_player = RuntimeResponsePlayer(
                response_client, args.response_output, debug=args.debug)
        output = OutputWriter(args.output, sink.required_format)
        provider_events = asyncio.create_task(
            print_provider_events(
                sink, done, debug=args.debug, response_player=response_player))
        try:
            if args.replay:
                await run_replay(args, sink, output, done)
            else:
                await run_live(args, sink, output, done)
        finally:
            done.set()
            provider_events.cancel()
            await asyncio.gather(provider_events, return_exceptions=True)
            output.close()
    finally:
        try:
            await sink.aclose()
            if response_player is not None:
                await response_player.close()
        finally:
            if response_client is not None:
                await response_client.close()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except (OSError, RuntimeError, SonexisError, ValueError) as error:
        raise SystemExit(f"error: {error}") from error
