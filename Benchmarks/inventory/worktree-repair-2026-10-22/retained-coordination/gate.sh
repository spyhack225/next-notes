#!/bin/sh
# Wait up to 2 h: swap <= 8 GB, load <= 40, disk >= 10 GB, memory free >= 50%.
# memory_pressure's system-wide free percentage is derived from VM page statistics.
base="$HOME/Library/Caches/NextNotesBuild"
poll=30
limit=7200
if [ "${GATE_TESTING:-0}" = 1 ]; then
  : "${GATE_TEST_ROOT:?test root required}"
  base=$GATE_TEST_ROOT
  poll=${GATE_TEST_POLL:-1}
  limit=${GATE_TEST_LIMIT:-2}
fi
started=$(date +%s)
last_report=0
while :; do
  if [ -f "$base/root-delivery-priority" ]; then
    echo 'gate: held for serial-root fix verification/install; no heavy job started' >&2
    exit 75
  fi
  if [ "${GATE_TESTING:-0}" = 1 ]; then
    swap=${GATE_TEST_SWAP:-0}
    load=${GATE_TEST_LOAD:-0}
    free=${GATE_TEST_DISK:-100}
    memory=${GATE_TEST_MEMORY:-100}
  else
    swap=$(sysctl -n vm.swapusage 2>/dev/null | sed -En 's/.*used = ([0-9.]+)M.*/\1/p' | cut -d. -f1)
    load=$(sysctl -n vm.loadavg 2>/dev/null | awk '/^\{ [0-9]/ {print int($2)}')
    free=$(df -g / 2>/dev/null | awk 'NR==2{print $4}')
    memory=$(memory_pressure 2>/dev/null | sed -En 's/^System-wide memory free percentage: ([0-9]+)%/\1/p')
  fi
  for value in "$swap" "$load" "$free" "$memory"; do
    case "$value" in ''|*[!0-9]*) echo 'gate: cannot read swap/load/disk/memory here (sandboxed?); stopping' >&2; exit 2;; esac
  done
  [ "$memory" -le 100 ] || { echo 'gate: invalid memory percentage; stopping' >&2; exit 2; }
  if [ "$swap" -le 8192 ] && [ "$load" -le 40 ] && [ "$free" -ge 10 ] && [ "$memory" -ge 50 ]; then exit 0; fi
  now=$(date +%s)
  if [ $((now-last_report)) -ge 300 ]; then
    echo "gate: waiting (swap ${swap}M, load $load, free ${free}G, memory ${memory}%)" >&2
    last_report=$now
  fi
  [ $((now-started)) -lt "$limit" ] || { echo 'gate: gave up after 2 h' >&2; exit 1; }
  sleep "$poll"
done
