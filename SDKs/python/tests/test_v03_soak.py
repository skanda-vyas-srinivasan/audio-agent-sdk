"""Deterministic long-running-consumer simulations for the public Python SDK."""

import asyncio
import gc
import json
import sys
import tempfile
import tracemalloc
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "src"))

from sonexis import AudioFormat, Sonexis
from sonexis.protocol import FLAG_EOS, PCM_HEADER, PCM_MAGIC


def _source(source_id, name, bundle, pid):
    return {
        "id": source_id,
        "kind": "application",
        "name": name,
        "process_ids": [pid],
        "bundle_identifier": bundle,
        "process_state": "running",
        "is_available": True,
        "is_producing_audio": True,
        "native_format": None,
    }


class StreamingRuntime:
    """Small protocol-v2 peer that emits finite, independent PCM streams."""

    def __init__(self, directory, *, frames_per_stream=96):
        self.directory = Path(directory)
        self.control_path = str(self.directory / "control.sock")
        self.frames_per_stream = frames_per_stream
        self.control_server = None
        self.stream_servers = {}
        self.sessions = {}
        self.terminal_sessions = {}
        self.sessions_started = 0
        self.connections_opened = 0
        self.connections_closed = 0
        self.sources = [
            _source("app.music", "Music", "test.music", 101),
            _source("app.conversation", "Conversation", "test.conversation", 202),
        ]

    async def start(self):
        self.control_server = await asyncio.start_unix_server(
            self._control, self.control_path)

    async def close(self):
        if self.control_server is not None:
            self.control_server.close()
            await self.control_server.wait_closed()
        for server in list(self.stream_servers.values()):
            server.close()
            await server.wait_closed()
        self.stream_servers.clear()

    async def wait_for_idle(self):
        for _ in range(100):
            if not self.sessions and self.connections_opened == self.connections_closed:
                return
            await asyncio.sleep(0.001)
        raise AssertionError(
            f"runtime did not become idle: sessions={len(self.sessions)}, "
            f"connections={self.connections_opened}/{self.connections_closed}"
        )

    async def _control(self, reader, writer):
        self.connections_opened += 1
        try:
            while line := await reader.readline():
                request = json.loads(line)
                response = {
                    "message_type": "response",
                    "protocol_version": 2,
                    "response_id": str(uuid.uuid4()),
                    "request_id": request["request_id"],
                    "ok": True,
                }
                command = request["command"]
                if command == "hello":
                    response["handshake"] = {
                        "protocol_version": 2,
                        "runtime_version": "0.3.0-test",
                        "runtime_instance_id": "soak-runtime",
                        "capabilities": ["multi_session", "format_negotiation"],
                        "supported_formats": [AudioFormat().to_wire()],
                        "limits": {"maximum_sessions": 16},
                    }
                elif command == "list_sources":
                    response["sources"] = self.sources
                elif command == "start_capture":
                    response["session"] = await self._start_capture(request)
                elif command == "stop_capture":
                    response["session"] = await self._stop_capture(request["session_id"])
                elif command == "session_status":
                    session = self.sessions.get(request["session_id"])
                    response["session"] = (
                        session
                        or self.terminal_sessions.get(request["session_id"])
                        or self._terminal_session(request["session_id"])
                    )
                elif command == "runtime_status":
                    response["status"] = {
                        "runtime_version": "0.3.0-test",
                        "runtime_instance_id": "soak-runtime",
                        "uptime_nanoseconds": 1,
                        "active_clients": 1,
                        "active_sessions": len(self.sessions),
                        "event_subscribers": 0,
                        "total_sessions_started": self.sessions_started,
                        "total_frames_forwarded": 0,
                        "total_dropped_frames": 0,
                        "total_bytes_transmitted": 0,
                    }
                else:
                    response.update(
                        ok=False,
                        error={"code": "invalid_command", "message": command,
                               "retryable": False},
                    )
                writer.write(json.dumps(response, separators=(",", ":")).encode() + b"\n")
                await writer.drain()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except (BrokenPipeError, ConnectionResetError):
                pass
            self.connections_closed += 1

    async def _start_capture(self, request):
        session_id = str(uuid.uuid4())
        stream_id = uuid.uuid4()
        stream_path = str(self.directory / f"s{self.sessions_started}.sock")
        format_value = request.get("format", AudioFormat().to_wire())
        info = {
            "id": session_id,
            "stream_id": str(stream_id),
            "source_id": request["source_id"],
            "state": "capturing",
            "format": format_value,
            "data_socket_path": stream_path,
            "started_at_nanoseconds": 1,
            "metrics": {},
        }
        server = await asyncio.start_unix_server(
            lambda reader, writer: self._stream(
                session_id, stream_id, format_value, reader, writer),
            stream_path,
        )
        self.stream_servers[session_id] = server
        self.sessions[session_id] = info
        self.sessions_started += 1
        return info

    async def _stop_capture(self, session_id):
        info = self.sessions.pop(session_id, None)
        server = self.stream_servers.pop(session_id, None)
        if server is not None:
            server.close()
            await server.wait_closed()
        if info is None:
            return self.terminal_sessions.get(
                session_id, self._terminal_session(session_id))
        return {**info, "state": "stopped"}

    def _terminal_session(self, session_id):
        return {
            "id": session_id,
            "stream_id": str(uuid.UUID(int=0)),
            "source_id": "app.music",
            "state": "stopped",
            "format": AudioFormat().to_wire(),
            "data_socket_path": "",
            "started_at_nanoseconds": 1,
            "metrics": {},
        }

    async def _stream(self, session_id, stream_id, format_value, _reader, writer):
        sample_rate = int(format_value["sample_rate"])
        channels = int(format_value["channel_count"])
        format_code = 1 if format_value["sample_format"] == "pcm_s16le" else 2
        bytes_per_sample = 2 if format_code == 1 else 4
        frame_count = 160
        payload = b"\0" * frame_count * channels * bytes_per_sample
        try:
            for sequence in range(self.frames_per_stream):
                timestamp = sequence * frame_count * 1_000_000_000 // sample_rate
                header = PCM_HEADER.pack(
                    PCM_MAGIC, 2, 0, PCM_HEADER.size, len(payload), stream_id.bytes,
                    sequence, timestamp, sample_rate, frame_count, channels, format_code, 0,
                )
                writer.write(header + payload)
                await writer.drain()
                await asyncio.sleep(0)
            eos = PCM_HEADER.pack(
                PCM_MAGIC, 2, FLAG_EOS, PCM_HEADER.size, 0, stream_id.bytes,
                self.frames_per_stream,
                self.frames_per_stream * frame_count * 1_000_000_000 // sample_rate,
                0, 0, 0, format_code, 0,
            )
            writer.write(eos)
            await writer.drain()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except (BrokenPipeError, ConnectionResetError):
                pass
            info = self.sessions.pop(session_id, None)
            if info is not None:
                self.terminal_sessions[session_id] = {**info, "state": "stopped"}
            server = self.stream_servers.pop(session_id, None)
            if server is not None:
                server.close()
                await server.wait_closed()


def _descriptor_count():
    descriptor_directory = Path("/dev/fd")
    if not descriptor_directory.exists():
        return None
    return len(list(descriptor_directory.iterdir()))


class AIConsumerSoakTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.runtime = StreamingRuntime(self.temporary.name)
        await self.runtime.start()

    async def asyncTearDown(self):
        await self.runtime.close()
        self.temporary.cleanup()

    async def test_slow_multi_source_consumer_is_bounded_and_reports_drops(self):
        labels = set()
        received_frames = 0
        async with Sonexis(self.runtime.control_path) as client:
            async with client.session(max_queue_packets=3) as group:
                await group.add("media", "Music")
                await group.add("conversation", "Conversation")
                async for item in group.frames():
                    labels.add(item.label)
                    received_frames += 1
                    # Deterministic provider slowdown: ingestion remains independent and bounded.
                    await asyncio.sleep(0.002)
                self.assertGreater(group.dropped_frames, 0)
                self.assertEqual(
                    received_frames + group.dropped_frames // 160,
                    2 * self.runtime.frames_per_stream,
                )
        await self.runtime.wait_for_idle()
        self.assertEqual(labels, {"media", "conversation"})
        self.assertEqual(self.runtime.sessions, {})

    async def test_cancel_reconnect_cycles_leave_no_sdk_tasks_sessions_or_descriptors(self):
        before_fds = _descriptor_count()
        tracemalloc.start()
        before_memory, _ = tracemalloc.get_traced_memory()

        for cycle in range(30):
            first_frame = asyncio.Event()
            async with Sonexis(self.runtime.control_path) as client:
                capture = await client.capture("Music")

                async def simulated_provider():
                    async for _frame in capture:
                        first_frame.set()
                        await asyncio.sleep(0.01 if cycle % 5 == 0 else 0)

                consumer = asyncio.create_task(
                    simulated_provider(), name=f"test-ai-provider-{cycle}")
                await asyncio.wait_for(first_frame.wait(), timeout=1)
                consumer.cancel()
                await asyncio.gather(consumer, return_exceptions=True)
                await capture.aclose()

        await self.runtime.wait_for_idle()
        await asyncio.sleep(0)
        gc.collect()
        after_memory, peak_memory = tracemalloc.get_traced_memory()
        tracemalloc.stop()
        after_fds = _descriptor_count()

        leaked_tasks = [
            task for task in asyncio.all_tasks()
            if task is not asyncio.current_task()
            and not task.done()
            and (task.get_name().startswith("sonexis-")
                 or task.get_name().startswith("test-ai-provider-"))
        ]
        self.assertEqual(leaked_tasks, [])
        self.assertEqual(self.runtime.sessions, {})
        self.assertEqual(self.runtime.connections_opened, self.runtime.connections_closed)
        if before_fds is not None and after_fds is not None:
            self.assertLessEqual(after_fds, before_fds + 3)
        # This catches retained per-cycle buffers while allowing interpreter/test noise.
        self.assertLess(after_memory - before_memory, 2 * 1024 * 1024)
        self.assertLess(peak_memory, 12 * 1024 * 1024)


if __name__ == "__main__":
    unittest.main()
