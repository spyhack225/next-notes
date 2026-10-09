#!/bin/sh
set -u
scratch=/Users/sergekadjo/Library/Caches/NextNotesBuild/wt-scratch/voice
report=/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/voice-mini/Tests/Reports/voice-mini
swift build -c debug -j 2 --scratch-path "$scratch" > "$report/red-build.log" 2>&1 || { tail -60 "$report/red-build.log"; exit 2; }
shasum -a 256 "$scratch/debug/NextNotes" > "$report/red-binary.sha256"
python3 "$report/native-driver.py" red --selftest-voice-latency --voice-latency-resident-contract --voice-latency-partials --voice-latency-partial-route --voice-latency-resident-only
result=$?
echo "red exit=$result" > "$report/red-status.txt"
tail -20 "$report/red.log"
exit "$result"
