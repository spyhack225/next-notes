#!/usr/bin/env bash
# Atomic install of the staged Next Notes.app into /Applications.
# Invoked under Scripts/with-install-lock.sh from the Makefile.
set -euo pipefail

APPNAME=${APPNAME:?}
EXEC=${EXEC:?}
BUNDLE=${BUNDLE:?}
OPEN=${OPEN:-1}

pkill -x "$EXEC" 2>/dev/null || true

# Old probe/rollback bundles in this dedicated cache also register with
# LaunchServices and can be selected in place of the installed app.
STAGE_DIR=$(dirname "$BUNDLE")
find "$STAGE_DIR" -maxdepth 1 -type d -name '*.app' ! -name "$APPNAME" -exec rm -rf {} +
rm -rf "$STAGE_DIR/dmg-root/$APPNAME"

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
rm -rf "$BUNDLE"

if [[ "$OPEN" != "0" ]]; then
  open "/Applications/${APPNAME}"
fi
echo "installed to /Applications/${APPNAME}"
