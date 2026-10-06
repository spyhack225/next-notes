#!/usr/bin/env bash
# Exclusive lock around install and self-test so they never overlap.
# macOS has no util-linux `flock(1)`; hold the lock in Python while the
# child command runs.
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <lockfile> <command> [args...]" >&2
  exit 2
fi

LOCKFILE=$1
shift

mkdir -p "$(dirname "$LOCKFILE")"

exec python3 - "$LOCKFILE" "$@" <<'PY'
import fcntl
import os
import signal
import subprocess
import sys

lock_path = sys.argv[1]
cmd = sys.argv[2:]
os.makedirs(os.path.dirname(lock_path) or ".", exist_ok=True)
fd = open(lock_path, "a+", encoding="utf-8")
fcntl.flock(fd.fileno(), fcntl.LOCK_EX)
child = None
pending_signal = None

def forward_signal(signum, _frame):
    global pending_signal
    pending_signal = signum
    if child is not None:
        try:
            child.send_signal(signum)
        except ProcessLookupError:
            pass

for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(signum, forward_signal)
try:
    child = subprocess.Popen(cmd)
    if pending_signal is not None:
        forward_signal(pending_signal, None)
    status = child.wait()  # Keep the lock until the exact launcher has joined.
    raise SystemExit(128 + pending_signal if pending_signal is not None else status)
finally:
    fcntl.flock(fd.fileno(), fcntl.LOCK_UN)
    fd.close()
PY
