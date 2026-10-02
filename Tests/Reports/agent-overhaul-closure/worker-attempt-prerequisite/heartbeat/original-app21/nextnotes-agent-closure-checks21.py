import subprocess,pathlib,re,sys,json
root=pathlib.Path('/Users/sergekadjo/Documents/Claude/Projects/speechify')
out=pathlib.Path('/tmp/nextnotes-agent-closure-checks-21');out.mkdir(exist_ok=True)
flags=['task-worker-attempt']
results=[]
for f in flags:
 p=out/('selftest-'+f)
 with p.with_suffix('.log').open('w') as log:
  r=subprocess.run([str(root/'Scripts/run-selftest.sh'),'--out',str(p.with_suffix('.out')),'--selftest-'+f,'--selftest-timeout','300'],cwd=root,stdout=log,stderr=subprocess.STDOUT)
 data=p.with_suffix('.log').read_text()+ (p.with_suffix('.out').read_text() if p.with_suffix('.out').exists() else '')
 markers=re.findall(r'^[A-Z][A-Z0-9_]*_(?:OK|FAILED)[^\n]*',data,re.M)
 marker=markers[-1] if markers else 'ABSENT'
 verdict='PASS' if r.returncode==0 and '_OK' in marker else 'FAIL'
 results.append({'flag':f,'exit':r.returncode,'verdict':verdict,'marker':marker})
 print(f'{verdict} {f} {marker}',flush=True)
(out/'summary.json').write_text(json.dumps(results,indent=2)+'\n')
sys.exit(any(x['verdict']=='FAIL' for x in results))
