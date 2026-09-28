"""Provider-neutral realtime audio consumer contract and validation helpers."""

from dataclasses import dataclass
from typing import Any, AsyncIterator, Optional, Protocol

from ..diagnostics import AudioSendReceipt
from ..errors import ProviderError
from ..models import AudioFormat, AudioFrame


@dataclass(frozen=True)
class ProviderEvent:
    """One provider event.

    ``raw`` is intentionally unstable provider-private diagnostic data. Public
    applications should use the normalized response flags and correlation
    fields instead.
    """

    provider: str
    type: str
    text: Optional[str] = None
    audio: Optional[bytes] = None
    audio_format: Optional[AudioFormat] = None
    raw: Any = None
    response_started: bool = False
    response_completed: bool = False
    response_interrupted: bool = False
    source_id: Optional[str] = None
    session_id: Optional[str] = None
    stream_id: Optional[str] = None


class ProviderStreamValidator:
    """Validate one ordered Sonexis stream without owning provider I/O."""

    def __init__(self, provider: str, required_format: AudioFormat) -> None:
        self.provider = provider
        self.required_format = required_format
        self.stream_id: Optional[str] = None
        self.source_id: Optional[str] = None
        self.session_id: Optional[str] = None
        self.last_sequence: Optional[int] = None

    def validate(self, frame: AudioFrame) -> None:
        if frame.format != self.required_format:
            raise ProviderError(
                "unsupported_provider_format",
                f"{self.provider} requires {self.required_format!r}; got {frame.format!r}",
            )
        expected = (frame.frame_count * frame.format.channels
                    * frame.format.sample_format.bytes_per_sample)
        if frame.frame_count < 1 or len(frame.data) != expected:
            raise ProviderError(
                "invalid_audio", "PCM payload does not match its frame metadata")
        if self.stream_id is not None and self.stream_id != frame.stream_id:
            raise ProviderError(
                "provider_stream_mismatch",
                f"Use one {self.provider} sink per Sonexis stream",
            )
        if self.last_sequence is not None and frame.sequence <= self.last_sequence:
            raise ProviderError(
                "provider_sequence_error", "Audio frames must be sent in sequence order")

    def commit(self, frame: AudioFrame) -> None:
        if self.stream_id is None:
            self.stream_id = frame.stream_id
            self.source_id = frame.source_id
            self.session_id = frame.session_id
        self.last_sequence = frame.sequence

    def event_fields(self) -> dict:
        return {
            "source_id": self.source_id,
            "session_id": self.session_id,
            "stream_id": self.stream_id,
        }


class RealtimeAudioSink(Protocol):
    """The intentionally small interface implemented by optional adapters."""

    required_format: AudioFormat

    async def __aenter__(self) -> "RealtimeAudioSink":
        ...

    async def __aexit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        ...

    async def send_audio(self, frame: AudioFrame) -> AudioSendReceipt:
        ...

    def events(self) -> AsyncIterator[ProviderEvent]:
        ...

    async def aclose(self) -> None:
        ...
