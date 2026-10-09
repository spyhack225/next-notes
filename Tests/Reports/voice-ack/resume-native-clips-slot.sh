#!/bin/sh
# Rebuild within the admitted slot; shared scratch binaries may change while queued.
set -u
scratch="$HOME/Library/Caches/NextNotesBuild/wt-scratch/voice"
report=Tests/Reports/voice-ack
fixture="$HOME/Library/Caches/NextNotesBuild/integration/listen-acceptance/fixtures/haiku16k.wav"
swift build -c debug -j 2 --scratch-path "$scratch" || exit $?
python3 "$report/artifact-pins.py" "$scratch/debug/NextNotes" 'debug -j 2 native-clip diagnostic; RMS-fixed source, original raw bound; not timing acceptance' || exit $?
python3 "$report/native-run.py" native-clips-red-retry "$scratch/debug/NextNotes" --selftest-voice-latency --voice-latency-fixture "$fixture" --voice-latency-ack-native-clips
status=$?
[ "$status" -eq 1 ] || exit 1
python3 "$report/apply-native-clips.py" native-clips-red-retry.log || exit $?
swift build -c release -j 2 --scratch-path "$scratch" || exit $?
app="$scratch/release/NextNotes"
python3 "$report/artifact-pins.py" "$app" || exit $?
python3 "$report/native-run.py" green-policy-final "$app" --selftest-voice-latency --voice-latency-ack-policy || exit $?
failed=0
run() { label=$1; shift; python3 "$report/native-run.py" "$label" "$app" "$@" || failed=1; }
run before-no-ack-final --selftest-voice-latency --voice-latency-fixture "$fixture" --voice-latency-runs 5 --voice-no-ack
run after-ack-final --selftest-voice-latency --voice-latency-fixture "$fixture" --voice-latency-runs 5
run voice-pipeline-final --selftest-voice-pipeline "$fixture"
run voice-turn-routing-final --selftest-voice-turn-routing
run concurrent-voice-final --selftest-concurrent-voice
run voice-conversation-final --selftest-voice-conversation
run duplex-final --selftest-duplex
run voice-scheduling-final --selftest-voice-scheduling
run tts-final --selftest-tts
run store-isolation-final --selftest-store-isolation
exit "$failed"
