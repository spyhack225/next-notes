#!/bin/sh
# Invoke only through ../heavy.sh. Review-head producer RED, same fixtures GREEN,
# seven flags, three restored mutations and credential pattern checks in one slot.
set -eu
scratch=$1
evidence=$2
service=Sources/NextNotes/Calendar/CalendarService.swift
store=Sources/NextNotes/Calendar/Google/GoogleTokenStore.swift
binary=$scratch/debug/NextNotes
mkdir -p "$evidence"
cp "$service" "$evidence/CalendarService.green.swift"
cp "$store" "$evidence/GoogleTokenStore.green.swift"
git show "6e490cec:$service" > "$evidence/CalendarService.red.swift"
git show "6e490cec:$store" > "$evidence/GoogleTokenStore.red.swift"
# Read-only diagnostic accessor is the sole scaffold on the exact old service.
# It exposes its actual backing, adding no grant fence, transition or behavior.
python3 - "$evidence/CalendarService.red.swift" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
s=s.replace('    // MARK: - Lifecycle', '''    var googleCalendarCacheForTesting: [GoogleCalendarListEntry] {
        precondition(GoogleAccessTokens.testHooksAdmitted)
        return googleCalendars
    }

    // MARK: - Lifecycle''', 1)
p.write_text(s)
PY
restore() {
    if [ -f .google-replay-snapshot/Sources/NextNotes/Agent/Mac/MailDatabase.swift ]; then
        python3 Tests/GoogleOptionCReplay.py green .google-replay-snapshot
    fi
    cp "$evidence/CalendarService.green.swift" "$service"
    cp "$evidence/GoogleTokenStore.green.swift" "$store"
}
trap restore EXIT HUP INT TERM
python3 - "$evidence" <<'PY'
import datetime,hashlib,json,platform,subprocess,sys
from pathlib import Path
root=Path(sys.argv[1])
json.dump({'startedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'macOS':platform.mac_ver()[0],'architecture':platform.machine(),
 'head':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
 'originalProducers':'6e490cec CalendarService + GoogleTokenStore; read-only old cache accessor scaffold',
 'wrapper':'../heavy.sh FIFO, normal gates, RELAY_ID=claude2-google-c',
 'scope':'native isolated functional fixtures; no model/GUI/install/private OAuth input'},
 (root/'slot-metadata.json').open('w'),indent=2)
paths=sorted(Path('Sources/NextNotes/Calendar/Google').glob('Google*SelfTest.swift'))
(root/'fixture-sha256.txt').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p)+'\n' for p in paths))
PY
build() {
    stage=$1
    shasum -a 256 "$service" "$store" > "$evidence/$stage-source-sha256.txt"
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
cp "$evidence/CalendarService.red.swift" "$service"
cp "$evidence/GoogleTokenStore.red.swift" "$store"
build grant-transition-red
sh Tests/GoogleOptionCChecks.sh grant-transition-red "$binary" "$evidence/grant-transition-red"
cp "$evidence/CalendarService.green.swift" "$service"
cp "$evidence/GoogleTokenStore.green.swift" "$store"
build green
python3 Tests/GoogleOptionCHarnessTest.py > "$evidence/harness.log"
sh Tests/GoogleOptionCChecks.sh green "$binary" "$evidence/green"
shasum -a 256 -c "$evidence/fixture-sha256.txt" > "$evidence/fixture-invariance.log"
cmp "$evidence/CalendarService.green.swift" "$service"
cmp "$evidence/GoogleTokenStore.green.swift" "$store"
python3 Tests/GoogleCredentialScan.py > "$evidence/secret-scans.log"
echo GOOGLE_GRANT_PUBLICATION_BATCH_OK
