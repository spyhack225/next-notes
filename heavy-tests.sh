#!/bin/bash
# bash 3.2; shell/process tests only. No builds, app, models, or live relay data.
set -u
here=$(cd "$(dirname "$0")" && pwd)
wrapper=${HEAVY_WRAPPER:-$here/heavy.sh}
original=${HEAVY_ORIGINAL:-0}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/heavy-tests.XXXXXX")
export HOME="$tmp/home"
base="$HOME/Library/Caches/NextNotesBuild"
mkdir -p "$base/wt"
export HEAVY_TESTING=1 HEAVY_TEST_ROOT="$base" HEAVY_TEST_PROCESS_ROOT=$$
export HEAVY_TEST_POLL=1 HEAVY_TEST_REPORT=1 HEAVY_TEST_LIMIT=15
export RELAY_ID=claude2-heavy-test AGENT_RELAY_HOME="$base/relay"
export HEAVY_TEST_GATE="$base/gate.sh"
cat > "$base/gate.sh" <<'GATE'
#!/bin/sh
exit 0
GATE
chmod +x "$base/gate.sh"
cp "$base/gate.sh" "$base/wt/gate.sh"
pids=
cleanup() {
  for p in $pids; do
    # Never signal a recycled PID belonging to somebody else.
    if ps -axo pid=,ppid= | awk -v p="$p" -v root="$$" '
      {parent[$1]=$2} END {for(i=0;p>0&&i<1000;i++){if(p==root)exit 0;p=parent[p]}exit 1}'; then
      kill -TERM "$p" 2>/dev/null || :
    fi
  done
  if [ -f "$AGENT_RELAY_HOME/broker.json" ]; then
    # This file belongs ONLY to the isolated daemon started by these tests.
    pid=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).pid)' "$AGENT_RELAY_HOME/broker.json")
    if ps -p "$pid" -o command= | grep -F -- "daemon --data-dir $AGENT_RELAY_HOME" >/dev/null; then
      kill -TERM "$pid" 2>/dev/null || :
    fi
    wait "$pid" 2>/dev/null || :
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
relay() { agent-relay "$@" --project "$base" --data-dir "$AGENT_RELAY_HOME"; }
relay join --as "$RELAY_ID" --runner shell >/dev/null || exit 1
relay join --as foreign-test --runner shell >/dev/null || exit 1
failures=0
checks=0
check() {
  checks=$((checks+1))
  if "$@"; then echo "PASS $label"; else echo "FAIL $label"; failures=$((failures+1)); fi
}
no_claim() {
  relay agents --active | node -e 'let s="";process.stdin.on("data",x=>s+=x);process.stdin.on("end",()=>process.exit(JSON.parse(s).claims.some(c=>c.scope==="machine"&&c.agentId==="claude2-heavy-test")?1:0))'
}
start() {
  rm -f "$base/entered" "$base/claim.json"
  "$wrapper" "$*" >"$base/log" 2>&1 &
  job=$!
  pids="$pids $job"
}
finish() {
  wait "$job"; rc=$?
}
wait_entered() {
  for ((i=0;i<100;i++)); do [ ! -f "$base/entered" ] || return 0; sleep .1; done
  return 1
}
cat > "$base/job.sh" <<'JOB'
#!/bin/sh
agent-relay agents --active --project "$HEAVY_TEST_ROOT" --data-dir "$AGENT_RELAY_HOME" > "$HEAVY_TEST_ROOT/claim.json"
touch "$HEAVY_TEST_ROOT/entered"
[ "${1:-}" != hold ] || sleep 30
exit "${1:-0}"
JOB
chmod +x "$base/job.sh"

# Queue fixtures use the real wrapper, fake commands, and a priority admission barrier.
# Pausing the oldest LIVE waiter makes v2's overtaking deterministic, rather than
# relying on unspecified kernel lock wake order. All three jobs overlap in time.
queue="$base/heavy-queue"
wait_ticket() {
  local target=$1
  for ((q=0;q<50;q++)); do
    if [ -d "$queue" ] && rg -l "^pid=$target$" "$queue"/*.ticket >/dev/null 2>&1; then return 0; fi
    sleep .1
  done
  return 1
}
queue_empty() {
  local f
  for f in "$queue"/*.ticket; do [ ! -e "$f" ] || return 1; done
}
queue_start() {
  # Reset shell-background ignored signals before exec so INT/HUP traps are tested.
  python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); signal.signal(signal.SIGHUP, signal.SIG_DFL); os.execv(sys.argv[1], sys.argv[1:])' "$wrapper" "$1" >"$base/queue-$2.log" 2>&1 &
  job=$!; pids="$pids $job"
}
# v2 has no tickets: its priority log still establishes that the waiter entered.
wait_queued() {
  local target=$1 log=$2
  for ((q=0;q<50;q++)); do
    if [ -d "$queue" ] && rg -l "^pid=$target$" "$queue"/*.ticket >/dev/null 2>&1; then return 0; fi
    if rg -q 'priority hold' "$log"; then return 0; fi
    sleep .1
  done
  return 1
}
touch "$base/root-delivery-priority"
queue_start "echo 1 >> '$base/order'; sleep 1" first; first=$job
label=fifo_first_waiting; check wait_queued "$first" "$base/queue-first.log"
kill -STOP "$first"
queue_start "echo 2 >> '$base/order'; sleep 1" second; second=$job
label=fifo_second_waiting; check wait_queued "$second" "$base/queue-second.log"
queue_start "echo 3 >> '$base/order'; sleep 1" third; third=$job
label=fifo_third_waiting; check wait_queued "$third" "$base/queue-third.log"
rm "$base/root-delivery-priority"
sleep 3
label=fifo_live_head_not_overtaken; check test ! -f "$base/order"
kill -CONT "$first"
wait "$first"; wait "$second"; wait "$third"
printf 'FIFO_ORDER=%s\n' "$(tr '\n' ',' < "$base/order")"
label=fifo_three_fake_jobs; check test "$(cat "$base/order")" = "$(printf '1\n2\n3')"
label=fifo_queue_position_report; check rg -q 'queue position [23]' "$base/queue-third.log"
label=fifo_tickets_released; check queue_empty
# A SIGKILL cannot run traps; its retained lowest ticket must be reaped by peers.
touch "$base/root-delivery-priority"
queue_start 'exit 0' dead; dead=$job
label=dead_waiter_has_ticket; check wait_ticket "$dead"
kill -KILL "$dead"; wait "$dead" 2>/dev/null || :
queue_start "touch '$base/dead-skipped'" skipped; skipped=$job
rm "$base/root-delivery-priority"
wait "$skipped"; rc=$?
label=dead_waiter_skipped; check test "$rc" = 0
label=dead_waiter_successor_ran; check test -f "$base/dead-skipped"
label=dead_waiter_ticket_reaped; check queue_empty
# Catchable signals must clean a waiting ticket immediately, without a successor.
touch "$base/root-delivery-priority"
for signal in TERM HUP INT; do
  queue_start 'exit 0' "killed-$signal"; killed=$job
  label="${signal}_waiter_has_ticket"; check wait_ticket "$killed"
  kill -"$signal" "$killed"
  wait "$killed" 2>/dev/null || :
  label="${signal}_waiter_ticket_removed"; check queue_empty
done
rm "$base/root-delivery-priority"
# Crash an admitted wrapper with no command descendants holding the descriptor.
# The short fake child has already exited; a STOP freezes its parent's wait return.
queue_start "touch '$base/crash-entered'; sleep 2" holder; holder=$job
for ((q=0;q<100;q++)); do [ ! -f "$base/crash-entered" ] || break; sleep .1; done
label=holder_crash_fixture_entered; check test -f "$base/crash-entered"
kill -STOP "$holder"
sleep 3
kill -KILL "$holder"; wait "$holder" 2>/dev/null || :
# SIGKILL also bypasses v2's relay cleanup. The same caller's successor must
# proceed without intervening cleanup, preserving v2's inherited-claim behavior.
queue_start "touch '$base/crash-recovered'" recovered; recovered=$job
wait "$recovered"; rc=$?
label=holder_crash_queue_proceeds; check test "$rc" = 0
label=holder_crash_successor_ran; check test -f "$base/crash-recovered"
label=holder_crash_ticket_reaped; check queue_empty
# Clean the retained caller-owned fixture claim only AFTER observing recovery.
# Recovery of a different caller's relay lease is outside the queue contract.
relay release --as "$RELAY_ID" --scope machine build >/dev/null
if [ "${HEAVY_QUEUE_ONLY:-0}" = 1 ]; then
  echo "HEAVY_QUEUE_CHECKS=$checks FAILURES=$failures"
  [ "$failures" = 0 ] && echo HEAVY_QUEUE_TESTS_OK && exit 0
  echo HEAVY_QUEUE_TESTS_FAILED; exit 1
fi

# Same actual renamed process fixture is used against v1 and v2.
/bin/bash -c 'exec -a swift-frontend /bin/sleep 3' &
foreign=$!; pids="$pids $foreign"
start "$base/job.sh 0"
sleep 1
label=foreign_process_blocks; check test ! -f "$base/entered"
finish
label=foreign_process_then_proceeds; check test "$rc" = 0
label=foreign_pid_reported; check rg -q "$foreign elapsed=" "$base/log"
if [ "$original" = 1 ]; then
  echo "HEAVY_ORIGINAL_CHECKS=$checks FAILURES=$failures"
  [ "$failures" = 0 ]; exit "$?"
fi
label=quiet_claim_present_during_job
check node -e 'const v=JSON.parse(require("fs").readFileSync(process.argv[1]));process.exit(v.claims.some(c=>c.agentId==="claude2-heavy-test"&&c.scope==="machine"&&c.resource==="build")?0:1)' "$base/claim.json"
label=success_releases_claim; check no_claim
start "$base/job.sh 37"; finish
label=exit_code_passthrough; check test "$rc" = 37
label=failure_releases_claim; check no_claim
for resource in build native model-evaluation; do
  relay claim --as foreign-test --scope machine "$resource" >/dev/null
  start "$base/job.sh 0"
  sleep 1
  label="foreign_${resource}_claim_blocks"; check test ! -f "$base/entered"
  relay release --as foreign-test --scope machine "$resource" >/dev/null
  finish
  label="foreign_${resource}_claim_then_proceeds"; check test "$rc" = 0
  label="foreign_${resource}_claim_reported"; check rg -q "foreign-test holds $resource" "$base/log"
done
# Active filtering never hides a retained claim, even in a different project room.
mkdir "$base/other-room"
agent-relay join --as other-room-peer --runner shell --project "$base/other-room" --data-dir "$AGENT_RELAY_HOME" >/dev/null
agent-relay claim --as other-room-peer --scope machine native --project "$base/other-room" --data-dir "$AGENT_RELAY_HOME" >/dev/null
start "$base/job.sh 0"; sleep 1
label=cross_project_claim_blocks; check test ! -f "$base/entered"
agent-relay release --as other-room-peer --scope machine native --project "$base/other-room" --data-dir "$AGENT_RELAY_HOME" >/dev/null
finish
label=cross_project_claim_then_proceeds; check test "$rc" = 0
start "$base/job.sh hold"
label=signal_fixture_entered; check wait_entered
# job.sh hold uses exit hold only if not terminated; SIGTERM must stop it first.
kill -TERM "$job"
finish
label=SIGTERM_exit; check test "$rc" = 143
label=SIGTERM_releases_claim; check no_claim
label=SIGTERM_command_stopped; check /bin/sh -c '! ps -axo command= | grep -F "$1/job.sh hold" | grep -v grep >/dev/null' sh "$base"
touch "$base/root-delivery-priority"
start "$base/job.sh 0"; sleep 1
label=priority_blocks; check test ! -f "$base/entered"
rm "$base/root-delivery-priority"
finish
label=priority_then_proceeds; check test "$rc" = 0
# Hold arising while blocked on the shared lock must also prevent entry.
/bin/sh -c 'exec 9>"$1/heavy.lock"; lockf -k -s 9; touch "$1/locked"; sleep 2' sh "$base" &
locker=$!; pids="$pids $locker"
while [ ! -f "$base/locked" ]; do sleep .1; done
start "$base/job.sh 0"
touch "$base/root-delivery-priority"; sleep 3
label=priority_inside_lock_blocks; check test ! -f "$base/entered"
rm "$base/root-delivery-priority"; finish
label=priority_inside_lock_proceeds; check test "$rc" = 0
# Wrapper serialization remains an actual lock, not a relay-only convention.
start 'sleep 2'; first=$job
sleep .3
start "$base/job.sh 0"; sleep .5
label=shared_lock_serializes; check test ! -f "$base/entered"
finish; wait "$first"
label=shared_lock_then_proceeds; check test "$rc" = 0
# Descendants of this wrapper cannot block their own admitted command.
start '/bin/bash -c "exec -a swiftc /bin/sleep 1"'
finish
label=own_heavy_descendant_allowed; check test "$rc" = 0
# A caller's already-owned claim must not be released by a nested invocation.
relay claim --as "$RELAY_ID" --scope machine build >/dev/null
start "$base/job.sh 0"; finish
label=preexisting_own_claim_allows_job; check test "$rc" = 0
label=preexisting_own_claim_preserved; check /bin/sh -c 'agent-relay agents --project "$1" --data-dir "$2" | grep -q "claude2-heavy-test"' sh "$base" "$AGENT_RELAY_HOME"
# Assert the retained claim (not merely the registered agent).
label=preexisting_claim_still_held
check node -e 'const v=JSON.parse(require("fs").readFileSync(process.argv[1]));process.exit(v.claims.some(c=>c.agentId==="claude2-heavy-test"&&c.scope==="machine"&&c.resource==="build")?0:1)' <(relay agents --active)
relay release --as "$RELAY_ID" --scope machine build >/dev/null
# Excluded peer claims on other resources do not block this wrapper.
relay join --as claude2-peer --runner shell >/dev/null
relay claim --as claude2-peer --scope machine native >/dev/null
start "$base/job.sh 0"; finish
label=own_peer_native_claim_excluded; check test "$rc" = 0
relay release --as claude2-peer --scope machine native >/dev/null
# Every required executable form, including the spaced installed app path.
for name in swift-build swiftc llama-bench 'NextNotes --selftest-test' '/Applications/Next Notes.app/Contents/MacOS/NextNotes --model-eval'; do
  /bin/bash -c 'exec -a "$1" /bin/sleep 3' sh "$name" &
  foreign=$!; pids="$pids $foreign"
  start "$base/job.sh 0"; sleep 1
  label="process_match_$name"; check test ! -f "$base/entered"
  finish
  label="process_match_proceeds_$name"; check test "$rc" = 0
  wait "$foreign"
done
# Bounded refusal: no command starts after a foreign process wait times out.
/bin/bash -c 'exec -a llama-server /bin/sleep 5' &
foreign=$!; pids="$pids $foreign"
export HEAVY_TEST_LIMIT=2
start "$base/job.sh 0"; finish
label=foreign_timeout_75; check test "$rc" = 75
label=foreign_timeout_never_runs; check test ! -f "$base/entered"
kill -TERM "$foreign" 2>/dev/null || :; wait "$foreign" 2>/dev/null || :
export HEAVY_TEST_LIMIT=15
# Simulated relay failure: explicit fallback, still using lock/process/gate.
cat > "$base/no-relay" <<'NO'
#!/bin/sh
exit 1
NO
chmod +x "$base/no-relay"
export HEAVY_TEST_RELAY_BIN="$base/no-relay"
start 'exit 19'; finish
label=relay_unreachable_passthrough; check test "$rc" = 19
label=relay_unreachable_disclosed; check rg -q 'without a claim' "$base/log"
unset HEAVY_TEST_RELAY_BIN
# A lost reply after an accepted claim must not leak that claim on error.
cat > "$base/lost-claim-reply" <<'LOST'
#!/bin/sh
if [ "$1" = claim ]; then
  agent-relay "$@" >/dev/null || exit 1
  exit 1
fi
exec agent-relay "$@"
LOST
chmod +x "$base/lost-claim-reply"
export HEAVY_TEST_RELAY_BIN="$base/lost-claim-reply" HEAVY_TEST_LIMIT=2
start "$base/job.sh 0"; finish
label=lost_claim_reply_returns_75; check test "$rc" = 75
label=lost_claim_reply_never_runs; check test ! -f "$base/entered"
label=lost_claim_reply_releases_claim; check no_claim
unset HEAVY_TEST_RELAY_BIN
export HEAVY_TEST_LIMIT=15
# Rejected gate must return its code without admitting the command or claim.
cat > "$base/reject-gate" <<'REJECT'
#!/bin/sh
exit 2
REJECT
chmod +x "$base/reject-gate"
export HEAVY_TEST_GATE="$base/reject-gate"
start "$base/job.sh 0"; finish
label=gate_error_passthrough; check test "$rc" = 2
label=gate_error_no_command; check test ! -f "$base/entered"
label=gate_error_no_claim; check no_claim
export HEAVY_TEST_GATE="$base/gate.sh"
# Exercise the actual gate producer through documented metric overrides.
export GATE_TESTING=1 GATE_TEST_ROOT="$base" GATE_TEST_POLL=1 GATE_TEST_LIMIT=1
export GATE_TEST_SWAP=8192 GATE_TEST_LOAD=40 GATE_TEST_DISK=10 GATE_TEST_MEMORY=50
"$here/../gate.sh" >"$base/gate.log" 2>&1; rc=$?
label=gate_exact_thresholds_pass; check test "$rc" = 0
for spec in SWAP=8193 LOAD=41 DISK=9; do
  env "GATE_TEST_$spec" "$here/../gate.sh" >"$base/gate.log" 2>&1; rc=$?
  label="gate_over_threshold_$spec"; check test "$rc" = 1
done
export GATE_TEST_MEMORY=49
"$here/../gate.sh" >"$base/gate.log" 2>&1; rc=$?
label=gate_memory_49_gives_up_1; check test "$rc" = 1
for field in SWAP LOAD DISK MEMORY; do
  env "GATE_TEST_$field=unreadable" "$here/../gate.sh" >"$base/gate.log" 2>&1; rc=$?
  label="gate_unreadable_${field}_2"; check test "$rc" = 2
done
touch "$base/root-delivery-priority"
"$here/../gate.sh" >"$base/gate.log" 2>&1; rc=$?
label=gate_priority_75; check test "$rc" = 75
rm "$base/root-delivery-priority"
echo "HEAVY_CHECKS=$checks FAILURES=$failures"
if [ "$failures" = 0 ]; then echo HEAVY_TESTS_OK; else echo HEAVY_TESTS_FAILED; exit 1; fi
