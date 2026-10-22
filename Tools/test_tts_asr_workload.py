"""Actual process/owned-file lifecycle with a fake RPC worker; no ML models."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

class WorkloadLifecycle(unittest.TestCase):
    def test_planned_stop_joins_native_worker_before_snapshot_cleanup(self):
        with tempfile.TemporaryDirectory(prefix='tts-asr-workload-test-') as directory:
            root = Path(directory)
            model = root/'Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3'
            model.mkdir(parents=True)
            for name in ['Encoder.mlmodelc','Preprocessor.mlmodelc','Decoder.mlmodelc','JointDecisionv3.mlmodelc','parakeet_v3_vocab.json']:
                (model/name).write_text('fixture preserved')
            before = {p.name:p.read_bytes() for p in model.iterdir()}
            fake = root/'fake-rpc'
            fake.write_text('''#!/usr/bin/env python3
import json,sys
print('ASR_RPC '+json.dumps({'ready':True,'native_peak_rss_bytes':1}),flush=True)
for line in sys.stdin:
 print('ASR_RPC '+json.dumps({'text':'Hello world','native_peak_rss_bytes':1}),flush=True)
''')
            fake.chmod(0o700)
            output = root/'evidence'
            child = subprocess.Popen([sys.executable,str(Path(__file__).with_name('tts_asr_workload.py')),
                '--probe',str(fake),'--output',str(output)], env={**os.environ,'HOME':str(root),'TMPDIR':str(root)+'/'},
                stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
            native_pid = None
            try:
                deadline = time.monotonic()+10
                while time.monotonic()<deadline and child.poll() is None:
                    if (output/'ready.json').exists():
                        ready = json.loads((output/'ready.json').read_text())
                        if ready.get('active'):
                            native_pid = ready['workerPID'];break
                    time.sleep(.05)
                self.assertIsNotNone(native_pid)
                os.kill(child.pid,signal.SIGINT)
                stdout,stderr = child.communicate(timeout=12)
                self.assertEqual(child.returncode,0,stderr.decode())
                receipt = json.loads((output/'receipt.json').read_text())
                self.assertTrue(receipt['childJoined'])
                self.assertTrue(receipt['temporaryAssetsDeleted'])
                self.assertTrue(receipt['ownerArtifactsUnchanged'])
                self.assertEqual(receipt['status'],'planned-stop-after-TTS')
                self.assertFalse(json.loads((output/'ready.json').read_text())['active'])
                with self.assertRaises(ProcessLookupError):os.kill(native_pid,0)
                self.assertFalse(list(root.glob('nextnotes-tts-asr-load-*')))
                self.assertEqual(before,{p.name:p.read_bytes() for p in model.iterdir()})
            finally:
                if child.poll() is None:
                    os.kill(child.pid,signal.SIGINT)
                    try:child.communicate(timeout=12)
                    except subprocess.TimeoutExpired:
                        child.kill();child.communicate()
                child.stdout.close();child.stderr.close()

if __name__=='__main__':unittest.main()
