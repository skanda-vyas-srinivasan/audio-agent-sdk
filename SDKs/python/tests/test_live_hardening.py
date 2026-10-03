"""Offline regressions: lifecycle ordering, cancellation and output timing."""
import asyncio
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).parents[1] / 'src'))
from audioplane import agent
from sonexis import AudioFormat
from sonexis.providers.base import ProviderEvent, ProviderLifecycleEvent
from sonexis.providers.gemini import GeminiLiveSink


class CorrelationTests(unittest.TestCase):
    def edge(self, tracker, name, ms):
        tracker.lifecycle(ProviderLifecycleEvent('gemini', name, timestamp_ns=ms*1_000_000))

    def response(self, tracker, ms, **flags):
        event = ProviderEvent('gemini', 'message', **flags)
        with mock.patch.object(agent.time, 'monotonic_ns', return_value=ms*1_000_000):
            tracker.provider_event(event)
            tracker.finish_provider_event(event)

    def test_early_response_does_not_leave_stale_finalization(self):
        t = agent.LiveValidationTracker(enabled=False)
        self.edge(t, 'activity_started', 0)
        self.response(t, 100, response_started=True)
        self.edge(t, 'activity_ended', 1200)
        self.edge(t, 'input_finalized', 1201)
        self.response(t, 2000, response_completed=True)
        self.edge(t, 'activity_started', 3000)
        self.response(t, 3100, response_started=True, response_completed=True)
        self.assertEqual(len(t.turns), 2)
        self.assertIsNone(t.turns[0].summary()['response_start_ms'])
        self.assertEqual(t.turns[1].response_started_ns, 3_100_000_000)
        self.assertIsNone(t.turns[1].summary()['response_start_ms'])

    def test_multiple_or_absent_segments_are_not_fifo_latency(self):
        t = agent.LiveValidationTracker(enabled=False)
        for start in (0, 1000):
            self.edge(t, 'activity_started', start)
            self.edge(t, 'activity_ended', start+100)
            self.edge(t, 'input_finalized', start+101)
        self.response(t, 9000, response_started=True, response_completed=True)
        report=t.final_report()
        self.assertTrue(all(row['response_start_ms'] is None for row in report['turns']))
        self.assertFalse(any('exceeded' in w for row in report['turns'] for w in row['warnings']))

    def test_overlap_then_interruption_does_not_steal_next_response(self):
        t = agent.LiveValidationTracker(enabled=False)
        self.edge(t, 'activity_started', 0)
        self.response(t, 100, response_started=True)
        self.edge(t, 'activity_ended', 200)
        self.edge(t, 'input_finalized', 201)
        self.edge(t, 'activity_started', 300)
        self.response(t, 400, response_interrupted=True)
        self.response(t, 401, response_started=True)
        self.edge(t, 'activity_ended', 500)
        self.edge(t, 'input_finalized', 501)
        self.response(t, 600, response_completed=True)
        self.assertEqual(len(t.turns), 2)
        self.assertEqual(t.turns[1].response_started_ns, 401_000_000)
        self.assertIsNone(t.turns[1].summary()['response_start_ms'])


class AdapterTimingTests(unittest.IsolatedAsyncioTestCase):
    async def test_early_response_cannot_reuse_its_late_end_in_debug(self):
        messages=asyncio.Queue()
        class Session:
            async def send_realtime_input(self, **kwargs): pass
            async def receive(self):
                yield await messages.get()
        debug=[]
        sink=GeminiLiveSink(Session(), blob_factory=lambda **kw: kw, debug_callback=debug.append)
        sink._segment_open=True
        def value(**kw): return SimpleNamespace(server_content=SimpleNamespace(**kw), text=None)
        events=sink.events()
        await messages.put(value(model_turn=SimpleNamespace(parts=[])))
        await events.__anext__()
        await sink._send_audio_stream_end()
        await messages.put(value(turn_complete=True))
        await events.__anext__()
        await messages.put(value(model_turn=SimpleNamespace(parts=[])))
        await events.__anext__()
        starts=[s for s in debug if s.startswith('Gemini response start')]
        self.assertFalse(any('after turn end' in s for s in starts))
        await events.aclose()
        await sink.aclose()
