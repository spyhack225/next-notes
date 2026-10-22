from pathlib import Path
import subprocess,tempfile,json,hashlib,shutil,re,os,time
root=Path(__file__).resolve().parents[4]
report=Path(__file__).resolve().parent
scratch=Path.home()/'Library/Caches/NextNotesBuild/wt-scratch/voice-ack'
work=Path(tempfile.mkdtemp(prefix='NextNotes-voice-ack-round2-'))
results=[]
(report/'batch-start.json').write_text(json.dumps(dict(utc=time.time(),pid=os.getpid()))+'\n')
original=json.loads((report/'original-producers.json').read_text())
fixed={p:(root/p).read_text() for p in original}
(report/'fixed-producers.json').write_text(json.dumps(fixed,indent=2)+'\n')
fixture=root/'Tests/Reports/voice-ack/round2/haiku16k.wav'
source_fixture=Path.home()/'Library/Caches/NextNotesBuild/integration/listen-acceptance/fixtures/haiku16k.wav'
shutil.copyfile(source_fixture,fixture)
def save(): (report/'checks.json').write_text(json.dumps(results,indent=2)+'\n')
def run(name,args,expected=None):
    before=time.time(); log=report/(name+'.log')
    with log.open('w') as out:
        try: p=subprocess.run(args,cwd=root,stdout=out,stderr=subprocess.STDOUT,timeout=1800)
        except subprocess.TimeoutExpired:
            results.append(dict(name=name,exit='timeout'));save();return False
    text=log.read_text(errors='replace'); native=work/(name+'.log')
    if native.exists():
        nt=native.read_text(errors='replace');(report/(name+'-selftest.log')).write_text(nt);text=nt+'\n'+text
    markers=[x for x in text.splitlines() if re.match(r'^[A-Z][A-Z0-9_]*_(?:OK|FAILED|ABSENT)(?::|$)',x)]
    roots=[x for x in markers if expected is None or x.startswith(expected+'_')]
    item=dict(name=name,exit=p.returncode,marker=roots[-1] if roots else 'NO_FINAL_MARKER',expected=expected,elapsed=time.time()-before)
    results.append(item);save();print(json.dumps(item),flush=True)
    return p.returncode==0 and (expected is None or bool(roots) and roots[-1].startswith(expected+'_OK'))
def build(name):return run(name,['swift','build','-c','release','-j','2','--scratch-path',str(scratch)])
def check(name,flag,args=[],expected=None):
    expected=expected or {'tts-stream':'TTS_TOKEN_STREAM'}.get(flag,flag.upper().replace('-','_'))
    return run(name,[str(scratch/'release/NextNotes'),'--selftest-'+flag,*args,'--selftest-out',str(work/(name+'.log'))],expected)
def pin(name):
    (report/(name+'-pin.json')).write_text(json.dumps(dict(binary_sha256=hashlib.sha256((scratch/'release/NextNotes').read_bytes()).hexdigest(),head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),sources={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (root/'Sources').rglob('*') if p.is_file()},fixture_sha256=hashlib.sha256(fixture.read_bytes()).hexdigest()),indent=2)+'\n')
try:
    if not run('webrtc-build',['make','webrtc-audio']):raise SystemExit(1)
    for p,s in original.items(): (root/p).write_text(s)
    if not build('red-build'): raise SystemExit(1)
    pin('red');check('review-red','voice-latency',['--voice-latency-ack-policy'],expected='VOICE_ACK')
    red=results[-1]
    check('census-red','voice-latency',['--voice-latency-fixture',str(fixture),'--voice-latency-ack-census'])
    if red['exit']!=1 or red['marker']!='VOICE_ACK_FAILED':raise SystemExit('original fixture did not fail')
    for p,s in fixed.items(): (root/p).write_text(s)
    if not build('green-build'):raise SystemExit(1)
    pin('green'); check('review-green','voice-latency',['--voice-latency-ack-policy'],expected='VOICE_ACK')
    check('census-green','voice-latency',['--voice-latency-fixture',str(fixture),'--voice-latency-ack-census'])
    check('instrumentation','voice-latency',['--voice-latency-instrumentation'])
    check('first-token-contract','voice-latency',['--voice-latency-first-token-contract'])
    check('no-apple-review','tts',['--voice-policy-review'],expected='VOICE_POLICY_REVIEW')
    for flag in ['voice-turn-routing','concurrent-voice','voice-conversation','duplex','voice-scheduling','tts','store-isolation']:
        check(flag,flag)
    for name,extra in [('before-no-ack',['--voice-no-ack']),('after-ack',[])]:
        check(name,'voice-latency',['--voice-latency-fixture',str(fixture),'--voice-latency-runs','5',*extra])
    check('voice-pipeline','voice-pipeline',[str(fixture)])
    pin('final')
    raise SystemExit(1 if any(x['exit']!=0 or x.get('expected') and not x['marker'].startswith(x['expected']+'_OK') for x in results if x['name'] not in ['review-red','census-red']) else 0)
finally:
    for p,s in fixed.items(): (root/p).write_text(s)
    shutil.rmtree(work)
    (report/'batch-finished.json').write_text(json.dumps(dict(utc=time.time(),pid=os.getpid()))+'\n')
