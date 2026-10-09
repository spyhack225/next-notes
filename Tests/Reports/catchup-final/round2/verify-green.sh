#!/bin/bash
set -u
scratch=/Users/sergekadjo/Library/Caches/NextNotesBuild/wt-scratch/catchup-final
reports=Tests/Reports/catchup-final/round2/green
mkdir -p "$reports/selftest-out"
runtemp=$(mktemp -d "${TMPDIR%/}/catchup-final-r2-green.XXXXXX") || exit 1
printf '%s\n' "$runtemp" > "$reports/run-temp.txt"
git rev-parse HEAD > "$reports/tested-commit.txt"
git diff -- Sources > "$reports/tested-source.diff"
date -u +%Y-%m-%dT%H:%M:%SZ > "$reports/environment.txt"
uname -a >> "$reports/environment.txt"
sw_vers >> "$reports/environment.txt"
pmset -g batt >> "$reports/environment.txt" 2>&1
pmset -g therm >> "$reports/environment.txt" 2>&1
xargs shasum -a 256 < Tests/Reports/catchup-final/round2/combined-source-files.txt > "$reports/tested-sources.sha256"
swift build -c debug -j 2 --scratch-path "$scratch" > "$reports/build.log" 2>&1
status=$?
printf 'build EXIT=%s\n' "$status" | tee "$reports/exits.txt"
[ "$status" -eq 0 ] || exit "$status"
shasum -a 256 "$scratch/debug/NextNotes" > "$reports/binary.sha256"
dwarfdump --uuid "$scratch/debug/NextNotes" > "$reports/binary-uuid.txt"
python3 Tests/Reports/catchup-final/round2/run-native.py "$scratch/debug/NextNotes" "$reports" "$runtemp" catch-up agent-panes ui-strings island commandkey voice-conversation duplex settings store-isolation
status=$?
shasum -a 256 -c "$reports/tested-sources.sha256" > "$reports/source-invariance.txt" || exit 1
exit "$status"
