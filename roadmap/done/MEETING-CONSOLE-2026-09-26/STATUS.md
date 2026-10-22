# MEETING-CONSOLE-2026-09-26 — STATUS

The progress record for the panel that opens over a live meeting. `00-README.md` is the entry
point, `01-PANEL.md` holds the five pieces, `02-VERIFICATION.md` holds the evidence. This is the
only place a status may be written down.

Built 2026-09-26 against `58d0b8c`, in seven parallel subagents over two phases.

---

## 1. Tasks

| ID | Piece | Status | Gate | Result |
|---|---|---|---|---|
| MC-01 | The panel, the rail, the one orb, the self-test gate | **done** | `--selftest-meeting-console` | `MEETING_CONSOLE_OK` |
| MC-02 | Notes: `MeetingScratchpad` + `ScratchNotesMerger` | **done** | `--selftest-meeting-scratchpad` | `MEETING_SCRATCHPAD_OK` |
| MC-02 | Notes: `MeetingScratchpadTidier` + the section | **done** | `--selftest-meeting-tidier` | `MEETING_TIDIER_OK` |
| MC-03 | Actions: the reconciler, redrawn for a panel, no new seam | **done** | console + existing actions gates | `MEETING_CONSOLE_OK` |
| MC-04 | History: `Knowledge/MeetingRecall.swift` + the section | **done** | `--selftest-meeting-recall` | `MEETING_RECALL_OK` |
| MC-05 | Ask: the assistant, through the manifest, no service | **done** | console + agent gates | `MEETING_CONSOLE_OK` |
| — | Tokens (10), acceptance tiers, README tree, AGENTS.md rules | **done** | `--selftest-ui-strings`, `make test` | `UI_STRINGS_OK`, 30/30 |

## 2. Scope boundary held

Three of the four sections added **no data layer**:

- **Actions** reads `AgentService.reconciled(for:)`; every button calls `AgentService`. No new
  proposal store, no second view of an action.
- **Ask** sends the question as typed with `source: .meeting`; the agent's existing seven
  `.meeting` tools read the meeting. No service, no prompt prefix, no second conversation.
- **History** is the only one that needed a query, and it reused `KnowledgeIndexer.searcher`,
  `GraphStore.personMeetings` and `MeetingStore` rather than adding a `KnowledgeSourceKind`
  (which would have rippled through eighteen exhaustive matches).
- **Notes** is the only section that needed something that did not exist, and it is two files in
  the meeting's own folder, not a second store and not a second root.

## 3. Defects found by running the gates

Both were in the verification, not in the feature. Both are written up in full in
`02-VERIFICATION.md` §2–§4.

| # | Found | Fix |
|---|---|---|
| 1 | `MeetingRecallSelfTest` never ran — a `RunLoop` pump that does not service the main-actor executor — **and** ~30 assertions named the failure while asserting the bug, so the gate would have passed on the behaviour it exists to catch | runner made `async`, pump/deadline/`FailureBox` deleted, every check rewritten to the tree's convention, `stage(_:)` lines added |
| 2 | `MeetingConsolePolicy` gated the sheet but not the button, so a self-test would have carried a dead control | button gated on the same rule; a check added and mutation-verified |
| 3 | (found by the same exercise) the `.related`-refusal check was **vacuous** — run against an off indexer, an empty answer was being read as a refusal | asserted as a pair against an indexer that is on; the mutation that first slipped through is now caught |

## 4. Not done, and why

| | Why |
|---|---|
| Seen by an eye | No grant-free way to render a sheet in this app; `--settings-sheet` needs a hosted window. **This is the first thing to do.** |
| `.sameTopic` / `.related` against this Mac's real index and map | Exercised end to end only over fixtures the self-test wrote |
| Tidier prose quality | Prompt and parse are pinned without a model; the prose a real model writes is unmeasured |
| Ask thread grouping observed | Reasoned from the two `recordX` call sites and verified by reading them |
| `PerformedActionRow` deduplicated | `private` in `MeetingActionsView`; ~30 lines duplicated rather than refactoring a view three other things read. Lift it when a fifth caller appears |
| `.findingActions` reachable mid-meeting | `agent.isThinking(_:)` is only set by the post-meeting review pass. Implemented as specified, flagged rather than worked around |
| Redrawn actions cards shared with `MeetingActionsView` | Same reason: `CandidateActionCard` and `ProposalCard` are `private` |

## 5. If you change this

- **Do not** let a section draw its own orb, header, pill frame or sheet frame. The one-orb rule
  is a property of `MeetingConsoleSheet.swift`, not something four files each remember.
- **Do not** un-gate the panel button, or give the panel a width floor.
- **Do not** prefix the assistant's question with a transcript dump. Add a tool.
- **Do not** give `.related` a `.samePeople` fallback, a similarity percentage, or a matched
  snippet. The first is a lie about the question, the other two are claims the query cannot back
  up.
- **Do not** write `notes.md` from the console. It is the notes model's file, and it overwrites.
- **Do not** write a check whose name describes the failure. Name the property that must hold and
  assert it — see `02-VERIFICATION.md` §2.2.
- A new `MeetingConsoleSection` case is picked up by `allCases`, so the self-test checks its
  title, symbol, help and that the panel draws it — but the compiler is what forces the rest:
  `MeetingConsoleSheet.current` is an exhaustive switch, so a fifth section will not build until
  its `Resolved` arm exists. A new `MeetingConsoleActivity` case gets no such help from the
  compiler, which is why its table is walked from `allCases` rather than from a list typed out
  beside it — a fifth case there would otherwise be skipped by the only test that would notice.
- `performed` rows in the Actions section are re-read from `MeetingStore` rather than from the
  reconciler, because approving rewrites `meeting.json` and the in-memory copy is stale.
