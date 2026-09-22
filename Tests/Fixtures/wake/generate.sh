#!/usr/bin/env bash
# Regenerate the --selftest-wake-live fixture set (+ manifest.json).
#
# Synth only (say + afconvert), so no real voice is committed. 8 voices x 3 rates
# for hits (the WakeWordTuning header recipe), 32 adversarial negatives grown from
# the header's three seeds. manifest.json is emitted from the same arrays that
# render the audio, so the two cannot drift.
#
# Usage: Tests/Fixtures/wake/generate.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
HITS="$HERE/hits"
NEGS="$HERE/near-miss"
mkdir -p "$HITS" "$NEGS"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

render() { # voice rate text out
  say -v "$1" -r "$2" "$3" -o "$TMP/clip.aiff"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/clip.aiff" "$4"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

HIT_VOICES="Samantha Daniel Karen Moira Tessa Rishi Jacques Thomas"
RATES="150 190 230"
REQUESTS="__REQ__"
REQ0="Hey Will, open Chrome"
REQ1="Hey Will, what is on my calendar"
REQ2="Hey Will, send the report"
REQ3="Hey Will, take a note"
REQ4="Hey Will, play some music"
REQ5="Hey Will, set a timer for ten minutes"

req_text() {
  case "$1" in
    0) printf '%s' "$REQ0";; 1) printf '%s' "$REQ1";; 2) printf '%s' "$REQ2";;
    3) printf '%s' "$REQ3";; 4) printf '%s' "$REQ4";; 5) printf '%s' "$REQ5";;
  esac
}

MANIFEST_HITS=""
MANIFEST_NEGS=""
n=0
k=0
for v in $HIT_VOICES; do
  for r in $RATES; do
    n=$((n + 1))
    # Half bare, half with a request; each voice covers both kinds.
    vi=0; for x in $HIT_VOICES; do vi=$((vi + 1)); [ "$x" = "$v" ] && break; done
    ri=0; for x in $RATES; do ri=$((ri + 1)); [ "$x" = "$r" ] && break; done
    if [ $(( (vi + ri) % 2 )) -eq 0 ]; then
      text=$(req_text $((k % 6))); k=$((k + 1))
    else
      text="Hey Will"
    fi
    num=$(printf "%02d" $n)
    file="hits/hit-$num-$(lower "$v")-$r.wav"
    render "$v" "$r" "$text" "$HERE/$file"
    MANIFEST_HITS="$MANIFEST_HITS{\"file\":\"$file\",\"text\":\"$text\",\"voice\":\"$v\",\"rate\":$r},"
  done
done

NEG_VOICES="Samantha Daniel Karen Moira Tessa Rishi"
NEG_TEXTS="__NEG__"
# The first three are the WakeWordTuning header seeds, verbatim.
NEG_TXT_01="hey Bill can you check the numbers|bill-numbers"
NEG_TXT_02="I will send you the file|will-send-file"
NEG_TXT_03="hey we need to talk about the budget|we-need-budget"
NEG_TXT_04="hey Bill did the numbers come in|bill-numbers-in"
NEG_TXT_05="hey Jill are you still there|jill-there"
NEG_TXT_06="hey Phil what time is the meeting|phil-meeting"
NEG_TXT_07="I will call you back tomorrow|will-call-back"
NEG_TXT_08="we will need the report by Friday|we-will-report"
NEG_TXT_09="they will meet us at noon|they-will-noon"
NEG_TXT_10="hey we should leave in ten minutes|we-should-leave"
NEG_TXT_11="hey when does the store close|when-store-close"
NEG_TXT_12="hey where did I put my keys|where-keys"
NEG_TXT_13="hey well that went better than expected|well-better"
NEG_TXT_14="a will is not a plan for tomorrow|will-not-plan"
NEG_TXT_15="hey there how are you doing today|hey-there"
NEG_TXT_16="hey thanks for sending that over|hey-thanks"
NEG_TXT_17="wait Will you be at the meeting|wait-will-meeting"
NEG_TXT_18="tell Will I said hello|tell-will-hello"
NEG_TXT_19="the meeting with William is at four|william-four"
NEG_TXT_20="wheel the cart over to the door|wheel-cart"
NEG_TXT_21="hail the cab before it leaves|hail-cab"
NEG_TXT_22="hey win or lose we played well|win-or-lose"
NEG_TXT_23="hey wind the clock before bed|wind-clock"
NEG_TXT_24="I win every argument lately|win-argument"
NEG_TXT_25="the bill came to forty dollars|bill-forty"
NEG_TXT_26="build the shelf against the wall|build-shelf"
NEG_TXT_27="fill the kettle and boil it|fill-kettle"
NEG_TXT_28="still waters run deep in this town|still-waters"
NEG_TXT_29="hey did anyone feed the cat|feed-cat"
NEG_TXT_30="hey remember to water the plants|water-plants"
NEG_TXT_31="will it rain again tomorrow|will-rain"
NEG_TXT_32="well I never thought it would end|well-never-end"

neg_entry() { # index -> "text|slug"
  case "$1" in
    1) printf '%s' "$NEG_TXT_01";; 2) printf '%s' "$NEG_TXT_02";; 3) printf '%s' "$NEG_TXT_03";;
    4) printf '%s' "$NEG_TXT_04";; 5) printf '%s' "$NEG_TXT_05";; 6) printf '%s' "$NEG_TXT_06";;
    7) printf '%s' "$NEG_TXT_07";; 8) printf '%s' "$NEG_TXT_08";; 9) printf '%s' "$NEG_TXT_09";;
    10) printf '%s' "$NEG_TXT_10";; 11) printf '%s' "$NEG_TXT_11";; 12) printf '%s' "$NEG_TXT_12";;
    13) printf '%s' "$NEG_TXT_13";; 14) printf '%s' "$NEG_TXT_14";; 15) printf '%s' "$NEG_TXT_15";;
    16) printf '%s' "$NEG_TXT_16";; 17) printf '%s' "$NEG_TXT_17";; 18) printf '%s' "$NEG_TXT_18";;
    19) printf '%s' "$NEG_TXT_19";; 20) printf '%s' "$NEG_TXT_20";; 21) printf '%s' "$NEG_TXT_21";;
    22) printf '%s' "$NEG_TXT_22";; 23) printf '%s' "$NEG_TXT_23";; 24) printf '%s' "$NEG_TXT_24";;
    25) printf '%s' "$NEG_TXT_25";; 26) printf '%s' "$NEG_TXT_26";; 27) printf '%s' "$NEG_TXT_27";;
    28) printf '%s' "$NEG_TXT_28";; 29) printf '%s' "$NEG_TXT_29";; 30) printf '%s' "$NEG_TXT_30";;
    31) printf '%s' "$NEG_TXT_31";; 32) printf '%s' "$NEG_TXT_32";;
  esac
}

i=0
for idx in $(seq 1 32); do
  entry=$(neg_entry "$idx")
  text=${entry%%|*}
  slug=${entry##*|}
  i=$((i + 1))
  # Rotate voices across the set.
  vi=$(( (idx - 1) % 6 + 1 ))
  v=$(printf '%s' "$NEG_VOICES" | cut -d' ' -f"$vi")
  num=$(printf "%02d" "$idx")
  file="near-miss/neg-$num-$slug.wav"
  render "$v" 190 "$text" "$HERE/$file"
  MANIFEST_NEGS="$MANIFEST_NEGS{\"file\":\"$file\",\"text\":\"$text\",\"voice\":\"$v\",\"rate\":190},"
done

{
  printf '{\n  "phrase": "Hey Will",\n'
  printf '  "description": "Committed --selftest-wake-live corpus: 24 hits (8 voices x 3 rates, half with a request) + 32 adversarial near-misses. Regenerate with generate.sh.",\n'
  printf '  "hits": [%s],\n' "${MANIFEST_HITS%,}"
  printf '  "nearMisses": [%s]\n}\n' "${MANIFEST_NEGS%,}"
} > "$HERE/manifest.json"

echo "wrote $(ls "$HITS"/*.wav | wc -l | tr -d ' ') hits, $(ls "$NEGS"/*.wav | wc -l | tr -d ' ') near-misses, manifest.json"
