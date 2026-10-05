# Named-speaker meeting read — 2026-10-05

‘What did Sarah say about the budget?’ matched the existing frontend meeting question route but selected no meeting schema in the manifest. Reuse of that route now supplies selection when no explicit source matched. The existing AccountRead floor also recognizes the narrowly bound information-absence reply and reads the selected current meeting context. Explicit mail/file sources, clarification/advice and completed/unavailable controls remain unchanged. Historical meeting search is not implemented by this slice.

Revised unchanged COMMON original: five failures -> fixed PASS, with one actual registered read, two provider rounds, and exact returned Sarah/budget evidence at the final consumer. Capability-manifest, tool-review, voice-turn-routing and isolation pass. The first packet incorrectly required feature selection as an input precondition; its result remains UNQUALIFIED outside the repo, with the original request/raw preserved.

Pinned Mini native K03 now reads meeting.recent_context but says ‘Serge said’ rather than the fixture’s ‘Sarah said’. The grader returns PASS for the 10% detail, but that is not semantic acceptance. Speaker attribution, general historical lookup, full/owner/floor/latency and broader readiness stay OPEN; no correct native answer or aggregate improvement is claimed.

Evidence: `~/Library/Caches/NextNotesBuild/integration/k03-requested-meeting-absence/revision2/`. Bulk artifacts stay outside iCloud.
