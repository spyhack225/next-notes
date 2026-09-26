# DICTATION-MEETINGS-LIMITS — Phase D report (deeper changes and hygiene)

Date: 2026-09-25 · Tree: `b1473a8` (gate C's report) · Raw output:
`~/Library/Caches/NextNotesBuild/dictation-meetings/gateD/`

Phase D is the deep dictation change, the hygiene work, and the meetings' remaining depth. Nine
tasks landed, every one red-first.

| Task | Commit | What it changed |
|---|---|---|
| D-12 | `39c16f6` | stable sentences are cleaned while the key is still down, so the tail only carries the unstable ones |
| D-15a | `ce94dfc` | `runs.jsonl` appends in memory, reloads only on edit/delete, retention is opt-in |
| D-15b | `50467e0` | the clipboard is left alone when the user copied something during the restore window (`changeCount`) |
| D-15c | `7ef34ef` | injected self-test failures log at info in a `selftest` category, never at error level in the user's log |
| D-16 | `2568758` | spike report: Parakeet vocabulary boosting (**recommend defer**) and Terminal title context (**recommend do the project-root row**) |
| M-14 | `24d3a70` | live meeting understanding scheduled on speech time, reading the last 3 minutes, on its own switch |
| M-15 | `91d56bd` | speaker identification is on by default once its models exist, and offered after the first multi-voice meeting |
| M-16b | `40af406` | the notes collapse pass and the live reconcile write their usage rows through P0-20b's writer |
| M-16c | `76b819e` | `transcript.json` is written on a 5 s throttle with a trailing write, flushed on every exit |

M-13 and M-11 were completed in phase order but belong to this phase's dependency graph; their
evidence is in the C report.

## 1. `make test`

30 tests in 2 suites passed — unchanged across all four gates.

## 2. `make acceptance TIER=core`

**15/16 PASS**, unchanged across all four gates on this tree. The single FAIL is
`--selftest-wake-live` (`17/24 hits, 3/32 false at sens 0.6`), the known red AGENTS.md records
before this roadmap began. No CORE entry regressed at any gate.

## 3. Exit flags

| Flag | Final line |
|---|---|
| `--selftest-dictation` (via-open, once) | `DICTATION_OK: every hold came back to idle` |
| `--selftest-dictation-hygiene` | `DICTATION_HYGIENE_OK: history appends in memory, retention is opt-in, the clipboard survives` |
| `--selftest-contention` | `CONTENTION_OK` |
| `--selftest-meeting-live` | `MEETING_LIVE_OK: cadence, cards and the authority split hold` |
| `--selftest-onboarding` | `ONBOARDING_OK` |
| `--selftest-metrics` | `METRICS_OK` |
| `--selftest-usage-log` (M-16b's cases) | `USAGE_LOG_FAILED: 1 problem(s)` — `E1: the typed turn wrote no answer row for its turnID` |

Every gate-D flag this roadmap owns is green. The one failure is the same `E1` seen in gate A:
it exercises the **typed Agent turn**, which is AGENT-OVERHAUL's in-flight work (its
uncommitted `RealtimeAgent+ToolLoop.swift` and untracked `AgentCapabilityManifest.swift`), not a
file of this roadmap. M-16b's own cases M6 (15 map + 2 collapse + 1 reduce rows matching the
result exactly) and M7 (one `meeting.reconcile` row) pass within the same run.

## 4. What the hygiene work bought

- `runs.jsonl` no longer rewrites the whole file per dictation; the store appends in memory and
  re-reads only when the user edits or deletes. Retention is opt-in ("Forever / 90 days / Last
  5,000"), off by default, so the owner's file is never truncated without their choice.
- The clipboard is no longer overwritten when the user copied something during the 400 ms restore
  window.
- Injected self-test failures no longer write error-level lines into the owner's unified log:
  **3 error lines before, 0 after, 8 `[selftest]` info lines** on the same run.
- `transcript.json` is written on a 5 s throttle with a trailing write inside the interval and an
  unconditional flush on `stop()` / `endAbruptly()` / `abort()`: **4 writes for 100 segments,
  100 segments on disk at the end.** M-08's crash-recovery property still holds, because the
  interval, not the write count, is what protects the transcript.

## 5. The two blocked tasks, decided as blocked rather than guessed

**D-13** (pipelined holds) and **D-14** (per-pass `.realtimeASR` acquisition) are evidence-gated.
`usage.jsonl` has **0** `dictation.hold` rows: D-01b landed today (`d9d6f8b`), so the owner's own
dictations will be the first rows the log ever holds, and both gates need a week of them.
`Scripts/dictation-stats.py` now prints `holds.press_refused_finishing_per_100` (D-13's own
threshold), so each gate is one command:

```bash
python3 Scripts/dictation-stats.py --since 2026-09-25
```

D-13 proceeds only if refused presses in state `finishing` reach ≥ 3 per 100 holds; D-14 only if a
dictation hold overlaps a meeting's transcription with a ≥ 5 s window wait, or waits ≥ 1 s on the
lane, ≥ 3 times. Neither is `won't do` — there is no evidence either way yet, and the honest state
is `blocked` with the command and the threshold recorded.

## 6. Owner use still owed — the whole of `01-DICTATION.md` §0.3

T1 (key-up → text p50/p90), T2 (timeout rate), T3 (wasted share), T4 (key-down → capture p90),
T5 (holds that end with nothing typed), T6 (raw strings shown), T7 (layout cut by its deadline),
T9 (learner) are hold-level numbers. The gates measured the **mechanisms** on fixtures and in
self-tests; the **rates** need the owner to use the app. *Owner-use measurements* is where those
rows go, one per phase, compared against the baseline row.

The two numbers already known from this Mac's own history, and which this phase's changes
directly address: 9 cleanup timeouts in 50 attempts (18 %, each waited out in full and thrown
away) and a 4.40 s worst-case key-down → capture that lost a hold outright.
