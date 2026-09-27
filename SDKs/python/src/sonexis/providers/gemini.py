"""Optional Gemini Live adapter using the official `google-genai` SDK."""

import os
import asyncio
import inspect
import sys
from dataclasses import dataclass
from typing import Any, AsyncIterator, Callable, List, Optional

from ..activity import (ActivityDetectionConfig, ActivityState,
                        AudioActivityDetector, VoiceActivityDetector)
from ..diagnostics import AudioSendReceipt, send_receipt
from ..errors import ProviderError, sanitized_provider_error
from ..models import AudioFormat, AudioFrame
from .base import ProviderEvent, ProviderStreamValidator


@dataclass(frozen=True)
class GeminiTurnDetectionConfig(ActivityDetectionConfig):
    """Client-side end detection used alongside Gemini's automatic VAD."""

    enabled: bool = True

    def __post_init__(self) -> None:
        super().__post_init__()
        if not isinstance(self.enabled, bool):
            raise ValueError("enabled must be a boolean")


class GeminiLiveSink:
    """Send Sonexis PCM to a Google Gemini Live session."""

    required_format = AudioFormat.gemini_live()

    @staticmethod
    def _output_audio_format(mime_type: str) -> AudioFormat:
        parts = [part.strip().lower() for part in mime_type.split(";")]
        if not parts or parts[0] != "audio/pcm":
            raise ProviderError(
                "unsupported_provider_audio_format",
                f"Gemini returned unsupported output audio type {mime_type!r}",
            )
        parameters = {}
        for part in parts[1:]:
            if "=" in part:
                key, value = part.split("=", 1)
                parameters[key.strip()] = value.strip()
        if parameters.get("rate") != "24000":
            raise ProviderError(
                "unsupported_provider_audio_format",
                "Gemini output PCM must explicitly declare rate=24000",
            )
        return AudioFormat.gemini_live_output()

    @staticmethod
    def _connection_config(response_modalities, system_instruction: Optional[str]) -> dict:
        config = {
            "response_modalities": list(response_modalities or ["AUDIO"]),
            "output_audio_transcription": {},
            "realtime_input_config": {
                "automatic_activity_detection": {"disabled": False},
            },
        }
        if system_instruction:
            config["system_instruction"] = system_instruction
        return config

    def __init__(self, session: Any, *, blob_factory: Any,
                 session_context: Any = None, client: Any = None,
                 close_timeout: float = 2.0,
                 turn_detection: Optional[GeminiTurnDetectionConfig] = None,
                 voice_activity_detector: Optional[VoiceActivityDetector] = None,
                 debug_callback: Optional[Callable[[str], None]] = None) -> None:
        self._session = session
        self._blob_factory = blob_factory
        self._session_context = session_context
        self._client = client
        self._closed = False
        self._close_task: Optional[asyncio.Task] = None
        self._close_timeout = close_timeout
        self._send_lock = asyncio.Lock()
        self._validator = ProviderStreamValidator("Gemini Live", self.required_format)
        self._turn_detection = turn_detection or GeminiTurnDetectionConfig()
        self._voice_activity_detector = voice_activity_detector
        self._activity_detector = AudioActivityDetector(
            ActivityDetectionConfig(
                activity_start_threshold=self._turn_detection.activity_start_threshold,
                activity_end_threshold=self._turn_detection.activity_end_threshold,
                minimum_activity_ms=self._turn_detection.minimum_activity_ms,
                silence_duration_ms=self._turn_detection.silence_duration_ms,
            ),
            voice_activity_detector=voice_activity_detector,
        )
        self._debug_callback = debug_callback
        self._candidate_frames: List[AudioFrame] = []
        self._segment_open = False
        self._terminal_send_error = False
        self._response_in_progress = False
        self._events_active = False

    @classmethod
    async def connect(
        cls,
        *,
        api_key: Optional[str] = None,
        model: Optional[str] = None,
        response_modalities=None,
        handshake_timeout: float = 10.0,
        close_timeout: float = 2.0,
        system_instruction: Optional[str] = None,
        turn_detection: Optional[GeminiTurnDetectionConfig] = None,
        voice_activity_detector: Optional[VoiceActivityDetector] = None,
        debug_callback: Optional[Callable[[str], None]] = None,
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
        config = cls._connection_config(response_modalities, system_instruction)
        client = genai.Client(api_key=key)
        context = client.aio.live.connect(model=selected_model, config=config)
        try:
            session = await asyncio.wait_for(
                context.__aenter__(), timeout=handshake_timeout)
            return cls(session, blob_factory=types.Blob,
                       session_context=context, client=client,
                       close_timeout=close_timeout,
                       turn_detection=turn_detection,
                       voice_activity_detector=voice_activity_detector,
                       debug_callback=debug_callback)
        except BaseException as error:
            close = getattr(client, "close", None)
            if close is not None:
                close()
            if isinstance(error, (asyncio.CancelledError, ProviderError)):
                raise
            raise ProviderError("provider_handshake_failed",
                                sanitized_provider_error(error), retryable=True) from None

    async def __aenter__(self) -> "GeminiLiveSink":
        return self

    async def __aexit__(self, exc_type, exc, traceback) -> None:
        await self.aclose()

    def _debug(self, message: str) -> None:
        if self._debug_callback is not None:
            try:
                self._debug_callback(message)
            except Exception:
                pass

    async def _send_frame(self, frame: AudioFrame) -> None:
        blob = self._blob_factory(data=frame.data, mime_type="audio/pcm;rate=16000")
        await self._session.send_realtime_input(audio=blob)
        # Set after every successful remote send so cancellation during an
        # onset-buffer flush still leaves close() able to terminate the segment.
        self._segment_open = True

    async def _send_audio_stream_end(self) -> None:
        if not self._segment_open:
            return
        # A cancelled/failed send has ambiguous remote state. Mark this segment
        # terminal before awaiting so close() cannot duplicate the edge.
        self._segment_open = False
        try:
            await self._session.send_realtime_input(audio_stream_end=True)
        except BaseException:
            self._terminal_send_error = True
            raise
        self._debug("audio_stream_end sent")

    async def _send_with_turn_detection(self, frame: AudioFrame) -> int:
        config = self._turn_detection
        if not config.enabled:
            await self._send_frame(frame)
            return len(frame.data)

        if frame.discontinuity:
            if self._segment_open:
                self._debug("local activity end (discontinuity)")
                await self._send_audio_stream_end()
            self._activity_detector.reset()
            self._candidate_frames.clear()

        was_active = self._activity_detector.active
        transition = self._activity_detector.observe(frame)
        if not was_active:
            if (self._activity_detector.state is ActivityState.IDLE
                    and transition is None):
                self._candidate_frames.clear()
                return 0
            self._candidate_frames.append(frame)
            if transition is None:
                return 0

            pending = self._candidate_frames
            self._candidate_frames = []
            sent_bytes = 0
            for candidate in pending:
                await self._send_frame(candidate)
                sent_bytes += len(candidate.data)
            self._debug("local activity start")
            return sent_bytes

        await self._send_frame(frame)
        if transition is not None and transition.type == "activity_ended":
            self._debug("local activity end")
            await self._send_audio_stream_end()
        return len(frame.data)

    async def send_audio(self, frame: AudioFrame) -> AudioSendReceipt:
        if self._closed:
            raise ProviderError("provider_closed", "Gemini session is closed")
        async with self._send_lock:
            if self._closed:
                raise ProviderError("provider_closed", "Gemini session is closed")
            if self._terminal_send_error:
                raise ProviderError("provider_failed", "Gemini send stream is no longer usable")
            self._validator.validate(frame)
            try:
                payload_bytes = await self._send_with_turn_detection(frame)
            except asyncio.CancelledError:
                self._terminal_send_error = True
                raise
            except BaseException as error:
                self._terminal_send_error = True
                raise ProviderError("provider_send_failed",
                                    sanitized_provider_error(error), retryable=False) from None
            if self._closed:
                raise ProviderError("provider_closed", "Gemini session closed during send")
            self._validator.commit(frame)
        return send_receipt("gemini", frame, payload_bytes=payload_bytes)

    async def events(self) -> AsyncIterator[ProviderEvent]:
        if self._events_active:
            raise ProviderError("provider_event_consumer_exists",
                                "Gemini events already have a consumer")
        self._events_active = True
        try:
            while not self._closed:
                received_any = False
                async for value in self._session.receive():
                    received_any = True
                    server = getattr(value, "server_content", None)
                    transcription = getattr(server, "output_transcription", None)
                    text = getattr(transcription, "text", None) or getattr(value, "text", None)
                    audio_parts = []
                    audio_format = None
                    model_turn = getattr(server, "model_turn", None)
                    for part in getattr(model_turn, "parts", None) or []:
                        inline = getattr(part, "inline_data", None)
                        data = getattr(inline, "data", None)
                        mime = str(getattr(inline, "mime_type", ""))
                        if isinstance(data, bytes) and mime.startswith("audio/"):
                            part_format = self._output_audio_format(mime)
                            if audio_format is not None and part_format != audio_format:
                                raise ProviderError(
                                    "unsupported_provider_audio_format",
                                    "Gemini returned mixed output audio formats in one event",
                                )
                            audio_format = part_format
                            audio_parts.append(data)
                    has_response = bool(text or audio_parts or model_turn)
                    response_started = has_response and not self._response_in_progress
                    if response_started:
                        self._response_in_progress = True
                        self._debug("Gemini response start")
                    turn_complete = bool(getattr(server, "turn_complete", False))
                    if turn_complete:
                        self._debug("Gemini turn complete")
                        self._response_in_progress = False
                    event_type = ("output_transcription"
                                  if isinstance(text, str) else "message")
                    yield ProviderEvent(
                        "gemini", event_type,
                        text=text if isinstance(text, str) else None,
                        audio=b"".join(audio_parts) or None,
                        audio_format=audio_format,
                        raw=value,
                        response_started=response_started,
                        response_completed=turn_complete,
                        **self._validator.event_fields(),
                    )
                # Gemini receive iterators are turn-bounded. Re-enter after a
                # completed turn, but an immediately empty iterator means the
                # session itself has ended and avoids a busy loop.
                if not received_any:
                    return
        except asyncio.CancelledError:
            raise
        except GeneratorExit:
            return
        except ProviderError:
            raise
        except BaseException as error:
            if self._closed:
                return
            raise ProviderError("provider_receive_failed",
                                sanitized_provider_error(error), retryable=True) from None
        finally:
            self._events_active = False

    async def aclose(self) -> None:
        if self._close_task is None:
            self._closed = True
            self._close_task = asyncio.create_task(
                self._finish_close(), name="sonexis-gemini-cleanup")
        await asyncio.shield(self._close_task)

    async def _finish_close(self) -> None:
        try:
            await asyncio.wait_for(self._finish_audio_stream(), timeout=self._close_timeout)
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

    async def _finish_audio_stream(self) -> None:
        async with self._send_lock:
            self._candidate_frames.clear()
            self._activity_detector.reset()
            if self._segment_open:
                await self._send_audio_stream_end()
