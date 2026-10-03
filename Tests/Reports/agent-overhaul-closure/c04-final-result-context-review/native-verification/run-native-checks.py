from pathlib import Path
import hashlib, json, re, shutil, subprocess, sys, tempfile, time
root = Path(__file__).resolve().parents[5]
report = Path(__file__).resolve().parent
build = int(sys.argv[1])
flags = sys.argv[2:] or ['c04-final-result-context']
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
manifest = json.loads((report / f'build{build}-source-manifest.json').read_text())
def source_map():
    files = list((root/'Sources').rglob('*')) + list((root/'Resources').rglob('*'))
    files += [root/n for n in ('Makefile','Package.swift','Package.resolved')]
    return {str(p.relative_to(root)):sha(p) for p in sorted(files) if p.is_file()}
def drift():
    after = source_map()
    return [p for p in manifest.keys() | after.keys() if manifest.get(p) != after.get(p)]
bundle = Path('/Applications/Next Notes.app')
binary = bundle/'Contents/MacOS/NextNotes'
def bundle_map():
    return {str(p.relative_to(bundle)):sha(p) for p in sorted(bundle.rglob('*')) if p.is_file()}
assert not drift(), drift()
identity = sha(binary)
before = bundle_map()
existing = report/f'app{build}-bundle-before.json'
if existing.exists(): assert json.loads(existing.read_text()) == before
else: existing.write_text(json.dumps(before,indent=2)+'\n')
cache = Path.home()/f'Library/Caches/NextNotesBuild/agent-closure-app{build}-NextNotes'
shutil.copy2(binary,cache)
metadata = {'build':build,'sha256':identity,'cache':str(cache),'sourceDrift':[]}
(report/f'app{build}-binary.json').write_text(json.dumps(metadata,indent=2)+'\n')
Path(f'/tmp/nextnotes-agent-closure-app{build}-binary.json').write_text(json.dumps(metadata,indent=2)+'\n')
shutil.copy2(f'/tmp/nextnotes-agent-closure-build{build}.log',report/f'build{build}.log')
out = Path(tempfile.mkdtemp(prefix=f'nextnotes-c04-final-context-{build}-'))
records_path = report/f'app{build}-checks.json'
records = json.loads(records_path.read_text()) if records_path.exists() else []
for flag in flags:
    args = ['--c04-fixture-now',(report/'fixture-now.txt').read_text().strip()] if flag in ('c04-result-context','c04-final-result-context') else []
    stdout = report/f'app{build}-{flag}.stdout'; app_log=out/(flag+'.log')
    start=time.monotonic()
    with stdout.open('w') as stream:
        result=subprocess.run([str(root/'Scripts/run-selftest.sh'),'--out',str(app_log),'--selftest-'+flag,*args],cwd=root,stdout=stream,stderr=subprocess.STDOUT,timeout=330)
    seconds=time.monotonic()-start
    raw_stdout=stdout.read_text(); raw_log=app_log.read_text() if app_log.exists() else ''
    if app_log.exists(): shutil.copy2(app_log,report/f'app{build}-{flag}.log')
    # Prefer intact application verdict; interleaved stdout is retained verbatim.
    markers=re.findall(r'^[A-Z][A-Z0-9_]*_(?:OK|FAILED)[^\n]*',raw_log,re.M)
    if not markers: markers=re.findall(r'^[A-Z][A-Z0-9_]*_(?:OK|FAILED)[^\n]*',raw_stdout,re.M)
    marker=markers[-1] if markers else 'ABSENT'
    record={'flag':flag,'exit':result.returncode,'marker':marker,'seconds':seconds,'sourceDrift':drift(),'sameInstalledBinary':sha(binary)==identity,'sameBundle':bundle_map()==before}
    records.append(record);records_path.write_text(json.dumps(records,indent=2)+'\n');print(record,flush=True)
    assert not record['sourceDrift'] and record['sameInstalledBinary'] and record['sameBundle'], record
    if flag=='c04-final-result-context':
        checks=re.findall(r'^C04_FINAL_RESULT_CONTEXT_CHECK (.+) (PASS|FAIL)$',raw_stdout,re.M)
        failures=re.findall(r'^C04_FINAL_RESULT_CONTEXT_FAILURE (.+)$',raw_stdout,re.M)
        assert len(checks)==122 and len({name for name,_ in checks})==122, (len(checks),checks)
        assert all(verdict=='PASS' for name,verdict in checks if any(k in name for k in ('grounding','memory','permission'))), 'Fixture domain controls failed; prompt artifacts must remain private'
        assert 'OMITTED_UNPROVEN_LOCAL_GROUNDING' not in raw_stdout
        if build==109:
            expected=[name+'/C07-final-mail-body-admission' for name in ('refusal-8192','claim-8192','refusal-32768','claim-32768')]+['history/H03-measured-earlier-history-removal','unfit/U05-refuse-final-model','unfit/U06-render-existing-overflow-result']
            assert result.returncode==1 and marker=='C04_FINAL_RESULT_CONTEXT_FAILED 7/122', record
            assert failures==expected and [name for name,v in checks if v=='FAIL']==expected, failures
        else:
            assert result.returncode==0 and marker=='C04_FINAL_RESULT_CONTEXT_OK 122' and not failures,record
    else:
        assert result.returncode==0 and '_OK' in marker and not re.search(r'^[A-Z][A-Z0-9_]*_FAILED',raw_stdout+'\n'+raw_log,re.M),record
(report/f'app{build}-bundle-after.json').write_text(json.dumps(bundle_map(),indent=2)+'\n')
print('Native checks completed; Sources and signed bundle unchanged.',flush=True)
