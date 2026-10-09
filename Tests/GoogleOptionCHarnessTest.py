"""Shell-only harness negatives. Synthetic executable; no app, compiler or account."""
from pathlib import Path
import os
import subprocess
import tempfile

with tempfile.TemporaryDirectory(prefix='google-c-red-harness-') as folder:
    root = Path(folder)
    binary = root / 'synthetic-check'
    binary.write_text('''#!/bin/sh
out=
while [ "$#" -gt 0 ]; do
 if [ "$1" = --selftest-out ]; then shift; out=$1; fi
 shift
done
printf 'GOOGLE_CONNECT_FAILED\\n' > "$out"
case "$GOOGLE_REVIEW_HARNESS_CASE" in
 target|wrong-exit) echo '  FAIL a rejected client must not read as a revoked grant' >> "$out" ;;
 all-six) for n in 1 2 3 4 5 6; do echo "  FAIL R$n targeted producer regression" >> "$out"; done ;;
 five) for n in 1 2 3 4 5; do echo "  FAIL R$n targeted producer regression" >> "$out"; done ;;
 *) echo '  FAIL unrelated assertion' >> "$out" ;;
esac
[ "$GOOGLE_REVIEW_HARNESS_CASE" = wrong-exit ] && exit 0
exit 1
''')
    binary.chmod(0o755)
    for mode, case, expected in [('revocation', 'target', 0), ('revocation', 'wrong-exit', 1),
                                 ('revocation', 'unrelated', 1), ('review-red', 'all-six', 0),
                                 ('review-red', 'five', 1)]:
        env = dict(os.environ, GOOGLE_REVIEW_HARNESS_CASE=case)
        result = subprocess.run(['sh', 'Tests/GoogleOptionCChecks.sh', mode, str(binary), str(root / case)],
                                env=env, capture_output=True)
        assert result.returncode == expected, (mode, case, result.returncode)
print('GOOGLE_RED_HARNESS_OK: targeted assertion plus native exit1 required')
