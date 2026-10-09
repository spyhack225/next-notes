#!/bin/bash
set -u
scratch=/Users/sergekadjo/Library/Caches/NextNotesBuild/wt-scratch/catchup-final
reports=Tests/Reports/catchup-final/round2/red
mkdir -p "$reports/selftest-out"
runtemp=$(mktemp -d "${TMPDIR%/}/catchup-final-r2-red.XXXXXX") || exit 1
printf '%s\n' "$runtemp" > "$reports/run-temp.txt"
git rev-parse HEAD > "$reports/tested-commit.txt"
git diff -- Sources > "$reports/tested-source.diff"
date -u +%Y-%m-%dT%H:%M:%SZ > "$reports/environment.txt"
uname -a >> "$reports/environment.txt"
sw_vers >> "$reports/environment.txt"
pmset -g batt >> "$reports/environment.txt" 2>&1
pmset -g therm >> "$reports/environment.txt" 2>&1
xargs shasum -a 256 < Tests/Reports/catchup-final/combined-source-files.txt > "$reports/tested-sources.sha256"
swift build -c debug -j 2 --scratch-path "$scratch" > "$reports/build.log" 2>&1
status=$?
printf 'build EXIT=%s\n' "$status" | tee "$reports/exits.txt"
[ "$status" -eq 0 ] || exit "$status"
shasum -a 256 "$scratch/debug/NextNotes" > "$reports/binary.sha256"
dwarfdump --uuid "$scratch/debug/NextNotes" > "$reports/binary-uuid.txt"
python3 Tests/Reports/catchup-final/round2/run-native.py "$scratch/debug/NextNotes" "$reports" "$runtemp" agent-panes
status=$?
shasum -a 256 -c "$reports/tested-sources.sha256" > "$reports/source-invariance.txt" || exit 1
# RED is an expected failing process, never a pass marker.
[ "$status" -eq 1 ] && rg -q CATCH_UP_LATER_LIVE_FAILED "$reports/agent-panes.log"
