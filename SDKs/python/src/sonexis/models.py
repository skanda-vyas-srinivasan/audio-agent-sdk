"""Typed public models for Sonexis Runtime v0.3."""

from dataclasses import dataclass
from enum import Enum
from typing import Any, Dict, List, Optional


class SampleFormat(str, Enum):
    PCM_S16LE = "pcm_s16le"
    FLOAT32_LE = "float32_le"

    @property
    def bytes_per_sample(self) -> int:
        return 2 if self is SampleFormat.PCM_S16LE else 4


@dataclass(frozen=True)
class AudioFormat:
    sample_rate: int = 16_000
    channels: int = 1
    sample_format: SampleFormat = SampleFormat.PCM_S16LE
    interleaved: bool = True

    def to_wire(self) -> Dict[str, Any]:
        return {
            "sample_rate": self.sample_rate,
            "channel_count": self.channels,
            "sample_format": self.sample_format.value,
            "interleaved": self.interleaved,
        }

    @classmethod
    def speech_16k(cls) -> "AudioFormat":
        """PCM16 mono used by conventional speech pipelines."""
        return cls(16_000, 1, SampleFormat.PCM_S16LE)

    @classmethod
    def openai_realtime(cls) -> "AudioFormat":
        """PCM16 mono accepted by the OpenAI Realtime audio input."""
        return cls(24_000, 1, SampleFormat.PCM_S16LE)

    @classmethod
    def gemini_live(cls) -> "AudioFormat":
        """PCM16 mono accepted by Gemini Live realtime input."""
        return cls(16_000, 1, SampleFormat.PCM_S16LE)

    @classmethod
    def from_wire(cls, value: Dict[str, Any]) -> "AudioFormat":
        return cls(int(value["sample_rate"]), int(value["channel_count"]),
                   SampleFormat(value["sample_format"]), bool(value.get("interleaved", True)))


@dataclass(frozen=True)
class AudioSource:
    id: str
    name: str
    kind: str
    process_ids: List[int]
    bundle_identifier: Optional[str]
    process_state: str
    available: bool
    producing_audio: Optional[bool]
    native_format: Optional[AudioFormat]

    def __repr__(self) -> str:
        bundle = f", bundle_identifier={self.bundle_identifier!r}" if self.bundle_identifier else ""
        return f"AudioSource(id={self.id!r}, name={self.name!r}{bundle})"

    @classmethod
    def from_wire(cls, value: Dict[str, Any]) -> "AudioSource":
        native = value.get("native_format")
        return cls(str(value["id"]), str(value["name"]), str(value["kind"]),
                   [int(pid) for pid in value.get("process_i_ds", value.get("process_ids", []))],
                   value.get("bundle_identifier"), str(value.get("process_state", "unknown")),
                   bool(value.get("is_available", False)), value.get("is_producing_audio"),
                   AudioFormat.from_wire(native) if native else None)


@dataclass(frozen=True)
class SessionMetrics:
    capture_callbacks: int = 0
    native_frames_received: int = 0
    normalized_frames_delivered: int = 0
    ring_dropped_frames: int = 0
    delivery_dropped_frames: int = 0
    conversion_batches: int = 0
    conversion_nanoseconds: int = 0
    ring_backlog_frames: int = 0
    frames_forwarded: int = 0
    queue_dropped_frames: int = 0
    no_subscriber_frames: int = 0
    slow_consumer_disconnects: int = 0
    bytes_transmitted: int = 0
    connected_subscribers: int = 0
    data_queue_high_water_mark: int = 0

    @property
    def dropped_frames(self) -> int:
        return (self.ring_dropped_frames + self.delivery_dropped_frames
                + self.queue_dropped_frames + self.no_subscriber_frames)

    @property
    def average_conversion_us(self) -> float:
        return (self.conversion_nanoseconds / self.conversion_batches / 1000
                if self.conversion_batches else 0.0)

    @classmethod
    def from_wire(cls, value: Dict[str, Any]) -> "SessionMetrics":
        return cls(**{name: int(value.get(name, 0)) for name in cls.__dataclass_fields__})


@dataclass(frozen=True)
class RuntimeErrorInfo:
    code: str
    message: str
    retryable: bool = False
    details: Optional[Dict[str, str]] = None

    @classmethod
    def from_wire(cls, value: Dict[str, Any]) -> "RuntimeErrorInfo":
        details = value.get("details")
        return cls(str(value["code"]), str(value["message"]),
                   bool(value.get("retryable", False)),
                   {str(k): str(v) for k, v in details.items()} if details else None)


@dataclass(frozen=True)
class CaptureInfo:
    id: str
    stream_id: str
    source_id: str
    state: str
    format: AudioFormat
    data_socket_path: str
    started_at_ns: int
    metrics: SessionMetrics
    error: Optional[RuntimeErrorInfo] = None

    @classmethod
    def from_wire(cls, value: Dict[str, Any]) -> "CaptureInfo":
        return cls(str(value["id"]), str(value["stream_id"]), str(value["source_id"]),
                   str(value["state"]), AudioFormat.from_wire(value["format"]),
                   str(value["data_socket_path"]), int(value["started_at_nanoseconds"]),
                   SessionMetrics.from_wire(value.get("metrics", {})),
                   RuntimeErrorInfo.from_wire(value["error"]) if value.get("error") else None)


@dataclass(frozen=True)
class AudioFrame:
    stream_id: str
    sequence: int
    timestamp_ns: int
    frame_count: int
    format: AudioFormat
    data: bytes
    discontinuity: bool = False
    dropped_frames_before: int = 0
    source: Optional[AudioSource] = None
    session_id: Optional[str] = None
    runtime_started_at_ns: Optional[int] = None
    received_at_ns: Optional[int] = None

    @property
    def source_id(self) -> Optional[str]:
        return self.source.id if self.source else None

    @property
    def source_name(self) -> Optional[str]:
        return self.source.name if self.source else None

    @property
    def bundle_identifier(self) -> Optional[str]:
        return self.source.bundle_identifier if self.source else None

    @property
    def estimated_capture_at_ns(self) -> Optional[int]:
        """Estimated monotonic time; this is not a preserved HAL host timestamp."""
        if self.runtime_started_at_ns is None:
            return None
        return self.runtime_started_at_ns + self.timestamp_ns

    @property
    def estimated_sonexis_latency_ns(self) -> Optional[int]:
        capture = self.estimated_capture_at_ns
        if capture is None or self.received_at_ns is None:
            return None
        return max(0, self.received_at_ns - capture)


@dataclass(frozen=True)
class RuntimeEvent:
    id: str
    type: str
    timestamp_ns: int
    source_id: Optional[str] = None
    session_id: Optional[str] = None
    stream_id: Optional[str] = None
    message: Optional[str] = None
    dropped_frames: Optional[int] = None
    sequence: Optional[int] = None
    dropped_events_before: int = 0
    source: Optional[AudioSource] = None
    session: Optional[CaptureInfo] = None
    error: Optional[RuntimeErrorInfo] = None

    @classmethod
    def from_wire(cls, value: Dict[str, Any]) -> "RuntimeEvent":
        if (value.get("protocol_version") != 2
                or not isinstance(value.get("event_id"), str)
                or not isinstance(value.get("type"), str)
                or not isinstance(value.get("timestamp_nanoseconds"), int)):
            raise ValueError("invalid Runtime event envelope")
        return cls(
            str(value["event_id"]), str(value["type"]),
            int(value["timestamp_nanoseconds"]), value.get("source_id"),
            value.get("session_id"), value.get("stream_id"), value.get("message"),
            int(value["dropped_frames"]) if value.get("dropped_frames") is not None else None,
            int(value["event_sequence"]) if value.get("event_sequence") is not None else None,
            int(value.get("dropped_events_before", 0)),
            AudioSource.from_wire(value["source"]) if value.get("source") else None,
            CaptureInfo.from_wire(value["session"]) if value.get("session") else None,
            RuntimeErrorInfo.from_wire(value["error"]) if value.get("error") else None,
        )


@dataclass(frozen=True)
class RuntimeStatus:
    runtime_version: str
    runtime_instance_id: str
    uptime_ns: int
    active_clients: int
    active_sessions: int
    event_subscribers: int
    total_sessions_started: int
    total_frames_forwarded: int
    total_dropped_frames: int
    total_bytes_transmitted: int
    total_events_dropped: int = 0

    @classmethod
    def from_wire(cls, value: Dict[str, Any]) -> "RuntimeStatus":
        return cls(str(value["runtime_version"]), str(value["runtime_instance_id"]),
                   int(value["uptime_nanoseconds"]), int(value["active_clients"]),
                   int(value["active_sessions"]), int(value["event_subscribers"]),
                   int(value["total_sessions_started"]), int(value["total_frames_forwarded"]),
                   int(value["total_dropped_frames"]), int(value["total_bytes_transmitted"]),
                   int(value.get("total_events_dropped", 0)))


@dataclass(frozen=True)
class Handshake:
    protocol_version: int
    runtime_version: str
    runtime_instance_id: str
    capabilities: List[str]
    supported_formats: List[AudioFormat]
    limits: Dict[str, int]

    @classmethod
    def from_wire(cls, value: Dict[str, Any]) -> "Handshake":
        return cls(int(value["protocol_version"]), str(value["runtime_version"]),
                   str(value["runtime_instance_id"]), list(value["capabilities"]),
                   [AudioFormat.from_wire(item) for item in value["supported_formats"]],
                   {str(k): int(v) for k, v in value["limits"].items()})
