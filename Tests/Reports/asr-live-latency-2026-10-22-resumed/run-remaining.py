"""Invoke only after the coordinated native machine handback."""
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'Tools'))
import run_asr_live_serial as suite
import subprocess,json,os,datetime
report = Path(__file__).resolve().parent
for name,script,extra in [('phonon','asr_phonon_compare.py',[]),('qwen-17b','asr_qwen_compare.py',['--size','1.7b']),('voz','asr_voz_live.py',[])]:
    output = report/f'{name}.json'
    if output.exists():
        raise RuntimeError(f'Review existing attempt before retry: {output}')
    before=suite.context()
    print(f'START {name}: free{before["disk_free_bytes"]/1024**3:.2f}GiB',flush=True)
    result=subprocess.run([sys.executable,'-B',str(ROOT/'Tools'/script),*extra,'--output',str(output)],env={**os.environ,'ASR_LIVE':'1','PYTHONDONTWRITEBYTECODE':'1'})
    after=suite.context()
    context=report/(name+'-remaining-context.json')
    context.write_text(json.dumps(dict(before=before,after=after,command_exit=result.returncode),indent=2)+'\n')
    print(f'FINISHED {name}: exit{result.returncode}',flush=True)
    # Inspect native failures before continuing; OS model compilers may still
    # settle after the owned runtime has joined.
    cache=Path.home()/'Library/Caches/NextNotesASRBench'
    residue=[str(p) for p in cache.iterdir() if p.name!='serial.lock']
    if residue:
        raise RuntimeError(f'Inspect owned residual assets before successor: {residue}')
    if result.returncode:
        raise SystemExit(result.returncode)
