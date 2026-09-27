"""Small composition helper for independent Sonexis capture and output."""

import asyncio
from typing import Any, Optional, TYPE_CHECKING, Union

from .models import AudioFormat

if TYPE_CHECKING:
    from .client import CaptureSession, Sonexis, SourceSelector
    from .models import AudioOutputDestination
    from .output import AudioOutput


class DuplexSession:
    """Own one capture and one output without imposing an agent policy.

    Applications remain responsible for model calls, echo policy, and barge-in.
    ``output.flush()`` is the primitive for discarding buffered response audio.
    """

    def __init__(
        self,
        client: "Sonexis",
        input_source: "SourceSelector",
        *,
        output_destination: Union[str, "AudioOutputDestination"] = "default",
        input_format: AudioFormat = AudioFormat(),
        output_format: Optional[AudioFormat] = None,
        target_buffer_milliseconds: int = 60,
    ) -> None:
        self.client = client
        self.input_source = input_source
        self.output_destination = output_destination
        self.input_format = input_format
        self.output_format = output_format or input_format
        self.target_buffer_milliseconds = target_buffer_milliseconds
        self._input: Optional["CaptureSession"] = None
        self._output: Optional["AudioOutput"] = None
        self._state = "new"
        self._lifecycle_lock = asyncio.Lock()
        self._close_task: Optional[asyncio.Task] = None

    @property
    def input(self) -> "CaptureSession":
        if self._input is None:
            raise RuntimeError("Duplex session has not been entered or is already closed")
        return self._input

    @property
    def output(self) -> "AudioOutput":
        if self._output is None:
            raise RuntimeError("Duplex session has not been entered or is already closed")
        return self._output

    @property
    def feedback_risk(self) -> bool:
        """True when output targets an advisory loopback/virtual-input device.

        This warns about a possible digital loop; it is not echo cancellation
        and cannot prove that the captured application selected this input.
        """
        return bool(self._output and self._output.destination
                    and self._output.destination.kind == "virtual_input")

    @property
    def feedback_warning(self) -> Optional[str]:
        if not self.feedback_risk:
            return None
        return ("Output targets a virtual input. Prevent the receiving application from "
                "feeding generated audio back into the selected capture source.")

    async def __aenter__(self) -> "DuplexSession":
        async with self._lifecycle_lock:
            if self._state != "new":
                raise RuntimeError(f"Duplex session cannot be entered while {self._state}")
            self._state = "opening"
            try:
                self._input = await self.client.capture(
                    self.input_source, format=self.input_format)
                self._output = await self.client.playback(
                    destination=self.output_destination,
                    format=self.output_format,
                    target_buffer_milliseconds=self.target_buffer_milliseconds,
                )
            except BaseException:
                if self._input is not None:
                    await self._input.aclose()
                    self._input = None
                self._state = "closed"
                raise
            self._state = "open"
            return self

    async def __aexit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        await self.aclose(drain_output=exc_type is None)

    async def aclose(self, *, drain_output: bool = True) -> None:
        async with self._lifecycle_lock:
            if self._close_task is None:
                self._state = "closing"
                self._close_task = asyncio.create_task(
                    self._finish_close(drain_output=drain_output),
                    name="sonexis-duplex-cleanup")
            close_task = self._close_task
        await asyncio.shield(close_task)

    async def _finish_close(self, *, drain_output: bool) -> None:
        output, capture = self._output, self._input
        self._output = None
        self._input = None
        async def close_capture() -> None:
            if capture is not None:
                await capture.aclose()

        async def close_output() -> None:
            if output is not None:
                await output.aclose(drain=drain_output)

        capture_result, output_result = await asyncio.gather(
            close_capture(), close_output(), return_exceptions=True)
        self._state = "closed"
        for result in (capture_result, output_result):
            if isinstance(result, BaseException):
                raise result
