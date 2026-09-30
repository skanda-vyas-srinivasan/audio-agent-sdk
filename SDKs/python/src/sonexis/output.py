"""Client-to-Runtime realtime audio output stream."""

import asyncio
import uuid
from typing import Any, Optional, TYPE_CHECKING, Union

from .errors import SonexisConnectionError, SonexisError
from .models import AudioOutputDestination, OutputInfo, OutputMetrics
from .protocol import encode_frame_header
from .unix_socket import open_trusted_unix_connection

if TYPE_CHECKING:
    from .client import Sonexis

BytesLike = Union[bytes, bytearray, memoryview]


class AudioOutput:
    """A negotiated, ordered PCM stream rendered by Sonexis Runtime.

    Writes are serialized and split into packets no longer than 200 ms. Socket
    backpressure is intentional: it bounds memory in both the SDK and Runtime.
    """

    _MAX_PACKET_MILLISECONDS = 200
    _DRAIN_TIMEOUT_SECONDS = 3.0

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
        self._cancel_close = asyncio.Event()

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
        reader, writer = await open_trusted_unix_connection(
            self.info.data_socket_path)
        if self._closed:
            writer.close()
            try:
                await asyncio.wait_for(writer.wait_closed(), timeout=1.0)
            except (OSError, ConnectionError, asyncio.TimeoutError):
                pass
            raise SonexisError("output_closed", "Audio output closed while attaching")
        self._reader, self._writer = reader, writer

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
        minimum_frames = max(1, audio_format.sample_rate // 1000)

        write_started = False
        try:
            async with self._operation_lock:
                if self._closed or self._writer is None:
                    raise SonexisError("output_closed", "Audio output is already closed")
                writer = self._writer
                write_started = True
                offset = 0
                frames_written_this_call = 0
                first_timestamp = (
                    timestamp_ns if timestamp_ns is not None else self._next_timestamp_ns)
                while offset < len(view):
                    # Closing rejects operations that have not acquired the
                    # lock, but graceful cleanup waits for this active write.
                    # Only cancellation or drain expiry cuts it short.
                    if self._cancel_close.is_set():
                        raise SonexisError("output_closed", "Audio output is already closed")
                    remaining_frames = (len(view) - offset) // frame_size
                    frame_count = min(max_frames, remaining_frames)
                    tail = remaining_frames - frame_count
                    if 0 < tail < minimum_frames:
                        frame_count -= minimum_frames - tail
                    packet = view[offset:offset + frame_count * frame_size]
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
                        writer.write(header)
                        writer.write(packet)
                        await writer.drain()
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
        """Refresh session metrics and the destination's current route metadata."""
        self.info, self.destination = await asyncio.gather(
            self.client.output_status(self.info.id),
            self.client.get_output_destination(self.info.destination_id),
        )
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
        """Reject new writes, finish the active write and EOS, or cancel immediately."""
        if not drain:
            self._cancel_close.set()
            if self._writer is not None:
                # Keep the transport reachable even while EOS is being sent.
                self._abort_transport(self._writer)
        if self._cleanup_task is None:
            self._closed = True
            self._cleanup_task = asyncio.create_task(
                self._finish_cleanup(drain, stop_runtime), name="sonexis-output-cleanup")
        await asyncio.shield(self._cleanup_task)

    async def _finish_cleanup(self, drain: bool, stop_runtime: bool) -> None:
        writer = self._writer
        graceful: Optional[asyncio.Task] = None
        cancellation: Optional[asyncio.Task] = None
        try:
            if drain and not self._cancel_close.is_set():
                graceful = asyncio.create_task(self._drain_and_close(stop_runtime))
                cancellation = asyncio.create_task(self._cancel_close.wait())
                done, _ = await asyncio.wait(
                    (graceful, cancellation), timeout=self._DRAIN_TIMEOUT_SECONDS,
                    return_when=asyncio.FIRST_COMPLETED)
                if graceful in done and not self._cancel_close.is_set():
                    await graceful
                    return
            # Cancellation and the deadline bypass the operation lock. An old
            # write may still own it, but this stream will never be reused.
            self._cancel_close.set()
            if writer is not None:
                self._abort_transport(writer)
            if graceful is not None:
                graceful.cancel()
                await asyncio.gather(graceful, return_exceptions=True)
            if stop_runtime:
                await self.client._cleanup_request("stop_output", output_session_id=self.info.id)
        except BaseException:
            if stop_runtime:
                await self.client._cleanup_request("stop_output", output_session_id=self.info.id)
            raise
        finally:
            for task in (graceful, cancellation):
                if task is not None:
                    task.cancel()
            await asyncio.gather(
                *(task for task in (graceful, cancellation) if task is not None),
                return_exceptions=True)
            self._writer = None
            self._reader = None
            if writer is not None:
                writer.close()
                try:
                    await asyncio.wait_for(writer.wait_closed(), timeout=1.0)
                except (OSError, ConnectionError, asyncio.TimeoutError):
                    self._abort_transport(writer)
            self.client._outputs.discard(self)

    @staticmethod
    def _abort_transport(writer: asyncio.StreamWriter) -> None:
        # close() may keep a full socket buffer alive indefinitely while trying
        # to flush it. Cancellation must discard those bytes and wake drain().
        writer.close()
        transport = getattr(writer, "transport", None)
        if transport is not None:
            transport.abort()

    async def _drain_and_close(self, stop_runtime: bool) -> None:
        async with self._operation_lock:
            writer = self._writer
            if writer is not None:
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
                writer.close()
        if stop_runtime:
            await self._wait_for_drain()

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
