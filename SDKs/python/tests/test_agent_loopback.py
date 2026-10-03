"""Opt-in actual HAL regression; generated PCM stays in memory, no recordings."""
import asyncio
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).parents[1] / 'src'))
from audioplane import AudioPlane, AudioFormat
from audioplane.agent import RuntimeResponsePlayer
from sonexis.providers.base import ProviderEvent


@unittest.skipUnless(os.environ.get('AUDIOPLANE_TEST_LOOPBACK_RUNTIME'),
                     'set AUDIOPLANE_TEST_LOOPBACK_RUNTIME to a signed runtime; requires BlackHole')
class ActualHALPlaybackTests(unittest.IsolatedAsyncioTestCase):
    async def test_short_response_and_short_resumption_render_without_output_close(self):
        with tempfile.TemporaryDirectory(prefix='ap-tail-',dir='/tmp') as directory:
            with open(os.devnull,'w') as log:
                runtime=subprocess.Popen([os.environ['AUDIOPLANE_TEST_LOOPBACK_RUNTIME'],
                    '--socket-dir',directory],stdout=log,stderr=log)
                try:
                    path=directory+'/control.sock'
                    for _ in range(100):
                        if os.path.exists(path): break
                        await asyncio.sleep(.02)
                    async with AudioPlane(path) as client:
                        async with await client.capture('microphone:BlackHole2ch_UID',
                                                       format=AudioFormat(48000,1)) as capture:
                            peaks=[]
                            async def read():
                                async for frame in capture:
                                    peaks.append(max((abs(v[0]) for v in struct.iter_unpack('<h',frame.data)),default=0))
                            reading=asyncio.create_task(read())
                            player=RuntimeResponsePlayer(client,'coreaudio:BlackHole2ch_UID',debug=False)
                            try:
                                for frames in (480,5,480):
                                    peaks.clear()
                                    await player.write(ProviderEvent('gemini','audio',
                                        audio=struct.pack('<h',2000)*frames,
                                        audio_format=AudioFormat.gemini_live_output()))
                                    await player.finish_response();await player._queue.join()
                                    # Includes the existing 50 ms metrics timer quantization.
                                    await asyncio.sleep(.35)
                                    self.assertGreater(max(peaks,default=0),100,
                                        'partial/short resumed PCM stayed silent until a later packet or EOS')
                                    info=await player._output.refresh()
                                    self.assertEqual(info.metrics.dropped_frames,0)
                                    self.assertGreater(info.metrics.device_frames_rendered,0)
                                self.assertEqual(player.diagnostics['output_sessions'],1)
                            finally:
                                await player.close();reading.cancel()
                                await asyncio.gather(reading,return_exceptions=True)
                finally:
                    runtime.terminate()
                    await asyncio.to_thread(runtime.wait,5)
