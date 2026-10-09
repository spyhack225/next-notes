#!/usr/bin/env python3
"""Run inside one normal heavy.sh slot; changes only this owned worktree."""
from pathlib import Path
import hashlib,json,os,re,shutil,subprocess,tempfile,time
root=Path(__file__).resolve().parents[4]
report=Path(__file__).resolve().parent
scratch=Path.home()/'Library/Caches/NextNotesBuild/wt-scratch/clockfix'
work=Path(tempfile.mkdtemp(prefix='NextNotes-clockfix-'))
runner=root/'Sources/NextNotes/Agent/Planner/ToolStepRunner.swift'
grounder=root/'Sources/NextNotes/Agent/AgentToolLoop.swift'
floor=root/'Sources/NextNotes/Agent/AgentAccountRead.swift'
initial={p:p.read_text() for p in [runner,grounder,floor]}
baseline={p:subprocess.check_output(['git','show','e0b649c5:'+str(p.relative_to(root))],cwd=root,text=True) for p in initial}
binding='for: canonicalID, proposed: call.arguments, request: request,\n            now: SelfTest.fixtureClock ?? Date())'
assert baseline[runner].count(binding)==1
removed=baseline[runner].replace(binding,'for: canonicalID, proposed: call.arguments, request: request)')
fixed={runner:removed,grounder:baseline[grounder].replace('now: Date = Date(), calendar: Calendar = .current','now: Date = SelfTest.fixtureClock ?? Date(), calendar: Calendar = .current'),floor:baseline[floor].replace('now: Date = Date()', 'now: Date = SelfTest.fixtureClock ?? Date()')}
assert fixed[grounder]!=baseline[grounder] and fixed[floor]!=baseline[floor]
results=[]
env={**os.environ,'TMPDIR':str(work)+'/', 'TZ':'America/New_York'}
def run(name,args,expected=None,env_override=None):
    before=time.time(); log=report/(name+'.log')
    with log.open('w') as out:
        try: code=subprocess.run(args,cwd=root,stdout=out,stderr=subprocess.STDOUT,timeout=1800,env=env_override or env).returncode
        except subprocess.TimeoutExpired: code='timeout'
    text=log.read_text(errors='replace')
    native=work/(name+'.log')
    if native.exists():
        (report/(name+'-selftest.log')).write_bytes(native.read_bytes())
        text+='\n'+native.read_text(errors='replace')
    markers=[x for x in text.splitlines() if expected and re.match('^'+expected+r'_(?:OK|FAILED|ABSENT)(?::|$)',x)]
    item=dict(name=name,exit=code,marker=markers[-1] if markers else 'NO_FINAL_MARKER',elapsed=time.time()-before,args=args,
              cases=[x for x in text.splitlines() if x.startswith('TOOLLOOP_LIVE_CASE ')][:2])
    results.append(item);(report/'checks.json').write_text(json.dumps(results,indent=2)+'\n');print(json.dumps(item),flush=True)
    return code==0 and (expected is None or markers and markers[-1].startswith(expected+'_OK'))
def build(name):
    ok=run(name,['swift','build','-c','debug','-j','2','--scratch-path',str(scratch)])
    if ok:
        binary=scratch/'debug/NextNotes'
        (report/(name+'-pin.json')).write_text(json.dumps(dict(binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),sources={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (root/'Sources').rglob('*') if p.is_file()}),indent=2)+'\n')
    return ok
def check(name,flag,args=None,expected=None,env_override=None):
    return run(name,[str(scratch/'debug/NextNotes'),'--selftest-'+flag,*(args or []),'--selftest-out',str(work/(name+'.log'))],expected or flag.upper().replace('-','_'),env_override)
def clock(name,stamp='2026-10-05T09:00:00-04:00',env_override=None):
    return check(name,'toolloop-live',['--only','C01,C04','--model','scripted-clock','--fixture-now',stamp,'--report',str(report/(name+'.md'))],env_override=env_override)
finished=False
try:
    for p in baseline:
        assert initial[p] in (baseline[p], fixed[p]) or p == runner and initial[p] == baseline[p], 'Owned producer changed; refusing stale whole-file replay'
    for p,s in baseline.items(): p.write_text(s)
    if not run('webrtc-build',['make','webrtc-audio']): raise SystemExit(1)
    if not build('baseline-build'): raise SystemExit(1)
    clock('baseline-explicit-binding')
    if results[-1]['exit']!=1 or 'clock defaults failed (4)' not in results[-1]['marker']:
        raise SystemExit('Baseline default-clock regression did not produce expected RED')
    runner.write_text(removed)
    (report/'removed-binding.patch').write_text(subprocess.check_output(['git','diff','--',str(runner)],cwd=root,text=True))
    if not build('removed-binding-build'): raise SystemExit(1)
    clock('original-removed-binding')
    original=results[-1]
    if original['exit']!=1 or not all(' WRONG_TOOL ' in row for row in original['cases']) or len(original['cases'])!=2:
        raise SystemExit('Exact removed-clock original did not reproduce C01+C04 WRONG_TOOL')
    for p,s in fixed.items(): p.write_text(s)
    if not build('fixed-build'): raise SystemExit(1)
    if not clock('fixed-same-fixture'): raise SystemExit(1)
    # Prove the canonical omitted caller too, then keep HEAD's explicit binding.
    runner.write_text(baseline[runner])
    fixed[runner]=baseline[runner]
    if not build('final-build'): raise SystemExit(1)
    if not clock('final-same-fixture'): raise SystemExit(1)
    ok=True
    for name,stamp,zone in [('midnight','2026-10-05T23:30:00-04:00','America/New_York'),('dst','2026-11-01T01:30:00-04:00','America/New_York'),('utc','2026-10-05T23:30:00-04:00','UTC')]:
        ok=clock('fixed-'+name,stamp,{**env,'TZ':zone}) and ok
    for flag,marker in [('now-block','NOW_BLOCK'),('toolloop-live-grader','TOOLLOOP_LIVE_GRADER'),('toolloop-production','TOOLLOOP_PRODUCTION'),('capability-manifest','CAPABILITY_MANIFEST'),('store-isolation','STORE_ISOLATION')]:
        ok=check(flag,flag,expected=marker) and ok
    # One real Mini quick control, unchanged ten-case selection/bar. Gate again within the shared slot.
    if run('mini-resource-gate',['agent-relay','gate','--max-swap-gb','8','--max-load','40','--min-free-gb','10','--path',str(root),'--project','/Users/sergekadjo/Documents/Claude/Projects/speechify']):
        check('mini-control','toolloop-live',['--quick','--model','openbmb/MiniCPM5-2B-GGUF/MiniCPM5-2B-Q4_K_M.gguf','--fixture-now','2026-10-05T09:00:00-04:00','--report',str(report/'mini-control.md'),'--selftest-timeout','1800'])
    (report/'final.patch').write_text(subprocess.check_output(['git','diff'],cwd=root,text=True))
    print('CLOCKFIX_BATCH_OK' if ok else 'CLOCKFIX_BATCH_FAILED',flush=True)
    finished=True
    raise SystemExit(0 if ok else 1)
finally:
    for p,s in (fixed if finished else initial).items(): p.write_text(s)
    shutil.rmtree(work);shutil.rmtree(scratch,ignore_errors=True)
    (report/'cleanup.json').write_text(json.dumps(dict(temporary=str(work),temporary_exists=work.exists(),scratch=str(scratch),scratch_exists=scratch.exists(),finished=finished))+'\n')
