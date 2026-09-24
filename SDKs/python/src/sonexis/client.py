"""Async public client for Sonexis Runtime v0.2."""

import asyncio
import json
import os
import uuid
from typing import Any, AsyncIterator, Dict, Iterable, List, Optional, Set, Union

from .errors import SonexisConnectionError, SonexisError, SonexisProtocolError
from .models import (AudioFormat, AudioFrame, AudioSource, CaptureInfo, Handshake,
                     RuntimeEvent, RuntimeStatus)
from .protocol import FLAG_EOS, MAX_CONTROL_BYTES, PROTOCOL_VERSION, read_frame


class Sonexis:
    """A reusable asynchronous connection to the local Sonexis Runtime."""

    def __init__(self, socket_path: Optional[str] = None, *, client_name: str = "sonexis-python",
                 client_version: str = "0.2.0") -> None:
        self.socket_path = socket_path or os.environ.get(
            "SONEXIS_RUNTIME_SOCKET", f"/tmp/sonexis-runtime-{os.getuid()}/control.sock")
        self.client_name = client_name
        self.client_version = client_version
        self.handshake: Optional[Handshake] = None
        self._reader: Optional[asyncio.StreamReader] = None
        self._writer: Optional[asyncio.StreamWriter] = None
        self._reader_task: Optional[asyncio.Task] = None
        self._write_lock = asyncio.Lock()
        self._pending: Dict[str, asyncio.Future] = {}
        self._discarded_request_ids: Set[str] = set()
        self._captures: Set["CaptureSession"] = set()
        self._events: Set["EventSubscription"] = set()

    async def __aenter__(self) -> "Sonexis":
        await self.connect()
        return self

    async def __aexit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        await self.close()

    async def connect(self, *, reconnect_attempts: int = 0) -> Handshake:
        if self._writer is not None:
            assert self.handshake is not None
            return self.handshake
        last_error: Optional[BaseException] = None
        for attempt in range(reconnect_attempts + 1):
            try:
                self._reader, self._writer = await asyncio.open_unix_connection(
                    self.socket_path, limit=MAX_CONTROL_BYTES + 1)
                self._reader_task = asyncio.create_task(self._control_reader(),
                                                        name="sonexis-control-reader")
                result = await self._request("hello", supported_protocol_versions=[2],
                                             client_name=self.client_name,
                                             client_version=self.client_version)
                handshake = Handshake.from_wire(result["handshake"])
                if handshake.protocol_version != PROTOCOL_VERSION:
                    raise SonexisProtocolError("unsupported_protocol_version",
                                               "Runtime selected an incompatible protocol")
                self.handshake = handshake
                return handshake
            except (OSError, SonexisError) as error:
                last_error = error
                await self.close()
                if attempt < reconnect_attempts:
                    await asyncio.sleep(min(0.1 * (2 ** attempt), 1.0))
        if isinstance(last_error, SonexisError):
            raise last_error
        raise SonexisConnectionError("connect_failed", str(last_error), retryable=True)

    async def reconnect(self, *, attempts: int = 3) -> Handshake:
        """Create a fresh control connection; streams are never silently resumed."""
        await self.close()
        return await self.connect(reconnect_attempts=attempts)

    async def close(self) -> None:
        captures = list(self._captures)
        events = list(self._events)
        for capture in captures:
            await capture.aclose(stop_runtime=False)
        for subscription in events:
            await subscription.aclose(unsubscribe=False)
        writer, self._writer = self._writer, None
        self._reader = None
        if writer is not None:
            writer.close()
            try:
                await writer.wait_closed()
            except (OSError, ConnectionError):
                pass
        task, self._reader_task = self._reader_task, None
        if task is not None and task is not asyncio.current_task():
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        error = SonexisConnectionError("disconnected", "Runtime connection closed", retryable=True)
        for future in list(self._pending.values()):
            if not future.done():
                future.set_exception(error)
        self._pending.clear()
        self._discarded_request_ids.clear()
        self.handshake = None

    async def sources(self) -> List[AudioSource]:
        response = await self._request("list_sources")
        return [AudioSource.from_wire(value) for value in response.get("sources", [])]

    async def status(self, session_id: Optional[str] = None) -> Union[RuntimeStatus, CaptureInfo]:
        if session_id is None:
            response = await self._request("runtime_status")
            return RuntimeStatus.from_wire(response["status"])
        response = await self._request("session_status", session_id=session_id)
        return CaptureInfo.from_wire(response["session"])

    async def capture(self, source: Union[str, AudioSource], *,
                      format: AudioFormat = AudioFormat()) -> "CaptureSession":
        source_id = source.id if isinstance(source, AudioSource) else source
        response = await self._request("start_capture", source_id=source_id,
                                       format=format.to_wire())
        capture = CaptureSession(self, CaptureInfo.from_wire(response["session"]))
        await capture._open()
        self._captures.add(capture)
        return capture

    async def stop(self, session_id: str) -> CaptureInfo:
        response = await self._request("stop_capture", session_id=session_id)
        return CaptureInfo.from_wire(response["session"])

    async def events(self, event_types: Optional[Iterable[str]] = None) -> "EventSubscription":
        params: Dict[str, Any] = {}
        if event_types is not None:
            params["event_types"] = list(event_types)
        response = await self._request("subscribe_events", **params)
        subscription = EventSubscription(self, response["subscription"])
        await subscription._open()
        self._events.add(subscription)
        return subscription

    async def _request(self, command: str, **parameters: Any) -> Dict[str, Any]:
        writer = self._writer
        if writer is None:
            raise SonexisConnectionError("not_connected", "Connect to Sonexis Runtime first")
        request_id = str(uuid.uuid4())
        envelope = {"message_type": "request", "protocol_version": PROTOCOL_VERSION,
                    "request_id": request_id, "command": command}
        envelope.update(parameters)
        payload = json.dumps(envelope, separators=(",", ":")).encode("utf-8") + b"\n"
        if len(payload) > MAX_CONTROL_BYTES:
            raise SonexisProtocolError("message_too_large", "Control request exceeds 64 KiB")
        future = asyncio.get_running_loop().create_future()
        self._pending[request_id] = future
        try:
            async with self._write_lock:
                writer.write(payload)
                await writer.drain()
            return await future
        finally:
            self._pending.pop(request_id, None)
            if future.cancelled():
                self._discarded_request_ids.add(request_id)
                if len(self._discarded_request_ids) > 1024:
                    self._discarded_request_ids.clear()

    async def _control_reader(self) -> None:
        assert self._reader is not None
        try:
            while True:
                line = await self._reader.readline()
                if not line:
                    raise SonexisConnectionError("disconnected", "Runtime closed the control socket",
                                                 retryable=True)
                if len(line) > MAX_CONTROL_BYTES or not line.endswith(b"\n"):
                    raise SonexisProtocolError("message_too_large", "Invalid control response framing")
                try:
                    response = json.loads(line)
                except (UnicodeDecodeError, json.JSONDecodeError) as error:
                    raise SonexisProtocolError("malformed_json", "Runtime sent invalid JSON") from error
                request_id = response.get("request_id")
                future = self._pending.get(request_id)
                if future is None and request_id in self._discarded_request_ids:
                    self._discarded_request_ids.discard(request_id)
                    continue
                if future is None or future.done():
                    raise SonexisProtocolError("unknown_response", "Runtime sent an unknown response ID")
                if not response.get("ok", False):
                    future.set_exception(SonexisError.from_response(response))
                else:
                    future.set_result(response)
        except asyncio.CancelledError:
            raise
        except BaseException as error:
            sdk_error = error if isinstance(error, SonexisError) else SonexisConnectionError(
                "connection_lost", str(error), retryable=True)
            for future in list(self._pending.values()):
                if not future.done():
                    future.set_exception(sdk_error)


class CaptureSession(AsyncIterator[AudioFrame]):
    """An independent negotiated PCM stream and its capture lifecycle."""

    def __init__(self, client: Sonexis, info: CaptureInfo) -> None:
        self.client = client
        self.info = info
        self._reader: Optional[asyncio.StreamReader] = None
        self._writer: Optional[asyncio.StreamWriter] = None
        self._previous_sequence: Optional[int] = None
        self._closed = False

    def __repr__(self) -> str:
        return f"CaptureSession(id={self.info.id!r}, source={self.info.source_id!r}, format={self.info.format!r})"

    async def _open(self) -> None:
        self._reader, self._writer = await asyncio.open_unix_connection(self.info.data_socket_path)

    async def __aenter__(self) -> "CaptureSession":
        return self

    async def __aexit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        await self.aclose()

    def __aiter__(self) -> "CaptureSession":
        return self

    async def __anext__(self) -> AudioFrame:
        if self._closed or self._reader is None:
            raise StopAsyncIteration
        frame = await read_frame(self._reader, uuid.UUID(self.info.stream_id), self._previous_sequence)
        self._previous_sequence = frame.sequence
        if frame.frame_count == 0:
            await self.aclose(stop_runtime=False)
            raise StopAsyncIteration
        return frame

    async def aclose(self, *, stop_runtime: bool = True) -> None:
        if self._closed:
            return
        self._closed = True
        writer, self._writer = self._writer, None
        self._reader = None
        if writer is not None:
            writer.close()
            try:
                await writer.wait_closed()
            except (OSError, ConnectionError):
                pass
        self.client._captures.discard(self)
        if stop_runtime and self.client._writer is not None:
            try:
                await asyncio.wait_for(asyncio.shield(self.client.stop(self.info.id)), timeout=1.0)
            except (SonexisError, asyncio.TimeoutError, OSError):
                pass


class EventSubscription(AsyncIterator[RuntimeEvent]):
    """A bounded Runtime event stream."""

    def __init__(self, client: Sonexis, value: Dict[str, Any]) -> None:
        self.client = client
        self.id = str(value["id"])
        self.socket_path = str(value["event_socket_path"])
        self.event_types = tuple(value["event_types"])
        self._reader: Optional[asyncio.StreamReader] = None
        self._writer: Optional[asyncio.StreamWriter] = None
        self._closed = False

    async def _open(self) -> None:
        self._reader, self._writer = await asyncio.open_unix_connection(
            self.socket_path, limit=MAX_CONTROL_BYTES + 1)

    async def __aenter__(self) -> "EventSubscription":
        return self

    async def __aexit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        await self.aclose()

    def __aiter__(self) -> "EventSubscription":
        return self

    async def __anext__(self) -> RuntimeEvent:
        if self._closed or self._reader is None:
            raise StopAsyncIteration
        line = await self._reader.readline()
        if not line:
            await self.aclose(unsubscribe=False)
            raise StopAsyncIteration
        if len(line) > MAX_CONTROL_BYTES or not line.endswith(b"\n"):
            raise SonexisProtocolError("invalid_event", "Invalid event framing")
        try:
            return RuntimeEvent.from_wire(json.loads(line))
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
            raise SonexisProtocolError("invalid_event", "Runtime sent a malformed event") from error

    async def aclose(self, *, unsubscribe: bool = True) -> None:
        if self._closed:
            return
        self._closed = True
        writer, self._writer = self._writer, None
        self._reader = None
        if writer is not None:
            writer.close()
            try:
                await writer.wait_closed()
            except (OSError, ConnectionError):
                pass
        self.client._events.discard(self)
        if unsubscribe and self.client._writer is not None:
            try:
                await self.client._request("unsubscribe_events", subscription_id=self.id)
            except SonexisError:
                pass
