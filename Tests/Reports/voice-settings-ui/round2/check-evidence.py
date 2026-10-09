#!/usr/bin/env python3
"""Retain source invariance and normalized inherited diagnostic comparisons, no native runs."""
from pathlib import Path
import hashlib, json, re
report = Path(__file__).resolve().parent
root = report.parents[3]
comparisons = {}
for name in ['voice-delivery', 'duplex', 'voice-conversation', 'concurrent-voice', 'voice-scheduling', 'store-isolation']:
    def diagnostics(path):
        lines = [line for line in path.read_text(errors='replace').splitlines()
                 if 'VOICE_SESSION_DIVERGENCE:' in line or 'TOOLLOOP_PRODUCTION_WRONG:' in line
                 or line.startswith('TOOLLOOP_PRODUCTION_FAILED')]
        # Only generated task/output/turn identifiers differ; retain every state/event/verdict.
        return [re.sub(r'(task|output|turn)#[A-Fa-f0-9]+', r'\1#ID', line) for line in lines]
    baseline = diagnostics(root.parent/'no-apple/Tests/Reports/no-apple/round4'/f'{name}.log')
    current = diagnostics(report/f'{name}.log')
    comparisons[name] = dict(baseline_diagnostics=len(baseline), current_diagnostics=len(current), normalized_equal=baseline == current)
(report/'diagnostic-comparison.json').write_text(json.dumps(comparisons, indent=2)+'\n')
pin = json.loads((report/'build-pin.json').read_text())
mismatches = [name for name, expected in pin['sources'].items() if hashlib.sha256((root/name).read_bytes()).hexdigest() != expected]
(report/'source-invariance.json').write_text(json.dumps(dict(sources=len(pin['sources']), mismatches=mismatches), indent=2)+'\n')
print(json.dumps(dict(comparisons=comparisons, source_mismatches=mismatches)))
