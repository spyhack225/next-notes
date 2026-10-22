#!/usr/bin/env python3
"""Same pinned scorer as bakeoff2, with an owned debug executable."""
import importlib.util,json,os,shlex,subprocess,sys,hashlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('pinned',ROOT/'Scripts/pinned-quick.py');pinned=importlib.util.module_from_spec(spec);spec.loader.exec_module(pinned)
model,label,index,size=sys.argv[1:];out=HERE/label/('run'+index);out.mkdir(parents=True,exist_ok=False)
binary=Path('/Users/sergekadjo/Library/Caches/NextNotesBuild/wt-scratch/bakeoff3/debug/NextNotes')
identity=pinned.binary_identity(binary);sha=hashlib.sha256(binary.read_bytes()).hexdigest()
now='2026-10-05T09:00:00-04:00';report=out/'report.md'
command=[str(binary),'--selftest-toolloop-live','--quick','--model',model,'--fixture-now',now,'--report',str(report),'--selftest-timeout','1800','--selftest-out',str(out/'native.log')]
supervisor=['python3',str(HERE/'run-admitted.py'),str(out),size,*command]
notice=subprocess.run(['agent-relay','send','--as','claude2-bakeoff3','--to','meeting-performance-20261007','--project','/Users/sergekadjo/Documents/Claude/Projects/speechify','--message',f'bakeoff3 queueing {label} text quick {index}/3 via heavy.sh; owned debug binary, no voice/install, resource guards unchanged.'],capture_output=True,text=True)
(out/'notice.json').write_text(notice.stdout+notice.stderr)
if notice.returncode or json.loads(notice.stdout).get('ok') is not True:sys.exit('Notice failed; not queued')
env=dict(os.environ,RELAY_ID='claude2-bakeoff3',TZ='America/New_York')
with (out/'wrapper.log').open('w') as log:
 proc=subprocess.Popen([str(ROOT.parent/'heavy.sh'),shlex.join(supervisor)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=env)
 for line in proc.stdout:log.write(line);log.flush();print(line,end='',flush=True)
 code=proc.wait()
result=dict(modelPin=model,fixtureNow=now,wrapperExit=code,command=command,binary=str(binary),binarySHA256=sha,binaryIdentityBefore=identity,binaryUnchanged=identity==pinned.binary_identity(binary) and sha==hashlib.sha256(binary.read_bytes()).hexdigest())
try:
 if not result['binaryUnchanged']:raise RuntimeError('Debug binary changed')
 score,resolved,zone=pinned.read_score(report,(out/'wrapper.log').read_text(),code,model,now)
 result.update(score=score,resolvedModel=resolved,timezone=zone)
except (OSError,RuntimeError,ValueError) as error:result['unscoredReason']=str(error)
(out/'result.json').write_text(json.dumps(result,indent=2)+'\n');print('BAKEOFF_RESULT: '+json.dumps(result),flush=True)
sys.exit(0 if 'score' in result else 75)
