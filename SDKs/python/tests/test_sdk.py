import asyncio
import json
import os
import struct
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "src"))

from sonexis import (AudioFormat, CaptureInfo, CaptureSession, EventSubscription,
                     SampleFormat, SessionMetrics, Sonexis, SonexisError,
                     SonexisProtocolError)
from sonexis.protocol import FLAG_DISCONTINUITY, FLAG_EOS, PCM_HEADER, PCM_MAGIC, read_frame


class FakeRuntime:
    def __init__(self, directory):
        self.directory = directory
        self.control_path = os.path.join(directory, "control.sock")
        self.stream_path = os.path.join(directory, "stream.sock")
        self.event_path = os.path.join(directory, "events.sock")
        self.stream_id = uuid.uuid4()
        self.control_server = None
        self.stream_server = None
        self.event_server = None
        self.commands = []
        self.malformed_handshake = False
        self.sources = [{"id": "app.test", "kind": "application",
            "name": "Test Audio", "process_ids": [123], "bundle_identifier": "test",
            "process_state": "running", "is_available": True,
            "is_producing_audio": True, "native_format": None},
            {"id": "missing-stream", "kind": "application",
             "name": "Missing Stream", "process_ids": [456],
             "bundle_identifier": "test.missing", "process_state": "running",
             "is_available": True, "is_producing_audio": False, "native_format": None}]

    async def start(self):
        self.stream_server = await asyncio.start_unix_server(self._stream, self.stream_path)
        self.event_server = await asyncio.start_unix_server(self._events, self.event_path)
        self.control_server = await asyncio.start_unix_server(self._control, self.control_path)

    async def close(self):
        for server in (self.control_server, self.stream_server, self.event_server):
            if server:
                server.close()
                await server.wait_closed()

    async def _control(self, reader, writer):
        try:
            while line := await reader.readline():
                request = json.loads(line)
                request_id = request["request_id"]
                command = request["command"]
                self.commands.append(command)
                response = {"message_type": "response", "protocol_version": 2,
                            "response_id": str(uuid.uuid4()), "request_id": request_id, "ok": True}
                if command == "hello":
                    response["handshake"] = {
                        "protocol_version": 2, "runtime_version": "0.2.0",
                        "runtime_instance_id": "instance", "capabilities": ["event_stream"],
                        "supported_formats": [AudioFormat().to_wire()],
                        "limits": {"maximum_sessions": 16},
                    }
                    if self.malformed_handshake:
                        response["handshake"].pop("runtime_version")
                elif command == "list_sources":
                    response["sources"] = self.sources
                elif command == "start_capture":
                    if request.get("source_id") == "bad":
                        response.update(ok=False, error={"code": "source_not_found",
                            "message": "missing", "retryable": False})
                    else:
                        fmt = request.get("format", AudioFormat().to_wire())
                        response["session"] = {"id": "session", "stream_id": str(self.stream_id),
                            "source_id": request.get("source_id"), "state": "capturing", "format": fmt,
                            "data_socket_path": self.stream_path, "started_at_nanoseconds": 10,
                            "metrics": {}}
                        if request.get("source_id") == "missing-stream":
                            response["session"]["data_socket_path"] = os.path.join(
                                self.directory, "missing-stream.sock")
                elif command == "stop_capture":
                    response["session"] = {"id": "session", "stream_id": str(self.stream_id),
                        "source_id": "app.test", "state": "stopped",
                        "format": AudioFormat().to_wire(), "data_socket_path": self.stream_path,
                        "started_at_nanoseconds": 10, "metrics": {}}
                elif command == "runtime_status":
                    response["status"] = {"runtime_version": "0.2.0",
                        "runtime_instance_id": "instance", "uptime_nanoseconds": 12,
                        "active_clients": 1, "active_sessions": 0, "event_subscribers": 0,
                        "total_sessions_started": 1, "total_frames_forwarded": 160,
                        "total_dropped_frames": 0, "total_bytes_transmitted": 320}
                elif command == "session_status":
                    response["session"] = {"id": request["session_id"],
                        "stream_id": str(self.stream_id), "source_id": "app.test",
                        "state": "stopped", "format": AudioFormat().to_wire(),
                        "data_socket_path": self.stream_path,
                        "started_at_nanoseconds": 10, "metrics": {}}
                elif command == "subscribe_events":
                    response["subscription"] = {"id": "events", "event_socket_path": self.event_path,
                        "event_types": ["runtime_warning"]}
                elif command == "unsubscribe_events":
                    response["message"] = "unsubscribed"
                elif command == "ping":
                    await asyncio.sleep(0.02)
                    response["message"] = "pong"
                else:
                    response["message"] = "pong"
                writer.write(json.dumps(response).encode() + b"\n")
                await writer.drain()
        finally:
            writer.close()
            await writer.wait_closed()

    async def _stream(self, reader, writer):
        payload = bytes(range(32)) * 10
        header = PCM_HEADER.pack(PCM_MAGIC, 2, FLAG_DISCONTINUITY, 64, len(payload),
            self.stream_id.bytes, 0, 0, 16000, 160, 1, 1, 7)
        packet = header + payload
        for index in range(0, len(packet), 7):
            writer.write(packet[index:index + 7])
            await writer.drain()
        eos = PCM_HEADER.pack(PCM_MAGIC, 2, FLAG_EOS, 64, 0, self.stream_id.bytes,
                              1, 10_000_000, 0, 0, 0, 1, 0)
        writer.write(eos)
        await writer.drain()
        writer.close()
        await writer.wait_closed()

    async def _events(self, reader, writer):
        event = {"protocol_version": 2, "event_id": "event-1", "type": "runtime_warning",
                 "timestamp_nanoseconds": 20, "message": "synthetic"}
        try:
            writer.write(json.dumps(event).encode() + b"\n")
            await writer.drain()
        except (ConnectionError, OSError):
            pass
        writer.close()
        try:
            await writer.wait_closed()
        except (ConnectionError, OSError):
            pass


class SDKTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.runtime = FakeRuntime(self.temp.name)
        await self.runtime.start()

    async def asyncTearDown(self):
        await self.runtime.close()
        self.temp.cleanup()

    async def test_handshake_sources_status_error_and_context_cleanup(self):
        async with Sonexis(self.runtime.control_path) as client:
            self.assertEqual(client.handshake.protocol_version, 2)
            sources = await client.sources()
            self.assertEqual(sources[0].id, "app.test")
            self.assertEqual(sources[0].process_ids, [123])
            status = await client.status()
            self.assertEqual(status.total_frames_forwarded, 160)
            with self.assertRaises(SonexisError) as caught:
                await client.capture("bad")
            self.assertEqual(caught.exception.code, "source_not_found")

    async def test_capture_iteration_and_eos(self):
        async with Sonexis(self.runtime.control_path) as client:
            async with await client.capture("app.test") as capture:
                frames = [frame async for frame in capture]
            self.assertEqual(len(frames), 1)
            self.assertEqual(frames[0].frame_count, 160)
            self.assertTrue(frames[0].discontinuity)
            self.assertEqual(frames[0].dropped_frames_before, 7)

    async def test_event_iteration(self):
        async with Sonexis(self.runtime.control_path) as client:
            async with await client.events() as events:
                event = await events.__anext__()
                self.assertEqual(event.type, "runtime_warning")
                self.assertEqual(event.message, "synthetic")
                with self.assertRaises(StopAsyncIteration):
                    await events.__anext__()
            self.assertEqual(self.runtime.commands.count("unsubscribe_events"), 1)

    async def test_concurrent_requests_are_correlated(self):
        async with Sonexis(self.runtime.control_path) as client:
            results = await asyncio.gather(*(client.sources() for _ in range(20)))
            self.assertTrue(all(result[0].id == "app.test" for result in results))

    async def test_cancelled_request_does_not_poison_connection(self):
        async with Sonexis(self.runtime.control_path) as client:
            request = asyncio.create_task(client._request("ping"))
            await asyncio.sleep(0)
            request.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await request
            await asyncio.sleep(0.03)
            self.assertEqual((await client.sources())[0].id, "app.test")

    async def test_truncated_and_wrong_stream_frames_fail(self):
        reader = asyncio.StreamReader()
        reader.feed_data(b"short")
        reader.feed_eof()
        with self.assertRaises(SonexisProtocolError) as truncated:
            await read_frame(reader, self.runtime.stream_id, None)
        self.assertEqual(truncated.exception.code, "truncated_pcm_stream")

        payload = b"\0\0"
        raw = PCM_HEADER.pack(PCM_MAGIC, 2, 0, 64, 2, uuid.uuid4().bytes,
                              0, 0, 16000, 1, 1, 1, 0) + payload
        reader = asyncio.StreamReader()
        reader.feed_data(raw)
        reader.feed_eof()
        with self.assertRaises(SonexisProtocolError) as mismatch:
            await read_frame(reader, self.runtime.stream_id, None)
        self.assertEqual(mismatch.exception.code, "stream_id_mismatch")

        backwards_eos = PCM_HEADER.pack(PCM_MAGIC, 2, FLAG_EOS, 64, 0,
            self.runtime.stream_id.bytes, 1, 0, 0, 0, 0, 1, 0)
        reader = asyncio.StreamReader()
        reader.feed_data(backwards_eos)
        reader.feed_eof()
        with self.assertRaises(SonexisProtocolError) as backwards:
            await read_frame(reader, self.runtime.stream_id, 10)
        self.assertEqual(backwards.exception.code, "invalid_pcm_sequence")

    async def test_capture_attach_failure_rolls_back_runtime_session(self):
        async with Sonexis(self.runtime.control_path) as client:
            with self.assertRaises(OSError):
                await client.capture("missing-stream")
            await asyncio.sleep(0)
            self.assertIn("stop_capture", self.runtime.commands)

    async def test_malformed_handshake_is_protocol_error_and_connection_resets(self):
        self.runtime.malformed_handshake = True
        client = Sonexis(self.runtime.control_path)
        with self.assertRaises(SonexisProtocolError):
            await client.connect()
        self.assertIsNone(client.handshake)
        self.assertIsNone(client._writer)

    async def test_cancelled_stream_cleanup_finishes_and_is_retryable(self):
        class BlockingWriter:
            def __init__(self):
                self.release = asyncio.Event()

            def close(self):
                pass

            async def wait_closed(self):
                await self.release.wait()

        async with Sonexis(self.runtime.control_path) as client:
            info = CaptureInfo("cancel-session", str(self.runtime.stream_id), "app.test",
                "capturing", AudioFormat(), self.runtime.stream_path, 0, SessionMetrics())
            capture = CaptureSession(client, info)
            capture_writer = BlockingWriter()
            capture._writer = capture_writer
            client._captures.add(capture)
            closing = asyncio.create_task(capture.aclose())
            await asyncio.sleep(0)
            closing.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await closing
            capture_writer.release.set()
            await capture.aclose()
            self.assertNotIn(capture, client._captures)
            self.assertIn("stop_capture", self.runtime.commands)

            subscription = EventSubscription(client, {"id": "cancel-events",
                "event_socket_path": self.runtime.event_path,
                "event_types": ["runtime_warning"]})
            event_writer = BlockingWriter()
            subscription._writer = event_writer
            client._events.add(subscription)
            closing = asyncio.create_task(subscription.aclose())
            await asyncio.sleep(0)
            closing.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await closing
            event_writer.release.set()
            await subscription.aclose()
            self.assertNotIn(subscription, client._events)
            self.assertIn("unsubscribe_events", self.runtime.commands)


if __name__ == "__main__":
    unittest.main()
