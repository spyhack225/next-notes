#!/usr/bin/env python3
"""Read authored retained metadata only; never open owner usage/metrics stores."""
from pathlib import Path
import json,re,hashlib,statistics
report=Path('Tests/Reports/voice-mini')
base=Path('Tests/Reports/pl12-listen2')
result={}
for label in ['baseline-pocket','route-after','mini-before','mini-after-final']:
    path=base/(label+'.stdout.log')
    if not path.exists():path=base/(label+'.log')
    text=path.read_text()
    turns=[]
    for line in text.splitlines():
        if not re.match(r'VOICE_LATENCY_RUN=[1-5] speech_end',line):continue
        fields=dict(re.findall(r'(\w+)=([^ ]+)',line))
        def val(key):
            try:return float(fields[key])
            except (KeyError,ValueError):return None
        l2=val('L2');tail=val('route_to_first_token')
        turns.append({'run':int(fields['VOICE_LATENCY_RUN']), 'endpoint_to_route_done_s':round(l2-tail,3) if l2 is not None and tail is not None else None,'route_total_s':val('route'),'route_to_first_answer_s':tail,'endpoint_source':fields.get('endpoint_source'),'main_stall_s':val('main_stall_max')})
    answers=[line for line in text.splitlines() if re.match(r'VOICE_LATENCY_MODEL run=[1-5] pass=frontend-answer',line)]
    reasons=re.findall(r'model\.unload.*?reason=(\w+)',text)
    events={}
    for line in text.splitlines():
        m=re.match(r'VOICE_FRONTEND_TIMING gen=(\d+) revision=\S+ event=(.*?) elapsed_s=([\d.]+)(.*)',line)
        if m:events.setdefault(m[1],[]).append({'event':m[2], 'elapsed_s':float(m[3]),'duration_s':float(re.search(r'duration_s=([\d.]+)',m[4])[1]) if 'duration_s=' in m[4] else None})
    committed=[{'generation':gen,'events':rows} for gen,rows in events.items() if any(row['event']=='partial_route_committed_answer' for row in rows)]
    result[label]={'source':str(path),'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'turns':turns,'endpoint_to_route_done_median_s':statistics.median(v) if (v:=[x['endpoint_to_route_done_s'] for x in turns if x['endpoint_to_route_done_s'] is not None]) else None,'answer_rows':len(answers),'warm_true':sum('warm=true' in row for row in answers),'warm_false':sum('warm=false' in row for row in answers),'warm_unknown':sum('warm=unavailable' in row for row in answers),'final_counts_unavailable':sum('completion_tokens=unavailable' in row for row in answers),'unload_reasons_observed_in_retained_stdout':reasons,'committed_generations':committed}
(report/'retained-analysis.json').write_text(json.dumps({'scope':'retained authored listen2 diagnostic metadata only; missing unload rows are unavailable, not zero owner evictions; no normal-use rate can be inferred','runs':result},indent=2)+'\n')
print('RETAINED_VOICE_METADATA_CAPTURE_OK')
