# Requested mail read, M03 — 2026-10-06

Confirmed cause: AgentAccountRead treated `now` as a denial through the `no` prefix; its tokenizer also split ASCII/curly “can’t” into `can,t` without recognizing that refusal. The existing read-promise producer now compares standalone no/not exactly and recognizes the contraction pair. Other denial stems and permissions are preserved.

The same corrected original production-path fixture fails 12 assertions; the qualified fix passes. It retains “Let me check your email now.” and the captured final reply, exercises the real typed handle/runner/validation/fire boundary, performs one newest-mail read and gives the complete returned message to the final provider. Explicit refusal, plural request, already-completed read and can-tomorrow controls pass. The fixture separately verifies the existing removal of an unauthored inbox filter; no mail-filter product change was made.

The shared qualified build also passes C04, the full production tool loop, capability manifest, tool review and store isolation (21 files/32 defaults unchanged). All six child temporary roots were deleted. Binary SHA: 8b3a34bb8bed42a33a98dbb2d9962e02ff89b965a86decf62f730863e597caec. No new model pass, wait, store or approval was added. Native quick/full/owner/latency acceptance remains open.

Raw original/fixed logs and results: ~/Library/Caches/NextNotesBuild/integration/read-promise-qualified/{original-corrected-common-result.json,fixed-final-result.json}.
