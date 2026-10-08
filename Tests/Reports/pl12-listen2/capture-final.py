#!/usr/bin/env python3
"""Read retained outputs only; no build, test, mutation or native launch."""
import hashlib,json,re,subprocess
from pathlib import Path
r=Path('Tests/Reports/pl12-listen2')
labels=['resident-red','resident-green','prefill-final','route-resident-final','mini-after-final','resident-partials','resident-pipeline','resident-routing','resident-concurrent','resident-conversation','resident-duplex','resident-prefix','resident-isolation']
statuses={}
for line in (r/'resident-status.txt').read_text().splitlines():
    label, code=line.split(' exit='); statuses[label]=int(code)
checks={}
for label in labels:
    f=r/(label+'.log')
    if not f.exists(): f=r/(label+'.stdout.log')
    raw=f.read_bytes(); lines=raw.decode(errors='replace').splitlines()
    stdout=r/(label+'.stdout.log'); sr=stdout.read_bytes(); sl=sr.decode(errors='replace').splitlines()
    checks[label]={'stdout_file':str(stdout),'stdout_sha256':hashlib.sha256(sr).hexdigest(),'stdout_markers':[x for x in sl if re.match(r'^[A-Z][A-Z0-9_]*_(OK|FAILED|ABSENT)(?:$|:|=)',x)],'exit':statuses.get(label),'file':str(f),'sha256':hashlib.sha256(raw).hexdigest(),'markers':[x for x in lines if re.match(r'^[A-Z][A-Z0-9_]*_(OK|FAILED|ABSENT)(?:$|:|=)',x)],'nested_browser_failures':sum('TOOLLOOP_PRODUCTION_WRONG: A02' in x for x in sl)}
red=json.loads((r/'resident-red-pins.json').read_text()); fixed=json.loads((r/'resident-final-pins.json').read_text())
assert red['fixture_sha256']==fixed['fixture_sha256']
assert red['resident_fixture_sha256']==fixed['resident_fixture_sha256']
assert red['original_fixture_body_sha256']==fixed['original_fixture_body_sha256']
for f,want in fixed['source_hashes'].items(): assert hashlib.sha256(Path(f).read_bytes()).hexdigest()==want, f
(r/'resident-checks.json').write_text(json.dumps({'unchanged_resident_fixture':True,'unchanged_original_prefill_body':True,'source_invariance_after_tests':True,'checks':checks},indent=2)+'\n')
files=['baseline-pocket.log','route-after.log','mini-before.log','mini-after-initial.log','mini-after-final.log']
v=subprocess.check_output(['python3',str(r/'summarize-latency.py')]+[str(r/f) for f in files],text=True)
(r/'final-comparison.json').write_text(v)
print('LISTEN2_FINAL_EVIDENCE_CAPTURE_OK')
