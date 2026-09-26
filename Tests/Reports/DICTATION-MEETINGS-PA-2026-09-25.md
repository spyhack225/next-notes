# DICTATION-MEETINGS-LIMITS — Phase A report (measure)

Date: 2026-09-25 · Tree: `6b5ebb3` (the stats script; the roadmap ran on a tree that also
carried the parallel AGENT-OVERHAUL effort's uncommitted work, which is named wherever it
touched a result) · Raw output: `~/Library/Caches/NextNotesBuild/dictation-meetings/gateA/`

Phase A exists so every later "better" is a number rather than a hunch. It landed three tasks:

| Task | Commit | Gate |
|---|---|---|
| D-01a — `sessionPrewarmed` recorded before `respond`, on every exit including timeout | `b0cec70` | `CLEANUP_ROUTER_OK` (red first: 4 cases) |
| D-01b — one `dictation.hold` usage row per hold, `dictation.press_refused`, dropped buffers | `d9d6f8b` | `DICTATION_OK` (red first: 11 problems) |
| M-16a — transcript-quality probe, meeting stage spans, fixtures, `--meeting-quality-report` | `2edc55f` | `MEETING_QUALITY_OK` (red first: 18 checks) |

## 1. `make test`

30 tests in 2 suites passed (0.603 s) — the dictionary and spoken-form vectors, unchanged.

## 2. `make acceptance TIER=core`

**15/16 PASS.** The one FAIL is `--selftest-wake-live`:

```
WAKE_LIVE_FAILED: 17/24 hits, 3/32 false at sens 0.6 — hit rate 0.71 under 0.8
```

That is the known red AGENTS.md records before this roadmap began (the 2026-09-22 tuning pass
took the measured trade-surface maximum and left it red on purpose; the missing fixtures are
real-room recordings). Nothing in this roadmap touches the wake word.

`--selftest-computer` **PASS**es here; it was FAIL in the AGENT-OVERHAUL baseline only because
the screen was locked then. No CORE entry regressed against the baseline.

Log: `~/Library/Caches/NextNotesBuild/acceptance/20260926-020332-21103/`.

## 3. Exit flags

| Flag | Final line |
|---|---|
| `--selftest-dictation` (via-open, once) | `DICTATION_OK: every hold came back to idle` |
| `--selftest-cleanup-router` | `CLEANUP_ROUTER_OK` |
| `--selftest-metrics` | `METRICS_OK` |
| `--selftest-meeting-quality` | `MEETING_QUALITY_OK` |
| `--selftest-usage-log` (P0-20e) | `USAGE_LOG_FAILED: 1 problem(s)` — `E1: the typed turn wrote no answer row for its turnID` |

The one failure is **not this roadmap's**. E1 exercises the typed Agent turn, which is
AGENT-OVERHAUL's in-flight work (uncommitted `RealtimeAgent+ToolLoop.swift`, untracked
`AgentCapabilityManifest.swift` at the time of the run). M-14's agent hit the same line and
confirmed M-16b's own meeting cases pass, so the `dictation.hold` and `meeting.reconcile`
rows this roadmap owns are truthful.

Diagnostics (read-only, outside the harness): `--meeting-quality-report` →
`MEETING_QUALITY_REPORT_DONE: 6 meeting(s)`, one row per finished meeting on this Mac;
`--usage-report` → `USAGE_REPORT_OK rows=3 files=1`, the three rows being AGENT-OVERHAUL's
`agent.typed` passes.

## 4. Stats script before → after

`python3 Scripts/dictation-stats.py` (committed `6b5ebb3`) on the owner's own history. Phase A
changed no dictation behaviour, so the numbers are the pre-change baseline — which is the point
of capturing them at all:

| Number | Baseline (2026-09-25) | After Phase A |
|---|---|---|
| filed runs / with cleanup record | 226 / 51 | 226 / 51 (no owner dictation since) |
| cleanup model attempts / timed out / rate | 50 / 9 / **0.18** | 50 / 9 / 0.18 |
| cleanup seconds total / wasted / share | 242.6 s / 81.8 s / **0.337** | 242.6 s / 81.8 s / 0.337 |
| `processSeconds` p50 / p90 (model-cleaned) | 4.46 s / 9.74 s | 4.46 s / 9.74 s |
| layout asked / cut by deadline / used | 6 / 5 / 1 | 6 / 5 / 1 |
| `sessionPrewarmed` on timeouts (None/True) | 8 / 1 | 8 / 1 |
| `keyDown_to_capture` p50 / p90 / max | 0.062 s / 0.392 s / 4.398 s | unchanged |
| `asr_final_to_cleanup` p50 / p90 | 5.386 s / 9.815 s | unchanged |
| dictionary rules / duplicates | 31 / 5 | 31 / 5 |
| `dictation.hold` rows | 0 | 0 — **D-01b landed today; the first hold row is the owner's** |

The audit's 2026-09-23 figures are reproduced exactly (50 / 9 / 18 %, 81.8 of 242.6 s, 6/5/1),
which is the check that the script reads the history the audit read.

**The Phase A measurement is not finished and cannot be, today.** `holds` is empty because the
owner has not dictated since D-01b landed, so D-13's and D-14's evidence gates are `blocked` on
owner usage rather than decided. `Scripts/dictation-stats.py` now prints
`holds.press_refused_finishing_per_100`, so each gate is one command once the week of holds
exists.

## 5. BLOCKED tasks in this phase

None. D-13 and D-14 are Phase D and are `blocked` on owner usage data, with the exact command
and threshold in their BLOCKED notes.

## 6. What Phase A bought

Every later claim in this roadmap is now checkable from a file rather than from a log line that
ages out within minutes: `dictation.hold` says what happened to every hold including the ones
that typed nothing, `dictation.press_refused` says when a press was ignored, the five new
`meeting.*` spans time the drain, diarization, notes and dropped windows, and
`--meeting-quality-report` reads the six real meetings on this Mac without touching them.
