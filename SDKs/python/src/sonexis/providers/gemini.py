"""Optional Gemini Live adapter using the official `google-genai` SDK."""

import os
import asyncio
import inspect
import sys
from typing import Any, AsyncIterator, Optional

from ..diagnostics import AudioSendReceipt, send_receipt
from ..errors import ProviderError
from ..models import AudioFormat, AudioFrame
from .base import ProviderEvent


class GeminiLiveSink:
    """Send Sonexis PCM to a Google Gemini Live session."""

    required_format = AudioFormat.gemini_live()

    def __init__(self, session: Any, *, blob_factory: Any,
                 session_context: Any = None, client: Any = None,
                 close_timeout: float = 2.0) -> None:
        self._session = session
        self._blob_factory = blob_factory
        self._session_context = session_context
        self._client = client
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
        model: Optional[str] = None,
        response_modalities=None,
        handshake_timeout: float = 10.0,
        close_timeout: float = 2.0,
    ) -> "GeminiLiveSink":
        key = api_key or os.environ.get("GEMINI_API_KEY")
        if not key:
            raise ProviderError("missing_credentials", "GEMINI_API_KEY is not set")
        if sys.version_info < (3, 10):
            raise ProviderError("unsupported_python",
                                "The Gemini adapter requires Python 3.10+")
        try:
            from google import genai
            from google.genai import types
        except ImportError as error:
            raise ProviderError(
                "missing_dependency", "Install the Sonexis 'gemini' extra (google-genai)") from error
        selected_model = model or os.environ.get("GEMINI_LIVE_MODEL", "gemini-3.8-live")
        config = {
            "response_modalities": list(response_modalities or ["AUDIO"]),
            "output_audio_transcription": {},
        }
        client = genai.Client(api_key=key)
        context = client.aio.live.connect(model=selected_model, config=config)
        try:
            session = await asyncio.wait_for(
                context.__aenter__(), timeout=handshake_timeout)
            return cls(session, blob_factory=types.Blob,
                       session_context=context, client=client,
                       close_timeout=close_timeout)
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
        expected = frame.frame_count * frame.format.channels * frame.format.sample_format.bytes_per_sample
        if frame.frame_count < 1 or len(frame.data) != expected:
            raise ProviderError("invalid_audio", "PCM payload does not match its frame metadata")

    async def send_audio(self, frame: AudioFrame) -> AudioSendReceipt:
        if self._closed:
            raise ProviderError("provider_closed", "Gemini session is closed")
        self._validate(frame)
        async with self._send_lock:
            if self._stream_id is None:
                self._stream_id = frame.stream_id
            elif self._stream_id != frame.stream_id:
                raise ProviderError("provider_stream_mismatch",
                                    "Use one Gemini sink per Sonexis stream")
            if self._last_sequence is not None and frame.sequence <= self._last_sequence:
                raise ProviderError("provider_sequence_error",
                                    "Audio frames must be sent in sequence order")
            try:
                blob = self._blob_factory(data=frame.data, mime_type="audio/pcm;rate=16000")
                await self._session.send_realtime_input(audio=blob)
            except asyncio.CancelledError:
                raise
            except BaseException as error:
                raise ProviderError("provider_send_failed", str(error), retryable=True) from error
            if self._closed:
                raise ProviderError("provider_closed", "Gemini session closed during send")
            self._last_sequence = frame.sequence
        return send_receipt("gemini", frame)

    async def events(self) -> AsyncIterator[ProviderEvent]:
        try:
            async for value in self._session.receive():
                server = getattr(value, "server_content", None)
                transcription = getattr(server, "output_transcription", None)
                text = getattr(transcription, "text", None) or getattr(value, "text", None)
                audio_parts = []
                model_turn = getattr(server, "model_turn", None)
                for part in getattr(model_turn, "parts", None) or []:
                    inline = getattr(part, "inline_data", None)
                    data = getattr(inline, "data", None)
                    mime = str(getattr(inline, "mime_type", ""))
                    if isinstance(data, bytes) and mime.startswith("audio/"):
                        audio_parts.append(data)
                event_type = "output_transcription" if isinstance(text, str) else "message"
                yield ProviderEvent("gemini", event_type,
                                    text=text if isinstance(text, str) else None,
                                    audio=b"".join(audio_parts) or None, raw=value)
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
            await asyncio.wait_for(
                self._session.send_realtime_input(audio_stream_end=True),
                timeout=self._close_timeout)
        except BaseException:
            pass
        try:
            if self._session_context is not None:
                try:
                    await asyncio.wait_for(
                        self._session_context.__aexit__(None, None, None),
                        timeout=self._close_timeout)
                except BaseException:
                    pass
        finally:
            close = getattr(self._client, "close", None)
            if close is not None:
                try:
                    result = close()
                    if inspect.isawaitable(result):
                        await asyncio.wait_for(result, timeout=self._close_timeout)
                except BaseException:
                    pass
