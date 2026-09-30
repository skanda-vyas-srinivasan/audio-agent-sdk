"""Regression coverage for lost onset audio and noise-held-open Gemini turns."""

import asyncio
import importlib.util
import os
import random
import struct
import sys
import unittest
import wave
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).parents[1] / "src"))

from audioplane import (ActivityDetectionConfig, AudioActivityDetector, AudioFormat,
                       AudioFrame, WebRTCVoiceActivityDetector)
from audioplane.agent import create_sink, parse_args
from audioplane.providers import GeminiLiveSink, GeminiTurnDetectionConfig


def pcm_frame(sequence, amplitude, count=160, **kwargs):
    return AudioFrame(
        "stream", sequence, sequence * 10_000_000, count,
        AudioFormat.gemini_live(), struct.pack("<h", round(amplitude * 32767)) * count,
        **kwargs)


class Session:
    def __init__(self):
        self.values = []

    async def send_realtime_input(self, **value):
        self.values.append(value)


class FakeVad:
    instances = []

    def __init__(self, mode):
        self.mode = mode
        self.blocks = []
        self.instances.append(self)

    def is_speech(self, block, rate):
        self.blocks.append((block, rate))
        return abs(struct.unpack_from("<h", block)[0]) > 1000


class SpeechClassifierTests(unittest.TestCase):
    def setUp(self):
        FakeVad.instances = []
        self.modules = mock.patch.dict(
            sys.modules, {"webrtcvad": SimpleNamespace(Vad=FakeVad)})
        self.modules.start()
        self.addCleanup(self.modules.stop)

    def test_arbitrary_packet_sizes_preserve_bytes_with_one_partial_block(self):
        detector = WebRTCVoiceActivityDetector()
        expected = b""
        for sequence, count in enumerate([17, 171, 511, 9, 932, 128]):
            frame = pcm_frame(sequence, 0.1, count)
            expected += frame.data
            detector.is_speech(frame)
            self.assertLess(len(detector._pending), 320)
        blocks = FakeVad.instances[0].blocks
        self.assertTrue(all(len(block) == 320 and rate == 16000 for block, rate in blocks))
        self.assertEqual(b"".join(block for block, _ in blocks) + bytes(detector._pending),
                         expected)

    def test_discontinuity_discards_partial_audio_and_classifier_history(self):
        detector = WebRTCVoiceActivityDetector()
        detector.is_speech(pcm_frame(0, 0.1, 80))
        self.assertFalse(detector.is_speech(pcm_frame(1, 0.0, discontinuity=True)))
        self.assertEqual(len(FakeVad.instances), 2)
        self.assertEqual(FakeVad.instances[0].blocks, [])
        self.assertEqual(FakeVad.instances[1].blocks[0][0], b"\0" * 320)

    def test_invalid_mode_format_and_stream_fail_explicitly(self):
        for mode in (-1, 4, True, 2.0):
            with self.assertRaises(ValueError):
                WebRTCVoiceActivityDetector(mode)
        detector = WebRTCVoiceActivityDetector()
        with self.assertRaises(ValueError):
            detector.is_speech(replace(pcm_frame(0, 0), format=AudioFormat(24000)))
        with self.assertRaises(ValueError):
            detector.is_speech(replace(pcm_frame(0, 0), data=b"\0"))
        detector.is_speech(pcm_frame(0, 0))
        with self.assertRaises(ValueError):
            detector.is_speech(replace(pcm_frame(1, 0), stream_id="other"))

    def test_missing_optional_dependency_has_install_guidance(self):
        with mock.patch.dict(sys.modules, {"webrtcvad": None}):
            with self.assertRaisesRegex(ImportError, "pip install webrtcvad-wheels"):
                WebRTCVoiceActivityDetector()

    def test_legacy_energy_detector_retains_contiguous_onset_default(self):
        detector = AudioActivityDetector(ActivityDetectionConfig())
        amplitudes = ([0.08] * 20 + [0.003] * 4) * 5
        self.assertFalse(any(detector.observe(pcm_frame(i, amplitude))
                             for i, amplitude in enumerate(amplitudes)))

    def test_one_large_speech_packet_can_confirm_an_onset(self):
        detector = AudioActivityDetector(ActivityDetectionConfig(
            minimum_activity_ms=100, onset_gap_ms=100))
        event = detector.observe(pcm_frame(0, 0.1, count=6400))
        self.assertEqual(event.type, "activity_started")


class GeminiSpeechTurnTests(unittest.IsolatedAsyncioTestCase):
    async def test_first_fragmented_utterance_is_sent_and_finalized_before_close(self):
        session = Session()
        sink = GeminiLiveSink(session, blob_factory=lambda **value: value)
        utterance = ([0.08] * 20 + [0.003] * 4) * 5
        frames = [pcm_frame(i, amplitude)
                  for i, amplitude in enumerate(utterance + [0.0] * 140)]
        for frame in frames:
            await sink.send_audio(frame)
        ends = [value for value in session.values if value.get("audio_stream_end")]
        self.assertEqual(len(ends), 1)
        sent = b"".join(value["audio"]["data"] for value in session.values if "audio" in value)
        self.assertTrue(sent.startswith(b"".join(frame.data for frame in frames[:len(utterance)])))
        await sink.aclose()
        self.assertEqual(sum(bool(value.get("audio_stream_end")) for value in session.values), 1)

    async def test_speech_classifier_finalizes_over_noise_above_energy_end_threshold(self):
        with mock.patch.dict(sys.modules, {"webrtcvad": SimpleNamespace(Vad=FakeVad)}):
            classifier = WebRTCVoiceActivityDetector()
        session = Session()
        sink = GeminiLiveSink(
            session, blob_factory=lambda **value: value,
            voice_activity_detector=classifier)
        amplitudes = [0.012] * 100 + [0.1] * 40 + [0.012] * 300
        for sequence, amplitude in enumerate(amplitudes):
            await sink.send_audio(pcm_frame(sequence, amplitude))
        self.assertEqual(sum(bool(value.get("audio_stream_end")) for value in session.values), 1)
        self.assertFalse(sink._segment_open)
        await sink.aclose()

    async def test_new_speech_reopens_without_finalizing_short_sentence_gaps(self):
        session = Session()
        sink = GeminiLiveSink(session, blob_factory=lambda **value: value)
        sequence = 0
        for _ in range(3):
            for amplitude in [0.08] * 40 + [0.0] * 40 + [0.08] * 40:
                await sink.send_audio(pcm_frame(sequence, amplitude))
                sequence += 1
            self.assertTrue(sink._segment_open)
            for _ in range(140):
                await sink.send_audio(pcm_frame(sequence, 0))
                sequence += 1
        self.assertEqual(sum(bool(value.get("audio_stream_end")) for value in session.values), 3)
        await sink.aclose()

    async def test_sparse_noise_never_accumulates_unbounded_onset_buffer(self):
        session = Session()
        sink = GeminiLiveSink(session, blob_factory=lambda **value: value)
        for sequence in range(10000):
            amplitude = 0.1 if sequence % 9 == 0 else 0
            await sink.send_audio(pcm_frame(sequence, amplitude))
            self.assertLessEqual(len(sink._candidate_frames), 61)
        self.assertEqual(session.values, [])
        await sink.aclose()

    async def test_cli_defaults_to_speech_vad_and_forwards_configuration(self):
        args = parse_args(["--provider", "gemini", "--gemini-vad-mode", "3"])
        with mock.patch.dict(sys.modules, {"webrtcvad": SimpleNamespace(Vad=FakeVad)}):
            with mock.patch.object(GeminiLiveSink, "connect", new_callable=mock.AsyncMock) as connect:
                await create_sink(args)
        self.assertIsInstance(connect.call_args.kwargs["voice_activity_detector"],
                              WebRTCVoiceActivityDetector)
        self.assertEqual(FakeVad.instances[-1].mode, 3)
        self.assertEqual(connect.call_args.kwargs["turn_detection"].onset_gap_ms, 100)

    async def test_energy_mode_is_explicit_and_dependency_free(self):
        args = parse_args(["--provider", "gemini", "--gemini-vad", "energy"])
        with mock.patch.dict(sys.modules, {"webrtcvad": None}):
            with mock.patch.object(GeminiLiveSink, "connect", new_callable=mock.AsyncMock) as connect:
                await create_sink(args)
        self.assertIsNone(connect.call_args.kwargs["voice_activity_detector"])


@unittest.skipUnless(importlib.util.find_spec("webrtcvad"), "optional WebRTC extra not installed")
class NativeSpeechClassifierTests(unittest.TestCase):
    def test_native_classifier_accepts_runtime_sized_silence_packets(self):
        detector = WebRTCVoiceActivityDetector()
        for sequence in range(1000):
            self.assertFalse(detector.is_speech(pcm_frame(sequence, 0.0, count=171)))
            self.assertLess(len(detector._pending), 320)

    @unittest.skipUnless(os.environ.get("AUDIOPLANE_VAD_SPEECH_FIXTURE"),
                         "run Scripts/test-gemini-speech-vad.sh for synthesized speech")
    def test_real_speech_finalizes_once_over_silence_and_stationary_noise(self):
        with wave.open(os.environ["AUDIOPLANE_VAD_SPEECH_FIXTURE"]) as fixture:
            self.assertEqual((fixture.getframerate(), fixture.getsampwidth(),
                              fixture.getnchannels()), (16000, 2, 1))
            samples = [item[0] for item in struct.iter_unpack(
                "<h", fixture.readframes(fixture.getnframes()))]
        self.assertTrue(samples)

        async def run_case(noisy):
            rng = random.Random(123)

            def noise():
                return int(rng.gauss(0, 0.012) * 32767) if noisy else 0

            data = [noise() for _ in range(32000)]
            data += [max(-32768, min(32767, int(value * 0.5) + noise()))
                     for value in samples]
            data += [noise() for _ in range(48000)]
            session = Session()
            events = []
            sink = GeminiLiveSink(
                session, blob_factory=lambda **value: value,
                turn_detection=GeminiTurnDetectionConfig(minimum_activity_ms=100),
                voice_activity_detector=WebRTCVoiceActivityDetector(),
                lifecycle_callback=events.append)
            try:
                for sequence, position in enumerate(range(0, len(data), 171)):
                    chunk = data[position:position + 171]
                    await sink.send_audio(AudioFrame(
                        "stream", sequence, position * 1_000_000_000 // 16000,
                        len(chunk), AudioFormat.gemini_live(),
                        struct.pack("<" + "h" * len(chunk), *chunk)))
                self.assertEqual([event.type for event in events],
                                 ["activity_started", "activity_ended", "input_finalized"])
                self.assertFalse(sink._segment_open)
                self.assertTrue(any("audio" in value for value in session.values))
            finally:
                await sink.aclose()
            self.assertEqual(sum(bool(value.get("audio_stream_end"))
                                 for value in session.values), 1)

        for noisy in (False, True):
            with self.subTest(stationary_noise=noisy):
                asyncio.run(run_case(noisy))


if __name__ == "__main__":
    unittest.main()
