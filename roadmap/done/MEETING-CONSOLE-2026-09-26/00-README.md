# MEETING-CONSOLE-2026-09-26 — start here

A **completed** record of the panel that opens over a meeting that is still running. It was built
on 2026-09-26 against `58d0b8c` ("P1-05: three constrained-decoding backends"), in seven parallel
subagents over two phases, and is in the app. Read this file for what it is and what it is not,
`01-PANEL.md` for the five pieces and why each is shaped the way it is, and `02-VERIFICATION.md`
for every gate that was run and the two defects that running them found.

`STATUS.md` is the progress record and is the only place a status may be written down.

---

## 1. What this is

A sheet on the live meeting view — ⌘⇧M, or the **Meeting panel** button beside Stop — carrying a
rail of four sections over one column of content, with one floating primary action over the top
of the content and one status row reporting what is running.

| Section | The question it answers | New data layer? |
|---|---|---|
| **Notes** | "What do I want to remember?" | **yes** — `MeetingScratchpad`, `MeetingScratchpadTidier` |
| **Actions** | "What did the app hear me agree to?" | no — `AgentService` already owned all of it |
| **History** | "What did we already decide about this?" | **yes** — `MeetingRecall` |
| **Ask** | "What did they just mean?" | no — the agent already had the tools |

**Three of the four had no new data layer, and that is the design, not an accident.** Only two of
the four capabilities needed something that did not exist. Everything else is a second window onto
a seam the app already had, which is the whole argument in AGENTS.md's "Do not architect ahead of
a need" and the reason this was a week of surface rather than a month of plumbing.

## 2. What the references were, and what was refused

Four sources, read before any code:

| Source | What it contributed |
|---|---|
| A macOS meeting window: large title, meta chips (a date, a headcount, a folder-plus), a body of hand-typed note lines, a floating bottom capsule reading **Generate notes** | the hand-written capture surface, the generous leading, and the single floating primary action over scrolling content |
| The same window after generation: bold-ish headings, `•` bullets, `–` sub-bullets, one term in an accent colour, the capsule reading **Enhancing notes** with a spinner | the structured output, and the accent as the only coloured emphasis |
| A dark chat panel with a suggestion card, a prose answer, a `+ / model / voice` composer | the suggestion card, the composer shape, the scope switch |
| A chat-history dropdown: a first action, a hairline divider, a list, the selected row on an accent-tinted rounded rectangle, "More chats ›", a second divider, two rows with `›` | the filter control's exact shape — a `Menu`, not a segmented picker |

**Deliberately not ported**, because this app is a native macOS app and its own design system
says so:

- **The serif.** `DS.Font` has no serif anywhere — system styles plus `.rounded` for counters and
  `.monospaced` for timestamps. The reference's serif title became `DS.Font.largeTitle`. The
  typographic hierarchy (a large title, generous body leading, one accented term) survived; the
  typeface did not.
- **The dark theme, the gradients, the rim light.** The app has no gradient on chrome. `.glassSurface`
  deliberately does not port one, because macOS 26 draws its own specular edge.
- **The gold highlight.** Became `DS.Color.accent`, on the `why` line of a recall row.

## 3. The five rules this feature lives by

These are the load-bearing decisions. Each is in AGENTS.md now, and each exists because the
obvious alternative is a regression.

1. **A hand-written note is the person's; `notes.md` is the model's.** Two files, because the
   model's pass overwrites `notes.md` and must never overwrite a line someone typed at minute
   twelve. `scratchpad.json` sits beside it in the meeting's own folder, written through
   `MeetingStore` — no second store, no second root — and reaches `notes.md` once, at the end,
   through a pure idempotent merge.
2. **A filter that cannot answer says so; it does not answer a different question.** `.related`
   refuses when the map is off. `samePeople` standing in for `related` would put a
   confidently-labelled row in front of somebody who asked about a project. Every hit carries a
   non-empty `why`. There is deliberately no similarity percentage and no matched snippet: neither
   is something the query can back up.
3. **No transcript dump prefixed onto the assistant's question.** The agent already owns
   `meeting.current`, `meeting.transcript`, `meeting.recent_context`, `meeting.decisions`,
   `meeting.action_items` and `meeting.search`, and `AgentUtteranceSource.meeting` is already a
   case. `RealtimeAgent` records the utterance verbatim, so a prefix would land in the permanent
   conversation and in every later turn's context — and it would be the second path around
   `AgentCapabilityManifest` that AGENTS.md forbids. If you want more in the turn, add a tool.
4. **One animating orb per screen, and it is the sheet's.** A section returns a
   `MeetingConsoleActivity` and the sheet draws the orb. The Notes pill's badge-size orb is
   `isAnimated: false` so two shapes cannot both be live for one job.
5. **The panel must not present under a self-test.** A sheet keeps `NSApp.terminate` from ever
   completing, so the run would print its result and hang and the watchdog would report a timeout
   for a run that had already finished. `MeetingConsolePolicy.shouldPresent` is the whole rule, and
   it gates the **button as well as the sheet** — a control with no panel behind it is the one
   state that gate exists to prevent, and the first version of the wiring got that wrong.

## 4. How to verify it

```bash
make install OPEN=0
Scripts/run-selftest.sh --selftest-meeting-console     # MEETING_CONSOLE_OK
Scripts/run-selftest.sh --selftest-meeting-scratchpad  # MEETING_SCRATCHPAD_OK
Scripts/run-selftest.sh --selftest-meeting-tidier      # MEETING_TIDIER_OK
Scripts/run-selftest.sh --selftest-meeting-recall      # MEETING_RECALL_OK
Scripts/run-selftest.sh --selftest-ui-strings          # UI_STRINGS_OK
```

All four are in the **INTEGRATION** tier of `make acceptance`. Full evidence, including the
mutation checks that prove each gate goes red when its subject breaks, is in `02-VERIFICATION.md`.

## 5. What is not proven

**This panel has never been seen by an eye.** There is no grant-free way to render a sheet in
this app — `--settings-sheet` uses `cacheDisplay`, which needs a hosted window. Every visual
claim in this folder is argued from design tokens and source, not observed. Open a meeting and
press ⌘⇧M; that is the first real check and it has not happened.

Two smaller unknowns, both in `01-PANEL.md` under each section's **Not proven**:

- The **Tidier's** prompt and parse are pinned by a self-test that needs no model, so the shape
  of its output is proven; the prose a real model writes into it is not.
- The **Ask section's** thread filter had to account for `recordAssistant` being called with
  `source: nil` for non-voice turns, so answers to meeting questions carry no source at all. The
  filter works around that by grouping; it has not been seen against a real meeting.

## 6. Files

| File | Lines | What it is |
|---|---|---|
| `UI/Meetings/MeetingConsoleSheet.swift` | 293 | the panel, the rail, the activity table, the policy |
| `UI/Meetings/MeetingConsoleNotesSection.swift` | 414 | MC-02 |
| `UI/Meetings/MeetingConsoleActionsSection.swift` | 664 | MC-03 |
| `UI/Meetings/MeetingConsoleHistorySection.swift` | 414 | MC-04 |
| `UI/Meetings/MeetingConsoleAskSection.swift` | 489 | MC-05 |
| `Meetings/MeetingScratchpad.swift` | 157 | `MeetingScratchNote`, `ScratchNotesMerger` |
| `Meetings/MeetingScratchpadTidier.swift` | 507 | your lines → a tidied document, mid-meeting |
| `Knowledge/MeetingRecall.swift` | 495 | which earlier meetings, and why |
| 4 × `*SelfTest.swift` | 1431 | the four gates |
| modified | +315 | `MeetingStore`, `NotesService`, `DesignSystem`, `MeetingLiveView`, `NextNotesApp`, `Scripts/acceptance.sh`, `README.md`, `AGENTS.md` |

Paths are relative to `Sources/NextNotes/` unless they name a repo-root folder. Line numbers were
read on 2026-09-26 against the working tree; the tree moves, so grep the quoted symbol if an
anchor has drifted.
