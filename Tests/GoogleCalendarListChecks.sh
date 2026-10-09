#!/bin/sh
# Invoke only through ../heavy.sh: actual old producer RED, fixed seven, mutations,
# restored seven and credential scans in one guarded machine slot.
set -eu
scratch=$1
evidence=$2
source=Sources/NextNotes/Calendar/CalendarService.swift
fixed=${3:-$source}
binary=$scratch/debug/NextNotes
mkdir -p "$evidence"
cp "$fixed" "$evidence/CalendarService.green.swift"
git show "08ffb2ec:$source" > "$evidence/CalendarService.red.swift"
restore() {
    if [ -f .google-replay-snapshot/Sources/NextNotes/Agent/Mac/MailDatabase.swift ]; then
        python3 Tests/GoogleOptionCReplay.py green .google-replay-snapshot
    fi
    cp "$evidence/CalendarService.green.swift" "$source"
}
trap restore EXIT HUP INT TERM
python3 - "$evidence" <<'PY'
import datetime,hashlib,json,platform,subprocess,sys
from pathlib import Path
root=Path(sys.argv[1])
json.dump({'startedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'macOS':platform.mac_ver()[0],'architecture':platform.machine(),
 'head':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
 'originalCalendarService':'08ffb2ec',
 'wrapper':'../heavy.sh FIFO, normal gates, RELAY_ID=claude2-google-c',
 'scope':'isolated native functional fixtures; no model/GUI/install/private OAuth input'},
 (root/'slot-metadata.json').open('w'),indent=2)
paths=sorted(Path('Sources/NextNotes/Calendar/Google').glob('Google*SelfTest.swift'))
(root/'fixture-sha256.txt').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p)+'\n' for p in paths))
PY
build() {
    stage=$1
    shasum -a 256 "$source" > "$evidence/$stage-source-sha256.txt"
    if ! swift build -c debug -j 2 --disable-automatic-resolution --scratch-path "$scratch" > "$evidence/$stage-build.log" 2>&1; then
        cp "$evidence/$stage-build.log" "$evidence/$stage-first-build-failure.log"
        echo "BUILD_FAILED $stage; waiting for explicit $evidence/resume-$stage"
        while [ ! -f "$evidence/resume-$stage" ]; do sleep 5; done
        rm "$evidence/resume-$stage"
        swift build -c debug -j 2 --disable-automatic-resolution --scratch-path "$scratch" > "$evidence/$stage-build.log" 2>&1
    fi
    shasum -a 256 "$binary" > "$evidence/$stage-binary-sha256.txt"
}
make webrtc-audio > "$evidence/webrtc-build.log" 2>&1
cp "$evidence/CalendarService.red.swift" "$source"
build calendar-list-red
sh Tests/GoogleOptionCChecks.sh calendar-list-red "$binary" "$evidence/calendar-list-red"
cp "$evidence/CalendarService.green.swift" "$source"
build green
python3 Tests/GoogleOptionCHarnessTest.py > "$evidence/harness.log"
sh Tests/GoogleOptionCChecks.sh green "$binary" "$evidence/green"
shasum -a 256 -c "$evidence/fixture-sha256.txt" > "$evidence/fixture-invariance.log"
cmp "$evidence/CalendarService.green.swift" "$source"
python3 Tests/GoogleCredentialScan.py > "$evidence/secret-scans.log"
echo GOOGLE_CALENDAR_LIST_BATCH_OK
