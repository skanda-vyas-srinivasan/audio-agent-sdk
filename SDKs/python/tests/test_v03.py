import asyncio
import os
import struct
import sys
import tempfile
import unittest
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "src"))

from sonexis import (AmbiguousSourceError, AudioFormat, AudioFrame, AudioSource,
                     LatencyTracker, ReplayStream, SampleFormat, SourceNotFoundError,
                     measure_activity)
from sonexis.diagnostics import send_receipt
from sonexis.mcp_control import SonexisControlTools
from sonexis.providers import GeminiLiveSink, OpenAIRealtimeSink

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

    async def send_realtime_input(self, **value):
        self.values.append(value)

    def receive(self):
        async def values():
            if False:
                yield None
        return values()


class ProviderTests(unittest.IsolatedAsyncioTestCase):
    def frame(self, format):
        source_value = AudioSource("app.test", "Test", "application", [1], "test",
                                   "running", True, True, None)
        return AudioFrame("stream", 1, 0, 160, format,
                          b"\0" * (160 * format.channels * format.sample_format.bytes_per_sample),
                          source=source_value, session_id="session")

    async def test_openai_audio_encoding_and_format_validation(self):
        connection = FakeOpenAIConnection()
        sink = OpenAIRealtimeSink(connection)
        receipt = await sink.send_audio(self.frame(AudioFormat.openai_realtime()))
        self.assertEqual(receipt.provider, "openai")
        self.assertEqual(len(connection.session.input_audio.values), 1)
        with self.assertRaises(Exception) as invalid:
            await sink.send_audio(self.frame(AudioFormat.gemini_live()))
        self.assertEqual(invalid.exception.code, "unsupported_provider_format")
        await sink.aclose()
        self.assertTrue(connection.session.closed)

    async def test_gemini_blob_and_stream_end(self):
        session = FakeGeminiSession()
        sink = GeminiLiveSink(session, blob_factory=lambda **value: value)
        await sink.send_audio(self.frame(AudioFormat.gemini_live()))
        self.assertEqual(session.values[0]["audio"]["mime_type"], "audio/pcm;rate=16000")
        await sink.aclose()
        self.assertTrue(session.values[-1]["audio_stream_end"])


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
        enabled = SonexisControlTools(client, allow_capture=True)
        result = await enabled.start_capture("Test", "openai_realtime")
        self.assertEqual(client.created[1], AudioFormat.openai_realtime())
        self.assertIn("binary data plane", result["audio_delivery"])
        self.assertNotIn("pcm", result["session"])


if __name__ == "__main__":
    unittest.main()
