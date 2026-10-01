from pathlib import Path
import subprocess,json,tempfile,os
root=Path(__file__).resolve().parents[3]; out=root/'Tests/Reports/voice-production/2026-10-01-p3-06a'
tmp=Path(tempfile.mkdtemp(prefix='nextnotes-p3-final-'))
os.chdir(root)
rows=[]
def run(name,args,expected=0):
 p=subprocess.run(['Scripts/run-selftest.sh','-ApplePersistenceIgnoreState','YES','-NSQuitAlwaysKeepsWindows','NO',*args],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
 (out/(name+'.txt')).write_text(p.stdout)
 rows.append({'name':name,'exit':p.returncode,'expected':expected})
 print(name,p.returncode,flush=True)
 (out/'wake-isolated-summary.json').write_text(json.dumps({'temporaryTraceDirectory':str(tmp),'runs':rows},indent=2)+'\n')
 if p.returncode!=expected: raise SystemExit('unexpected exit: '+name)
run('wake-isolated-recorded',['--selftest-voice-session-reducer','--record-voice-trace',str(tmp/'recorded.jsonl')])
run('wake-isolated-replay',['--selftest-voice-session-reducer',str(tmp/'recorded.jsonl')])
run('wake-isolated-missing',['--selftest-voice-session-reducer',str(tmp/'missing.jsonl')],1)
(tmp/'empty.jsonl').write_text('')
run('wake-isolated-empty',['--selftest-voice-session-reducer',str(tmp/'empty.jsonl')],1)
frames=[json.loads(x) for x in (tmp/'recorded.jsonl').read_text().splitlines()]
for name,changed in [('negative',[dict(frames[0],at=-1)]),('backwards',[dict(frames[0],at=2),dict(frames[1],at=1)])]:
 (tmp/(name+'.jsonl')).write_text(''.join(json.dumps(x)+'\n' for x in changed))
 run('wake-isolated-'+name,['--selftest-voice-session-reducer',str(tmp/(name+'.jsonl'))],1)
refusal=Path.home()/'Library/Application Support/NextNotesP3TraceRefusal-final.jsonl'
assert not refusal.exists()
run('wake-isolated-refusal',['--selftest-voice-session-reducer','--record-voice-trace',str(refusal)],1)
assert not refusal.exists()
for name in ['concurrent-voice','voice-work-lifecycle','voice-duplex-work','voice-conversation','voice-turn-routing','task-durability','voice-turns','voice-delivery','realtime']:
 run('wake-isolated-'+name,['--selftest-'+name])
