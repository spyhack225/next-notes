#!/usr/bin/env python3
"""Existing app floor diagnostic, C0 text only; no speed-floor promotion."""
import hashlib,json,os,shlex,subprocess,sys
from pathlib import Path
root=Path(__file__).resolve().parents[2]
model,label,size=sys.argv[1:]
out=root/'evidence/2026-10-09'/label/'speed';out.mkdir(parents=True,exist_ok=False)
app=Path('/Users/sergekadjo/Library/Caches/NextNotesBuild/bakeoff-app/NextNotes-503e0e40.app');binary=app/'Contents/MacOS/NextNotes'
digest=hashlib.sha256(binary.read_bytes()).hexdigest()
command=[str(root/'Scripts/run-selftest.sh'),'--selftest-llm-metal','--floor','--floor-model',model,'--floor-runs','10','--selftest-timeout','1800']
notice=subprocess.run(['agent-relay','send','--as','claude2-bakeoff2','--to','meeting-performance-20261007','--project','/Users/sergekadjo/Documents/Claude/Projects/speechify','--message',f'bakeoff2 notice: queueing {label} existing C0 text-only floor/decode256 diagnostic via FIFO heavy.sh; no voice/ASR.'],capture_output=True,text=True)
(out/'notice.json').write_text(notice.stdout+notice.stderr)
if notice.returncode or json.loads(notice.stdout).get('ok') is not True:sys.exit('Notice not persisted')
env=dict(os.environ,NEXTNOTES_APP=str(app),RELAY_ID='claude2-bakeoff2',TZ='America/New_York')
supervisor=['python3',str(root/'evidence/2026-10-09/run-admitted.py'),str(out),size,*command]
with (out/'wrapper.log').open('w') as log:
 p=subprocess.Popen([str(root.parent/'heavy.sh'),shlex.join(supervisor)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=env)
 for line in p.stdout:log.write(line);log.flush();print(line,end='',flush=True)
 code=p.wait()
same=digest==hashlib.sha256(binary.read_bytes()).hexdigest()
result={'modelPin':model,'app':str(app),'sha256':digest,'binaryUnchanged':same,'wrapperExit':code,'command':command}
(out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print('SPEED_RESULT: '+json.dumps(result),flush=True)
sys.exit(0 if code==0 and same else 75)
