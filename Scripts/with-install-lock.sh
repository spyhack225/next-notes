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
import subprocess
import sys

lock_path = sys.argv[1]
cmd = sys.argv[2:]
os.makedirs(os.path.dirname(lock_path) or ".", exist_ok=True)
fd = open(lock_path, "a+", encoding="utf-8")
fcntl.flock(fd.fileno(), fcntl.LOCK_EX)
try:
    raise SystemExit(subprocess.call(cmd))
finally:
    fcntl.flock(fd.fileno(), fcntl.LOCK_UN)
    fd.close()
PY
