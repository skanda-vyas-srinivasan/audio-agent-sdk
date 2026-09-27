"""Optional Gemini Live adapter using the official `google-genai` SDK."""

import os
import asyncio
import inspect
import sys
from dataclasses import dataclass
from typing import Any, AsyncIterator, Callable, List, Optional

from ..activity import VoiceActivityDetector, measure_activity
from ..diagnostics import AudioSendReceipt, send_receipt
from ..errors import ProviderError, sanitized_provider_error
from ..models import AudioFormat, AudioFrame
from .base import ProviderEvent


@dataclass(frozen=True)
class GeminiTurnDetectionConfig:
    """Client-side end detection used alongside Gemini's automatic VAD."""

    enabled: bool = True
    activity_start_threshold: float = 0.015
    activity_end_threshold: float = 0.008
    minimum_activity_ms: float = 250.0
    silence_duration_ms: float = 1_200.0

    def __post_init__(self) -> None:
        if not 0 <= self.activity_end_threshold <= self.activity_start_threshold <= 1:
            raise ValueError(
                "Gemini activity thresholds must satisfy 0 <= end <= start <= 1")
        if not 0 < self.minimum_activity_ms <= 5_000:
            raise ValueError("minimum_activity_ms must be in (0, 5000]")
        if not 0 < self.silence_duration_ms <= 30_000:
            raise ValueError("silence_duration_ms must be in (0, 30000]")


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
        self._stream_id: Optional[str] = None
        self._last_sequence: Optional[int] = None
        self._turn_detection = turn_detection or GeminiTurnDetectionConfig()
        self._voice_activity_detector = voice_activity_detector
        self._debug_callback = debug_callback
        self._turn_state = "idle"
        self._candidate_duration_ms = 0.0
        self._candidate_frames: List[AudioFrame] = []
        self._silence_duration_ms = 0.0
        self._segment_open = False
        self._response_in_progress = False

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
                                sanitized_provider_error(error), retryable=True) from error

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

    def _debug(self, message: str) -> None:
        if self._debug_callback is not None:
            try:
                self._debug_callback(message)
            except Exception:
                pass

    def _is_active(self, frame: AudioFrame, *, starting: bool) -> bool:
        if self._voice_activity_detector is not None:
            return bool(self._voice_activity_detector.is_speech(frame))
        threshold = (self._turn_detection.activity_start_threshold if starting
                     else self._turn_detection.activity_end_threshold)
        return measure_activity(frame, threshold=threshold).active

    @staticmethod
    def _duration_ms(frame: AudioFrame) -> float:
        return frame.frame_count * 1_000.0 / frame.format.sample_rate

    async def _send_frame(self, frame: AudioFrame) -> None:
        blob = self._blob_factory(data=frame.data, mime_type="audio/pcm;rate=16000")
        await self._session.send_realtime_input(audio=blob)

    async def _send_audio_stream_end(self) -> None:
        await self._session.send_realtime_input(audio_stream_end=True)
        self._segment_open = False
        self._debug("audio_stream_end sent")

    async def _send_with_turn_detection(self, frame: AudioFrame) -> int:
        config = self._turn_detection
        if not config.enabled:
            await self._send_frame(frame)
            self._segment_open = True
            return len(frame.data)

        duration_ms = self._duration_ms(frame)
        if self._turn_state != "active":
            if not self._is_active(frame, starting=True):
                self._turn_state = "idle"
                self._candidate_duration_ms = 0.0
                self._candidate_frames.clear()
                return 0
            self._turn_state = "starting"
            self._candidate_duration_ms += duration_ms
            self._candidate_frames.append(frame)
            if self._candidate_duration_ms < config.minimum_activity_ms:
                return 0

            pending = self._candidate_frames
            self._candidate_frames = []
            self._candidate_duration_ms = 0.0
            sent_bytes = 0
            for candidate in pending:
                await self._send_frame(candidate)
                sent_bytes += len(candidate.data)
            self._turn_state = "active"
            self._silence_duration_ms = 0.0
            self._segment_open = True
            self._debug("local activity start")
            return sent_bytes

        await self._send_frame(frame)
        self._segment_open = True
        if self._is_active(frame, starting=False):
            self._silence_duration_ms = 0.0
            return len(frame.data)

        self._silence_duration_ms += duration_ms
        if self._silence_duration_ms >= config.silence_duration_ms:
            self._debug("local activity end")
            await self._send_audio_stream_end()
            self._turn_state = "idle"
            self._silence_duration_ms = 0.0
        return len(frame.data)

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
                payload_bytes = await self._send_with_turn_detection(frame)
            except asyncio.CancelledError:
                raise
            except BaseException as error:
                raise ProviderError("provider_send_failed",
                                    sanitized_provider_error(error), retryable=True) from error
            if self._closed:
                raise ProviderError("provider_closed", "Gemini session closed during send")
            self._last_sequence = frame.sequence
        return send_receipt("gemini", frame, payload_bytes=payload_bytes)

    async def events(self) -> AsyncIterator[ProviderEvent]:
        try:
            async for value in self._session.receive():
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
                if has_response and not self._response_in_progress:
                    self._response_in_progress = True
                    self._debug("Gemini response start")
                turn_complete = bool(getattr(server, "turn_complete", False))
                if turn_complete:
                    self._debug("Gemini turn complete")
                    self._response_in_progress = False
                event_type = "output_transcription" if isinstance(text, str) else "message"
                yield ProviderEvent("gemini", event_type,
                                    text=text if isinstance(text, str) else None,
                                    audio=b"".join(audio_parts) or None,
                                    audio_format=audio_format,
                                    raw=value)
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
                                sanitized_provider_error(error), retryable=True) from error

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
            if self._segment_open:
                await self._send_audio_stream_end()
