from pathlib import Path
import hashlib,json,subprocess
root=Path(__file__).resolve().parents[5];report=Path(__file__).resolve().parent
proof=root/'Tests/Reports/agent-overhaul-closure/voice-playback-projection-prerequisite/resume'
manifest=json.loads((proof/'build95-source-manifest.json').read_text());bundle=Path('/Applications/Next Notes.app')
expected=json.loads((proof/'app95-bundle-after.json').read_text());sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
scripts={name:sha(root/name) for name in ('Scripts/acceptance.sh','Scripts/run-selftest.sh')}
def verify():
    assert not [p for p,h in manifest.items() if sha(root/p)!=h]
    assert {str(p.relative_to(bundle)):sha(p) for p in sorted(bundle.rglob('*')) if p.is_file()}==expected
    assert all(sha(root/p)==h for p,h in scripts.items())
verify()
with (report/'app95-core.stdout').open('w') as stream:
    result=subprocess.run(['make','acceptance','TIER=core'],cwd=root,stdout=stream,stderr=subprocess.STDOUT,timeout=7200)
verify()
record={'exit':result.returncode,'sourceDrift':[],'sameBundle':True,'scripts':scripts,'verdict':'PASS' if result.returncode==0 else 'OPEN'}
(report/'app95-core-gate.json').write_text(json.dumps(record,indent=2)+'\n');print(record,flush=True)
