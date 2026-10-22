"""Private full-file witness; only aggregate counts/digests enter the repo."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys

home = Path.home()
backup = home / 'Library/Application Support/NextNotesReleaseBackups/2026-10-22-main'
support = home / 'Library/Application Support/Next Notes'

def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        while block := stream.read(1024 * 1024):
            result.update(block)
    return result.hexdigest()

def witness(folder):
    return {str(path.relative_to(folder)): dict(bytes=path.stat().st_size, sha256=digest(path))
            for path in sorted(folder.rglob('*')) if path.is_file()}

def preferences():
    run = subprocess.run(['defaults', 'export', 'ai.pivotstudio.nextnotes', '-'], capture_output=True, check=True)
    data = plistlib.loads(run.stdout)
    return dict(keys=len(data), sha256=hashlib.sha256(plistlib.dumps(data, fmt=plistlib.FMT_BINARY, sort_keys=True)).hexdigest())

mode = sys.argv[1]
current = dict(files=witness(support), settings=preferences())
private = backup / 'before.json'
if mode == 'before':
    saved = witness(backup / 'Next Notes')
    assert current['files'] == saved, 'Backup content mismatch; file names retained privately'
    private.write_text(json.dumps(current, sort_keys=True))
    private.chmod(0o600)
    unchanged = True
else:
    original = json.loads(private.read_text())
    unchanged = current == original
    (backup / (mode + '.json')).write_text(json.dumps(current, sort_keys=True))
summary = dict(stage=mode, files=len(current['files']), bytes=sum(x['bytes'] for x in current['files'].values()),
               aggregate_sha256=hashlib.sha256(json.dumps(current, sort_keys=True).encode()).hexdigest(),
               settings_keys=current['settings']['keys'], unchanged=unchanged)
Path(__file__).with_name('owner-' + mode + '.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary))
if not unchanged:
    sys.exit(1)
