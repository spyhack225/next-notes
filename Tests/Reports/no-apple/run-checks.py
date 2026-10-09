from pathlib import Path
import subprocess,os,re,json,tempfile,hashlib,shutil,sys
root=Path(__file__).resolve().parents[3]
report=Path(__file__).resolve().parent
scratch=Path.home()/'Library/Caches/NextNotesBuild/wt-scratch/voice'
work=Path(tempfile.mkdtemp(prefix='NextNotes-no-apple-'))
results=[]
control=work/'control'
os.mkfifo(control)
print('SLOT_CONTROL '+str(control),flush=True)
attempts={}
def command():
    print('WAITING_FOR_SLOT_COMMAND '+str(control),flush=True)
    with control.open() as channel:return channel.readline().strip()
def checked(name,args,expected=0):
    okay=run(name,args,expected=expected)
    while not okay:
        # Explicit agent repair/retry in this SAME slot, never an automatic retry.
        if command()!='retry':raise SystemExit(1)
        okay=run(name,args,expected=expected)
    return True

def run(name,args,timeout=None,expected=0):
    print('START '+name,flush=True)
    attempts[name]=attempts.get(name,0)+1
    logfile=report/(name+('-attempt-'+str(attempts[name]) if attempts[name]>1 else '')+'.log')
    with logfile.open('w') as log:
        try: proc=subprocess.run(args,cwd=root,stdout=log,stderr=subprocess.STDOUT,timeout=timeout)
        except subprocess.TimeoutExpired:
            results.append({'check':name,'exit':'timeout','marker':'UNFINISHED'});save();return False
    content=logfile.read_text(errors='replace')
    markers=[line for line in content.splitlines() if re.search(r'(?:_OK|_FAILED|_ABSENT)(?::|$)',line)]
    results.append({'check':name,'attempt':attempts[name],'log':logfile.name,'exit':proc.returncode,'expected_exit':expected,'marker':markers[-1] if markers else 'NO_FINAL_MARKER'})
    print(json.dumps(results[-1]),flush=True);save()
    return proc.returncode==expected

def save(): (report/'checks.json').write_text(json.dumps(results,indent=2)+'\n')
try:
    if not checked('producer-original-compile',['swiftc','-parse-as-library',str(report/'original-probe.swift'),'-o',str(work/'original')]):raise SystemExit(1)
    if not checked('producer-red',[str(work/'original')],expected=1):raise SystemExit(1)
    if not checked('producer-fixed-compile',['swiftc','-parse-as-library',str(report/'fixed-probe.swift'),'-o',str(work/'fixed')]):raise SystemExit(1)
    if not checked('producer-green',[str(work/'fixed')]):raise SystemExit(1)
    if not checked('webrtc-build',['make','webrtc-audio']):raise SystemExit(1)
    if not checked('app-build',['swift','build','-c','debug','-j','2','--scratch-path',str(scratch)]):raise SystemExit(1)
    binary=scratch/'debug/NextNotes'
    (report/'binary-pin.json').write_text(json.dumps({'sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'size':binary.stat().st_size,'source':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()},indent=2)+'\n')
    flags=['tts','tts-stream','voice-conversation','voice-delivery','voice-scheduling','duplex','concurrent-voice','voice-turn-routing','catch-up','settings','ui-strings','store-isolation','voice-playback-projection','voice-playback-resume-receipt','apple-resume-owner','apple-playback-timeline']
    def native_checks(selected):
        for flag in selected:
            outfile=work/(flag+'.log')
            okay=run(flag,[str(binary),'--selftest-'+flag,'--selftest-out',str(outfile)],timeout=300)
            if outfile.exists():
                full=outfile.read_text(errors='replace')
                nativefile=report/(flag+'-selftest'+('-attempt-'+str(attempts[flag]) if attempts[flag]>1 else '')+'.log')
                nativefile.write_text(full)
                markers=[line for line in full.splitlines() if re.search(r'(?:_OK|_FAILED|_ABSENT)(?::|$)',line)]
                if markers:results[-1]['marker']=markers[-1];save();print(results[-1]['marker'],flush=True)
    native_checks(flags)
    print('NO_APPLE_CHECK_BATCH_FINISHED',flush=True)
    while True:
        instruction=command()
        if instruction=='finish':break
        if instruction.startswith('rebuild '):
            checked('app-build',['swift','build','-c','debug','-j','2','--scratch-path',str(scratch)])
            revision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
            pin={'sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'size':binary.stat().st_size,'source':revision}
            (report/('binary-pin-attempt-'+str(attempts['app-build'])+'.json')).write_text(json.dumps(pin,indent=2)+'\n')
            native_checks(flags if instruction=='rebuild all' else instruction.removeprefix('rebuild ').split(','))
        elif instruction.startswith('recheck '):
            native_checks(instruction.removeprefix('recheck ').split(','))
    last={item['check']:item for item in results}
    raise SystemExit(0 if all(item['exit']==item.get('expected_exit',0) for item in last.values()) else 1)
finally:
    shutil.rmtree(work)
