import argparse
import io
import json
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "src"))

from audioplane import AudioPlane, AudioPlaneClient, Sonexis
from audioplane.cli import _run
from sonexis import AudioOutputDestination, AudioSource, Handshake, RuntimeStatus


class FakeClient:
    def __init__(self, socket_path, *, client_name, client_version):
        self.socket_path = socket_path or "/tmp/audio-plane-test.sock"
        self.client_name = client_name
        self.client_version = client_version
        self.handshake = None

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


def arguments(command, *, json_output=False, socket=None):
    return argparse.Namespace(command=command, json=json_output, socket=socket)


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


if __name__ == "__main__":
    unittest.main()
