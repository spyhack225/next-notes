#!/usr/bin/env bash
# Atomic install of the staged Next Notes.app into /Applications.
# Invoked under Scripts/with-install-lock.sh from the Makefile.
set -euo pipefail

APPNAME=${APPNAME:?}
EXEC=${EXEC:?}
BUNDLE=${BUNDLE:?}
STAGE=${STAGE:-$(dirname "$(dirname "$BUNDLE")")}
OPEN=${OPEN:-1}

pkill -x "$EXEC" 2>/dev/null || true

# Our staging bundle lives in a directory named after this make invocation
# (`install-<pid>`), so nothing here can be another run's half-assembled bundle.
# The lock is held for this whole script, which is what makes the swap below atomic
# with respect to other installs and to a self-test waiting on the same lock.
STAGE_RUN=$(dirname "$BUNDLE")

# Old probe/rollback bundles in the stage root also register with LaunchServices and can
# be selected in place of the installed app. Each is a `*.app` directly in the root, so
# this cannot reach a live `install-<pid>/` directory.
find "$STAGE" -maxdepth 1 -type d -name '*.app' -exec rm -rf {} +

# A make that died between staging and swapping leaves its `install-<pid>/` behind. Reap
# only directories older than a day, so a slow concurrent install is never touched.
find "$STAGE" -maxdepth 1 -type d -name 'install-*' -mtime +1 -exec rm -rf {} +

# Swap via a sibling `.new` bundle so LaunchServices never sees a half-deleted app.
rm -rf "/Applications/${APPNAME}.new"
cp -R "$BUNDLE" "/Applications/${APPNAME}.new"
if [[ ! -x "/Applications/${APPNAME}.new/Contents/MacOS/${EXEC}" ]]; then
  echo "error: installed bundle is missing Contents/MacOS/${EXEC}" >&2
  rm -rf "/Applications/${APPNAME}.new"
  exit 1
fi
rm -rf "/Applications/${APPNAME}"
mv "/Applications/${APPNAME}.new" "/Applications/${APPNAME}"
rm -rf "$STAGE_RUN"

if [[ "$OPEN" != "0" ]]; then
  open "/Applications/${APPNAME}"
fi
echo "installed to /Applications/${APPNAME}"
