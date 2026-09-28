"""Bounded physical-microphone forwarding through Sonexis Runtime."""

import asyncio
from dataclasses import dataclass
from typing import Any, Optional, TYPE_CHECKING

from .errors import SonexisError
from .models import AudioFormat, AudioSource

if TYPE_CHECKING:
    from .client import CaptureSession, OutputDestinationSelector, Sonexis, SourceSelector
    from .output import AudioOutput


@dataclass(frozen=True)
class MicrophonePassthroughMetrics:
    """Client-side forwarding counters for one passthrough epoch."""

    frames_forwarded: int = 0
    bytes_forwarded: int = 0
    discontinuities_forwarded: int = 0


class MicrophonePassthrough:
    """Forward one Runtime microphone source to one Runtime output.

    This is a convenience composition of the existing bounded capture and
    output planes. It neither changes the macOS default input nor selects the
    virtual microphone inside third-party applications.
    """

    def __init__(
        self,
        client: "Sonexis",
        *,
        input_source: Optional["SourceSelector"],
        output_destination: "OutputDestinationSelector",
        format: AudioFormat,
        target_buffer_milliseconds: int,
    ) -> None:
        self.client = client
        self.input_source = input_source
        self.output_destination = output_destination
        self.format = format
        self.target_buffer_milliseconds = target_buffer_milliseconds
        self.source: Optional[AudioSource] = None
        self.capture: Optional["CaptureSession"] = None
        self.output: Optional["AudioOutput"] = None
        self._pump_task: Optional[asyncio.Task] = None
        self._close_task: Optional[asyncio.Task] = None
        self._state = "new"
        self._metrics = MicrophonePassthroughMetrics()

    @property
    def metrics(self) -> MicrophonePassthroughMetrics:
        return self._metrics

    async def __aenter__(self) -> "MicrophonePassthrough":
        if self._state != "new":
            raise RuntimeError(f"Microphone passthrough cannot start while {self._state}")
        self._state = "opening"
        try:
            self.source = (
                await self.client.default_microphone()
                if self.input_source is None
                else await self.client.get_source(self.input_source)
            )
            if self.source.kind != "microphone":
                raise SonexisError(
                    "not_a_microphone",
                    f"{self.source.name!r} is a {self.source.kind} source, not a microphone",
                    details={"source_id": self.source.id},
                )
            destination = await self.client.get_output_destination(self.output_destination)
            self._reject_direct_feedback(self.source, destination.active_device_id)
            self.output = await self.client.playback(
                destination=destination,
                format=self.format,
                target_buffer_milliseconds=self.target_buffer_milliseconds,
            )
            self.capture = await self.client.capture(self.source, format=self.format)
        except BaseException:
            if self.output is not None:
                await self.output.aclose(drain=False)
                self.output = None
            self._state = "closed"
            raise

        self._state = "open"
        self._pump_task = asyncio.create_task(
            self._pump(), name="sonexis-microphone-passthrough")
        return self

    async def __aexit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        await self.aclose(drain=exc_type is None)

    async def wait(self) -> None:
        """Wait until capture ends or forwarding fails."""
        if self._pump_task is None:
            raise RuntimeError("Microphone passthrough has not been entered")
        await asyncio.shield(self._pump_task)

    async def aclose(self, *, drain: bool = False) -> None:
        """Stop forwarding and close both Runtime sessions deterministically."""
        if self._close_task is None:
            self._state = "closing"
            self._close_task = asyncio.create_task(
                self._finish_close(drain=drain),
                name="sonexis-microphone-passthrough-cleanup",
            )
        await asyncio.shield(self._close_task)

    async def _pump(self) -> None:
        assert self.capture is not None
        assert self.output is not None
        async for frame in self.capture:
            discontinuity = frame.discontinuity or frame.dropped_frames_before > 0
            await self.output.write(
                frame.data,
                timestamp_ns=frame.timestamp_ns,
                discontinuity=discontinuity,
            )
            self._metrics = MicrophonePassthroughMetrics(
                frames_forwarded=self._metrics.frames_forwarded + frame.frame_count,
                bytes_forwarded=self._metrics.bytes_forwarded + len(frame.data),
                discontinuities_forwarded=(
                    self._metrics.discontinuities_forwarded + int(discontinuity)
                ),
            )

    async def _finish_close(self, *, drain: bool) -> None:
        pump, self._pump_task = self._pump_task, None
        if pump is not None and pump is not asyncio.current_task():
            if not pump.done():
                pump.cancel()
            await asyncio.gather(pump, return_exceptions=True)
        capture, self.capture = self.capture, None
        output, self.output = self.output, None
        results = await asyncio.gather(
            capture.aclose() if capture is not None else _completed(),
            output.aclose(drain=drain) if output is not None else _completed(),
            return_exceptions=True,
        )
        self._state = "closed"
        for result in results:
            if isinstance(result, BaseException):
                raise result

    @staticmethod
    def _reject_direct_feedback(source: AudioSource,
                                output_device_uid: Optional[str]) -> None:
        prefix = "microphone:"
        source_uid = source.id[len(prefix):] if source.id.startswith(prefix) else None
        output_prefix = "coreaudio:"
        normalized_output_uid = (
            output_device_uid[len(output_prefix):]
            if output_device_uid and output_device_uid.startswith(output_prefix)
            else output_device_uid
        )
        if source_uid and normalized_output_uid and source_uid == normalized_output_uid:
            raise SonexisError(
                "microphone_feedback_loop",
                "The selected microphone and output are the same Core Audio device. "
                "Choose a physical microphone as the source and AudioPlane Input as the output.",
                details={"source_id": source.id, "device_uid": output_device_uid},
            )


async def _completed() -> None:
    return None
