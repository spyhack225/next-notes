#!/usr/bin/env python3
"""Paced reference ASR load for a coordinated TTS output experiment.

Uses the existing native v3 RPC probe and authored paced-ASR harness. This is
concurrent decoder load, not the app microphone/AEC/endpoint integration test.
No download, owner preferences, transcript store or effects. Original caches
are copied with APFS CoW and verified unchanged after native process exit.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

import asr_live
from tts_compare import save, stop_process_group


def hashes(root):
    return {str(p.relative_to(root)): hashlib.file_digest(p.open('rb'), 'sha256').hexdigest()
            for p in root.rglob('*') if p.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    marker = args.output/'ready.json'
    if marker.exists():
        parser.error('Use a fresh evidence directory')
    owner = Path.home()/'Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3'
    required = ['Encoder.mlmodelc','Preprocessor.mlmodelc','Decoder.mlmodelc','JointDecisionv3.mlmodelc','parakeet_v3_vocab.json']
    if not all((owner/p).exists() for p in required):
        parser.error('Installed reference ASR unavailable; no download will occur')
    before = hashes(owner)
    child = None
    began = time.monotonic()
    receipt = {'schema':'nextnotes.tts-reference-asr-load.v1',
               'scope':'Cached native Parakeet v3; authored English prefixes at 400ms then one-second updates. Concurrent decoder load, not production mic/EOU/full-duplex acceptance.',
               'startedMonotonic':began, 'probeSHA256':hashlib.sha256(args.probe.read_bytes()).hexdigest(),
               'ownerSHA256Before':before}
    # Share the existing ASR diagnostic lock; TTS's heavy claim admits this
    # declared workload, while another independent ASR benchmark cannot start.
    lockpath = Path.home()/'Library/Caches/NextNotesASRBench/serial.lock'
    lockpath.parent.mkdir(parents=True, exist_ok=True)
    with lockpath.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        root = Path(tempfile.mkdtemp(prefix="nextnotes-tts-asr-load-"))
        clone = root/'reference-model'
        command = [str(args.probe.resolve()),str(clone),str(clone/'parakeet_v3_vocab.json'),str(root/'unused.json'),'unused.wav']
        receipt['command'] = command
        try:
            subprocess.run(['/bin/cp','-cRL',str(owner),str(clone)],check=True)
            child = subprocess.Popen(command, env={**os.environ,'ASR_LIVE':'1','TMPDIR':str(root)+'/'},
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            original_measure = asr_live.measure
            def workload(infer, languages):
                audio, _, _ = asr_live.fixture('en')
                infer(audio[:6400], 'en', False)
                infer(audio, 'en', True)
                count = 0
                def observed(audio, language, final):
                    nonlocal count
                    value = infer(audio,language,final)
                    count += 1
                    save(marker, {'active':True,'workerPID':child.pid,'lastResponseMonotonic':time.monotonic(),
                                  'responses':count,'scope':receipt['scope']}, durable=False)
                    return value
                # Reuse the actual paced/coalescing harness; a planned SIGINT
                # ends the long workload after all serial TTS children finish.
                return original_measure(observed, ('en',), trials=400)
            asr_live.measure = workload
            asr_live.rpc_driver(child,args.output/'rpc.json',languages=('en',))
            receipt['status'] = 'completed-workload'
        except KeyboardInterrupt:
            receipt['status'] = 'planned-stop-after-TTS'
        except BaseException as error:
            receipt.update(status='failed',reason=str(error))
        finally:
            asr_live.measure = original_measure if 'original_measure' in locals() else asr_live.measure
            if child is not None:
                stop_process_group(child)
                if child.stdin is not None: child.stdin.close()
                child.stdout.close(); child.stderr.close()
            # Publish inactive only after native process exit. TemporaryDirectory
            # then removes the sole reference-model snapshot.
            save(marker, {'active':False,'endedMonotonic':time.monotonic(),'status':receipt.get('status')}, durable=False)
            receipt.update(childJoined=child is None or child.poll() is not None,
                           elapsedSeconds=time.monotonic()-began,
                           ownerArtifactsUnchanged=before == hashes(owner))
            save(args.output/'receipt.json',receipt)
        # A failed save retains this one owned snapshot instead of deleting
        # the only recoverable evidence; no subsequent TTS model may start.
        shutil.rmtree(root)
    receipt['temporaryAssetsDeleted'] = not root.exists()
    save(args.output/'receipt.json',receipt)
    print(json.dumps({k:v for k,v in receipt.items() if k not in ('ownerSHA256Before','command')}),flush=True)
    return 0 if receipt.get('status') != 'failed' and receipt['ownerArtifactsUnchanged'] and receipt['temporaryAssetsDeleted'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
