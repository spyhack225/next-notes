# Acceptance failure accounting — 2026-10-06

Confirmed producer bug: actual native-tools output ends NATIVE_TOOLS_FAILED (MiniCPM0/4 optional tool calls), but a separate CLOUD_ABSENT line makes acceptance.sh classify it SKIP. The first absence branch ignored a genuine failed backend. The existing classifier now retains the actual non-precondition failure and reports FAIL before considering an optional absence. Genuine absence stays SKIP; optional absence followed by successful available-backend checks stays PASS.

The unchanged actual output and six related classification cases produce original RED2 → fixed all6 GREEN. Portable regression: python3 Scripts/acceptance-classifier-selftest.py; shell syntax passes; every owned temporary directory removed. Fixture retains the actual0/4/Apple/cloud-absence/WRONG/FAILED sequence, excludes unrelated launcher/model path metadata. No native/model rerun, artifact/default or app behavior change.

Reclassified identical20 retained required-flag logs: **16PASS/4FAIL**, rather than16PASS/3FAIL/1SKIP. Native Mini0/4, voice-grounding, Needle function calls and not-signed-in Composio remain explicitly open. This reporting fix does not repair those product/backend failures, certify Phase1 or change any grade threshold. Underlying optional-tool result is unchanged.

Evidence outside iCloud: ~/Library/Caches/NextNotesBuild/integration/acceptance-failure-before-absence/{red-result.json,green-result.json,root-green.json,PRODUCER.patch}; current installed69115eb/57d90e70 same-log summary-corrected.json in integration/phase1-current-69115eb/remaining-required/. Canonical foreign script hunks/index retained; no AGENTS/roadmap edits.
