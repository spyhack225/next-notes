#!/usr/bin/env bash
# Generates the file-fed voice fixtures used by the Phase 2 self-tests.
# Float32 / 16 kHz / mono WAV, the format --selftest-voice-pipeline was measured with.
set -euo pipefail
DIR=${1:-"$HOME/Library/Caches/NextNotesBuild/voice-fixtures"}
mkdir -p "$DIR"
duration() { afinfo "$1" | awk '/estimated duration/ {print $3}'; }
make_fixture() { # name text
  say -o "$DIR/$1.aiff" "$2"
  afconvert -f WAVE -d LEF32@16000 -c 1 "$DIR/$1.aiff" "$DIR/$1.wav"
  rm -f "$DIR/$1.aiff"
  echo "$1.wav $(duration "$DIR/$1.wav")s"
}
make_fixture haiku16k     "Hello there. Please tell me briefly what a haiku is."
make_fixture stop16k      "Wait, please stop speaking."
make_fixture question16k  "What time is it in Tokyo right now?"
make_fixture pause-mid16k "I want to book a table for [[slnc 900]] four people tomorrow evening."
make_fixture pause-um16k  "So I was thinking we could [[slnc 700]] maybe move the meeting."
make_fixture nopause16k   "I want to book a table for four people tomorrow evening."
# [[slnc]] must have produced real silence: pause-mid must be >= 0.7 s longer than nopause.
awk -v a="$(duration "$DIR/pause-mid16k.wav")" -v b="$(duration "$DIR/nopause16k.wav")" \
  'BEGIN { if (a - b < 0.7) { print "error: [[slnc]] ignored by this voice"; exit 1 } }'
