# DICTATION-MEETINGS-RATES-AND-GATES: start here

**Model alignment, 2026-09-30:** follow the
[independent-role/shared-file contract](../SHARED-BRAIN/00-README.md).
The owner chose MiniCPM cleanup + Apple guard/fallback (concurrent OpenCode work).
Keep this roadmap's rate gates and usage.jsonl seam, but tag baseline/current samples
with actual cleanup engine/build. Do not pool old S1/Apple runs with new MiniCPM runs
as though one configuration produced them. Exact model files are reused across roles;
workload overlap and bounded fallback remain part of latency measurements.

This folder is the follow-up to `roadmap/done/DICTATION-MEETINGS-LIMITS/`. That roadmap
implemented 29 of its 31 tasks and closed four phase gates. This one covers exactly what it
left, and nothing else. It is executed task by task by a coding agent that has **no access to the
conversation that produced it**. Everything you need is in these files, the repo, and the gates
report the app now writes on every build.

Read this file completely, then `AGENTS.md` at the repo root, then `STATUS.md` in this folder.
Where this file is silent, follow `roadmap/done/DICTATION-MEETINGS-LIMITS/00-README.md` §8 for
the per-task workflow, gates and rules — the previous roadmap's own rule set, unaltered.

---

## 1. Why

The previous roadmap proved **mechanisms** and left **rates** unmeasured. That distinction is the
whole of this folder.

| What the four gates proved | What nobody has measured |
|---|---|
| a cold cleanup call answers instead of timing out | whether the timeout rate fell from its 18 % |
| a hold released during start-up transcribes | whether holds still end with nothing typed |
| 0 notes facts dropped on a 90-minute 4 K fixture | how long key-up → text actually takes now |
| 0 s of audio lost behind a slow transcriber | how many buffers a real hold drops |
| 0 unattributed far-end segments on the fixture | the same rate on a real call |
| 3/3 interrupted meetings resume with audio intact | how often that happens in a week |
| 0 error-level lines in the owner's log from a self-test | — (this one is a rate and it is 0) |

The reasons are structural, not accidental. `dictation.hold` rows — the record that makes every
hold countable, including the ones that typed nothing — **began at D-01b on 2026-09-25**. Until
the owner has used the app, there is nothing to count. And two tasks were explicitly
evidence-gated, which means the honest state for them is `blocked`, not `done` and not
`won't do`.

**Execution update, 2026-09-30:** F-01 already landed (`99d4a46`). A readiness
audit reproduced a gate-reader crash and an omitted measured-ASR condition;
F-01a repairs that Python evidence producer, with eleven real CLI fixtures green.
The folder moved to in-progress on this bounded claim. F-02…04 owner-use work
remains pending; the historical premise below is not current task readiness.

Three original items, in the order they block each other:

1. **F-01 — D-14's second condition is unmeasurable.** The gate needs to know how long a dictation
   waited for the speech lane. The app records that for meetings and not for dictation, so half
   the gate can never be read. This is the only code task here, it is ~5 lines, and it should
   land *before* the week being judged — otherwise the dictation-side lane waits in that week are
   simply missing.
2. **F-02, F-03 — the two evidence gates.** Both are now computed automatically. Each is `proceed`
   or `won't do (evidence)` once enough owner use exists, and this roadmap says what to build in
   the first case and what to record in the second.
3. **F-04 — the rate table.** T1–T9 from the previous roadmap §0.3, measured on the owner's own
   holds and recorded.

---

## 2. File map

| File | What it holds |
|---|---|
| `00-README.md` | this file: why, IDs, order, workflow, gates, kept limits |
| `STATUS.md` | the ledger — **update it after every task**; it also carries the rate table F-04 fills |
| `01-FOLLOWUP.md` | F-01 … F-04, the task texts, self-contained |

The previous roadmap's texts stay where they are, for reference and for the detail F-02/F-03's
implementations inherit: `roadmap/done/DICTATION-MEETINGS-LIMITS/01-DICTATION.md` (§D-13) and
`02-MEETINGS.md` is not needed. Note that **`roadmap/` is git-ignored**, so these files live on
this machine only; the code, the flags and the gates report do not depend on them.

**IDs are fixed: F-01 … F-04. Never renumber.** They are deliberately *not* `D-13`/`D-14` or `M-nn`
— those belong to the previous roadmap, whose ledger records their state and must be updated when
they resolve. This folder never renumbers another roadmap's IDs.

---

## 3. The gates report: what you are reading

`make app` refreshes this in the background (`Scripts/dictation-gates.sh`), detached and unable to
fail a build. It lands three files in `~/Library/Caches/NextNotesBuild/dictation-meetings/`:
`gates-latest.txt` (in words, with a `reproduce:` and a `decide:` line), `gates-latest.json`, and
one `gates-history.jsonl` line per run carrying the commit it ran against. A reader that breaks
appends `GATES_RUN_FAILED` and leaves the last good report in place, so a stale report never looks
like "no news".

Read it first, every time:

```bash
cat ~/Library/Caches/NextNotesBuild/dictation-meetings/gates-latest.txt
# or, attached and fresh:
make gates
# or the raw reader:
python3 Scripts/dictation-stats.py --gates
```

Each gate prints `proceed`, `won't do (evidence)`, or `not enough data` **with the shortfall
named**. An undecided gate is never a pass, and this roadmap forbids turning `not enough data`
into a pass by any means.

The thresholds are the previous roadmap's task text, restated so they cannot drift:

| Gate | Proceed when | Decidable only after |
|---|---|---|
| **D-13** pipelined holds | `dictation.press_refused` in state `finishing` **≥ 3 per 100 holds** | ≥ 100 owner holds **and** ≥ 7 days of use |
| **D-14** per-pass ASR lane | ≥ 3 occurrences of *either*: a hold overlapping a meeting whose window wait is **≥ 5 s**, or a dictation start waiting **≥ 1 s** on the lane | enough qualifying occurrences, and (for the second condition) F-01 landed |

**D-14's second condition needs F-01, which has landed.** The availability field
still reports false for a dataset with no valid measured ASR rows; missing data is
not a zero-second wait. F-01a now counts the measured starts as well as the existing
meeting-overlap condition, without changing the occurrence threshold.

---

## 4. Order

| Task | What | Blocked on |
|---|---|---|
| **F-01** | record the dictation side's speech-lane wait on `dictation.asr` | already done `99d4a46`; do not repeat |
| **F-01a** | repair the read-only diagnostic producer | done `7a94d2d`; eleven CLI cases green |
| **F-01b** | enforce the minimum observed days in both reader modes | done `fba4287`; fifteen CLI cases green |
| **F-04** | measure T1–T9 on the owner's holds and record them | ≥ 7 days and ≥ 30 owner holds *after* F-01 |
| **F-02** | decide D-13 from the report; build the queued hold if `proceed` | F-01 (for clean data), then the report |
| **F-03** | decide D-14 from the report; move the acquire per pass if `proceed` | F-01 (its own second condition), then the report |

F-04 before F-02/F-03 is deliberate: the rates are the evidence those two decisions argue about.
A `proceed` on D-13 with the tail still 9 seconds long is a different decision from the same
verdict with it at 2.

**Time is the real dependency.** Nothing here needs a decision from the owner except *using the
app*; no task is blocked on a model, a grant, an account or another agent. If the report says
`not enough data`, the correct action is to wait and re-read it, and to say so in `STATUS.md`.

---

## 5. Kept limits — do not "improve" these while working here

| Limit | Where | Why it stays |
|---|---|---|
| Every await in the dictation tail stays behind `withBoundedWait`; `Limits.cleanup` 30 s | `Core/DictationController.swift` | AGENTS.md: the tail's deadlines are the answer to "stuck in `.finishing`" |
| The 26 s chunked pass budget and `maxWords` 120 | `Formatting/SentenceChunker.swift` | measured; the previous roadmap's D-07/D-08 changed per-call ceilings inside it, never this |
| `CleanupGuard`'s thresholds, `CleanupSessionWarmer.capacity` 3, one staged session per take | `Formatting/CleanupGuard.swift`, `FoundationModelFormatter.swift` | the previous roadmap's D-11 changed salvage *granularity*, not the thresholds |
| `deniedBundleIDs` is a denylist; Chrome and WebKit are ask-only | `Meetings/CallPolicy.swift` | AGENTS.md: a conferencing app nobody has heard of must work on day one |
| Meeting new fields decode with `decodeIfPresent` | `Meetings/MeetingModels.swift` | AGENTS.md: otherwise every meeting on disk vanishes |
| One task ledger, one audio channel, one tool manifest, one usage log | `AGENTS.md` | `usage.jsonl` is the only model-pass log; **F-01 adds a field to a row, never a second log** |
| Self-tests pass seams; a self-test never writes the owner's stores | everywhere | AGENTS.md: 55 fixture rows once leaked into a real history |
| Build with `make build`, install with `make install OPEN=0`, self-tests via `Scripts/run-selftest.sh` | — | AGENTS.md, and the iCloud folder's mid-build modification failure |

---

## 6. Workflow, commits and gates

**Per task.** Read the task and its files → re-verify every anchor with `grep -n` (lines drift;
the task text names the symbol too) → write the red-first self-test (seam only, no fix) →
`make build` → `make install OPEN=0` → run it and see `<NAME>_FAILED` → implement → build → install
→ run until `<NAME>_OK` → run the regression flags → update `STATUS.md` → one commit containing
only the files you touched (`git add <paths>`, never `-A`).

**Commits** are `F-0N: <title>`; F-04 and any task that only measures may record instead of
commit. Every commit body ends with
`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Logs go to
`~/Library/Caches/NextNotesBuild/dictation-meetings/F-0N-{red,green}.txt`; the gates report lives
beside them as `gates-latest.txt`.

**Cross-roadmap bookkeeping.** When F-02 or F-03 resolves a gate, the **previous** roadmap's row
(`roadmap/done/DICTATION-MEETINGS-LIMITS/STATUS.md`, D-13 / D-14) is updated in the same commit,
with the verdict and the numbers. Its rows say `blocked` until then, and they are not this
roadmap's to change at any other time.

**The one phase gate** (run when every row is `done`, `won't do (evidence)` or `blocked`):

1. `make test`
2. `make acceptance TIER=core` — nothing that was PASS at the previous roadmap's four gates may
   be FAIL. Known red: `selftest-wake-live` (17/24 hits), and `selftest-computer` on a locked
   screen.
3. `cat ~/Library/Caches/NextNotesBuild/dictation-meetings/gates-latest.txt` — both gates decided,
   or explicitly still short, with the shortfall.
4. `python3 Scripts/dictation-stats.py --since 2026-09-25` and `Scripts/run-selftest.sh
   --usage-report` — the numbers F-04 recorded, re-read once more.
5. `Tests/Reports/DICTATION-MEETINGS-RATES-<YYYY-MM-DD>.md`, committed alone as
   `F-GATE: rates and gates report`.
6. Update *Phase gates* in `STATUS.md`, and the previous roadmap's two rows.

**Rules you must never break** (long form: `AGENTS.md`):

- Never bare `swift build` / `swift test` — this folder is inside the iCloud-synced repo. On
  "input file was modified during the build", wait 5 s and retry, up to 3×.
- Install only with `make install OPEN=0`. Never launch the GUI; never bare-invoke the binary.
- Self-tests only through `Scripts/run-selftest.sh --selftest-…`, foreground, one at a time.
  `--via-open` only for TCC-bound tests, and **never in a loop**.
- A self-test ends `<NAME>_OK` / `<NAME>_FAILED: <reason>`; a missing precondition is
  `<NAME>_ABSENT`, never OK. It must fail when the thing it names did not happen.
- Never lower a threshold, skip an assertion, special-case `SelfTest.isRunning` in production
  logic, or turn `_FAILED` into `_ABSENT` to get a pass. Stop and write `BLOCKED` instead.
- `MainActor.assumeIsolated` is forbidden. Never mutate `@State` inside a `Canvas` draw closure.
- `usage.jsonl` never leaves this Mac: no transcript, dictated text, app name, subject, address or
  URL in any row. **F-01 adds a duration, never content.**
- Use `/usr/bin/log`, not `log`. Never `tccutil reset` without `ai.pivotstudio.nextnotes`.
- When a task changes a behaviour `AGENTS.md` documents as deliberate, quote the paragraph, say
  what new evidence overrides it, and update `AGENTS.md` in the same commit.
- Never commit anything under `roadmap/`. Test reports go in `Tests/Reports/` (tracked).

**When stuck:** set the row to `blocked` and write the note under the ledger (date, what you
tried, the failing line and its saved path, what is missing). For F-02/F-03 the honest blocker is
almost always *not enough owner use*, and that is a valid terminal state, not a failure.

---

## 7. What "finished" means for this folder

- F-01 landed, and `gates-latest.txt` reports `dictation_side_lane_wait_recorded: true`.
- F-04's rate table filled from the owner's own holds: T1–T9 each **met**, or **not met with the
  number and the reason**, and the baseline row beside it for comparison.
- D-13 and D-14 each carry a verdict — `proceed` and built, or `won't do (evidence)` with the
  numbers — and the previous roadmap's rows agree.
- `make test` green; `make acceptance TIER=core` no regression.
- `Tests/Reports/DICTATION-MEETINGS-RATES-<date>.md` written and committed.
- This folder moves to `roadmap/done/`.
