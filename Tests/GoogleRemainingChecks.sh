#!/bin/sh
# ONLY through heavy.sh: one FIFO slot for original RED, fixed seven, mutations, scans.
set -eu
scratch=$1
evidence=$2
binary=$scratch/debug/NextNotes
snapshot=.google-review-work/v3/fixed-snapshot
mkdir -p "$evidence"
python3 - "$evidence/slot-metadata.json" <<'META'
import datetime,json,platform,subprocess,sys
json.dump({'startedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'macOS':platform.mac_ver()[0],'architecture':platform.machine(),
 'baseHead':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
 'wrapper':'../heavy.sh FIFO, normal gates, RELAY_ID=claude2-google-c',
 'scope':'isolated native functional fixtures; no model/GUI/install/private OAuth input'},open(sys.argv[1],'w'),indent=2)
META
python3 Tests/GoogleRemainingReplay.py capture "$snapshot"
restore() {
    if [ -f .google-review-work/v3/six-snapshot/Sources/NextNotes/Agent/AgentCapabilityManifest.swift ]; then
        python3 Tests/GoogleReviewReplay.py green .google-review-work/v3/six-snapshot
    fi
    python3 Tests/GoogleRemainingReplay.py green "$snapshot"
}
trap restore EXIT HUP INT TERM
pins() {
    python3 - "$evidence/$1-source-sha256.json" <<'PY'
import hashlib,json,sys
from pathlib import Path
paths=list(Path('Sources/NextNotes/Calendar/Google').glob('Google*SelfTest.swift'))
paths += [Path(p) for p in ['Sources/NextNotes/Calendar/Google/GoogleTokenStore.swift','Sources/NextNotes/Calendar/Google/GoogleAccessTokens.swift','Sources/NextNotes/Calendar/Google/GoogleCalendarProvider.swift','Sources/NextNotes/Calendar/Google/GoogleConnection.swift','Sources/NextNotes/Agent/GoogleWorkspaceCLI.swift','Sources/NextNotes/Calendar/CalendarService.swift']]
json.dump({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths},open(sys.argv[1],'w'),indent=2)
PY
}
build() {
    pins "$1"
    if ! swift build -c debug -j 2 --disable-automatic-resolution --scratch-path "$scratch" > "$evidence/$1-build.log" 2>&1; then
        # Retain a compile failure and the same slot for an explicit source correction.
        # No automatic retry and no build loop. Native/assertion failures still abort.
        cp "$evidence/$1-build.log" "$evidence/$1-first-build-failure.log"
        echo "BUILD_FAILED $1; waiting for explicit $evidence/resume-$1"
        while [ ! -f "$evidence/resume-$1" ]; do sleep 5; done
        rm "$evidence/resume-$1"
        pins "$1"
        swift build -c debug -j 2 --disable-automatic-resolution --scratch-path "$scratch" > "$evidence/$1-build.log" 2>&1
    fi
    shasum -a 256 "$binary" > "$evidence/$1-binary-sha256.txt"
}
make webrtc-audio > "$evidence/webrtc-build.log" 2>&1
python3 Tests/GoogleRemainingReplay.py remaining-red "$snapshot"
git diff > "$evidence/remaining-red.patch"
build remaining-red
sh Tests/GoogleOptionCChecks.sh remaining-red "$binary" "$evidence/remaining-red"
python3 Tests/GoogleRemainingReplay.py green "$snapshot"
# Real native six-finding replay proves the named harness still accepts behavioral RED.
python3 Tests/GoogleReviewReplay.py capture .google-review-work/v3/six-snapshot
python3 Tests/GoogleReviewReplay.py review-red .google-review-work/v3/six-snapshot
build review-red
sh Tests/GoogleOptionCChecks.sh review-red "$binary" "$evidence/review-red"
python3 Tests/GoogleReviewReplay.py green .google-review-work/v3/six-snapshot
build green
python3 Tests/GoogleOptionCHarnessTest.py > "$evidence/harness.log"
python3 Tests/GoogleOAuthInjectionTest.py > "$evidence/injection.log"
# This runs the seven flags, three producer mutations and the restored seven flags.
sh Tests/GoogleOptionCChecks.sh green "$binary" "$evidence/green"
shasum -a 256 -c "$evidence/fixture-sha256.txt" > "$evidence/fixture-invariance.log"
python3 Tests/GoogleCredentialScan.py > "$evidence/secret-scans.log"
echo GOOGLE_REMAINING_BATCH_OK
