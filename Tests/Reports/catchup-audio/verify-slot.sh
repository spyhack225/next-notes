#!/bin/sh
set -u
scratch=/Users/sergekadjo/Library/Caches/NextNotesBuild/wt-scratch/catchup-audio
reports=Tests/Reports/catchup-audio
{
    date -u
    sw_vers
    uname -m
    sysctl hw.model hw.memsize
} > "$reports/environment.txt"
make webrtc-audio || exit $?
swift build -c debug -j 2 --scratch-path "$scratch" > "$reports/red-build.log" 2>&1 || exit $?
rm -f "$TMPDIR/catchup-audio-red.log"
"$scratch/debug/NextNotes" --selftest-catch-up --selftest-out "$TMPDIR/catchup-audio-red.log" > "$reports/red.log" 2>&1
red=$?
[ ! -f "$TMPDIR/catchup-audio-red.log" ] || cp "$TMPDIR/catchup-audio-red.log" "$reports/red-mirror.log"
printf 'RED_EXIT=%s\n' "$red" | tee "$reports/exits.txt"
shasum -a 256 "$scratch/debug/NextNotes" > "$reports/red-binary.sha256"
# A runtime failure must include BOTH original regressions, not a startup failure.
if [ "$red" -eq 0 ] || ! rg -q '^CATCH_UP_HANDOFF_FAILED' "$reports/red.log" || ! rg -q '^CATCH_UP_PLAYBACK_FAILED' "$reports/red.log"; then
    echo 'RED_REGRESSION_NOT_ESTABLISHED'
    exit 1
fi
shasum -a 256 Sources/NextNotes/UI/CatchUp/CatchUpHandoffSelfTest.swift > "$reports/fixture.sha256"
python3 "$reports/apply-fix.py" || exit $?
swift build -c debug -j 2 --scratch-path "$scratch" > "$reports/fixed-build.log" 2>&1 || exit $?
shasum -a 256 -c "$reports/fixture.sha256" || exit $?
shasum -a 256 "$scratch/debug/NextNotes" > "$reports/fixed-binary.sha256"
shasum -a 256 Sources/NextNotes/UI/CatchUp/CatchUpLibrary.swift Sources/NextNotes/UI/CatchUp/CatchUpConversationContext.swift Sources/NextNotes/UI/CatchUp/CatchUpHandoffSelfTest.swift Sources/NextNotes/Agent/RealtimeAgent.swift Sources/NextNotes/Agent/Schedules/CatchUpSelfTest.swift > "$reports/fixed-sources.sha256"
failed=0
for flag in catch-up agent-panes ui-strings voice-conversation duplex store-isolation; do
    rm -f "$TMPDIR/catchup-audio-$flag.log"
    "$scratch/debug/NextNotes" "--selftest-$flag" --selftest-out "$TMPDIR/catchup-audio-$flag.log" > "$reports/$flag.log" 2>&1
    status=$?
    [ ! -f "$TMPDIR/catchup-audio-$flag.log" ] || cp "$TMPDIR/catchup-audio-$flag.log" "$reports/$flag-mirror.log"
    printf '%s EXIT=%s\n' "$flag" "$status" | tee -a "$reports/exits.txt"
    [ "$status" -eq 0 ] || failed=1
done
exit "$failed"
