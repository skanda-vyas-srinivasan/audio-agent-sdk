"""Provider-neutral reference agent built only on public AudioPlane APIs."""

import argparse
import asyncio
import json
import math
import os
import stat
import signal
import struct
import sys
import time
import wave
from collections import deque
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import AsyncIterator, Awaitable, Callable, Deque, Dict, List, Optional, Set

from sonexis import (
    AudioFormat,
    AudioFrame,
    AudioSendReceipt,
    LatencyTracker,
    ProviderError,
    ReplayStream,
    SampleFormat,
    Sonexis,
    SonexisError,
    WebRTCVoiceActivityDetector,
)
from .providers import (
    GeminiLiveSink,
    GeminiTurnDetectionConfig,
    OpenAIRealtimeSink,
    ProviderEvent,
    ProviderLifecycleEvent,
    RealtimeAudioSink,
)


GEMINI_SYSTEM_INSTRUCTION = (
    "Respond in English. Briefly summarize or respond to the audio you just heard."
)

__all__ = [
    "GEMINI_SYSTEM_INSTRUCTION", "LiveValidationTracker", "MockRealtimeSink",
    "OutputWriter", "ProviderInputForwarder", "RuntimeResponsePlayer",
    "StreamStats", "TurnValidation", "add_agent_arguments", "cli_main",
    "create_sink", "main", "parse_args", "print_provider_events",
    "required_format", "run_agent",
]


def terminal_safe(value: object) -> str:
    """Render untrusted source/provider text without terminal control sequences."""
    text = str(value)
    return "".join(
        character if ord(character) >= 0x20 and not 0x7f <= ord(character) <= 0x9f
        else f"\\u{{{ord(character):04X}}}"
        for character in text
    )


class MockRealtimeSink:
    """Offline sink that exercises the same flow as a network provider."""

    def __init__(self, audio_format: AudioFormat) -> None:
        self.required_format = audio_format
        self._events: "asyncio.Queue[Optional[ProviderEvent]]" = asyncio.Queue()
        self._frames = 0
        self._next_summary = audio_format.sample_rate * 5
        self._closed = False
        self._stream_id: Optional[str] = None
        self._last_sequence: Optional[int] = None

    async def __aenter__(self) -> "MockRealtimeSink":
        return self

    async def __aexit__(self, exc_type, exc, traceback) -> None:
        await self.aclose()

    async def send_audio(self, frame: AudioFrame) -> AudioSendReceipt:
        if self._closed:
            raise ProviderError("provider_closed", "Mock provider is closed")
        if frame.format != self.required_format:
            raise ProviderError(
                "unsupported_provider_format",
                f"Mock provider expected {self.required_format!r}; got {frame.format!r}",
            )
        expected = (frame.frame_count * frame.format.channels
                    * frame.format.sample_format.bytes_per_sample)
        if frame.frame_count < 1 or len(frame.data) != expected:
            raise ProviderError("invalid_audio", "PCM payload does not match frame metadata")
        if self._stream_id is not None and self._stream_id != frame.stream_id:
            raise ProviderError("provider_stream_mismatch",
                                "Use one mock sink per AudioPlane stream")
        if self._last_sequence is not None and frame.sequence <= self._last_sequence:
            raise ProviderError("provider_sequence_error",
                                "Audio frames must be sent in sequence order")
        self._frames += frame.frame_count
        if self._stream_id is None:
            self._stream_id = frame.stream_id
        self._last_sequence = frame.sequence
        if self._frames >= self._next_summary:
            seconds = self._frames / self.required_format.sample_rate
            # A quiet 100 ms tone makes the credential-free reference path
            # exercise provider output and AudioPlane playback deterministically.
            tone_frames = self.required_format.sample_rate // 10
            tone = b"".join(struct.pack(
                "<h", round(2_000 * math.sin(
                    2 * math.pi * 440 * index
                    / self.required_format.sample_rate)))
                * self.required_format.channels for index in range(tone_frames))
            await self._events.put(ProviderEvent(
                "mock", "mock.summary",
                text=f"received {seconds:.1f} seconds from {frame.source_name or 'replay'}",
                audio=tone, audio_format=self.required_format,
                response_started=True, response_completed=True,
                source_id=frame.source_id, session_id=frame.session_id,
                stream_id=frame.stream_id,
            ))
            self._next_summary += self.required_format.sample_rate * 5
        return AudioSendReceipt(
            "mock", frame.sequence, time.monotonic_ns(), len(frame.data),
            frame.estimated_sonexis_latency_ns,
        )

    async def events(self) -> AsyncIterator[ProviderEvent]:
        while True:
            event = await self._events.get()
            if event is None:
                return
            yield event

    async def aclose(self) -> None:
        if self._closed:
            return
        self._closed = True
        await self._events.put(None)


class OutputWriter:
    def __init__(self, path: Optional[Path], audio_format: AudioFormat) -> None:
        self._raw = None
        self._wav = None
        if path is None:
            return
        flags = os.O_WRONLY | os.O_CREAT
        if hasattr(os, "O_NONBLOCK"):
            flags |= os.O_NONBLOCK
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags, 0o600)
        status = os.fstat(descriptor)
        if not stat.S_ISREG(status.st_mode) or status.st_uid != os.geteuid():
            os.close(descriptor)
            raise ValueError("Output must be a regular file owned by the current user")
        os.fchmod(descriptor, 0o600)
        os.ftruncate(descriptor, 0)
        output = os.fdopen(descriptor, "wb")
        if path.suffix.lower() == ".wav":
            if audio_format.sample_format is not SampleFormat.PCM_S16LE:
                output.close()
                raise ValueError("WAV output requires PCM16 audio")
            self._wav = wave.open(output, "wb")
            self._wav.setnchannels(audio_format.channels)
            self._wav.setsampwidth(2)
            self._wav.setframerate(audio_format.sample_rate)
        else:
            self._raw = output

    def write(self, data: bytes) -> None:
        if self._wav is not None:
            self._wav.writeframesraw(data)
        elif self._raw is not None:
            self._raw.write(data)

    def close(self) -> None:
        if self._wav is not None:
            self._wav.close()
        if self._raw is not None:
            self._raw.close()


def _write_private_json(path: Path, value: object) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    try:
        status = os.fstat(descriptor)
        if not stat.S_ISREG(status.st_mode) or status.st_uid != os.geteuid():
            raise ValueError(
                "Validation output must be a regular file owned by the current user")
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            descriptor = -1
            output.write(json.dumps(value, indent=2, sort_keys=True) + "\n")
    finally:
        if descriptor >= 0:
            os.close(descriptor)


class StreamStats:
    def __init__(self) -> None:
        self.started = time.monotonic()
        self.frames = 0
        self.packets = 0
        self.bytes = 0
        self.dropped = 0
        self.provider_dropped = 0
        self.provider_queue_high_water = 0
        self.latency = LatencyTracker()

    def observe(self, frame: AudioFrame) -> None:
        self.frames += frame.frame_count
        self.packets += 1
        self.bytes += len(frame.data)
        self.dropped += frame.dropped_frames_before
        self.latency.observe(frame)

    def line(self) -> str:
        elapsed = time.monotonic() - self.started
        latency = self.latency.summary()
        timing = "latency=unavailable"
        if latency is not None:
            timing = (f"latency_ms(p50/p95/p99)={latency.p50_ms:.2f}/"
                      f"{latency.p95_ms:.2f}/{latency.p99_ms:.2f}")
        return (f"wall_seconds={elapsed:.1f} packets={self.packets} frames={self.frames} "
                f"bytes={self.bytes} dropped={self.dropped} "
                f"provider_dropped={self.provider_dropped} "
                f"provider_queue_hwm={self.provider_queue_high_water} {timing}")


@dataclass
class TurnValidation:
    """Privacy-safe timing and lifecycle data for one local/provider turn."""

    index: int
    activity_started_ns: Optional[int] = None
    activity_ended_ns: Optional[int] = None
    input_finalized_ns: Optional[int] = None
    response_started_ns: Optional[int] = None
    output_started_ns: Optional[int] = None
    response_completed_ns: Optional[int] = None
    response_interrupted_ns: Optional[int] = None
    output_flushed_ns: Optional[int] = None
    warnings: List[str] = field(default_factory=list)
    correlation: str = "unknown"
    candidate_segments: List[int] = field(default_factory=list)

    @staticmethod
    def _milliseconds(start: Optional[int], end: Optional[int]) -> Optional[float]:
        if start is None or end is None or end < start:
            return None
        return max(0.0, (end - start) / 1_000_000)

    def summary(self) -> Dict[str, object]:
        terminal = self.response_completed_ns or self.response_interrupted_ns
        return {
            "turn": self.index,
            "correlation": self.correlation,
            "candidate_segments": list(self.candidate_segments),
            "finalize_ms": self._milliseconds(
                self.activity_ended_ns, self.input_finalized_ns),
            "response_start_ms": self._milliseconds(
                self.input_finalized_ns, self.response_started_ns)
                if self.correlation == "single_segment_candidate" else None,
            "output_start_ms": self._milliseconds(
                self.response_started_ns, self.output_started_ns),
            "response_duration_ms": self._milliseconds(
                self.response_started_ns, terminal),
            "interrupted": self.response_interrupted_ns is not None,
            "output_flushed": self.output_flushed_ns is not None,
            "warnings": list(self.warnings),
        }


class LiveValidationTracker:
    """Correlate low-volume lifecycle events without retaining private audio."""

    def __init__(self, *, enabled: bool, output_path: Optional[Path] = None) -> None:
        self.enabled = enabled
        self.output_path = output_path
        self.turns: List[TurnValidation] = []
        self._awaiting_response: Deque[TurnValidation] = deque()
        self._current_activity: Optional[TurnValidation] = None
        self._active_response: Optional[TurnValidation] = None
        self._last_response: Optional[TurnValidation] = None
        self._responses: Dict[int, TurnValidation] = {}
        self._response_index = 0
        self.lifecycle_warnings: List[str] = []
        self.latest_stats: Optional[StreamStats] = None
        self.playback_diagnostics: Dict[str, object] = {}

    def lifecycle(self, event: ProviderLifecycleEvent) -> None:
        timestamp = event.timestamp_ns
        if event.type == "activity_started":
            if self._current_activity is not None:
                self.lifecycle_warnings.append("duplicate activity start")
                return
            turn = TurnValidation(
                index=len(self.turns) + 1, activity_started_ns=timestamp)
            self.turns.append(turn)
            self._current_activity = turn
        elif event.type == "activity_ended":
            if self._current_activity is None:
                self.lifecycle_warnings.append("activity end without start")
                return
            if self._current_activity.activity_ended_ns is not None:
                self.lifecycle_warnings.append("duplicate activity end")
                return
            self._current_activity.activity_ended_ns = timestamp
        elif event.type == "input_finalized":
            if self._current_activity is None:
                self.lifecycle_warnings.append("input finalization without activity")
                return
            if self._current_activity.input_finalized_ns is not None:
                self.lifecycle_warnings.append("duplicate input finalization")
                return
            self._current_activity.input_finalized_ns = timestamp
            if (self._current_activity.response_started_ns is None
                    and self._current_activity.correlation != "ambiguous"):
                self._awaiting_response.append(self._current_activity)
            self._current_activity = None
        elif event.type == "output_started":
            turn = (self._responses.get(event.details["response_index"])
                    if "response_index" in event.details else self._active_response)
            if turn is not None:
                turn.output_started_ns = timestamp
        elif event.type == "output_flushed":
            turn = (self._responses.get(event.details["response_index"])
                    if "response_index" in event.details
                    else self._active_response or self._last_response)
            if turn is not None:
                turn.output_flushed_ns = timestamp

    def provider_event(self, event: ProviderEvent) -> None:
        timestamp = time.monotonic_ns()
        if event.response_started:
            if self._active_response is not None:
                self.lifecycle_warnings.append("response started before prior response ended")
            candidates = list(self._awaiting_response)
            if (self._current_activity is not None
                    and self._current_activity.response_started_ns is None
                    and self._current_activity.correlation != "ambiguous"):
                candidates.append(self._current_activity)
            self._awaiting_response.clear()
            if len(candidates) == 1:
                turn = candidates[0]
                turn.correlation = ("early" if turn.input_finalized_ns is None
                                    else "single_segment_candidate")
            else:
                turn = TurnValidation(index=len(self.turns) + 1)
                turn.correlation = "ambiguous" if candidates else "unknown"
                turn.warnings.append("provider response has " + turn.correlation
                                     + " local timing correlation")
                self.turns.append(turn)
                # Consume the candidate window once. It cannot be assigned to
                # a later response by FIFO, even if a local end arrives later.
                for candidate in candidates:
                    candidate.correlation = "ambiguous"
            turn.candidate_segments = [candidate.index for candidate in candidates]
            turn.response_started_ns = timestamp
            self._active_response = turn
            self._response_index += 1
            self._responses[self._response_index] = turn
        if event.response_interrupted:
            if self._active_response is None:
                self.lifecycle_warnings.append("response interruption without active response")
            else:
                self._active_response.response_interrupted_ns = timestamp
        if event.response_completed:
            if self._active_response is None:
                self.lifecycle_warnings.append("response completion without active response")
            else:
                self._active_response.response_completed_ns = timestamp

    def response_playback_event(self, event: ProviderLifecycleEvent) -> None:
        if event.type == "playback_failed":
            if "response playback failed" not in self.lifecycle_warnings:
                self.lifecycle_warnings.append("response playback failed")
        elif event.type == "playback_diagnostics":
            self.playback_diagnostics = dict(event.details)
        else:
            self.lifecycle(event)

    def finish_provider_event(self, event: ProviderEvent) -> None:
        if ((event.response_completed or event.response_interrupted)
                and self._active_response is not None):
            self._finish_active_response()

    def _finish_active_response(self) -> None:
        turn = self._active_response
        if turn is None:
            return
        response_ms = (TurnValidation._milliseconds(
            turn.input_finalized_ns, turn.response_started_ns)
            if turn.correlation == "single_segment_candidate" else None)
        if isinstance(response_ms, float) and response_ms > 5_000:
            turn.warnings.append(
                "response arrived >5000 ms after the sole local finalization; "
                "correlation remains unproven")
        summary = turn.summary()
        warnings = summary["warnings"]
        if self.enabled:
            outcome = "WARN" if warnings else "PASS"
            fields = []
            for name in ("finalize_ms", "response_start_ms", "output_start_ms"):
                value = summary[name]
                fields.append(f"{name}={value:.0f}" if isinstance(value, float)
                              else f"{name}=n/a")
            print(f"\nValidation turn {turn.index}: {outcome} " + " ".join(fields))
        self._last_response = turn
        self._active_response = None

    def final_report(self, stats: Optional[StreamStats] = None) -> Dict[str, object]:
        capture_latency = stats.latency.summary() if stats is not None else None
        warnings = list(self.lifecycle_warnings)
        if self._current_activity is not None:
            warnings.append("session ended during local activity")
        if self._active_response is not None:
            warnings.append("session ended during provider response")
        if self._awaiting_response:
            warnings.append(
                f"{len(self._awaiting_response)} finalized segment(s) received no response; "
                "a response is not required for every local segment")
        if stats is not None and stats.provider_dropped:
            warnings.append(f"provider input dropped {stats.provider_dropped} frames")
        if capture_latency is not None and capture_latency.p95_ms > 150:
            warnings.append(
                f"capture p95 latency is {capture_latency.p95_ms:.1f} ms")
        payload: Dict[str, object] = {
            "status": "warn" if warnings or any(t.warnings for t in self.turns) else "pass",
            "turns": [turn.summary() for turn in self.turns],
            "playback": dict(self.playback_diagnostics),
            "warnings": warnings,
        }
        if stats is not None:
            payload["stream"] = {
                "packets": stats.packets,
                "frames": stats.frames,
                "runtime_dropped_frames": stats.dropped,
                "provider_dropped_frames": stats.provider_dropped,
                "provider_queue_high_water_packets": stats.provider_queue_high_water,
                "capture_latency_p95_ms": (
                    capture_latency.p95_ms if capture_latency is not None else None),
            }
        if self.output_path is not None:
            _write_private_json(self.output_path, payload)
        if self.enabled:
            print(
                f"\nLive validation: {str(payload['status']).upper()} "
                f"turns={len(self.turns)} warnings={len(warnings)}")
            for warning in warnings:
                print(f"  - {terminal_safe(warning)}")
        return payload


class ProviderInputForwarder:
    """Keep live capture current when a provider's send call stalls.

    The queue drops its oldest packets. The next delivered frame carries a
    discontinuity and the exact dropped sample-frame count, allowing local VAD
    and provider adapters to terminate stale activity rather than processing
    seconds-old audio.
    """

    def __init__(
        self,
        sink: RealtimeAudioSink,
        stats: StreamStats,
        *,
        max_queue_packets: int = 32,
        close_timeout: float = 2.0,
        on_failure: Optional[Callable[[Exception], None]] = None,
    ) -> None:
        if max_queue_packets < 1:
            raise ValueError("provider input queue limit must be positive")
        self._sink = sink
        self._stats = stats
        self._close_timeout = close_timeout
        self._on_failure = on_failure
        self._queue: "asyncio.Queue[Optional[AudioFrame]]" = asyncio.Queue(
            maxsize=max_queue_packets)
        self._pending_dropped_frames = 0
        self._paused = False
        self._closed = False
        self._failure: Optional[Exception] = None
        self._worker = asyncio.create_task(self._run())

    async def send_audio(self, frame: AudioFrame) -> None:
        if self._closed:
            raise RuntimeError("provider input forwarding is closed")
        if self._failure is not None:
            raise RuntimeError(
                f"provider input forwarding failed: {self._failure}") from self._failure
        if self._paused:
            self._record_drop(frame)
            return
        if self._queue.full():
            dropped = self._queue.get_nowait()
            self._queue.task_done()
            if dropped is not None:
                self._record_drop(dropped)
        self._queue.put_nowait(frame)
        self._stats.provider_queue_high_water = max(
            self._stats.provider_queue_high_water, self._queue.qsize())

    def pause(self) -> None:
        """Drop queued/new input while a non-interruptible response is active."""
        self._paused = True
        while True:
            try:
                frame = self._queue.get_nowait()
            except asyncio.QueueEmpty:
                break
            self._queue.task_done()
            if frame is not None:
                self._record_drop(frame)

    def resume(self) -> None:
        self._paused = False

    def _record_drop(self, frame: AudioFrame) -> None:
        self._pending_dropped_frames += frame.frame_count
        self._stats.provider_dropped += frame.frame_count

    async def _run(self) -> None:
        try:
            while True:
                frame = await self._queue.get()
                try:
                    if frame is None:
                        return
                    if self._pending_dropped_frames:
                        frame = replace(
                            frame,
                            discontinuity=True,
                            dropped_frames_before=(
                                frame.dropped_frames_before
                                + self._pending_dropped_frames),
                        )
                        self._pending_dropped_frames = 0
                    await self._sink.send_audio(frame)
                finally:
                    self._queue.task_done()
        except asyncio.CancelledError:
            raise
        except Exception as error:
            self._failure = error
            self.pause()
            if self._on_failure is not None:
                self._on_failure(error)

    async def close(self) -> None:
        if self._closed:
            return
        self._closed = True

        async def finish_worker() -> None:
            await self._queue.join()
            self._queue.put_nowait(None)
            await self._worker

        if not self._worker.done():
            try:
                await asyncio.wait_for(finish_worker(), self._close_timeout)
            except asyncio.TimeoutError:
                self._worker.cancel()
            await asyncio.gather(self._worker, return_exceptions=True)


@dataclass(frozen=True)
class _QueuedProviderAudio:
    provider: str
    data: bytes
    audio_format: AudioFormat
    finish_response: bool = False
    interrupt_response: bool = False
    epoch: int = 0
    cleanup: Optional[asyncio.Task] = None
    response_index: int = 1


class RuntimeResponsePlayer:
    """Routes provider audio through the public AudioPlane output API."""

    def __init__(
        self,
        client: Sonexis,
        destination: str,
        *,
        debug: bool,
        max_pending_bytes: int = 4 * 1024 * 1024,
        max_pending_chunks: int = 64,
        close_timeout: float = 5.0,
        on_failure: Optional[Callable[[Exception], None]] = None,
        output_chunk_milliseconds: int = 50,
        max_playback_lead_milliseconds: int = 150,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
        lifecycle_callback: Optional[
            Callable[[ProviderLifecycleEvent], None]] = None,
    ) -> None:
        if max_pending_bytes < 1 or max_pending_chunks < 1:
            raise ValueError("response playback queue limits must be positive")
        if output_chunk_milliseconds < 1:
            raise ValueError("output chunk duration must be positive")
        if max_playback_lead_milliseconds < output_chunk_milliseconds:
            raise ValueError("maximum playback lead must cover at least one chunk")
        self._client = client
        self._destination = destination
        self._debug = debug
        self._max_pending_bytes = max_pending_bytes
        self._close_timeout = close_timeout
        self._on_failure = on_failure
        self._output_chunk_milliseconds = output_chunk_milliseconds
        self._max_playback_lead_seconds = max_playback_lead_milliseconds / 1_000
        self._clock = clock
        self._sleep = sleep
        self._lifecycle_callback = lifecycle_callback
        self._output = None
        self._format: Optional[AudioFormat] = None
        self._playback_cursor: Optional[float] = None
        self._expecting_audio = False
        self._response_epoch = 0
        self._response_index = 0
        self._output_started_epoch: Optional[int] = None
        self._active_write: Optional[asyncio.Task] = None
        self._discard_tasks: Set[asyncio.Task] = set()
        self._pending_bytes = 0
        self._queue: "asyncio.Queue[Optional[_QueuedProviderAudio]]" = (
            asyncio.Queue(maxsize=max_pending_chunks))
        self._failure: Optional[Exception] = None
        self._closed = False
        self._diagnostics = {
            "provider_chunks": 0, "max_provider_chunk_interval_ms": 0.0,
            "estimated_supply_gap_ms": 0.0, "pacing_wait_ms": 0.0,
            "max_write_wait_ms": 0.0, "coalescer_timeout_flushes": 0,
            "output_sessions": 0, "interruption_flushes": 0,
            "interrupted_writes": 0, "padded_tail_frames": 0,
            "interruption_discarded_bytes": 0, "runtime_underrun_frames": 0,
            "runtime_underrun_events": 0, "runtime_dropped_frames": 0,
            "runtime_flushed_frames": 0, "runtime_route_changes": 0,
            "runtime_buffered_ms": 0.0, "runtime_target_buffer_ms": 0,
            "runtime_metrics_samples": 0, "runtime_metrics_failures": 0,
        }
        self._last_chunk_at: Optional[float] = None
        self._metrics_seen: Dict[str, int] = {}
        self._metrics_task: Optional[asyncio.Task] = None
        self._worker = asyncio.create_task(self._run())

    def _begin_response(self) -> None:
        self._response_index += 1

    @property
    def diagnostics(self) -> Dict[str, object]:
        """Bounded metadata only; estimated supply gaps are not measured sound."""
        return dict(self._diagnostics)

    def _sample_metrics(self, output) -> None:
        metrics = output.metrics
        for source, dest in (("underrun_frames", "runtime_underrun_frames"),
                ("underrun_events", "runtime_underrun_events"),
                ("dropped_frames", "runtime_dropped_frames"),
                ("flushed_frames", "runtime_flushed_frames"),
                ("route_changes", "runtime_route_changes")):
            current = getattr(metrics, source, 0)
            self._diagnostics[dest] += max(0, current - self._metrics_seen.get(source, 0))
            self._metrics_seen[source] = current
        self._diagnostics["runtime_buffered_ms"] = getattr(metrics, "buffered_milliseconds", 0)
        self._diagnostics["runtime_target_buffer_ms"] = getattr(metrics, "target_buffer_milliseconds", 0)
        self._diagnostics["runtime_metrics_samples"] += 1
        self._lifecycle("playback_diagnostics", **self.diagnostics)

    async def _poll_output_metrics(self) -> None:
        while True:
            await asyncio.sleep(.25)
            output = self._output
            if output is not None and hasattr(output, "refresh"):
                try:
                    await asyncio.wait_for(output.refresh(), 1.0)
                    if self._output is output:
                        self._sample_metrics(output)
                except Exception:
                    self._diagnostics["runtime_metrics_failures"] += 1

    def _lifecycle(self, event_type: str, **details: object) -> None:
        if self._lifecycle_callback is None:
            return
        try:
            self._lifecycle_callback(ProviderLifecycleEvent(
                "audioplane", event_type, details=details))
        except Exception:
            pass

    async def write(self, event: ProviderEvent) -> None:
        if not event.audio:
            return
        if self._closed:
            raise RuntimeError("provider response playback is closed")
        if self._failure is not None:
            raise RuntimeError(
                f"provider response playback failed: {self._failure}") from self._failure
        if event.audio_format is None:
            raise RuntimeError(
                f"{event.provider} returned audio without a declared PCM format")
        if self._format is None:
            self._format = event.audio_format
        elif event.audio_format != self._format:
            raise RuntimeError(
                f"provider response format changed from {self._format!r} "
                f"to {event.audio_format!r}")
        now = self._clock()
        self._diagnostics["provider_chunks"] += 1
        if self._last_chunk_at is not None:
            self._diagnostics["max_provider_chunk_interval_ms"] = max(
                self._diagnostics["max_provider_chunk_interval_ms"],
                (now - self._last_chunk_at) * 1_000)
        self._last_chunk_at = now
        data = bytes(event.audio)
        frame_size = (event.audio_format.channels
                      * event.audio_format.sample_format.bytes_per_sample)
        if len(data) % frame_size:
            raise RuntimeError(
                f"{event.provider} returned a partial interleaved PCM frame")
        if self._response_index == 0:
            self._response_index = 1
        await self._enqueue(_QueuedProviderAudio(
            event.provider, data, event.audio_format,
            epoch=self._response_epoch, response_index=self._response_index))
        if self._debug:
            print(
                f"\nOutput debug: buffered {len(data)} provider audio bytes "
                f"({self._pending_bytes} pending)")

    async def finish_response(self) -> None:
        """Flush a provider response's final sub-packet PCM tail."""
        if self._format is None:
            return
        self._last_chunk_at = None
        await self._enqueue(_QueuedProviderAudio(
            "provider", b"", self._format, finish_response=True,
            epoch=self._response_epoch, response_index=self._response_index))

    async def interrupt_response(self) -> None:
        """Discard queued/generated speech after a provider barge-in event."""
        if self._closed:
            raise RuntimeError("provider response playback is closed")
        if self._format is None:
            return
        self._response_epoch += 1
        self._last_chunk_at = None
        self._diagnostics["interruption_flushes"] += 1
        while True:
            try:
                item = self._queue.get_nowait()
            except asyncio.QueueEmpty:
                break
            if item is not None:
                self._pending_bytes -= len(item.data)
                self._diagnostics["interruption_discarded_bytes"] += len(item.data)
            self._queue.task_done()
        cleanup = None
        writing = self._active_write
        if writing is not None and not writing.done():
            # A flush cannot acquire the SDK's operation lock behind this write.
            # Cancellation ends its uncertain stream epoch; reopen on new audio.
            output, self._output = self._output, None
            writing.cancel()
            cleanup = asyncio.create_task(self._discard_output(output, writing))
            self._discard_tasks.add(cleanup)
            cleanup.add_done_callback(self._discard_finished)
        await self._enqueue(_QueuedProviderAudio(
            "provider", b"", self._format, interrupt_response=True,
            epoch=self._response_epoch, cleanup=cleanup,
            response_index=self._response_index))
        if cleanup is not None:
            await asyncio.shield(cleanup)

    async def _discard_output(self, output, writing: asyncio.Task) -> None:
        try:
            if output is not None:
                await output.aclose(drain=False)
                self._sample_metrics(output)
        finally:
            await asyncio.gather(writing, return_exceptions=True)

    def _discard_finished(self, task: asyncio.Task) -> None:
        self._discard_tasks.discard(task)
        if not task.cancelled():
            task.exception()

    async def _enqueue(self, item: _QueuedProviderAudio) -> None:
        if self._closed:
            raise RuntimeError("provider response playback is closed")
        if self._failure is not None:
            raise RuntimeError(
                f"provider response playback failed: {self._failure}") from self._failure
        data_size = len(item.data)
        if (self._queue.full()
                or self._pending_bytes + data_size > self._max_pending_bytes):
            raise RuntimeError(
                "provider response playback queue is full; the output destination "
                "is not consuming audio")
        self._pending_bytes += data_size
        try:
            self._queue.put_nowait(item)
        except asyncio.QueueFull as error:
            self._pending_bytes -= data_size
            raise RuntimeError(
                "provider response playback queue is full; the output destination "
                "is not consuming audio") from error

    async def _open_output(
        self, provider: str, audio_format: AudioFormat,
    ) -> None:
        if self._output is not None:
            return
        self._output = await self._client.playback(
            destination=self._destination,
            format=audio_format,
        )
        self._diagnostics["output_sessions"] += 1
        self._metrics_seen = {}
        if self._metrics_task is None:
            self._metrics_task = asyncio.create_task(self._poll_output_metrics())
        print(
            f"\nPlaying {provider} responses through "
            f"{self._output.info.destination_id} "
            f"(output session {self._output.info.id})")

    async def _write_paced(
        self, provider: str, data: bytes, audio_format: AudioFormat, epoch: int,
        response_index: int = 1,
    ) -> bool:
        if epoch != self._response_epoch:
            return False
        await self._open_output(provider, audio_format)
        frame_size = (audio_format.channels
                      * audio_format.sample_format.bytes_per_sample)
        frame_count = len(data) // frame_size
        duration = frame_count / audio_format.sample_rate
        now = self._clock()
        if (self._expecting_audio and self._playback_cursor is not None
                and self._playback_cursor < now):
            self._diagnostics["estimated_supply_gap_ms"] += (now-self._playback_cursor)*1_000
        if self._playback_cursor is None or self._playback_cursor < now:
            self._playback_cursor = now
        lead = self._playback_cursor - now
        if lead + duration > self._max_playback_lead_seconds:
            delay = lead + duration - self._max_playback_lead_seconds
            self._diagnostics["pacing_wait_ms"] += delay * 1_000
            await self._sleep(delay)
            now = self._clock()
            if self._playback_cursor < now:
                self._playback_cursor = now
        if epoch != self._response_epoch:
            return False
        writing = asyncio.create_task(self._output.write(data))
        self._active_write = writing
        write_started = self._clock()
        try:
            await writing
        except asyncio.CancelledError:
            if epoch != self._response_epoch and not self._closed:
                self._diagnostics["interrupted_writes"] += 1
                return False
            raise
        finally:
            self._diagnostics["max_write_wait_ms"] = max(
                self._diagnostics["max_write_wait_ms"], (self._clock()-write_started)*1_000)
            if self._active_write is writing:
                self._active_write = None
        if epoch != self._response_epoch:
            return False
        self._playback_cursor += duration
        self._expecting_audio = True
        if self._output_started_epoch != response_index:
            self._output_started_epoch = response_index
            self._lifecycle("output_started", epoch=epoch, response_index=response_index)
        return True

    async def _flush_audio(
        self,
        pending: bytearray,
        provider: str,
        audio_format: AudioFormat,
        epoch: int,
        *,
        final: bool,
        response_index: int = 1,
    ) -> None:
        frame_size = (audio_format.channels
                      * audio_format.sample_format.bytes_per_sample)
        minimum_bytes = max(1, audio_format.sample_rate // 1_000) * frame_size
        chunk_frames = max(
            1,
            audio_format.sample_rate * self._output_chunk_milliseconds // 1_000,
        )
        chunk_bytes = chunk_frames * frame_size
        while len(pending) >= chunk_bytes:
            if epoch != self._response_epoch:
                self._diagnostics["interruption_discarded_bytes"] += len(pending)
                pending.clear()
                return
            chunk = bytes(pending[:chunk_bytes])
            del pending[:chunk_bytes]
            if not await self._write_paced(
                    provider, chunk, audio_format, epoch, response_index):
                self._diagnostics["interruption_discarded_bytes"] += len(chunk)+len(pending)
                pending.clear()
                return
        if final and pending:
            if epoch != self._response_epoch:
                self._diagnostics["interruption_discarded_bytes"] += len(pending)
                pending.clear()
                return
            if len(pending) < minimum_bytes:
                self._diagnostics["padded_tail_frames"] += (minimum_bytes-len(pending))//frame_size
                pending.extend(b"\0" * (minimum_bytes - len(pending)))
            chunk = bytes(pending)
            pending.clear()
            if not await self._write_paced(provider, chunk, audio_format, epoch, response_index):
                self._diagnostics["interruption_discarded_bytes"] += len(chunk)

    async def _run(self) -> None:
        pending = bytearray()
        pending_provider = "provider"
        pending_response_index = 1
        pending_deadline: Optional[float] = None
        loop = asyncio.get_running_loop()
        try:
            while True:
                try:
                    if pending and self._queue.empty():
                        remaining = pending_deadline - loop.time()
                        if remaining <= 0:
                            raise asyncio.TimeoutError
                        item = await asyncio.wait_for(self._queue.get(), remaining)
                    else:
                        item = await self._queue.get()
                except asyncio.TimeoutError:
                    self._diagnostics["coalescer_timeout_flushes"] += 1
                    await self._flush_audio(pending, pending_provider, self._format,
                                            self._response_epoch, final=True,
                                            response_index=pending_response_index)
                    continue
                try:
                    if item is None:
                        if self._format is not None:
                            await self._flush_audio(
                                pending, pending_provider, self._format,
                                self._response_epoch, final=True,
                                response_index=pending_response_index)
                        return
                    if item.interrupt_response:
                        self._diagnostics["interruption_discarded_bytes"] += len(pending)
                        pending.clear()
                        self._playback_cursor = None
                        self._expecting_audio = False
                        self._output_started_epoch = None
                        if item.cleanup is not None:
                            await asyncio.shield(item.cleanup)
                        elif self._output is not None:
                            await self._output.flush()
                        self._lifecycle("output_flushed", epoch=item.epoch,
                                        response_index=item.response_index)
                        continue
                    if item.epoch != self._response_epoch:
                        continue
                    if item.data:
                        pending_provider = item.provider
                        pending_response_index = item.response_index
                        if not pending:
                            pending_deadline = loop.time() + self._output_chunk_milliseconds / 1_000
                        pending.extend(item.data)
                    await self._flush_audio(
                        pending,
                        pending_provider,
                        item.audio_format,
                        item.epoch,
                        final=item.finish_response,
                        response_index=pending_response_index,
                    )
                    if item.finish_response:
                        self._expecting_audio = False
                finally:
                    if item is not None:
                        self._pending_bytes -= len(item.data)
                    self._queue.task_done()
        except asyncio.CancelledError:
            raise
        except Exception as error:
            self._failure = error
            while True:
                try:
                    item = self._queue.get_nowait()
                except asyncio.QueueEmpty:
                    break
                if item is not None:
                    self._pending_bytes -= len(item.data)
                self._queue.task_done()
            self._lifecycle("playback_failed", error_type=type(error).__name__)
            if self._on_failure is not None:
                self._on_failure(error)

    async def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        drain = self._failure is None
        async def finish_worker() -> None:
            await self._queue.join()
            self._queue.put_nowait(None)
            await self._worker

        if not self._worker.done():
            try:
                await asyncio.wait_for(finish_worker(), self._close_timeout)
            except asyncio.TimeoutError:
                drain = False
                self._worker.cancel()
            await asyncio.gather(self._worker, return_exceptions=True)
        if self._metrics_task is not None:
            self._metrics_task.cancel()
            await asyncio.gather(self._metrics_task, return_exceptions=True)
        output, self._output = self._output, None
        await asyncio.gather(*tuple(self._discard_tasks), return_exceptions=True)
        if output is not None:
            await output.aclose(drain=drain)
            self._sample_metrics(output)
            if self._debug:
                print(f"\nOutput diagnostics: {json.dumps(self.diagnostics, sort_keys=True)}")


def add_agent_arguments(
    parser: argparse.ArgumentParser, *, include_socket: bool = True,
) -> None:
    """Add the shared agent options to an argparse parser."""
    parser.add_argument("--provider", choices=("mock", "openai", "gemini"), default="mock")
    parser.add_argument("--source", help="source ID, bundle ID, PID, or exact app name")
    if include_socket:
        parser.add_argument("--socket", help="Runtime control socket path")
    parser.add_argument("--output", type=Path, help="optional PCM or .wav recording")
    parser.add_argument(
        "--response-output", metavar="DESTINATION",
        help="route generated provider audio through AudioPlane (for example: default)")
    parser.add_argument(
        "--play-response", action="store_const", const="default",
        dest="response_output",
        help="shorthand for --response-output default")
    parser.add_argument("--replay", type=Path, help="use a PCM16 WAV/PCM file instead of live capture")
    parser.add_argument("--sample-rate", type=int, default=16_000,
                        help="mock/raw-replay rate; provider modes use their required preset")
    parser.add_argument("--channels", type=int, choices=(1, 2), default=1,
                        help="mock/raw-replay channels")
    parser.add_argument("--realtime-replay", action="store_true",
                        help="pace replay according to recorded timestamps")
    parser.add_argument("--non-interactive", action="store_true",
                        help="disable switch/quit prompt (requires --source for live capture)")
    parser.add_argument("--debug", action="store_true",
                        help="show provider lifecycle and raw output-audio diagnostics")
    parser.add_argument(
        "--validate-live", action="store_true",
        help="print privacy-safe per-turn timing and lifecycle validation")
    parser.add_argument(
        "--validation-json", type=Path, metavar="PATH",
        help="write privacy-safe live validation results as JSON")
    parser.add_argument("--gemini-start-threshold", type=float, default=0.015,
                        help="normalized RMS required to begin local Gemini activity")
    parser.add_argument("--gemini-end-threshold", type=float, default=0.008,
                        help="normalized RMS below which Gemini silence accumulates")
    parser.add_argument("--gemini-min-activity-ms", type=float, default=100.0,
                        help="activity required before opening a Gemini turn")
    parser.add_argument("--gemini-silence-ms", type=float, default=1_200.0,
                        help="continuous local silence required to finalize a Gemini turn")
    parser.add_argument("--gemini-onset-gap-ms", type=float, default=100.0,
                        help="brief non-speech gaps tolerated while confirming an onset")
    parser.add_argument("--gemini-vad", choices=("webrtc", "energy"), default="webrtc",
                        help="local speech classifier (default: webrtc; energy is loudness only)")
    parser.add_argument("--gemini-vad-mode", type=int, choices=(0, 1, 2, 3), default=2,
                        help="WebRTC noise filtering aggressiveness, from 0 to 3 (default: 2)")
    parser.add_argument(
        "--gemini-barge-in", action="store_true",
        help="allow new source activity to interrupt an active Gemini response")
    parser.add_argument(
        "--gemini-model",
        default=os.environ.get(
            "GEMINI_LIVE_MODEL", "gemini-3.1-flash-live-preview"),
        help=("Gemini Live model (default: gemini-3.1-flash-live-preview; "
              "GEMINI_LIVE_MODEL also supported)"))


def parse_args(argv=None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Feed a source-aware AudioPlane stream to a realtime AI provider.")
    add_agent_arguments(parser)
    return parser.parse_args(argv)


async def create_sink(
    args: argparse.Namespace,
    lifecycle_callback: Optional[
        Callable[[ProviderLifecycleEvent], None]] = None,
) -> RealtimeAudioSink:
    if args.provider == "openai":
        return await OpenAIRealtimeSink.connect()
    if args.provider == "gemini":
        turn_detection = GeminiTurnDetectionConfig(
            activity_start_threshold=args.gemini_start_threshold,
            activity_end_threshold=args.gemini_end_threshold,
            minimum_activity_ms=args.gemini_min_activity_ms,
            silence_duration_ms=args.gemini_silence_ms,
            onset_gap_ms=args.gemini_onset_gap_ms,
            allow_response_interruptions=args.gemini_barge_in,
        )
        debug_callback = ((lambda message: print(f"\nGemini debug: {message}"))
                          if args.debug else None)
        detector = None
        if args.gemini_vad == "webrtc":
            try:
                detector = WebRTCVoiceActivityDetector(mode=args.gemini_vad_mode)
            except ImportError as error:
                raise ProviderError("missing_dependency", str(error)) from error
        if debug_callback is not None:
            debug_callback(
                f"local detector={args.gemini_vad} "
                f"onset_ms={args.gemini_min_activity_ms:g} "
                f"onset_gap_ms={args.gemini_onset_gap_ms:g} "
                f"pause_ms={args.gemini_silence_ms:g}")
        return await GeminiLiveSink.connect(
            model=args.gemini_model,
            system_instruction=GEMINI_SYSTEM_INSTRUCTION,
            turn_detection=turn_detection,
            voice_activity_detector=detector,
            debug_callback=debug_callback,
            lifecycle_callback=lifecycle_callback,
        )
    return MockRealtimeSink(AudioFormat(
        args.sample_rate, args.channels, SampleFormat.PCM_S16LE))


def required_format(args: argparse.Namespace) -> AudioFormat:
    if args.provider == "openai":
        return AudioFormat.openai_realtime()
    if args.provider == "gemini":
        return AudioFormat.gemini_live()
    return AudioFormat(args.sample_rate, args.channels, SampleFormat.PCM_S16LE)


PROVIDER_CLOSE_TIMEOUT = 7.0
OUTPUT_CLOSE_TIMEOUT = 8.0


async def close_provider_session(
    sink: RealtimeAudioSink,
    event_task: "asyncio.Task[None]",
) -> None:
    """Finalize provider input, then bound the wait for trailing responses."""
    try:
        await asyncio.wait_for(sink.aclose(), timeout=PROVIDER_CLOSE_TIMEOUT)
        try:
            await asyncio.wait_for(asyncio.shield(event_task), timeout=1.0)
        except asyncio.TimeoutError:
            pass
    finally:
        if not event_task.done():
            event_task.cancel()
        await asyncio.gather(event_task, return_exceptions=True)


async def choose_source(client: Sonexis, selector: Optional[str] = None):
    if selector:
        if selector.isdecimal():
            return await client.get_source(int(selector))
        return await client.get_source(selector)
    sources = [source for source in await client.sources() if source.available]
    if not sources:
        raise RuntimeError("No available audio sources")
    print("\nAvailable sources:\n")
    for index, source in enumerate(sources, 1):
        bundle = f" [{source.bundle_identifier}]" if source.bundle_identifier else ""
        print(f"  [{index}] {terminal_safe(source.name)}{terminal_safe(bundle)}")
    answer = (await console_input("\nSelect source: ")).strip()
    try:
        return sources[int(answer) - 1]
    except (ValueError, IndexError) as error:
        raise RuntimeError("Invalid source selection") from error


async def print_provider_events(
    sink: RealtimeAudioSink,
    done: asyncio.Event,
    *,
    debug: bool = False,
    response_player: Optional[RuntimeResponsePlayer] = None,
    input_forwarder: Optional[ProviderInputForwarder] = None,
    validation: Optional[LiveValidationTracker] = None,
) -> None:
    try:
        async for event in sink.events():
            if validation is not None:
                validation.provider_event(event)
            if event.response_started and response_player is not None:
                begin = getattr(response_player, "_begin_response", None)
                if begin is not None:
                    begin()
            if event.response_started and input_forwarder is not None:
                input_forwarder.pause()
            if event.text:
                print(f"\nAgent ({terminal_safe(event.provider)}): {terminal_safe(event.text)}")
            if event.audio and response_player is not None:
                await response_player.write(event)
            elif event.audio and debug:
                print(f"\nAgent ({event.provider}): received {len(event.audio)} audio bytes")
            if event.response_completed and response_player is not None:
                await response_player.finish_response()
            if event.response_interrupted and response_player is not None:
                await response_player.interrupt_response()
            if ((event.response_completed or event.response_interrupted)
                    and input_forwarder is not None):
                input_forwarder.resume()
            if validation is not None:
                validation.finish_provider_event(event)
            if (debug and not event.text and not event.audio
                    and event.type not in {"session.started", "session.updated"}):
                print(f"\nProvider event: {terminal_safe(event.type)}")
    except ProviderError as error:
        if validation is not None:
            validation.lifecycle_warnings.append("provider receive failed")
        done.set()
        print(f"\nProvider receive failed: {terminal_safe(error.message)} (retryable={error.retryable})")
    except (OSError, RuntimeError, SonexisError) as error:
        done.set()
        if validation is not None and "response playback failed" not in validation.lifecycle_warnings:
            validation.lifecycle_warnings.append("response playback failed")
        print(f"\nResponse playback failed: {terminal_safe(error)}")


async def report_stats(stats: StreamStats, done: asyncio.Event) -> None:
    while not done.is_set():
        try:
            await asyncio.wait_for(done.wait(), timeout=2.0)
        except asyncio.TimeoutError:
            print(f"\nStream: {stats.line()}")


async def console_input(prompt: str) -> str:
    """Read a terminal line without leaving an uncancellable executor thread."""
    print(prompt, end="", flush=True)
    loop = asyncio.get_running_loop()
    future = loop.create_future()
    descriptor = sys.stdin.fileno()

    def readable() -> None:
        loop.remove_reader(descriptor)
        line = sys.stdin.readline()
        if not future.done():
            future.set_result(line)

    loop.add_reader(descriptor, readable)
    try:
        return await future
    finally:
        loop.remove_reader(descriptor)


async def read_command() -> str:
    while True:
        raw = await console_input("\n[s]witch source, [q]uit: ")
        if not raw:
            return "quit"
        value = raw.strip().lower()
        if value in {"s", "switch", "q", "quit"}:
            return "switch" if value.startswith("s") else "quit"


async def watch_source(client: Sonexis, source_id: str) -> str:
    subscription = await client.events([
        "source_removed", "capture_failed", "runtime_shutting_down",
    ])
    async with subscription:
        async for event in subscription:
            if event.type == "runtime_shutting_down":
                print("\nRuntime is shutting down")
                return "quit"
            if event.source_id == source_id:
                detail = f": {event.message}" if event.message else ""
                print(f"\nSource event: {terminal_safe(event.type)}{terminal_safe(detail)}")
                return "source-ended"
    return "source-ended"


async def consume(
    stream: AsyncIterator[AudioFrame],
    sink,
    output: OutputWriter,
    stats: StreamStats,
    done: asyncio.Event,
) -> str:
    try:
        async for frame in stream:
            if done.is_set():
                return "quit"
            stats.observe(frame)
            await asyncio.to_thread(output.write, frame.data)
            await sink.send_audio(frame)
    except asyncio.CancelledError:
        raise
    except ProviderError as error:
        print(f"\nProvider send failed: {terminal_safe(error.message)} (retryable={error.retryable})")
        return "quit"
    except SonexisError as error:
        print(f"\nAudio stream failed: {terminal_safe(error.message)} (retryable={error.retryable})")
        return "source-ended"
    print("\nAudio stream ended")
    return "source-ended"


async def run_live(
    args: argparse.Namespace,
    output: OutputWriter,
    done: asyncio.Event,
    response_player: Optional[RuntimeResponsePlayer],
    validation: LiveValidationTracker,
) -> StreamStats:
    if args.non_interactive and not args.source:
        raise RuntimeError("--non-interactive live capture requires --source")
    async with Sonexis(args.socket, client_name="audioplane-agent") as client:
        selector = args.source
        while not done.is_set():
            source = await choose_source(client, selector)
            selector = None
            stats = StreamStats()
            validation.latest_stats = stats
            sink = await create_sink(args, validation.lifecycle)
            def provider_input_failed(error: Exception) -> None:
                if isinstance(error, ProviderError):
                    detail = f"{error.message} (retryable={error.retryable})"
                else:
                    detail = str(error)
                done.set()
                validation.lifecycle_warnings.append("provider send failed")
                print(f"\nProvider send failed: {terminal_safe(detail)}")

            input_forwarder = ProviderInputForwarder(
                sink, stats, on_failure=provider_input_failed)
            provider_events = asyncio.create_task(print_provider_events(
                sink,
                done,
                debug=args.debug,
                response_player=response_player,
                input_forwarder=(
                    None if args.gemini_barge_in else input_forwarder),
                validation=validation,
            ))
            try:
                async with await client.capture(source, format=sink.required_format) as stream:
                    print(f"\nListening to {terminal_safe(source.name)} ({terminal_safe(source.id)})")
                    print(f"session={terminal_safe(stream.info.id)} stream={terminal_safe(stream.info.stream_id)}")
                    tasks = {
                        asyncio.create_task(consume(
                            stream, input_forwarder, output, stats, done)),
                        asyncio.create_task(watch_source(client, source.id)),
                        asyncio.create_task(report_stats(stats, done)),
                        asyncio.create_task(done.wait()),
                    }
                    if not args.non_interactive:
                        tasks.add(asyncio.create_task(read_command()))
                    try:
                        completed, _ = await asyncio.wait(
                            tasks, return_when=asyncio.FIRST_COMPLETED)
                        result = "quit"
                        for task in completed:
                            value = task.result()
                            if isinstance(value, str):
                                result = value
                                break
                    finally:
                        for task in tasks:
                            if not task.done():
                                task.cancel()
                        await asyncio.gather(*tasks, return_exceptions=True)
            finally:
                try:
                    await input_forwarder.close()
                finally:
                    await close_provider_session(sink, provider_events)
            print(f"Final stream stats: {stats.line()}")
            if result == "switch":
                continue
            if result == "source-ended" and not args.non_interactive:
                answer = (await console_input(
                    "Source ended. Select another source? [y/N]: ")).strip().lower()
                if answer in {"y", "yes"}:
                    continue
            return stats
    return StreamStats()


async def run_replay(
    args: argparse.Namespace,
    sink: RealtimeAudioSink,
    output: OutputWriter,
    done: asyncio.Event,
    validation: Optional[LiveValidationTracker] = None,
) -> StreamStats:
    assert args.replay is not None
    if args.replay.suffix.lower() == ".wav":
        stream = ReplayStream.from_wav(args.replay, realtime=args.realtime_replay)
    else:
        stream = ReplayStream.from_pcm(
            args.replay, format=AudioFormat(args.sample_rate, args.channels),
            realtime=args.realtime_replay)
    if stream.format != sink.required_format:
        await stream.aclose()
        raise RuntimeError(
            f"Replay format {stream.format!r} does not match {args.provider} "
            f"format {sink.required_format!r}")
    stats = StreamStats()
    if validation is not None:
        validation.latest_stats = stats
    async with stream:
        print(f"Replaying {args.replay} as source {stream.source.id}")
        await consume(stream, sink, output, stats, done)
    print(f"Final replay stats: {stats.line()}")
    return stats


async def run_agent(args: argparse.Namespace) -> int:
    """Run one agent session from an already parsed configuration."""
    done = asyncio.Event()
    loop = asyncio.get_running_loop()
    main_task = asyncio.current_task()
    signal_received = False
    def request_shutdown() -> None:
        nonlocal signal_received
        if not signal_received:
            signal_received = True
            done.set()
            # Wake setup/source-selection/playback waits as well as capture.
            main_task.cancel()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, request_shutdown)

    response_client: Optional[Sonexis] = None
    response_player: Optional[RuntimeResponsePlayer] = None
    validation = LiveValidationTracker(
        enabled=args.validate_live,
        output_path=args.validation_json,
    )
    final_stats: Optional[StreamStats] = None
    try:
        if args.response_output:
            response_client = Sonexis(
                args.socket, client_name="audioplane-agent-output")
            await response_client.connect()
            def response_playback_failed(error: Exception) -> None:
                done.set()
                if "response playback failed" not in validation.lifecycle_warnings:
                    validation.lifecycle_warnings.append("response playback failed")
                print(f"\nResponse playback failed: {terminal_safe(error)}")

            response_player = RuntimeResponsePlayer(
                response_client,
                args.response_output,
                debug=args.debug,
                on_failure=response_playback_failed,
                lifecycle_callback=validation.response_playback_event,
            )
        output = OutputWriter(args.output, required_format(args))
        try:
            if args.replay:
                sink = await create_sink(args, validation.lifecycle)
                provider_events = asyncio.create_task(print_provider_events(
                    sink, done, debug=args.debug, response_player=response_player,
                    validation=validation))
                try:
                    final_stats = await run_replay(args, sink, output, done, validation)
                finally:
                    await close_provider_session(sink, provider_events)
            else:
                final_stats = await run_live(
                    args, output, done, response_player, validation)
        finally:
            done.set()
            output.close()
    except asyncio.CancelledError:
        if not signal_received:
            validation.lifecycle_warnings.append("session cancelled")
            raise
    except BrokenPipeError:
        # tee may exit on terminal SIGINT before the agent finishes cleanup.
        # The private report is independent of the terminal output's lifetime.
        done.set()
    except BaseException:
        validation.lifecycle_warnings.append("session failed")
        raise
    finally:
        done.set()
        try:
            if response_player is not None:
                try:
                    await asyncio.wait_for(response_player.close(), OUTPUT_CLOSE_TIMEOUT)
                except Exception as error:
                    validation.lifecycle_warnings.append(
                        "output cleanup " + type(error).__name__)
            if response_client is not None:
                try:
                    await asyncio.wait_for(response_client.close(), 5.0)
                except Exception as error:
                    validation.lifecycle_warnings.append(
                        "output client cleanup " + type(error).__name__)
        finally:
            for sig in (signal.SIGINT, signal.SIGTERM):
                loop.remove_signal_handler(sig)
            # Persist even when setup, provider teardown or output cleanup fails.
            # Write before printing: stdout may already have closed with tee.
            try:
                validation.final_report(final_stats or validation.latest_stats)
            except BrokenPipeError:
                pass
    return 0


async def main(argv=None) -> int:
    """Parse arguments and run the reference agent."""
    return await run_agent(parse_args(argv))


def cli_main(argv=None) -> None:
    """Synchronous console-script entry point."""
    try:
        result = asyncio.run(main(argv))
    except BrokenPipeError:
        result = 0
    except (OSError, RuntimeError, SonexisError, ValueError) as error:
        raise SystemExit(f"error: {error}") from error
    try:
        sys.stdout.flush()
    except BrokenPipeError:
        # Avoid another failure during the interpreter's buffered flush.
        descriptor = os.open(os.devnull, os.O_WRONLY)
        try:
            os.dup2(descriptor, sys.stdout.fileno())
        finally:
            os.close(descriptor)
    raise SystemExit(result)


if __name__ == "__main__":
    cli_main()
