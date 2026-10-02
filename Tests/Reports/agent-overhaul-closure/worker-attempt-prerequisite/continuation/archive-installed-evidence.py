#!/usr/bin/env python3
"""Copy completed root-owned evidence only; no compiler, app or test invocation."""
import argparse, hashlib, json, shutil
from pathlib import Path
parser = argparse.ArgumentParser()
parser.add_argument('--build', type=int, required=True)
parser.add_argument('--checks', type=Path, required=True)
args = parser.parse_args()
base = Path(__file__).resolve().parent
repo = base.parents[4]
pin = Path(f'/private/tmp/nextnotes-agent-closure-build{args.build}-source-manifest.json')
manifest = json.loads(pin.read_text())
assert manifest['phase'] == 'installed', 'Installed source/binary pin absent'
summary = json.loads((args.checks / 'summary.json').read_text())
restoration = next(row for row in summary if row['flag'] == 'task-restoration')
assert restoration['marker'] != 'ABSENT', 'No actual restoration verdict'
archive = base / f'installed-app{args.build}'
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
    'Sources/NextNotes/Agent/Tasks/Durable/TaskRestorationProductionSelfTest.swift',
    'Sources/NextNotes/Agent/Tasks/Durable/TaskWorkerAttemptSelfTest.swift',
    'Sources/NextNotes/Agent/Tasks/AgentTaskManager.swift',
    'Sources/NextNotes/Agent/Tasks/AgentTaskStore.swift',
    'Sources/NextNotes/Agent/Tasks/Durable/TaskStore.swift',
    'Sources/NextNotes/Agent/Tasks/Durable/TaskEventJournal.swift',
    'Sources/NextNotes/Agent/Backend/LocalAgentBackend.swift',
    'Sources/NextNotes/Agent/Tools/AgentToolExecutor.swift',
    'Sources/NextNotes/NextNotesApp.swift']:
    source = repo / path
    assert hashlib.sha256(source.read_bytes()).hexdigest() == manifest['sources'][path], 'Source changed after pin: ' + path
    retain(source, 'installed-' + source.name + '.txt')
result = {'status': 'actual completed root-run installed evidence', 'build': args.build,
          'binary_sha256': manifest['installedBinarySHA256'], 'restoration': restoration,
          'checks': summary, 'files': files, 'absent_companions': absent,
          'scope': 'Continuation metadata and stale-context delta to existing actual read/write fixtures; no replacement handle coexistence/process crash/heartbeat/remote host claim',
          'aggregate': 'Latest quick13 FAILED3/10 is historical, not a model verdict for this build'}
(base / f'installed-app{args.build}-evidence-manifest.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({'build': args.build, 'restoration': restoration, 'files': len(files), 'absent': absent}))
