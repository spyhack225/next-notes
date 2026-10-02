#!/usr/bin/env python3
"""Archive completed root-owned evidence; never launch tests, apps or compilers."""
import argparse, hashlib, json, re, shutil
from pathlib import Path
parser = argparse.ArgumentParser()
parser.add_argument('--build', type=int, required=True)
parser.add_argument('--checks', type=Path, required=True)
args = parser.parse_args()
base = Path(__file__).resolve().parent
repo = base.parents[4]
pin = Path(f'/private/tmp/nextnotes-agent-closure-build{args.build}-source-manifest.json')
pinned = json.loads(pin.read_text())
assert pinned['phase'] == 'installed', 'No installed source/binary pin'
summary = json.loads((args.checks / 'summary.json').read_text())
worker = next(row for row in summary if row['flag'] == 'task-worker-attempt')
assert worker['marker'] != 'ABSENT', 'Worker verdict absent'
archive = base / f'current-app{args.build}'
archive.mkdir(exist_ok=True)
files, absent = [], []
def retain(source, name=None):
    if not source.exists():
        absent.append(str(source))
        return
    target = archive / (name or source.name)
    shutil.copyfile(source, target)
    files.append({'source': str(source), 'archive': str(target.relative_to(base)),
                  'sha256': hashlib.sha256(target.read_bytes()).hexdigest(), 'bytes': target.stat().st_size})
retain(pin)
retain(Path(f'/private/tmp/nextnotes-agent-closure-install-{args.build}.log'))
retain(args.checks / 'summary.json')
for row in summary:
    for suffix in ['out', 'log']:
        retain(args.checks / f'selftest-{row["flag"]}.{suffix}')
for path in [
    'Sources/NextNotes/Agent/Tasks/AgentTaskManager.swift',
    'Sources/NextNotes/Agent/Tasks/Durable/TaskDurability.swift',
    'Sources/NextNotes/Agent/Tasks/Durable/TaskWorkerAttemptSelfTest.swift',
    'Sources/NextNotes/Agent/Tasks/Durable/TaskRestorationProductionSelfTest.swift',
    'Sources/NextNotes/Agent/Tasks/AgentTaskStore.swift',
    'Sources/NextNotes/Agent/Tasks/Durable/TaskStore.swift',
    'Sources/NextNotes/Agent/Tasks/Durable/TaskEventJournal.swift',
    'Sources/NextNotes/Agent/ActionRuntime.swift',
    'Sources/NextNotes/Agent/Backend/LocalAgentBackend.swift',
    'Sources/NextNotes/Agent/Tools/AgentToolExecutor.swift',
    'Sources/NextNotes/NextNotesApp.swift']:
    source = repo / path
    assert hashlib.sha256(source.read_bytes()).hexdigest() == pinned['sources'][path], 'Source changed since pin: ' + path
    retain(source, 'installed-' + source.name + '.txt')
count = re.search(r'TASK_WORKER_ATTEMPT_OK: (\d+) cases', worker['marker'])
result = {'status': 'actual completed root-run installed evidence', 'build': args.build,
          'binary_sha256': pinned['installedBinarySHA256'], 'worker': worker,
          'actual_worker_cases': int(count.group(1)) if count else None,
          'checks': summary, 'files': files, 'absent_companions': absent,
          'fixture_sha256': pinned['sources']['Sources/NextNotes/Agent/Tasks/Durable/TaskWorkerAttemptSelfTest.swift'],
          'scope': 'Same-transaction admitted typed-local worker/tool fields only; scripted temp clock; no stale consumer/classification/timer/retry/IM16',
          'aggregate': 'Historical quick13 FAILED3/10; no model verdict for this build supplied'}
(base / f'current-app{args.build}-evidence-manifest.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({'worker': worker, 'actual_cases': result['actual_worker_cases'], 'files': len(files), 'absent': absent}))
