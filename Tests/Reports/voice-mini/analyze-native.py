#!/usr/bin/env python3
"""Analyze only this worktree's authored, metadata-only diagnostic artifacts."""
import json,re,statistics,math
from pathlib import Path
root=Path(__file__).resolve().parent
result={}
for label in ['apple','mini','cold-fallback','repeat-apple','repeat-mini']:
 path=root/(label+'.stdout.log')
 pin=root/(label+'-pins.json')
 if not path.exists() or not pin.exists(): continue
 lines=path.read_text(errors='replace').splitlines(); pins=json.loads(pin.read_text()); rows=[]
 for i in range(1,6):
  line=next((x for x in lines if x.startswith(f'VOICE_LATENCY_RUN={i} speech_end')),None)
  if line is None: rows.append({'run':i,'qualified':False,'reasons':['no measured turn row']});continue
  fields=dict(re.findall(r'(\w+)=([^ ]+)',line))
  def value(k):
   try:return float(fields[k])
   except (KeyError,ValueError):return None
  turnline=next((x for x in reversed(lines) if x.startswith(f'VOICE_LATENCY_TURN run={i} ')), '')
  ident=re.search(r' turn=([^ ]+)',turnline)
  passes=[x for x in pins['usage_metadata'] if ident and str(x.get('turnID','')).startswith(ident[1]) and x.get('pass')=='frontend-answer']
  completed=[x for x in passes if x.get('finishReason')=='stop' and x.get('errorClass') is None and (x.get('completionTokens') or 0)>0]
  reasons=[]
  if len(completed)!=1: reasons.append('not exactly one joined completed answer with final positive counts')
  elif label.endswith('mini') and (completed[0].get('provider')!='llama' or completed[0].get('warm') is not True or completed[0].get('countsEstimated') is not False):reasons.append('not a counted warm native Mini answer')
  elif not label.endswith('mini') and completed[0].get('provider')!='appleFM':reasons.append('not an Apple FM answer')
  if fields.get('endpoint_source')!='localEOU':reasons.append('endpoint not localEOU')
  if value('main_stall_max') is None or value('main_stall_max')>.100:reasons.append('main stall absent or over unchanged 100ms limit')
  if any(value(k) is None for k in ['L1','L2','L3']):reasons.append('required headline stage absent')
  problems=[x for x in lines if x.startswith('VOICE_LATENCY_WRONG:') and (f'run {i}:' in x or f'turn {i+1} ' in x)]
  if problems: reasons.append('existing per-turn acceptance failed')
  book=next((x for x in lines if x.startswith(f'VOICE_LATENCY_RUN={i} bookkeeping')), '')
  if 'committed=1' not in book or 'firstAudioAcknowledged=true' not in book:reasons.append('commit/audio acknowledgement unavailable')
  rows.append({'run':i,'qualified':not reasons,'reasons':reasons,'fields':fields,'joined_answer_passes':passes,'existing_problems':problems,'endpoint_to_route_done_s':round(value('L2')-value('route_to_first_token'),3) if value('L2') is not None and value('route_to_first_token') is not None else None})
 def stats(key,only_qualified=False):
  values=[]
  for row in rows:
   if only_qualified and not row['qualified']:continue
   try: v=float(row.get('fields',{}).get(key,''))
   except ValueError:continue
   values.append(v)
  values.sort()
  return {'n':len(values),'median':statistics.median(values),'p95_nearest_rank':values[math.ceil(.95*len(values))-1],'min':min(values),'max':max(values)} if values else {'n':0}
 result[label]={'exit':pins['exit'],'markers':[x for x in lines if re.match(r'^[A-Z][A-Z0-9_]*_(OK|FAILED|ABSENT)(?:$|[:= ])',x)],'qualified_count':sum(x['qualified'] for x in rows),'turns':rows,'all_measured':{k:stats(k) for k in ['L1','L2','L3']},'qualified_only':{k:stats(k,True) for k in ['L1','L2','L3']},'apple_synthesis':[x for x in lines if x.startswith('VOICE_DIAGNOSTIC_APPLE_CALLS=')],'unloads':pins['unloads'],'sampled_peak_rss_bytes':pins['peak_rss_sampled'],'sampled_peak_footprint_bytes':pins['peak_footprint_sampled']}
(root/'native-analysis.json').write_text(json.dumps({'scope':'Debug n5 file-fed runs. p95 is nearest-rank (n5 maximum); all-measured includes failed turns explicitly. Qualification requires exact actual answering provider, positive final joined counts, local EOU, complete stages, one committed turn/audio acknowledgement, unchanged 100ms stall bar and existing per-turn acceptance. No normal-use residency rate or hardware causal proof.','arms':result},indent=2)+'\n')
print('VOICE_MINI_NATIVE_ANALYSIS_OK arms='+str(len(result)))
