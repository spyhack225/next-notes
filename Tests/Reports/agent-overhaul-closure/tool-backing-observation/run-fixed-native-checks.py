from pathlib import Path
import hashlib,json,subprocess,shutil,re,sys,tempfile
root=Path('/Users/sergekadjo/Documents/Claude/Projects/speechify')
r=root/'Tests/Reports/agent-overhaul-closure/tool-backing-observation'
m=json.loads((r/'build51-source-manifest.json').read_text())
def drift(): return [f for f,h in m.items() if not (root/f).is_file() or hashlib.sha256((root/f).read_bytes()).hexdigest()!=h]
assert not drift(),drift()
binary=Path('/Applications/Next Notes.app/Contents/MacOS/NextNotes');h=hashlib.sha256(binary.read_bytes()).hexdigest()
cache=Path.home()/'Library/Caches/NextNotesBuild/agent-closure-app51-NextNotes';shutil.copy2(binary,cache)
meta={'build':47,'sha256':h,'cache':str(cache),'sourceStability':drift()}
(r/'app51-binary.json').write_text(json.dumps(meta,indent=2)+'\n')
Path('/tmp/nextnotes-agent-closure-app51-binary.json').write_text(json.dumps(meta,indent=2)+'\n')
shutil.copy2('/tmp/nextnotes-agent-closure-build51.log',r/'build51.log')
flags=['task-harness-read','task-worker-attempt','task-durability','task-recovery','task-authority','task-restoration','task-history-repair','receipt-persistence','tool-review','toolloop-production','routine-authority','schedule','usage-log','store-isolation','toolloop-live-grader','voice-scheduling','acp','mcp','acp-confirm']
results=[]
outputRoot=Path(tempfile.mkdtemp(prefix='nextnotes-task-read-checks51-'))
for f in flags:
 log=r/f'fixed51-{f}.stdout'
 with log.open('w') as out:
  output=outputRoot/(f+'.log')
  result=subprocess.run([str(root/'Scripts/run-selftest.sh'),'--out',str(output),'--selftest-'+f],cwd=root,stdout=out,stderr=subprocess.STDOUT)
 if output.exists(): shutil.copy2(output,r/f'fixed51-{f}.log')
 data=log.read_text()+(output.read_text() if output.exists() else '');markers=re.findall(r'^[A-Z][A-Z0-9_]*_(?:OK|FAILED)[^\n]*',data,re.M)
 marker=markers[-1] if markers else 'ABSENT'
 ok=result.returncode==0 and '_OK' in marker and not re.search(r'^[A-Z][A-Z0-9_]*_FAILED',data,re.M)
 results.append({'flag':f,'exit':result.returncode,'marker':marker,'verdict':'PASS' if ok else 'FAIL'})
 print(results[-1],flush=True)
 (r/'fixed51-checks.json').write_text(json.dumps(results,indent=2)+'\n')
 if not ok: sys.exit(1)
assert not drift(),drift()
assert hashlib.sha256(binary.read_bytes()).hexdigest()==h
(r/'fixed51-stability.json').write_text(json.dumps({'sourceDrift':drift(),'sameInstalledBinary':True},indent=2)+'\n')
print('All19 flags PASS; full source manifest/binary unchanged.',flush=True)
