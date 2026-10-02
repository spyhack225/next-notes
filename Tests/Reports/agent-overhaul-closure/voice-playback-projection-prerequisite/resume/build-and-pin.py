from pathlib import Path
import hashlib, json, subprocess, sys
root = Path(__file__).resolve().parents[5]
report = Path(__file__).resolve().parent
build = int(sys.argv[1])
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
def source_map():
    files = list((root / 'Sources').rglob('*')) + list((root / 'Resources').rglob('*'))
    files += [root / name for name in ('Makefile', 'Package.swift', 'Package.resolved')]
    return {str(p.relative_to(root)): sha(p) for p in sorted(files) if p.is_file()}
manifest = source_map()
encoded = json.dumps(manifest, indent=2) + '\n'
(report / f'build{build}-source-manifest.json').write_text(encoded)
Path(f'/tmp/nextnotes-agent-closure-build{build}-source-manifest.json').write_text(encoded)
log = Path(f'/tmp/nextnotes-agent-closure-build{build}.log')
with log.open('w') as output:
    result = subprocess.run(['make', 'install', 'OPEN=0'], cwd=root, stdout=output, stderr=subprocess.STDOUT)
after = source_map()
drift = [p for p in manifest.keys() | after.keys() if manifest.get(p) != after.get(p)]
print(json.dumps({'build':build, 'exit': result.returncode, 'sourceEntries':len(manifest), 'sourceDrift':drift}), flush=True)
assert result.returncode == 0 and not drift, log.read_text()[-9000:]
