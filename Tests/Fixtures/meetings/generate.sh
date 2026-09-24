#!/usr/bin/env bash
# Regenerate the M-16a meeting fixtures (+ manifest.json).
#
# Synth only (say + afconvert + stdlib python3), so no real voice is committed.
# One turn per script line (prefixed A: / B: / C:) is rendered with its voice,
# then concatenated with 0.8 s of silence between turns. manifest.json is
# emitted from the same turn lists that render the audio, so the two cannot
# drift. Every file stays mono 16 kHz Int16, <= 95 s and <= 3 MB.
#
# Usage: Tests/Fixtures/meetings/generate.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPTS="$HERE/scripts"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Voices from 02-MEETINGS.md §1.8. The parenthesised locale selects the voice's
# language variant; a bare `say -v Flo` would read French text with English
# pronunciation. All names verified present with `say -v '?'`.
FR_A="Thomas (French (France))"
FR_B="Flo (French (France))"
FR_C="Grandpa (French (France))"
EN_A="Samantha (English (US))"
EN_B="Reed (English (US))"
EN_C="Rocko (English (US))"

render() { # voice text out.wav
  say -v "$1" "$2" -o "$TMP/turn.aiff"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/turn.aiff" "$3"
}

# Render every turn of a script file; list "speaker<TAB>wav<TAB>text" for python.
render_script() { # script-name lang out-list
  local name="$1" lang="$2" list="$3"
  local n=0
  : > "$list"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    n=$((n + 1))
    local speaker="${line%%:*}"
    local text="${line#*:}"
    text="$(printf '%s' "$text" | sed 's/^ //')"
    local voice
    case "$lang:$speaker" in
      fr:A) voice="$FR_A";; fr:B) voice="$FR_B";; fr:C) voice="$FR_C";;
      en:A) voice="$EN_A";; en:B) voice="$EN_B";; en:C) voice="$EN_C";;
      *) echo "generate: bad turn prefix in $name: $line" >&2; exit 1;;
    esac
    local out="$TMP/$name-$n.wav"
    render "$voice" "$text" "$out"
    printf '%s\t%s\t%s\n' "$speaker" "$out" "$text" >> "$list"
  done < "$SCRIPTS/$name.txt"
  echo "rendered $n turn(s) for $name"
}

render_script fr-dialogue fr "$TMP/fr-dialogue.tsv"
render_script en-dialogue en "$TMP/en-dialogue.tsv"
render_script fr-call fr "$TMP/fr-call.tsv"
render_script fr-1to1 fr "$TMP/fr-1to1.tsv"

# Assemble the six files and manifest.json with stdlib python3 (wave/array,
# no numpy). The phone variant is band-limited through 8 kHz with afconvert
# first; the -45 dBFS comfort noise is added by the second python pass so the
# turn timings still come from the one assembly.
python3 - "$TMP" "$HERE" <<'PYEOF'
import array
import json
import sys
import wave

tmp, here = sys.argv[1], sys.argv[2]
GAP = int(0.8 * 16000)


def read_turns(path):
    turns = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            speaker, wav, text = line.split("\t")
            turns.append((speaker, wav, text))
    return turns


def read_mono16(path):
    with wave.open(path, "rb") as w:
        assert w.getnchannels() == 1, path
        assert w.getframerate() == 16000, path
        assert w.getsampwidth() == 2, path
        return array.array("h", w.readframes(w.getnframes()))


def write_mono16(path, samples):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(samples.tobytes())


def concat(turns):
    out = array.array("h")
    timed = []
    pos = 0
    for i, (speaker, wav, text) in enumerate(turns):
        if i > 0:
            out.extend([0] * GAP)
            pos += GAP
        audio = read_mono16(wav)
        start = pos / 16000.0
        out.extend(audio)
        pos += len(audio)
        timed.append({
            "speaker": speaker,
            "start": round(start, 3),
            "end": round(pos / 16000.0, 3),
            "text": text,
        })
    return out, timed


def split_tracks(turns, keep):
    """One timeline for all turns; kept speakers audible, the rest silence."""
    total = sum(len(read_mono16(w)) for _, w, _ in turns) + GAP * (len(turns) - 1)
    out = array.array("h", [0] * total)
    timed = []
    pos = 0
    for i, (speaker, wav, text) in enumerate(turns):
        if i > 0:
            pos += GAP
        audio = read_mono16(wav)
        start = pos / 16000.0
        if keep(speaker):
            out[pos:pos + len(audio)] = audio
        pos += len(audio)
        timed.append({
            "speaker": speaker,
            "start": round(start, 3),
            "end": round(pos / 16000.0, 3),
            "text": text,
        })
    return out, timed


manifest = {"files": {}}


def emit(name, samples, timed):
    path = "%s/%s" % (here, name)
    write_mono16(path, samples)
    manifest["files"][name] = {
        "duration": round(len(samples) / 16000.0, 3),
        "turns": timed,
    }


fr = read_turns("%s/fr-dialogue.tsv" % tmp)
en = read_turns("%s/en-dialogue.tsv" % tmp)
call = read_turns("%s/fr-call.tsv" % tmp)
one = read_turns("%s/fr-1to1.tsv" % tmp)

emit("fr-dialogue.wav", *concat(fr))
emit("en-dialogue.wav", *concat(en))
mic, mic_timed = split_tracks(call, lambda s: s == "A")
emit("fr-call-mic.wav", mic, mic_timed)
sys_audio, sys_timed = split_tracks(call, lambda s: s in ("B", "C"))
emit("fr-call-system.wav", sys_audio, sys_timed)
emit("fr-1to1-system.wav", *concat(one))

with open("%s/manifest.json" % here, "w", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2)
    f.write("\n")

for name, info in manifest["files"].items():
    print("%s: %.1fs, %d turn(s)" % (name, info["duration"], len(info["turns"])))
PYEOF

# Band-limit the French dialogue through 8 kHz (a stand-in for WhatsApp's
# codec), back to 16 kHz, then add white comfort noise at -45 dBFS.
afconvert -f WAVE -d LEI16@8000 "$HERE/fr-dialogue.wav" "$TMP/phone8k.wav"
afconvert -f WAVE -d LEI16@16000 "$TMP/phone8k.wav" "$TMP/phone16k.wav"
python3 - "$TMP/phone16k.wav" "$HERE/fr-dialogue-phone.wav" <<'PYEOF'
import array
import random
import sys
import wave

src, dst = sys.argv[1], sys.argv[2]
with wave.open(src, "rb") as w:
    assert (w.getnchannels(), w.getframerate(), w.getsampwidth()) == (1, 16000, 2)
    samples = array.array("h", w.readframes(w.getnframes()))
rng = random.Random(1234)
sigma = 10 ** (-45.0 / 20.0) * 32768.0
for i, s in enumerate(samples):
    v = int(round(s + rng.gauss(0.0, sigma)))
    samples[i] = max(-32768, min(32767, v))
with wave.open(dst, "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(16000)
    w.writeframes(samples.tobytes())
print("phone: %.1fs with -45 dBFS noise" % (len(samples) / 16000.0))
PYEOF

# Record the phone file in the manifest (same timings as fr-dialogue).
python3 - "$HERE" <<'PYEOF'
import json
import sys
import wave

here = sys.argv[1]
with open("%s/manifest.json" % here, encoding="utf-8") as f:
    manifest = json.load(f)
with wave.open("%s/fr-dialogue-phone.wav" % here, "rb") as w:
    dur = w.getnframes() / w.getframerate()
manifest["files"]["fr-dialogue-phone.wav"] = {
    "duration": round(dur, 3),
    "note": "fr-dialogue.wav band-limited through 8 kHz with -45 dBFS comfort noise",
    "turns": manifest["files"]["fr-dialogue.wav"]["turns"],
}
with open("%s/manifest.json" % here, "w", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2)
    f.write("\n")
print("manifest: %d file(s)" % len(manifest["files"]))
PYEOF

echo "--- sizes ---"
ls -la "$HERE"/*.wav
echo "regenerate: Tests/Fixtures/meetings/generate.sh"
