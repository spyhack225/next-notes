#!/bin/sh
set -u
scratch="$HOME/Library/Caches/NextNotesBuild/wt-scratch/voice"
report=Tests/Reports/voice-ack
fixture="$HOME/Library/Caches/NextNotesBuild/integration/listen-acceptance/fixtures/haiku16k.wav"
swift build -c debug -j 2 --scratch-path "$scratch" || exit $?
app="$scratch/debug/NextNotes"
python3 "$report/artifact-pins.py" "$app" 'debug -j 2 faithful original bounded cache diagnostic; RMS-fixed; no timing acceptance' || exit $?
cp "$report/native-artifact-pins.json" "$report/cache-path-original-artifact-pins.json"
python3 "$report/native-run.py" cleaned-resume-green-trace "$app" --selftest-voice-latency --voice-latency-ack-policy || exit $?
python3 "$report/native-run.py" cache-path-original "$app" --selftest-voice-latency --voice-latency-fixture "$fixture" --voice-latency-ack-cache-trace --voice-latency-ack-cache-only || exit $?
swift build -c release -j 2 --scratch-path "$scratch" || exit $?
app="$scratch/release/NextNotes"
python3 "$report/artifact-pins.py" "$app" || exit $?
python3 "$report/native-run.py" green-policy-final "$app" --selftest-voice-latency --voice-latency-ack-policy || exit $?
failed=0
run() { label=$1; shift; python3 "$report/native-run.py" "$label" "$app" "$@" || failed=1; }
run before-no-ack-final --selftest-voice-latency --voice-latency-fixture "$fixture" --voice-latency-runs 5 --voice-no-ack
run after-ack-final --selftest-voice-latency --voice-latency-fixture "$fixture" --voice-latency-runs 5 --voice-latency-ack-cache-trace
run voice-pipeline-final --selftest-voice-pipeline "$fixture"
run voice-turn-routing-final --selftest-voice-turn-routing
run concurrent-voice-final --selftest-concurrent-voice
run voice-conversation-final --selftest-voice-conversation
run duplex-final --selftest-duplex
run voice-scheduling-final --selftest-voice-scheduling
run tts-final --selftest-tts
run store-isolation-final --selftest-store-isolation
exit "$failed"
