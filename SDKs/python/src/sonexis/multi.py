"""Bounded orchestration for independent labeled Sonexis capture streams."""

import asyncio
import warnings
from collections import deque
from dataclasses import dataclass
from typing import AsyncIterator, Deque, Dict, Mapping, Optional, Set

from .client import CaptureSession, Sonexis, SourceSelector
from .models import AudioFormat, AudioFrame, AudioSource


@dataclass(frozen=True)
class LabeledAudioFrame:
    """One frame from a named member of a multi-source session."""

    label: str
    frame: AudioFrame
    local_dropped_frames_before: int = 0

    @property
    def source(self) -> AudioSource:
        if self.frame.source is None:
            raise RuntimeError("multi-source frame is missing source context")
        return self.frame.source

    @property
    def session_id(self) -> str:
        if self.frame.session_id is None:
            raise RuntimeError("multi-source frame is missing session context")
        return self.frame.session_id

    @property
    def stream_id(self) -> str:
        return self.frame.stream_id

    @property
    def timestamp_ns(self) -> int:
        return self.frame.timestamp_ns

    @property
    def discontinuity(self) -> bool:
        return self.frame.discontinuity or self.local_dropped_frames_before > 0


@dataclass(frozen=True)
class _StreamEnded:
    label: str
    error: Optional[BaseException] = None


class MultiSourceSession:
    """Own independent captures while yielding their frames with stable labels."""

    def __init__(self, client: Sonexis, *, max_queue_packets: int = 128,
                 fail_fast: bool = True,
                 max_queue_frames: Optional[int] = None) -> None:
        if max_queue_frames is not None:
            if max_queue_packets != 128:
                raise TypeError(
                    "max_queue_packets and max_queue_frames cannot both be specified")
            warnings.warn(
                "max_queue_frames is deprecated; use max_queue_packets",
                DeprecationWarning,
                stacklevel=2,
            )
            max_queue_packets = max_queue_frames
        if max_queue_packets < 1:
            raise ValueError("max_queue_packets must be positive")
        self.client = client
        self.max_queue_packets = max_queue_packets
        # Compatibility mirror. The queue has always counted packets.
        self.max_queue_frames = max_queue_packets
        self.fail_fast = fail_fast
        self.dropped_frames = 0
        self.dropped_frames_by_label: Dict[str, int] = {}
        self._queues: Dict[str, Deque[LabeledAudioFrame]] = {}
        self._pending_drops: Dict[str, int] = {}
        self._terminals: Dict[str, _StreamEnded] = {}
        self._available = asyncio.Event()
        self._captures: Dict[str, CaptureSession] = {}
        self._tasks: Dict[str, asyncio.Task] = {}
        self._pending_labels: Set[str] = set()
        self._removals: Dict[str, asyncio.Task] = {}
        self._closed = False
        self._iterator_active = False
        self._close_task: Optional[asyncio.Task] = None
        self._errors_by_label: Dict[str, BaseException] = {}

    async def __aenter__(self) -> "MultiSourceSession":
        return self

    async def __aexit__(self, exc_type, exc, traceback) -> None:
        await self.aclose()

    @property
    def labels(self):
        return tuple(self._captures)

    @property
    def errors_by_label(self) -> Mapping[str, BaseException]:
        """Terminal member errors retained when ``fail_fast`` is disabled."""
        return dict(self._errors_by_label)

    async def add(self, label: str, source: SourceSelector, *,
                  format: AudioFormat = AudioFormat()) -> CaptureSession:
        """Start one independently buffered capture under a unique application label."""
        if self._closed:
            raise RuntimeError("multi-source session is closed")
        if not label or label in self._captures or label in self._pending_labels:
            raise ValueError(f"capture label must be non-empty and unique: {label!r}")
        self._pending_labels.add(label)
        try:
            capture = await self.client.capture(source, format=format)
            if self._closed:
                await capture.aclose()
                raise RuntimeError("multi-source session closed while capture was starting")
            self._queues[label] = deque()
            self._pending_drops[label] = 0
            self.dropped_frames_by_label[label] = 0
            self._captures[label] = capture
            self._tasks[label] = asyncio.create_task(
                self._pump(label, capture), name=f"sonexis-multi-{label}")
            return capture
        finally:
            self._pending_labels.discard(label)

    async def remove(self, label: str) -> None:
        removal = self._removals.get(label)
        if removal is None:
            capture = self._captures.get(label)
            if capture is None:
                return
            # Reserve the label until its old pump and all queue state are gone.
            self._pending_labels.add(label)
            self._captures.pop(label)
            task = self._tasks.pop(label, None)
            removal = asyncio.create_task(
                self._finish_remove(label, capture, task), name=f"sonexis-remove-{label}")
            self._removals[label] = removal
        await asyncio.shield(removal)

    async def _finish_remove(self, label: str, capture: CaptureSession,
                             task: Optional[asyncio.Task]) -> None:
        if task is not None:
            task.cancel()
        try:
            await capture.aclose()
        finally:
            if task is not None:
                await asyncio.gather(task, return_exceptions=True)
            self._queues.pop(label, None)
            self._pending_drops.pop(label, None)
            self._terminals.pop(label, None)
            self._removals.pop(label, None)
            self._pending_labels.discard(label)
            self._available.set()

    async def _pump(self, label: str, capture: CaptureSession) -> None:
        error: Optional[BaseException] = None
        try:
            async for frame in capture:
                queue = self._queues.get(label)
                if queue is None:
                    return
                if len(queue) >= self.max_queue_packets:
                    self.dropped_frames += frame.frame_count
                    self.dropped_frames_by_label[label] += frame.frame_count
                    self._pending_drops[label] += frame.frame_count
                    continue
                dropped = self._pending_drops[label]
                self._pending_drops[label] = 0
                if dropped:
                    frame = AudioFrame(
                        frame.stream_id, frame.sequence, frame.timestamp_ns,
                        frame.frame_count, frame.format, frame.data,
                        discontinuity=True,
                        dropped_frames_before=frame.dropped_frames_before,
                        source=frame.source, session_id=frame.session_id,
                        runtime_started_at_ns=frame.runtime_started_at_ns,
                        received_at_ns=frame.received_at_ns,
                    )
                queue.append(LabeledAudioFrame(label, frame, dropped))
                self._available.set()
        except asyncio.CancelledError:
            raise
        except BaseException as caught:
            error = caught
        finally:
            if self._captures.get(label) is capture:
                if error is not None and not self.fail_fast:
                    self._errors_by_label[label] = error
                self._terminals[label] = _StreamEnded(label, error)
            self._available.set()

    async def frames(self) -> AsyncIterator[LabeledAudioFrame]:
        """Yield labeled frames until all members end or the session is closed."""
        if self._iterator_active:
            raise RuntimeError("multi-source frames already have a consumer")
        self._iterator_active = True
        try:
            while not self._closed:
                if not self._tasks:
                    return
                for label in tuple(self._tasks):
                    queue = self._queues.get(label)
                    if queue:
                        yield queue.popleft()

                finished = [label for label in self._terminals
                            if not self._queues.get(label)]
                for label in finished:
                    terminal = self._terminals.pop(label)
                    self._tasks.pop(label, None)
                    self._captures.pop(label, None)
                    self._queues.pop(label, None)
                    self._pending_drops.pop(label, None)
                    if terminal.error is not None:
                        self._errors_by_label[label] = terminal.error
                        if self.fail_fast:
                            raise terminal.error
                if not self._tasks:
                    return

                self._available.clear()
                if any(self._queues.get(label) for label in self._tasks) or self._terminals:
                    continue
                await self._available.wait()
        finally:
            self._iterator_active = False

    async def aclose(self) -> None:
        if self._close_task is None:
            self._closed = True
            self._close_task = asyncio.create_task(
                self._finish_close(), name="sonexis-multi-cleanup")
        await asyncio.shield(self._close_task)

    async def _finish_close(self) -> None:
        labels = list(self._captures)
        await asyncio.gather(*(self.remove(label) for label in labels),
                             *list(self._removals.values()))
