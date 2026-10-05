# Installed Agent quality checkpoint — 2026-10-05

Tested code: b11df78. Installed binary SHA256 `0079ba3f673cac62a2ef51d6c7785358f0e80640b4828ac274552a6133ac3ae7`. Explicit MiniCPM5-2B-Q4_K_M file, baseline sampler, New York timezone, fixed Oct 5 09:00 clock and unchanged binary. Load 1.8–2.5, swap 1.50 GiB, free disk above 14 GiB at admission. Raw rounds and model receipts stay outside iCloud.

| Instrument after native scheduling-fixture correction | Results |
|---|---|
| Quick, three runs | 9/10, 8/10, 9/10; min 8, median 9, max 9 |
| Full, consecutive runs | 25/30 and 25/30 |
| Owner cases | 8/10 in both runs |

The numeric full threshold is met, but one quick run falls below 9/10 and owner acceptance remains open. Both full runs fail R01 reminder completion, R02 repeating-reminder arguments, F02 current projects, F03 pricing-document follow-through and N01 identity roles. N03's actual Australia/Canberra request passes in both current runs. R02 now fails truthfully on unsupported model=gpt-4o-mini: routine proposals bypass the existing reminder-only preflight/repair. This is an exposed product failure, not acceptance restored by the former synthetic schedule result.

Inspection preserves semantic false positives: K03 says Serge where its source says Sarah; M02 calls the September 26 message “new”; quick F03 can grade PASS while asking for a file named Marcus. The grader verdict does not establish those requests were correctly fulfilled. Owner O01/O08, broader readiness, model/default promotion and phase completion remain open. Historical f1b796a quick 10/10/9 and full 27/25 predate the scheduling fixture correction and retain their caveats.

The installed build also adds exact voice answer-model selection for the diagnostic. Same authored audio reaches Mini's committed turn, native token counts and playback acknowledgement; default Apple remains functional. One measured Mini turn: L1/L2/L3 0.759/2.882/3.213 s, answer decode 46.250 tok/s over 74 tokens. This is identity/stage proof, not fixed-256-token C2 floor or latency acceptance; the 200 ms and first-audio targets remain open.

Evidence: `~/Library/Caches/NextNotesBuild/toolloop-live/minicpm-current-b11df78-20261005/`, `integration/r01-schedule-fixture-fidelity/` and `integration/pl01-voice-candidate-pinning/`. Only the current staged app is retained. This turn removed four obsolete original stages (819,312,964 bytes); private models, raw evidence and unresolved peer worktrees remain. Parallel cache proposals cover the existing floor feeder and schedule preflight; no new P6 work.
