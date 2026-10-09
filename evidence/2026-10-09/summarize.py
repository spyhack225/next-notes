#!/usr/bin/env python3
"""Summarize retained measurements without altering native grades."""
import json,re,statistics
from pathlib import Path
root=Path(__file__).resolve().parent
results=[]
for d in sorted(root.glob('*/run*')):
 if not (d/'result.json').exists():continue
 r=json.loads((d/'result.json').read_text());r['relativePath']=str(d.relative_to(root))
 report=d/'report.md'
 if report.exists():
  md=report.read_text();m=re.search(r'elapsed ([\d.]+)s',md)
  r['elapsedSeconds']=float(m[1]) if m else None
  rows=[json.loads(s) for s in Path(str(report)+'.jsonl').read_text().splitlines()]
  r['verdicts']={row['id']:row['verdict'] for row in rows}
  r['nativePeakRSSBytes']=max((row.get('process',{}).get('peakResidentMemoryBytes',0) for row in rows),default=None)
  r['thermalStates']=sorted({row.get('process',{}).get('thermalState','unknown') for row in rows})
 if (d/'admission.json').exists():r['admission']=json.loads((d/'admission.json').read_text())
 if (d/'machine.jsonl').exists():
  samples=[json.loads(s) for s in (d/'machine.jsonl').read_text().splitlines()]
  usage=[u for s in samples for u in s.get('ownedUsage',[]) if u.get('name','').endswith('/NextNotes') and u.get('available')]
  r['sampledPeakFootprintBytes']=max((u['footprintBytes'] or 0 for u in usage),default=None)
  r['minFreeGiB']=min(s['freeGiB'] for s in samples);r['maxSwapGiB']=max(s['swapGiB'] for s in samples)
 results.append(r)
cohorts={}
for label in ('qwen35-clone','apple-clone','minicpm-clone','gemma-clone','qwen3-clone'):
 rs=[r for r in results if r['relativePath'].split('/')[0]==label and 'score' in r]
 if len(rs)==3:
  assert len({r['resolvedModel'] for r in rs})==1 and len({r['fixtureNow'] for r in rs})==1
  assert all(r['binaryUnchanged'] and r['app'].endswith('NextNotes-503e0e40.app') for r in rs)
  scores=[r['score'] for r in rs];times=[r['elapsedSeconds'] for r in rs]
  cohorts[label]={'scores':scores,'median':statistics.median(scores),'min':min(scores),'max':max(scores),'elapsedMedian':statistics.median(times),'elapsedMin':min(times),'elapsedMax':max(times)}
(root/'measurements.json').write_text(json.dumps({'cohorts':cohorts,'runs':results},indent=2)+'\n')
print(json.dumps(cohorts))
