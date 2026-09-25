"""Optional Gemini Live adapter using the official `google-genai` SDK."""

import os
import asyncio
from typing import Any, AsyncIterator, Optional

from ..diagnostics import AudioSendReceipt, send_receipt
from ..errors import ProviderError
from ..models import AudioFormat, AudioFrame
from .base import ProviderEvent


class GeminiLiveSink:
    """Send Sonexis PCM to a Google Gemini Live session."""

    required_format = AudioFormat.gemini_live()

    def __init__(self, session: Any, *, blob_factory: Any,
                 session_context: Any = None, client: Any = None) -> None:
        self._session = session
        self._blob_factory = blob_factory
        self._session_context = session_context
        self._client = client
        self._closed = False
        self._close_task: Optional[asyncio.Task] = None

    @classmethod
    async def connect(
        cls,
        *,
        api_key: Optional[str] = None,
        model: Optional[str] = None,
        response_modalities=None,
    ) -> "GeminiLiveSink":
        key = api_key or os.environ.get("GEMINI_API_KEY")
        if not key:
            raise ProviderError("missing_credentials", "GEMINI_API_KEY is not set")
        try:
            from google import genai
            from google.genai import types
        except ImportError as error:
            raise ProviderError(
                "missing_dependency", "Install the Sonexis 'gemini' extra (google-genai)") from error
        selected_model = model or os.environ.get("GEMINI_LIVE_MODEL", "gemini-3.8-live")
        config = {"response_modalities": list(response_modalities or ["AUDIO"])}
        client = genai.Client(api_key=key)
        context = client.aio.live.connect(model=selected_model, config=config)
        try:
            session = await context.__aenter__()
            return cls(session, blob_factory=types.Blob,
                       session_context=context, client=client)
        except BaseException:
            close = getattr(client, "close", None)
            if close is not None:
                close()
            raise

    async def __aenter__(self) -> "GeminiLiveSink":
        return self

    async def __aexit__(self, exc_type, exc, traceback) -> None:
        await self.aclose()

    def _validate(self, frame: AudioFrame) -> None:
        if frame.format != self.required_format:
            raise ProviderError(
                "unsupported_provider_format",
                f"Gemini Live requires {self.required_format!r}; got {frame.format!r}",
            )

    async def send_audio(self, frame: AudioFrame) -> AudioSendReceipt:
        if self._closed:
            raise ProviderError("provider_closed", "Gemini session is closed")
        self._validate(frame)
        try:
            blob = self._blob_factory(data=frame.data, mime_type="audio/pcm;rate=16000")
            await self._session.send_realtime_input(audio=blob)
        except asyncio.CancelledError:
            raise
        except BaseException as error:
            raise ProviderError("provider_send_failed", str(error), retryable=True) from error
        return send_receipt("gemini", frame)

    async def events(self) -> AsyncIterator[ProviderEvent]:
        try:
            async for value in self._session.receive():
                text = getattr(value, "text", None)
                yield ProviderEvent("gemini", "message",
                                    text=text if isinstance(text, str) else None, raw=value)
        except asyncio.CancelledError:
            raise
        except BaseException as error:
            if self._closed:
                return
            raise ProviderError("provider_receive_failed", str(error), retryable=True) from error

    async def aclose(self) -> None:
        if self._close_task is None:
            self._closed = True
            self._close_task = asyncio.create_task(
                self._finish_close(), name="sonexis-gemini-cleanup")
        await asyncio.shield(self._close_task)

    async def _finish_close(self) -> None:
        try:
            await self._session.send_realtime_input(audio_stream_end=True)
        except BaseException:
            pass
        try:
            if self._session_context is not None:
                await self._session_context.__aexit__(None, None, None)
        finally:
            close = getattr(self._client, "close", None)
            if close is not None:
                close()
