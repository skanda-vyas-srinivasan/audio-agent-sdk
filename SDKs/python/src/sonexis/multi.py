"""Bounded orchestration for independent labeled Sonexis capture streams."""

import asyncio
from dataclasses import dataclass
from typing import AsyncIterator, Dict, Optional

from .client import CaptureSession, Sonexis, SourceSelector
from .models import AudioFormat, AudioFrame, AudioSource


@dataclass(frozen=True)
class LabeledAudioFrame:
    """One frame from a named member of a multi-source session."""

    label: str
    frame: AudioFrame

    @property
    def source(self) -> Optional[AudioSource]:
        return self.frame.source

    @property
    def session_id(self) -> Optional[str]:
        return self.frame.session_id

    @property
    def stream_id(self) -> str:
        return self.frame.stream_id

    @property
    def timestamp_ns(self) -> int:
        return self.frame.timestamp_ns


@dataclass(frozen=True)
class _StreamEnded:
    label: str
    error: Optional[BaseException] = None


class MultiSourceSession:
    """Own independent captures while yielding their frames with stable labels."""

    def __init__(self, client: Sonexis, *, max_queue_frames: int = 128) -> None:
        if max_queue_frames < 1:
            raise ValueError("max_queue_frames must be positive")
        self.client = client
        self.max_queue_frames = max_queue_frames
        self.dropped_frames = 0
        self._queue: "asyncio.Queue[object]" = asyncio.Queue(max_queue_frames)
        self._captures: Dict[str, CaptureSession] = {}
        self._tasks: Dict[str, asyncio.Task] = {}
        self._closed = False
        self._close_task: Optional[asyncio.Task] = None

    async def __aenter__(self) -> "MultiSourceSession":
        return self

    async def __aexit__(self, exc_type, exc, traceback) -> None:
        await self.aclose()

    @property
    def labels(self):
        return tuple(self._captures)

    async def add(self, label: str, source: SourceSelector, *,
                  format: AudioFormat = AudioFormat()) -> CaptureSession:
        if self._closed:
            raise RuntimeError("multi-source session is closed")
        if not label or label in self._captures:
            raise ValueError(f"capture label must be non-empty and unique: {label!r}")
        capture = await self.client.capture(source, format=format)
        self._captures[label] = capture
        self._tasks[label] = asyncio.create_task(
            self._pump(label, capture), name=f"sonexis-multi-{label}")
        return capture

    async def remove(self, label: str) -> None:
        capture = self._captures.pop(label, None)
        task = self._tasks.pop(label, None)
        if task is not None:
            task.cancel()
        if capture is not None:
            await capture.aclose()
        if task is not None:
            await asyncio.gather(task, return_exceptions=True)

    async def _pump(self, label: str, capture: CaptureSession) -> None:
        error: Optional[BaseException] = None
        try:
            async for frame in capture:
                try:
                    self._queue.put_nowait(LabeledAudioFrame(label, frame))
                except asyncio.QueueFull:
                    self.dropped_frames += frame.frame_count
        except asyncio.CancelledError:
            raise
        except BaseException as caught:
            error = caught
        finally:
            await self._queue.put(_StreamEnded(label, error))

    async def frames(self) -> AsyncIterator[LabeledAudioFrame]:
        """Yield labeled frames until all members end or the session is closed."""
        while not self._closed:
            if not self._tasks:
                return
            item = await self._queue.get()
            if isinstance(item, _StreamEnded):
                self._tasks.pop(item.label, None)
                self._captures.pop(item.label, None)
                if item.error is not None:
                    raise item.error
                continue
            assert isinstance(item, LabeledAudioFrame)
            yield item

    async def aclose(self) -> None:
        if self._close_task is None:
            self._closed = True
            self._close_task = asyncio.create_task(
                self._finish_close(), name="sonexis-multi-cleanup")
        await asyncio.shield(self._close_task)

    async def _finish_close(self) -> None:
        labels = list(self._captures)
        for label in labels:
            await self.remove(label)
