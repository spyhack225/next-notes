#!/bin/sh
# macOS /bin/sh (bash 3.2). One command string, as in v1.
# Test overrides are enabled ONLY by HEAVY_TESTING=1; see RULES-2.md.
set -u
base="$HOME/Library/Caches/NextNotesBuild"
gate="$base/wt/gate.sh"
poll=20
limit=10800
report=60
process_root=0
relay_project=${HEAVY_RELAY_PROJECT:-$HOME/Documents/Claude/Projects/speechify}
relay_id=${RELAY_ID:-claude2-heavy}
relay_bin=agent-relay
if [ "${HEAVY_TESTING:-0}" = 1 ]; then
  : "${HEAVY_TEST_ROOT:?test root required}"
  base=$HEAVY_TEST_ROOT
  gate=${HEAVY_TEST_GATE:-$base/gate.sh}
  poll=${HEAVY_TEST_POLL:-1}
  limit=${HEAVY_TEST_LIMIT:-20}
  report=${HEAVY_TEST_REPORT:-1}
  process_root=${HEAVY_TEST_PROCESS_ROOT:-0}
  relay_project=$base
  relay_bin=${HEAVY_TEST_RELAY_BIN:-agent-relay}
  export AGENT_RELAY_HOME="$base/relay"
fi
[ "$#" -gt 0 ] || { echo 'Usage: heavy.sh "command"' >&2; exit 64; }
relay() {
  if [ "${HEAVY_TESTING:-0}" = 1 ]; then
    "$relay_bin" "$@" --project "$relay_project" --data-dir "$AGENT_RELAY_HOME"
  else
    "$relay_bin" "$@" --project "$relay_project"
  fi
}
claimed=0
inherited_claim=0
claim_pending=0
child=
release_claim() {
  if [ "$claimed" = 1 ] || [ "$claim_pending" = 1 ]; then
    relay release --as "$relay_id" --scope machine build >/dev/null 2>&1 ||
      echo 'heavy: relay release failed; own build claim may need attention' >&2
    claimed=0
    claim_pending=0
  fi
}
queue="$base/heavy-queue"
ticket=
cleanup() {
  release_claim
  [ -z "$ticket" ] || rm -f "$ticket"
  rm -f "$queue/counter-$$.tmp"
}
on_signal() {
  trap '' HUP INT TERM
  if [ -n "$child" ]; then
    # Job control gives ONLY our command its own process group.
    kill -TERM -- "-$child" 2>/dev/null || :
    wait "$child" 2>/dev/null || :
  fi
  exit "$1"
}
trap cleanup EXIT
trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
# Allocate a monotonically numbered ticket before any admission wait. The short
# allocator lock protects numbering only; it never owns the heavy job slot.
# Its inherited descriptor is kernel-released even if the allocator crashes.
mkdir -p "$queue" || exit 75
exec 8>"$queue/number.lock"
lockf -k -s 8 || exit "$?"
number=0
if [ -f "$queue/last-number" ]; then
  read -r number < "$queue/last-number" || exit 75
  case "$number" in ''|*[!0-9]*) echo 'heavy: unreadable queue counter; not run' >&2; exit 75;; esac
fi
number=$((number+1))
[ "$number" -gt 0 ] || { echo 'heavy: queue counter exhausted; not run' >&2; exit 75; }
# Publish counter first: a crash may leave a gap, never a reused number.
printf '%s\n' "$number" > "$queue/counter-$$.tmp" &&
  mv -f "$queue/counter-$$.tmp" "$queue/last-number" || exit 75
ticket="$queue/$(printf '%020d' "$number")-$$.ticket"
# PID in the name makes even a not-yet-written ticket a live reservation.
(set -C; printf 'pid=%s\nagent=%s\ntimestamp=%s\n' "$$" "$relay_id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$ticket") || exit 75
exec 8>&-
queue_last_report=0
while :; do
  position=1
  for entry in "$queue"/*.ticket; do
    [ -f "$entry" ] || continue
    name=${entry##*/}
    owner=${name#*-}; owner=${owner%.ticket}
    case "$owner" in ''|*[!0-9]*) echo "heavy: invalid queue ticket $name; not run" >&2; exit 75;; esac
    if ! kill -0 "$owner" 2>/dev/null; then
      rm -f "$entry"
      continue
    fi
    # Fixed-width names sort in ticket order, independent of directory order.
    if [ "$entry" \< "$ticket" ]; then position=$((position+1)); fi
  done
  now=$(date +%s)
  if [ "$position" = 1 ] && [ ! -f "$base/root-delivery-priority" ]; then break; fi
  if [ $((now-queue_last_report)) -ge "$report" ]; then
    printf 'heavy: queue position %s%s, waiting\n' "$position" "$( [ ! -f "$base/root-delivery-priority" ] || printf '; serial-root priority hold' )" >&2
    queue_last_report=$now
  fi
  sleep "$poll"
done
# Only the lowest live ticket may contend for the existing shared lock. Retain
# the ticket throughout all v2 admission checks and the command itself.
exec 9>"$base/heavy.lock"
while :; do
  lockf -k -s -t "$report" 9 2>/dev/null && break
  lock_result=$?
  [ "$lock_result" = 75 ] || exit "$lock_result"
  echo 'heavy: queue position 1, waiting for shared lock' >&2
done
started=$(date +%s)
last_report=0
relay_warned=0
foreign_processes() {
  census=$(ps -axo pid=,ppid=,etime=,command=) || return 2
  printf '%s\n' "$census" | awk -v own="$$" -v root="$process_root" '
    { pid=$1; parent[pid]=$2; elapsed[pid]=$3; $1=$2=$3=""; sub(/^ +/, ""); cmd[pid]=$0 }
    function below(p, ancestor, steps) {
      for (steps=0; p>0 && steps<1000; steps++) {
        if (p==ancestor) return 1;
        if (!(p in parent) || parent[p]==p) return 0;
        p=parent[p];
      }
      return 0;
    }
    END {
      for (p in cmd) {
        if (below(p,own) || (root>0 && !below(p,root))) continue;
        c=cmd[p];
        # Match executable tokens, not commands mentioned in shell source/arguments.
        heavy=(c ~ /^([^ ]*\/)?(swift-build|swift-frontend|swiftc|llama-bench|llama-server)( |$)/);
        # Quoted/spaced installed bundle paths are handled by this executable prefix.
        if (c ~ /^([^ ]*\/)?NextNotes( |$)/ || c ~ /^\/.*\.app\/Contents\/MacOS\/NextNotes( |$)/)
          heavy=heavy || c ~ / --(selftest[^ ]*|[^ ]*eval[^ ]*)( |$)/;
        if (heavy) print p " elapsed=" elapsed[p] " " substr(c,1,180);
      }
    }'
}
claims_view() {
  node -e '
    let s="";process.stdin.on("data",x=>s+=x);process.stdin.on("end",()=>{
      try {
        const v=JSON.parse(s); if(v.ok!==true||!Array.isArray(v.claims)||!Array.isArray(v.agents))throw Error();
        for(const c of v.claims) if(c.scope==="machine" && ["build","native","model-evaluation"].includes(c.resource)
          && !/^claude2-/.test(c.agentId) && c.agentId!=="claude-positioning")
          console.log(c.agentId+" holds "+c.resource+" age="+Math.floor(c.ageMs/1000)+"s");
      }catch(e){process.exitCode=2;}
    });'
}
while :; do
  now=$(date +%s)
  if [ $((now-started)) -ge "$limit" ]; then
    echo 'heavy: gave up after 3 h waiting for foreign heavy work; not run' >&2
    exit 75
  fi
  # Recheck priority INSIDE the lock (a hold can appear while we waited).
  blocked=
  [ ! -f "$base/root-delivery-priority" ] || blocked='priority hold'
  processes=$(foreign_processes) || { echo 'heavy: cannot read process census; not run' >&2; exit 75; }
  [ -z "$processes" ] || blocked="${blocked}${blocked:+
}$processes"
  relay_ok=0
  if view=$(relay agents --active 2>/dev/null) && claims=$(printf '%s' "$view" | claims_view); then
    relay_ok=1
    [ -z "$claims" ] || blocked="${blocked}${blocked:+
}$claims"
  elif [ "$relay_warned" = 0 ]; then
    echo 'heavy: relay unreachable/unreadable; continuing without a claim' >&2
    relay_warned=1
  fi
  if [ -z "$blocked" ]; then
    # Gate may wait; recheck foreign work AFTER it returns before taking a claim.
    "$gate" || exit "$?"
    processes=$(foreign_processes) || { echo 'heavy: cannot read process census; not run' >&2; exit 75; }
    if [ -n "$processes" ]; then blocked=$processes
    elif [ "$relay_ok" = 1 ]; then
      # Register only if absent; never reset an existing agent task/status.
      if ! printf '%s' "$view" | node -e 'let s="";process.stdin.on("data",x=>s+=x);process.stdin.on("end",()=>process.exit(JSON.parse(s).agents.some(a=>a.agentId===process.argv[1])?0:1))' "$relay_id"; then
        relay join --as "$relay_id" --runner shell >/dev/null 2>&1 || relay_ok=0
      fi
      # Refresh all machine claims (including native/model-evaluation) after the gate.
      if view=$(relay agents --active 2>/dev/null) && claims=$(printf '%s' "$view" | claims_view); then
        if [ -n "$claims" ]; then blocked=$claims
        else
          # Preserve a claim the caller already owned; release only ours.
          if printf '%s' "$view" | node -e 'let s="";process.stdin.on("data",x=>s+=x);process.stdin.on("end",()=>process.exit(JSON.parse(s).claims.some(c=>c.scope==="machine"&&c.resource==="build"&&c.agentId===process.argv[1]&&c.project===process.argv[2])?0:1))' "$relay_id" "$(cd "$relay_project" && pwd -P)"; then
            inherited_claim=1
          else
          claim_pending=1
          if relay claim --as "$relay_id" --scope machine build >/dev/null 2>&1; then
            claimed=1
            claim_pending=0
          else
            # Also release after an ambiguous claim reply: it may have committed.
            release_claim
            # A conflict (including an excluded claude2 peer) must never run unclaimed.
            if relay agents --active >/dev/null 2>&1; then blocked='build claim unavailable'
            else relay_ok=0; fi
          fi
          fi
        fi
      else relay_ok=0; fi
    fi
    if [ -z "$blocked" ]; then
      if [ "$claimed" = 0 ] && [ "$inherited_claim" = 0 ]; then echo 'heavy: relay unavailable; running without a claim' >&2; fi
      [ ! -f "$base/root-delivery-priority" ] || { echo 'heavy: priority held; not run' >&2; exit 75; }
      # Keep a supervisor for traps, preserving the command exit code exactly.
      set -m
      /bin/sh -c "$*" &
      child=$!
      wait "$child"
      result=$?
      child=
      exit "$result"
    fi
  fi
  if [ $((now-last_report)) -ge "$report" ]; then
    printf 'heavy: queue position 1, waiting for foreign work:\n%s\n' "$blocked" >&2
    last_report=$now
  fi
  sleep "$poll"
done
