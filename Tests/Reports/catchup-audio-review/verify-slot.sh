#!/bin/bash
set -u
scratch=/Users/sergekadjo/Library/Caches/NextNotesBuild/wt-scratch/catchup-audio
reports=Tests/Reports/catchup-audio-review
make webrtc-audio || exit $?
python3 - <<'PYPATH'
from pathlib import Path
import subprocess
paths=set(subprocess.check_output(['git','diff','--name-only','--','Sources']).decode().splitlines())
for patch in Path('Tests/Reports/catchup-audio-review').glob('fix-*.patch'):
    paths.update(line.removeprefix('+++ b/') for line in patch.read_text().splitlines() if line.startswith('+++ b/'))
paths.update(str(p) for p in Path('Sources/NextNotes/UI/CatchUp').glob('*SelfTest.swift'))
Path('Tests/Reports/catchup-audio-review/source-paths.txt').write_text('\n'.join(sorted(paths))+'\n')
PYPATH
xargs shasum -a 256 < "$reports/source-paths.txt" > "$reports/red-sources.sha256"
swift build -c debug -j 2 --scratch-path "$scratch" > "$reports/red-build.log" 2>&1 || exit $?
shasum -a 256 "$scratch/debug/NextNotes" > "$reports/red-binary.sha256"
shasum -a 256 Sources/NextNotes/UI/CatchUp/CatchUp*SelfTest.swift > "$reports/fixtures.sha256"
python3 - <<'PYHASH' > "$reports/wake-fixture.sha256"
from pathlib import Path
import hashlib
s=Path('Sources/NextNotes/Activation/WakeWord/WakeWordAudioMonitor.swift').read_text().split('    /// Same AudioCaptureHub subscription/callback/detection consumer;')[1]
print(hashlib.sha256(s.encode()).hexdigest())
PYHASH
"$scratch/debug/NextNotes" --selftest-catch-up --selftest-out "$TMPDIR/catchup-review-red.log" > "$reports/red.log" 2>&1
red=$?
printf 'RED EXIT=%s\n' "$red" > "$reports/exits.txt"
[ "$red" -ne 0 ] || exit 1
for name in ACCEPTANCE WAKE PERMISSION PROVENANCE; do
    rg -q "^CATCH_UP_${name}_FAILED" "$reports/red.log" || exit 1
done
for number in 1 2 3 4; do
    git apply "$reports/fix-$number.patch" || exit $?
done
swift build -c debug -j 2 --scratch-path "$scratch" > "$reports/fixed-build.log" 2>&1 || exit $?
shasum -a 256 -c "$reports/fixtures.sha256" || exit $?
python3 - <<'PYHASH' || exit $?
from pathlib import Path
import hashlib
s=Path('Sources/NextNotes/Activation/WakeWord/WakeWordAudioMonitor.swift').read_text().split('    /// Same AudioCaptureHub subscription/callback/detection consumer;')[1]
assert hashlib.sha256(s.encode()).hexdigest() == Path('Tests/Reports/catchup-audio-review/wake-fixture.sha256').read_text().strip()
PYHASH
shasum -a 256 "$scratch/debug/NextNotes" > "$reports/fixed-binary.sha256"
xargs shasum -a 256 < "$reports/source-paths.txt" > "$reports/fixed-sources.sha256"
failed=0
for flag in catch-up agent-panes ui-strings voice-conversation duplex wake store-isolation; do
    "$scratch/debug/NextNotes" "--selftest-$flag" --selftest-out "$TMPDIR/catchup-review-$flag.log" > "$reports/$flag.log" 2>&1
    status=$?
    printf '%s EXIT=%s\n' "$flag" "$status" | tee -a "$reports/exits.txt"
    [ "$status" -eq 0 ] || failed=1
done
exit "$failed"
