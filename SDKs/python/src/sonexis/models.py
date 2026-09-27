"""Typed public models for Sonexis Runtime."""

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
    def openai_realtime_output(cls) -> "AudioFormat":
        """PCM16 mono returned by OpenAI realtime audio responses."""
        return cls(24_000, 1, SampleFormat.PCM_S16LE)

    @classmethod
    def gemini_live(cls) -> "AudioFormat":
        """PCM16 mono accepted by Gemini Live realtime input."""
        return cls(16_000, 1, SampleFormat.PCM_S16LE)

    @classmethod
    def gemini_live_output(cls) -> "AudioFormat":
        """PCM16 mono returned by Gemini Live native-audio responses."""
        return cls(24_000, 1, SampleFormat.PCM_S16LE)

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
class AudioOutputDestination:
    """A Runtime-owned destination that can render client-provided audio."""

    id: str
    name: str
    kind: str
    available: bool
    is_default: bool
    follows_system_default: bool
    active_device_id: Optional[str]
    active_device_name: Optional[str]
    native_format: Optional[AudioFormat]
    supported_formats: List[AudioFormat]

    def __repr__(self) -> str:
        return (f"AudioOutputDestination(id={self.id!r}, name={self.name!r}, "
                f"kind={self.kind!r}, available={self.available!r})")

    @classmethod
    def from_wire(cls, value: Dict[str, Any]) -> "AudioOutputDestination":
        if not isinstance(value, dict):
            raise TypeError("output destination must be an object")
        for field in ("id", "name", "kind"):
            if not isinstance(value.get(field), str) or not value[field]:
                raise ValueError(f"output destination {field} must be a non-empty string")
        if value["kind"] not in ("playback", "virtual_input"):
            raise ValueError("unknown output destination kind")
        available = value.get("is_available", value.get("available", False))
        if not isinstance(available, bool):
            raise TypeError("output destination is_available must be a boolean")
        for field in ("is_default", "follows_system_default"):
            if not isinstance(value.get(field), bool):
                raise TypeError(f"output destination {field} must be a boolean")
        for field in ("active_device_id", "active_device_name"):
            if value.get(field) is not None and not isinstance(value[field], str):
                raise TypeError(f"output destination {field} must be a string or null")
        formats = value.get("supported_formats")
        native = value.get("native_format")
        if not isinstance(formats, list):
            raise TypeError("output destination supported_formats must be an array")
        if native is not None and not isinstance(native, dict):
            raise TypeError("output destination native_format must be an object or null")
        return cls(
            value["id"],
            value["name"],
            value["kind"],
            available,
            value["is_default"],
            value["follows_system_default"],
            value.get("active_device_id"),
            value.get("active_device_name"),
            AudioFormat.from_wire(native) if native else None,
            [AudioFormat.from_wire(item) for item in formats],
        )


@dataclass(frozen=True)
class OutputMetrics:
    """A point-in-time snapshot of one output session's bounded pipeline."""

    packets_received: int = 0
    input_frames_received: int = 0
    input_bytes_received: int = 0
    device_frames_enqueued: int = 0
    device_frames_rendered: int = 0
    dropped_frames: int = 0
    flushed_frames: int = 0
    late_frames: int = 0
    underrun_frames: int = 0
    underrun_events: int = 0
    overrun_events: int = 0
    queue_depth_frames: int = 0
    queue_high_water_frames: int = 0
    buffered_milliseconds: float = 0.0
    target_buffer_milliseconds: int = 0
    conversion_batches: int = 0
    conversion_nanoseconds: int = 0
    route_changes: int = 0
    producer_connected: bool = False
    device_sample_rate: Optional[int] = None
    device_channel_count: Optional[int] = None
    estimated_output_latency_milliseconds: Optional[float] = None
    uptime_nanoseconds: Optional[int] = None

    @property
    def frames_received(self) -> int:
        return self.input_frames_received

    @property
    def frames_rendered(self) -> int:
        return self.device_frames_rendered

    @property
    def frames_dropped(self) -> int:
        return self.dropped_frames

    @property
    def frames_late(self) -> int:
        return self.late_frames

    @property
    def underruns(self) -> int:
        return self.underrun_events

    @property
    def overruns(self) -> int:
        return self.overrun_events

    @property
    def average_conversion_us(self) -> float:
        return (self.conversion_nanoseconds / self.conversion_batches / 1000
                if self.conversion_batches else 0.0)

    @classmethod
    def from_wire(cls, value: Dict[str, Any]) -> "OutputMetrics":
        integer_fields = {
            "packets_received", "input_frames_received", "input_bytes_received",
            "device_frames_enqueued", "device_frames_rendered", "dropped_frames",
            "flushed_frames", "late_frames", "underrun_frames", "underrun_events",
            "overrun_events", "queue_depth_frames", "queue_high_water_frames",
            "target_buffer_milliseconds", "conversion_batches", "conversion_nanoseconds",
            "route_changes",
        }
        converted = {name: int(value.get(name, 0)) for name in integer_fields}
        converted["buffered_milliseconds"] = float(value.get("buffered_milliseconds", 0.0))
        converted["producer_connected"] = bool(value.get("producer_connected", False))
        converted["device_sample_rate"] = (int(value["device_sample_rate"])
                                             if value.get("device_sample_rate") is not None
                                             else None)
        converted["device_channel_count"] = (int(value["device_channel_count"])
                                               if value.get("device_channel_count") is not None
                                               else None)
        converted["estimated_output_latency_milliseconds"] = (
            float(value["estimated_output_latency_milliseconds"])
            if value.get("estimated_output_latency_milliseconds") is not None else None)
        converted["uptime_nanoseconds"] = (int(value["uptime_nanoseconds"])
                                            if value.get("uptime_nanoseconds") is not None
                                            else None)
        return cls(**converted)


@dataclass(frozen=True)
class OutputInfo:
    """Runtime state and negotiated data-plane details for an audio output."""

    id: str
    stream_id: str
    destination_id: str
    state: str
    format: AudioFormat
    data_socket_path: str
    started_at_ns: int
    target_buffer_milliseconds: int
    metrics: OutputMetrics
    error: Optional[RuntimeErrorInfo] = None

    @classmethod
    def from_wire(cls, value: Dict[str, Any]) -> "OutputInfo":
        return cls(
            str(value["id"]),
            str(value["stream_id"]),
            str(value["destination_id"]),
            str(value["state"]),
            AudioFormat.from_wire(value["format"]),
            str(value["data_socket_path"]),
            int(value["started_at_nanoseconds"]),
            int(value.get("target_buffer_milliseconds", 0)),
            OutputMetrics.from_wire(value.get("metrics", {})),
            RuntimeErrorInfo.from_wire(value["error"]) if value.get("error") else None,
        )


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
    output_destination_id: Optional[str] = None
    message: Optional[str] = None
    dropped_frames: Optional[int] = None
    sequence: Optional[int] = None
    dropped_events_before: int = 0
    source: Optional[AudioSource] = None
    session: Optional[CaptureInfo] = None
    error: Optional[RuntimeErrorInfo] = None
    output_session: Optional[OutputInfo] = None
    output_destination: Optional[AudioOutputDestination] = None

    @classmethod
    def from_wire(cls, value: Dict[str, Any]) -> "RuntimeEvent":
        if (value.get("protocol_version") != 2
                or not isinstance(value.get("event_id"), str)
                or not isinstance(value.get("type"), str)
                or not isinstance(value.get("timestamp_nanoseconds"), int)):
            raise ValueError("invalid Runtime event envelope")
        destination = (AudioOutputDestination.from_wire(value["output_destination"])
                       if value.get("output_destination") is not None else None)
        destination_id = value.get("output_destination_id")
        if destination_id is not None and not isinstance(destination_id, str):
            raise ValueError("invalid Runtime event output destination ID")
        if destination is not None and destination_id is not None and destination.id != destination_id:
            raise ValueError("Runtime event output destination ID does not match its snapshot")
        if destination_id is None and destination is not None:
            destination_id = destination.id
        return cls(
            str(value["event_id"]), str(value["type"]),
            int(value["timestamp_nanoseconds"]), value.get("source_id"),
            value.get("session_id"), value.get("stream_id"),
            destination_id,
            value.get("message"),
            int(value["dropped_frames"]) if value.get("dropped_frames") is not None else None,
            int(value["event_sequence"]) if value.get("event_sequence") is not None else None,
            int(value.get("dropped_events_before", 0)),
            AudioSource.from_wire(value["source"]) if value.get("source") else None,
            CaptureInfo.from_wire(value["session"]) if value.get("session") else None,
            RuntimeErrorInfo.from_wire(value["error"]) if value.get("error") else None,
            OutputInfo.from_wire(value["output_session"]) if value.get("output_session") else None,
            destination,
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
    active_output_sessions: int = 0
    total_output_sessions_started: int = 0
    total_output_frames_received: int = 0
    total_output_frames_rendered: int = 0
    total_output_frames_dropped: int = 0
    total_output_bytes_received: int = 0
    total_capture_ring_dropped_frames: int = 0
    total_capture_delivery_dropped_frames: int = 0
    total_capture_queue_dropped_frames: int = 0
    total_capture_no_subscriber_frames: int = 0
    connected_capture_subscribers: int = 0
    retained_capture_sessions: int = 0
    reserved_capture_starts: int = 0
    total_output_frames_lost: int = 0
    total_output_frames_flushed: int = 0
    total_output_frames_late: int = 0
    total_output_underrun_frames: int = 0
    total_output_underrun_events: int = 0
    total_output_overrun_events: int = 0
    total_output_route_changes: int = 0
    total_output_conversion_batches: int = 0
    total_output_conversion_nanoseconds: int = 0
    connected_output_producers: int = 0
    retained_output_sessions: int = 0
    reserved_output_starts: int = 0
    total_control_clients_accepted: int = 0
    total_control_clients_disconnected: int = 0
    total_control_clients_rejected: int = 0
    total_control_requests: int = 0
    total_control_errors: int = 0
    total_malformed_control_messages: int = 0
    total_control_handshake_timeouts: int = 0
    total_source_monitor_failures: int = 0
    total_destination_monitor_failures: int = 0
    source_monitor_consecutive_failures: int = 0
    destination_monitor_consecutive_failures: int = 0
    source_monitor_recoveries: int = 0
    destination_monitor_recoveries: int = 0
    source_monitor_last_success_nanoseconds: int = 0
    destination_monitor_last_success_nanoseconds: int = 0
    resident_memory_bytes: int = 0
    peak_resident_memory_bytes: int = 0
    open_file_descriptors: int = 0
    thread_count: int = 0

    @classmethod
    def from_wire(cls, value: Dict[str, Any]) -> "RuntimeStatus":
        return cls(str(value["runtime_version"]), str(value["runtime_instance_id"]),
                   int(value["uptime_nanoseconds"]), int(value["active_clients"]),
                   int(value["active_sessions"]), int(value["event_subscribers"]),
                   int(value["total_sessions_started"]), int(value["total_frames_forwarded"]),
                   int(value["total_dropped_frames"]), int(value["total_bytes_transmitted"]),
                   int(value.get("total_events_dropped", 0)),
                   int(value.get("active_output_sessions", 0)),
                   int(value.get("total_output_sessions_started", 0)),
                   int(value.get("total_output_frames_received", 0)),
                   int(value.get("total_output_frames_rendered", 0)),
                   int(value.get("total_output_frames_dropped", 0)),
                   int(value.get("total_output_bytes_received", 0)),
                   int(value.get("total_capture_ring_dropped_frames", 0)),
                   int(value.get("total_capture_delivery_dropped_frames", 0)),
                   int(value.get("total_capture_queue_dropped_frames", 0)),
                   int(value.get("total_capture_no_subscriber_frames", 0)),
                   int(value.get("connected_capture_subscribers", 0)),
                   int(value.get("retained_capture_sessions", 0)),
                   int(value.get("reserved_capture_starts", 0)),
                   int(value.get("total_output_frames_lost", 0)),
                   int(value.get("total_output_frames_flushed", 0)),
                   int(value.get("total_output_frames_late", 0)),
                   int(value.get("total_output_underrun_frames", 0)),
                   int(value.get("total_output_underrun_events", 0)),
                   int(value.get("total_output_overrun_events", 0)),
                   int(value.get("total_output_route_changes", 0)),
                   int(value.get("total_output_conversion_batches", 0)),
                   int(value.get("total_output_conversion_nanoseconds", 0)),
                   int(value.get("connected_output_producers", 0)),
                   int(value.get("retained_output_sessions", 0)),
                   int(value.get("reserved_output_starts", 0)),
                   int(value.get("total_control_clients_accepted", 0)),
                   int(value.get("total_control_clients_disconnected", 0)),
                   int(value.get("total_control_clients_rejected", 0)),
                   int(value.get("total_control_requests", 0)),
                   int(value.get("total_control_errors", 0)),
                   int(value.get("total_malformed_control_messages", 0)),
                   int(value.get("total_control_handshake_timeouts", 0)),
                   int(value.get("total_source_monitor_failures", 0)),
                   int(value.get("total_destination_monitor_failures", 0)),
                   int(value.get("source_monitor_consecutive_failures", 0)),
                   int(value.get("destination_monitor_consecutive_failures", 0)),
                   int(value.get("source_monitor_recoveries", 0)),
                   int(value.get("destination_monitor_recoveries", 0)),
                   int(value.get("source_monitor_last_success_nanoseconds", 0)),
                   int(value.get("destination_monitor_last_success_nanoseconds", 0)),
                   int(value.get("resident_memory_bytes", 0)),
                   int(value.get("peak_resident_memory_bytes", 0)),
                   int(value.get("open_file_descriptors", 0)),
                   int(value.get("thread_count", 0)))


@dataclass(frozen=True)
class Handshake:
    protocol_version: int
    runtime_version: str
    runtime_instance_id: str
    capabilities: List[str]
    supported_formats: List[AudioFormat]
    supported_output_formats: List[AudioFormat]
    limits: Dict[str, int]

    @classmethod
    def from_wire(cls, value: Dict[str, Any]) -> "Handshake":
        return cls(int(value["protocol_version"]), str(value["runtime_version"]),
                   str(value["runtime_instance_id"]), list(value["capabilities"]),
                   [AudioFormat.from_wire(item) for item in value["supported_formats"]],
                   [AudioFormat.from_wire(item)
                    for item in value.get("supported_output_formats", [])],
                   {str(k): int(v) for k, v in value["limits"].items()})
