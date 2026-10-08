#!/usr/bin/env python3
"""Retain counted original log rows and recompute nearest-rank p95, never fill NA."""
import hashlib,json,math,re,statistics,sys
from pathlib import Path
out={}
for filename in sys.argv[1:]:
    p=Path(filename); raw=p.read_bytes(); s=raw.decode(errors='replace')
    lines=[x for x in s.splitlines() if x.startswith('VOICE_LATENCY_RUN=') and ' L1=' in x and not x.startswith('VOICE_LATENCY_RUN=0 ')]
    rows=[]
    for line in lines:
        row={'index':int(re.search(r'VOICE_LATENCY_RUN=(\d+)',line)[1]),'raw':line}
        for k in ['L1','L2','L3','route_to_first_token','speech_end_to_endpoint','endpoint_to_request']:
            m=re.search(r'\b'+k+r'=([0-9.]+|NA)\b',line)
            row[k]=float(m[1]) if m and m[1]!='NA' else None
        rows.append(row)
    summary={}
    for k in ['L1','L2','L3','route_to_first_token','speech_end_to_endpoint','endpoint_to_request']:
        v=sorted(r[k] for r in rows if r[k] is not None)
        summary[k]={'n':len(v),'median':statistics.median(v) if v else None,'p95':v[math.ceil(len(v)*.95)-1] if v else None,'min':min(v) if v else None,'max':max(v) if v else None}
    gates={k:('PASS' if summary[k]['n']==5 and summary[k]['median'] < .2 else 'FAIL' if summary[k]['n']==5 else 'UNMEASURED') for k in ['L1','L2']}
    markers=[x for x in s.splitlines() if x.startswith(('VOICE_LATENCY_OK','VOICE_LATENCY_FAILED','VOICE_LATENCY_ABSENT','SELFTEST_TIMEOUT'))]
    out[p.name]={'file':str(p),'sha256':hashlib.sha256(raw).hexdigest(),'rows':rows,'summary_seconds':summary,'200ms_median_gates':gates,'markers':markers}
print(json.dumps(out,indent=2))
