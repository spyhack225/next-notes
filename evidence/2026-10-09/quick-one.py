#!/usr/bin/env python3
import importlib.util, json, os, shlex, subprocess, sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('pinned',ROOT/'Scripts/pinned-quick.py'); pinned=importlib.util.module_from_spec(spec);spec.loader.exec_module(pinned)
model,label,index,large=sys.argv[1:]; output=ROOT/'evidence/2026-10-09'/label/('run'+index);output.mkdir(parents=True,exist_ok=False)
now='2026-10-05T09:00:00-04:00'; report=output/'report.md'
app=Path(os.environ.get('NEXTNOTES_APP','/Applications/Next Notes.app'));binary=app/'Contents/MacOS/NextNotes';identity=pinned.binary_identity(binary)
command=[str(ROOT/'Scripts/run-selftest.sh'),'--selftest-toolloop-live','--quick','--model',model,'--fixture-now',now,'--report',str(report),'--selftest-timeout','1800']
supervisor=['python3',str(ROOT/'evidence/2026-10-09/run-admitted.py'),str(output),large,*command]
notice=subprocess.run(['agent-relay','send','--as','claude2-bakeoff2','--to','meeting-performance-20261007','--project','/Users/sergekadjo/Documents/Claude/Projects/speechify','--message',f'bakeoff2 notice: queueing {label} text-only quick {index}/3 via FIFO heavy.sh with model claim/resource guards; explicit go waived by orchestrator; no voice.'],capture_output=True,text=True)
(output/'notice.json').write_text(notice.stdout+notice.stderr)
if notice.returncode or json.loads(notice.stdout).get('ok') is not True: sys.exit('Notice persistence failed; not queued')
env=dict(os.environ,RELAY_ID='claude2-bakeoff2',TZ='America/New_York')
with (output/'wrapper.log').open('w') as log:
    proc=subprocess.Popen([str(ROOT.parent/'heavy.sh'),shlex.join(supervisor)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=env)
    for line in proc.stdout:
        log.write(line);log.flush();print(line,end='',flush=True)
    code=proc.wait()
result={'modelPin':model,'fixtureNow':now,'wrapperExit':code,'command':command,'app':str(app),'binaryIdentityBefore':identity,'binaryUnchanged':identity==pinned.binary_identity(binary)}
try:
    if not result['binaryUnchanged']: raise RuntimeError('Installed binary changed')
    score,resolved,timezone=pinned.read_score(report,(output/'wrapper.log').read_text(),code,model,now)
    result.update(score=score,resolvedModel=resolved,timezone=timezone)
except (OSError,RuntimeError,ValueError) as error: result['unscoredReason']=str(error)
(output/'result.json').write_text(json.dumps(result,indent=2)+'\n'); print('BAKEOFF_RESULT: '+json.dumps(result),flush=True)
sys.exit(0 if 'score' in result else 75)
