"""Small composition helper for independent Sonexis capture and output."""

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
        output_format: AudioFormat = AudioFormat.openai_realtime_output(),
        target_buffer_milliseconds: int = 60,
    ) -> None:
        self.client = client
        self.input_source = input_source
        self.output_destination = output_destination
        self.input_format = input_format
        self.output_format = output_format
        self.target_buffer_milliseconds = target_buffer_milliseconds
        self._input: Optional["CaptureSession"] = None
        self._output: Optional["AudioOutput"] = None

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

    async def __aenter__(self) -> "DuplexSession":
        self._input = await self.client.capture(
            self.input_source, format=self.input_format)
        try:
            self._output = await self.client.playback(
                destination=self.output_destination,
                format=self.output_format,
                target_buffer_milliseconds=self.target_buffer_milliseconds,
            )
        except BaseException:
            await self._input.aclose()
            self._input = None
            raise
        return self

    async def __aexit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        await self.aclose(drain_output=exc_type is None)

    async def aclose(self, *, drain_output: bool = True) -> None:
        output, capture = self._output, self._input
        self._output = None
        self._input = None
        first_error: Optional[BaseException] = None
        try:
            if capture is not None:
                await capture.aclose()
        except BaseException as error:
            first_error = error
        try:
            if output is not None:
                await output.aclose(drain=drain_output)
        except BaseException as error:
            if first_error is None:
                first_error = error
        if first_error is not None:
            raise first_error
