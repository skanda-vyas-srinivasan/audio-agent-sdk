"""Exercise real process signals/stdin/tee with offline SDK boundaries."""
import asyncio
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).parents[1] / 'src'))
from audioplane import agent
from sonexis import AudioFormat, AudioFrame, ProviderError
from sonexis.providers.base import ProviderEvent, ProviderLifecycleEvent


def fixture(phase, ready, report):
    class Stream:
        info=SimpleNamespace(id='capture', stream_id='stream')
        async def __aenter__(self): return self
        async def __aexit__(self, *args): pass
        def __aiter__(self): return self
        async def __anext__(self):
            await asyncio.sleep(.01)
            if phase == 'activity': Path(ready).touch()
            return AudioFrame('stream', 1, 0, 160, AudioFormat.gemini_live(), b'\0'*320)
    class Output:
        info=SimpleNamespace(id='output', destination_id='offline')
        metrics=SimpleNamespace(frames_rendered=0)
        async def write(self, data):
            Path(ready).touch()
            await asyncio.Event().wait()
        async def aclose(self, **kwargs): pass
    class Client:
        def __init__(self, *args, **kwargs): pass
        async def __aenter__(self): return self
        async def __aexit__(self, *args): pass
        async def connect(self): pass
        async def close(self): pass
        async def get_source(self, selector): return SimpleNamespace(id='offline', name='Offline')
        async def capture(self, source, **kwargs): return Stream()
        async def playback(self, **kwargs): return Output()
    class Sink:
        required_format=AudioFormat.gemini_live()
        async def send_audio(self, frame): pass
        async def aclose(self):
            if phase == 'failure':
                await asyncio.sleep(.05)
                raise RuntimeError('offline cleanup failed')
        async def events(self):
            await asyncio.sleep(.03)
            if phase == 'failure':
                Path(ready).touch()
                raise ProviderError('offline_failure', 'offline receive failure')
            yield ProviderEvent('gemini', 'audio', response_started=True,
                                audio=b'\1\2'*2400, audio_format=AudioFormat.gemini_live_output())
            await asyncio.Event().wait()
    async def create_sink(args, callback):
        callback(ProviderLifecycleEvent('gemini', 'activity_started'))
        return Sink()
    async def watch(*args): await asyncio.Event().wait()
    args=['--source', 'Offline', '--provider', 'gemini', '--gemini-barge-in',
          '--validation-json', report, '--validate-live']
    if phase == 'playback': args += ['--response-output', 'offline']
    # Only accelerate timeouts. stdin, run_live/run_agent, cancellation, report
    # persistence and playback worker are the actual implementation.
    with mock.patch.object(agent, 'Sonexis', Client), \
         mock.patch.object(agent, 'create_sink', create_sink), \
         mock.patch.object(agent, 'watch_source', watch), \
         mock.patch.object(agent, 'OUTPUT_CLOSE_TIMEOUT', .1, create=True):
        original_player=agent.RuntimeResponsePlayer
        def player(*args, **kwargs): return original_player(*args, close_timeout=.03, **kwargs)
        with mock.patch.object(agent, 'RuntimeResponsePlayer', player):
            agent.cli_main(args)


class ShutdownProcessTests(unittest.TestCase):
    def test_q_ctrl_c_and_tee_during_activity_playback_and_failure(self):
        for phase in ('activity', 'playback', 'failure'):
            for stop in ('q', 'sigint', 'tee'):
                with self.subTest(phase=phase, stop=stop), tempfile.TemporaryDirectory() as directory:
                    root=Path(directory); ready=root/'ready'; report=root/'validation.json'
                    command=[sys.executable, '-u', __file__, '--fixture', phase, str(ready), str(report)]
                    if stop == 'tee':
                        command=['/bin/bash', '-c', shlex.join(command)+' | tee '+shlex.quote(str(root/'log'))]
                    process=subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                             stderr=subprocess.PIPE, start_new_session=True)
                    try:
                        deadline=time.monotonic()+3
                        while not ready.exists() and process.poll() is None and time.monotonic()<deadline:
                            time.sleep(.01)
                        self.assertTrue(ready.exists())
                        if stop == 'q': process.stdin.write(b'q\n'); process.stdin.flush()
                        else: os.killpg(process.pid, signal.SIGINT)
                        _, errors=process.communicate(timeout=3)
                        self.assertTrue(report.exists(), errors.decode())
                        value=json.loads(report.read_text())
                        self.assertIn('turns', value)
                        self.assertEqual(report.stat().st_mode & 0o777, 0o600)
                        if phase == 'failure': self.assertIn('provider receive failed', value['warnings'])
                    finally:
                        if process.poll() is None:
                            os.killpg(process.pid, signal.SIGKILL)
                            process.wait()
                        if process.stdin: process.stdin.close()
                        if process.stderr: process.stderr.close()


if __name__ == '__main__':
    if len(sys.argv)>1 and sys.argv[1]=='--fixture': fixture(*sys.argv[2:])
    else: unittest.main()
