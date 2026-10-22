# MEETING-CONSOLE-2026-09-26 — 01 The panel (MC-01 … MC-05)

`00-README.md` in this folder is the entry point; `STATUS.md` is the progress record and
`02-VERIFICATION.md` holds the evidence. This file records five pieces, what each one is for,
what was rejected, and what a future change must not undo.

All five are **done**. Each section below keeps the house task fields — why it exists, what
changed, what must not be undone, and the gate that holds it — with the observed result filled in
where a result exists.

---

## MC-01 — The panel, the rail, and the one orb

**Effort:** 1 d  **Depends on:** nothing  **Unblocks:** MC-02 … MC-05

### Why

There was no surface over a live meeting at all. `MeetingLiveView` had a header, two level bars,
a transcript and `RenameMeetingSheet` — the only sheet reachable mid-meeting. A person in a call
who wanted to write something down, or check what had been agreed, or ask a question, had to stop
the recording to do it or leave the meeting.

### What was built

`UI/Meetings/MeetingConsoleSheet.swift`:

- `MeetingConsoleSection` — `notes, actions, history, ask`. `allCases` **is** the rail; the order
  is the order of the feature, not the alphabet, and the self-test pins it.
- `MeetingConsoleActivity` — the one table answering "what is this surface doing right now":
  `idle` (no orb at all), `transcribing`, `writingNotes`, `findingActions`, `lookingBack`,
  `thinking`. Every orb value is a row of AGENTS.md's orb table, not a choice made here.
- `MeetingConsoleSheet` — `HSplitView`, a 168pt rail and the content column. The floating action
  is `.glassSurface(cornerRadius: DS.Radius.consolePill)` in an `.overlay(alignment: .bottom)`, so
  content scrolls **under** it; the pane carries a bottom inset of `actionClearance` so the last
  line can be scrolled out from underneath. `.dottedField(opacity: .fieldFaint, fade: .top)`,
  matching `MeetingLiveView` and `MeetingDetailView`.
- `MeetingConsolePolicy.shouldPresent(isSelfTest:)` — the self-test gate.
- `MeetingConsoleSectionHeader` — the one heading row, so four sections cannot each invent a
  title bar.

`UI/Meetings/MeetingLiveView.swift`: a bordered **Meeting panel** button beside Stop, gated on
the same rule as the sheet, `⌘⇧M`.

### Design decisions

- **`HSplitView`, not `NavigationSplitView`** — the house pattern, and a `NavigationSplitView`
  wants a sidebar and a title bar and fights a sheet for both.
- **A `List(selection:)` rail, not four hand-drawn rectangles.** The stock sidebar style already
  draws the selected row on an accent-tinted rounded rectangle in whatever accent and appearance
  the person chose, which is the reference's dropdown highlight for free.
- **Width is `meetingConsoleWidth` (520) with a height floor and no width floor.** Asking for more
  than a host has is a demand SwiftUI declines by drawing past the edge — the measured version of
  that story is `settingsPaneMinWidth`. A long meeting scrolls instead of growing the panel.
- **The rail carries SF Symbols, not orbs.** The app's rule is one animating orb per screen, and
  the content area spends it on whatever is actually running. This also matches the reference,
  whose rail is plain icons.
- **The rail is a third of the panel** (168 of 520, leaving ≈344pt). It works — close to
  `settingsPaneMinWidth`'s 320 — but if the Actions list ever wants two columns,
  `meetingConsoleWidth` is the token to raise.

### Tokens added

`DS.Size`: `meetingConsoleWidth` 520, `meetingConsoleMinHeight` 520, `meetingConsoleRailWidth`
168, `meetingConsoleRowHeight` 44, `meetingConsolePillHeight` 40, `meetingConsoleNoteEditorHeight`
132, `meetingConsoleHistoryRowHeight` 56, `meetingConsoleHistoryPreviewLines` 3.
`DS.Radius.consolePill` 20. `DS.Motion.consoleSectionChange` `.smooth(duration: 0.22)`.
Ten tokens for the whole feature; nothing else was added speculatively.

### Do not

- Do not let a section draw its own orb, header, pill frame or sheet frame. The one-orb rule is
  currently a property of one file rather than something four files each remember.
- Do not give the panel a width floor.
- Do not un-gate the button. A control with no panel behind it is the exact state rule 5 in
  `00-README.md` exists to prevent.

### Gate

`--selftest-meeting-console` → `MEETING_CONSOLE_OK`. 16 mutations were tried against the first
version; all 16 produced a failure line. Two found real bugs in the author's own work: a
`spacing:` matcher that started outside any call and swallowed the next line, and a canary that
asserted 7 offenders where 5 existed.

---

## MC-02 — Notes: a line you typed that survives the meeting

**Depends on:** MC-01  **Unblocks:** nothing

### Why

`notes.md` is written by the notes model minutes after the meeting ends, and it overwrites the
file. A person who types "Tanya to update the ICP doc" at minute twelve would lose it. There was
also nowhere to type: `TextEditor` appeared in exactly five places in the tree, all sheets, all
for *finished* meetings.

### What was built

`Meetings/MeetingScratchpad.swift` — `MeetingScratchNote` (`id`, `text`, `at`, `isPinned`,
`maxStored = 200`, `singleLine`) and `ScratchNotesMerger` (`heading = "Your notes"`, `markdown`,
`merged`).

`Meetings/MeetingStore.swift` — `scratchpadFile = "scratchpad.json"`, `scratchpadRevision`,
`scratchpad(for:)` (uncached, like `notes(for:)`), `saveScratchpad(_:for:)` (atomic, bumps the
revision, invalidates search, tells `KnowledgeIndexer` — exactly what `saveNotes` calls).

`Meetings/NotesService.swift:120-122` — four added lines. The merge happens where the notes are
already being written.

`Meetings/MeetingScratchpadTidier.swift` — the pass behind the pill. `Outcome` is
`.wrote` / `.cutShort` / `.noModel` / `.failed`; `promptBlock` and `parse` are pure and
`nonisolated`.

`UI/Meetings/MeetingConsoleNotesSection.swift` — composer (Return adds, Shift-Return breaks, and
the field stays ready for the next line, because a person taking notes mid-meeting must never
click before typing the next one), the notes as **selectable** rows pinned-first, the tidied
document in a `GlassCard` underneath with a "who wrote it" chip and a copy button, and the pill.

### Design decisions

- **The tidier is not a second notes pipeline, and it writes nothing until you press "Keep
  this".** `NotesService` reads the transcript and runs after the meeting. This turns the
  fragments *you typed while the meeting was still running* into a document you can read and
  keep. `.cutShort` rather than a shorter document presented as complete; `.noModel` with a plain
  sentence rather than a structure invented from nothing.
- **`markdown` is skipped when the list is empty**, and `merged` strips a pre-existing `## Your
  notes` from the generated side, ending at the block's own `##` rule — which is what makes a
  second pass a no-op and the merge idempotent.
- **The rows are selectable, and deliberately not a `List`.** The Dictation list is
  deliberately non-selectable; repeating that here would cost the person their notes. Copy is how
  a fragment gets out.
- **The empty state is narrower than "nothing at all".** It renders only when the meeting is not
  recording, because a `breathing` orb beside the status row's `weaving` would be two animating
  orbs naming two different things. While recording, the reassurance that a line is kept as
  written is carried by the header subtitle instead.
- **No new `KnowledgeSourceKind`.** The scratchpad reaches the index by being folded into the
  notes' chunking at the end of the meeting. A new case would have rippled through eighteen
  exhaustive matches in the tree for no benefit here.

### Not proven

The prompt and the parse are pinned by `--selftest-meeting-tidier` with no model, so the *shape*
of the output is proven. The prose a real model writes into it is not.

### Gate

`--selftest-meeting-scratchpad` → `MEETING_SCRATCHPAD_OK` (41 checks) and
`--selftest-meeting-tidier` → `MEETING_TIDIER_OK`. Both halves were mutation-checked: 12 of 12
and 2 of 2 caught, each naming the assertion that bit.

---

## MC-03 — Actions: the real-time list, on the seam that already existed

**Depends on:** MC-01  **New data layer:** none

### Why

`MeetingActionsView` draws the reconciled actions for a **finished** meeting. Mid-meeting, the
same list existed in `AgentService` and on the island, one card at a time, and nowhere as a list
a person could read.

### What was built

`UI/Meetings/MeetingConsoleActionsSection.swift` (664 lines). Three groups in the reconciler's own
order — "Asked in the meeting", "Waiting for you", "Done" — with `MeetingConsoleActivity
.findingActions` while a pass or a tool is running, and `floatingAction == nil`.

### Design decisions

- **The cards are a re-draw of `MeetingActionsView`'s, not a shared type.** `CandidateActionCard`,
  `ProposalCard` and `PerformedActionRow` are all `private` to that file, and duplicating ~30
  lines of `PerformedActionRow` was cheaper than a cross-file refactor of a view three other
  things read. This is the one piece of duplication in the feature and it should be lifted the
  first time a fifth caller appears.
- **One card, two shapes.** A row with a proposal is a `GlassCard`; a row that is only a candidate
  is not. Waiting-ness is surface, chip line and chip text — never colour alone, and never red.
- **No panel-wide "Approve all".** That would put a bulk path in front of irreversible actions,
  which is the one thing the permission model exists to prevent. An approve button lives on its
  own row, next to the thing it approves.
- **Every button calls `AgentService`**, which routes through `AgentToolExecutor` and the
  permission model. There is no second path from a card to a Workspace write. Three sheets the
  first version carried were dropped: "Identify speakers" and "Review this meeting" need a
  finished transcript, and nothing here navigates anywhere, so there is no `›` chevron.
- **Three empty states, not one.** Follow-up actions off (`.breathing`, a `SettingsLink`), nothing
  connected (`.connecting`, `authState.detail` naming which of four it is), and nothing to do yet
  — which forks on `agentLiveDuringMeeting`, because the shipped default is off and a live panel
  that says "nothing yet" while nothing is listening is a lie.

### Known oddity

`agent.isThinking(_:)` is only ever set by the **post**-meeting review pass, which is guarded on a
non-empty transcript. So in practice `.findingActions` will be false during a live meeting. The
state is implemented as specified and will start mattering if the live pass ever reports itself
through `thinking`. Flagged rather than worked around.

### Gate

No new self-test: the section has no logic of its own, and its two axes are covered by
`--selftest-meeting-console` (the activity table) and the existing actions-path gates. Its source
is linted for literal values and for banned words by the same two scanners the other three
sections run.

---

## MC-04 — History: which earlier meetings, and why

**Depends on:** MC-01  **New data layer:** `Knowledge/MeetingRecall.swift`

### Why

`relatedNodes(matching:)` existed but is node-level, not meeting-level; `Assembler` groups hits by
source, which is ranking, not relatedness. There was **no related-meetings capability and no
same-people query** anywhere in the tree.

### What was built

`MeetingRecallHit` (`meetingID`, `title`, `at`, `why`, `people`, `matchCount`),
`MeetingRecallFilter` (`.recent`, `.samePeople`, `.sameTopic`, `.related`, each with a title, a
symbol, the **question** it answers and a `help`), and `MeetingRecall` with
`availability(indexEnabled:graphEnabled:filter:)`, `hits(meeting:filter:indexer:store:limit:)` and
`reasonUnavailable(_:)`.

### Design decisions

- **Three sources for four filters, and the split is the feature.** `.recent` and `.samePeople`
  are a pass over the user's own meeting folders and answer on a Mac with every switch off.
  `.sameTopic` needs the search index (on by default); `.related` needs the map (off by default).
- **`.related` is the map, in two steps and no LLM**: expand `meeting:<uuid>` at depth 1, then
  `personMeetings(personID:)` for each `person:` node and `relatedNodes(matching:)` for topic
  words. The meeting node id format was read out of `Extractor.swift:752`, not guessed.
- **`.sameTopic` is one search pass** over the meeting's own title, narrowed to
  `[.transcript, .notes]` and to every other meeting's id, over-fetched ×4, then collapsed to one
  row per meeting keeping the best (lowest) BM25 score.
- **`Availability` is a separate answer from `hits`**, precisely so the panel can render *"off"*
  instead of an empty list, and `reasonUnavailable` is the one sentence for it.
- **Each filter returns its own answer to its own question** (newest first, most-shared-people
  first, strongest passage first, strongest connection first), with date and `matchCount` breaking
  ties. Documented on `hits`; the UI is free to re-sort.
- **No snippet and no percentage.** `meetingConsoleHistoryPreviewLines` is the `lineLimit` on
  `why`, not a preview of the meeting's notes — `MeetingStore.notes(for:)` is uncached and reads
  from disk, so a preview would put a file read per row inside `body` on the main actor.

### The wording tension, and how it was resolved

`reasonUnavailable` says "Turn it on in Settings, under Agent" because the banned word *index*
cannot be put in front of a person. But the app's own Search row is **dropped from the sidebar
while the index is off** — i.e. in exactly the state that sentence is written for, found by
reading `Sidebar.swift:108`. So each case now names something that is actually on screen: the
index case describes the switch, the graph case names the Graph screen. `MeetingRecall` was left
alone, so there is still exactly one answer to "why is this empty".

### Not proven

`.sameTopic` and `.related` were exercised end to end only over indexes and maps the self-test
wrote. Neither has run against this Mac's real index or its real map.

### Gate

`--selftest-meeting-recall` → `MEETING_RECALL_OK`. **This gate was wrong twice and had to be
rewritten** — see `02-VERIFICATION.md` §3.

---

## MC-05 — Ask: the assistant, through the manifest

**Depends on:** MC-01  **New data layer:** none, and no service, and no prompt prefix

### Why

There was no way to ask a question mid-meeting. There was also a tempting wrong answer, which is
why this section is a paragraph rather than a service.

### What was built

`UI/Meetings/MeetingConsoleAskSection.swift` (489 lines). Suggestion card (four generic
questions, tapping one fills the composer rather than sending it blind), the thread, a turn-in-
flight row with real step titles, the composer with a leading scope `Menu`, and four honest states
plus the permanent "Next Notes is AI and can make mistakes." footer.

### Design decisions

- **The question goes out as typed, with `source: .meeting`.** The agent already has the seven
  `.meeting` tools. A prefix would be recorded verbatim into the permanent conversation and repeat
  there forever, and it would be the second path around `AgentCapabilityManifest` that AGENTS.md
  forbids. If you want more in the turn, add a tool.
- **Two scopes, and the menu states the scope rather than narrowing anything.** "This meeting" and
  "Everything else I know" (offered only when the agent is on and signed in; a stored wide choice
  falls back). The manifest is built from app state with no per-request narrowing seam, and adding
  one would be the forbidden second path — so the copy does not claim the narrow scope *prevents*
  anything.
- **The thread filter is not `source == "meeting"`.** `recordAssistant` is called with
  `source: currentTurnSource == .voice ? .voice : nil`, so **answers to meeting questions carry no
  source at all**; the literal filter would have shown every question and not one reply. A
  question now carries the rows after it up to the next question of any kind, which drops an
  answer a spoken turn overtook rather than mis-filing it. Capped at 8 rows with a count of the
  rest and a link to the whole conversation.
- **The still portrait, not the animated one.** The sheet's orb is the animating shape here; a
  `List` row and a compact panel draw `NotionAvatarView` on purpose, and two live avatars on one
  screen is one too many.
- **No auto-scroll.** A `ScrollViewReader` cannot reach the container's `ScrollView` from inside
  a section body, and a nested one would be a second scroll area in a 520pt sheet. The mitigation
  is that the progress row carries real step titles rather than a spinner.
- **Stop does not replace Send.** `AgentView.composer` shows both while a turn runs, and the
  contract requires a second question to interrupt rather than be refused, so `AgentView`'s
  composition was kept.

### Not proven

Never run against a real meeting. The thread grouping above is reasoned from the two `recordX`
call sites and verified by reading them, not observed.

### Gate

No new self-test — the section has no logic of its own. `--selftest-meeting-console` covers the
activity table and the literal scan.
