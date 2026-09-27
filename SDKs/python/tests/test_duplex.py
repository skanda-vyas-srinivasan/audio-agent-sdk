import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "src"))

from sonexis import AudioFormat, AudioOutputDestination, DuplexSession


class FakeStream:
    def __init__(self, destination=None):
        self.closed = 0
        self.destination = destination

    async def aclose(self, **kwargs):
        self.closed += 1


class FakeClient:
    def __init__(self, *, fail_output=False):
        self.capture_stream = FakeStream()
        self.output_stream = FakeStream(AudioOutputDestination(
            "default", "Default", "playback", True, True, True,
            None, None, None, [AudioFormat.openai_realtime_output()]))
        self.fail_output = fail_output
        self.capture_call = None
        self.output_call = None

    async def capture(self, source, *, format):
        self.capture_call = (source, format)
        return self.capture_stream

    async def playback(self, *, destination, format, target_buffer_milliseconds):
        self.output_call = (destination, format, target_buffer_milliseconds)
        if self.fail_output:
            raise RuntimeError("output unavailable")
        return self.output_stream


class DuplexTests(unittest.IsolatedAsyncioTestCase):
    async def test_duplex_owns_independent_input_and_output(self):
        client = FakeClient()
        duplex = DuplexSession(
            client, "Discord", output_destination="default",
            input_format=AudioFormat.speech_16k(),
            output_format=AudioFormat.gemini_live_output(),
            target_buffer_milliseconds=80)
        async with duplex as active:
            self.assertIs(active.input, client.capture_stream)
            self.assertIs(active.output, client.output_stream)
            self.assertEqual(client.capture_call, ("Discord", AudioFormat.speech_16k()))
            self.assertEqual(client.output_call,
                             ("default", AudioFormat.gemini_live_output(), 80))
        self.assertEqual(client.output_stream.closed, 1)
        self.assertEqual(client.capture_stream.closed, 1)

    async def test_output_start_failure_closes_capture(self):
        client = FakeClient(fail_output=True)
        duplex = DuplexSession(client, "Chrome")
        with self.assertRaisesRegex(RuntimeError, "output unavailable"):
            await duplex.__aenter__()
        self.assertEqual(client.capture_stream.closed, 1)

    def test_provider_output_presets(self):
        self.assertEqual(AudioFormat.openai_realtime_output().sample_rate, 24_000)
        self.assertEqual(AudioFormat.gemini_live_output().sample_rate, 24_000)
        self.assertEqual(AudioFormat.openai_realtime_output().channels, 1)
        self.assertEqual(AudioFormat.gemini_live_output().channels, 1)

    async def test_virtual_input_surfaces_advisory_feedback_risk(self):
        client = FakeClient()
        client.output_stream.destination = AudioOutputDestination(
            "coreaudio:blackhole", "BlackHole 2ch", "virtual_input", True,
            False, False, "coreaudio:blackhole", "BlackHole 2ch", None,
            [AudioFormat.openai_realtime_output()])
        duplex = DuplexSession(client, "Discord", output_destination="BlackHole 2ch")
        async with duplex:
            self.assertTrue(duplex.feedback_risk)
            self.assertIn("virtual input", duplex.feedback_warning)


if __name__ == "__main__":
    unittest.main()
