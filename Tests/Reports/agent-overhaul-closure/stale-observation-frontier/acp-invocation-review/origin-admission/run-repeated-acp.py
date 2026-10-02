from pathlib import Path
import hashlib, json, re, subprocess, tempfile

root = Path(__file__).resolve().parents[6]
report = Path(__file__).resolve().parent
manifest = json.loads((report / 'build53-source-manifest.json').read_text())
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
def drift():
    return [f for f, h in manifest.items() if not (root / f).is_file() or sha(root / f) != h]
binary = Path('/Applications/Next Notes.app/Contents/MacOS/NextNotes')
identity = json.loads((report / 'app53-binary.json').read_text())['sha256']
bundle = binary.parents[2]
def bundle_map():
    return {str(p.relative_to(bundle)): sha(p) for p in sorted(bundle.rglob('*')) if p.is_file()}
bundle_before = bundle_map()
assert not drift() and sha(binary) == identity
out_root = Path(tempfile.mkdtemp(prefix='nextnotes-acp-origin-53-repeat-'))
records = []
for index in range(1, 6):
    output = out_root / f'repeat{index}.log'
    stdout = report / f'app53-acp-repeat{index}.stdout'
    with stdout.open('w') as stream:
        result = subprocess.run([str(root / 'Scripts/run-selftest.sh'), '--out', str(output),
                                 '--selftest-acp'], cwd=root, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=240)
    if output.exists():
        (report / f'app53-acp-repeat{index}.log').write_bytes(output.read_bytes())
    text = stdout.read_text() + (output.read_text() if output.exists() else '')
    record = {'run': index, 'exit': result.returncode,
              'markers': re.findall(r'^ACP_(?:OK|FAILED)[^\n]*', text, re.M),
              'originChecks': re.findall(r'ACP_ORIGIN_CHECKS: (\d+)', text),
              'sourceDrift': drift(), 'sameInstalledBinary': sha(binary) == identity,
              'sameInstalledBundle': bundle_map() == bundle_before}
    records.append(record)
    (report / 'app53-repeated-acp-checks.json').write_text(json.dumps(records, indent=2) + '\n')
    print(record, flush=True)
    assert result.returncode == 0 and record['markers'] and all(
        m.startswith('ACP_OK') for m in record['markers']), record
    assert record['originChecks'] and set(record['originChecks']) == {'68'}, record
    assert not record['sourceDrift'] and record['sameInstalledBinary'] and record['sameInstalledBundle']
