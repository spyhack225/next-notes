# DICTATION-MEETINGS-RATES-AND-GATES: F-01 … F-04

## F-01a — Repair the diagnostic evidence producer (2026-09-30)

Parent F-01 is done (`99d4a46`). This child repairs the existing read-only
`Scripts/dictation-stats.py`, not the dictation pipeline. The original CLI failed
when a hold row reached `stamp` before its local definition, and full mode omitted
D-14's measured ≥1 s ASR-start condition. Keep the original 1 s / 5 s / three
occurrence thresholds. Only actual `dictation.asr` numeric, finite, nonnegative
measurements in the selected date range count; other features or absent fields
cannot stand in for them. Preserve the meeting-overlap condition.

Verify the real subprocess CLI against isolated temporary store shapes with
`python3 Scripts/test-dictation-stats.py`. Record red/green and a fresh read-only
owner diagnostic in `Tests/Reports/dictation-gates/`; no model/build/install needed.
F-02…04 remain evidence-gated and are not completed by fixing the reader.

## F-01b — Enforce the existing observation minimum (2026-09-30)

The normal reader skipped D-13's seven-day minimum without `--since`, and an
older cutoff alone could invent unseen observation days. Repair only that gate
producer: use earliest valid eligible hold through current time in both modes,
retain cutoff filtering and all existing thresholds, and report observed/required
days. This is a minimum observed window, not a new rolling seven-day filter.
Red-first real CLI fixtures require 100 same-day holds to remain insufficient;
the exact seven-day boundary with 100 holds must still evaluate the original
materiality threshold. Run the same focused driver; parent owner-use work stays
pending. Evidence: `Tests/Reports/dictation-gates/2026-09-30-f01b-observation.md`.

**Model alignment, 2026-09-30:** follow the
[independent-role/shared-file contract](../SHARED-BRAIN/00-README.md).
Engine/default changes do not waive the existing rate gates. Compare actual
engine/build cohorts and record fallback outcomes using usage.jsonl. Cleanup's
MiniCPM artifact may be reused by notes/Agent without merging choices or blocking
voice on a deferred swap; measure overlap latency, not only isolated cleanup.

Read `00-README.md` first (gates report, order, kept limits, workflow, rules). Paths are relative
to `Sources/NextNotes/` unless they start with a repo-root folder (`Scripts/`, `Tests/`,
`roadmap/`). Line numbers were read on 2026-09-26 and will drift — **grep the symbol named in
each anchor** and trust that over the number.

Context every task inherits: the previous roadmap (`roadmap/done/DICTATION-MEETINGS-LIMITS/`)
landed 29 of 31 tasks and closed four phase gates. Its ledger's *Owner-use measurements* table is
where T1–T9 are supposed to be recorded, and it is empty because `dictation.hold` rows began at
D-01b on 2026-09-25. Every anchor below was verified against the tree on that date.

---

## F-01 — Record the dictation side's speech-lane wait on `dictation.asr`

**Blocked on:** nothing. **Effort:** 1–2 h. **Unblocks:** D-14's second gate condition, and F-04's
lane numbers. **Owner of the file:** AGENT-OVERHAUL P0-20c — coordinate, do not fork.

**Why (what is unmeasurable today).** D-14 asks: does a dictation start ever *wait* for the
speech lane? The meeting side answers it — P0-20b's `MeetingTranscribeTally` carries
`stages["laneWait"]` per track, and `ChunkedTranscriber.swift:627` measures it around the acquire.
The dictation side does not: `ParakeetEngine.start()` acquires `.realtimeASR`
(`Transcription/ParakeetEngine.swift:87`) and holds it until `finish()`, and nothing records how
long that acquire waited. So the gates report prints
`dictation_side_lane_wait_recorded: false` and can only ever evaluate the *first* of D-14's two
conditions. A week of owner use would answer half the gate.

**What lands:** one `stages["laneWait"]` on the `dictation.asr` row, in seconds, `0` when there
was no wait. Nothing else changes: no new file, no new log, no behaviour.

**Files you will change** (re-verify each with `grep -n`):
- `Sources/NextNotes/Support/Usage/UsageRecord+Dictation.swift` — `dictationRows(...)` @ :26, the
  `stages:` dictionary @ :73. Add a `laneWait: Double` parameter with a default of `0` and put it
  in that dictionary. **A default matters:** P0-20c's own callers and its self-test
  (`UsageLogSelfTest.swift:685`, `:764`, `:1102`) call this without the new argument, and a
  signature change that breaks them is a regression in another roadmap.
- `Sources/NextNotes/Core/DictationController.swift:1900` — the only production caller of
  `dictationRows`. Pass the measured value through.
- The seam that knows the wait: `ParakeetEngine` measures the acquire around
  `ComputeScheduler.shared.acquire(.realtimeASR)` @ :87 and must **report** it. Read how `start()`
  and `finish()` hand state back before choosing the shape; a small `Sendable` box (the file
  already has a lock-protected counter idiom) or a returned value is fine. Do **not** change when
  the lane is held — that is D-14's own change and it is gated on evidence.
- `Sources/NextNotes/Support/Usage/UsageLogSelfTest.swift` — extend the existing dictation cases
  (D1–D3, E1–E4) with the new field. One marker, `USAGE_LOG_OK` / `USAGE_LOG_FAILED`.

**Read for context (do not change):** `Sources/NextNotes/Meetings/MeetingTranscribeTally.swift`
(the shape the meeting side already uses, including its doc comment on what `laneWait` excludes),
`Core/Compute/ComputeScheduler.swift` (`acquire` / `acquireCancellable`, P0-06's cancellable
variant), and `Sources/NextNotes/Support/Usage/UsageRecord.swift:68` (`stages: [String: Double]?` —
a named sub-stage map, seconds).

**Steps.**
1. Measure the wait where the acquire happens, and carry it to `dictationRows`.
2. Add `laneWait` to the `stages` dictionary with a defaulted parameter.
3. Keep the reader working: `Scripts/dictation-stats.py` already reads
   `stages["laneWait"]` off any `dictation.*` row (`dictation_lane_recorded` /
   `D14_DICTATION_WAIT_S`), so **no reader change is needed** — verify it by running `--gates`
   and watching the field flip to `true`.
4. Update the gates report's own comment only if the field's meaning needs a sentence; the reader
   is the previous roadmap's script and its `--gates` output is the contract.

**Do not:**
- change the lane's hold/release points, its priority, or `ComputeScheduler` semantics — that is
  F-03 and it is evidence-gated;
- add a new usage log, a second record type, or any field carrying content. This is a duration.
- make the field required: a defaulted parameter keeps P0-20c's callers compiling;
- special-case `SelfTest.isRunning`; use the existing seams.

**Red-first self-test.** Extend `--selftest-usage-log` (`UsageLogSelfTest`, one marker):
- **a.** a hold driven through `UsageRecord.dictationRows(...)` with a 1.4 s lane wait produces a
  `dictation.asr` row whose `stages["laneWait"] == 1.4` (`USAGE_LOG_WRONG: the asr row has no
  stages[laneWait]` before the change);
- **b.** a row built without the new argument has `stages["laneWait"] == 0` — the default is real,
  and P0-20c's three existing call sites keep compiling;
- **c.** `E4`'s schema lock still passes (no new *key* in the coding keys — `stages` is a map, so
  the row's shape is unchanged).
Then `python3 Scripts/dictation-stats.py --gates` reports
`dictation_side_lane_wait_recorded: true`.

Confirm RED: case a fails (`stages` has no `laneWait` key) before the change.

**Verify.**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-usage-log 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/F-01-green.txt | tail -3
python3 Scripts/dictation-stats.py --gates | tail -12
Scripts/run-selftest.sh --selftest-dictation      # via-open, ONCE — the controller changed
Scripts/run-selftest.sh --selftest-metrics
make test
```

**Success threshold:** `USAGE_LOG_OK` with a–c (red first); `--gates` reports
`dictation_side_lane_wait_recorded: true`; `DICTATION_OK` unchanged.

**Risks & rollback:** additive and optional; the worst case is a field nobody reads. Roll back by
reverting.

**Done when:**
- [ ] `dictation.asr` rows carry `stages["laneWait"]`, defaulted, and the value is the measured
      acquire wait;
- [ ] `--selftest-usage-log` green with a–c (red first);
- [ ] `make gates` shows `dictation_side_lane_wait_recorded: true`;
- [ ] `STATUS.md` F-01 row updated; committed as `F-01: record the dictation side's speech-lane wait`;
- [ ] AGENT-OVERHAUL's `STATUS.md` P0-20c row carries a courtesy note (that file is git-ignored;
      edit, do not commit).

---

## F-02 — Decide D-13 (pipelined holds) from the gates report

**Blocked on:** F-01, then ≥ 100 owner holds and ≥ 7 days. **Effort:** 2 h to read the report;
2 days if it says `proceed`. **Decides:** the previous roadmap's D-13.

**Why.** While a hold is in its tail (`.finishing`, 5–12 s before the previous roadmap's work),
`beginDictation` returns silently for a new press. A user who starts the next thought at once
loses it. The previous roadmap left the row `blocked` on purpose: the remedy is invasive (it
restructures the very session machinery `AGENTS.md` calls load-bearing) and the problem was never
measured.

**Step 1 — read the verdict, and do not argue with it.**
```bash
make gates        # or: cat ~/Library/Caches/NextNotesBuild/dictation-meetings/gates-latest.txt
```
- `not enough data` → **stop.** Record the shortfall in `STATUS.md` (F-02 row) and move to F-04.
  This is a valid terminal state, not a failure.
- `won't do (evidence)` → set the previous roadmap's D-13 row to `won't do (evidence)` with the
  numbers (`refused_finishing`, `refused_finishing_per_100_holds`, `holds`), commit that as
  `F-02: D-13 is not worth building on the evidence`, and stop.
- `proceed` → step 2.

**Step 2 — if `proceed`, consider the cheaper remedy first.** The new rows answer a question the
old evidence could not: *how long is the tail now?* If refusals are real but
`dictation.keyUp_to_asr_final` and the `dictation.hold` `totalMs` show a short tail, making the
refusal **visible** — a beep or a HUD note when a press is ignored — may serve the user better
than a queue, at a fraction of the risk. Say which you chose and why, in `STATUS.md`; if the
refusal is frequent enough that a user would hit it several times a day, build the queue.

**Step 3 — the queue, if that is the answer.** The previous roadmap's task text has the full
design (`roadmap/done/DICTATION-MEETINGS-LIMITS/01-DICTATION.md` §D-13 — on this machine only;
`roadmap/` is git-ignored). In outline: a press during `.finishing` starts capturing at once into
D-02's pre-roll for a **queued** hold; its engine starts when the previous tail releases the
engine; its text is injected after the previous hold's, in order, into its own key-down origin; at
most one queued hold; every `withBoundedWait` still applies to both. Structurally: make the
per-hold slots a struct (`HoldSlots`: engine, consumeTask, feedTask, audioContinuation, session,
origin, holdID) with `current` and `queued`, the `session` guard per slot, the tail's last step
promoting `queued` to `current`, and injection order through a serial `injectionQueue` actor.

**Do not:** allow more than one queued hold; remove or lengthen any deadline; share an engine
instance between holds; let a queued hold's text land before the hold it follows; touch
`DictationController.Limits`.

**Red-first self-test** (only if step 3 is the answer): extend `--selftest-dictation` (via-open,
once) with a press during `.finishing` and assert the queued hold is captured immediately, its
transcript is injected **after** the first hold's, in order, and both holds file exactly one
`dictation.hold` row. Confirm `DICTATION_FAILED` before implementing.

**Verify.**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --via-open --selftest-dictation | tail -6
Scripts/run-selftest.sh --selftest-commandkey
Scripts/run-selftest.sh --selftest-usage-log
make test
```

**Success threshold:** the previous roadmap's D-13 row is `done` (built) or `won't do (evidence)`
(refused), with the numbers, and `DICTATION_OK` with the new case.

**Done when:**
- [ ] the verdict and the numbers are in both ledgers;
- [ ] the previous roadmap's D-13 row is final;
- [ ] if built: `--selftest-dictation` green with the queued-hold case (red first);
- [ ] committed as `F-02: <title>`.

---

## F-03 — Decide D-14 (per-pass `.realtimeASR` acquisition) from the gates report

**Blocked on:** F-01 (its own second condition), then the report. **Effort:** 30 min to read;
0.5 day if it says `proceed`. **Decides:** the previous roadmap's D-14.

**Why.** `ParakeetEngine.start()` acquires `.realtimeASR` and releases it in `finish()` — the
whole hold, which can be 98 s. Meeting windows take the same class, and equal priority does not
preempt, so dictating during a recorded meeting delays that meeting's windows by the length of the
hold. I1 found 0 "dropped window" lines in the retained log, so the harm was never visible — which
is exactly why the task was gated.

**Step 1 — read the verdict.**
```bash
make gates
```
- `not enough data` → stop, record the shortfall. If the only reason is
  `dictation_side_lane_wait_recorded: false`, F-01 has not landed: do that first
  (`roadmap/in-progress/DICTATION-MEETINGS-RATES-AND-GATES/01-FOLLOWUP.md` §F-01).
- `won't do (evidence)` → set the previous roadmap's D-14 row to `won't do (evidence)` with
  `overlaps_with_window_wait_ge_5s` and `worst_window_wait_in_an_overlap_s`, commit as
  `F-03: D-14 is not worth building on the evidence`, and stop.
- `proceed` → step 2.

**Step 2 — if `proceed`.** Acquire the lane around each Parakeet pass rather than around the hold,
so a meeting window can run between a dictation's passes:
- `Transcription/ParakeetEngine.swift` — `start()` @ :62 / the acquire @ :87, `finish()`, and the
  partial path (`startPartial` @ :294, the partial cadence of 1.0 s and the reuse rule below 0.5 s
  leftover are **kept limits**). Take the lane around each `transcribe` call.
- `Support/ContentionSelfTests.swift` — the deterministic cases: a meeting window that would have
  waited now runs between two dictation passes, and a `.background` job (notes) still parks at
  its next checkpoint whenever a dictation pass holds the lane.

**Do not:** change lane priorities or `ComputeScheduler` semantics — AGENT-OVERHAUL P3-07a owns
that; read its lane model first if its row has landed. Do not drop the lane for Apple's engine
path (controller-owned, unchanged). Do not change the partial cadence or the reuse rule.

**Red-first self-test:** extend `--selftest-contention` with a case that measures the meeting
window's wait with a dictation hold in flight: red, it is the length of the hold; green, it is
bounded by one pass. Confirm `CONTENTION_FAILED` before implementing.

**Verify.**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-contention 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/F-03-green.txt | tail -4
Scripts/run-selftest.sh --selftest-parakeet
Scripts/run-selftest.sh --selftest-meeting-backlog
Scripts/run-selftest.sh --selftest-usage-log     # the lane's acquire is now inside a pass
make test
```

**Success threshold:** the previous roadmap's D-14 row is final, `CONTENTION_OK` with the new
case, and the meeting-backlog gate still reports 0 s lost.

**Done when:**
- [ ] the verdict and the numbers are in both ledgers;
- [ ] the previous roadmap's D-14 row is final;
- [ ] if built: `--selftest-contention` green with the new case (red first);
- [ ] committed as `F-03: <title>`.

---

## F-04 — Measure T1–T9 on the owner's holds and record them

**Blocked on:** ≥ 7 days and ≥ 30 owner holds. **Effort:** 1 h, no code unless a target's
measurement needs a seam. **This is the big one** — it is the only task that answers "did any of
it actually get faster?".

**Why.** Four phase gates proved mechanisms on fixtures. A rate is a property of this Mac, this
model and this user's speech, and the baseline it must be compared against is the previous
roadmap's row (2026-09-25, from the owner's own history, reproduced by
`Scripts/dictation-stats.py` with no arguments):

| # | Metric | Baseline (2026-09-25) | Target | How it is read today |
|---|---|---|---|---|
| T1 | key-up → text, p50 / p90 | 4.46 s / 9.74 s | ≤ 3.0 / 6.5 s after phase C; ≤ 2.0 / 4.5 s after D-12 | `holds.keyUp_to_text_ms` (`dictation.hold` `totalMs`, no `errorClass`) |
| T2 | cleanup timeout rate | 0.18 (9/50) | ≤ 0.02 | `cleanup.timeout_rate` |
| T3 | cleanup seconds wasted (timeout + rejected) | 0.337 (81.8 / 242.6 s) | ≤ 0.10 | `cleanup.wasted_share` |
| T4 | key-down → capturing, p90 | 0.392 s (max 4.398 s) | ≤ 0.150 s | `holds.keyDown_to_capture_ms` |
| T5 | holds that end with nothing typed and no message | not countable (≥ 2 on 09-23) | 0; every hold has exactly one outcome row | `holds.silent_loss_share` |
| T6 | raw engine/framework strings shown to the user | 1 in 24 h | 0 | `/usr/bin/log show --last 1d --predicate 'subsystem == "ai.pivotstudio.nextnotes"' \| grep -c "16kHz"` |
| T7 | layout passes cut by their deadline while cleanup ran | 5 of 6 | ≤ 1 in 10 asked | `cleanup.layout_timed_out / layout_asked` |
| T8 | a press in the 3 s after an error | refused silently | starts a hold | `press_refused_by_state` (D-05) — assert no `error` rows |
| T9 | learner: bad or duplicate rules added | 1 bad, 5 duplicates on disk | 0 new | `dictionary.duplicate_rules` vs the baseline's 5 |

**Step 1 — capture.**
```bash
python3 Scripts/dictation-stats.py --since 2026-09-25 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/F-04-stats.txt
python3 Scripts/dictation-stats.py --since 2026-09-25 --json > ~/Library/Caches/NextNotesBuild/dictation-meetings/F-04-stats.json
Scripts/run-selftest.sh --usage-report | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/F-04-usage-report.txt
```
Compare with the **same window length** and after checking the engine mix did not change
(`runs.engines`, `cleanup` settings) — a different `cleanupEngine` or `cleanupFixesGrammar` makes
every comparison meaningless, and the script prints the mix for exactly that reason.

**Step 2 — record, one row per target, met or not.** Fill the *Owner-use measurements* table in
`STATUS.md` here **and** in `roadmap/done/DICTATION-MEETINGS-LIMITS/STATUS.md`, and the *Owner-use
measurements* table in the previous roadmap's ledger. Each target gets: the number, the target, and
for anything missed the **reason** and whether it is a threshold that was wrong, a fixture-only
effect, or a real regression. A missed target with a number and a reason is a success for this
task; a missing row is not.

**Step 3 — for each miss, decide and write down which of three it is.**
- **A threshold that was wrong** (the target was derived, not measured — the previous roadmap says
  so for T3 and T7). Say so, with the measurement that shows it, and adjust the target in the
  ledger rather than the code.
- **A fixture-only effect** — the mechanism is proven and the rate is unaffected at this volume.
  Say so with both numbers.
- **A real regression** — open a new task in this folder (next free `F-0N`), do not expand this one,
  and do not "fix it quietly" inside an unrelated change. Note it in the ledger the same day.

**Do not** invent a denominator, extrapolate from a week to a month, or average across an engine
change. Do not report a rate from a window shorter than the baseline's. Do not re-run a target
until it looks good: the number you first measured is the number you record, with its date.

**Red-first:** n/a — this task measures. Its gate is the ledger row, and a row that is missing or
unexplained is the failure.

**Success threshold:** every target T1–T9 has a number, a verdict and (if missed) a reason; the
two ledgers agree; `make gates` has been read in the same session so the numbers describe the same
tree.

**Done when:**
- [ ] the rate table is filled for T1–T9 in both ledgers;
- [ ] every miss has a reason and a classification, and any real regression has a new `F-0N` row;
- [ ] `F-04-stats.txt`, `.json` and the usage report are saved under the cache directory;
- [ ] committed as `F-04: measure the dictation rates on owner holds` (or recorded, if the tree is
      unchanged — say which).
