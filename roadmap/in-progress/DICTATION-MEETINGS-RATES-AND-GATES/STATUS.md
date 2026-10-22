# DICTATION-MEETINGS-RATES-AND-GATES status ledger

**Model alignment, 2026-09-30:** follow the
[independent-role/shared-file contract](../SHARED-BRAIN/00-README.md).
Settings/rates below are historical baseline samples, not current defaults.
MiniCPM cleanup + Apple guard/fallback is concurrent OpenCode work. Preserve the
recorded numbers; subsequent measurements must identify engine/build and shared
runtime contention. No follow-up task becomes done from this documentation change.

The only progress record for this roadmap. Update it after every task, following
`00-README.md` §6.

| State | Meaning |
|---|---|
| `todo` | Not started. |
| `red` | The self-test is written and confirmed failing on the old code. |
| `green` | The gate passed and the regressions are unchanged. |
| `done` | Committed. |
| `won't do (evidence)` | An evidence-gated task whose verdict was `won't do (evidence)`. Say the numbers. |
| `blocked` | See the notes at the bottom. |

Dates are `YYYY-MM-DD`. Evidence is the verdict line plus measured numbers with units. The commit
is a short hash.

## Baseline

Captured 2026-09-25 by the previous roadmap, from the owner's own history with
`python3 Scripts/dictation-stats.py` (committed `6b5ebb3`). No owner dictation has been recorded
since D-01b landed that day, so this row is still the pre-change baseline **and** the current one.

| Item | Value |
|---|---|
| Commit | `6b5ebb3` (script) on a tree carrying the parallel AGENT-OVERHAUL effort's uncommitted work |
| Date | 2026-09-25 |
| Free disk | 9.4Gi avail (58 % used) |
| Settings | parakeet, s1Mini, grammar 1, dictionaryLearning automatic, meetingsDiarize 1, meetingsKeepAudio 0, callDetectionAutoRecord 1, `modelRoles.meetingNotes` apple |
| `make test` | 30 tests, 2 suites passed |
| `make acceptance TIER=core` | **15/16 PASS**; the one FAIL is `--selftest-wake-live` (`17/24 hits, 3/32 false at sens 0.6`), the known red from before the previous roadmap. `--selftest-computer` PASSes where the AGENT-OVERHAUL baseline had it red on a locked screen |
| Filed runs / with a cleanup record | 226 / 51 |
| Cleanup attempts / timed out / rate | 50 / 9 / **0.18** |
| Cleanup seconds total / wasted / share | 242.6 s / 81.8 s / **0.337** |
| Cleanup seconds p50 / p90 | 4.16 s / 9.37 s |
| `processSeconds` p50 / p90, model-cleaned | 4.46 s / 9.74 s (n = 50) |
| `keyDown_to_capture` p50 / p90 / max | 0.062 s / 0.392 s / **4.398 s** |
| `keyUp_to_asr_final` p50 / p90 | 0.422 s / 1.847 s |
| `asr_final_to_cleanup` p50 / p90 | 5.386 s / 9.815 s |
| `cleanup_to_injection` p50 / p90 | 0.150 s / 0.219 s |
| Layout asked / cut by deadline / used | 6 / 5 / 1 |
| `sessionPrewarmed` on timeouts (None/True) | 8 / 1 |
| Dictionary rules / duplicates | 31 / **5** |
| `dictation.hold` rows | **0** — the record begins at D-01b (`d9d6f8b`, 2026-09-25) |
| `--selftest-cleanup apple-grammar` | `CLEANUP_SUMMARY apple-grammar: n=42 cold=4.790s median=2.125s warm-median=2.092s warm-max=4.969s` (the previous roadmap's Phase C gate) |

The four phase gates it closed, with their reports in `Tests/Reports/`:
`DICTATION-MEETINGS-PA-2026-09-25.md` (`ab1895b`), `-PB-` (`212c6a2`), `-PC-` (`b1473a8`),
`-PD-` (`92b1a9f`).

## Ledger

| ID | Title | Blocked on | State | Date | Evidence | Commit |
|---|---|---|---|---|---|---|
| F-01b | Enforce D-13 seven-day observation in default and filtered diagnostics | F-01a | done | 2026-09-30 | Default + old cutoff falsely proceeded with 100 same-day holds; retained 15/15 CLI fixtures pass. Owner: 27 holds/3 observed days, 73 holds/4 days short; F-02…04 pending. [Report](../../../Tests/Reports/dictation-gates/2026-09-30-f01b-observation.md) | fba4287 |
| F-01a | Repair diagnostic gate reader at the evidence producer | F-01 done; no app/model prerequisite | done | 2026-09-30 | Frozen old script: 10/11 failures; retained: 11/11 CLI cases pass with fixture stores unchanged. Owner diagnostic completes: 27 holds, zero qualifying waits; F-02…04 not closed. [Report](../../../Tests/Reports/dictation-gates/2026-09-30-f01a-reader.md) | 7a94d2d |
| F-01 | Record the dictation side's speech-lane wait on `dictation.asr` so D-14's gate is fully decidable | nothing | done | 2026-09-26 | Red first: `USAGE_LOG_WRONG: D1: the asr row has no stages[laneWait]` + `has 5 stage(s), expected 6` (F-01-red.txt). Green: every case this task owns passes — D1 pins the default of 0 and a real 1.4 s carry, D2's production-path case pins the six-key stage set (F-01-green.txt). Regressions: `DICTATION_OK` (via-open), `METRICS_OK`, `make test` 30/30. The reader flips on a synthetic store: a row without the field reports `dictation_side_lane_wait_recorded: False`, one with it `True`. **Not `USAGE_LOG_OK`:** case E1 (`the typed turn wrote no answer row for its turnID`) is red before and after this change — AGENT-OVERHAUL's in-flight typed path, no file of this roadmap | 99d4a46 |
| F-02 | Decide D-13 from the gates report; build the queued hold if `proceed` | F-01, ≥ 100 holds and ≥ 7 days | todo | | | |
| F-03 | Decide D-14 from the gates report; move the acquire per pass if `proceed` | F-01, the report | todo | | | |
| F-04 | Measure T1–T9 on the owner's holds and record them | ≥ 7 days and ≥ 30 owner holds | todo | | Precondition check 2026-10-04: `usage.jsonl` has 31 `dictation.hold` rows dated 2026-09-27 → 10-02 (≥ 30 met; 7 calendar days since D-01b on 09-25, but the holds themselves span 6 days). Not measured yet. | |

**F-01 is the only original unconditional code task and is already done.** F-02…04
wait for owner-use evidence; task readiness must not be inferred from the old
"unblocked" sentence. F-01a repairs the 2026-09-30 diagnostic producer failure:
`stamp` was called before its local definition, and the D-14 reader ignored measured
dictation ASR waits. No lane ownership, hold behavior or threshold was changed.
The folder moved on F-01a claim; owner-use follow-ups remain pending.

## Gates read so far

One line per read of `~/Library/Caches/NextNotesBuild/dictation-meetings/gates-latest.txt`, so the
history is here rather than only in the cache. `make app` refreshes that file in the background.

| When | Commit | D-13 | D-14 | Shortfall named |
|---|---|---|---|---|
| 2026-09-26 | `7a3eb54` | not enough data | not enough data | D-13: `100 more owner hold(s) (have 0)`; D-14: `no dictation.hold rows yet` |
| 2026-10-04 (doc-freshness read; report refreshed 2026-10-05T00:21Z) | `f4d2a16` | not enough data | **won't do (evidence)** | D-13: `69 more owner hold(s) (have 31)`, refused-while-finishing 3.23/100 vs 3.0. D-14: 31 holds examined, 0 overlapping a meeting, worst dictation lane wait 0.007 s. `gates-history.jsonl` shows this same pair on every successful run since 2026-10-01T02:54Z (30 earlier runs were `GATES_RUN_FAILED`). F-03 stays `todo` until someone records the decision; the report alone does not change a task state. |

## Owner-use measurements (F-04 fills this)

Read with `python3 Scripts/dictation-stats.py --since 2026-09-25`. One row per capture, the
baseline beside it. **The first number you measure is the number you record.**

| Date | Holds (n) | T1 key-up → text p50 / p90 | T2 timeout rate | T3 wasted share | T4 keyDown → capture p90 | T5 silent-loss share | T6 raw strings | T7 layout cut | T8 presses refused in `error` | T9 new duplicate rules | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-09-25 (baseline) | 0 | 4.46 / 9.74 s | 0.18 | 0.337 | 0.392 s | not countable | 1 in 24 h | 5 of 6 | n/a | 5 on disk | owner's own history, pre-change |
| (target) | ≥ 30 | ≤ 2.0 / 4.5 s | ≤ 0.02 | ≤ 0.10 | ≤ 0.150 s | 0 | 0 | ≤ 1 in 10 asked | 0 | 0 new | the previous roadmap's T1–T9 |

T8 is a structural fix (D-05 makes a press during the error card start a hold) and T6 is a
structural fix (D-04 maps every engine error to a plain sentence); both are confirmed by their
self-tests and need only a confirming number here. T1–T5 and T7 are the ones that move.

## Phase gates

| Phase | `make test` | `make acceptance TIER=core` vs baseline | Gates report | Rate table | Report | Date | Commit |
|---|---|---|---|---|---|---|---|
| one phase — rates and gates | | | both decided, or explicitly still short with the shortfall | T1–T9 each met, or not met with the number and the reason | `Tests/Reports/DICTATION-MEETINGS-RATES-____.md` | | |

## BLOCKED notes

```
### <ID> — blocked <YYYY-MM-DD>
Tried: …
Failing line: `<NAME>_FAILED: …` (or the gate's verdict + shortfall) (output saved at
  ~/Library/Caches/NextNotesBuild/dictation-meetings/<ID>-….txt)
Missing: <owner use | model | grant | network | owner decision | another agent's uncommitted work>
Next step when unblocked: …
```

For F-02 and F-03 the honest blocker is almost always *not enough owner use*, and that is a valid
terminal state rather than a failure. Write the shortfall the report names, and the date it was
read.

## Decisions and deviations

Record each on one line: date, task, what you changed relative to the task text, and why.

- 2026-09-26 roadmap: F-02 and F-03 keep the previous roadmap's **task text** as their design
  reference (`roadmap/done/DICTATION-MEETINGS-LIMITS/01-DICTATION.md` §D-13) rather than copying
  two days of steps, because that text is the authoritative design and `roadmap/` is git-ignored —
  so it lives on this machine only, and this folder is written to be read beside it. The *gates*,
  which are all an executor needs to make the decision, are restated in full in `00-README.md` §3
  so the decision never depends on that file being present.
- 2026-09-26 roadmap: the ID prefix is `F-`, deliberately not `D-`/`M-`. D-13 and D-14 keep their
  IDs in the previous roadmap's ledger, which is where their state is recorded; renumbering them
  here would fork one task into two identities.
- 2026-09-26 roadmap: F-04 sits **before** F-02/F-03 in the order even though it blocks on more
  time, because the rates are the evidence those two decisions argue about — a `proceed` on D-13
  means something different when the tail is 9 s than when it is 2 s.
