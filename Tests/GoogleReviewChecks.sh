#!/bin/sh
# All native work (RED, GREEN, three mutations, restored seven flags) in one FIFO slot.
set -eu
scratch=$1
evidence=$2
snapshot=.google-review-work/native-snapshot
binary=$scratch/debug/NextNotes
mkdir -p "$evidence"
python3 - "$evidence/slot-metadata.json" <<'META'
import datetime,json,platform,subprocess,sys
json.dump({'startedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'macOS': platform.mac_ver()[0], 'architecture': platform.machine(),
    'baseHead': subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
    'wrapper': '../heavy.sh FIFO, normal gates, RELAY_ID=claude2-google-c',
    'scope': 'debug native functional fixtures; no models/GUI/install/private OAuth input'}, open(sys.argv[1],'w'),indent=2)
META
python3 Tests/GoogleReviewReplay.py capture "$snapshot"
trap 'python3 Tests/GoogleReviewReplay.py green "$snapshot"' EXIT HUP INT TERM
build() {
    swift build -c debug -j 2 --disable-automatic-resolution --scratch-path "$scratch" > "$evidence/$1-build.log" 2>&1
    shasum -a 256 "$binary" > "$evidence/$1-binary-sha256.txt"
    python3 - "$evidence/$1-source-sha256.json" <<'PINS'
import hashlib,json,sys
from pathlib import Path
import importlib.util
spec=importlib.util.spec_from_file_location('replay','Tests/GoogleReviewReplay.py')
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
json.dump({p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in m.FILES},open(sys.argv[1],'w'),indent=2)
PINS
}
make webrtc-audio > "$evidence/webrtc-build.log" 2>&1
python3 Tests/GoogleReviewReplay.py review-red "$snapshot"
git diff > "$evidence/review-red.patch"
build review-red
sh Tests/GoogleOptionCChecks.sh review-red "$binary" "$evidence/review-red"
python3 Tests/GoogleReviewReplay.py green "$snapshot"
build green
python3 Tests/GoogleOAuthInjectionTest.py > "$evidence/injection.log"
sh Tests/GoogleOptionCChecks.sh green "$binary" "$evidence/green"
shasum -a 256 -c "$evidence/fixture-sha256.txt" > "$evidence/fixture-invariance.log"
echo GOOGLE_REVIEW_BATCH_OK
