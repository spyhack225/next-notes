#!/bin/bash
set -u
scratch=/Users/sergekadjo/Library/Caches/NextNotesBuild/wt-scratch/catchup-audio
reports=Tests/Reports/catchup-audio-review
# Same strengthened fixture, real original player/wake/speech producers only.
git apply --reverse "$reports/fix-2.patch" || exit $?
xargs shasum -a 256 < "$reports/source-paths.txt" > "$reports/backing-red-sources.sha256"
swift build -c debug -j 2 --scratch-path "$scratch" > "$reports/backing-red-build.log" 2>&1 || exit $?
shasum -a 256 "$scratch/debug/NextNotes" > "$reports/backing-red-binary.sha256"
shasum -a 256 Sources/NextNotes/UI/CatchUp/CatchUp*SelfTest.swift > "$reports/backing-ui-fixtures.sha256"
python3 - <<'PY' > "$reports/backing-fixture.sha256"
from pathlib import Path
import hashlib
s=Path('Sources/NextNotes/Activation/WakeWord/WakeWordAudioMonitor.swift').read_text().split('    /// Same AudioCaptureHub subscription/callback/detection consumer;')[1]
print(hashlib.sha256(s.encode()).hexdigest())
PY
"$scratch/debug/NextNotes" --selftest-catch-up --selftest-out "$TMPDIR/catchup-review-backing-red.log" > "$reports/backing-red.log" 2>&1
red=$?
printf 'BACKING RED EXIT=%s\n' "$red" > "$reports/backing-exits.txt"
[ "$red" -eq 1 ] || exit 1
rg -q '^CATCH_UP_SPEECH_BACKING speak=3 resume=1 overlaps=3$' "$reports/backing-red.log" || exit 1
rg -q '^CATCH_UP_WAKE_CHECK_FAILED: file was still playing at actual speech backing entry$' "$reports/backing-red.log" || exit 1
rg -q '^CATCH_UP_ACCEPTANCE_CHECK_FAILED: acceptance: oversized offer silently lost omission notice$' "$reports/backing-red.log" || exit 1
for name in PERMISSION PROVENANCE; do
    rg -q "^CATCH_UP_${name}_OK$" "$reports/backing-red.log" || exit 1
done
git apply "$reports/fix-1-bounded-offer.patch" || exit $?
git apply "$reports/fix-2.patch" || exit $?
swift build -c debug -j 2 --scratch-path "$scratch" > "$reports/backing-fixed-build.log" 2>&1 || exit $?
python3 - <<'PY' || exit $?
from pathlib import Path
import hashlib
s=Path('Sources/NextNotes/Activation/WakeWord/WakeWordAudioMonitor.swift').read_text().split('    /// Same AudioCaptureHub subscription/callback/detection consumer;')[1]
assert hashlib.sha256(s.encode()).hexdigest()==Path('Tests/Reports/catchup-audio-review/backing-fixture.sha256').read_text().strip()
PY
shasum -a 256 -c "$reports/backing-ui-fixtures.sha256" || exit $?
shasum -a 256 "$scratch/debug/NextNotes" > "$reports/backing-fixed-binary.sha256"
xargs shasum -a 256 < "$reports/source-paths.txt" > "$reports/backing-fixed-sources.sha256"
failed=0
for flag in catch-up agent-panes ui-strings voice-conversation duplex wake store-isolation; do
    "$scratch/debug/NextNotes" "--selftest-$flag" --selftest-out "$TMPDIR/catchup-review-backing-$flag.log" > "$reports/backing-$flag.log" 2>&1
    status=$?
    printf '%s EXIT=%s\n' "$flag" "$status" | tee -a "$reports/backing-exits.txt"
    [ "$status" -eq 0 ] || failed=1
done
rg -q '^CATCH_UP_SPEECH_BACKING speak=3 resume=1 overlaps=0$' "$reports/backing-catch-up.log" || failed=1
exit "$failed"
