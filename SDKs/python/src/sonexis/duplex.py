"""Small composition helper for independent Sonexis capture and output."""

from typing import Any, Optional, TYPE_CHECKING

from .models import AudioFormat

if TYPE_CHECKING:
    from .client import CaptureSession, Sonexis, SourceSelector
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
        output_destination: str = "default",
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
        self.input: Optional["CaptureSession"] = None
        self.output: Optional["AudioOutput"] = None

    async def __aenter__(self) -> "DuplexSession":
        self.input = await self.client.capture(
            self.input_source, format=self.input_format)
        try:
            self.output = await self.client.playback(
                destination=self.output_destination,
                format=self.output_format,
                target_buffer_milliseconds=self.target_buffer_milliseconds,
            )
        except BaseException:
            await self.input.aclose()
            self.input = None
            raise
        return self

    async def __aexit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        await self.aclose(drain_output=exc_type is None)

    async def aclose(self, *, drain_output: bool = False) -> None:
        output, capture = self.output, self.input
        self.output = None
        self.input = None
        if output is not None:
            await output.aclose(drain=drain_output)
        if capture is not None:
            await capture.aclose()
