#!/bin/sh
set -u
app=/Users/sergekadjo/Library/Caches/NextNotesBuild/wt-scratch/listen2/debug/NextNotes
report=/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/listen2/Tests/Reports/pl12-listen2
fixture=/Users/sergekadjo/Library/Caches/NextNotesBuild/integration/listen-acceptance/fixtures/haiku16k.wav
swift build -c debug -j 2 --scratch-path /Users/sergekadjo/Library/Caches/NextNotesBuild/wt-scratch/listen2 || exit $?
python3 "$report/pin-candidate.py" resident-red-pins.json || exit $?
batch_failed=0
run() {
    label=$1
    shift
    "$app" "$@" --selftest-out "$report/$label.log" --selftest-timeout 600 > "$report/$label.stdout.log" 2>&1
    result=$?
    if [ "$result" -ne 0 ]; then batch_failed=1; fi
    echo "$label exit=$result" >> "$report/resident-status.txt"
    if [ -f "$report/$label.log" ]; then tail -n 2 "$report/$label.log"; else tail -n 2 "$report/$label.stdout.log"; fi
    return "$result"
}
run resident-red --selftest-llm-prefix-cache --interactive-prefill-resident
if ! rg -q '^RESIDENT_PREFILL_FAILED' "$report/resident-red.log"; then exit 2; fi
python3 "$report/resident-fix.py" || exit $?
swift build -c debug -j 2 --scratch-path /Users/sergekadjo/Library/Caches/NextNotesBuild/wt-scratch/listen2 || exit $?
python3 "$report/pin-candidate.py" resident-final-pins.json || exit $?
batch_failed=0
run resident-green --selftest-llm-prefix-cache --interactive-prefill-resident || exit $?
run prefill-final --selftest-llm-prefix-cache --interactive-prefill || exit $?
run route-resident-final --selftest-voice-latency --voice-latency-partials --voice-latency-partial-route --voice-latency-prefill || exit $?
run mini-after-final --selftest-voice-latency --voice-latency-fixture "$fixture" --voice-latency-runs 5 --voice-latency-partial-route --voice-latency-prefill --voice-latency-model 'file:/Users/sergekadjo/Library/Application Support/Next Notes/Models/MiniCPM5-2B-Q4_K_M.gguf'
run resident-partials --selftest-voice-latency --voice-latency-partials
run resident-pipeline --selftest-voice-pipeline "$fixture"
run resident-routing --selftest-voice-turn-routing
run resident-concurrent --selftest-concurrent-voice
run resident-conversation --selftest-voice-conversation
run resident-duplex --selftest-duplex
run resident-prefix --selftest-llm-prefix-cache
run resident-isolation --selftest-store-isolation
shasum -a 256 '/Users/sergekadjo/Library/Application Support/Next Notes/Models/MiniCPM5-2B-Q4_K_M.gguf' > "$report/mini-model-final.sha256"
exit "$batch_failed"
