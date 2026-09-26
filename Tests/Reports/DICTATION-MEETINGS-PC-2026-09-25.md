# DICTATION-MEETINGS-LIMITS — Phase C report (faster and better)

Date: 2026-09-25 · Tree: `212c6a2` (gate B's report) · Raw output:
`~/Library/Caches/NextNotesBuild/dictation-meetings/gateC/`

Phase C is latency and quality. Thirteen tasks landed across its dictation and meeting chains,
every one red-first.

| Task | Commit | What it changed |
|---|---|---|
| D-06 | `2922430` | Apple's model warmed at launch and after wake; the S1-mini launch load is gated on the engine that will actually run |
| D-07 | `bccfcfc` | the per-call budget answers to warmth: cold gets `min(16, 8.5 + 0.07w)`, staged/warm keep `min(14, 4.0 + 0.07w)` |
| D-08 | `0315c9d` | chunk width chosen by measurement (Apple 1, S1-mini 2), wave-aware ceilings, a staged session per group, per-group verdicts |
| D-09 | `0d195b3` | the layout pass's deadline is anchored to the cleanup pass it runs beside |
| D-11 | `92e777a` | clause-level salvage for long single-sentence answers |
| M-04 | `8a5ea49` | short far-end segments labelled from the nearest run or agreeing neighbours |
| M-03 | `82a5745` | speaker-count hints, voice-print cluster merge, "Identify again with N speakers" while audio exists |
| M-12 | `4fc61c3` | notes budgeting reads Apple's real `contextSize` and token count; chunks derive from the budget; overflow is retried. **Landed AGENT-OVERHAUL P1-10a step 0 verbatim**, so P1-10a skips that step |
| M-13 | `e041521` | a cut-off answer says so on the page instead of being padded with `_None._`; one retry at double the budget; the cap scales with the meeting |
| M-07 | `b960cf5` | the transcription backlog is bounded by audio seconds, windows merge, nothing is dropped silently |
| M-09 | `b36ccf5` | the system-audio tap is retried every 30 s while a meeting records, up to ten times |
| M-10 | `1b6e14e` | temporary audio keeps 72 h or until the speakers are confirmed, with a disk guard and a sweep |
| M-11 | `90fbdea` | a call near an event starts that event's own meeting and ends on hang-up; the overrun is a grace, not a deadline |

## 1. `make test`

30 tests in 2 suites passed — unchanged.

## 2. `make acceptance TIER=core`

**15/16 PASS**, unchanged from gates A and B on this tree; the one FAIL remains
`--selftest-wake-live`, the known red from before this roadmap. No CORE entry regressed.

## 3. Exit flags — all ten green

| Flag | Final line |
|---|---|
| `--selftest-cleanup-router` | `CLEANUP_ROUTER_OK` |
| `--selftest-cleanup apple-grammar` | `CLEANUP_OK` — `CLEANUP_SUMMARY apple-grammar: n=42 cold=4.790s median=2.125s warm-median=2.092s warm-max=4.969s` |
| `--selftest-diarize-assign` | `DIARIZE_ASSIGN_OK` |
| `--selftest-diarize-hints` | `DIARIZE_HINTS_OK` |
| `--selftest-notes-longform` | `NOTES_LONGFORM_OK: 90-min facts kept on 4K and 8K, stubborn collapse visible, single pass intact, overflow retried, window-derived chunks` |
| `--selftest-notes-truncation` | `NOTES_TRUNCATION_OK: a cut answer says so on the page, the single pass and the reduce each retry once at double the budget, the cap scales with the meeting, the wire finish reasons are read` |
| `--selftest-meeting-backlog` | `MEETING_BACKLOG_OK: 0 s lost behind a slow transcriber over 180s of input` |
| `--selftest-meeting-tap-retry` | `MEETING_TAP_RETRY_OK: joined late, placed at the join time, gave up and stopped cleanly` |
| `--selftest-audio-retention` | `AUDIO_RETENTION_OK: temporary audio keeps 72 h, the disk guards hold, the sweeper spares kept, active and problem meetings` |
| `--selftest-calendar` | `CALENDAR_OK: 0 upcoming event(s), decision rules behave` |

`CLEANUP_ROUTER_OK` is now seen on a **quiet** tree, which is what D-11's agent could not do
while three other workstreams were mid-edit.

## 4. The numbers this phase was for

**Cleanup latency — the phase's headline.** The audit measured an 18 % timeout rate and 34 % of
all cleanup seconds wasted on timeouts and rejections, with the cold floor (4.0 s) sitting below
the model's own 4.69 s cold start. Today:

```
CLEANUP_SUMMARY apple-grammar: n=42 cold=4.790s median=2.125s warm-median=2.092s warm-max=4.969s
```

against the pre-change audit figures of 9 timeouts in 50 attempts and a 4.16 s p50. The cold
first case **answers** (4.79 s inside the cold budget) instead of being waited out and thrown
away — which is the whole of the D-07 change. Chunk width is now measured rather than assumed
(`CHUNK_WIDTH w1_wall=5.92 w2_wall=6.28` against a 5.03 s bar → Apple runs one group at a time;
S1-mini keeps two, where it was measured fast enough).

**T2 (timeout rate ≤ 2 %) and T3 (wasted share ≤ 10 %) are not yet measurable.** They are
owner-use numbers and `dictation.hold`/`runs.jsonl` have no rows since D-01b landed today. What
the fixtures show is the mechanism is in place; the rate is owed.

**Speaker attribution.** 33 system segments on the 3-person fixture, **0 unattributed** (limit
10 %); a 1:1 call comes back as 1 far-end cluster with the call's hint, 2 without.

**Transcription backlog.** 0 s of audio lost behind a slow transcriber over 180 s of input
(I2 measured 132 s of 132 s lost before M-07).

**Notes completeness.** Unchanged from gate B: `chunks=15 collapsed=2 dropped=0` on the 90-minute
4K fixture, and now with chunks derived from Apple's real 8,192-token window rather than a
hard-coded 4,096.

## 5. BLOCKED tasks in this phase

None.

## 6. Owner use still owed

T1 (key-up → text p50/p90 after Phase C: ≤ 3.0 s / ≤ 6.5 s), T2, T3, T4, T5, T6, T7, T9 — every
target whose measurement is a hold rather than a fixture. `Scripts/dictation-stats.py --since
2026-09-25` is the command, and *Owner-use measurements* is where the rows go.
