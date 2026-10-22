# MEETING-CONSOLE-2026-09-26 — 02 Verification

Every gate that was run on 2026-09-26, with the output it printed, followed by the two defects
that running them found and the mutation checks that prove each gate goes red when its subject
breaks. `00-README.md` has the commands; this file is the record.

Base commit: `58d0b8c` ("P1-05: three constrained-decoding backends").

---

## 1. The gates

Run in this order, on an installed build (`make install OPEN=0`, `OPEN=0` never omitted):

| Gate | Result |
|---|---|
| `--selftest-meeting-console` | `MEETING_CONSOLE_OK` |
| `--selftest-meeting-scratchpad` | `MEETING_SCRATCHPAD_OK` |
| `--selftest-meeting-tidier` | `MEETING_TIDIER_OK` |
| `--selftest-meeting-recall` | `MEETING_RECALL_OK` |
| `--selftest-ui-strings` | `UI_STRINGS_OK` |
| `--selftest-meeting-resume` (CORE, adjacent: `NotesService` changed) | `MEETING_RESUME_OK: 3/3 resumable meetings reached .done with notes; no temp audio released early; 4 write(s) for 100 segments, flushed to 100` |
| `--selftest-audio-retention` (adjacent: `MeetingStore` changed) | `AUDIO_RETENTION_OK: temporary audio keeps 72 h, the disk guards hold, the sweeper spares kept, active and problem meetings` |
| `--selftest-notes-truncation` (adjacent: the notes pass) | `NOTES_TRUNCATION_OK` |
| `--selftest-store-isolation` | `STORE_ISOLATION_OK: 14 files and 23 defaults unchanged` |
| `make test` (shared vectors) | 30 tests in 2 suites passed — `VectorTests`, `SpokenFormsTests` |

`--selftest-store-isolation` is the one that matters most for a feature that adds a file to the
meeting folder: it says nothing was written to the owner's real stores.

**No compiler warning** is attributable to any of the 14 new or 8 modified files (checked by
touching each and grepping the build output).

`make acceptance TIER=integration --dry-run` renders all four new flags, and
`bash -n Scripts/acceptance.sh` passes.

## 2. `--selftest-meeting-recall` was wrong twice

This is the substantive finding of the whole exercise and it is worth reading in full, because
both failures are failures of the *test*, not of the feature — and the second one had already
shipped a green run that proved nothing.

### 2.1 It never ran

The first run reported `MEETING_RECALL_FAILED: the checks did not finish in 60s` and nothing
else. The cause: `run()` was synchronous and tried to let the main actor turn by pumping
`RunLoop.current.run(until:)` between 5 ms slices. It does not service the Swift main-actor
executor when `run()` is itself called from a main-actor task — which is exactly how the
registrar calls it. So `checks()` never started, no stage line printed, and the only thing the
run ever produced was the deadline.

Fixed by deleting the pump, the deadline and the `FailureBox`, and making the runner
`static func run() async -> Bool` — the registrar already has an async context, so the whole
run-loop bridge was solving a problem it had created. A `stage(_:)` line was added per section,
because a bare "the checks did not finish" names no stage to look at; the next run printed all
ten.

### 2.2 Roughly thirty assertions passed on the behaviour they were written to catch

With the runner fixed the test ran, and reported three failures. All three were bad assertions —
and they were bad in the same way, which is why they had survived: the check *name* described the
failure and the *condition* asserted the bug.

```swift
check("the meeting in the room is in the list of earlier meetings",
      recent.contains { $0.meetingID == live.id })     // passes when the bug is present
```

The convention in the rest of the tree is the opposite: `expect(condition, message)` where the
message names the property that must hold. Every check in the file was rewritten to that
convention, and the file's doc comment now says why in a paragraph, because this is the kind of
mistake that reads as thoroughness.

The three failures the honest run produced were:

| Reported | Reality |
|---|---|
| `a question with no other meeting never reaches the searcher (1)` | bad assertion. `UnreadableSearch.asked` is **cumulative**, so the check compared against zero when it meant "unchanged". Now each of the two checks captures the count before the call and asserts it did not move. |
| `a title with no words never reaches the searcher (1)` | same cause. |
| `a passage with no heading of its own is dropped` | a rule I invented. The heading only chooses between `"Same topic: <section>"` and the plain `"Same topic"`, so a no-heading passage is **kept** and becomes a row — that is the exact case the plain wording exists for, and the end-to-end case two stages later depends on it. |

No product code changed as a result of any of this. All three were in the test.

## 3. The honesty claim was vacuous, and the first mutation proved it

`MeetingRecall`'s load-bearing claim is that **`.related` refuses rather than answering
`.samePeople`'s question when the map is off**. AGENTS.md states the same rule for the meeting
console: *"`samePeople` standing in for `related` would put a confidently-labelled row in front of
somebody who asked about a project."*

The test asserted it — and the mutation proved the assertion was worth nothing. The mutation was
a `.related` that fell back to `samePeopleHits` when the map was off:

```
mutant 1 -> MEETING_RECALL_OK          ← the bug, undetected
```

The reason: the only `.related`-refusal check ran against the **harness indexer, which is
switched off**. A fallback that needs the searcher therefore returns the same empty list, so the
check passed on the bug. An empty answer was being read as a refusal, and the two are different
things.

The test now asserts the pair, against an indexer built with `KnowledgeIndexSettings(enabled: true)`
and the map off:

```swift
check("the index is on, so the pair below can tell a refusal from a dead end", indexer.settings.enabled)
check("the same index answers .sameTopic", !answered.isEmpty)
check("related answers nothing with the index on and the map off (3)", refused.isEmpty)
```

One filter on the same indexer answers; the other refuses. Re-applied mutation:

```
mutant 2 -> MEETING_RECALL_FAILED: related answers nothing with no map to read
            MEETING_RECALL_FAILED: related answers nothing with the index on and the map off (3)
```

Caught by both checks. The second one is the check that could not have existed before.

## 4. The other mutation checks

| Mutation | Caught by |
|---|---|
| drop the `!sourceIDs.isEmpty` guard in `topicSignals` | `a question with no other meeting never reaches the searcher (2 before 1)` |
| `.related` answers `.samePeople`'s question when the map is off | two checks — see §3 |
| the Notes pill's badge orb animates (two live orbs for one job) | the activity table + the "the panel builds no orb of its own" source check |
| `.idle` given an orb, or made busy, or two busy titles colliding | the activity table |
| the rail reordered, or wired to the wrong section | `the rail draws one row per section`, the four "the panel draws X from Y" checks |
| a seventh `MeetingConsoleActivity` case | the table is walked from `allCases`, so a new case cannot be skipped |
| the self-test gate removed, or the sheet replaced by `EmptyView()` | `the panel is never presented during a self-test`, `…and is presented in the app` |
| a literal value injected into each of the five UI files | the token scan, one offender per canary line, `[1, 2, 3, 4, 5]` |
| a `spacing: 0` mistaken for a magnitude | `…and reads a zero as the absence of a value` |
| **the panel button left ungated** | `the panel's own button is gated on the same rule as the panel` |

The last row is the second real defect, found by reading the diff rather than by a test:
`MeetingConsolePolicy` guarded the `.sheet` but `consoleButton` was drawn unconditionally, so a
self-test would have carried a control that does nothing. Fixed, and the check above added and
then mutation-verified — re-applying the exact bug produces
`MEETING_CONSOLE_FAILED: the panel's own button is gated on the same rule as the panel`.

The four data-layer gates were mutation-checked by the agents that wrote them and report
`MeetingScratchpadSelfTest` 12/12, `MeetingScratchpadTidierSelfTest` 2/2, and
`MeetingConsoleSelfTest` 16/16, each naming the assertion that bit. Those ran as standalone
harnesses against the shipped source, because at the time the flags were not yet registered.

## 5. How the UI-string lint was actually verified

`UIStringsLint.run()` resolves its directory from `#filePath`, so running the file out of a
temp directory reports `UI_STRINGS_OK` **vacuously** — it scanned the temp copy. The first green
was therefore meaningless, and the real run calls `scan(directory:)` with the real `UI/` path.

Two canaries were then needed to show the scanner is not merely quiet:

- a canary injected into a spot the lint does not cover (`subtitle:`) reported OK — correct, since
  only `Text(`, `Label(`, `LabeledContent(`, `TextField(` and `accessibilityLabel(` are call sites;
- a canary injected into a real `Text(` site — `Text("workspace.send_email")` — produced
  `UI_STRINGS_WRONG: MeetingConsoleNotesSection.swift:81: workspace.send_email` and exit 1.

So `UI_STRINGS_OK` over the real tree is a green that was earned.

## 6. What is still unverified

- **The panel has never been seen by an eye.** There is no grant-free way to render a sheet in
  this app — `--settings-sheet` uses `cacheDisplay`, which needs a hosted window. Every visual
  claim in this folder is argued from tokens and source.
- `.sameTopic` and `.related` have run only over indexes and maps the self-test wrote.
- The Tidier's prompt and parse are pinned without a model; the prose a real model writes into
  that shape is not measured.
- The Ask section's thread grouping is reasoned from the two `recordX` call sites and verified by
  reading them.
- `agent.isThinking(_:)` is only ever set by the post-meeting review pass, so
  `.findingActions` will be false during a live meeting. Implemented as specified, flagged rather
  than worked around.

## 7. A note on the state of the tree

A second session was working in this same working tree throughout, mid-refactor of
`Agent/Planner/`. It broke the build five times during this work, and every install was gated on
a clean `make build` for exactly that reason — twice a stale binary produced a convincing
`MEETING_RECALL_OK` that was not the code under test. `TOOLLOOP_PRODUCTION_FAILED` lines appear in
the `--selftest-store-isolation` output and belong to that session, not to this feature.

If you re-run any of this later, **check that the installed binary is newer than the source you
think you are testing.** That is the whole lesson of §2.1.
