from pathlib import Path
import subprocess, tempfile, os, json, re, hashlib, shutil
root=Path(__file__).resolve().parents[4]
report=Path(__file__).resolve().parent
scratch=Path.home()/'Library/Caches/NextNotesBuild/wt-scratch/no-apple'
work=Path(tempfile.mkdtemp(prefix='NextNotes-no-apple-round4-'))
results=[]
def run(name,args,expected=None):
    log=report/(name+'.log')
    with log.open('w') as out:
        try: p=subprocess.run(args,cwd=root,stdout=out,stderr=subprocess.STDOUT,timeout=900)
        except subprocess.TimeoutExpired:
            results.append(dict(name=name,exit='timeout')); save();return False
    text=log.read_text(errors='replace')
    outfile=work/(name+'.log')
    if outfile.exists():
        native_text=outfile.read_text(errors='replace');(report/(name+'-selftest.log')).write_text(native_text)
        text=native_text+'\n'+text # retain the CLI root marker as well as diagnostics
    markers=[x for x in text.splitlines() if re.match(r'^[A-Z][A-Z0-9_]*_(?:OK|FAILED|ABSENT)(?::|$)',x)]
    roots=[x for x in markers if expected is None or x.startswith(expected+'_')]
    item=dict(name=name,exit=p.returncode,marker=roots[-1] if roots else 'NO_FINAL_MARKER',expected=expected)
    results.append(item);save();print(json.dumps(item),flush=True)
    return p.returncode==0 and (expected is None or bool(roots) and roots[-1].startswith(expected+'_OK'))

def save(): (report/'checks.json').write_text(json.dumps(results,indent=2)+'\n')
def build(name):
    return run(name,['swift','build','-c','debug','-j','2','--scratch-path',str(scratch)])
def check(name,flag,args=[]):
    expected='VOICE_POLICY_REVIEW' if '--voice-policy-review' in args else {'tts-stream':'TTS_TOKEN_STREAM'}.get(flag,flag.upper().replace('-','_'))
    return run(name,[str(scratch/'debug/NextNotes'),'--selftest-'+flag,*args,'--selftest-out',str(work/(name+'.log'))],expected)
try:
    run('webrtc-build',['make','webrtc-audio'])
    if not build('red-build'):raise SystemExit(1)
    binary=scratch/'debug/NextNotes'
    def pin(name):
        (report/(name+'.json')).write_text(json.dumps(dict(sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),diff=subprocess.check_output(['git','diff','--stat'],cwd=root,text=True),sources={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (root/'Sources').rglob('*') if p.is_file()}),indent=2)+'\n')
    (report/'red-source.patch').write_text(subprocess.check_output(['git','diff'],cwd=root,text=True))
    pin('red-pin'); check('producer-red','tts',['--voice-policy-review'])
    red=results[-1]
    if red['exit'] != 1 or not red['marker'].startswith('VOICE_POLICY_REVIEW_FAILED'):raise SystemExit('original regression did not fail')
    if not run('apply-fix',['python3',str(report/'apply-fix.py')]):raise SystemExit(1)
    if not build('green-build'):raise SystemExit(1)
    (report/'green-source.patch').write_text(subprocess.check_output(['git','diff'],cwd=root,text=True))
    pin('green-pin'); check('producer-green','tts',['--voice-policy-review'])
    for flag in ['tts','tts-stream','voice-conversation','voice-delivery','voice-scheduling','duplex','concurrent-voice','voice-turn-routing','catch-up','settings','ui-strings','store-isolation','voice-playback-projection','voice-playback-resume-receipt','apple-resume-owner','apple-playback-timeline','task-authority','residency','scheduler']:
        check(flag,flag)
    print('NO_APPLE_ROUND4_BATCH_FINISHED',flush=True)
    raise SystemExit(1 if any(x['exit']!=0 or x.get('expected') and not x['marker'].startswith(x['expected']+'_OK') for x in results if x['name']!='producer-red') else 0)
finally: shutil.rmtree(work)
