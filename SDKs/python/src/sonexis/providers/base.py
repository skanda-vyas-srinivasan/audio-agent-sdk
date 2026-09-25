"""Provider-neutral realtime audio consumer contract."""

from dataclasses import dataclass
from typing import Any, AsyncIterator, Optional, Protocol

from ..diagnostics import AudioSendReceipt
from ..models import AudioFormat, AudioFrame


@dataclass(frozen=True)
class ProviderEvent:
    provider: str
    type: str
    text: Optional[str] = None
    audio: Optional[bytes] = None
    raw: Any = None


class RealtimeAudioSink(Protocol):
    """The intentionally small interface implemented by optional adapters."""

    required_format: AudioFormat

    async def send_audio(self, frame: AudioFrame) -> AudioSendReceipt:
        ...

    def events(self) -> AsyncIterator[ProviderEvent]:
        ...

    async def aclose(self) -> None:
        ...
