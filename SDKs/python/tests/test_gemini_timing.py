"""Offline Gemini receive/send interleaving regression; no network or PCM logs."""
import asyncio
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).parents[1] / 'src'))
from sonexis.providers.gemini import GeminiLiveSink


class GeminiFinalizationTimingTests(unittest.IsolatedAsyncioTestCase):
    async def test_response_during_stream_end_ack_does_not_seed_next_latency(self):
        messages=asyncio.Queue();ending=asyncio.Event();ack=asyncio.Event()
        class Session:
            async def send_realtime_input(self, **kw):
                if kw.get("audio_stream_end"):
                    ending.set();await ack.wait()
            async def receive(self): yield await messages.get()
        debug=[];sink=GeminiLiveSink(Session(),blob_factory=lambda **kw:kw,debug_callback=debug.append)
        sink._segment_open=True
        end=asyncio.create_task(sink._send_audio_stream_end())
        await ending.wait()
        events=sink.events()
        def value(**kw):return SimpleNamespace(server_content=SimpleNamespace(**kw),text=None)
        await messages.put(value(model_turn=SimpleNamespace(parts=[])))
        await events.__anext__()
        ack.set();await end
        await messages.put(value(turn_complete=True));await events.__anext__()
        await messages.put(value(model_turn=SimpleNamespace(parts=[])));await events.__anext__()
        self.assertIsNone(sink._last_turn_finalized_at)
        self.assertFalse(any("since local finalization" in line for line in debug))
        await events.aclose();await sink.aclose()
