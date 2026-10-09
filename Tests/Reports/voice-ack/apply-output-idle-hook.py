#!/usr/bin/env python3
# Only invoked in our admitted wrapper slot AFTER the unchanged gap fixture fails.
import hashlib,json,shutil
from pathlib import Path
report=Path('Tests/Reports/voice-ack')
log=(report/'output-idle-red.log').read_text()
assert 'VOICE_ACK_CHECKS=39 failures=0' in log, 'original controls must first be GREEN'
assert 'VOICE_ACK_WRONG: natural output completion restarts actual idle clip producer' in log
assert log.rstrip().endswith('VOICE_ACK_FAILED'), 'require actual failing root marker'
shutil.copyfile(report/'native-artifact-pins.json',report/'output-idle-original-artifact-pins.json')
shutil.copyfile(report/'green-source-before.json',report/'output-idle-original-source-pins.json')
p=Path('Sources/NextNotes/Agent/Speech/AgentSpeechSynthesizer.swift')
s=p.read_text()
old='''        advanceQueue()
        onVoiceLifecycleSettled?()
    }

    /// Self-test seam'''
new='''        advanceQueue()
        onVoiceLifecycleSettled?()
        // Output is not Observable. Retry optional idle clips only after the
        // existing completion path has released the same speech owner.
        VoiceAcknowledgement.shared.prewarm()
    }

    /// Self-test seam'''
assert s.count(old)==1, 'require exact original native completion producer'
p.write_text(s.replace(old,new,1))
p=report/'green-source-before.json';d=json.loads(p.read_text());p.write_text(json.dumps({k:hashlib.sha256(Path(k).read_bytes()).hexdigest() for k in d},indent=2)+'\n')
