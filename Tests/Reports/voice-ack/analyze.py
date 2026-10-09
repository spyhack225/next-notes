#!/usr/bin/env python3
"""Retain counted native rows and distributions; no missing values become zero."""
import hashlib,json,math,re,statistics
from pathlib import Path
report=Path(__file__).parent
result={}
for label in ['before-no-ack','after-ack','before-no-ack-final','after-ack-final']:
 log=report/(label+'.log')
 if not log.exists(): continue
 lines=log.read_text().splitlines()
 rows=[]
 for line in lines:
  m=re.match(r'VOICE_LATENCY_RUN=(\d+) speech_end_to_eou=',line)
  if not m or int(m[1])==0: continue
  row={'run':int(m[1])}
  for key,value in re.findall(r'(\w+)=([^ ]+)',line):
   if key in ['ACK','L1','L2','L3','speech_end_to_endpoint','speech_end_to_eou','eou_to_endpoint','main_stall_max','clause_to_first_pcm','first_pcm_to_audible']:
    try: row[key]=float(value)
    except ValueError: row[key]=None
  rows.append(row)
 distributions={}
 for col in ['ACK','L1','L2','L3','speech_end_to_endpoint','speech_end_to_eou','eou_to_endpoint','main_stall_max']:
  values=sorted(r[col] for r in rows if r.get(col) is not None)
  if values: distributions[col]={'median':statistics.median(values),'p95':values[max(0,math.ceil(len(values)*.95)-1)],'min':min(values),'max':max(values),'n':len(values),'units':'s','precision':'printed 0.001s'}
 result[label]={'rows':rows,'distributions':distributions,'final_marker':lines[-1] if lines else None,'ack_column_present':any(' ACK=' in x or x.startswith('VOICE_LATENCY_LISTEN ACK ') for x in lines), 'gate_lines':[l for l in lines if l.startswith(('VOICE_ACK_GATE=','VOICE_ACK_APPLE_SYNTHESIS_CALLS=','VOICE_DIAGNOSTIC_APPLE_CALLS='))]}
fixture=Path('Sources/NextNotes/Agent/Voice/VoiceAcknowledgementSelfTest.swift')
result['original_scripted_fixture_sha256']=hashlib.sha256(fixture.read_bytes()).hexdigest()
result['original_scripted_fixture_unchanged']=result['original_scripted_fixture_sha256']=='127b39cea63b5ba723e39428188082828b47f36c03c9fe47d7cc0a233e4a7fd7'
result['status']=(report/'batch-status.txt').read_text().splitlines() if (report/'batch-status.txt').exists() else []
(report/'native-analysis.json').write_text(json.dumps(result,indent=2)+'\n')
for label,v in result.items():
 if isinstance(v,dict) and 'distributions' in v:
  print(label,v['final_marker'])
  for col,d in v['distributions'].items(): print(col,d)
