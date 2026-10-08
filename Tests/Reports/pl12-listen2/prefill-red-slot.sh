#!/bin/sh
set -u
app=/Users/sergekadjo/Library/Caches/NextNotesBuild/wt-scratch/listen2/debug/NextNotes
report=/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/listen2/Tests/Reports/pl12-listen2
fixture=/Users/sergekadjo/Library/Caches/NextNotesBuild/integration/listen-acceptance/fixtures/haiku16k.wav
swift build -c debug -j 2 --scratch-path /Users/sergekadjo/Library/Caches/NextNotesBuild/wt-scratch/listen2 || exit $?
batch_failed=0
run() {
    label=$1
    shift
    "$app" "$@" --selftest-out "$report/$label.log" --selftest-timeout 600 > "$report/$label.stdout.log" 2>&1
    result=$?
    if [ "$result" -ne 0 ]; then batch_failed=1; fi
    echo "$label exit=$result" >> "$report/prefill-red-status.txt"
    tail -n 2 "$report/$label.log"
    return "$result"
}
run prefill-red --selftest-llm-prefix-cache --interactive-prefill
# RED must actually fail, then capture the same native answering model without prefill.
if ! rg -q '^INTERACTIVE_PREFILL_FAILED' "$report/prefill-red.log"; then exit 2; fi
batch_failed=0
run mini-before --selftest-voice-latency --voice-latency-fixture "$fixture" --voice-latency-runs 5 --voice-latency-partial-route --voice-latency-model 'file:/Users/sergekadjo/Library/Application Support/Next Notes/Models/MiniCPM5-2B-Q4_K_M.gguf'
shasum -a 256 '/Users/sergekadjo/Library/Application Support/Next Notes/Models/MiniCPM5-2B-Q4_K_M.gguf' > "$report/mini-model.sha256"
exit "$batch_failed"
