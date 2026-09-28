import argparse
import io
import json
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "src"))

from audioplane import AudioPlane, AudioPlaneClient, Sonexis
from audioplane.cli import SpeechSynthesisError, _parser, _run
from sonexis import (AudioFormat, AudioOutputDestination, AudioSource, Handshake,
                     RuntimeStatus, SampleFormat)


class FakeOutput:
    def __init__(self, destination):
        self.destination = destination
        self.writes = []
        self.exited = False
        self.drained = None

    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc, traceback):
        self.exited = True
        self.drained = exc_type is None

    async def write(self, value):
        self.writes.append(value)


class FakeClient:
    last_instance = None

    def __init__(self, socket_path, *, client_name, client_version):
        type(self).last_instance = self
        self.socket_path = socket_path or "/tmp/audio-plane-test.sock"
        self.client_name = client_name
        self.client_version = client_version
        self.handshake = None
        self.output = None
        self.playback_call = None

    async def __aenter__(self):
        self.handshake = Handshake(
            protocol_version=2,
            runtime_version="1.0.0",
            runtime_instance_id="test-instance",
            capabilities=["output_sessions"],
            supported_formats=[],
            supported_output_formats=[],
            limits={},
        )
        return self

    async def __aexit__(self, exc_type, exc, traceback):
        return None

    async def sources(self):
        return [AudioSource(
            id="app.test.42",
            name="Test Audio",
            kind="application",
            process_ids=[42],
            bundle_identifier="example.test",
            process_state="running",
            available=True,
            producing_audio=True,
            native_format=None,
        )]

    async def output_destinations(self):
        return [AudioOutputDestination(
            id="default",
            name="System Default",
            kind="playback",
            available=True,
            is_default=True,
            follows_system_default=True,
            active_device_id="device.test",
            active_device_name="Test Device",
            native_format=None,
            supported_formats=[],
        )]

    async def status(self):
        return RuntimeStatus(
            runtime_version="1.0.0",
            runtime_instance_id="test-instance",
            uptime_ns=2_000_000_000,
            active_clients=1,
            active_sessions=2,
            event_subscribers=0,
            total_sessions_started=3,
            total_frames_forwarded=160,
            total_dropped_frames=0,
            total_bytes_transmitted=320,
            active_output_sessions=1,
            total_output_frames_rendered=240,
        )

    async def playback(self, *, destination, format, target_buffer_milliseconds):
        resolved = AudioOutputDestination(
            id=destination,
            name="AudioPlane Input",
            kind="virtual_input",
            available=True,
            is_default=False,
            follows_system_default=False,
            active_device_id="com.audioplane.input.device",
            active_device_name="AudioPlane Input",
            native_format=None,
            supported_formats=[],
        )
        self.playback_call = (destination, format, target_buffer_milliseconds)
        self.output = FakeOutput(resolved)
        return self.output


def arguments(command, *, json_output=False, socket=None, **values):
    return argparse.Namespace(command=command, json=json_output, socket=socket, **values)


class AudioPlaneCLITests(unittest.IsolatedAsyncioTestCase):
    async def test_public_aliases_preserve_existing_client(self):
        self.assertIs(AudioPlane, Sonexis)
        self.assertIs(AudioPlaneClient, Sonexis)

    async def test_doctor_reports_compatible_runtime(self):
        output = io.StringIO()
        with redirect_stdout(output):
            result = await _run(arguments("doctor"), FakeClient)
        self.assertEqual(result, 0)
        self.assertIn("AudioPlane SDK 1.0.0: ok", output.getvalue())
        self.assertIn("Protocol v2: compatible", output.getvalue())

    async def test_sources_json_is_typed_public_data(self):
        output = io.StringIO()
        with redirect_stdout(output):
            result = await _run(arguments("sources", json_output=True), FakeClient)
        self.assertEqual(result, 0)
        payload = json.loads(output.getvalue())
        self.assertEqual(payload[0]["id"], "app.test.42")
        self.assertEqual(payload[0]["bundle_identifier"], "example.test")

    async def test_status_and_outputs_human_output(self):
        status_output = io.StringIO()
        with redirect_stdout(status_output):
            await _run(arguments("status"), FakeClient)
        self.assertIn("captures=2 outputs=1", status_output.getvalue())

        output_output = io.StringIO()
        with redirect_stdout(output_output):
            await _run(arguments("outputs"), FakeClient)
        self.assertIn("System Default", output_output.getvalue())
        self.assertIn("available,default", output_output.getvalue())

    async def test_version_does_not_connect(self):
        class MustNotConstruct:
            def __init__(self, *args, **kwargs):
                raise AssertionError("version must not connect")

        output = io.StringIO()
        with redirect_stdout(output):
            result = await _run(arguments("version"), MustNotConstruct)
        self.assertEqual(result, 0)
        self.assertEqual(output.getvalue().strip(), "AudioPlane 1.0.0")

    async def test_speak_reuses_one_output_until_quit(self):
        lines = iter(["hello everyone", "", "another line", "/quit"])
        synthesized = []

        def synthesize(text, voice, rate):
            synthesized.append((text, voice, rate))
            return text.encode("utf-8")

        output = io.StringIO()
        with redirect_stdout(output):
            result = await _run(
                arguments(
                    "speak",
                    destination="coreaudio:com.audioplane.input.device",
                    voice="Samantha",
                    rate=190,
                    buffer_ms=80,
                ),
                FakeClient,
                line_reader=lambda prompt: next(lines),
                synthesizer=synthesize,
            )

        self.assertEqual(result, 0)
        client = FakeClient.last_instance
        self.assertIsNotNone(client)
        self.assertEqual(
            client.playback_call,
            (
                "coreaudio:com.audioplane.input.device",
                AudioFormat(48_000, 1, SampleFormat.PCM_S16LE),
                80,
            ),
        )
        self.assertEqual(
            synthesized,
            [("hello everyone", "Samantha", 190), ("another line", "Samantha", 190)],
        )
        self.assertEqual(client.output.writes, [b"hello everyone", b"another line"])
        self.assertTrue(client.output.exited)
        self.assertTrue(client.output.drained)
        self.assertIn("AudioPlane Input ready", output.getvalue())

    async def test_speak_reports_one_synthesis_failure_and_keeps_reading(self):
        lines = iter(["bad voice", "works", "/quit"])
        calls = []

        def synthesize(text, voice, rate):
            calls.append(text)
            if text == "bad voice":
                raise SpeechSynthesisError("voice unavailable")
            return b"pcm"

        error_output = io.StringIO()
        standard_output = io.StringIO()
        with redirect_stderr(error_output), redirect_stdout(standard_output):
            result = await _run(
                arguments(
                    "speak",
                    destination="virtual_input",
                    voice=None,
                    rate=None,
                    buffer_ms=60,
                ),
                FakeClient,
                line_reader=lambda prompt: next(lines),
                synthesizer=synthesize,
            )

        self.assertEqual(result, 0)
        self.assertEqual(calls, ["bad voice", "works"])
        self.assertEqual(FakeClient.last_instance.output.writes, [b"pcm"])
        self.assertIn("voice unavailable", error_output.getvalue())

    async def test_speak_parser_defaults_to_first_party_virtual_input(self):
        parsed = _parser().parse_args(["speak"])
        self.assertEqual(parsed.destination, "coreaudio:com.audioplane.input.device")
        self.assertEqual(parsed.buffer_ms, 60)
        self.assertIsNone(parsed.voice)
        self.assertIsNone(parsed.rate)


if __name__ == "__main__":
    unittest.main()
