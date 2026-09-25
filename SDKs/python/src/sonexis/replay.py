"""Deterministic source-aware PCM/WAV replay for SDK and adapter development."""

import asyncio
import time
import uuid
import wave
from pathlib import Path
from typing import AsyncIterator, BinaryIO, Optional, Union

from .models import AudioFormat, AudioFrame, AudioSource, SampleFormat


class ReplayStream(AsyncIterator[AudioFrame]):
    """Yield recorded PCM as ordinary source-aware Sonexis frames."""

    def __init__(
        self,
        handle: Optional[BinaryIO],
        *,
        format: AudioFormat,
        source_name: str,
        chunk_frames: int = 1_600,
        realtime: bool = False,
        wave_reader: Optional[wave.Wave_read] = None,
    ) -> None:
        if chunk_frames < 1:
            raise ValueError("chunk_frames must be positive")
        self.format = format
        self.chunk_frames = chunk_frames
        self.realtime = realtime
        self._handle = handle
        self._wave_reader = wave_reader
        self._sequence = 0
        self._position_frames = 0
        self._started_at_ns = time.monotonic_ns()
        identity = str(uuid.uuid5(uuid.NAMESPACE_URL, source_name))
        self.source = AudioSource(f"replay.{identity}", source_name, "virtual", [], None,
                                  "running", True, None, format)
        self.session_id = str(uuid.uuid4())
        self.stream_id = str(uuid.uuid4())
        self._closed = False
        self._closed_event = asyncio.Event()
        self._read_task: Optional[asyncio.Task] = None
        self._close_task: Optional[asyncio.Task] = None

    @classmethod
    def from_wav(cls, path: Union[str, Path], *, chunk_frames: int = 1_600,
                 realtime: bool = False) -> "ReplayStream":
        """Open an uncompressed PCM16 WAV as a deterministic audio source."""
        value = Path(path)
        reader = wave.open(str(value), "rb")
        if reader.getcomptype() != "NONE" or reader.getsampwidth() != 2:
            reader.close()
            raise ValueError("Replay WAV must contain uncompressed PCM16 audio")
        format = AudioFormat(reader.getframerate(), reader.getnchannels(), SampleFormat.PCM_S16LE)
        return cls(None, format=format, source_name=value.name,
                   chunk_frames=chunk_frames, realtime=realtime, wave_reader=reader)

    @classmethod
    def from_pcm(cls, path: Union[str, Path], *, format: AudioFormat,
                 chunk_frames: int = 1_600, realtime: bool = False) -> "ReplayStream":
        """Open headerless PCM using the caller-supplied format."""
        value = Path(path)
        return cls(value.open("rb"), format=format, source_name=value.name,
                   chunk_frames=chunk_frames, realtime=realtime)

    async def __aenter__(self) -> "ReplayStream":
        return self

    async def __aexit__(self, exc_type, exc, traceback) -> None:
        await self.aclose()

    def __aiter__(self) -> "ReplayStream":
        return self

    async def __anext__(self) -> AudioFrame:
        if self._closed:
            raise StopAsyncIteration
        if self._read_task is not None and not self._read_task.done():
            raise RuntimeError("ReplayStream supports one consumer")
        if self._wave_reader is not None:
            task = asyncio.create_task(
                asyncio.to_thread(self._wave_reader.readframes, self.chunk_frames),
                name="sonexis-replay-read")
        else:
            assert self._handle is not None
            size = self.chunk_frames * self.format.channels * self.format.sample_format.bytes_per_sample
            task = asyncio.create_task(
                asyncio.to_thread(self._handle.read, size), name="sonexis-replay-read")
        self._read_task = task
        try:
            data = await asyncio.shield(task)
        finally:
            if task.done() and self._read_task is task:
                self._read_task = None
        if not data:
            await self.aclose()
            raise StopAsyncIteration
        bytes_per_frame = self.format.channels * self.format.sample_format.bytes_per_sample
        if len(data) % bytes_per_frame:
            await self.aclose()
            raise ValueError("Replay PCM ends with a partial sample frame")
        frame_count = len(data) // bytes_per_frame
        timestamp_ns = self._position_frames * 1_000_000_000 // self.format.sample_rate
        if self.realtime:
            target = self._started_at_ns + timestamp_ns
            delay = (target - time.monotonic_ns()) / 1_000_000_000
            if delay > 0:
                try:
                    await asyncio.wait_for(self._closed_event.wait(), timeout=delay)
                except asyncio.TimeoutError:
                    pass
        if self._closed:
            raise StopAsyncIteration
        frame = AudioFrame(
            stream_id=self.stream_id,
            sequence=self._sequence,
            timestamp_ns=timestamp_ns,
            frame_count=frame_count,
            format=self.format,
            data=data,
            source=self.source,
            session_id=self.session_id,
            runtime_started_at_ns=self._started_at_ns,
            received_at_ns=time.monotonic_ns(),
        )
        self._sequence += 1
        self._position_frames += frame_count
        return frame

    async def aclose(self) -> None:
        if self._close_task is None:
            self._closed = True
            self._closed_event.set()
            self._close_task = asyncio.create_task(
                self._finish_close(), name="sonexis-replay-cleanup")
        await asyncio.shield(self._close_task)

    async def _finish_close(self) -> None:
        read_task = self._read_task
        if read_task is not None:
            await asyncio.gather(read_task, return_exceptions=True)
            if self._read_task is read_task:
                self._read_task = None
        if self._wave_reader is not None:
            await asyncio.to_thread(self._wave_reader.close)
        else:
            assert self._handle is not None
            await asyncio.to_thread(self._handle.close)
