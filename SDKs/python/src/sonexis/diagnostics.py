"""Bounded, consumer-side timing summaries for Sonexis audio frames."""

import math
import time
from collections import deque
from dataclasses import dataclass
from typing import Deque, Optional

from .models import AudioFrame


@dataclass(frozen=True)
class AudioSendReceipt:
    provider: str
    sequence: int
    sent_at_ns: int
    payload_bytes: int
    estimated_sonexis_latency_ns: Optional[int]


@dataclass(frozen=True)
class LatencySummary:
    count: int
    p50_ms: float
    p95_ms: float
    p99_ms: float
    maximum_ms: float


class LatencyTracker:
    """Retain a bounded window of estimated Sonexis-to-SDK latency samples."""

    def __init__(self, max_samples: int = 4096) -> None:
        if max_samples < 1:
            raise ValueError("max_samples must be positive")
        self._samples: Deque[int] = deque(maxlen=max_samples)

    def observe(self, frame: AudioFrame) -> None:
        value = frame.estimated_sonexis_latency_ns
        if value is not None:
            self._samples.append(value)

    def summary(self) -> Optional[LatencySummary]:
        if not self._samples:
            return None
        ordered = sorted(self._samples)

        def percentile(value: float) -> float:
            index = max(0, math.ceil(len(ordered) * value) - 1)
            return ordered[index] / 1_000_000

        return LatencySummary(len(ordered), percentile(0.50), percentile(0.95),
                              percentile(0.99), ordered[-1] / 1_000_000)


def send_receipt(provider: str, frame: AudioFrame, payload_bytes: Optional[int] = None) -> AudioSendReceipt:
    return AudioSendReceipt(provider, frame.sequence, time.monotonic_ns(),
                            len(frame.data) if payload_bytes is None else payload_bytes,
                            frame.estimated_sonexis_latency_ns)
