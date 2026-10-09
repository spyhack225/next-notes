#!/bin/sh
# Run only via RELAY_ID=claude2-voice-ack ../heavy.sh; one shared voice scratch.
set -u
scratch="$HOME/Library/Caches/NextNotesBuild/wt-scratch/voice"
report=Tests/Reports/voice-ack
fixture="$HOME/Library/Caches/NextNotesBuild/integration/listen-acceptance/fixtures/haiku16k.wav"
swift build -c release -j 2 --scratch-path "$scratch" || exit $?
app="$scratch/release/NextNotes"
python3 "$report/artifact-pins.py" "$app" || exit $?
python3 "$report/native-run.py" output-idle-red "$app" --selftest-voice-latency --voice-latency-ack-policy
red_status=$?
[ "$red_status" -eq 1 ] || exit 1
python3 "$report/apply-output-idle-hook.py" || exit $?
swift build -c release -j 2 --scratch-path "$scratch" || exit $?
python3 "$report/artifact-pins.py" "$app" || exit $?
python3 "$report/native-run.py" green-policy "$app" --selftest-voice-latency --voice-latency-ack-policy || exit $?
failed=0
run() {
    label=$1
    shift
    python3 "$report/native-run.py" "$label" "$app" "$@" || failed=1
}
run before-no-ack --selftest-voice-latency --voice-latency-fixture "$fixture" --voice-latency-runs 5 --voice-no-ack
run after-ack --selftest-voice-latency --voice-latency-fixture "$fixture" --voice-latency-runs 5
run voice-pipeline --selftest-voice-pipeline "$fixture"
run voice-turn-routing --selftest-voice-turn-routing
run concurrent-voice --selftest-concurrent-voice
run voice-conversation --selftest-voice-conversation
run duplex --selftest-duplex
run voice-scheduling --selftest-voice-scheduling
run tts --selftest-tts
run store-isolation --selftest-store-isolation
exit "$failed"
