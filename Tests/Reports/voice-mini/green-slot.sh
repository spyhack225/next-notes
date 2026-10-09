#!/bin/sh
set -u
scratch=/Users/sergekadjo/Library/Caches/NextNotesBuild/wt-scratch/voice
report=/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/voice-mini/Tests/Reports/voice-mini
fixture=/Users/sergekadjo/Library/Caches/NextNotesBuild/integration/listen-acceptance/fixtures/haiku16k.wav
model='file:/Users/sergekadjo/Library/Application Support/Next Notes/Models/MiniCPM5-2B-Q4_K_M.gguf'
swift build -c debug -j 2 --scratch-path "$scratch" > "$report/scripted-red-build.log" 2>&1 || { tail -70 "$report/scripted-red-build.log"; exit 2; }
python3 "$report/native-driver.py" red-scripted --selftest-voice-latency --voice-latency-resident-contract --voice-latency-resident-scripted-only --voice-latency-partials --voice-latency-partial-route --voice-latency-resident-only
if ! rg -q '^VOICE_RESIDENT_ANSWER_FAILED' "$report/red-scripted.stdout.log"; then exit 4; fi
python3 "$report/apply-fix.py" || exit 5
git apply --check "$report/counter-prerequisite/1-bf8d8984dbde-apple-synthesis-counter.patch" || exit 6
git apply "$report/counter-prerequisite/1-bf8d8984dbde-apple-synthesis-counter.patch" || exit 6
swift build -c debug -j 2 --scratch-path "$scratch" > "$report/green-build.log" 2>&1 || { tail -70 "$report/green-build.log"; exit 2; }
shasum -a 256 "$fixture" > "$report/fixture.sha256"
shasum -a 256 '/Users/sergekadjo/Library/Application Support/Next Notes/Models/MiniCPM5-2B-Q4_K_M.gguf' > "$report/model.sha256"
failed=0
run() {
    label=$1
    shift
    python3 "$report/native-driver.py" "$label" "$@"
    status=$?
    if [ "$status" -ne 0 ]; then failed=1; fi
    return "$status"
}
run green --selftest-voice-latency --voice-latency-resident-contract --voice-latency-partials --voice-latency-partial-route --voice-latency-resident-only || exit 3
run partials --selftest-voice-latency --voice-latency-partials --voice-latency-partial-route --voice-latency-prefill
run apple --selftest-voice-latency --voice-latency-fixture "$fixture" --voice-latency-runs 5 --voice-latency-partial-route
run mini --selftest-voice-latency --voice-latency-fixture "$fixture" --voice-latency-runs 5 --voice-latency-partial-route --voice-latency-prefill --voice-latency-resident-only --voice-latency-resident-prepare --voice-latency-model "$model"
run cold-fallback --selftest-voice-latency --voice-latency-fixture "$fixture" --voice-latency-runs 5 --voice-latency-partial-route --voice-latency-prefill --voice-latency-resident-only --voice-latency-model "$model"
run pipeline --selftest-voice-pipeline "$fixture"
run routing --selftest-voice-turn-routing
run concurrent --selftest-concurrent-voice
run conversation --selftest-voice-conversation
run duplex --selftest-duplex
run prefix --selftest-llm-prefix-cache
run isolation --selftest-store-isolation
exit "$failed"
