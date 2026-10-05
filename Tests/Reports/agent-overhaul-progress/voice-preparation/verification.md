# Voice preparation — 2026-10-05

The coordinator withheld stable partials below four words and slept 220ms before preparing an answer. It now prepares each nonempty stable revision immediately through the existing frontend slot, preserving cancellation, session, request and correlation checks.

Unchanged original fixture: four 150ms start assertions failed; fixed: all pass. Voice speculation, turn routing, concurrency, conversation and owner-store isolation pass.

Matched newly authored WAV, one warmup plus five measured turns per variant:

| Median | Original | Fixed |
|---|---:|---:|
| Voice onset → preparation (L1) | 1.778s | 0.671s |
| Endpoint → first answer token (L2) | 3.322s | 2.448s |
| Endpoint → first audible output (L3) | 3.777s | 2.649s |

Original native run failed the unchanged 100ms main-stall limit (122ms); fixed passes (36ms p90). This comparison does not meet the 200ms L1/L2 targets or close physical/overall latency gates. The deleted historical peer WAV was not substituted or claimed identical.

Raw inputs, logs and seven passing fixed results: `~/Library/Caches/NextNotesBuild/integration/listen-acceptance/`.
