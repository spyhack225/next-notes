from pathlib import Path
from collections import Counter
import hashlib,json,re,shutil,subprocess,sys,tempfile,time
ROOT=next(p for p in Path(__file__).resolve().parents if (p/'Package.swift').is_file())
REPORT=Path(__file__).resolve().parent
build=int(sys.argv[1]);flags=sys.argv[2:] or ['task-worker-attempt']
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
manifest=json.loads((REPORT/f'build{build}-source-manifest.json').read_text())
def source_map():
 files=list((ROOT/'Sources').rglob('*'))+list((ROOT/'Resources').rglob('*'))+[ROOT/n for n in ('Makefile','Package.swift','Package.resolved')]
 return {str(p.relative_to(ROOT)):sha(p) for p in sorted(files) if p.is_file()}
def source_drift():
 after=source_map();return [p for p in manifest.keys()|after.keys() if manifest.get(p)!=after.get(p)]
bundle=Path('/Applications/Next Notes.app');binary=bundle/'Contents/MacOS/NextNotes'
def bundle_map():return {str(p.relative_to(bundle)):sha(p) for p in sorted(bundle.rglob('*')) if p.is_file()}
assert not source_drift(),source_drift()
identity=sha(binary);before=bundle_map();existing=REPORT/f'app{build}-bundle-before.json'
if existing.exists():assert json.loads(existing.read_text())==before
else:existing.write_text(json.dumps(before,indent=2)+'\n')
cache=Path.home()/f'Library/Caches/NextNotesBuild/agent-closure-app{build}-NextNotes';shutil.copy2(binary,cache)
metadata={'build':build,'sha256':identity,'cache':str(cache),'sourceDrift':[]}
(REPORT/f'app{build}-binary.json').write_text(json.dumps(metadata,indent=2)+'\n');Path(f'/tmp/nextnotes-agent-closure-app{build}-binary.json').write_text(json.dumps(metadata,indent=2)+'\n')
shutil.copy2(f'/tmp/nextnotes-agent-closure-build{build}.log',REPORT/f'build{build}.log')
out=Path(tempfile.mkdtemp(prefix=f'nextnotes-verified-mail-{build}-'))
records_path=REPORT/f'app{build}-checks.json';records=json.loads(records_path.read_text()) if records_path.exists() else []
MODELS=['accepted','denied','held','released','zero-date','missing-date','boolean-date','fractional-date','partial-metadata','empty-metadata','mismatched-response','failed-read']
expected=[]
for mode in MODELS:
 if mode not in ('empty-metadata','mismatched-response'):
  expected += [f'verified mail target: exact verified ordered/deduplicated references ({mode})',f'verified mail target: positive-only title/date/source ({mode})']
 if mode not in ('released','empty-metadata','mismatched-response'):
  expected += [f'verified mail target: same immutable intent/prepared/request descriptors ({mode})']
 if mode not in ('denied','held','released','empty-metadata','mismatched-response'):
  expected += [f'verified mail target: same evidence survives exact completed receipt ({mode})']
assert len(expected)==36
def worker_events(app,stdout):
 prefix=r'^TASK_WORKER_ATTEMPT_(?:WRONG|OK|FAILED):'
 def intact(raw):
  lines=[line for line in raw.splitlines() if re.match(prefix,line)]
  broken=[line for line in lines if len(re.findall(r'TASK_WORKER_ATTEMPT_(?:WRONG|OK|FAILED):',line))!=1]
  return [line for line in lines if line not in broken],broken
 a,ab=intact(app);b,bb=intact(stdout);counts=Counter(a);seen=Counter();merged=list(a)
 for line in b:
  seen[line]+=1
  if seen[line]>counts[line]:merged.append(line)
 markers=[x for x in merged if not x.startswith('TASK_WORKER_ATTEMPT_WRONG:')]
 assert len(set(markers))==1 and not ab,(markers,ab)
 return merged,{'appLog':ab,'stdout':bb}
for flag in flags:
 app_log=out/(flag+'.log');stdout=REPORT/f'app{build}-{flag}.stdout'
 args=['--c04-fixture-now',(REPORT/'fixture-now.txt').read_text().strip()] if flag.startswith('c04-') else []
 start=time.monotonic()
 with stdout.open('w') as stream:
  result=subprocess.run([str(ROOT/'Scripts/run-selftest.sh'),'--out',str(app_log),'--selftest-'+flag,*args],cwd=ROOT,stdout=stream,stderr=subprocess.STDOUT,timeout=340)
 elapsed=time.monotonic()-start
 raw_stdout=stdout.read_text();raw_app=app_log.read_text() if app_log.exists() else ''
 if app_log.exists():shutil.copy2(app_log,REPORT/f'app{build}-{flag}.log')
 if flag=='task-worker-attempt':
  events,fragments=worker_events(raw_app,raw_stdout)
  markers=[x for x in events if not x.startswith('TASK_WORKER_ATTEMPT_WRONG:')];marker=markers[-1]
  wrong=[x.removeprefix('TASK_WORKER_ATTEMPT_WRONG: ') for x in events if x.startswith('TASK_WORKER_ATTEMPT_WRONG:')]
  traces=re.findall(r'^VERIFIED_MAIL_TRACE: mode=(\S+) cli=(\d+) refs=(\d+) writes=(\d+) attempt=(\d+) pending=(true|false)$',raw_app,re.M)
  if not traces:traces=re.findall(r'^VERIFIED_MAIL_TRACE: mode=(\S+) cli=(\d+) refs=(\d+) writes=(\d+) attempt=(\d+) pending=(true|false)$',raw_stdout,re.M)
  classification={'phase':'original' if build==111 else 'fixed','failures':wrong,'expectedOriginalFeatures':expected,'intactFinalMarker':marker,'bufferedFragments':fragments,'modeTraces':traces,'originalActualCaseCount':None,'limit':'FAILED prints assertions only; original1714 is preparation arithmetic, not measured case count.'}
  (REPORT/f'app{build}-worker-classification.json').write_text(json.dumps(classification,indent=2)+'\n')
 else:
  markers=re.findall(r'^[A-Z][A-Z0-9_]*_(?:OK|FAILED)[^\n]*',raw_app,re.M) or re.findall(r'^[A-Z][A-Z0-9_]*_(?:OK|FAILED)[^\n]*',raw_stdout,re.M)
  marker=markers[-1] if markers else 'ABSENT'
 record={'flag':flag,'exit':result.returncode,'marker':marker,'seconds':elapsed,'sourceDrift':source_drift(),'sameInstalledBinary':sha(binary)==identity,'sameBundle':bundle_map()==before}
 records.append(record);records_path.write_text(json.dumps(records,indent=2)+'\n');print(record,flush=True)
 assert not record['sourceDrift'] and record['sameInstalledBinary'] and record['sameBundle'],record
 if flag=='task-worker-attempt':
  assert len(traces)==12 and [x[0] for x in traces]==MODELS and all(int(x[4])>0 for x in traces),traces
  if build==111:
   assert result.returncode==1 and marker=='TASK_WORKER_ATTEMPT_FAILED: 36 assertions' and Counter(wrong)==Counter(expected),(record,wrong)
  else:
   assert result.returncode==0 and marker=='TASK_WORKER_ATTEMPT_OK: 1714 cases' and not wrong,(record,wrong)
 else:
  assert result.returncode==0 and '_OK' in marker and not re.search(r'^[A-Z][A-Z0-9_]*_FAILED',raw_stdout+'\n'+raw_app,re.M),record
(REPORT/f'app{build}-bundle-after.json').write_text(json.dumps(bundle_map(),indent=2)+'\n')
print('Native checks complete; full compiler Source and signed bundle unchanged.',flush=True)
