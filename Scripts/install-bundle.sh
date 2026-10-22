#!/usr/bin/env bash
# Atomic install of the staged Next Notes.app into /Applications.
# Invoked under Scripts/with-install-lock.sh from the Makefile.
set -euo pipefail

APPNAME=${APPNAME:?}
EXEC=${EXEC:?}
BUNDLE=${BUNDLE:?}
STAGE=${STAGE:-$(dirname "$(dirname "$BUNDLE")")}
OPEN=${OPEN:-1}

# Never stop another checkout's diagnostics (or interrupt an active recording).
# The release caller closes the installed app gracefully before taking this lock.
python3 - "/Applications/$APPNAME/Contents/MacOS/$EXEC" <<'PY'
import ctypes, os, subprocess, sys
installed = os.path.realpath(sys.argv[1])
libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
active = []
processes = subprocess.run(['pgrep', '-x', os.path.basename(installed)], capture_output=True, text=True)
if processes.returncode not in (0, 1):
    sys.exit('Could not check whether Next Notes is open; installed app retained.')
for pid in processes.stdout.split():
    path = ctypes.create_string_buffer(4096)
    if libproc.proc_pidpath(int(pid), path, len(path)) > 0 and os.path.realpath(os.fsdecode(path.value)) == installed:
        active.append(pid)
if active:
    sys.exit('Please quit Next Notes before installing. Your current work has not been interrupted.')
PY

# Our staging bundle lives in a directory named after this make invocation
# (`install-<pid>`), so nothing here can be another run's half-assembled bundle.
# The lock is held for this whole script, which is what makes the swap below atomic
# with respect to other installs and to a self-test waiting on the same lock.
STAGE_RUN=$(dirname "$BUNDLE")

# Other build and rollback folders belong to their owners; install cleans only its
# own staging directory after success.

# Swap via a sibling `.new` bundle so LaunchServices never sees a half-deleted app.
rm -rf "/Applications/${APPNAME}.new"
cp -R "$BUNDLE" "/Applications/${APPNAME}.new"
if [[ ! -x "/Applications/${APPNAME}.new/Contents/MacOS/${EXEC}" ]]; then
  echo "error: installed bundle is missing Contents/MacOS/${EXEC}" >&2
  rm -rf "/Applications/${APPNAME}.new"
  exit 1
fi
if ! codesign --verify --deep --strict "/Applications/${APPNAME}.new"; then
  rm -rf "/Applications/${APPNAME}.new"
  echo "error: candidate signature failed; installed app retained" >&2
  exit 1
fi
rollback=""
if [[ -d "/Applications/${APPNAME}" ]]; then
  rollback="$STAGE/rollback/$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$rollback"
  mv "/Applications/${APPNAME}" "$rollback/$APPNAME"
fi
if ! mv "/Applications/${APPNAME}.new" "/Applications/${APPNAME}"; then
  if [[ -n "$rollback" ]]; then mv "$rollback/$APPNAME" "/Applications/${APPNAME}"; fi
  exit 1
fi
if [[ -n "$rollback" ]]; then echo "previous app retained at $rollback/$APPNAME"; fi
rm -rf "$STAGE_RUN"

if [[ "$OPEN" != "0" ]]; then
  open "/Applications/${APPNAME}"
fi
echo "installed to /Applications/${APPNAME}"
