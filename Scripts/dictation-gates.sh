#!/usr/bin/env bash
# The D-13 / D-14 evidence-gate report, refreshed in the background by every `make app`.
#
# Why it exists: both tasks in roadmap/done/DICTATION-MEETINGS-LIMITS say "check before
# writing any code", and both are waiting on the owner's own dictations rather than on
# anything the app has to be taught to record first. A report that only a human can produce
# by hand is a report that stays unwritten, so `make app` refreshes it — detached, read-only,
# and never able to fail a build.
#
# It reads the owner's stores and writes only into this project's cache directory:
#   gates-latest.txt    the verdicts, in words, with what is missing when undecided
#   gates-latest.json   the same, machine-readable
#   gates-history.jsonl one line per run: when, which commit, each verdict
#
# Run it by hand any time with `make gates` (foreground) or
#   python3 Scripts/dictation-stats.py --gates
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${NEXTNOTES_GATES_DIR:-$HOME/Library/Caches/NextNotesBuild/dictation-meetings}
STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HEAD=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)

mkdir -p "$OUT" || exit 0
TXT=$(mktemp "$OUT/.gates.XXXXXX")
JSON=$(mktemp "$OUT/.gates.XXXXXX")

python3 "$ROOT/Scripts/dictation-stats.py" --gates >"$TXT" 2>"$OUT/.gates.err" || {
  # A broken reader must not look like a verdict. Leave the previous report in place and
  # record the failure, so the next agent sees "the report is stale" rather than "no news".
  printf 'GATES_RUN_FAILED %s head=%s see %s\n' "$STAMP" "$HEAD" "$OUT/.gates.err" >>"$OUT/gates-history.jsonl"
  rm -f "$TXT" "$JSON"
  exit 0
}

{
  echo "# D-13 / D-14 evidence gates"
  echo "# refreshed $STAMP at commit $HEAD by make app (background)"
  echo "# reproduce:  python3 Scripts/dictation-stats.py --gates"
  echo "# decide:     roadmap/done/DICTATION-MEETINGS-LIMITS/STATUS.md, D-13 / D-14 rows"
  echo "# hold count and thresholds are the task text's own (100 holds, 7 days, 3 per 100)."
  echo
  cat "$TXT"
  echo
  echo "# full history: python3 Scripts/dictation-stats.py --since 2026-09-25"
} >"$TXT.header"

python3 "$ROOT/Scripts/dictation-stats.py" --gates --json >"$JSON" 2>/dev/null || true

VERDICTS=$(python3 - "$JSON" <<'PY'
import json, sys
try:
    gates = json.load(open(sys.argv[1])).get("gates", {})
except Exception:
    print("unreadable")
    raise SystemExit(0)
print(" ".join(f"{k.split()[0]}={v.get('verdict', '?')}" for k, v in gates.items()))
PY
)

# Atomic publish: a reader never sees a half-written report.
mv "$TXT.header" "$OUT/gates-latest.txt"
mv "$JSON" "$OUT/gates-latest.json"
printf '{"ts":"%s","head":"%s","verdicts":"%s"}\n' "$STAMP" "$HEAD" "$VERDICTS" >>"$OUT/gates-history.jsonl"
rm -f "$OUT/.gates.err"

if [ -n "${NEXTNOTES_GATES_VERBOSE:-}" ]; then
  echo "gates report: $OUT/gates-latest.txt ($VERDICTS)"
fi
exit 0
