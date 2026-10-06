#!/usr/bin/env bash
# Agent-safe Next Notes self-test launcher.
#
# - Waits on the same install lock `make install` holds, so it never races a
#   half-swapped `/Applications/Next Notes.app`.
# - Verifies the Mach-O exists and the bundle codesigns before launch.
# - Keeps this launcher in the foreground, waiting on its exact child, so the
#   parent shell stays alive through AppKit `_RegisterApplication`. Cursor-agent
#   shells that exit while NextNotes is still registering produce the
#   SIGABRT crash reports with Responsible=Cursor / Parent=Exited process.
# - Does not call `make install`, and never opens the GUI for its own sake.
#
# Usage:
#   Scripts/run-selftest.sh --selftest-graph-layout
#   Scripts/run-selftest.sh --via-open --selftest-systemaudio
#   Scripts/run-selftest.sh --out /tmp/out.txt --selftest-ask
#
# Env:
#   NEXTNOTES_APP   override app bundle (default /Applications/Next Notes.app)
#   NEXTNOTES_LOCK  override lockfile
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=${NEXTNOTES_APP:-"/Applications/Next Notes.app"}
BIN="$APP/Contents/MacOS/NextNotes"
LOCK=${NEXTNOTES_LOCK:-"$HOME/Library/Caches/NextNotesBuild/install.lock"}
VIA_OPEN=0
OUT=""
ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --via-open|--tcc)
      VIA_OPEN=1
      shift
      ;;
    --out)
      OUT=${2:?--out requires a path}
      shift 2
      ;;
    --under-lock)
      # Internal: already holding the install lock.
      shift
      UNDER_LOCK=1
      ;;
    -h|--help)
      sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ ${#ARGS[@]} -eq 0 ]]; then
  echo "error: pass at least one --selftest-… argument" >&2
  exit 2
fi

UNDER_LOCK=${UNDER_LOCK:-0}

if [[ "$UNDER_LOCK" != "1" ]]; then
  forward=(--under-lock)
  if [[ "$VIA_OPEN" == "1" ]]; then
    forward+=(--via-open)
  fi
  if [[ -n "$OUT" ]]; then
    forward+=(--out "$OUT")
  fi
  forward+=("${ARGS[@]}")
  exec "$ROOT/Scripts/with-install-lock.sh" "$LOCK" \
    "$ROOT/Scripts/run-selftest.sh" "${forward[@]}"
fi

if [[ -e "$APP.new" ]]; then
  echo "error: $APP.new exists — install still in progress or aborted mid-swap" >&2
  exit 1
fi
if [[ ! -x "$BIN" ]]; then
  echo "error: missing executable: $BIN" >&2
  echo "hint: make install OPEN=0   # never launch while install is copying" >&2
  exit 1
fi
if ! codesign --verify --verbose=2 "$APP" >/dev/null 2>&1; then
  echo "error: codesign verification failed for $APP" >&2
  codesign --verify --verbose=4 "$APP" 2>&1 | tail -20 >&2 || true
  exit 1
fi

# Own one disposable child directory, never the caller's TMPDIR itself.
owned_tmp=$(mktemp -d "${TMPDIR:-/tmp}/NextNotesSelfTest-run.XXXXXX")
export TMPDIR="$owned_tmp/"
child_pid=""
joined=0
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  retain=0
  if [[ -n "$child_pid" && "$joined" == "0" ]]; then
    kill -TERM "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
    # Joining open after interrupt does not prove its LaunchServices app joined.
    if [[ "$VIA_OPEN" == "1" ]]; then retain=1; fi
  fi
  if [[ "$retain" == "1" ]]; then
    echo "run-selftest: app join unproven; retained $owned_tmp" >&2
  else
    rm -rf -- "$owned_tmp"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$VIA_OPEN" == "1" ]]; then
  out=${OUT:-"/tmp/nextnotes-selftest-$$.txt"}
  rm -f "$out"
  echo "run-selftest: open -n -W $APP --args ${ARGS[*]} --selftest-out $out" >&2
  open -n -W "$APP" --env "TMPDIR=$TMPDIR" --args "${ARGS[@]}" --selftest-out "$out" &
  child_pid=$!
  launch_status=0
  wait "$child_pid" || launch_status=$?
  joined=1
  verdict_re='^[[:space:]]*[A-Z0-9_]+_(OK|FAILED|SILENT|MISSING)($|:)|SELFTEST_TIMEOUT'
  failed_re='^[[:space:]]*[A-Z0-9_]+_(FAILED|SILENT|MISSING)($|:)|SELFTEST_TIMEOUT'
  cat "$out" 2>/dev/null || true
  if [[ "$launch_status" != "0" ]] || ! grep -E "$verdict_re" "$out" >/dev/null 2>&1; then
    echo "error: self-test exited without a successful launch/verdict: $out" >&2
    exit 1
  fi
  if grep -E "$failed_re" "$out" >/dev/null 2>&1; then exit 1; fi
  exit 0
fi

cmd=("$BIN")
cmd+=("${ARGS[@]}")
if [[ -n "$OUT" ]]; then
  cmd+=(--selftest-out "$OUT")
fi
# Keep the foreground shell alive as parent until this exact child exits.
# A retained child PID lets signal cleanup forward and join without name-killing.
echo "run-selftest: direct ${cmd[*]}" >&2
"${cmd[@]}" <&0 &
child_pid=$!
run_status=0
wait "$child_pid" || run_status=$?
joined=1
exit "$run_status"
