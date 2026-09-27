import asyncio
import base64
import contextlib
import importlib.util
import io
import os
import struct
import sys
import tempfile
import threading
import unittest
import wave
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).parents[1] / "src"))

from sonexis import (AmbiguousSourceError, AudioFormat, AudioFrame, AudioSource,
                     CaptureInfo, CaptureSession, EventSubscription, LatencyTracker,
                     MultiSourceSession, ReplayStream, SampleFormat, SessionMetrics,
                     SonexisProtocolError, SourceNotFoundError, measure_activity)
from sonexis.diagnostics import send_receipt
from sonexis.mcp_control import SonexisControlTools
from sonexis.providers import (GeminiLiveSink, GeminiTurnDetectionConfig,
                               OpenAIRealtimeSink)

from test_sdk import FakeRuntime
from sonexis import Sonexis


def source(source_id, name, bundle, pid):
    return {"id": source_id, "kind": "application", "name": name,
            "process_ids": [pid], "bundle_identifier": bundle,
            "process_state": "running", "is_available": True,
            "is_producing_audio": True, "native_format": None}


class V03SDKTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.runtime = FakeRuntime(self.temp.name)
        self.runtime.sources = [
            source("app.spotify", "Spotify", "com.spotify.client", 10),
            source("app.chat.one", "Chat", "example.chat.one", 20),
            source("app.chat.two", "Chat", "example.chat.two", 21),
        ]
        await self.runtime.start()

    async def asyncTearDown(self):
        await self.runtime.close()
        self.temp.cleanup()

    async def test_source_resolution_and_ambiguity(self):
        async with Sonexis(self.runtime.control_path) as client:
            self.assertEqual((await client.get_source("app.spotify")).name, "Spotify")
            self.assertEqual((await client.get_source("com.spotify.client")).id, "app.spotify")
            self.assertEqual((await client.get_source("spotify")).id, "app.spotify")
            self.assertEqual((await client.get_source(10)).id, "app.spotify")
            self.assertEqual(len(await client.find_sources("chat")), 2)
            with self.assertRaises(AmbiguousSourceError) as ambiguous:
                await client.get_source("Chat")
            self.assertEqual(set(ambiguous.exception.details.values()),
                             {"app.chat.one", "app.chat.two"})
            with self.assertRaises(SourceNotFoundError):
                await client.get_source("missing")

    async def test_concurrent_connect_calls_share_one_handshake(self):
        client = Sonexis(self.runtime.control_path)
        first, second = await asyncio.gather(client.connect(), client.connect())
        self.assertIs(first, second)
        await client.close()

    async def test_wait_for_source_uses_fresh_snapshot_and_times_out(self):
        async with Sonexis(self.runtime.control_path) as client:
            async def launch():
                await asyncio.sleep(0.02)
                self.runtime.sources.append(
                    source("app.later", "Later", "example.later", 30))
            task = asyncio.create_task(launch())
            found = await client.wait_for_source("Later", timeout=0.3, poll_interval=0.01)
            await task
            self.assertEqual(found.id, "app.later")
            with self.assertRaises(SourceNotFoundError) as timeout:
                await client.wait_for_source("Never", timeout=0.02, poll_interval=0.005)
            self.assertEqual(timeout.exception.code, "source_wait_timeout")

    async def test_capture_frames_retain_source_session_and_timing(self):
        async with Sonexis(self.runtime.control_path) as client:
            async with await client.capture("Spotify") as capture:
                frame = await capture.__anext__()
                self.assertEqual(frame.source.id, "app.spotify")
                self.assertEqual(frame.source_name, "Spotify")
                self.assertEqual(frame.bundle_identifier, "com.spotify.client")
                self.assertEqual(frame.session_id, capture.info.id)
                self.assertIsNotNone(frame.received_at_ns)
                self.assertIsNotNone(frame.estimated_sonexis_latency_ns)

    async def test_labeled_multi_source_session(self):
        async with Sonexis(self.runtime.control_path) as client:
            async with client.session(max_queue_frames=4) as group:
                await group.add("music", "Spotify")
                await group.add("conversation", "example.chat.one")
                labels = set()
                async for item in group.frames():
                    labels.add(item.label)
                self.assertEqual(labels, {"music", "conversation"})
                self.assertEqual(group.labels, ())


class ReplayAndDiagnosticsTests(unittest.IsolatedAsyncioTestCase):
    async def test_replay_wav_activity_and_latency(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sample.wav"
            samples = struct.pack("<" + "h" * 320, *([8192] * 320))
            with wave.open(str(path), "wb") as output:
                output.setnchannels(1)
                output.setsampwidth(2)
                output.setframerate(16_000)
                output.writeframes(samples)
            async with ReplayStream.from_wav(path, chunk_frames=160) as replay:
                frames = [frame async for frame in replay]
            self.assertEqual([frame.sequence for frame in frames], [0, 1])
            self.assertEqual(frames[1].timestamp_ns, 10_000_000)
            self.assertEqual(frames[0].source.name, "sample.wav")
            activity = measure_activity(frames[0])
            self.assertTrue(activity.active)
            self.assertAlmostEqual(activity.peak, 0.25)
            tracker = LatencyTracker(2)
            for frame in frames:
                tracker.observe(frame)
            self.assertEqual(tracker.summary().count, 2)
            self.assertEqual(send_receipt("mock", frames[0]).provider, "mock")

    async def test_partial_raw_replay_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.pcm"
            path.write_bytes(b"\x00")
            replay = ReplayStream.from_pcm(path, format=AudioFormat.speech_16k())
            with self.assertRaises(ValueError):
                await replay.__anext__()

    async def test_cancelled_replay_read_finishes_before_file_close(self):
        class BlockingHandle:
            def __init__(self):
                self.started = threading.Event()
                self.release = threading.Event()
                self.closed = False

            def read(self, _size):
                self.started.set()
                self.release.wait()
                return b""

            def close(self):
                self.closed = True

        handle = BlockingHandle()
        replay = ReplayStream(handle, format=AudioFormat.speech_16k(),
                              source_name="blocking")
        read = asyncio.create_task(replay.__anext__())
        self.assertTrue(await asyncio.to_thread(handle.started.wait, 0.2))
        read.cancel()
        await asyncio.gather(read, return_exceptions=True)
        closing = asyncio.create_task(replay.aclose())
        await asyncio.sleep(0.01)
        self.assertFalse(handle.closed)
        handle.release.set()
        await closing
        self.assertTrue(handle.closed)

    async def test_close_wakes_realtime_replay_pacing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "paced.pcm"
            path.write_bytes(b"\0\0" * 32_000)
            replay = ReplayStream.from_pcm(
                path, format=AudioFormat.speech_16k(), chunk_frames=16_000, realtime=True)
            await replay.__anext__()
            pending = asyncio.create_task(replay.__anext__())
            await asyncio.sleep(0.01)
            await replay.aclose()
            with self.assertRaises(StopAsyncIteration):
                await asyncio.wait_for(pending, timeout=0.1)


class DelayedCapture:
    def __init__(self):
        self.closed = False

    async def aclose(self):
        self.closed = True


class DelayedCaptureClient:
    def __init__(self):
        self.started = asyncio.Event()
        self.release = asyncio.Event()
        self.captures = []

    async def capture(self, _source, *, format):
        capture = DelayedCapture()
        self.captures.append(capture)
        self.started.set()
        await self.release.wait()
        return capture


class MultiSourceRaceTests(unittest.IsolatedAsyncioTestCase):
    async def test_concurrent_duplicate_label_is_rejected_before_second_capture(self):
        client = DelayedCaptureClient()
        group = MultiSourceSession(client)
        first = asyncio.create_task(group.add("media", "one"))
        await client.started.wait()
        with self.assertRaises(ValueError):
            await group.add("media", "two")
        self.assertEqual(len(client.captures), 1)
        client.release.set()
        capture = await first
        await group.aclose()
        self.assertTrue(capture.closed)

    async def test_close_racing_capture_start_closes_late_capture(self):
        client = DelayedCaptureClient()
        group = MultiSourceSession(client)
        add = asyncio.create_task(group.add("media", "one"))
        await client.started.wait()
        await group.aclose()
        client.release.set()
        with self.assertRaises(RuntimeError):
            await add
        self.assertTrue(client.captures[0].closed)
        self.assertEqual(group.labels, ())


class StreamShutdownTests(unittest.IsolatedAsyncioTestCase):
    async def test_explicit_close_wakes_blocked_capture_and_event_iterators(self):
        with tempfile.TemporaryDirectory() as directory:
            async def hold(reader, writer):
                await reader.read()
                writer.close()
                await writer.wait_closed()

            capture_path = str(Path(directory) / "capture.sock")
            event_path = str(Path(directory) / "event.sock")
            capture_server = await asyncio.start_unix_server(hold, capture_path)
            event_server = await asyncio.start_unix_server(hold, event_path)
            client = Sonexis("/unused")
            source_value = AudioSource("app.test", "Test", "application", [1],
                                       "test", "running", True, True, None)
            info = CaptureInfo("session", "00112233-4455-6677-8899-aabbccddeeff",
                               source_value.id, "capturing", AudioFormat.speech_16k(),
                               capture_path, 0, SessionMetrics())
            capture = CaptureSession(client, info, source_value)
            await capture._open()
            capture_read = asyncio.create_task(capture.__anext__())
            await asyncio.sleep(0)
            await capture.aclose(stop_runtime=False)
            with self.assertRaises(StopAsyncIteration):
                await capture_read

            events = EventSubscription(client, {
                "id": "events", "event_socket_path": event_path, "event_types": []})
            await events._open()
            event_read = asyncio.create_task(events.__anext__())
            await asyncio.sleep(0)
            await events.aclose(unsubscribe=False)
            with self.assertRaises(StopAsyncIteration):
                await event_read

            capture_server.close()
            event_server.close()
            await capture_server.wait_closed()
            await event_server.wait_closed()

    async def test_oversized_event_is_structured_protocol_error(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "events.sock")

            async def oversized(_reader, writer):
                writer.write(b"x" * 70_000)
                await writer.drain()
                writer.close()
                await writer.wait_closed()

            server = await asyncio.start_unix_server(oversized, path)
            events = EventSubscription(Sonexis("/unused"), {
                "id": "events", "event_socket_path": path, "event_types": []})
            await events._open()
            with self.assertRaises(SonexisProtocolError) as error:
                await events.__anext__()
            self.assertEqual(error.exception.code, "invalid_event")
            server.close()
            await server.wait_closed()


class FakeOpenAIInput:
    def __init__(self):
        self.values = []

    async def append(self, *, audio):
        self.values.append(audio)


class FakeOpenAISession:
    def __init__(self):
        self.input_audio = FakeOpenAIInput()
        self.closed = False

    async def close(self):
        self.closed = True


class FakeOpenAIConnection:
    def __init__(self):
        self.session = FakeOpenAISession()

    def __aiter__(self):
        async def values():
            if False:
                yield None
        return values()


class FakeGeminiSession:
    def __init__(self):
        self.values = []
        self.received = []

    async def send_realtime_input(self, **value):
        self.values.append(value)

    def receive(self):
        async def values():
            for value in self.received:
                yield value
        return values()


class ProviderTests(unittest.IsolatedAsyncioTestCase):
    def frame(self, format):
        source_value = AudioSource("app.test", "Test", "application", [1], "test",
                                   "running", True, True, None)
        return AudioFrame("stream", 1, 0, 160, format,
                          b"\0" * (160 * format.channels * format.sample_format.bytes_per_sample),
                          source=source_value, session_id="session")

    def pcm_frame(self, sequence, amplitude, frame_count=1_600):
        base = self.frame(AudioFormat.gemini_live())
        sample = max(-32768, min(32767, round(amplitude * 32767)))
        return replace(base, sequence=sequence, frame_count=frame_count,
                       timestamp_ns=(sequence - 1) * 100_000_000,
                       data=struct.pack("<h", sample) * frame_count)

    @staticmethod
    def turn_config(**overrides):
        values = {
            "activity_start_threshold": 0.02,
            "activity_end_threshold": 0.01,
            "minimum_activity_ms": 200,
            "silence_duration_ms": 300,
        }
        values.update(overrides)
        return GeminiTurnDetectionConfig(**values)

    def test_gemini_keeps_server_vad_and_output_transcription_enabled(self):
        instruction = "Respond in English."
        config = GeminiLiveSink._connection_config(None, instruction)
        self.assertFalse(config["realtime_input_config"]
                         ["automatic_activity_detection"]["disabled"])
        self.assertEqual(config["output_audio_transcription"], {})
        self.assertEqual(config["system_instruction"], instruction)

    async def test_openai_audio_encoding_and_format_validation(self):
        connection = FakeOpenAIConnection()
        sink = OpenAIRealtimeSink(connection)
        receipt = await sink.send_audio(self.frame(AudioFormat.openai_realtime()))
        self.assertEqual(receipt.provider, "openai")
        self.assertEqual(len(connection.session.input_audio.values), 1)
        with self.assertRaises(Exception) as sequence:
            await sink.send_audio(self.frame(AudioFormat.openai_realtime()))
        self.assertEqual(sequence.exception.code, "provider_sequence_error")
        with self.assertRaises(Exception) as invalid:
            await sink.send_audio(self.frame(AudioFormat.gemini_live()))
        self.assertEqual(invalid.exception.code, "unsupported_provider_format")
        await sink.aclose()
        self.assertTrue(connection.session.closed)

    async def test_gemini_blob_and_stream_end(self):
        session = FakeGeminiSession()
        sink = GeminiLiveSink(
            session, blob_factory=lambda **value: value,
            turn_detection=GeminiTurnDetectionConfig(enabled=False))
        await sink.send_audio(self.frame(AudioFormat.gemini_live()))
        self.assertEqual(session.values[0]["audio"]["mime_type"], "audio/pcm;rate=16000")
        session.received.append(SimpleNamespace(server_content=SimpleNamespace(
            output_transcription=SimpleNamespace(text="hello"), model_turn=None)))
        event = await sink.events().__anext__()
        self.assertEqual((event.type, event.text), ("output_transcription", "hello"))
        self.assertIsNone(event.audio_format)
        await sink.aclose()
        self.assertTrue(session.values[-1]["audio_stream_end"])

    async def test_gemini_hybrid_vad_finalizes_once_per_activity_segment(self):
        session = FakeGeminiSession()
        debug = []
        sink = GeminiLiveSink(
            session, blob_factory=lambda **value: value,
            turn_detection=self.turn_config(), debug_callback=debug.append)

        sequence = 1
        for amplitude in [0.2, 0.2, 0.0, 0.0, 0.0] + [0.0] * 10:
            await sink.send_audio(self.pcm_frame(sequence, amplitude))
            sequence += 1

        endings = [value for value in session.values if value.get("audio_stream_end")]
        self.assertEqual(len(endings), 1)
        self.assertEqual(debug.count("local activity start"), 1)
        self.assertEqual(debug.count("local activity end"), 1)
        self.assertEqual(debug.count("audio_stream_end sent"), 1)
        await sink.aclose()
        self.assertEqual(len([value for value in session.values
                              if value.get("audio_stream_end")]), 1)

    async def test_gemini_hybrid_vad_ignores_short_mid_sentence_pause(self):
        session = FakeGeminiSession()
        sink = GeminiLiveSink(
            session, blob_factory=lambda **value: value,
            turn_detection=self.turn_config())
        for sequence, amplitude in enumerate([0.2, 0.2, 0.0, 0.0, 0.2], 1):
            await sink.send_audio(self.pcm_frame(sequence, amplitude))
        self.assertFalse(any(value.get("audio_stream_end") for value in session.values))
        await sink.aclose()

    async def test_gemini_hybrid_vad_reopens_for_new_speech(self):
        session = FakeGeminiSession()
        debug = []
        sink = GeminiLiveSink(
            session, blob_factory=lambda **value: value,
            turn_detection=self.turn_config(), debug_callback=debug.append)
        amplitudes = ([0.2, 0.2, 0.0, 0.0, 0.0]
                      + [0.2, 0.2, 0.0, 0.0, 0.0])
        for sequence, amplitude in enumerate(amplitudes, 1):
            await sink.send_audio(self.pcm_frame(sequence, amplitude))
        self.assertEqual(len([value for value in session.values
                              if value.get("audio_stream_end")]), 2)
        self.assertEqual(debug.count("local activity start"), 2)
        await sink.aclose()

    async def test_gemini_hybrid_vad_background_noise_does_not_repeat_end(self):
        session = FakeGeminiSession()
        sink = GeminiLiveSink(
            session, blob_factory=lambda **value: value,
            turn_detection=self.turn_config())
        for sequence in range(1, 101):
            await sink.send_audio(self.pcm_frame(sequence, 0.012))
        self.assertEqual(session.values, [])
        await sink.aclose()
        self.assertEqual(session.values, [])

    async def test_gemini_hybrid_vad_cancellation_during_activity(self):
        session = FakeGeminiSession()
        started = asyncio.Event()

        async def blocked_send(**value):
            if "audio" in value:
                started.set()
                await asyncio.Event().wait()
            session.values.append(value)

        session.send_realtime_input = blocked_send
        sink = GeminiLiveSink(
            session, blob_factory=lambda **value: value,
            turn_detection=self.turn_config(minimum_activity_ms=100))
        sending = asyncio.create_task(sink.send_audio(self.pcm_frame(1, 0.2)))
        await started.wait()
        sending.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await sending
        await sink.aclose()
        self.assertFalse(any(value.get("audio_stream_end") for value in session.values))

    async def test_gemini_output_transcription_and_turn_debug_events(self):
        session = FakeGeminiSession()
        debug = []
        session.received.append(SimpleNamespace(server_content=SimpleNamespace(
            output_transcription=SimpleNamespace(text="A concise English response."),
            model_turn=SimpleNamespace(parts=[]), turn_complete=True)))
        sink = GeminiLiveSink(
            session, blob_factory=lambda **value: value, debug_callback=debug.append)
        event = await sink.events().__anext__()
        self.assertEqual(event.type, "output_transcription")
        self.assertEqual(event.text, "A concise English response.")
        self.assertEqual(debug, ["Gemini response start", "Gemini turn complete"])
        await sink.aclose()

    async def test_provider_output_audio_declares_playback_format(self):
        gemini_session = FakeGeminiSession()
        gemini_session.received.append(SimpleNamespace(server_content=SimpleNamespace(
            output_transcription=None,
            model_turn=SimpleNamespace(parts=[SimpleNamespace(inline_data=SimpleNamespace(
                data=b"gemini", mime_type="audio/pcm"))]),
            turn_complete=False)))
        gemini = GeminiLiveSink(gemini_session, blob_factory=lambda **value: value)
        gemini_event = await gemini.events().__anext__()
        self.assertEqual(gemini_event.audio, b"gemini")
        self.assertEqual(gemini_event.audio_format, AudioFormat.gemini_live_output())
        await gemini.aclose()

        openai_event = OpenAIRealtimeSink._event(SimpleNamespace(
            type="session.output_audio.delta",
            delta=base64.b64encode(b"openai").decode("ascii")))
        self.assertEqual(openai_event.audio, b"openai")
        self.assertEqual(openai_event.audio_format, AudioFormat.openai_realtime_output())

    async def test_provider_stream_affinity_and_bounded_close(self):
        connection = FakeOpenAIConnection()

        async def never_close():
            await asyncio.Event().wait()

        connection.session.close = never_close
        sink = OpenAIRealtimeSink(connection, close_timeout=0.01)
        first = self.frame(AudioFormat.openai_realtime())
        await sink.send_audio(first)
        with self.assertRaises(Exception) as mismatch:
            await sink.send_audio(replace(first, stream_id="another", sequence=2))
        self.assertEqual(mismatch.exception.code, "provider_stream_mismatch")
        await asyncio.wait_for(sink.aclose(), timeout=0.1)

    async def test_provider_rejects_bad_payload_and_close_racing_send(self):
        connection = FakeOpenAIConnection()
        sink = OpenAIRealtimeSink(connection)
        good = self.frame(AudioFormat.openai_realtime())
        with self.assertRaises(Exception) as invalid:
            await sink.send_audio(replace(good, data=b"\0\0"))
        self.assertEqual(invalid.exception.code, "invalid_audio")

        started = asyncio.Event()
        release = asyncio.Event()

        async def blocked_append(*, audio):
            started.set()
            await release.wait()

        connection.session.input_audio.append = blocked_append
        sending = asyncio.create_task(sink.send_audio(good))
        await started.wait()
        await sink.aclose()
        release.set()
        with self.assertRaises(Exception) as closed:
            await sending
        self.assertEqual(closed.exception.code, "provider_closed")


class FakeControlClient:
    def __init__(self):
        self.created = None

    async def sources(self):
        return [AudioSource("app.test", "Test", "application", [1], "test",
                            "running", True, True, None)]

    async def get_source(self, selector):
        return (await self.sources())[0]

    async def status(self, session_id=None):
        if session_id is None:
            from sonexis import RuntimeStatus
            return RuntimeStatus("0.3.0", "instance", 1, 1, 0, 0, 0, 0, 0, 0)
        raise AssertionError("not used")

    async def create_capture(self, source, format):
        self.created = (source, format)
        from sonexis import CaptureInfo, SessionMetrics
        return CaptureInfo("session", "stream", "app.test", "capturing", format,
                           "/tmp/data", 0, SessionMetrics())


class MCPControlTests(unittest.IsolatedAsyncioTestCase):
    async def test_mcp_is_control_only_and_capture_is_opt_in(self):
        client = FakeControlClient()
        tools = SonexisControlTools(client)
        listed = await tools.list_sources()
        self.assertNotIn("data", str(listed).lower())
        with self.assertRaises(Exception) as disabled:
            await tools.start_capture("Test")
        self.assertEqual(disabled.exception.code, "capture_control_disabled")
        with self.assertRaises(Exception) as stop_disabled:
            await tools.stop_capture("session")
        self.assertEqual(stop_disabled.exception.code, "capture_control_disabled")
        enabled = SonexisControlTools(client, allow_capture=True)
        result = await enabled.start_capture("Test", "openai_realtime")
        self.assertEqual(client.created[1], AudioFormat.openai_realtime())
        self.assertIn("binary data plane", result["audio_delivery"])
        self.assertNotIn("pcm", result["session"])


class OutputSecurityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = Path(__file__).parents[3] / "Examples/audio-agent/audio_agent.py"
        spec = importlib.util.spec_from_file_location("sonexis_audio_agent", path)
        assert spec is not None and spec.loader is not None
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def test_recording_is_private_and_symlinks_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "capture.pcm"
            writer = self.module.OutputWriter(output, AudioFormat.speech_16k())
            writer.write(b"\0\0")
            writer.close()
            self.assertEqual(os.stat(output).st_mode & 0o777, 0o600)

            target = Path(directory) / "target.pcm"
            target.write_bytes(b"private")
            link = Path(directory) / "link.pcm"
            link.symlink_to(target)
            with self.assertRaises(OSError):
                self.module.OutputWriter(link, AudioFormat.speech_16k())
            self.assertEqual(target.read_bytes(), b"private")

    def test_reference_gemini_instruction_is_stable(self):
        self.assertEqual(
            self.module.GEMINI_SYSTEM_INSTRUCTION,
            "Respond in English. Briefly summarize or respond to the audio you just heard.")


class ReferenceProviderOutputTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        path = Path(__file__).parents[3] / "Examples/audio-agent/audio_agent.py"
        spec = importlib.util.spec_from_file_location("sonexis_audio_agent_output", path)
        assert spec is not None and spec.loader is not None
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    async def test_raw_provider_audio_is_debug_only(self):
        class Sink:
            async def events(self):
                yield self_event

        from sonexis.providers import ProviderEvent
        self_event = ProviderEvent("gemini", "message", audio=b"audio")
        quiet_output = io.StringIO()
        with contextlib.redirect_stdout(quiet_output):
            await self.module.print_provider_events(Sink(), asyncio.Event())
        self.assertEqual(quiet_output.getvalue(), "")

        debug_output = io.StringIO()
        with contextlib.redirect_stdout(debug_output):
            await self.module.print_provider_events(
                Sink(), asyncio.Event(), debug=True)
        self.assertIn("received 5 audio bytes", debug_output.getvalue())


if __name__ == "__main__":
    unittest.main()
