import asyncio
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "src"))

from sonexis import (AudioFormat, AudioFrame, AudioOutputDestination, AudioSource,
                     MicrophonePassthrough, SampleFormat, Sonexis, SonexisError)
from sonexis.errors import AmbiguousSourceError, SourceNotFoundError


FORMAT = AudioFormat(48_000, 1, SampleFormat.PCM_S16LE)


def microphone(uid="built-in", *, is_default=True):
    return AudioSource(
        id=f"microphone:{uid}",
        name="Test Microphone",
        kind="microphone",
        process_ids=[],
        bundle_identifier=None,
        process_state="running",
        available=True,
        producing_audio=None,
        native_format=FORMAT,
        is_default=is_default,
    )


def destination(uid="com.audioplane.input.device"):
    return AudioOutputDestination(
        id=f"coreaudio:{uid}",
        name="AudioPlane Input",
        kind="virtual_input",
        available=True,
        is_default=False,
        follows_system_default=False,
        active_device_id=f"coreaudio:{uid}",
        active_device_name="AudioPlane Input",
        native_format=FORMAT,
        supported_formats=[FORMAT],
    )


class FakeCapture:
    def __init__(self, frames=None, *, block=False):
        self.frames = iter(frames or [])
        self.block = block
        self.closed = False

    def __aiter__(self):
        return self

    async def __anext__(self):
        if self.block:
            await asyncio.Future()
        try:
            return next(self.frames)
        except StopIteration:
            raise StopAsyncIteration

    async def aclose(self):
        self.closed = True


class FakeOutput:
    def __init__(self, value):
        self.destination = value
        self.writes = []
        self.closed = False
        self.drain = None

    async def write(self, data, *, timestamp_ns=None, discontinuity=False):
        self.writes.append((data, timestamp_ns, discontinuity))

    async def aclose(self, *, drain=True):
        self.closed = True
        self.drain = drain


class FakeClient:
    def __init__(self, source, output_destination, capture):
        self.source = source
        self.destination = output_destination
        self.capture_session = capture
        self.output = FakeOutput(output_destination)

    async def default_microphone(self):
        return self.source

    async def get_source(self, selector):
        return self.source

    async def get_output_destination(self, selector):
        return self.destination

    async def playback(self, **kwargs):
        return self.output

    async def capture(self, source, *, format):
        return self.capture_session


class SourceResolutionTests(unittest.IsolatedAsyncioTestCase):
    async def test_default_microphone_uses_default_annotation(self):
        selected = microphone("selected", is_default=True)
        other = microphone("other", is_default=False)
        client = Sonexis()

        async def sources():
            return [other, selected]

        client.sources = sources
        self.assertEqual(await client.default_microphone(), selected)
        self.assertEqual(await client.find_sources(kind="microphone"), [other, selected])

    async def test_default_microphone_rejects_missing_or_ambiguous_metadata(self):
        client = Sonexis()

        async def none():
            return []

        client.sources = none
        with self.assertRaises(SourceNotFoundError):
            await client.default_microphone()

        async def ambiguous():
            return [microphone("one", is_default=None),
                    microphone("two", is_default=None)]

        client.sources = ambiguous
        with self.assertRaises(AmbiguousSourceError):
            await client.default_microphone()


class MicrophonePassthroughTests(unittest.IsolatedAsyncioTestCase):
    async def test_close_during_opening_cannot_resurrect_passthrough(self):
        capture = FakeCapture(block=True)
        client = FakeClient(microphone(), destination(), capture)
        entered, release = asyncio.Event(), asyncio.Event()

        async def delayed_capture(source, *, format):
            entered.set()
            await release.wait()
            return capture

        client.capture = delayed_capture
        passthrough = MicrophonePassthrough(
            client, input_source=None, output_destination="virtual_input",
            format=FORMAT, target_buffer_milliseconds=60)
        opening = asyncio.create_task(passthrough.__aenter__())
        await asyncio.wait_for(entered.wait(), 1.0)
        closing = asyncio.create_task(passthrough.aclose())
        await asyncio.sleep(0)
        release.set()
        await asyncio.gather(opening, closing)
        self.assertEqual(passthrough._state, "closed")
        self.assertTrue(capture.closed)
        self.assertTrue(client.output.closed)
        self.assertIsNone(passthrough._pump_task)

    async def test_forwards_frames_and_discontinuities(self):
        frames = [
            AudioFrame("stream", 0, 10, 2, FORMAT, b"\x00\x01\x02\x03"),
            AudioFrame("stream", 1, 20, 2, FORMAT, b"\x04\x05\x06\x07",
                       dropped_frames_before=4),
        ]
        capture = FakeCapture(frames)
        client = FakeClient(microphone(), destination(), capture)
        passthrough = MicrophonePassthrough(
            client,
            input_source=None,
            output_destination="virtual_input",
            format=FORMAT,
            target_buffer_milliseconds=60,
        )

        async with passthrough:
            await passthrough.wait()

        self.assertEqual(
            client.output.writes,
            [(b"\x00\x01\x02\x03", 10, False),
             (b"\x04\x05\x06\x07", 20, True)],
        )
        self.assertEqual(passthrough.metrics.frames_forwarded, 4)
        self.assertEqual(passthrough.metrics.bytes_forwarded, 8)
        self.assertEqual(passthrough.metrics.discontinuities_forwarded, 1)
        self.assertTrue(capture.closed)
        self.assertTrue(client.output.closed)
        self.assertTrue(client.output.drain)

    async def test_rejects_direct_virtual_input_feedback(self):
        uid = "com.audioplane.input.device"
        client = FakeClient(microphone(uid), destination(uid), FakeCapture())
        passthrough = MicrophonePassthrough(
            client,
            input_source=None,
            output_destination="virtual_input",
            format=FORMAT,
            target_buffer_milliseconds=60,
        )
        with self.assertRaisesRegex(SonexisError, "microphone_feedback_loop"):
            await passthrough.__aenter__()

    async def test_cancellation_closes_both_sessions_without_drain(self):
        capture = FakeCapture(block=True)
        client = FakeClient(microphone(), destination(), capture)
        passthrough = MicrophonePassthrough(
            client,
            input_source=None,
            output_destination="virtual_input",
            format=FORMAT,
            target_buffer_milliseconds=60,
        )
        await passthrough.__aenter__()
        await passthrough.aclose(drain=False)
        self.assertTrue(capture.closed)
        self.assertTrue(client.output.closed)
        self.assertFalse(client.output.drain)


if __name__ == "__main__":
    unittest.main()
