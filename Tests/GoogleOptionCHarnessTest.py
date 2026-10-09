"""Shell-only harness controls. Synthetic executable; no app, compiler or account."""
from pathlib import Path
import os
import subprocess
import tempfile

# Independent names: changing the shell gate to a prefix must fail these controls.
TARGETS = [
 'R1 denied read never runs the runnable alternate login',
 'R2 after-token cancelled send has zero backing entries',
 'R3 outstanding old invalid_grant cannot delete a real successful reconnect',
 'R4 delayed 401 invalidates only rejected A and never cancels refresh B',
 'R5 probing planner excludes known missing Mail permission from allowed and selected tools',
 'R6 actual connect flow enables and lists Calendar only when granted (false)',
]
with tempfile.TemporaryDirectory(prefix='google-c-red-harness-') as folder:
    root = Path(folder)
    binary = root / 'synthetic-check'
    binary.write_text('''#!/bin/sh
out=
marker=GOOGLE_CONNECT_FAILED
while [ "$#" -gt 0 ]; do
 case "$1" in
  --selftest-mac-accounts) marker=MAC_ACCOUNTS_FAILED ;;
  --selftest-task-authority) marker=TASK_AUTHORITY_OK ;;
  --selftest-out) shift; out=$1 ;;
 esac
 shift
done
printf '%s\\n' "$marker" > "$out"
[ "$marker" = TASK_AUTHORITY_OK ] && exit 0
case "$GOOGLE_REVIEW_HARNESS_CASE" in
 target|wrong-exit) echo '  FAIL a rejected client must not read as a revoked grant' >> "$out" ;;
 all-six|five|mixed) cat "$GOOGLE_REVIEW_TARGETS" >> "$out" ;;
 setup) for n in 1 2 3 4 5 6; do echo "  FAIL R$n fixture written" >> "$out"; done ;;
 broad) for n in 1 2 3 4 5 6; do echo "  FAIL R$n targeted producer regression" >> "$out"; done ;;
 *) echo '  FAIL unrelated assertion' >> "$out" ;;
esac
[ "$GOOGLE_REVIEW_HARNESS_CASE" = wrong-exit ] && exit 0
exit 1
''')
    binary.chmod(0o755)
    targets = root / 'targets'
    for mode, case, expected in [('review-red', 'setup', 1), ('review-red', 'broad', 1),
                                 ('revocation', 'target', 0), ('revocation', 'wrong-exit', 1),
                                 ('revocation', 'unrelated', 1), ('review-red', 'all-six', 0),
                                 ('review-red', 'five', 1)]:
        targets.write_text('\n'.join('  FAIL ' + t for t in (TARGETS[:-1] if case == 'five' else TARGETS)) + '\n')
        env = dict(os.environ, GOOGLE_REVIEW_HARNESS_CASE=case, GOOGLE_REVIEW_TARGETS=str(targets))
        result = subprocess.run(['sh', 'Tests/GoogleOptionCChecks.sh', mode, str(binary), str(root / (mode + '-' + case))],
                                env=env, capture_output=True)
        assert result.returncode == expected, (mode, case, result.returncode, 'setup failures must never satisfy RED')
    # Each finding independently refuses setup even with the other five real failures.
    for index in range(6):
        mixed = list(TARGETS)
        mixed[index] = 'R' + str(index + 1) + ' fixture written'
        targets.write_text('\n'.join('  FAIL ' + t for t in mixed) + '\n')
        result = subprocess.run(['sh', 'Tests/GoogleOptionCChecks.sh', 'review-red', str(binary),
                                 str(root / ('mixed-' + str(index)))],
                                env=dict(os.environ, GOOGLE_REVIEW_HARNESS_CASE='mixed',
                                         GOOGLE_REVIEW_TARGETS=str(targets)), capture_output=True)
        assert result.returncode == 1, ('finding', index + 1, 'setup incorrectly satisfied RED')
    # Setup errors must not satisfy any of the other RED modes either.
    for mode in ['revocation', 'unpinned', 'draft-red', 'withdrawal-red', 'remaining-red', 'calendar-list-red', 'original', 'mailbox']:
        result = subprocess.run(['sh', 'Tests/GoogleOptionCChecks.sh', mode, str(binary), str(root / ('setup-' + mode))],
                                env=dict(os.environ, GOOGLE_REVIEW_HARNESS_CASE='setup'), capture_output=True)
        assert result.returncode == 1, (mode, 'setup incorrectly satisfied RED')
    held_targets = ['R6 held ' + route + ' drops old list completion after account transition'
                    for route in ['withdrawal', 'disconnect', 'reconnect', 'replacement',
                                  'failed-replacement', 'service-withdrawal', 'service-disconnect']]
    for omit in [None] + list(range(len(held_targets))):
        selected = [target for index, target in enumerate(held_targets) if index != omit]
        targets.write_text('\n'.join('  FAIL ' + t for t in selected) + '\n')
        result = subprocess.run(['sh', 'Tests/GoogleOptionCChecks.sh', 'calendar-list-red', str(binary),
                                 str(root / ('held-' + str(omit)))],
                                env=dict(os.environ, GOOGLE_REVIEW_HARNESS_CASE='all-six',
                                         GOOGLE_REVIEW_TARGETS=str(targets)), capture_output=True)
        assert result.returncode == (0 if omit is None else 1), ('held list', omit, 'requires every named failure')
print('GOOGLE_RED_HARNESS_OK: exact named behavior and exit1; setup and broad prefixes rejected')
