#!/usr/bin/env python3
"""Select a producer correction only from the actual confined native trace."""
import hashlib,json,re,shutil,sys
from pathlib import Path
r=Path('Tests/Reports/voice-ack')
lines=(r/(sys.argv[1] if len(sys.argv)>1 else 'native-clips-red.log')).read_text().splitlines()
selection_lines=[v for v in lines if v.startswith('VOICE_ACK_NATIVE_SELECTION ')]
assert len(selection_lines)==1, 'require exact actual selected native voice'
selection=dict(re.findall(r'(\w+)=([^ ]+)',selection_lines[0]))
assert selection['engine']=='pocket', 'Pocket comparison requires Pocket input'
rows=[]
for line in lines:
    if line.startswith('VOICE_ACK_NATIVE_CLIP '):
        row=dict(re.findall(r'(\w+)=([^ ]+)',line))
        rows.append({**row,**{k:int(row[k]) for k in ['index','raw_samples','body_samples']},'rate':float(row['rate'])})
assert len(rows)==4 and [v['index'] for v in rows]==list(range(4)), 'require all four actual native candidates'
assert all(v['finite']=='true' and v['rate']==24000 for v in rows), 'do not repair native model failures by accepting invalid PCM'
assert any(v['original_bound_ok']=='false' for v in rows[:2]), 'require actual original clip refusal'
shutil.copyfile(r/'native-artifact-pins.json',r/'native-clips-original-artifact-pins.json')
(r/'native-clips-original-source-pins.json').write_text(json.dumps(json.loads((r/'native-artifact-pins.json').read_text())['source_sha256'],indent=2)+'\n')
p=Path('Sources/NextNotes/Agent/Voice/VoiceAcknowledgementClips.swift');s=p.read_text()
padding=[v for v in rows[:2] if v['raw_samples']>48000 and 0<v['body_samples']<=48000]
if padding and all(0<v['body_samples']<=48000 for v in rows[:2]):
    # Keep the same two phrases. The native producer includes extra padding;
    # bound collection separately from the unchanged short prepared-clip bound.
    old='24_000 * (traceOnly ? 4 : 2)'
    assert s.count(old)==1
    s=s.replace(old,'24_000 * 4',1)
    old='audio.samples.count <= 48_000,'
    assert s.count(old)==1
    s=s.replace(old,'audio.samples.count <= 96_000,',1)
    old='let last = audio.samples.lastIndex(where: { abs($0) > 0.0001 }),'
    assert s.count(old)==1
    s=s.replace(old,old+'\n              last - first + 1 <= 48_000,',1)
    decision='separate bounded raw native padding from unchanged two-second prepared body; same phrases'
else:
    phrases=['Mm.','Okay.','Got it.','One sec.']
    accepted=[phrases[v['index']] for v in rows if v['original_bound_ok']=='true']
    assert len(accepted)>=2, 'no pair of bounded native clips; leave producer unchanged'
    old='static let texts = ["Mm.", "Okay."]'
    assert s.count(old)==1
    s=s.replace(old,'static let texts = '+json.dumps(accepted[:2]),1)
    decision='replace refused native phrase with two measured bounded courtesy phrases; native phrase quality upstream remains open'
assert s.count('ack-v1/')==1
s=s.replace('ack-v1/','ack-v2/',1)
p.write_text(s)
(r/'native-clip-producer-decision.json').write_text(json.dumps({'actual_selection':selection,'actual_rows':rows,'decision':decision},indent=2)+'\n')
p=r/'green-source-before.json';d=json.loads(p.read_text());p.write_text(json.dumps({k:hashlib.sha256(Path(k).read_bytes()).hexdigest() for k in d},indent=2)+'\n')
