from pathlib import Path
import hashlib, json, re, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[5]
report = Path(__file__).resolve().parent
build = int(sys.argv[1])
flags = sys.argv[2:] or ['task-worker-attempt']
manifest = json.loads((report / f'build{build}-source-manifest.json').read_text())
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
def drift():
    return [f for f, h in manifest.items() if not (root / f).is_file() or sha(root / f) != h]
assert not drift(), drift()
binary = Path('/Applications/Next Notes.app/Contents/MacOS/NextNotes')
identity = sha(binary)
bundle = binary.parents[2]
def bundle_map():
    return {str(p.relative_to(bundle)): sha(p) for p in sorted(bundle.rglob('*')) if p.is_file()}
bundle_before = bundle_map()
(report / f'app{build}-bundle-before.json').write_text(json.dumps(bundle_before, indent=2) + '\n')
cache = Path.home() / f'Library/Caches/NextNotesBuild/agent-closure-app{build}-NextNotes'
shutil.copy2(binary, cache)
metadata = {'build': build, 'sha256': identity, 'cache': str(cache), 'sourceDrift': drift()}
(report / f'app{build}-binary.json').write_text(json.dumps(metadata, indent=2) + '\n')
Path(f'/tmp/nextnotes-agent-closure-app{build}-binary.json').write_text(json.dumps(metadata, indent=2) + '\n')
shutil.copy2(f'/tmp/nextnotes-agent-closure-build{build}.log', report / f'build{build}.log')
out_root = Path(tempfile.mkdtemp(prefix=f'nextnotes-acp-origin-{build}-'))
results = []
for flag in flags:
    stdout = report / f'app{build}-{flag}.stdout'
    app_log = out_root / (flag + '.log')
    with stdout.open('w') as output:
        result = subprocess.run([str(root / 'Scripts/run-selftest.sh'), '--out', str(app_log),
                                 '--selftest-' + flag], cwd=root, stdout=output,
                                stderr=subprocess.STDOUT, timeout=240)
    if app_log.exists():
        shutil.copy2(app_log, report / f'app{build}-{flag}.log')
    text = stdout.read_text() + (app_log.read_text() if app_log.exists() else '')
    markers = re.findall(r'^[A-Z][A-Z0-9_]*_(?:OK|FAILED)[^\n]*', text, re.M)
    marker = markers[-1] if markers else 'ABSENT'
    record = {'flag': flag, 'exit': result.returncode, 'marker': marker,
              'originChecks': re.findall(r'ACP_ORIGIN_CHECKS: (\d+)', text),
              'sourceDrift': drift(), 'sameInstalledBinary': sha(binary) == identity}
    results.append(record)
    (report / f'app{build}-checks.json').write_text(json.dumps(results, indent=2) + '\n')
    print(record, flush=True)
    assert not record['sourceDrift'] and record['sameInstalledBinary']
    assert bundle_map() == bundle_before, 'Installed bundle changed during native check'
    if build in (63, 65):
        assert flag == 'task-worker-attempt' and result.returncode == 1 and 'TASK_WORKER_ATTEMPT_FAILED' in marker
    else:
        assert result.returncode == 0 and '_OK' in marker and not re.search(
            r'^[A-Z][A-Z0-9_]*_FAILED', text, re.M), record
(report / f'app{build}-bundle-after.json').write_text(json.dumps(bundle_map(), indent=2) + '\n')
print('Native checks completed; pinned Sources and binary unchanged.', flush=True)
