"""Optional consumer-side audio activity primitives; never used on the HAL callback."""

import math
import struct
from dataclasses import dataclass
from enum import Enum
from typing import Optional, Protocol

from .models import AudioFrame, SampleFormat


@dataclass(frozen=True)
class AudioActivity:
    rms: float
    peak: float
    active: bool


class VoiceActivityDetector(Protocol):
    """Extension point for an application-provided VAD implementation."""

    def is_speech(self, frame: AudioFrame) -> bool:
        ...


class ActivityState(str, Enum):
    """Consumer-side activity detector state."""

    IDLE = "idle"
    STARTING = "starting"
    ACTIVE = "active"


@dataclass(frozen=True)
class ActivityDetectionConfig:
    """Hysteresis/debounce for provider-neutral audio activity edges."""

    activity_start_threshold: float = 0.015
    activity_end_threshold: float = 0.008
    minimum_activity_ms: float = 250.0
    silence_duration_ms: float = 1_200.0

    def __post_init__(self) -> None:
        values = (self.activity_start_threshold, self.activity_end_threshold,
                  self.minimum_activity_ms, self.silence_duration_ms)
        if not all(math.isfinite(value) for value in values):
            raise ValueError("activity detection values must be finite")
        if not 0 <= self.activity_end_threshold <= self.activity_start_threshold <= 1:
            raise ValueError("activity thresholds must satisfy 0 <= end <= start <= 1")
        if not 0 < self.minimum_activity_ms <= 5_000:
            raise ValueError("minimum_activity_ms must be in (0, 5000]")
        if not 0 < self.silence_duration_ms <= 30_000:
            raise ValueError("silence_duration_ms must be in (0, 30000]")


@dataclass(frozen=True)
class ActivityEvent:
    """One edge from an :class:`AudioActivityDetector`."""

    type: str
    timestamp_ns: int
    sequence: int
    source_id: Optional[str]
    session_id: Optional[str]
    stream_id: str


class AudioActivityDetector:
    """Detect edge-triggered activity on an SDK consumer thread.

    The built-in detector measures signal energy, not speech. Supplying a
    ``VoiceActivityDetector`` changes only the per-frame classification; the
    same start/end debounce remains in force.
    """

    def __init__(self, config: ActivityDetectionConfig = ActivityDetectionConfig(), *,
                 voice_activity_detector: Optional[VoiceActivityDetector] = None) -> None:
        self.config = config
        self.voice_activity_detector = voice_activity_detector
        self.state = ActivityState.IDLE
        self.candidate_duration_ms = 0.0
        self.silence_duration_ms = 0.0
        self._stream_id: Optional[str] = None

    @property
    def active(self) -> bool:
        return self.state is ActivityState.ACTIVE

    def reset(self) -> None:
        self.state = ActivityState.IDLE
        self.candidate_duration_ms = 0.0
        self.silence_duration_ms = 0.0

    def observe(self, frame: AudioFrame) -> Optional[ActivityEvent]:
        if self._stream_id is None:
            self._stream_id = frame.stream_id
        elif self._stream_id != frame.stream_id:
            raise ValueError("Use one AudioActivityDetector per Sonexis stream")
        if frame.discontinuity:
            self.reset()
        duration_ms = frame.frame_count * 1_000.0 / frame.format.sample_rate
        if self.voice_activity_detector is not None:
            frame_active = bool(self.voice_activity_detector.is_speech(frame))
        else:
            threshold = (self.config.activity_end_threshold if self.active
                         else self.config.activity_start_threshold)
            frame_active = measure_activity(frame, threshold=threshold).active

        if not self.active:
            if not frame_active:
                self.state = ActivityState.IDLE
                self.candidate_duration_ms = 0.0
                return None
            self.state = ActivityState.STARTING
            self.candidate_duration_ms += duration_ms
            if self.candidate_duration_ms < self.config.minimum_activity_ms:
                return None
            self.state = ActivityState.ACTIVE
            self.candidate_duration_ms = 0.0
            self.silence_duration_ms = 0.0
            return self._event("activity_started", frame)

        if frame_active:
            self.silence_duration_ms = 0.0
            return None
        self.silence_duration_ms += duration_ms
        if self.silence_duration_ms < self.config.silence_duration_ms:
            return None
        self.reset()
        return self._event("activity_ended", frame)

    @staticmethod
    def _event(event_type: str, frame: AudioFrame) -> ActivityEvent:
        return ActivityEvent(event_type, frame.timestamp_ns, frame.sequence,
                             frame.source_id, frame.session_id, frame.stream_id)


def measure_activity(frame: AudioFrame, *, threshold: float = 0.01) -> AudioActivity:
    """Measure normalized signal energy; `active` means non-silent, not speech."""
    if not math.isfinite(threshold) or not 0 <= threshold <= 1:
        raise ValueError("threshold must be finite and between zero and one")
    if not frame.data:
        return AudioActivity(0.0, 0.0, False)
    if frame.format.sample_format is SampleFormat.PCM_S16LE:
        samples = (value[0] / 32768.0 for value in struct.iter_unpack("<h", frame.data))
    else:
        samples = (float(value[0]) for value in struct.iter_unpack("<f", frame.data))
    total = peak = 0.0
    count = 0
    for sample in samples:
        magnitude = abs(sample)
        peak = max(peak, magnitude)
        total += sample * sample
        count += 1
    rms = math.sqrt(total / count) if count else 0.0
    return AudioActivity(rms, peak, rms >= threshold)
