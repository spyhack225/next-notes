#!/bin/sh
# Invoke only through ../heavy.sh after the fixed seven-check batch has passed.
# Three explicit builds are necessary to exercise three different native producers.
set -eu
scratch=$1
evidence=$2
snapshot=.google-replay-snapshot
binary=$scratch/debug/NextNotes
trap 'python3 Tests/GoogleOptionCReplay.py green "$snapshot"' EXIT HUP INT TERM
mutation() {
    mode=$1
    source=$2
    python3 Tests/GoogleOptionCReplay.py "$mode" "$snapshot"
    mkdir -p "$evidence/$mode"
    python3 - "$snapshot/$source" "$source" > "$evidence/$mode.patch" <<'PY'
import difflib, pathlib, sys
before, after = map(pathlib.Path, sys.argv[1:])
sys.stdout.writelines(difflib.unified_diff(before.read_text().splitlines(True),
    after.read_text().splitlines(True), fromfile="fixed/" + str(after),
    tofile="mutation/" + str(after)))
PY
    swift build -c debug -j 2 --disable-automatic-resolution --scratch-path "$scratch" > "$evidence/$mode-build.log" 2>&1
    sh Tests/GoogleOptionCChecks.sh "$mode" "$binary" "$evidence/$mode"
    shasum -a 256 "$binary" > "$evidence/$mode-binary-sha256.txt"
}
mutation revocation Sources/NextNotes/Calendar/Google/GoogleAccessTokens.swift
mutation unpinned Sources/NextNotes/Agent/GoogleWorkspaceCLI.swift
mutation mailbox Sources/NextNotes/Agent/Mac/MailDatabase.swift
python3 Tests/GoogleOptionCReplay.py green "$snapshot"
swift build -c debug -j 2 --disable-automatic-resolution --scratch-path "$scratch" > "$evidence/restored-build.log" 2>&1
sh Tests/GoogleOptionCChecks.sh restored "$binary" "$evidence/restored"
shasum -a 256 "$binary" > "$evidence/restored-binary-sha256.txt"
echo GOOGLE_OPTION_C_MUTATIONS_RESTORED_OK
