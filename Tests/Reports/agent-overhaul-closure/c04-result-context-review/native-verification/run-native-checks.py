from pathlib import Path
import hashlib, json, re, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[5]
report = Path(__file__).resolve().parent
build = int(sys.argv[1])
flags = sys.argv[2:] or ['c04-result-context']
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
out_root = Path(tempfile.mkdtemp(prefix=f'nextnotes-c04-result-context-{build}-'))
prior_records = report / f'app{build}-checks.json'
results = json.loads(prior_records.read_text()) if prior_records.exists() else []
for flag in flags:
    fixture_args = ['--c04-fixture-now', (report / 'fixture-now.txt').read_text().strip()] if flag == 'c04-result-context' else []
    stdout = report / f'app{build}-{flag}.stdout'
    app_log = out_root / (flag + '.log')
    with stdout.open('w') as output:
        result = subprocess.run([str(root / 'Scripts/run-selftest.sh'), '--out', str(app_log),
                                 '--selftest-' + flag, *fixture_args], cwd=root, stdout=output,
                                stderr=subprocess.STDOUT, timeout=240)
    if app_log.exists():
        shutil.copy2(app_log, report / f'app{build}-{flag}.log')
    text = stdout.read_text() + (app_log.read_text() if app_log.exists() else '')
    markers = re.findall(r'^[A-Z][A-Z0-9_]*_(?:OK|FAILED)[^\n]*', text, re.M)
    app_markers = re.findall(r'^[A-Z][A-Z0-9_]*_(?:OK|FAILED)[^\n]*', app_log.read_text() if app_log.exists() else '', re.M)
    marker = app_markers[-1] if app_markers else (markers[-1] if markers else 'ABSENT')
    record = {'flag': flag, 'exit': result.returncode, 'marker': marker,
              'originChecks': re.findall(r'ACP_ORIGIN_CHECKS: (\d+)', text),
              'sourceDrift': drift(), 'sameInstalledBinary': sha(binary) == identity}
    results.append(record)
    (report / f'app{build}-checks.json').write_text(json.dumps(results, indent=2) + '\n')
    print(record, flush=True)
    assert not record['sourceDrift'] and record['sameInstalledBinary']
    assert bundle_map() == bundle_before, 'Installed bundle changed during native check'
    if build == 105 and flag == 'c04-result-context':
        assert result.returncode == 1 and marker == 'C04_RESULT_CONTEXT_FAILED 4/84', record
        wrong = re.findall(r'^C04_RESULT_CONTEXT_FAILURE ([^\n]*)', stdout.read_text(), re.M)
        assert wrong == [name + '/C07-mail-body-admission' for name in (
            'refusal-8192', 'claim-8192', 'refusal-32768', 'claim-32768')], wrong
        assert len(re.findall(r'^C04_RESULT_CONTEXT_CHECK ', stdout.read_text(), re.M)) == 84
    else:
        assert result.returncode == 0 and '_OK' in marker and not re.search(
            r'^[A-Z][A-Z0-9_]*_FAILED', text, re.M), record
(report / f'app{build}-bundle-after.json').write_text(json.dumps(bundle_map(), indent=2) + '\n')
print('Native checks completed; pinned Sources and binary unchanged.', flush=True)
