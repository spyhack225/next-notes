#!/bin/sh
# Invoke through heavy.sh, one final slot: six-finding and additive RED -> fixed seven -> mutations/restored.
set -eu
scratch=$1
evidence=$2
binary=$scratch/debug/NextNotes
mkdir -p "$evidence"
python3 - "$evidence/slot-metadata.json" <<'META'
import datetime,json,platform,subprocess,sys
json.dump({'startedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'macOS':platform.mac_ver()[0],'architecture':platform.machine(),
 'baseHead':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
 'wrapper':'../heavy.sh FIFO, normal gates, RELAY_ID=claude2-google-c',
 'scope':'matched six-finding and Calendar withdrawal fixtures; no model/GUI/install/private OAuth input'},open(sys.argv[1],'w'),indent=2)
META
pins() {
    python3 - "$evidence/$1-source-sha256.json" <<'PINS'
import hashlib,json,sys
from pathlib import Path
paths=list(Path('Sources/NextNotes/Calendar/Google').glob('Google*SelfTest.swift'))
paths += [Path(p) for p in ['Sources/NextNotes/Calendar/Google/GoogleTokenStore.swift','Sources/NextNotes/Calendar/Google/GoogleAccessTokens.swift','Sources/NextNotes/Calendar/Google/GoogleOAuthClient.swift','Sources/NextNotes/Calendar/Google/GoogleCalendarProvider.swift','Sources/NextNotes/Calendar/Google/GoogleConnection.swift','Sources/NextNotes/Agent/GoogleWorkspaceCLI.swift','Sources/NextNotes/Agent/Mac/MacWorkspace.swift','Sources/NextNotes/Agent/AgentCapabilityManifest.swift','Sources/NextNotes/Calendar/CalendarService.swift']]
json.dump({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(set(paths))},open(sys.argv[1],'w'),indent=2)
PINS
}
trap 'python3 Tests/GoogleReviewReplay.py green .google-review-work/native-snapshot-v2' EXIT HUP INT TERM
# Existing queued candidate snapshot or a clean checkout of the final fixed source.
if [ ! -f .google-review-work/native-snapshot-v2/Sources/NextNotes/Calendar/CalendarService.swift ]; then
    python3 Tests/GoogleReviewReplay.py capture .google-review-work/native-snapshot-v2
fi
python3 Tests/GoogleReviewReplay.py review-red .google-review-work/native-snapshot-v2
pins review-red
git diff > "$evidence/review-red.patch"
swift build -c debug -j 2 --disable-automatic-resolution --scratch-path "$scratch" > "$evidence/review-red-build.log" 2>&1
shasum -a 256 "$binary" > "$evidence/review-red-binary-sha256.txt"
sh Tests/GoogleOptionCChecks.sh review-red "$binary" "$evidence/review-red"
# Same fixtures, retaining only the first repair's missed disabled-cache transition.
python3 Tests/GoogleReviewReplay.py withdrawal-red .google-review-work/native-snapshot-v2
pins withdrawal-red
git diff > "$evidence/withdrawal-red.patch"
swift build -c debug -j 2 --disable-automatic-resolution --scratch-path "$scratch" > "$evidence/withdrawal-red-build.log" 2>&1
shasum -a 256 "$binary" > "$evidence/withdrawal-red-binary-sha256.txt"
sh Tests/GoogleOptionCChecks.sh withdrawal-red "$binary" "$evidence/withdrawal-red"
python3 Tests/GoogleReviewReplay.py green .google-review-work/native-snapshot-v2
pins green
git diff > "$evidence/green.patch"
swift build -c debug -j 2 --disable-automatic-resolution --scratch-path "$scratch" > "$evidence/green-build.log" 2>&1
shasum -a 256 "$binary" > "$evidence/green-binary-sha256.txt"
python3 Tests/GoogleOAuthInjectionTest.py > "$evidence/injection.log"
python3 Tests/GoogleOptionCHarnessTest.py > "$evidence/harness.log"
sh Tests/GoogleOptionCChecks.sh green "$binary" "$evidence/green"
shasum -a 256 -c "$evidence/fixture-sha256.txt" > "$evidence/fixture-invariance.log"
echo GOOGLE_WITHDRAWAL_BATCH_OK
