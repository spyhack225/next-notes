#!/bin/sh
set -u
scratch=/Users/sergekadjo/Library/Caches/NextNotesBuild/wt-scratch/voice
report=/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/voice-mini/Tests/Reports/voice-mini
fixture=/Users/sergekadjo/Library/Caches/NextNotesBuild/integration/listen-acceptance/fixtures/haiku16k.wav
model='file:/Users/sergekadjo/Library/Application Support/Next Notes/Models/MiniCPM5-2B-Q4_K_M.gguf'
swift build -c debug -j 2 --scratch-path "$scratch" > "$report/repeat-build.log" 2>&1 || { tail -60 "$report/repeat-build.log"; exit 2; }
shasum -a 256 "$fixture" > "$report/repeat-fixture.sha256"
shasum -a 256 '/Users/sergekadjo/Library/Application Support/Next Notes/Models/MiniCPM5-2B-Q4_K_M.gguf' > "$report/repeat-model.sha256"
failed=0
python3 "$report/native-driver.py" repeat-apple --selftest-voice-latency --voice-latency-fixture "$fixture" --voice-latency-runs 5 --voice-latency-partial-route || failed=1
python3 "$report/native-driver.py" repeat-mini --selftest-voice-latency --voice-latency-fixture "$fixture" --voice-latency-runs 5 --voice-latency-partial-route --voice-latency-prefill --voice-latency-resident-only --voice-latency-resident-prepare --voice-latency-model "$model" || failed=1
exit "$failed"
