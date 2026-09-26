# DICTATION-MEETINGS-LIMITS — Phase B report (nothing lost, consent holds)

Date: 2026-09-25 · Tree: `ab1895b` (gate A's report) · Raw output:
`~/Library/Caches/NextNotesBuild/dictation-meetings/gateB/`

Phase B is "nothing gets lost and consent holds". Ten tasks landed, every one red-first.

| Task | Commit | What it changed |
|---|---|---|
| D-04 | `e835c47` | short Parakeet audio padded to 300 ms through the shared `ParakeetInput`; engine errors reach the user only as plain sentences |
| D-05 | `95f59f8`, reconcile `96d1a3a` | a press during the error card starts a new hold; the 3 s clear is token-checked |
| D-10 | `5255ab5` | the learner refuses `of a product → for ProductFlo`, `add` is idempotent, re-saves learn only what is new, a review notice for suspicious and duplicate rules |
| D-02 | `05ee466` | capture opens at key-down into a pre-roll and replays into the engine; a release in `.starting` transcribes instead of failing |
| D-03 | `abc6535` | speech-energy check distinguishes an empty hold from a quiet one, the last failed hold's audio is kept, "Try again" |
| M-02 | `8a09ea8` | every audio helper resolves to its owning app before any call rule; `replayd` denied; helper-keyed answers migrated once |
| M-06 | `69f47c0` | the detected-call question stays on the island for the life of the call |
| M-05 | `9f119f8` | map-reduce never drops facts: per-chunk budget, collapse pass, visible count |
| M-01 | `0aba378` | long-window finals after Stop; the live tier keeps its 2–5 s windows |
| M-08 | `3f26b91` | interrupted meetings resume at their stage; temporary audio survives; stall watchdogs; Quit is confirmed while recording |

## 1. `make test`

30 tests in 2 suites passed — unchanged from the Phase A gate and from the pre-change baseline.
D-10 changes what is *learned*, not how a rule applies, so the correction vectors are untouched
by design (the task says so, and there is no learner on Windows to keep in parity —
`grep -ri CorrectionLearner windows/` is empty).

## 2. `make acceptance TIER=core`

**15/16 PASS**, identical to the Phase A gate on this tree: the only FAIL is
`--selftest-wake-live` (`17/24 hits, 3/32 false at sens 0.6`), the known red AGENTS.md records
before this roadmap. Nothing in Phase B regressed a CORE entry. Note `--selftest-meeting-resume`,
which is this phase's new CORE gate, **PASS**es.

## 3. Exit flags

| Flag | Final line |
|---|---|
| `--selftest-dictation` (via-open) | `DICTATION_OK: every hold came back to idle` (Phase A gate, same tree) |
| `--selftest-learn` | `LEARN_OK: 20 case(s), corrections learned and rejections held` |
| `--selftest-calls` | `CALLS_OK: 0 process(es) holding audio, own pid 23757, rules behave` |
| `--selftest-island` | `ISLAND_OK: 1 display(s), notched, placement notch, state machine behaves` |
| `--selftest-notes-longform` | `NOTES_LONGFORM_OK: 90-min facts kept on 4K and 8K, stubborn collapse visible, single pass intact, overflow retried, window-derived chunks` |
| `--selftest-meeting-finals` | `MEETING_FINALS_OK: long-window finals hold against the live tier` |
| `--selftest-meeting-resume` | `MEETING_RESUME_OK: 3/3 resumable meetings reached .done with notes; no temp audio released early; 4 write(s) for 100 segments, flushed to 100; a trailing write inside the interval, cancelled by the exit` |

## 4. The numbers this phase was for

**M-01 — the transcript.** Finals are cut at 10–30 s pauses after Stop; the live tier keeps its
2–5 s windows. On the generated fixtures (M-16a's, `$NEXTNOTES_FIXTURES/meetings`):

```
MEETING_FINALS_LANG  fr-dialogue.wav          live=0.0% final=0.0%
MEETING_FINALS_RECALL fr-dialogue.wav         live=0.908 final=0.929
MEETING_FINALS_LANG  fr-dialogue-phone.wav    live=0.0% final=0.0%
MEETING_FINALS_RECALL fr-dialogue-phone.wav   live=0.865 final=0.872
MEETING_FINALS_LANG  en-dialogue.wav          live=0.0% final=0.0%
MEETING_FINALS_RECALL en-dialogue.wav         live=0.956 final=0.963
MEETING_FINALS_RTF=0.0327
```

RTF 3.3 % against the ≤ 5 % target. **The wrong-language rate is 0.0 % on both tiers, so the
4× ratio the task asks for cannot be computed on synthetic voices** — the honest reading is that
the flip I2 measured on real French calls (16–24 % at 2–5 s windows) is not reproducible with
`say`, and re-measuring it is owner work on the next real meeting via
`--meeting-quality-report`. The recall column is the part that does move: the final pass recalls
more of the audio than the live tier on all three fixtures.

**M-05 — no lost notes facts.** A 90-minute fixture on a 4,096-token worst-case provider ends
`chunks=15 collapsed=2 dropped=0` (it dropped 12 facts before), and the same holds at 8,192.

**M-08 — no lost meetings.** 3/3 seeded interrupted meetings reach `.done` with notes; the
temporary recording of each is still there when its stage runs and is released only afterwards;
a 0.5 s stalled notes pass leaves a problem, keeps its audio and says so.

**M-02 — consent.** `CALLS_OK` with the 8/8 owner-resolution table: a Chrome tab call is
"Google Chrome", offered Ask/Never only, never recorded unasked. `com.apple.replayd` is denied
and is no longer an app-list row.

## 5. Dictionary hygiene

`LEARN_OK: 20 case(s)`. The two bad pairs from the audit are refused
(`of a product → for ProductFlo`, `of the → for the`); the known good ones still learn
(`cloud code → Claude Code`, `quen 2.54b → Qwen 3.5 4b`, `OLAMA → Ollama`). The five duplicate
rules already on disk are surfaced for review and are **not** deleted without a click — the
file is the user's. Raw engine error strings shown to the user: 0 (D-04).

## 6. BLOCKED tasks in this phase

None. The two blocked tasks in the roadmap (D-13, D-14) are Phase D and blocked on owner use.

## 7. Owner use still owed

The hold-level numbers (`key-up → text` p50/p90, lost share, `press_refused` share) need the
owner's own dictations; `dictation.hold` rows start with the first hold after D-01b landed today.
See *Owner-use measurements*.
