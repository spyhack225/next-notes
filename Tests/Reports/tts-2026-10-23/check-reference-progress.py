"""Audit actual native RPC progress against retained TTS request host clocks."""
import ctypes
import json
from pathlib import Path

class Timebase(ctypes.Structure):
    _fields_ = [('numer',ctypes.c_uint32),('denom',ctypes.c_uint32)]
tb=Timebase()
assert ctypes.CDLL(None).mach_timebase_info(ctypes.byref(tb)) == 0
seconds_per_tick=tb.numer/tb.denom/1e9
root=Path(__file__).resolve().parent/'serial-speaker'
result={'machTimebase':{'numer':tb.numer,'denom':tb.denom},'scope':'Completed authored native RPC responses during each TTS request, not selected-ASR/EOU/AEC acceptance. No transcript text exported.','engines':{}}
for engine in ['qwen','apple','phonon','pocket','kokoro']:
    row=json.loads((root/f'{engine}.json').read_text())
    trials=row.get('measurement',{}).get('trials',[])
    trace=root/f'reference-{engine}'/'rpc.json.diagnostic.json'
    requests=json.loads(trace.read_text()).get('requests',[]) if trace.exists() else []
    responses=[r['received_at'] for r in requests if isinstance(r.get('received_at'),(int,float))]
    intervals=[]
    for trial in trials:
        start=trial['output']['requestHost']*seconds_per_tick
        end=start+trial['completionMs']/1000
        within=[t for t in responses if start<=t<=end]
        points=[start,*within,end]
        intervals.append({'index':trial['index'],'phase':trial['phase'],'responsesDuringRequest':len(within),'maxGapSeconds':max(b-a for a,b in zip(points,points[1:]))})
    result['engines'][engine]={'completedResponses':len(responses),'allTimedRequestsHaveResponses':all(t['responsesDuringRequest']>0 for t in intervals) if intervals else None,'trials':intervals}
(root/'reference-progress-audit.json').write_text(json.dumps(result,indent=2)+'\n')
for engine,row in result['engines'].items():print(engine,row['completedResponses'],row['allTimedRequestsHaveResponses'],max((t['maxGapSeconds'] for t in row['trials']),default=None))
