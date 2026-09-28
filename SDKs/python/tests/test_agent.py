import asyncio
import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).parents[1] / "src"))

from audioplane.agent import (LiveValidationTracker, RuntimeResponsePlayer,
                              StreamStats)
from audioplane.cli import _parser
from sonexis import AudioFormat, AudioFrame
from sonexis.providers import (GeminiLiveSink, GeminiTurnDetectionConfig,
                               ProviderEvent, ProviderLifecycleEvent)


class AgentCLIAndDiagnosticsTests(unittest.TestCase):
    def test_packaged_agent_command_exposes_stable_live_options(self):
        arguments = _parser().parse_args([
            "agent",
            "--provider", "gemini",
            "--source", "Google Chrome",
            "--response-output", "AudioPlane Input",
            "--gemini-barge-in",
            "--validate-live",
        ])
        self.assertEqual(arguments.command, "agent")
        self.assertEqual(arguments.provider, "gemini")
        self.assertEqual(arguments.source, "Google Chrome")
        self.assertTrue(arguments.gemini_barge_in)
        self.assertTrue(arguments.validate_live)

    def test_live_validation_correlates_turn_without_private_content(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "validation.json"
            tracker = LiveValidationTracker(enabled=False, output_path=path)
            tracker.lifecycle(ProviderLifecycleEvent(
                "gemini", "activity_started", timestamp_ns=1_000_000))
            tracker.lifecycle(ProviderLifecycleEvent(
                "gemini", "activity_ended", timestamp_ns=2_000_000))
            tracker.lifecycle(ProviderLifecycleEvent(
                "gemini", "input_finalized", timestamp_ns=3_000_000))
            tracker.provider_event(ProviderEvent(
                "gemini", "output_transcription", text="private transcript",
                response_started=True))
            tracker.lifecycle(ProviderLifecycleEvent(
                "audioplane", "output_started", timestamp_ns=5_000_000))
            tracker.provider_event(ProviderEvent(
                "gemini", "message", response_completed=True))
            tracker.finish_provider_event(ProviderEvent(
                "gemini", "message", response_completed=True))
            report = tracker.final_report(StreamStats())
            serialized = json.dumps(report)
            self.assertEqual(report["status"], "pass")
            self.assertEqual(len(report["turns"]), 1)
            self.assertNotIn("private transcript", serialized)
            self.assertEqual(json.loads(path.read_text()), report)

    def test_live_validation_flags_duplicate_edges_and_missing_response(self):
        tracker = LiveValidationTracker(enabled=False)
        tracker.lifecycle(ProviderLifecycleEvent("gemini", "activity_started"))
        tracker.lifecycle(ProviderLifecycleEvent("gemini", "activity_started"))
        tracker.lifecycle(ProviderLifecycleEvent("gemini", "activity_ended"))
        tracker.lifecycle(ProviderLifecycleEvent("gemini", "input_finalized"))
        report = tracker.final_report()
        self.assertEqual(report["status"], "warn")
        self.assertIn("duplicate activity start", report["warnings"])
        self.assertTrue(any("received no response" in value
                            for value in report["warnings"]))


class AgentPlaybackLifecycleTests(unittest.IsolatedAsyncioTestCase):
    async def test_gemini_lifecycle_is_edge_triggered_and_privacy_safe(self):
        class Session:
            def __init__(self):
                self.ends = 0

            async def send_realtime_input(self, *, audio=None,
                                          audio_stream_end=False):
                if audio_stream_end:
                    self.ends += 1

        events = []
        session = Session()
        sink = GeminiLiveSink(
            session,
            blob_factory=lambda **value: value,
            turn_detection=GeminiTurnDetectionConfig(
                activity_start_threshold=0.02,
                activity_end_threshold=0.01,
                minimum_activity_ms=200,
                silence_duration_ms=300,
            ),
            lifecycle_callback=events.append,
        )
        audio_format = AudioFormat.gemini_live()

        def frame(sequence, amplitude):
            sample = round(amplitude * 32_767)
            return AudioFrame(
                "stream", sequence, sequence * 100_000_000, 1_600,
                audio_format, struct.pack("<h", sample) * 1_600,
                session_id="session")

        for sequence, amplitude in enumerate(
                [0.2, 0.2, 0.0, 0.0, 0.0, 0.0, 0.0], 1):
            await sink.send_audio(frame(sequence, amplitude))
        self.assertEqual(session.ends, 1)
        self.assertEqual(
            [event.type for event in events],
            ["activity_started", "activity_ended", "input_finalized"],
        )
        self.assertTrue(all(not event.details or "text" not in event.details
                            for event in events))
        await sink.aclose()

    async def test_playback_emits_start_and_flush_lifecycle(self):
        lifecycle = []

        class Output:
            info = SimpleNamespace(id="output", destination_id="virtual")
            metrics = SimpleNamespace(frames_rendered=0)

            def __init__(self):
                self.writes = []
                self.flushes = 0

            async def write(self, value):
                self.writes.append(bytes(value))

            async def flush(self):
                self.flushes += 1

            async def aclose(self, *, drain):
                pass

        class Client:
            def __init__(self):
                self.output = Output()

            async def playback(self, *, destination, format):
                return self.output

        client = Client()
        player = RuntimeResponsePlayer(
            client, "virtual", debug=False,
            lifecycle_callback=lifecycle.append)
        await player.write(ProviderEvent(
            "gemini", "audio", audio=b"\1\2" * 1_200,
            audio_format=AudioFormat.gemini_live_output()))
        await asyncio.sleep(0)
        await player.interrupt_response()
        for _ in range(20):
            if client.output.flushes:
                break
            await asyncio.sleep(0)
        await player.close()
        self.assertEqual(client.output.flushes, 1)
        self.assertEqual(
            [event.type for event in lifecycle],
            ["output_started", "output_flushed"],
        )


if __name__ == "__main__":
    unittest.main()
