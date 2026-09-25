"""Optional OpenAI GPT-Live adapter using the official `openai[realtime]` SDK."""

import base64
import asyncio
import os
import uuid
from typing import Any, AsyncIterator, List, Optional

from ..diagnostics import AudioSendReceipt, send_receipt
from ..errors import ProviderError
from ..models import AudioFormat, AudioFrame
from .base import ProviderEvent


class OpenAIRealtimeSink:
    """Send Sonexis PCM to an OpenAI GPT-Live primary WebSocket session."""

    required_format = AudioFormat.openai_realtime()

    def __init__(self, connection: Any, *, connection_context: Any = None,
                 client: Any = None, prefetched_events: Optional[List[Any]] = None) -> None:
        self._connection = connection
        self._connection_context = connection_context
        self._client = client
        self._prefetched_events = prefetched_events or []
        self._closed = False
        self._close_task: Optional[asyncio.Task] = None

    @classmethod
    async def connect(
        cls,
        *,
        api_key: Optional[str] = None,
        model: str = "gpt-live-1",
        instructions: str = "Respond concisely to the incoming audio.",
        voice: str = "marin",
    ) -> "OpenAIRealtimeSink":
        key = api_key or os.environ.get("OPENAI_API_KEY")
        if not key:
            raise ProviderError("missing_credentials", "OPENAI_API_KEY is not set")
        try:
            from openai import AsyncOpenAI
        except ImportError as error:
            raise ProviderError(
                "missing_dependency",
                "Install the Sonexis 'openai' extra (openai[realtime])",
            ) from error
        client = AsyncOpenAI(api_key=key)
        context = client.live.connect()
        try:
            connection = await context.__aenter__()
            await connection.session.start(
                session={
                    "model": model,
                    "instructions": instructions,
                    "audio": {
                        "format": {"type": "audio/pcm", "rate": 24_000},
                        "output": {"voice": voice},
                    },
                },
                event_id=f"sonexis_{uuid.uuid4().hex}",
            )
            iterator = connection.__aiter__()
            first = await iterator.__anext__()
            if getattr(first, "type", None) != "session.started":
                raise ProviderError("provider_handshake_failed",
                                    "OpenAI did not acknowledge session.start")
            # Preserve the iterator advanced above for event delivery.
            sink = cls(connection, connection_context=context, client=client,
                       prefetched_events=[first])
            sink._event_iterator = iterator
            return sink
        except BaseException:
            try:
                await context.__aexit__(None, None, None)
            finally:
                await client.close()
            raise

    async def __aenter__(self) -> "OpenAIRealtimeSink":
        return self

    async def __aexit__(self, exc_type, exc, traceback) -> None:
        await self.aclose()

    def _validate(self, frame: AudioFrame) -> None:
        if frame.format != self.required_format:
            raise ProviderError(
                "unsupported_provider_format",
                f"OpenAI GPT-Live requires {self.required_format!r}; got {frame.format!r}",
            )
        if len(frame.data) % 2:
            raise ProviderError("invalid_audio", "PCM16 payload contains a partial sample")

    async def send_audio(self, frame: AudioFrame) -> AudioSendReceipt:
        if self._closed:
            raise ProviderError("provider_closed", "OpenAI session is closed")
        self._validate(frame)
        encoded = base64.b64encode(frame.data).decode("ascii")
        try:
            await self._connection.session.input_audio.append(audio=encoded)
        except asyncio.CancelledError:
            raise
        except BaseException as error:
            raise ProviderError("provider_send_failed", str(error), retryable=True) from error
        return send_receipt("openai", frame, len(encoded))

    async def events(self) -> AsyncIterator[ProviderEvent]:
        for value in self._prefetched_events:
            yield self._event(value)
        self._prefetched_events.clear()
        iterator = getattr(self, "_event_iterator", self._connection.__aiter__())
        try:
            async for value in iterator:
                if getattr(value, "type", None) == "error":
                    message = getattr(getattr(value, "error", None), "message", None)
                    raise ProviderError("provider_error", str(message or "OpenAI session error"))
                yield self._event(value)
        except asyncio.CancelledError:
            raise
        except BaseException as error:
            if isinstance(error, ProviderError):
                raise
            if self._closed:
                return
            raise ProviderError("provider_receive_failed", str(error), retryable=True) from error

    @staticmethod
    def _event(value: Any) -> ProviderEvent:
        event_type = str(getattr(value, "type", "unknown"))
        text = getattr(value, "delta", None)
        if not isinstance(text, str):
            text = getattr(value, "text", None)
        audio = None
        if event_type == "session.output_audio.delta" and isinstance(getattr(value, "delta", None), str):
            try:
                audio = base64.b64decode(value.delta, validate=True)
                text = None
            except ValueError:
                pass
        return ProviderEvent("openai", event_type, text=text if isinstance(text, str) else None,
                             audio=audio, raw=value)

    async def aclose(self) -> None:
        if self._close_task is None:
            self._closed = True
            self._close_task = asyncio.create_task(
                self._finish_close(), name="sonexis-openai-cleanup")
        await asyncio.shield(self._close_task)

    async def _finish_close(self) -> None:
        try:
            await self._connection.session.close()
        except BaseException:
            pass
        try:
            if self._connection_context is not None:
                await self._connection_context.__aexit__(None, None, None)
        finally:
            if self._client is not None:
                await self._client.close()
