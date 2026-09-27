"""Optional OpenAI GPT-Live adapter using the official `openai[realtime]` SDK."""

import base64
import binascii
import asyncio
import os
import sys
import uuid
from typing import Any, AsyncIterator, List, Optional

from ..diagnostics import AudioSendReceipt, send_receipt
from ..errors import ProviderError, sanitized_provider_error
from ..models import AudioFormat, AudioFrame
from .base import ProviderEvent, ProviderStreamValidator


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
        self._validator = ProviderStreamValidator("OpenAI", self.required_format)
        self._terminal_send_error = False
        self._events_active = False
        self._response_in_progress = False

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
        except BaseException as error:
            try:
                await context.__aexit__(None, None, None)
            finally:
                await client.close()
            if isinstance(error, (asyncio.CancelledError, ProviderError)):
                raise
            raise ProviderError("provider_handshake_failed",
                                sanitized_provider_error(error), retryable=True) from error

    async def __aenter__(self) -> "OpenAIRealtimeSink":
        return self

    async def __aexit__(self, exc_type, exc, traceback) -> None:
        await self.aclose()

    async def send_audio(self, frame: AudioFrame) -> AudioSendReceipt:
        if self._closed:
            raise ProviderError("provider_closed", "OpenAI session is closed")
        if self._terminal_send_error:
            raise ProviderError("provider_failed", "OpenAI send stream is no longer usable")
        self._validator.validate(frame)
        async with self._send_lock:
            encoded = base64.b64encode(frame.data).decode("ascii")
            try:
                await self._connection.session.input_audio.append(audio=encoded)
            except asyncio.CancelledError:
                raise
            except BaseException as error:
                self._terminal_send_error = True
                raise ProviderError("provider_send_failed",
                                    sanitized_provider_error(error), retryable=False) from error
            if self._closed:
                raise ProviderError("provider_closed", "OpenAI session closed during send")
            self._validator.commit(frame)
        return send_receipt("openai", frame, len(encoded))

    async def events(self) -> AsyncIterator[ProviderEvent]:
        if self._events_active:
            raise ProviderError("provider_event_consumer_exists",
                                "OpenAI events already have a consumer")
        self._events_active = True
        try:
            for value in self._prefetched_events:
                yield self._event_for_sink(value)
            self._prefetched_events.clear()
            iterator = getattr(self, "_event_iterator", self._connection.__aiter__())
            async for value in iterator:
                if getattr(value, "type", None) == "error":
                    message = getattr(getattr(value, "error", None), "message", None)
                    raise ProviderError("provider_error", sanitized_provider_error(
                        RuntimeError(str(message or "OpenAI session error"))))
                yield self._event_for_sink(value)
        except asyncio.CancelledError:
            raise
        except BaseException as error:
            if isinstance(error, ProviderError):
                raise
            if self._closed:
                return
            raise ProviderError("provider_receive_failed",
                                sanitized_provider_error(error), retryable=True) from error
        finally:
            self._events_active = False

    @staticmethod
    def _event(value: Any) -> ProviderEvent:
        """Parse one wire event without sink correlation (legacy test helper)."""
        return OpenAIRealtimeSink._parse_event(value)

    def _event_for_sink(self, value: Any) -> ProviderEvent:
        event = self._parse_event(value)
        starts = event.type in {
            "response.created", "response.output_item.added", "session.output_audio.delta"
        } and not self._response_in_progress
        if starts:
            self._response_in_progress = True
        completes = event.type in {
            "response.done", "response.output_item.done", "session.output_audio.done"
        }
        if completes:
            self._response_in_progress = False
        return ProviderEvent(
            event.provider, event.type, event.text, event.audio, event.audio_format,
            event.raw, starts, completes, **self._validator.event_fields())

    @staticmethod
    def _parse_event(value: Any) -> ProviderEvent:
        event_type = str(getattr(value, "type", "unknown"))
        text = getattr(value, "delta", None)
        if not isinstance(text, str):
            text = getattr(value, "text", None)
        audio = None
        if event_type == "session.output_audio.delta" and isinstance(getattr(value, "delta", None), str):
            try:
                audio = base64.b64decode(value.delta, validate=True)
                text = None
            except (ValueError, binascii.Error) as error:
                raise ProviderError("invalid_provider_audio",
                                    "OpenAI returned malformed base64 audio") from error
        return ProviderEvent(
            "openai", event_type, text=text if isinstance(text, str) else None,
            audio=audio,
            audio_format=(AudioFormat.openai_realtime_output()
                          if audio is not None else None),
            raw=value,
        )

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
