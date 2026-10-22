"""Read-only owner-log extraction. Never exports meeting or transcript content."""
import csv
import hashlib
import json
import pathlib
import re

OUT = pathlib.Path(__file__).resolve().parent
ROOT = OUT.parents[3]
DATA = pathlib.Path.home() / 'Library/Application Support/Next Notes'

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()

inventory = []
for path in (DATA / 'Meetings').glob('*/meeting.json'):
    meeting = json.loads(path.read_text())
    entry = {key: meeting.get(key) for key in (
        'id', 'start', 'end', 'status', 'captureIntegrity', 'audioIsTemporary',
        'audioReleaseAfter', 'notesModel', 'providerID')}
    entry['audio_files'] = [{ 'name': p.name, 'bytes': p.stat().st_size }
                            for p in path.parent.iterdir() if p.suffix in ('.caf', '.wav')]
    entry['notes_present'] = (path.parent / 'notes.json').exists()
    entry['transcript_segments'] = {}
    for name in ('transcript.json', 'transcript.live.json'):
        p = path.parent / name
        if p.exists():
            value = json.loads(p.read_text())
            entry['transcript_segments'][name] = len(value) if isinstance(value, list) else None
    inventory.append(entry)
(OUT / 'meeting-inventory.json').write_text(json.dumps(sorted(inventory, key=lambda x: x['start']), indent=2) + '\n')

rows = []
for line in (DATA / 'metrics.jsonl').open():
    value = json.loads(line)
    ended = value.get('endedAt', '')
    if value.get('pipeline') != 'meeting' or not (
        '2026-10-06T19:48:40Z' <= ended <= '2026-10-06T19:50:00Z' or
        '2026-10-07T14:05:34Z' <= ended <= '2026-10-07T14:07:00Z'):
        continue
    row = {key: value.get(key) for key in ('name', 'startedAt', 'endedAt', 'durationSeconds')}
    row.update({key: value.get('process', {}).get(key) for key in (
        'physicalFootprintBytes', 'residentMemoryBytes', 'peakResidentMemoryBytes', 'hostUptime')})
    # Only this known numeric resource note is safe to export.
    if value.get('name') == 'meeting.resources':
        row.update(dict(re.findall(r'(\w+)=(-?\d+|normal|warning|critical|unknown)', value.get('note', ''))))
    rows.append(row)
rows.sort(key=lambda x: x['endedAt'])
(OUT / 'incident-metrics.json').write_text(json.dumps(rows, indent=2) + '\n')
fields = list(dict.fromkeys(k for row in rows for k in row))
with (OUT / 'incident-metrics.csv').open('w') as stream:
    writer = csv.DictWriter(stream, fieldnames=fields)
    writer.writeheader()
    writer.writerows(rows)

sources = [
    'Meetings/MeetingSession.swift', 'Meetings/MeetingAudioWriter.swift',
    'Meetings/ChunkedTranscriber.swift', 'Meetings/MeetingResourceHealth.swift',
    'Meetings/MeetingResourceLiveProbe.swift', 'Meetings/MeetingContextStore.swift',
    'Meetings/MeetingPipeline.swift', 'Meetings/FinalTranscriptService.swift',
    'Meetings/DiarizationService.swift', 'Meetings/NotesGenerator.swift',
    'Core/SystemAudioCapture.swift', 'Core/AudioCaptureHub.swift', 'Core/AudioConversion.swift',
    'Core/Compute/ModelResidencyPolicy.swift', 'Core/Compute/ComputeScheduler.swift',
    'Knowledge/Files/FileIndexer.swift', 'UI/Meetings/MeetingLiveView.swift',
    'UI/Meetings/TranscriptView.swift', 'UI/Components/ThinkingOrbs/ThinkingOrb.swift',
    'UI/Components/ThinkingOrbs/OrbGeometry.swift', 'UI/Components/DottedField.swift',
    'UI/Components/LevelMeter.swift', 'UI/Components/RecordingIndicator.swift',
]
pins = {name: digest(ROOT / 'Sources/NextNotes' / name) for name in sources}
pins['installed executable'] = digest(pathlib.Path('/Applications/Next Notes.app/Contents/MacOS/NextNotes'))
(OUT / 'source-pins.json').write_text(json.dumps(pins, indent=2) + '\n')

log = pathlib.Path('/tmp/nextnotes-meeting-20261007-owned.log')
if log.exists():
    drops = [line for line in log.read_text().splitlines() if 'capture delivery backlog full' in line]
    summary = {'capture_backlog_errors': len(drops), 'query_local_time_start': '2026-10-07 10:06:00',
               'query_local_time_end': '2026-10-07 10:07:00',
               'first_error_local_time': drops[0][:23] if drops else None,
               'last_error_local_time': drops[-1][:23] if drops else None}
    (OUT / 'unified-log-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(f'Exported metadata for {len(inventory)} meetings and {len(rows)} incident metrics; no speech, titles, or attendees.')
