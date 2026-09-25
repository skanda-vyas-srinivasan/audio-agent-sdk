"""Optional OpenAI GPT-Live adapter using the official `openai[realtime]` SDK."""

import base64
import asyncio
import os
import sys
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
                 client: Any = None, prefetched_events: Optional[List[Any]] = None,
                 close_timeout: float = 2.0) -> None:
        self._connection = connection
        self._connection_context = connection_context
        self._client = client
        self._prefetched_events = prefetched_events or []
        self._closed = False
        self._close_task: Optional[asyncio.Task] = None
        self._close_timeout = close_timeout
        self._send_lock = asyncio.Lock()
        self._stream_id: Optional[str] = None
        self._last_sequence: Optional[int] = None

    @classmethod
    async def connect(
        cls,
        *,
        api_key: Optional[str] = None,
        model: str = "gpt-live-1",
        instructions: str = "Respond concisely to the incoming audio.",
        voice: str = "marin",
        handshake_timeout: float = 10.0,
        close_timeout: float = 2.0,
    ) -> "OpenAIRealtimeSink":
        key = api_key or os.environ.get("OPENAI_API_KEY")
        if not key:
            raise ProviderError("missing_credentials", "OPENAI_API_KEY is not set")
        if sys.version_info < (3, 10):
            raise ProviderError("unsupported_python",
                                "The OpenAI adapter requires Python 3.10+")
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
            connection = await asyncio.wait_for(
                context.__aenter__(), timeout=handshake_timeout)
            await asyncio.wait_for(connection.session.start(
                session={
                    "model": model,
                    "instructions": instructions,
                    "audio": {
                        "format": {"type": "audio/pcm", "rate": 24_000},
                        "output": {"voice": voice},
                    },
                },
                event_id=f"sonexis_{uuid.uuid4().hex}",
            ), timeout=handshake_timeout)
            iterator = connection.__aiter__()
            first = await asyncio.wait_for(iterator.__anext__(), timeout=handshake_timeout)
            if getattr(first, "type", None) != "session.started":
                raise ProviderError("provider_handshake_failed",
                                    "OpenAI did not acknowledge session.start")
            # Preserve the iterator advanced above for event delivery.
            sink = cls(connection, connection_context=context, client=client,
                       prefetched_events=[first], close_timeout=close_timeout)
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
        expected = frame.frame_count * frame.format.channels * frame.format.sample_format.bytes_per_sample
        if frame.frame_count < 1 or len(frame.data) != expected:
            raise ProviderError("invalid_audio", "PCM payload does not match its frame metadata")

    async def send_audio(self, frame: AudioFrame) -> AudioSendReceipt:
        if self._closed:
            raise ProviderError("provider_closed", "OpenAI session is closed")
        self._validate(frame)
        async with self._send_lock:
            if self._stream_id is None:
                self._stream_id = frame.stream_id
            elif self._stream_id != frame.stream_id:
                raise ProviderError("provider_stream_mismatch",
                                    "Use one OpenAI sink per Sonexis stream")
            if self._last_sequence is not None and frame.sequence <= self._last_sequence:
                raise ProviderError("provider_sequence_error",
                                    "Audio frames must be sent in sequence order")
            encoded = base64.b64encode(frame.data).decode("ascii")
            try:
                await self._connection.session.input_audio.append(audio=encoded)
            except asyncio.CancelledError:
                raise
            except BaseException as error:
                raise ProviderError("provider_send_failed", str(error), retryable=True) from error
            if self._closed:
                raise ProviderError("provider_closed", "OpenAI session closed during send")
            self._last_sequence = frame.sequence
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
            await asyncio.wait_for(
                self._connection.session.close(), timeout=self._close_timeout)
        except BaseException:
            pass
        try:
            if self._connection_context is not None:
                try:
                    await asyncio.wait_for(
                        self._connection_context.__aexit__(None, None, None),
                        timeout=self._close_timeout)
                except BaseException:
                    pass
        finally:
            if self._client is not None:
                try:
                    await asyncio.wait_for(
                        self._client.close(), timeout=self._close_timeout)
                except BaseException:
                    pass
