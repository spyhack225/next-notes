from pathlib import Path
import subprocess,os,re,json,tempfile,hashlib,shutil
root=Path(__file__).resolve().parents[3]
report=Path(__file__).resolve().parent
scratch=Path.home()/'Library/Caches/NextNotesBuild/wt-scratch/voice'
work=Path(tempfile.mkdtemp(prefix='NextNotes-no-apple-'))
results=[]
def run(name,args,timeout=None,expected=0):
    print('START '+name,flush=True)
    with (report/(name+'.log')).open('w') as log:
        try: proc=subprocess.run(args,cwd=root,stdout=log,stderr=subprocess.STDOUT,timeout=timeout)
        except subprocess.TimeoutExpired:
            results.append({'check':name,'exit':'timeout','marker':'UNFINISHED'});save();return False
    content=(report/(name+'.log')).read_text(errors='replace')
    markers=[line for line in content.splitlines() if re.search(r'(?:_OK|_FAILED|_ABSENT)(?::|$)',line)]
    results.append({'check':name,'exit':proc.returncode,'marker':markers[-1] if markers else 'NO_FINAL_MARKER'})
    print(json.dumps(results[-1]),flush=True);save()
    return proc.returncode==expected

def save(): (report/'checks.json').write_text(json.dumps(results,indent=2)+'\n')
try:
    if not run('producer-original-compile',['swiftc','-parse-as-library',str(report/'original-probe.swift'),'-o',str(work/'original')]):raise SystemExit(1)
    if not run('producer-red',[str(work/'original')],expected=1):raise SystemExit(1)
    if not run('producer-fixed-compile',['swiftc','-parse-as-library',str(report/'fixed-probe.swift'),'-o',str(work/'fixed')]):raise SystemExit(1)
    if not run('producer-green',[str(work/'fixed')]):raise SystemExit(1)
    if not run('webrtc-build',['make','webrtc-audio']):raise SystemExit(1)
    if not run('app-build',['swift','build','-c','debug','-j','2','--scratch-path',str(scratch)]):raise SystemExit(1)
    binary=scratch/'debug/NextNotes'
    (report/'binary-pin.json').write_text(json.dumps({'sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'size':binary.stat().st_size,'source':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()},indent=2)+'\n')
    flags=['tts','tts-stream','voice-conversation','voice-delivery','voice-scheduling','duplex','concurrent-voice','voice-turn-routing','catch-up','settings','ui-strings','store-isolation','voice-playback-projection','voice-playback-resume-receipt','apple-resume-owner','apple-playback-timeline']
    for flag in flags:
        outfile=work/(flag+'.log')
        okay=run(flag,[str(binary),'--selftest-'+flag,'--selftest-out',str(outfile)],timeout=300)
        if outfile.exists():
            full=outfile.read_text(errors='replace')
            (report/(flag+'-selftest.log')).write_text(full)
            markers=[line for line in full.splitlines() if re.search(r'(?:_OK|_FAILED|_ABSENT)(?::|$)',line)]
            if markers:results[-1]['marker']=markers[-1];save();print(results[-1]['marker'],flush=True)
    print('NO_APPLE_CHECK_BATCH_FINISHED',flush=True)
finally:
    shutil.rmtree(work)
