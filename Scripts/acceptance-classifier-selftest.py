#!/usr/bin/env python3
"""Same retained-log classifier regression; never invokes the app or model."""
import argparse, json, re, subprocess, tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--script', type=Path, default=Path(__file__).with_name('acceptance.sh'),
                        help='acceptance producer; defaults to this repo’s Scripts/acceptance.sh')
    parser.add_argument('--fixture', type=Path,
                        default=Path(__file__).resolve().parent.parent / 'Tests/Fixtures/acceptance/native-tools-retained.log')
    parser.add_argument('--report', type=Path, help='optional JSON accounting report outside the fixture')
    args = parser.parse_args()
    text = args.script.read_text()
    functions = []
    for name in ['is_precondition_absence', 'classify']:
        match = re.search(r'^' + name + r'\(\) \{\n.*?^\}', text, re.M | re.S)
        if not match: raise RuntimeError('Actual acceptance classifier missing.')
        functions.append(match.group())
    command = '\n'.join(functions) + '\nclassify "" "$1" "$2"\nprintf "%s\\n%s\\n" "$VERDICT" "$REASON"\n'
    retained = args.fixture.read_text()
    assert '0/4 tool prompts called something' in retained
    assert 'NATIVE_TOOLS_CLOUD_ABSENT:' in retained and 'NATIVE_TOOLS_FAILED: 1 problem(s)' in retained
    cases = [
        ('actual-native-tools-failure', retained, 1, 'FAIL', 'NATIVE_TOOLS_FAILED'),
        ('optional-backend-absent-only', 'NATIVE_TOOLS_CLOUD_ABSENT: no cloud permission\n', 0, 'SKIP', 'NATIVE_TOOLS_CLOUD_ABSENT'),
        ('named-missing-precondition', 'WAKE_LIVE_MODEL_MISSING: unavailable\n', 1, 'SKIP', 'WAKE_LIVE_MODEL_MISSING'),
        ('failure-before-backend-absence', 'NATIVE_TOOLS_FAILED: local failure\nNATIVE_TOOLS_CLOUD_ABSENT: no cloud permission\n', 1, 'FAIL', 'NATIVE_TOOLS_FAILED'),
        ('optional-backend-absent-then-success', 'NATIVE_TOOLS_CLOUD_ABSENT: no cloud permission\nNATIVE_TOOLS_OK\n', 0, 'PASS', 'NATIVE_TOOLS_OK'),
        ('ordinary-failure-before-later-ok', 'NATIVE_TOOLS_FAILED: local failure\nNATIVE_TOOLS_OK\n', 1, 'FAIL', 'NATIVE_TOOLS_FAILED'),
    ]
    results = []
    with tempfile.TemporaryDirectory(prefix='acceptance-classifier-') as temporary:
        for index, (name, content, code, expected, reason_marker) in enumerate(cases):
            log = Path(temporary) / f'{index}.log'; log.write_text(content)
            process = subprocess.run(['bash', '-c', command, 'classify', str(log), str(code)], text=True, capture_output=True, check=True)
            verdict, _, reason = process.stdout.partition('\n')
            passed = verdict.strip() == expected and reason_marker in reason
            results.append({'case': name, 'expected': expected, 'actual': verdict.strip(), 'reason': reason.strip(), 'pass': passed})
    failures = sum(not row['pass'] for row in results)
    result = {'script': str(args.script), 'nativeInvocations': 0, 'failureCount': failures,
              'temporaryRootRemoved': not Path(temporary).exists(), 'cases': results}
    if args.report: args.report.write_text(json.dumps(result, indent=2) + '\n')
    for row in results: print(row['case'] + ': ' + row['actual'] + (' PASS' if row['pass'] else ' WRONG'))
    print('ACCEPTANCE_CLASSIFIER_' + ('FAILED' if failures else 'OK') + f': {failures} problem(s)')
    return 1 if failures else 0


if __name__ == '__main__':
    raise SystemExit(main())
