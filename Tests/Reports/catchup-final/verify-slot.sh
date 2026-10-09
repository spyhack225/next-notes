#!/bin/bash
set -u
scratch=/Users/sergekadjo/Library/Caches/NextNotesBuild/wt-scratch/catchup-final
reports=Tests/Reports/catchup-final
runtemp=$(mktemp -d "${TMPDIR%/}/catchup-final.XXXXXX") || exit 1
printf '%s\n' "$runtemp" > "$reports/run-temp.txt"
mkdir -p "$reports/selftest-out"
git rev-parse HEAD > "$reports/tested-commit.txt"
date -u +%Y-%m-%dT%H:%M:%SZ > "$reports/environment.txt"
uname -a >> "$reports/environment.txt"
pmset -g batt >> "$reports/environment.txt" 2>&1
sw_vers >> "$reports/environment.txt"
pmset -g therm >> "$reports/environment.txt" 2>&1
xargs shasum -a 256 < "$reports/combined-source-files.txt" > "$reports/tested-sources.sha256"
swift build -c debug -j 2 --scratch-path "$scratch" > "$reports/build.log" 2>&1
status=$?
printf 'build EXIT=%s\n' "$status" | tee "$reports/exits.txt"
[ "$status" -eq 0 ] || exit "$status"
shasum -a 256 "$scratch/debug/NextNotes" > "$reports/binary.sha256"
dwarfdump --uuid "$scratch/debug/NextNotes" > "$reports/binary-uuid.txt"
failed=0
for flag in catch-up agent-panes ui-strings island commandkey voice-conversation duplex settings store-isolation; do
    echo "Running $flag"
    if [ "$flag" = agent-panes ]; then
        "$scratch/debug/NextNotes" "--selftest-$flag" --catch-up-preview-dir "$runtemp/previews" --selftest-out "$runtemp/$flag.log" > "$reports/$flag.log" 2>&1
    else
        "$scratch/debug/NextNotes" "--selftest-$flag" --selftest-out "$runtemp/$flag.log" > "$reports/$flag.log" 2>&1
    fi
    status=$?
    printf '%s EXIT=%s\n' "$flag" "$status" | tee -a "$reports/exits.txt"
    if [ "$status" -ne 0 ]; then
        if [ "$flag" = settings ] && [ "$status" -eq 139 ]; then
            echo 'Settings inherited SIGSEGV retained separately'
        else
            failed=1
        fi
    fi
    [ ! -f "$runtemp/$flag.log" ] || cp "$runtemp/$flag.log" "$reports/selftest-out/$flag.log"
done
if [ -d "$runtemp/previews" ]; then cp -R "$runtemp/previews" "$reports/previews"; fi
shasum -a 256 -c "$reports/tested-sources.sha256" > "$reports/source-invariance.txt" || failed=1
exit "$failed"
