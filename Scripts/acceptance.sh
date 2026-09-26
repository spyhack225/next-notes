#!/usr/bin/env bash
# Tiered acceptance runner over the Next Notes self-test catalogue.
#
# The catalogue is ~140 `--selftest-…` flags, and most of them answer a question a
# release does not depend on. This runs a named tier sequentially through the same
# `Scripts/run-selftest.sh` launcher an agent would use by hand — so it shares the
# install lock and never races `make install` — captures each run's output, and
# classifies it. It never builds and never installs.
#
#   Scripts/acceptance.sh                      # all three tiers
#   Scripts/acceptance.sh --tier core          # release blockers only
#   Scripts/acceptance.sh --tier integration
#   Scripts/acceptance.sh --tier experimental
#   Scripts/acceptance.sh --dry-run            # print the manifest; run nothing
#   Scripts/acceptance.sh --only ui-strings --only orb   # restrict to named flags
#
# Or through make:
#
#   make acceptance [TIER=core|integration|experimental] [ARGS='--dry-run --only orb']
#
# Tier meanings
# -------------
#   CORE          Release blockers. A CORE FAIL makes this script exit non-zero. A CORE
#                 SKIP is reported and does not count as a pass, but does not gate:
#                 the task it names is environment-bound, not broken.
#   INTEGRATION   The seams between subsystems: knowledge index/search, graph and
#                 entity resolution, memory, routines/schedule, browser CDP, model
#                 roles and function calls.
#   EXPERIMENTAL  The rest of the catalogue — the newer experiments, the live and
#                 credential-bound diagnostics, and `--selftest-cleanup`. These are
#                 allowed to be red or to report an absent precondition honestly.
#
# Honest accounting
# -----------------
# The app's own rules are the source of truth: `writeSelfTest` in NextNotesApp.swift
# treats a leading `*_FAILED`, `*_SILENT`, `*_TIMEOUT` or `*_MISSING` marker as a
# declared failure (exit 1). This runner additionally classifies a run whose output
# names an absent precondition — `*_ABSENT`, `SYSTEM_AUDIO_SILENT`, or one of the
# `WAKE_*_MISSING` / `VOICE_FRONTEND_MISSING_WORKER_MODEL` diagnostics — as SKIP when
# that absence is the last word (i.e. no later `*_OK`). Anything else without a final
# `*_OK` is FAIL, including `SELFTEST_TIMEOUT` and a run that printed nothing at all.
# A skip is never counted in the `passed/total` fraction. Known-red tests are not
# special-cased to green.
#
# Per-test timeout
# ----------------
# Most entries pass `--selftest-timeout 300` explicitly; a few known-slow ones get a
# larger budget. `--selftest-cleanup` is deliberately run without the flag, because it
# sizes its own budget from `CleanupEvalCases.all` (see AGENTS.md) — overriding it
# with a flat number is what used to report a healthy run as hung. It is the long
# pole of the EXPERIMENTAL tier (model-backed engines run for hours).
#
# Flags that require an argument (`--selftest-transcribe <wav>`, `--selftest-notes`,
# `--selftest-voice-pipeline`, the acoustic speech replays, …) are deliberately not in
# any tier: without their file they are guaranteed `SELFTEST_FAILED`, which is noise
# rather than signal. Value-taking flags whose argument is optional are tiered and run
# without it.
#
# TCC-gated entries
# -----------------
# A self-test run from an agent shell is denied a grant the app itself holds, because
# TCC keys the grant to the *responsible* process and for a direct binary launch that
# is the shell (AGENTS.md, "A self-test run from a shell can be denied a grant"). An
# entry whose third field is `via-open` is launched through LaunchServices instead
# (`Scripts/run-selftest.sh --via-open`), which is the documented workaround; the app
# is then responsible and its own grants apply. `--dry-run` shows which entries these
# are. An unmarked entry that needs a grant will report the denial honestly — it is
# not special-cased.
#
# Logs: each run writes `<flag>.out` (the app's `--selftest-out` mirror) and
# `<flag>.log` (stdout+stderr) under
# `~/Library/Caches/NextNotesBuild/acceptance/<timestamp>-<pid>/` so a failure can be
# read back after the summary. Override with NEXTNOTES_ACCEPTANCE_DIR.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
export NEXTNOTES_FIXTURES="$ROOT/Tests/Fixtures"
LAUNCHER="$ROOT/Scripts/run-selftest.sh"
APP_SOURCE="$ROOT/Sources/NextNotes/NextNotesApp.swift"
APP=${NEXTNOTES_APP:-"/Applications/Next Notes.app"}

DRY_RUN=0
TIER=${TIER:-all}
ONLY=()

# Tier membership. Every flag here is a branch in
# `AppDelegate.runRequestedSelfTest` (NextNotesApp.swift); the pre-flight below
# re-checks that against the source so a renamed flag fails loudly instead of
# producing a mystery `SELFTEST_FAILED`.
CORE_ENTRIES=(
  # dictation — microphone and Accessibility, so LaunchServices
  "selftest-dictation|300|via-open"
  # meeting audio capture — the hub probe, not the live microphone
  "selftest-capture|300"
  # streaming transcription
  "selftest-stream|300"
  # wake live — synthetic fixtures through the real spotter (known red at the
  # shipped sensitivity; reported honestly)
  "selftest-wake-live|600"
  # voice conversation
  "selftest-voice-conversation|300"
  # acoustic full duplex — replay DSP, no microphone
  "selftest-acoustic-replay|300"
  "selftest-duplex|300"
  # action runtime / activity
  "selftest-action-runtime|300"
  "selftest-activity|300"
  # meeting live
  "selftest-meeting-live|300"
  # interrupted meetings resume at their stage (M-08). A lost meeting is a
  # release blocker, so this is CORE
  "selftest-meeting-resume|300"
  # tool loop
  "selftest-toolloop|300"
  # computer use — inspect/click/type on an owned window. Needs Accessibility, so
  # from an agent shell it reports COMPUTER_FAILED rather than a green lie.
  "selftest-computer|300"
  # ACP and MCP fixtures
  "selftest-acp|300"
  "selftest-mcp|300"
)

INTEGRATION_ENTRIES=(
  # knowledge index / search
  "selftest-index|300"
  "selftest-search|300"
  "selftest-ask|300"
  "selftest-embed|300"
  "selftest-file-index|300"
  # graph / entity resolution
  "selftest-extract|300"
  "selftest-resolve|300"
  "selftest-graph-layout|300"
  # memory
  "selftest-memory|300"
  "selftest-memory-review|300"
  "selftest-memory-portability|300"
  # routines / schedule
  "selftest-schedule|300"
  "selftest-routine-authority|300"
  "selftest-digest|300"
  "selftest-podcast|300"
  "selftest-guided|300"
  # browser CDP
  "selftest-cdp|300"
  "selftest-browser|300|via-open"
  # model roles
  "selftest-model-roles|300"
  # store isolation (P0-11): a harness run leaves the owner's real files and
  # modelRoles./modelLibrary./agent defaults untouched
  "selftest-store-isolation|300"
  "selftest-chat-template|300"
  "selftest-llm-prefix-cache|600"
  "selftest-usage-log|600"
  # live real-model tool-loop eval (P1-01). Acceptance passes no arguments, so this entry
  # is the full 30-case run; `--quick` is the per-task gate and is run by hand.
  "selftest-toolloop-live|9300"
  "selftest-toolloop-live-grader|300"
  # model architecture guard and private networking (P0-13, P0-19)
  "selftest-model-unopenable|300"
  "selftest-private-network|300"
  # function calls — optional Needle directory omitted, so the fallback model is
  # graded and `FUNCTION_CALLS_NEEDLE_ABSENT` stays informational
  "selftest-function-calls|600"
  # meeting transcript quality probe (M-16a)
  "selftest-meeting-quality|120"
  # map-reduce never drops facts (M-05; M-12 extends the cases)
  "selftest-notes-longform|300"
  # a cut-off notes answer says so instead of claiming nothing was decided (M-13)
  "selftest-notes-truncation|120"
  # nearest-run and neighbour fallback for far-end labels (M-04)
  "selftest-diarize-assign|120"
  # speaker-count hints, voice-print cluster merge and the measured threshold (M-03):
  # model-backed half runs the diarizer over both far-end fixtures three times
  "selftest-diarize-hints|600"
  # long-window meeting finals (M-01): reads $NEXTNOTES_FIXTURES/meetings, needs
  # Parakeet; without either it reports MEETING_FINALS_ABSENT, counted as SKIP
  "selftest-meeting-finals|900"
  # live transcription backlog bounded by audio seconds, windows merged (M-07):
  # a fake transcriber behind the queue, no model and no fixtures
  "selftest-meeting-backlog|300"
  # late system-audio tap join (M-09): injected capture and transcriber over an
  # isolated store; no microphone, no real tap, no model, no fixtures
  "selftest-meeting-tap-retry|120"
  # temporary audio kept 72 h with the disk guards (M-10): isolated store,
  # injected clock and free space, no model and no fixtures
  "selftest-audio-retention|120"
)

EXPERIMENTAL_ENTRIES=(
  "selftest-acoustic-live|600|via-open"
  "selftest-acoustic-tail|300"
  "selftest-acp-confirm|300"
  "selftest-acp-live|600"
  "selftest-agent-panes|300"
  # Phase 0 exit harness: three typed turns on the real Agent-role model. Needs a model
  # and the network; a cold multi-gigabyte load plus three turns outlives the flat budget.
  "selftest-agent-answers|900"
  "selftest-assemble|300"
  "selftest-avatar|300"
  "selftest-axreadback|300|via-open"
  "selftest-calendar|300"
  "selftest-calls|300"
  # Sizes its own budget from CleanupEvalCases.all; no --selftest-timeout here on
  # purpose. The long pole of this tier.
  "selftest-cleanup|"
  "selftest-cleanup-router|300"
  "selftest-cleanup-structure|300"
  "selftest-click-coordinate|300"
  "selftest-commandkey|300"
  "selftest-composio|300"
  "selftest-computer-actions|300"
  "selftest-computer-vision|300"
  "selftest-concurrent-voice|300"
  "selftest-contention|300"
  "selftest-context|300|via-open"
  "selftest-gws|300"
  "selftest-hf-search|600"
  "selftest-island|300"
  "selftest-learn|300"
  "selftest-llm-metal|900"
  "selftest-local-model-stream|600"
  "selftest-meeting-context|300"
  "selftest-meeting-live-tools|600"
  "selftest-meeting-reconcile|300"
  "selftest-meeting-reconcile-llm|600"
  "selftest-metrics|300"
  "selftest-microphone|300|via-open"
  "selftest-model-fit|300"
  "selftest-model-library|300"
  "selftest-notes-context|300"
  "selftest-onboarding|300"
  "selftest-openrouter|300"
  "selftest-openrouter-contract|300"
  "selftest-openrouter-speed|300"
  "selftest-orb|300"
  "selftest-parakeet|600"
  "selftest-pcm-callback|300"
  "selftest-pcm-reconfiguration|300"
  "selftest-persona|300"
  "selftest-playback-ledger|300"
  "selftest-portrait|300"
  "selftest-realtime|300"
  "selftest-residency|300"
  "selftest-s1|600"
  "selftest-scheduler|300"
  "selftest-seat-grid|300"
  "selftest-settings|300"
  "selftest-skills|600"
  "selftest-systemaudio|300|via-open"
  "selftest-systemaudio-timeout|300|via-open"
  "selftest-tasks|300"
  "selftest-tool-awareness|600"
  "selftest-tool-review|300"
  "selftest-toolloop-production|600"
  "selftest-tools|300"
  "selftest-transcript-bus|300"
  "selftest-tts|300"
  "selftest-tts-kokoro|600"
  "selftest-tts-pocket|900"
  "selftest-tts-pocket-session|600"
  "selftest-tts-stream|300"
  "selftest-ui-strings|300"
  "selftest-voice-capabilities|300"
  "selftest-voice-capabilities-live|600"
  "selftest-voice-delivery|300"
  "selftest-voice-echo-live|600|via-open"
  "selftest-voice-frontend|600"
  "selftest-voice-grounding|600"
  "selftest-voice-local|600"
  "selftest-voice-prompt-probe|600"
  "selftest-voice-scheduling|300"
  "selftest-voice-speculation|300"
  "selftest-voice-suspend|300"
  "selftest-voice-suspend-live|600|via-open"
  "selftest-voice-turn-routing|300"
  "selftest-voice-turns|300"
  "selftest-voice-work-lifecycle|300"
  "selftest-wake|300"
)

usage() {
  sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

entries_for() {
  case "$1" in
    core) printf '%s\n' "${CORE_ENTRIES[@]}" ;;
    integration) printf '%s\n' "${INTEGRATION_ENTRIES[@]}" ;;
    experimental) printf '%s\n' "${EXPERIMENTAL_ENTRIES[@]}" ;;
    *) return 1 ;;
  esac
}

tier_label() {
  case "$1" in
    core) printf 'CORE' ;;
    integration) printf 'INTEGRATION' ;;
    experimental) printf 'EXPERIMENTAL' ;;
  esac
}

normalize_flag() {
  local value=$1
  value=${value#--}
  value=${value#selftest-}
  printf '%s' "$value"
}

only_selected() {
  local normalized=${1#selftest-} candidate
  for candidate in "${ONLY[@]}"; do
    [[ "$candidate" == "$normalized" ]] && return 0
  done
  return 1
}

# A diagnostic that says the precondition this test names is absent. `*_ABSENT` and
# `*_SILENT` are suffix rules (`CDP_ABSENT`, `FUNCTION_CALLS_NEEDLE_ABSENT`,
# `SYSTEM_AUDIO_SILENT`); the rest are named because their marker does not end in a
# suffix the app itself treats as failure (`VOICE_FRONTEND_MISSING_WORKER_MODEL`).
# `NOTES_HEADINGS_MISSING` is a content failure and is deliberately not here.
is_precondition_absence() {
  case "$1" in
    *_ABSENT) return 0 ;;
    *_SILENT) return 0 ;;
    WAKE_MODEL_MISSING|WAKE_LIVE_MODEL_MISSING|WAKE_LIVE_FIXTURES_MISSING|\
    WAKE_LIVE_FIXTURE_MISSING|VOICE_FRONTEND_MISSING_WORKER_MODEL) return 0 ;;
    *) return 1 ;;
  esac
}

# Sets VERDICT (PASS|SKIP|FAIL) and REASON from the captured output and exit code.
classify() {
  local out=$1 log=$2 rc=$3
  # The `.out` mirror is what `--selftest-out` writes; the `.log` is stdout+stderr,
  # which is the same stream plus `print`-only lines some tests use for detail (and
  # for tests that never call `writeSelfTest` it is the only channel). Read both, the
  # mirror first, so the complete stream is considered and the last marker wins.
  local files=()
  if [[ -s "$out" ]]; then files+=("$out"); fi
  if [[ -s "$log" ]]; then files+=("$log"); fi
  VERDICT=FAIL
  REASON="no verdict line in the captured output"
  if (( ${#files[@]} == 0 )); then
    if [[ "$rc" != "0" ]]; then REASON="exited $rc with no output"; fi
    return
  fi

  local line_no=0 last_ok=0 last_fail=0 last_absence=0
  local ok_line="" fail_line="" absence_line="" last_line=""
  local line trimmed marker ch i len
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    if [[ -n "${line//[[:space:]]/}" ]]; then last_line=$line; fi
    # Same leading-marker shape `writeSelfTest` reads: uppercase ASCII, digits and
    # underscores up to the first other character.
    trimmed=${line#"${line%%[![:space:]]*}"}
    marker=""
    len=${#trimmed}
    i=0
    while (( i < len )); do
      ch=${trimmed:i:1}
      case "$ch" in
        [A-Z]|[0-9]|_) marker="$marker$ch" ;;
        *) break ;;
      esac
      i=$((i + 1))
    done
    [[ -z "$marker" ]] && continue
    case "$marker" in
      *_OK) last_ok=$line_no; ok_line=$trimmed ;;
      *_FAILED|*_TIMEOUT) last_fail=$line_no; fail_line=$trimmed ;;
      *_SILENT) last_fail=$line_no; fail_line=$trimmed ;;
      *_MISSING) last_fail=$line_no; fail_line=$trimmed ;;
    esac
    if is_precondition_absence "$marker"; then
      last_absence=$line_no; absence_line=$trimmed
    fi
  done < <(cat ${files[@]+"${files[@]}"} 2>/dev/null)

  if (( last_absence > 0 )) && { (( last_ok == 0 )) || (( last_absence > last_ok )); }; then
    # The thing this test names was not on the machine; the absence is the verdict.
    VERDICT=SKIP
    REASON=$absence_line
  elif (( last_ok > 0 )) && (( last_fail == 0 )) && [[ "$rc" == "0" ]]; then
    VERDICT=PASS
    REASON=$ok_line
  elif (( last_ok > 0 )) && (( last_fail == 0 )); then
    VERDICT=FAIL
    REASON="exited $rc after $ok_line"
  elif [[ -n "$fail_line" ]]; then
    VERDICT=FAIL
    REASON=$fail_line
  else
    VERDICT=FAIL
    REASON=$last_line
  fi
  REASON=${REASON:0:240}
}

run_one() {
  local tier=$1 flag=$2 timeout=$3 modes=$4
  local out="$RUN_DIR/$flag.out"
  local log="$RUN_DIR/$flag.log"
  local cmd=("$LAUNCHER")
  if [[ ",$modes," == *",via-open,"* ]]; then
    cmd+=(--via-open)
  fi
  cmd+=(--out "$out" "--$flag")
  if [[ -n "$timeout" ]]; then
    cmd+=(--selftest-timeout "$timeout")
  fi
  local started=$SECONDS
  local rc=0
  set +e
  "${cmd[@]}" >"$log" 2>&1
  rc=$?
  set -e
  classify "$out" "$log" "$rc"
  printf '  %-40s %-5s %ss\n' "--$flag" "$VERDICT" "$((SECONDS - started))" >&2
  if [[ "$VERDICT" != "PASS" ]]; then
    RESULTS_STATUS+=("$VERDICT")
    RESULTS_TIER+=("$tier")
    RESULTS_FLAG+=("--$flag")
    RESULTS_REASON+=("$REASON")
  fi
}

SELECTED=()
RESULTS_STATUS=()
RESULTS_TIER=()
RESULTS_FLAG=()
RESULTS_REASON=()

collect_selected() {
  local flag timeout modes entry
  SELECTED=()
  while IFS='|' read -r flag timeout modes; do
    [[ -z "$flag" ]] && continue
    if (( ${#ONLY[@]} > 0 )) && ! only_selected "$flag"; then continue; fi
    SELECTED+=("$flag|$timeout|$modes")
  done < <(entries_for "$1")
}

run_tier() {
  local tier=$1 label
  label=$(tier_label "$tier")
  collect_selected "$tier"
  if (( ${#SELECTED[@]} == 0 )); then return 0; fi

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s (%d)\n' "$label" "${#SELECTED[@]}"
    local entry flag timeout modes rest
    for entry in "${SELECTED[@]}"; do
      flag=${entry%%|*}
      rest=${entry#*|}
      timeout=${rest%%|*}
      modes=${rest#*|}
      printf '  Scripts/run-selftest.sh'
      if [[ ",$modes," == *",via-open,"* ]]; then printf ' --via-open'; fi
      printf ' --out <out> --%s' "$flag"
      if [[ -n "$timeout" ]]; then printf ' --selftest-timeout %s' "$timeout"; fi
      printf '\n'
    done
    printf '\n'
    return 0
  fi

  printf '== %s ==\n' "$label" >&2
  local total=0 passed=0 skipped=0
  local entry flag timeout modes rest
  for entry in "${SELECTED[@]}"; do
    flag=${entry%%|*}
    rest=${entry#*|}
    timeout=${rest%%|*}
    modes=${rest#*|}
    run_one "$tier" "$flag" "$timeout" "$modes"
    total=$((total + 1))
    case "$VERDICT" in
      PASS) passed=$((passed + 1)) ;;
      SKIP) skipped=$((skipped + 1)) ;;
    esac
    if [[ "$tier" == "core" && "$VERDICT" == "FAIL" ]]; then
      CORE_FAILURES=$((CORE_FAILURES + 1))
    fi
  done
  printf '%-12s %5s PASS' "$label" "$passed/$total"
  if (( skipped > 0 )); then printf '  (%d skipped)' "$skipped"; fi
  printf '\n'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --tier) TIER=${2:?--tier needs core, integration, experimental or all}; shift 2 ;;
    --only) ONLY+=("$(normalize_flag "${2:?--only needs a --selftest-… flag}")"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "acceptance: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$TIER" in
  core|integration|experimental|all) ;;
  *) echo "acceptance: unknown tier '$TIER' (core|integration|experimental|all)" >&2; exit 2 ;;
esac

if [[ "$DRY_RUN" != "1" && ! -x "$APP/Contents/MacOS/NextNotes" ]]; then
  echo "acceptance: missing $APP/Contents/MacOS/NextNotes" >&2
  echo "acceptance: run 'make install OPEN=0' first (this runner never installs)" >&2
  exit 2
fi

# Pre-flight: every selected flag must exist in the harness source, so a renamed flag
# fails here rather than as a mystery SELFTEST_FAILED after an hour.
if [[ -f "$APP_SOURCE" ]]; then
  preflight_missing=()
  for tier in core integration experimental; do
    collect_selected "$tier"
    if (( ${#SELECTED[@]} == 0 )); then continue; fi
    for entry in "${SELECTED[@]}"; do
      flag=${entry%%|*}
      if ! grep -q -- "\"--$flag\"" "$APP_SOURCE"; then
        preflight_missing+=("--$flag")
      fi
    done
  done
  if (( ${#preflight_missing[@]} > 0 )); then
    echo "acceptance: tier manifest names flags this build does not know:" >&2
    printf '  %s\n' "${preflight_missing[@]}" >&2
    exit 2
  fi
fi

if (( ${#ONLY[@]} > 0 )); then
  matched=0
  for tier in core integration experimental; do
    collect_selected "$tier"
    (( ${#SELECTED[@]} > 0 )) && matched=1
  done
  if (( matched == 0 )); then
    echo "acceptance: --only named no flag in the selected tier(s)" >&2
    exit 2
  fi
fi

CORE_FAILURES=0

if [[ "$DRY_RUN" == "1" ]]; then
  echo "acceptance dry run — no self-tests will run."
  echo
  case "$TIER" in
    all)
      run_tier core
      run_tier integration
      run_tier experimental
      ;;
    *) run_tier "$TIER" ;;
  esac
  exit 0
fi

RUN_DIR="${NEXTNOTES_ACCEPTANCE_DIR:-$HOME/Library/Caches/NextNotesBuild/acceptance/$(date +%Y%m%d-%H%M%S)-$$}"
mkdir -p "$RUN_DIR"
echo "acceptance: logs in $RUN_DIR" >&2

case "$TIER" in
  all)
    run_tier core
    run_tier integration
    run_tier experimental
    ;;
  *) run_tier "$TIER" ;;
esac

if (( ${#RESULTS_STATUS[@]} > 0 )); then
  echo
  i=0
  while (( i < ${#RESULTS_STATUS[@]} )); do
    printf '%-5s %-12s %-36s %s\n' \
      "${RESULTS_STATUS[$i]}" "${RESULTS_TIER[$i]}" "${RESULTS_FLAG[$i]}" "${RESULTS_REASON[$i]}"
    i=$((i + 1))
  done
fi

if (( CORE_FAILURES > 0 )); then
  exit 1
fi
exit 0
