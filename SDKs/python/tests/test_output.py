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

from sonexis import (AudioFormat, AudioOutput, AudioOutputDestination, OutputInfo,
                     OutputFailedError, OutputMetrics, RuntimeEvent, SampleFormat,
                     Sonexis, SonexisError)
from sonexis.protocol import FLAG_DISCONTINUITY, FLAG_EOS, PCM_HEADER, PCM_MAGIC


class FakeOutputRuntime:
    def __init__(self, directory, *, output_capability=True):
        self.control_path = os.path.join(directory, "control.sock")
        self.stream_paths = [os.path.join(directory, f"output-{index}.sock") for index in range(2)]
        self.stream_ids = [uuid.uuid4(), uuid.uuid4()]
        self.control_server = None
        self.stream_servers = []
        self.output_capability = output_capability
        self.commands = []
        self.requests = []
        self.packets = [[], []]
        self.stream_closed = []
        self.flush_count = 0

    async def start(self):
        self.stream_closed = [asyncio.Event(), asyncio.Event()]
        for index, path in enumerate(self.stream_paths):
            server = await asyncio.start_unix_server(
                lambda reader, writer, index=index: self._stream(index, reader, writer), path)
            self.stream_servers.append(server)
        self.control_server = await asyncio.start_unix_server(self._control, self.control_path)

    async def close(self):
        servers = [self.control_server, *self.stream_servers]
        for server in servers:
            if server:
                server.close()
        for server in servers:
            if server:
                await server.wait_closed()

    def session(self, index=0, state="playing"):
        return {
            "id": "output-session",
            "stream_id": str(self.stream_ids[index]),
            "destination_id": "default",
            "state": state,
            "format": AudioFormat.openai_realtime().to_wire(),
            "data_socket_path": self.stream_paths[index],
            "started_at_nanoseconds": 100,
            "target_buffer_milliseconds": 80,
            "metrics": {
                "input_frames_received": 480,
                "device_frames_rendered": 240,
                "dropped_frames": 3,
                "buffered_milliseconds": 10.0,
            },
        }

    async def _control(self, reader, writer):
        try:
            while line := await reader.readline():
                request = json.loads(line)
                self.requests.append(request)
                command = request["command"]
                self.commands.append(command)
                response = {
                    "message_type": "response",
                    "protocol_version": 2,
                    "response_id": str(uuid.uuid4()),
                    "request_id": request["request_id"],
                    "ok": True,
                }
                if command == "hello":
                    capabilities = ["output_sessions", "output_pcm_v2"] \
                        if self.output_capability else []
                    response["handshake"] = {
                        "protocol_version": 2,
                        "runtime_version": "0.4.0" if self.output_capability else "0.3.0",
                        "runtime_instance_id": "instance",
                        "capabilities": capabilities,
                        "supported_formats": [AudioFormat.openai_realtime().to_wire()],
                        "limits": {"maximum_output_sessions": 8},
                    }
                elif command == "list_output_destinations":
                    response["output_destinations"] = [{
                        "id": "default", "name": "System Default", "kind": "default_device",
                        "is_available": True, "is_default": True,
                        "supported_formats": [AudioFormat.openai_realtime().to_wire()],
                    }]
                elif command == "start_output":
                    response["output_session"] = self.session()
                elif command == "output_status":
                    response["output_session"] = self.session(self.flush_count, "stopped")
                elif command == "flush_output":
                    self.flush_count = 1
                    response["output_session"] = self.session(1)
                elif command == "stop_output":
                    response["output_session"] = self.session(self.flush_count, "stopped")
                else:
                    response.update(ok=False, error={
                        "code": "unknown_command", "message": command, "retryable": False})
                writer.write(json.dumps(response).encode() + b"\n")
                await writer.drain()
        finally:
            writer.close()
            await writer.wait_closed()

    async def _stream(self, index, reader, writer):
        try:
            while True:
                try:
                    raw = await reader.readexactly(PCM_HEADER.size)
                except asyncio.IncompleteReadError:
                    break
                values = PCM_HEADER.unpack(raw)
                payload = await reader.readexactly(values[4])
                self.packets[index].append((values, payload))
                if values[2] & FLAG_EOS:
                    break
        finally:
            self.stream_closed[index].set()
            writer.close()
            try:
                await writer.wait_closed()
            except (ConnectionError, OSError):
                pass


class OutputSDKTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.runtime = FakeOutputRuntime(self.temp.name)
        await self.runtime.start()

    async def asyncTearDown(self):
        await self.runtime.close()
        self.temp.cleanup()

    async def test_destinations_models_status_and_repr(self):
        async with Sonexis(self.runtime.control_path) as client:
            destinations = await client.output_destinations()
            self.assertEqual(len(destinations), 1)
            destination = destinations[0]
            self.assertIsInstance(destination, AudioOutputDestination)
            self.assertTrue(destination.is_default)
            self.assertEqual(destination.supported_formats, [AudioFormat.openai_realtime()])

            output = await client.playback(destination=destination)
            self.assertIn("output-session", repr(output))
            status = await output.refresh()
            self.assertIsInstance(status, OutputInfo)
            self.assertEqual(status.metrics.frames_dropped, 3)
            self.assertEqual(status.metrics.frames_received, 480)
            self.assertEqual(status.metrics.frames_rendered, 240)
            self.assertEqual(status.metrics.buffered_milliseconds, 10.0)
            await output.cancel()

    async def test_write_splits_at_200ms_sequences_timestamps_and_eos(self):
        audio_format = AudioFormat.openai_realtime()
        frame_count = 12_000  # 500 ms at 24 kHz -> 200, 200, 100 ms.
        payload = memoryview(b"\x12\x34" * frame_count)
        async with Sonexis(self.runtime.control_path) as client:
            output = await client.create_output(format=audio_format)
            await output.write(payload, discontinuity=True)
            await output.aclose()

        await asyncio.wait_for(self.runtime.stream_closed[0].wait(), timeout=1.0)
        packets = self.runtime.packets[0]
        self.assertEqual(len(packets), 4)
        audio_packets = packets[:3]
        self.assertEqual([packet[0][7] for packet in audio_packets],
                         [0, 200_000_000, 400_000_000])
        self.assertEqual([packet[0][6] for packet in packets], [0, 1, 2, 3])
        self.assertEqual([packet[0][9] for packet in audio_packets], [4_800, 4_800, 2_400])
        self.assertTrue(audio_packets[0][0][2] & FLAG_DISCONTINUITY)
        self.assertFalse(audio_packets[1][0][2] & FLAG_DISCONTINUITY)
        self.assertTrue(packets[-1][0][2] & FLAG_EOS)
        self.assertEqual(packets[-1][0][4], 0)
        self.assertEqual(self.runtime.commands.count("stop_output"), 0)
        self.assertGreaterEqual(self.runtime.commands.count("output_status"), 1)

    async def test_explicit_timestamp_offsets_only_within_write(self):
        async with Sonexis(self.runtime.control_path) as client:
            output = await client.playback()
            await output.write(b"\0\0" * 2_400)  # 100 ms
            await output.write(b"\0\0" * 12_000, timestamp_ns=7_000_000_000)
            await output.write(b"\0\0" * 2_400)
            await output.aclose()
        await asyncio.wait_for(self.runtime.stream_closed[0].wait(), timeout=1.0)
        timestamps = [packet[0][7] for packet in self.runtime.packets[0][:-1]]
        self.assertEqual(timestamps, [
            0, 7_000_000_000, 7_200_000_000, 7_400_000_000, 7_500_000_000])

    async def test_flush_rotates_socket_stream_and_resets_sequence(self):
        async with Sonexis(self.runtime.control_path) as client:
            output = await client.playback()
            await output.write(b"\0\0" * 240)
            info = await output.flush()
            self.assertEqual(info.stream_id, str(self.runtime.stream_ids[1]))
            await output.write(b"\1\0" * 240)
            await output.aclose()

        await asyncio.wait_for(self.runtime.stream_closed[1].wait(), timeout=1.0)
        first_header = self.runtime.packets[0][0][0]
        second_header = self.runtime.packets[1][0][0]
        self.assertEqual(first_header[6], 0)
        self.assertEqual(second_header[6], 0)
        self.assertEqual(uuid.UUID(bytes=second_header[5]), self.runtime.stream_ids[1])
        self.assertEqual(self.runtime.commands.count("flush_output"), 1)

    async def test_cancel_is_no_eos_and_close_tracks_outputs(self):
        client = Sonexis(self.runtime.control_path)
        await client.connect()
        first = await client.playback()
        await first.write(b"\0\0" * 240)
        await first.cancel()
        self.assertNotIn(first, client._outputs)
        await asyncio.wait_for(self.runtime.stream_closed[0].wait(), timeout=1.0)
        self.assertFalse(any(packet[0][2] & FLAG_EOS for packet in self.runtime.packets[0]))

        second = await client.playback()
        self.assertIn(second, client._outputs)
        await client.close()
        self.assertTrue(second.closed)
        self.assertNotIn(second, client._outputs)

    async def test_rejects_partial_pcm_frame_and_closed_write(self):
        async with Sonexis(self.runtime.control_path) as client:
            with self.assertRaises(ValueError):
                await client.playback(target_buffer_milliseconds=10)
            output = await client.playback(
                format=AudioFormat(48_000, 2, SampleFormat.FLOAT32_LE))
            with self.assertRaises(ValueError):
                await output.write(b"not-one-frame")
            await output.cancel()
            with self.assertRaises(SonexisError) as caught:
                await output.write(b"\0" * 8)
            self.assertEqual(caught.exception.code, "output_closed")

    async def test_v03_runtime_fails_cleanly_before_output_command(self):
        await self.runtime.close()
        self.runtime = FakeOutputRuntime(self.temp.name, output_capability=False)
        await self.runtime.start()
        async with Sonexis(self.runtime.control_path) as client:
            with self.assertRaises(SonexisError) as caught:
                await client.output_destinations()
            self.assertEqual(caught.exception.code, "unsupported_capability")
            self.assertNotIn("list_output_destinations", self.runtime.commands)

    async def test_start_attach_failure_stops_runtime_output(self):
        async with Sonexis(self.runtime.control_path) as client:
            original_path = self.runtime.stream_paths[0]
            missing_path = original_path + ".missing"
            self.runtime.stream_paths[0] = missing_path
            try:
                with self.assertRaises(OSError):
                    await client.playback()
            finally:
                self.runtime.stream_paths[0] = original_path
            self.assertIn("stop_output", self.runtime.commands)


class OutputHeaderTests(unittest.TestCase):
    def test_wire_header_is_shared_sxpc_v2_layout(self):
        from sonexis.protocol import encode_frame_header

        stream_id = uuid.uuid4()
        header = encode_frame_header(
            stream_id=stream_id, sequence=9, timestamp_ns=42,
            format=AudioFormat.speech_16k(), frame_count=160, payload_size=320,
            discontinuity=True)
        self.assertEqual(len(header), 64)
        values = PCM_HEADER.unpack(header)
        self.assertEqual(values[0], PCM_MAGIC)
        self.assertEqual(values[1], 2)
        self.assertEqual(values[3], 64)
        self.assertEqual(values[4], 320)
        self.assertEqual(uuid.UUID(bytes=values[5]), stream_id)
        self.assertEqual((values[6], values[7]), (9, 42))

    def test_output_event_retains_typed_session_metadata(self):
        session = FakeOutputRuntime("/tmp").session()
        event = RuntimeEvent.from_wire({
            "protocol_version": 2,
            "event_id": "event",
            "type": "output_started",
            "timestamp_nanoseconds": 123,
            "session_id": session["id"],
            "stream_id": session["stream_id"],
            "output_session": session,
        })
        self.assertIsNotNone(event.output_session)
        self.assertEqual(event.output_session.destination_id, "default")

    def test_output_failure_uses_typed_structured_error(self):
        error = SonexisError.from_response({
            "request_id": "request",
            "error": {
                "code": "output_initialization_failed",
                "message": "device unavailable",
                "retryable": True,
                "details": {"destination_id": "default"},
            },
        })
        self.assertIsInstance(error, OutputFailedError)
        self.assertTrue(error.retryable)
        self.assertEqual(error.details["destination_id"], "default")


class OutputCancellationTests(unittest.IsolatedAsyncioTestCase):
    async def test_cancel_wakes_write_blocked_by_transport_backpressure(self):
        class Client:
            def __init__(self):
                self._outputs = set()
                self._writer = object()
                self.cleaned = []

            async def _cleanup_request(self, command, **parameters):
                self.cleaned.append((command, parameters))

        class BlockingWriter:
            def __init__(self):
                self.closed = False
                self.entered = asyncio.Event()
                self.release = asyncio.Event()

            def write(self, _value):
                pass

            async def drain(self):
                self.entered.set()
                await self.release.wait()
                if self.closed:
                    raise ConnectionResetError("closed")

            def close(self):
                self.closed = True
                self.release.set()

            async def wait_closed(self):
                return None

        client = Client()
        info = OutputInfo(
            "output", str(uuid.uuid4()), "default", "ready",
            AudioFormat.openai_realtime(), "/unused", 0, 80, OutputMetrics())
        output = AudioOutput(client, info)
        writer = BlockingWriter()
        output._writer = writer
        client._outputs.add(output)
        writing = asyncio.create_task(output.write(b"\0\0" * 240))
        await writer.entered.wait()
        await asyncio.wait_for(output.cancel(), timeout=0.2)
        result = await asyncio.gather(writing, return_exceptions=True)
        self.assertEqual(result[0].code, "output_stream_closed")
        self.assertTrue(writer.closed)
        self.assertEqual(client.cleaned[0][0], "stop_output")

    async def test_cancelling_blocked_write_cancels_uncertain_stream_epoch(self):
        class Client:
            def __init__(self):
                self._outputs = set()
                self._writer = object()
                self.cleaned = []

            async def _cleanup_request(self, command, **parameters):
                self.cleaned.append((command, parameters))

        class BlockingWriter:
            def __init__(self):
                self.entered = asyncio.Event()

            def write(self, _value):
                pass

            async def drain(self):
                self.entered.set()
                await asyncio.Event().wait()

            def close(self):
                pass

            async def wait_closed(self):
                pass

        client = Client()
        info = OutputInfo(
            "output", str(uuid.uuid4()), "default", "ready",
            AudioFormat.openai_realtime(), "/unused", 0, 80, OutputMetrics())
        output = AudioOutput(client, info)
        writer = BlockingWriter()
        output._writer = writer
        client._outputs.add(output)
        writing = asyncio.create_task(output.write(b"\0\0" * 240))
        await writer.entered.wait()
        writing.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await asyncio.wait_for(writing, timeout=0.2)
        self.assertTrue(output.closed)
        self.assertNotIn(output, client._outputs)
        self.assertEqual(client.cleaned[0][0], "stop_output")


if __name__ == "__main__":
    unittest.main()
