#!/usr/bin/env python3
import hashlib,json,shutil
from pathlib import Path
r=Path('Tests/Reports/voice-ack');log=(r/'cleaned-resume-red.log').read_text()
assert 'VOICE_ACK_CHECKS=39 failures=0' in log
shutil.copyfile(r/'native-artifact-pins.json',r/'cleaned-resume-original-artifact-pins.json')
(r/'cleaned-resume-original-source-pins.json').write_text(json.dumps(json.loads((r/'native-artifact-pins.json').read_text())['source_sha256'],indent=2)+'\n')
if 'VOICE_ACK_CACHE_CHECKS=38 failures=0' in log and log.rstrip().endswith('VOICE_ACK_OK'):
    (r/'cleaned-resume-decision.json').write_text(json.dumps({'decision':'original actual cleaned-level producer already passes; no correction'},indent=2)+'\n')
    raise SystemExit(0)
assert 'VOICE_ACK_CACHE_CHECKS=38 failures=1' in log
assert 'VOICE_ACK_WRONG: cleaned input cancels courtesy without near-candidate gate' in log
assert log.rstrip().endswith('VOICE_ACK_FAILED')
p=Path('Sources/NextNotes/Activation/AgentCaptureController.swift');s=p.read_text()
old='''        if level >= Limits.speechLevel,
           !VoiceAcknowledgement.shared.isPlaying || nearCandidate {
            VoiceAcknowledgement.shared.cancel()
        }'''
new='''        if level >= Limits.speechLevel {
            VoiceAcknowledgement.shared.cancel()
        }'''
assert s.count(old)==1
p.write_text(s.replace(old,new,1))
(r/'cleaned-resume-decision.json').write_text(json.dumps({'decision':'exact actual cleaned-level RED1; remove courtesy-only near-candidate gate'},indent=2)+'\n')
p=r/'green-source-before.json';d=json.loads(p.read_text());p.write_text(json.dumps({k:hashlib.sha256(Path(k).read_bytes()).hexdigest() for k in d},indent=2)+'\n')
