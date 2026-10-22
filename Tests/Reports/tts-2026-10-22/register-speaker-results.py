"""Register this explicitly selected, incomplete native-clock cohort; never run models."""
from pathlib import Path
import json
import re
import math
import statistics

repo = Path(__file__).resolve().parents[3]
report = Path(__file__).resolve().parent
selected = {engine: report/'speaker-native'/f'{engine}.json'
            for engine in ('apple','pocket','kokoro','phonon')}
selected['qwen'] = report/'speaker-native-calibration/qwen.json'
names = dict(apple='macOS',pocket='Pocket',kokoro='Kokoro',phonon='Phonon31m',qwen='Qwen3-TTS0.6B4bit')
for engine,path in selected.items():
    raw = json.loads(path.read_text())
    measurement = raw.get('measurement',{})
    trials = measurement.get('trials',[])
    warm = [row for row in trials if row['phase']=='warm']
    qualified = [row for row in warm if row['output']['qualified']]
    summary = json.loads((path.parent/'summary.json').read_text())
    measured = raw['status']=='measured' and len(warm)>=30 and len(qualified)==len(warm)
    def metric(name,value,unit,boundary,n,aggregation):
        return dict(name=name,value=value,unit=unit,boundary=boundary,samples=n or None,aggregation=aggregation)
    metrics = [
        metric('Attempted warm microphone trials',len(warm),'trials','Completed warm requests in the retained native report; admission refusals have zero.',len(warm),'count'),
        metric('Qualified warm microphone trials',len(qualified),'trials','Requests passing frozen clock/room/correlation/onset/route gates; not an engine quality score.',len(warm),'count')]
    for key,label in [('firstRenderedMs','Warm first non-silent render'),('estimatedPresentationMs','Warm estimated presentation')]:
        values = [row['output'].get(key) for row in warm]
        if values and all(isinstance(value,(int,float)) for value in values):
            metrics.append(metric(label,statistics.median(values),'ms',
                'Text request → actual post-gain render timestamp' if key=='firstRenderedMs' else 'Render timestamp + queried output-node maximum presentation estimate; not observed sound.',len(values),'median'))
    if measured:
        values = [row['output']['acousticOnsetMs'] for row in warm]
        metrics.append(metric('Warm microphone pickup median',statistics.median(values),'ms','Text request → threshold-qualified correlated microphone pickup.',len(values),'median'))
        metrics.append(metric('Warm microphone pickup p95',sorted(values)[math.ceil(.95*len(values))-1],'ms','Same acoustic boundary; empirical nearest-rank p95,30 trials.',len(values),'nearest-rank p95'))
    cold = next((row for row in trials if row['phase']=='first-after-prepare' and row['output']['qualified']),None)
    if cold:
        metrics.append(metric('First-after-preparation microphone pickup',cold['output']['acousticOnsetMs'],'ms','First text request after preparation → qualified microphone pickup; not hardware-cold.',1,'single observation'))
    if engine=='qwen':
        peaks = [int(value) for value in re.findall(r'Peak:[^\n]*\((\d+)\)',(path.parent/'qwen.log').read_text())]
        if peaks: metrics.append(metric('MLX allocator peak',max(peaks),'bytes','Process-lifetime MLX counter after loading and four synthesised clauses; unified GPU allocation, not additive to RSS.',4,'maximum counter'))
    record = dict(schema_version=1,id=f'2026-10-22-tts-{engine}-speaker-output',
        title=f'{names[engine]}: native speaker-output experiment',date='2026-10-22',category='tts',
        status='measured' if measured else 'partial' if trials else 'blocked',
        scope='Actual production playback backing with native48k mono microphone observation under paced native Parakeet-v3 decoder load. Threshold-qualified arrival, not human perception or full-turn latency.',
        summary=(f'{len(qualified)}/{len(warm)} warm pickups qualified. ' if trials else 'No native-format trial started: disk admission refused. ')+
          ('Complete acoustic median accepted.' if measured else 'No acoustic median or fastest-default decision accepted. Background audio was present; all attempts and refusals remain retained.'),
        environment=dict(hardware='Apple M3 MacBook Air,16GB RAM,256GB storage',os=measurement.get('macOS','macOS27.2(26B5091g); source cohort environment'),
            workload='Paced cached native Parakeet-v3 authored English prefixes,400ms then1s updates; decoder load, not production mic/AEC/EOU integration. Other room/audio sound present.',
            cold_warm=f'One separate first-after-prepare request; {len(warm)} completed varied warm requests, cycling five English phrases. No voice-quality inference.',
            audio_route='Built-in speakers/microphone; native48000Hz mono float32. Source gain0.75. Hardware output38%,input51%,unmuted retained from setup; not audited at each trial boundary.',
            power_thermal='Not continuously sampled or controlled.'),
        provenance=dict(binary_sha256=summary['appSHA256'],model_revision=measurement.get('model','Pinned Phonon31m-CoreML/v0.4.0; no load occurred'),
            command='Tools/tts_compare.py --speaker-output --trials 30 --workload-ready <reference-ASR-ready-file>; Qwen retained diagnostic uses --trials 3. Exact source, binary/probe pins and original attempts are linked in the report.',
            grader='Native host timestamps; two consecutive10ms windows above max(.001RMS,4x room baseline), >=.75 rendered/microphone envelope correlation, strict timestamps/callbacktokens/route/drop gates. No survivor-only acoustic medians.'),
        metrics=metrics,
        limitations=['Background audio prevents a qualified quiet-room ranking; incomplete results do not change the default.',
            'Microphone pickup is threshold-dependent and includes acoustic/input timing; it is not human perceptual onset.',
            'Render and queried presentation estimates are separate component boundaries and do not substitute for physical output.',
            'Global utterance-envelope correlation does not independently prove every earliest transient belongs to the utterance; click/cough, route/format and double-talk controls remain open.',
            'Five English phrases, one route; no general language/voice-quality or production full-duplex/EOU acceptance.',
            'Timestamp regressions in the earlier converted16k collector are retained as superseded evidence; this report uses the native-format observer.'],
        sources=[str(path.relative_to(repo)),str((path.parent/'summary.json').relative_to(repo)),
            'Tests/Reports/tts-2026-10-22/README.md','Tests/Reports/tts-2026-10-22/speaker-native-source-pins.json'],
        publication=dict(approved=True,reviewed_by='Codex TTS: reviewed aggregate-only partial scope; no audio, transcript, private task data or host context in public fields',reviewed_on='2026-10-22'))
    if engine=='qwen':
        record['limitations'].append('Only three warm native diagnostic requests completed; one qualified. The separate30-request cohort was refused at disk admission. MLX peak and RSS measure different accounting domains; no allocator leak/cache fix is claimed.')
        record['sources'] += ['Tests/Reports/tts-2026-10-22/speaker-native/qwen.json','Tests/Reports/tts-2026-10-22/speaker-native-calibration/qwen.log']
    (repo/'Benchmarks/runs'/f"{record['id']}.json").write_text(json.dumps(record,indent=2)+'\n')
