from pathlib import Path
import subprocess, tempfile, json
root = Path(__file__).resolve().parents[4]
report = Path(__file__).resolve().parent
checks = json.loads((report/'checks.json').read_text())
with tempfile.TemporaryDirectory(prefix='wrapper-', dir=report) as tmp:
    binary = Path(tmp)/'census-wrapper'
    for name, args in [
        ('wrapper-compile', ['swiftc', '-swift-version', '6', '-parse-as-library', '-module-cache-path', str(Path(tmp)/'module-cache'), str(root/'Sources/NextNotes/Agent/Speech/AgentVoicePolicySelfTest.swift'), str(report/'wrapper-main.swift'), '-o', str(binary)]),
        ('selftest-census-wrapper', [str(binary)]),
    ]:
        proc = subprocess.run(args, capture_output=True, text=True)
        (report/(name+'.log')).write_text(proc.stdout+proc.stderr)
        final = proc.stdout.rstrip().splitlines()[-1] if proc.stdout.rstrip() else 'NO_FINAL_MARKER'
        checks.append({'check': name, 'exit': proc.returncode, 'final': final})
        (report/'checks.json').write_text(json.dumps(checks, indent=2)+'\n')
        print(name, 'exit', proc.returncode, final, flush=True)
        if proc.returncode: raise SystemExit(proc.returncode)
