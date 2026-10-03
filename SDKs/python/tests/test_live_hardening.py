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



class ShutdownTests(unittest.IsolatedAsyncioTestCase):
    async def test_provider_setup_failure_still_persists_report(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'validation.json'
            args=agent.parse_args(['--replay', 'unused.wav', '--validation-json', str(path)])
            with mock.patch.object(agent, 'create_sink', side_effect=RuntimeError('offline failure')):
                with self.assertRaises(RuntimeError):
                    await agent.run_agent(args)
            self.assertTrue(path.exists())
            self.assertIn('session failed', path.read_text())

    async def test_provider_close_is_bounded_and_receive_task_is_cancelled(self):
        class Sink:
            async def aclose(self): await asyncio.Event().wait()
        receive=asyncio.create_task(asyncio.Event().wait())
        with mock.patch.object(agent, 'PROVIDER_CLOSE_TIMEOUT', 0.02, create=True):
            with self.assertRaises(asyncio.TimeoutError):
                await asyncio.wait_for(agent.close_provider_session(Sink(), receive), 0.2)
        self.assertTrue(receive.done())


class PlaybackGapTests(unittest.IsolatedAsyncioTestCase):
    class Output:
        info=SimpleNamespace(id='output', destination_id='offline')
        def __init__(self):
            self.writes=[]
            self.metrics=SimpleNamespace(underrun_frames=17, underrun_events=1,
                dropped_frames=0, flushed_frames=0, queue_depth_frames=0,
                buffered_milliseconds=0, target_buffer_milliseconds=60, route_changes=0)
        async def write(self, data): self.writes.append(bytes(data))
        async def flush(self): pass
        async def refresh(self): return SimpleNamespace(metrics=self.metrics)
        async def aclose(self, **kw): pass
    class Client:
        def __init__(self): self.outputs=[]
        async def playback(self, **kw):
            output=PlaybackGapTests.Output();self.outputs.append(output);return output

    async def test_tiny_chunk_is_not_held_through_producer_stall(self):
        client=self.Client();player=agent.RuntimeResponsePlayer(client,'offline',debug=False)
        data=b'\1\2'*480
        try:
            await player.write(ProviderEvent('gemini','audio',audio=data,
                                  audio_format=AudioFormat.gemini_live_output()))
            await player._queue.join()
            await asyncio.sleep(.09)
            self.assertTrue(client.outputs, '20 ms PCM still waiting for a future provider event')
            self.assertEqual(b''.join(client.outputs[0].writes),data)
        finally: await player.close()

    async def test_continuous_tiny_chunks_do_not_reset_coalescing_deadline(self):
        client=self.Client();player=agent.RuntimeResponsePlayer(client,'offline',debug=False)
        async def produce():
            for _ in range(20):
                await player.write(ProviderEvent('gemini','audio',audio=b"\1\2"*24,
                    audio_format=AudioFormat.gemini_live_output()))
                await asyncio.sleep(.01)
        producer=asyncio.create_task(produce())
        try:
            await asyncio.sleep(.09)
            self.assertTrue(client.outputs, "tiny arrivals indefinitely extend the coalescing wait")
            self.assertFalse(producer.done())
        finally:
            await producer
            await player.finish_response()
            await player.close()
        self.assertEqual(b"".join(client.outputs[0].writes), b"\1\2"*480)

    async def test_burst_pacing_and_stall_diagnostics_do_not_log_pcm(self):
        now=[0.0];delays=[];lifecycle=[]
        async def sleep(delay): delays.append(delay);now[0]+=delay;await asyncio.sleep(0)
        client=self.Client();player=agent.RuntimeResponsePlayer(client,'offline',debug=False,
            clock=lambda:now[0],sleep=sleep,lifecycle_callback=lifecycle.append)
        fmt=AudioFormat.gemini_live_output();data=b'\1\2'*1200
        try:
            for _ in range(20): await player.write(ProviderEvent('gemini','audio',audio=data,audio_format=fmt))
            await player._queue.join()
            self.assertLessEqual(player._playback_cursor-now[0],.150001)
            now[0]+=1
            await player.write(ProviderEvent('gemini','audio',audio=data,audio_format=fmt))
            await player.finish_response()
            await player._queue.join()
        finally: await player.close()
        self.assertEqual(b''.join(client.outputs[0].writes),data*21)
        metrics=player.diagnostics
        self.assertGreater(metrics['max_provider_chunk_interval_ms'],900)
        self.assertGreater(metrics['estimated_supply_gap_ms'],500)
        self.assertGreater(metrics['pacing_wait_ms'],500)
        self.assertEqual(metrics['runtime_underrun_events'],1)
        self.assertEqual(metrics['output_sessions'],1)
        self.assertNotIn('audio', json.dumps([dict(e.details) for e in lifecycle]))

    async def test_interruption_of_blocked_short_tail_counts_discard_and_write_wait(self):
        started=asyncio.Event()
        class Output(self.Output):
            async def write(self, data):
                started.set();await asyncio.Event().wait()
        class Client:
            async def playback(self, **kwargs):return Output()
        player=agent.RuntimeResponsePlayer(Client(),'offline',debug=False)
        data=b"\1\2"*480
        try:
            await player.write(ProviderEvent('gemini','audio',audio=data,
                audio_format=AudioFormat.gemini_live_output()))
            await asyncio.wait_for(started.wait(),.3)
            await asyncio.wait_for(player.interrupt_response(),.2)
            await asyncio.sleep(0)
        finally:await player.close()
        self.assertEqual(player.diagnostics['interrupted_writes'],1)
        self.assertEqual(player.diagnostics['interruption_discarded_bytes'],len(data))
        self.assertGreater(player.diagnostics['max_write_wait_ms'],0)

    async def test_worker_failure_after_completed_response_cannot_pass_validation(self):
        tracker=agent.LiveValidationTracker(enabled=False);done=asyncio.Event()
        for name in ('activity_started','activity_ended','input_finalized'):
            tracker.lifecycle(ProviderLifecycleEvent('gemini',name))
        class Output(self.Output):
            async def write(self,data):raise RuntimeError('private error content')
        class Client:
            async def playback(self,**kw):return Output()
        class Sink:
            async def events(self):
                yield ProviderEvent('gemini','audio',response_started=True,response_completed=True,
                    audio=b"\1\2"*1200,audio_format=AudioFormat.gemini_live_output())
        player=agent.RuntimeResponsePlayer(Client(),'offline',debug=False,
            on_failure=lambda error:done.set(),lifecycle_callback=tracker.response_playback_event)
        await agent.print_provider_events(Sink(),done,response_player=player,validation=tracker)
        await player._queue.join();await player.close()
        report=tracker.final_report()
        self.assertEqual(report['status'],'warn')
        self.assertIn('response playback failed',report['warnings'])
        self.assertNotIn('private error content',json.dumps(report))

    async def test_receive_side_playback_failure_is_scalar_warning(self):
        tracker=agent.LiveValidationTracker(enabled=False)
        class Player:
            async def write(self,event):raise RuntimeError('private error content')
        class Sink:
            async def events(self):
                yield ProviderEvent('gemini','audio',response_started=True,response_completed=True,
                    audio=b"\1\2"*1200,audio_format=AudioFormat.gemini_live_output())
        await agent.print_provider_events(Sink(),asyncio.Event(),response_player=Player(),validation=tracker)
        report=tracker.final_report()
        self.assertIn('response playback failed',report['warnings'])
        self.assertNotIn('private error content',json.dumps(report))

    async def test_submillisecond_tail_is_padded_once_and_not_lost(self):
        client=self.Client();player=agent.RuntimeResponsePlayer(client,'offline',debug=False)
        data=b'\1\2'*5
        await player.write(ProviderEvent('gemini','audio',audio=data,
                              audio_format=AudioFormat.gemini_live_output()))
        await player.finish_response();await player._queue.join();await player.close()
        self.assertEqual(client.outputs[0].writes,[data+b'\0'*(48-len(data))])


class PlaybackCorrelationTests(unittest.TestCase):
    def test_delayed_output_is_attached_to_its_response_not_latest_input(self):
        tracker=agent.LiveValidationTracker(enabled=False)
        def edge(name, ms): tracker.lifecycle(ProviderLifecycleEvent('gemini',name,timestamp_ns=ms*1_000_000))
        edge('activity_started',0)
        first=ProviderEvent('gemini','message',response_started=True,response_completed=True)
        with mock.patch.object(agent.time,'monotonic_ns',return_value=100_000_000):
            tracker.provider_event(first);tracker.finish_provider_event(first)
        edge('activity_ended',200);edge('input_finalized',201)
        edge('activity_started',300)
        with mock.patch.object(agent.time,'monotonic_ns',return_value=400_000_000):
            tracker.provider_event(ProviderEvent('gemini','message',response_started=True))
        tracker.response_playback_event(ProviderLifecycleEvent('audioplane','output_started',
            timestamp_ns=500_000_000,details={'response_index':1}))
        self.assertEqual(tracker.turns[0].output_started_ns,500_000_000)
        self.assertIsNone(tracker.turns[1].output_started_ns)
