# PL-01 floor pressure/thermal observations — 2026-10-05

The existing floor diagnostic now observes delivered pressure events through the same guardian lock, seeding and disposing its one optional callback atomically. Metadata callback is nil in ordinary production. Pressure means delivered guardian events (including OS coalescing), not a claim of continuously sampled physical pressure. Thermal samples run on independent anchored10second utility deadlines; late/skipped observations are reported honestly. The diagnostic sampler cancels/joins on all activated exits; no wait/store is added to normal user turns.

COMMON reproduces7 pressure-observer and4 clock-control failures; fixed clears the same assertions. Residency, usage26 and owner isolation21files32defaults pass once. Identical bounded25second native input originally reports UNMEASURED pressure and text-coupled thermal samples17.13/27.14/37.15seconds; fixed reports guardian events and independent deadlines below. Actual native256 rows and model join remain intact. Authored per-test temp directories are deleted after process joins. No repeat of600second sustain.

```text
LLM_FLOOR_THERMAL: scheduled_s=0 actual_s=0.0000 state=0 lateness_s=0.0000 skipped_deadlines=0 clock=ContinuousClock
LLM_FLOOR_THERMAL: scheduled_s=10 actual_s=10.1923 state=0 lateness_s=0.1923 skipped_deadlines=0 clock=ContinuousClock
LLM_FLOOR_THERMAL: scheduled_s=20 actual_s=20.2327 state=0 lateness_s=0.2327 skipped_deadlines=0 clock=ContinuousClock
LLM_FLOOR_THERMAL: scheduled_s=30 actual_s=30.1930 state=0 lateness_s=0.1930 skipped_deadlines=0 clock=ContinuousClock
LLM_FLOOR_THERMAL: scheduled_s=40 actual_s=40.3926 state=0 lateness_s=0.3926 skipped_deadlines=0 clock=ContinuousClock
```

Bulk original/fixed focused+native logs and source: ~/Library/Caches/NextNotesBuild/integration/pl01-floor-pressure-thermal/. Fixed native is C0 observer qualification only; quiet full C1/C2, ten-minute cadence acceptance, disk union, warm voice and aggregate quality/default gates remain open. No floor/default/performance promotion.
