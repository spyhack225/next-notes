from pathlib import Path
import hashlib, json, re, shutil, subprocess, tempfile
root = Path(__file__).resolve().parents[4]
report = Path(__file__).resolve().parent
manifest=json.loads((report/'build93-source-manifest.json').read_text())
bundle=Path('/Applications/Next Notes.app')
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
expected=json.loads((report/'app93-bundle-after.json').read_text())
def verify():
    assert not [p for p,h in manifest.items() if sha(root/p)!=h]
    assert {str(p.relative_to(bundle)):sha(p) for p in sorted(bundle.rglob('*')) if p.is_file()}==expected
out=Path(tempfile.mkdtemp(prefix='nextnotes-playback-extra-93-'))
trace=out/'native-trace.jsonl'
cases=[('latency-instrumentation',['--selftest-voice-latency','--voice-latency-instrumentation'],0,'VOICE_LATENCY_OK'),
       ('latency-file-gate',['--selftest-voice-latency'],1,'VOICE_LATENCY_ABSENT'),
       ('projection-recorded',['--selftest-voice-playback-projection','--record-voice-trace',str(trace)],0,'VOICE_PLAYBACK_PROJECTION_OK'),
       ('reducer-native-replay',['--selftest-voice-session-reducer',str(trace)],0,'VOICE_SESSION_REDUCER_OK')]
records=[]
for name,args,expected_exit,prefix in cases:
    verify();app_log=out/(name+'.log');stdout=report/('app93-'+name+'.stdout')
    with stdout.open('w') as stream:
        result=subprocess.run([str(root/'Scripts/run-selftest.sh'),'--out',str(app_log),*args],cwd=root,stdout=stream,stderr=subprocess.STDOUT,timeout=240)
    if app_log.exists():shutil.copy2(app_log,report/('app93-'+name+'.log'))
    text=app_log.read_text() if app_log.exists() else stdout.read_text()
    matches=re.findall(r'^[A-Z][A-Z0-9_]*_(?:OK|FAILED|ABSENT)[^\n]*',text,re.M)
    marker=matches[-1] if matches else 'MISSING'
    verify()
    record={'name':name,'args':args,'exit':result.returncode,'marker':marker,'sourceDrift':[],'sameBundle':True,'acceptance':'UNAVAILABLE' if prefix.endswith('ABSENT') else 'PASS'}
    records.append(record);(report/'app93-extra-checks.json').write_text(json.dumps(records,indent=2)+'\n')
    print(record,flush=True)
    assert result.returncode==expected_exit and marker.startswith(prefix), record
if trace.exists():shutil.copy2(trace,report/'app93-native-trace.jsonl')
