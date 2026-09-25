"""Optional consumer-side audio activity primitives; never used on the HAL callback."""

import math
import struct
from dataclasses import dataclass
from typing import Protocol

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


def measure_activity(frame: AudioFrame, *, threshold: float = 0.01) -> AudioActivity:
    """Measure normalized signal energy; `active` means non-silent, not speech."""
    if threshold < 0:
        raise ValueError("threshold cannot be negative")
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
