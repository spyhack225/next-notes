#!/bin/bash
set -euo pipefail
report=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$report/../../../.." && pwd)
scratch=$(mktemp -d /tmp/nextnotes-meeting-ui-probe.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
python3 - "$repo" "$scratch" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1]); out=pathlib.Path(sys.argv[2])
source=(root/'Sources/NextNotes/UI/Components/LevelMeter.swift').read_text()
out.joinpath('LevelBar.swift').write_text('import SwiftUI\n' + source[source.index('struct LevelBar: View {'):])
PY
xcrun swiftc -swift-version 6 -parse-as-library -O \
  "$report/UIAllocationProbe.swift" \
  "$repo/Sources/NextNotes/UI/Meetings/MeetingLiveView.swift" \
  "$repo/Sources/NextNotes/UI/Meetings/TranscriptView.swift" \
  "$repo/Sources/NextNotes/UI/Components/ThinkingOrbs/ThinkingOrb.swift" \
  "$repo/Sources/NextNotes/UI/Components/ThinkingOrbs/OrbGeometry.swift" \
  "$repo/Sources/NextNotes/UI/Components/DottedField.swift" \
  "$repo/Sources/NextNotes/UI/Components/RecordingIndicator.swift" \
  "$scratch/LevelBar.swift" -o "$scratch/probe"
"$scratch/probe" "$@"
