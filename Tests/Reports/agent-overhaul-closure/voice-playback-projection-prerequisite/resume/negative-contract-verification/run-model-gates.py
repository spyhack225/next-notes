from pathlib import Path
import hashlib,json,re,shutil,subprocess,tempfile
root=Path(__file__).resolve().parents[6]
report=Path(__file__).resolve().parent
proof=report
manifest=json.loads((proof/'build101-source-manifest.json').read_text())
bundle=Path('/Applications/Next Notes.app')
expected=json.loads((proof/'app101-bundle-after.json').read_text())
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def verify():
    assert not [p for p,h in manifest.items() if sha(root/p)!=h]
    assert {str(p.relative_to(bundle)):sha(p) for p in sorted(bundle.rglob('*')) if p.is_file()}==expected
out=Path(tempfile.mkdtemp(prefix='nextnotes-knowledge-model-gates-101-'))
cases=[('quick',['--selftest-toolloop-live','--quick','--report',str(report/'app101-quick.md'),'--selftest-timeout','3350'],3450),
       ('tool-awareness',['--selftest-tool-awareness','--selftest-timeout','1000'],1100),
]
records=[]
for name,args,timeout in cases:
    verify();app_log=out/(name+'.log');stdout=(out if name=='agent-answers' else report)/('app101-'+name+'.stdout')
    with stdout.open('w') as stream:
        result=subprocess.run([str(root/'Scripts/run-selftest.sh'),'--out',str(app_log),*args],cwd=root,stdout=stream,stderr=subprocess.STDOUT,timeout=timeout)
    if app_log.exists() and name!='agent-answers':shutil.copy2(app_log,report/('app101-'+name+'.log'))
    text=app_log.read_text() if app_log.exists() else stdout.read_text()
    matches=re.findall(r'^[A-Z][A-Z0-9_]*_(?:OK|FAILED|ABSENT)[^\n]*',text,re.M)
    marker=matches[-1] if matches else 'MISSING'
    full=stdout.read_text()+'\n'+text
    record={'name':name,'exit':result.returncode,'marker':marker,'score':re.findall(r'TOOLLOOP_LIVE_SCORE[^\n]*',full),'sourceDrift':[],'sameBundle':True,'verdict':'PASS' if result.returncode==0 and '_OK' in marker else 'OPEN'}
    if name=='agent-answers':
        admitted=[]
        for suffix,raw in [('stdout',stdout),('log',app_log)]:
            if not raw.exists():continue
            lines=[line for line in raw.read_text().splitlines() if line.startswith(('AGENT_ANSWERS_OK:','AGENT_ANSWERS_PREFILL '))]
            (report/('app101-agent-answers.'+suffix)).write_text('METADATA_ONLY: granted calendar diagnostic; raw replies remain in private system temp.\n'+'\n'.join(lines)+'\n')
            admitted.append({'file':'app101-agent-answers.'+suffix,'rawSHA256':sha(raw),'retention':'private system temp, excluded from repository','shareable':'outcome and token counts only'})
        (report/'app101-agent-answers-artifact-policy.json').write_text(json.dumps(admitted,indent=2)+'\n')
    verify();records.append(record);(report/'app101-model-gates.json').write_text(json.dumps(records,indent=2)+'\n');print(record,flush=True)
    assert marker!='MISSING' and result.returncode in (0,1),record
