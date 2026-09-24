"""Typed public models for Sonexis Runtime v0.2."""

from dataclasses import dataclass, field
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
class CaptureInfo:
    id: str
    stream_id: str
    source_id: str
    state: str
    format: AudioFormat
    data_socket_path: str
    started_at_ns: int
    metrics: SessionMetrics
    error: Optional[Dict[str, Any]] = None

    @classmethod
    def from_wire(cls, value: Dict[str, Any]) -> "CaptureInfo":
        return cls(str(value["id"]), str(value["stream_id"]), str(value["source_id"]),
                   str(value["state"]), AudioFormat.from_wire(value["format"]),
                   str(value["data_socket_path"]), int(value["started_at_nanoseconds"]),
                   SessionMetrics.from_wire(value.get("metrics", {})), value.get("error"))


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
    raw: Dict[str, Any] = field(default_factory=dict, repr=False)

    @classmethod
    def from_wire(cls, value: Dict[str, Any]) -> "RuntimeEvent":
        return cls(str(value["event_id"]), str(value["type"]),
                   int(value["timestamp_nanoseconds"]), value.get("source_id"),
                   value.get("session_id"), value.get("stream_id"), value.get("message"),
                   int(value["dropped_frames"]) if value.get("dropped_frames") is not None else None,
                   value)


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

    @classmethod
    def from_wire(cls, value: Dict[str, Any]) -> "RuntimeStatus":
        return cls(str(value["runtime_version"]), str(value["runtime_instance_id"]),
                   int(value["uptime_nanoseconds"]), int(value["active_clients"]),
                   int(value["active_sessions"]), int(value["event_subscribers"]),
                   int(value["total_sessions_started"]), int(value["total_frames_forwarded"]),
                   int(value["total_dropped_frames"]), int(value["total_bytes_transmitted"]))


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
