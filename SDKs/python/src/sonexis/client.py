"""Async public client for Sonexis Runtime."""

import asyncio
from dataclasses import replace
import json
import os
import time
import uuid
from typing import Any, AsyncIterator, Dict, Iterable, List, Optional, Set, TYPE_CHECKING, Union

from .errors import (AmbiguousOutputDestinationError, AmbiguousSourceError,
                     CaptureFailedError, OutputDestinationNotFoundError,
                     SonexisConnectionError, SonexisError, SonexisProtocolError,
                     SourceNotFoundError, UnsupportedFormatError)
from .models import (AudioFormat, AudioFrame, AudioOutputDestination, AudioSource,
                     CaptureInfo, Handshake, OutputInfo, RuntimeEvent, RuntimeStatus)
from .protocol import FLAG_EOS, MAX_CONTROL_BYTES, PROTOCOL_VERSION, read_frame

SourceSelector = Union[str, int, AudioSource]
OutputDestinationSelector = Union[str, AudioOutputDestination]

RUNTIME_EVENT_TYPES = (
    "source_added", "source_removed", "source_updated", "capture_started",
    "capture_stopped", "capture_failed", "client_warning", "device_changed",
    "runtime_warning", "runtime_shutting_down", "output_started", "output_stopped",
    "output_cancelled", "output_failed", "output_underrun", "output_overrun",
    "output_dropped", "output_destination_changed", "output_destination_added",
    "output_destination_removed", "output_destination_updated", "output_default_changed",
)

if TYPE_CHECKING:
    from .duplex import DuplexSession
    from .output import AudioOutput


class Sonexis:
    """A reusable asynchronous connection to the local Sonexis Runtime."""

    def __init__(self, socket_path: Optional[str] = None, *, client_name: str = "sonexis-python",
                 client_version: str = "0.6.0") -> None:
        self.socket_path = socket_path or os.environ.get(
            "SONEXIS_RUNTIME_SOCKET", f"/tmp/sonexis-runtime-{os.getuid()}/control.sock")
        self.client_name = client_name
        self.client_version = client_version
        self.handshake: Optional[Handshake] = None
        self._reader: Optional[asyncio.StreamReader] = None
        self._writer: Optional[asyncio.StreamWriter] = None
        self._reader_task: Optional[asyncio.Task] = None
        self._connect_task: Optional[asyncio.Task] = None
        self._write_lock = asyncio.Lock()
        self._pending: Dict[str, asyncio.Future] = {}
        self._discarded_request_ids: Set[str] = set()
        self._captures: Set["CaptureSession"] = set()
        self._events: Set["EventSubscription"] = set()
        self._outputs: Set["AudioOutput"] = set()
        self._close_task: Optional[asyncio.Task] = None

    async def __aenter__(self) -> "Sonexis":
        await self.connect()
        return self

    async def __aexit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        await self.close()

    async def connect(self, *, reconnect_attempts: int = 0) -> Handshake:
        if self._writer is not None and self.handshake is not None:
            return self.handshake
        if self._connect_task is None:
            self._connect_task = asyncio.create_task(
                self._finish_connect(reconnect_attempts), name="sonexis-connect")
        task = self._connect_task
        try:
            return await asyncio.shield(task)
        finally:
            if task.done() and self._connect_task is task:
                self._connect_task = None

    async def _finish_connect(self, reconnect_attempts: int) -> Handshake:
        if self._close_task is not None:
            await asyncio.shield(self._close_task)
            self._close_task = None
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
            except asyncio.CancelledError:
                if self._close_task is None:
                    await self.close()
                raise
            except BaseException as error:
                if isinstance(error, OSError):
                    reason = error.strerror or str(error)
                    last_error = SonexisConnectionError(
                        "runtime_unavailable",
                        "Cannot connect to Sonexis Runtime at "
                        f"{self.socket_path}. Start the local sonexis-runtime process "
                        f"or verify SONEXIS_RUNTIME_SOCKET. ({reason})",
                        retryable=True,
                        details={"socket_path": self.socket_path},
                    )
                elif isinstance(error, SonexisError):
                    last_error = error
                else:
                    last_error = SonexisProtocolError(
                        "invalid_handshake", "Runtime sent a malformed handshake")
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
        connect_task = self._connect_task
        if (connect_task is not None and connect_task is not asyncio.current_task()
                and not connect_task.done()):
            connect_task.cancel()
            await asyncio.gather(connect_task, return_exceptions=True)
        if self._close_task is None:
            self._close_task = asyncio.create_task(
                self._finish_close(), name="sonexis-client-cleanup")
        task = self._close_task
        try:
            await asyncio.shield(task)
        finally:
            if task.done() and self._close_task is task:
                self._close_task = None

    async def _finish_close(self) -> None:
        captures = list(self._captures)
        events = list(self._events)
        outputs = list(self._outputs)
        for capture in captures:
            await capture.aclose(stop_runtime=False)
        for subscription in events:
            await subscription.aclose(unsubscribe=False)
        for output in outputs:
            await output.aclose(drain=False, stop_runtime=False)
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
        """Return the Runtime's current application-source snapshot."""
        response = await self._request("list_sources")
        try:
            return [AudioSource.from_wire(value) for value in response["sources"]]
        except (KeyError, TypeError, ValueError) as error:
            raise SonexisProtocolError("invalid_sources", "Runtime sent malformed sources") from error

    async def find_sources(
        self,
        query: Optional[str] = None,
        *,
        source_id: Optional[str] = None,
        bundle_identifier: Optional[str] = None,
        pid: Optional[int] = None,
        name: Optional[str] = None,
        available_only: bool = True,
    ) -> List[AudioSource]:
        """Return sources matching explicit fields or a case-insensitive search string."""
        values = await self.sources()
        matches: List[AudioSource] = []
        for source in values:
            if available_only and not source.available:
                continue
            if source_id is not None and source.id != source_id:
                continue
            if bundle_identifier is not None and source.bundle_identifier != bundle_identifier:
                continue
            if pid is not None and pid not in source.process_ids:
                continue
            if name is not None and source.name != name:
                continue
            if query is not None:
                folded = query.casefold()
                fields = (source.id, source.name, source.bundle_identifier or "")
                if not any(folded in value.casefold() for value in fields):
                    continue
            matches.append(source)
        return matches

    async def get_source(self, selector: SourceSelector) -> AudioSource:
        """Resolve an ID, bundle ID, PID, exact app name, or source object uniquely."""
        if isinstance(selector, AudioSource):
            candidates = [source for source in await self.sources()
                          if source.id == selector.id and source.available]
        elif isinstance(selector, int):
            candidates = [source for source in await self.sources()
                          if selector in source.process_ids and source.available]
        else:
            sources = [source for source in await self.sources() if source.available]
            candidates = [source for source in sources if source.id == selector]
            if not candidates:
                candidates = [source for source in sources
                              if source.bundle_identifier == selector]
            if not candidates:
                candidates = [source for source in sources if source.name == selector]
            if not candidates:
                folded = selector.casefold()
                candidates = [source for source in sources
                              if source.name.casefold() == folded]
        if not candidates:
            raise SourceNotFoundError(
                "source_not_found", f"No available audio source matches {selector!r}", retryable=True)
        if len(candidates) > 1:
            details = {f"candidate_{index}": source.id
                       for index, source in enumerate(candidates, 1)}
            raise AmbiguousSourceError(
                "ambiguous_source", f"Audio source selector {selector!r} is ambiguous",
                details=details)
        return candidates[0]

    async def wait_for_source(
        self,
        selector: SourceSelector,
        *,
        timeout: Optional[float] = None,
        poll_interval: float = 0.25,
    ) -> AudioSource:
        """Wait for a fresh, uniquely resolved source snapshot to become available."""
        if poll_interval <= 0:
            raise ValueError("poll_interval must be positive")
        deadline = None if timeout is None else asyncio.get_running_loop().time() + timeout
        while True:
            try:
                return await self.get_source(selector)
            except SourceNotFoundError:
                if deadline is not None:
                    remaining = deadline - asyncio.get_running_loop().time()
                    if remaining <= 0:
                        raise SourceNotFoundError(
                            "source_wait_timeout",
                            f"Timed out waiting for audio source {selector!r}", retryable=True)
                    await asyncio.sleep(min(poll_interval, remaining))
                else:
                    await asyncio.sleep(poll_interval)

    async def status(self, session_id: Optional[str] = None) -> Union[RuntimeStatus, CaptureInfo]:
        if session_id is None:
            response = await self._request("runtime_status")
            try:
                return RuntimeStatus.from_wire(response["status"])
            except (KeyError, TypeError, ValueError) as error:
                raise SonexisProtocolError("invalid_status", "Runtime sent malformed status") from error
        response = await self._request("session_status", session_id=session_id)
        try:
            return CaptureInfo.from_wire(response["session"])
        except (KeyError, TypeError, ValueError) as error:
            raise SonexisProtocolError("invalid_session", "Runtime sent a malformed session") from error

    async def create_capture(self, source: SourceSelector, *,
                             format: AudioFormat = AudioFormat()) -> CaptureInfo:
        """Create a Runtime capture without attaching its binary data socket."""
        resolved = await self.get_source(source)
        response = await self._request("start_capture", source_id=resolved.id,
                                       format=format.to_wire())
        try:
            return CaptureInfo.from_wire(response["session"])
        except (KeyError, TypeError, ValueError) as error:
            raise SonexisProtocolError("invalid_session", "Runtime sent a malformed session") from error

    async def attach_capture(
        self,
        capture: Union[str, CaptureInfo],
        *,
        source: Optional[AudioSource] = None,
    ) -> "CaptureSession":
        """Attach the PCM plane for an existing same-user Runtime capture."""
        info: CaptureInfo
        if isinstance(capture, str):
            value = await self.status(capture)
            assert isinstance(value, CaptureInfo)
            info = value
        else:
            info = capture
        resolved = source or await self.get_source(info.source_id)
        session = CaptureSession(self, info, resolved)
        await session._open()
        self._captures.add(session)
        return session

    async def capture(self, source: SourceSelector, *,
                      format: AudioFormat = AudioFormat()) -> "CaptureSession":
        """Resolve one source, start capture, and attach its binary PCM stream."""
        resolved = await self.get_source(source)
        response = await self._request("start_capture", source_id=resolved.id,
                                       format=format.to_wire())
        try:
            info = CaptureInfo.from_wire(response["session"])
            capture = CaptureSession(self, info, resolved)
        except (KeyError, TypeError, ValueError) as error:
            raise SonexisProtocolError("invalid_session", "Runtime sent a malformed session") from error
        try:
            await capture._open()
        except BaseException:
            await self._cleanup_request("stop_capture", session_id=capture.info.id)
            raise
        self._captures.add(capture)
        return capture

    def session(self, *, max_queue_frames: int = 128) -> "MultiSourceSession":
        """Create a labeled multi-source capture session."""
        from .multi import MultiSourceSession
        return MultiSourceSession(self, max_queue_frames=max_queue_frames)

    def duplex(self, input_source: SourceSelector, *,
               output_destination: Union[str, AudioOutputDestination] = "default",
               input_format: AudioFormat = AudioFormat(),
               output_format: AudioFormat = AudioFormat.openai_realtime_output(),
               target_buffer_milliseconds: int = 60) -> "DuplexSession":
        """Compose one independent capture and output session."""
        from .duplex import DuplexSession
        return DuplexSession(self, input_source,
                             output_destination=output_destination,
                             input_format=input_format, output_format=output_format,
                             target_buffer_milliseconds=target_buffer_milliseconds)

    async def stop(self, session_id: str) -> CaptureInfo:
        response = await self._request("stop_capture", session_id=session_id)
        try:
            return CaptureInfo.from_wire(response["session"])
        except (KeyError, TypeError, ValueError) as error:
            raise SonexisProtocolError("invalid_session", "Runtime sent a malformed session") from error

    async def events(self, event_types: Optional[Iterable[str]] = None) -> "EventSubscription":
        """Subscribe to a bounded Runtime lifecycle event stream."""
        params: Dict[str, Any] = {
            "event_types": list(RUNTIME_EVENT_TYPES if event_types is None else event_types)
        }
        response = await self._request("subscribe_events", **params)
        try:
            subscription = EventSubscription(self, response["subscription"])
        except (KeyError, TypeError, ValueError) as error:
            raise SonexisProtocolError("invalid_subscription",
                                       "Runtime sent a malformed event subscription") from error
        try:
            await subscription._open()
        except BaseException:
            await self._cleanup_request("unsubscribe_events", subscription_id=subscription.id)
            raise
        self._events.add(subscription)
        return subscription

    def _require_output_capability(self) -> None:
        handshake = self.handshake
        if handshake is None:
            raise SonexisConnectionError("not_connected", "Connect to Sonexis Runtime first")
        if "output_sessions" not in handshake.capabilities:
            raise SonexisError(
                "unsupported_capability",
                "This Runtime does not support client-to-Runtime audio output; Runtime v0.4 is required",
            )

    async def output_destinations(self) -> List[AudioOutputDestination]:
        """Return destinations that can render client-provided realtime audio."""
        self._require_output_capability()
        response = await self._request("list_output_destinations")
        try:
            return [AudioOutputDestination.from_wire(value)
                    for value in response["output_destinations"]]
        except (KeyError, TypeError, ValueError) as error:
            raise SonexisProtocolError(
                "invalid_output_destinations",
                "Runtime sent malformed output destinations",
            ) from error

    async def find_output_destinations(
        self,
        query: Optional[str] = None,
        *,
        destination_id: Optional[str] = None,
        name: Optional[str] = None,
        kind: Optional[str] = None,
        available_only: bool = True,
    ) -> List[AudioOutputDestination]:
        """Return output destinations matching explicit fields or a text query."""
        matches: List[AudioOutputDestination] = []
        folded_query = query.casefold() if query is not None else None
        for destination in await self.output_destinations():
            if available_only and not destination.available:
                continue
            if destination_id is not None and destination.id != destination_id:
                continue
            if name is not None and destination.name != name:
                continue
            if kind is not None and destination.kind != kind:
                continue
            if folded_query is not None and not any(
                folded_query in value.casefold()
                for value in (destination.id, destination.name,
                              destination.active_device_name or "")
            ):
                continue
            matches.append(destination)
        return matches

    async def get_output_destination(
        self,
        selector: Optional[OutputDestinationSelector] = "default",
        *,
        kind: Optional[str] = None,
    ) -> AudioOutputDestination:
        """Resolve an output ID, exact name, kind alias, or typed object uniquely."""
        available = [destination for destination in await self.output_destinations()
                     if destination.available]
        if selector is None:
            candidates = available
        elif isinstance(selector, AudioOutputDestination):
            candidates = [destination for destination in available
                          if destination.id == selector.id]
        else:
            candidates = [destination for destination in available
                          if destination.id == selector]
            if not candidates:
                candidates = [destination for destination in available
                              if destination.name == selector]
            if not candidates:
                folded = selector.casefold()
                candidates = [destination for destination in available
                              if destination.name.casefold() == folded]
            if not candidates and selector.casefold() in ("loopback", "virtual_input"):
                candidates = [destination for destination in available
                              if destination.kind == "virtual_input"]
        if kind is not None:
            candidates = [destination for destination in candidates
                          if destination.kind == kind]
        if not candidates:
            raise OutputDestinationNotFoundError(
                "output_destination_not_found",
                f"No available output destination matches {selector!r}", retryable=True)
        if len(candidates) > 1:
            details = {f"candidate_{index}": destination.id
                       for index, destination in enumerate(candidates, 1)}
            raise AmbiguousOutputDestinationError(
                "ambiguous_output_destination",
                f"Output destination selector {selector!r} is ambiguous",
                details=details)
        return candidates[0]

    async def wait_for_output_destination(
        self,
        selector: Optional[OutputDestinationSelector] = None,
        *,
        kind: Optional[str] = None,
        timeout: Optional[float] = None,
        poll_interval: float = 0.25,
    ) -> AudioOutputDestination:
        """Wait until a fresh, uniquely resolved output destination is available."""
        if poll_interval <= 0:
            raise ValueError("poll_interval must be positive")
        deadline = None if timeout is None else asyncio.get_running_loop().time() + timeout
        while True:
            try:
                return await self.get_output_destination(selector, kind=kind)
            except OutputDestinationNotFoundError:
                if deadline is not None:
                    remaining = deadline - asyncio.get_running_loop().time()
                    if remaining <= 0:
                        raise OutputDestinationNotFoundError(
                            "output_destination_wait_timeout",
                            f"Timed out waiting for output destination {selector!r}",
                            retryable=True)
                    await asyncio.sleep(min(poll_interval, remaining))
                else:
                    await asyncio.sleep(poll_interval)

    async def create_output(
        self,
        *,
        destination: OutputDestinationSelector = "default",
        format: AudioFormat = AudioFormat.openai_realtime_output(),
        target_buffer_milliseconds: int = 60,
    ) -> "AudioOutput":
        """Create and attach a bounded client-to-Runtime PCM output stream."""
        from .output import AudioOutput

        self._require_output_capability()
        if not 20 <= target_buffer_milliseconds <= 250:
            raise ValueError("target_buffer_milliseconds must be between 20 and 250")
        resolved_destination = await self.get_output_destination(destination)
        if (resolved_destination.supported_formats
                and format not in resolved_destination.supported_formats):
            raise UnsupportedFormatError(
                "unsupported_output_format",
                f"{resolved_destination.name} does not advertise support for {format!r}",
                details={"destination_id": resolved_destination.id})
        response = await self._request(
            "start_output",
            destination_id=resolved_destination.id,
            format=format.to_wire(),
            target_buffer_milliseconds=target_buffer_milliseconds,
        )
        try:
            output = AudioOutput(self, OutputInfo.from_wire(response["output_session"]),
                                 resolved_destination)
        except (KeyError, TypeError, ValueError) as error:
            raise SonexisProtocolError(
                "invalid_output_session", "Runtime sent a malformed output session") from error
        try:
            await output._open()
        except BaseException:
            await self._cleanup_request("stop_output", output_session_id=output.info.id)
            raise
        self._outputs.add(output)
        return output

    async def playback(
        self,
        *,
        destination: OutputDestinationSelector = "default",
        format: AudioFormat = AudioFormat.openai_realtime_output(),
        target_buffer_milliseconds: int = 60,
    ) -> "AudioOutput":
        """Convenience alias for :meth:`create_output`."""
        return await self.create_output(
            destination=destination,
            format=format,
            target_buffer_milliseconds=target_buffer_milliseconds,
        )

    async def output_status(self, output_session_id: str) -> OutputInfo:
        """Return current state and metrics for one output session."""
        self._require_output_capability()
        response = await self._request(
            "output_status", output_session_id=output_session_id)
        try:
            return OutputInfo.from_wire(response["output_session"])
        except (KeyError, TypeError, ValueError) as error:
            raise SonexisProtocolError(
                "invalid_output_session", "Runtime sent a malformed output session") from error

    async def stop_output(self, output_session_id: str) -> OutputInfo:
        """Stop one output session by ID."""
        self._require_output_capability()
        response = await self._request(
            "stop_output", output_session_id=output_session_id)
        try:
            return OutputInfo.from_wire(response["output_session"])
        except (KeyError, TypeError, ValueError) as error:
            raise SonexisProtocolError(
                "invalid_output_session", "Runtime sent a malformed output session") from error

    async def _flush_output(self, output_session_id: str) -> OutputInfo:
        self._require_output_capability()
        response = await self._request(
            "flush_output", output_session_id=output_session_id)
        try:
            return OutputInfo.from_wire(response["output_session"])
        except (KeyError, TypeError, ValueError) as error:
            raise SonexisProtocolError(
                "invalid_output_session", "Runtime sent a malformed output session") from error

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
        except asyncio.CancelledError:
            # The request may already be in the kernel buffer. Its eventual
            # response is valid but no longer has a waiter.
            self._discarded_request_ids.add(request_id)
            raise
        except (OSError, ConnectionError) as error:
            raise SonexisConnectionError("connection_lost", str(error), retryable=True) from error
        finally:
            self._pending.pop(request_id, None)
            if len(self._discarded_request_ids) > 1024:
                self._discarded_request_ids.clear()

    async def _cleanup_request(self, command: str, **parameters: Any) -> None:
        """Complete bounded Runtime cleanup even if the caller is cancelled."""
        if self._writer is None:
            return
        task = asyncio.create_task(self._request(command, **parameters))
        cancelled = False
        try:
            await asyncio.wait_for(asyncio.shield(task), timeout=1.0)
        except asyncio.CancelledError:
            cancelled = True
            try:
                await asyncio.wait_for(asyncio.shield(task), timeout=1.0)
            except (SonexisError, asyncio.TimeoutError, OSError):
                pass
        except (SonexisError, asyncio.TimeoutError, OSError):
            pass
        finally:
            if not task.done():
                task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        if cancelled:
            raise asyncio.CancelledError

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
                if (not isinstance(response, dict)
                        or response.get("message_type") != "response"
                        or response.get("protocol_version") != PROTOCOL_VERSION
                        or not isinstance(response.get("response_id"), str)
                        or not isinstance(response.get("request_id"), str)
                        or not isinstance(response.get("ok"), bool)):
                    raise SonexisProtocolError("invalid_response", "Runtime sent an invalid response envelope")
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
            writer = self._writer
            self._reader = None
            self._writer = None
            self.handshake = None
            if writer is not None:
                writer.close()
            self._reader_task = None


class CaptureSession(AsyncIterator[AudioFrame]):
    """An independent negotiated PCM stream and its capture lifecycle."""

    def __init__(self, client: Sonexis, info: CaptureInfo,
                 source: Optional[AudioSource] = None) -> None:
        self.client = client
        self.info = info
        self.source = source
        self._reader: Optional[asyncio.StreamReader] = None
        self._writer: Optional[asyncio.StreamWriter] = None
        self._previous_sequence: Optional[int] = None
        self._closed = False
        self._cleanup_task: Optional[asyncio.Task] = None
        self.terminal_info: Optional[CaptureInfo] = None
        self.terminal_error: Optional[SonexisError] = None

    def __repr__(self) -> str:
        name = self.source.name if self.source else self.info.source_id
        return f"CaptureSession(id={self.info.id!r}, source={name!r}, format={self.info.format!r})"

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
        try:
            frame = await read_frame(self._reader, uuid.UUID(self.info.stream_id), self._previous_sequence)
        except BaseException as error:
            intentional_close = self._closed
            await self.aclose()
            if intentional_close and not isinstance(error, asyncio.CancelledError):
                raise StopAsyncIteration
            raise
        self._previous_sequence = frame.sequence
        if frame.frame_count == 0:
            await self.aclose(stop_runtime=False)
            status = await self.client.status(self.info.id)
            assert isinstance(status, CaptureInfo)
            self.terminal_info = status
            if status.state == "failed":
                failure = status.error
                self.terminal_error = CaptureFailedError(
                    failure.code if failure else "capture_failed",
                    failure.message if failure else "Capture failed",
                    retryable=failure.retryable if failure else False,
                    details=failure.details if failure else None,
                )
                raise self.terminal_error
            raise StopAsyncIteration
        return replace(
            frame,
            source=self.source,
            session_id=self.info.id,
            runtime_started_at_ns=self.info.started_at_ns,
            received_at_ns=time.monotonic_ns(),
        )

    async def aclose(self, *, stop_runtime: bool = True) -> None:
        if self._cleanup_task is None:
            self._closed = True
            writer, self._writer = self._writer, None
            self._reader = None
            self._cleanup_task = asyncio.create_task(
                self._finish_cleanup(writer, stop_runtime), name="sonexis-capture-cleanup")
        await asyncio.shield(self._cleanup_task)

    async def _finish_cleanup(self, writer: Optional[asyncio.StreamWriter],
                              stop_runtime: bool) -> None:
        try:
            if writer is not None:
                writer.close()
                try:
                    await asyncio.wait_for(writer.wait_closed(), timeout=1.0)
                except (OSError, ConnectionError, asyncio.TimeoutError):
                    pass
        finally:
            self.client._captures.discard(self)
            if stop_runtime:
                await self.client._cleanup_request("stop_capture", session_id=self.info.id)


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
        self._cleanup_task: Optional[asyncio.Task] = None

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
        try:
            line = await self._reader.readline()
        except (ValueError, asyncio.LimitOverrunError) as error:
            await self.aclose()
            raise SonexisProtocolError(
                "invalid_event", "Event exceeded the 64 KiB framing limit") from error
        except BaseException:
            await self.aclose()
            raise
        if not line:
            if self._closed:
                raise StopAsyncIteration
            await self.aclose()
            raise SonexisConnectionError(
                "event_stream_closed", "Runtime event stream closed unexpectedly",
                retryable=True)
        if len(line) > MAX_CONTROL_BYTES or not line.endswith(b"\n"):
            await self.aclose()
            raise SonexisProtocolError("invalid_event", "Invalid event framing")
        try:
            return RuntimeEvent.from_wire(json.loads(line))
        except (KeyError, TypeError, ValueError, UnicodeDecodeError, json.JSONDecodeError) as error:
            await self.aclose()
            raise SonexisProtocolError("invalid_event", "Runtime sent a malformed event") from error

    async def aclose(self, *, unsubscribe: bool = True) -> None:
        if self._cleanup_task is None:
            self._closed = True
            writer, self._writer = self._writer, None
            self._reader = None
            self._cleanup_task = asyncio.create_task(
                self._finish_cleanup(writer, unsubscribe), name="sonexis-event-cleanup")
        await asyncio.shield(self._cleanup_task)

    async def _finish_cleanup(self, writer: Optional[asyncio.StreamWriter],
                              unsubscribe: bool) -> None:
        try:
            if writer is not None:
                writer.close()
                try:
                    await asyncio.wait_for(writer.wait_closed(), timeout=1.0)
                except (OSError, ConnectionError, asyncio.TimeoutError):
                    pass
        finally:
            self.client._events.discard(self)
            if unsubscribe:
                await self.client._cleanup_request("unsubscribe_events", subscription_id=self.id)
