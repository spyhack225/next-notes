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
    echo "$label exit=$result" >> "$report/route-green-status.txt"
    tail -n 2 "$report/$label.log"
    return "$result"
}
run route-green --selftest-voice-latency --voice-latency-partials --voice-latency-partial-route || exit $?
run route-after --selftest-voice-latency --voice-latency-fixture "$fixture" --voice-latency-runs 5 --voice-latency-partial-route
run related-partials --selftest-voice-latency --voice-latency-partials
run voice-pipeline --selftest-voice-pipeline "$fixture"
run voice-turn-routing --selftest-voice-turn-routing
run concurrent-voice --selftest-concurrent-voice
run voice-conversation --selftest-voice-conversation
run duplex --selftest-duplex
run prefix-cache --selftest-llm-prefix-cache
run store-isolation --selftest-store-isolation

exit "$batch_failed"
