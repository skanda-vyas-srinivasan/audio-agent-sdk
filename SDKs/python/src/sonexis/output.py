"""Client-to-Runtime realtime audio output stream."""

import asyncio
import uuid
from typing import Any, Optional, TYPE_CHECKING, Union

from .errors import SonexisConnectionError, SonexisError
from .models import AudioOutputDestination, OutputInfo, OutputMetrics
from .protocol import encode_frame_header

if TYPE_CHECKING:
    from .client import Sonexis

BytesLike = Union[bytes, bytearray, memoryview]


class AudioOutput:
    """A negotiated, ordered PCM stream rendered by Sonexis Runtime.

    Writes are serialized and split into packets no longer than 200 ms. Socket
    backpressure is intentional: it bounds memory in both the SDK and Runtime.
    """

    _MAX_PACKET_MILLISECONDS = 200

    def __init__(self, client: "Sonexis", info: OutputInfo,
                 destination: Optional[AudioOutputDestination] = None) -> None:
        self.client = client
        self.info = info
        self.destination = destination
        self._reader: Optional[asyncio.StreamReader] = None
        self._writer: Optional[asyncio.StreamWriter] = None
        self._stream_id = uuid.UUID(info.stream_id)
        self._sequence = 0
        self._next_timestamp_ns = 0
        self._operation_lock = asyncio.Lock()
        self._closed = False
        self._cleanup_task: Optional[asyncio.Task] = None

    def __repr__(self) -> str:
        return (f"AudioOutput(id={self.info.id!r}, destination={self.info.destination_id!r}, "
                f"format={self.info.format!r}, state={self.info.state!r})")

    @property
    def closed(self) -> bool:
        return self._closed

    @property
    def metrics(self) -> OutputMetrics:
        """The latest metrics snapshot; call :meth:`refresh` for current values."""
        return self.info.metrics

    async def _open(self) -> None:
        self._reader, self._writer = await asyncio.open_unix_connection(
            self.info.data_socket_path)

    async def __aenter__(self) -> "AudioOutput":
        return self

    async def __aexit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        await self.aclose(drain=exc_type is None)

    async def write(
        self,
        data: BytesLike,
        *,
        timestamp_ns: Optional[int] = None,
        discontinuity: bool = False,
    ) -> None:
        """Write whole interleaved PCM frames, applying bounded socket backpressure."""
        if self._closed:
            raise SonexisError("output_closed", "Audio output is already closed")
        view = memoryview(data)
        if not view.c_contiguous:
            view = memoryview(bytes(view))
        view = view.cast("B")
        if not view:
            return
        audio_format = self.info.format
        frame_size = audio_format.channels * audio_format.sample_format.bytes_per_sample
        if len(view) % frame_size:
            raise ValueError("audio payload must contain whole interleaved sample frames")
        if len(view) // frame_size < max(1, audio_format.sample_rate // 1000):
            raise ValueError("audio writes must contain at least one millisecond of PCM")
        max_frames = max(1, audio_format.sample_rate * self._MAX_PACKET_MILLISECONDS // 1000)
        max_bytes = max_frames * frame_size

        write_started = False
        try:
            async with self._operation_lock:
                if self._closed or self._writer is None:
                    raise SonexisError("output_closed", "Audio output is already closed")
                write_started = True
                offset = 0
                frames_written_this_call = 0
                first_timestamp = (
                    timestamp_ns if timestamp_ns is not None else self._next_timestamp_ns)
                while offset < len(view):
                    packet = view[offset:offset + max_bytes]
                    frame_count = len(packet) // frame_size
                    packet_timestamp = first_timestamp + self._frames_to_nanoseconds(
                        frames_written_this_call)
                    header = encode_frame_header(
                        stream_id=self._stream_id,
                        sequence=self._sequence,
                        timestamp_ns=packet_timestamp,
                        format=audio_format,
                        frame_count=frame_count,
                        payload_size=len(packet),
                        discontinuity=discontinuity and offset == 0,
                    )
                    try:
                        self._writer.write(header)
                        self._writer.write(packet)
                        await self._writer.drain()
                    except (OSError, ConnectionError) as error:
                        raise await self._resolve_stream_failure(error) from error
                    self._sequence += 1
                    frames_written_this_call += frame_count
                    self._next_timestamp_ns = (
                        packet_timestamp + self._frames_to_nanoseconds(frame_count))
                    offset += len(packet)
        except asyncio.CancelledError:
            # Once bytes enter the transport, it is impossible to know whether
            # Runtime accepted the packet. End this stream epoch rather than
            # risk reusing a sequence number after caller cancellation.
            if write_started:
                await self.aclose(drain=False)
            raise

    async def refresh(self) -> OutputInfo:
        """Refresh and return this output session's Runtime state and metrics."""
        self.info = await self.client.output_status(self.info.id)
        return self.info

    async def flush(self) -> OutputInfo:
        """Discard buffered audio and attach the fresh stream returned by Runtime."""
        if self._closed:
            raise SonexisError("output_closed", "Audio output is already closed")
        async with self._operation_lock:
            if self._closed:
                raise SonexisError("output_closed", "Audio output is already closed")
            info = await self.client._flush_output(self.info.id)
            old_writer, self._writer = self._writer, None
            self._reader = None
            if old_writer is not None:
                old_writer.close()
                try:
                    await asyncio.wait_for(old_writer.wait_closed(), timeout=1.0)
                except (OSError, ConnectionError, asyncio.TimeoutError):
                    pass
            self.info = info
            self._stream_id = uuid.UUID(info.stream_id)
            self._sequence = 0
            self._next_timestamp_ns = 0
            try:
                await self._open()
            except BaseException:
                await self.client._cleanup_request("stop_output", output_session_id=info.id)
                self._closed = True
                self.client._outputs.discard(self)
                raise
            return info

    async def cancel(self) -> None:
        """Stop immediately, discarding audio buffered by the Runtime."""
        await self.aclose(drain=False)

    async def close(self, *, drain: bool = True) -> None:
        """Close the output, draining by default. Alias for :meth:`aclose`."""
        await self.aclose(drain=drain)

    async def aclose(self, *, drain: bool = True, stop_runtime: bool = True) -> None:
        """Finish with EOS when ``drain`` is true, or cancel immediately."""
        if self._cleanup_task is None:
            self._closed = True
            if not drain and self._writer is not None:
                # Closing the transport wakes a write blocked in drain(), so a
                # barge-in/cancel does not wait for a full socket buffer.
                self._writer.close()
            self._cleanup_task = asyncio.create_task(
                self._finish_cleanup(drain, stop_runtime), name="sonexis-output-cleanup")
        await asyncio.shield(self._cleanup_task)

    async def _finish_cleanup(self, drain: bool, stop_runtime: bool) -> None:
        writer: Optional[asyncio.StreamWriter] = None
        try:
            async with self._operation_lock:
                writer, self._writer = self._writer, None
                self._reader = None
                if writer is not None and drain:
                    header = encode_frame_header(
                        stream_id=self._stream_id,
                        sequence=self._sequence,
                        timestamp_ns=self._next_timestamp_ns,
                        format=self.info.format,
                        frame_count=0,
                        payload_size=0,
                        eos=True,
                    )
                    try:
                        writer.write(header)
                        await writer.drain()
                    except (OSError, ConnectionError):
                        pass
                if writer is not None:
                    writer.close()
                    try:
                        await asyncio.wait_for(writer.wait_closed(), timeout=1.0)
                    except (OSError, ConnectionError, asyncio.TimeoutError):
                        pass
        finally:
            self.client._outputs.discard(self)
            if stop_runtime and drain:
                await self._wait_for_drain()
            elif stop_runtime:
                await self.client._cleanup_request(
                    "stop_output", output_session_id=self.info.id)

    async def _wait_for_drain(self) -> None:
        """Keep the owning control connection alive until EOS playback completes."""
        deadline = asyncio.get_running_loop().time() + 3.0
        while self.client._writer is not None:
            try:
                info = await self.client.output_status(self.info.id)
                self.info = info
                if info.state == "failed":
                    if info.error is not None:
                        raise SonexisError.from_response({"error": {
                            "code": info.error.code,
                            "message": info.error.message,
                            "retryable": info.error.retryable,
                            "details": info.error.details or {},
                        }})
                    raise SonexisError("output_failed",
                                       "Runtime output failed while draining")
                if info.state in ("stopped", "cancelled"):
                    return
            except SonexisError as error:
                if error.code in ("output_session_not_found", "session_not_found"):
                    return
                raise
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                await self.client._cleanup_request(
                    "stop_output", output_session_id=self.info.id)
                return
            await asyncio.sleep(min(0.02, remaining))

    async def _resolve_stream_failure(self, transport_error: BaseException) -> SonexisError:
        """Prefer the Runtime's terminal backend cause over a generic socket error."""
        async def terminal_error() -> Optional[SonexisError]:
            deadline = asyncio.get_running_loop().time() + 0.4
            while asyncio.get_running_loop().time() < deadline:
                info = await self.client.output_status(self.info.id)
                self.info = info
                if info.error is not None:
                    return SonexisError.from_response({
                        "error": {
                            "code": info.error.code,
                            "message": info.error.message,
                            "retryable": info.error.retryable,
                            "details": info.error.details or {},
                        }
                    })
                if info.state in ("stopped", "cancelled"):
                    return None
                await asyncio.sleep(0.02)
            return None

        try:
            resolved = await asyncio.wait_for(terminal_error(), timeout=0.5)
            if resolved is not None:
                return resolved
        except Exception:
            pass
        return SonexisConnectionError(
            "output_stream_closed", str(transport_error), retryable=True)

    def _frames_to_nanoseconds(self, frame_count: int) -> int:
        return frame_count * 1_000_000_000 // self.info.format.sample_rate
