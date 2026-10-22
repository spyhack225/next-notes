# Website to Mac experience — start here

**Planned 2026-09-30.** This is a UI and interaction roadmap, not a new agent architecture. [01-IMPLEMENTATION.md](01-IMPLEMENTATION.md) has the ordered tasks and acceptance checks; [STATUS.md](STATUS.md) is the only progress ledger. Nothing in this folder marks an app feature as shipped.

## 1. Outcome

Bring the **whole look and feeling** of the current website into the Mac app: fixed light
theme, serif display type, orb backdrops, dotted fields, glass panes and beams — calm,
personal, alive, and clear about what Next Notes is doing. A person should see their request
land, see real work progress, know when their choice is needed, and see what happened after
they chose. The app should help them stay in their life and work rather than make them
supervise a machine.

**Owner decision, 2026-10-01:** full site theme on every surface, not just the website's
vocabulary pieces. The implementation order is theme foundation first, then onboarding
(the first surface that wears it), then the Agent turn, island, meetings and dictation.
The last phase checks the whole journey in small windows, keyboard and VoiceOver use, and
Reduce Motion/Transparency. (There is no dark-appearance pass: the theme is fixed light.)

**Owner decision 2026-10-04: positioning and low-end floor.** See
[POSITIONING-AND-LOCAL-MODEL](../POSITIONING-AND-LOCAL-MODEL/00-README.md). Copy, empty
states, starter questions and onboarding speak to four people: a parent running a household
(school calendar, budgeting, groceries), an office manager (onboarding, team email and
calendar, summarize-and-follow-up), a legal-practice operations manager (case files,
deadlines, file sharing) and a filmmaker/editor (footage by shoot date, session and drive).
Examples are offered only for capabilities that actually work. Onboarding shows no model
choice, download picker, account key or terminal step; model setup is one plain progress
state. Agent-initiated suggestions get a calm, clearly dismissible presentation; their
content stays owned by AGENT-OVERHAUL Phase 4. The theme decision above is unchanged, and
the UX latency checks should also be read on the 16 GB MacBook Air floor.

## 2. Reference and present baseline

| Website reference | What to carry into the app | Existing app seam / present gap |
|---|---|---|
| [`Hero.tsx`](../../../site/src/sections/Hero.tsx): a request is typed, sent, worked on, answered, reviewed, approved, and completed | A readable **real** turn with distinct states and one clear next action | `AgentView` has messages, `thinkingRow`, a fixed composer, `AgentWorkingCard`, and `ToolReviewCard`. Its message row currently shows committed text; audit whether live answer text reaches the pane before adding UI plumbing. |
| [`WhatItDoes.tsx`](../../../site/src/sections/WhatItDoes.tsx): home, work, Mac apps, meeting moments | Outcome-led empty states and entry points, tied to capabilities actually available | The Agent starter questions are generic; section panes already exist. Do not create a second place for tasks or proposals. |
| [`HowItWorks.tsx`](../../../site/src/sections/HowItWorks.tsx): before, during, after, review | Meeting state continuity, with the promise and the follow-up visible | `MeetingsView`, `MeetingLiveView`, `MeetingDetailView`, and `MeetingConsoleSheet` already own these states. Proactive briefs and wrap behavior belong to AGENT-OVERHAUL P4-04/P4-05. |
| [`index.css`](../../../site/src/index.css): restrained ink, generous spacing, dotted orb, translucent pane | Hierarchy, breathing room, one meaningful motion signal | `DesignSystem.swift`, `ThinkingOrb`, `OrbBackdrop`, `DottedField`, `GlassSurface`, `LabeledOrb`, `SectionHeading` already port the vocabulary. |
| The hero's automatic loop | An **optional** guided preview in onboarding/help, driven by fixtures | Production conversation and task UI must follow actual state; no automatic playback, synthetic typing, or invented success. |

This baseline is from source inspection, **not** a visual sign-off of every app screen.
`AGENTS.md` §Design system carries the 2026-10-01 owner decision for the full site theme;
the native-shell sentences there apply only where the theme does not reach. The website's
serif, fixed black-and-white theme, and glow treatments **are** literal port targets under
UX-11. The app already has its own avatar for the agent; the orb describes app work.
Preserve that distinction.

## 3. Product experience contract

### A turn has seven observable moments

| Moment | What the person sees | Source of truth |
|---|---|---|
| 1. Composing | Their own words in the composer; speech shows live capture where that surface already supports it | Draft / capture state |
| 2. Received | Their message appears at once; the composer stays available for the next thought | `AgentSession` / accepted turn |
| 3. Working | A short verb tied to a real operation, with a live avatar or orb in **one** place | `RealtimeAgent`, `AgentActivityStore`, `TaskBridge` when it lands |
| 4. Responding | Real answer text appears as it becomes usable; no decorative per-character replay of a completed answer | Existing model/voice stream; otherwise committed message |
| 5. Needs you | The exact proposed action, destination, content, and blocker are visible; focus moves to the review | `PermissionGate` / `ToolCallReviewStore` |
| 6. Your choice | Approve, edit, or dismiss produces immediate acknowledgement. The action only runs after the existing gate says yes | The same gate, never a second approval state |
| 7. Finished | Result, link/open action, and any follow-up remain findable in the conversation or Activity | `AgentTaskManager` / task result / audit |

Not every turn has all seven moments. A question can answer without tools or approval. A denied or failed action ends with a specific result and recovery path. A longer job stays visible instead of ending in a still spinner. The UI never infers completion from elapsed time, never invents a confirmation, and never turns a read into a permission ceremony.

### Motion grammar

| Event | Treatment | Rule |
|---|---|---|
| Message accepted | New row settles into the thread with a short opacity/position transition | Show it in the same turn that accepts the request; animation cannot delay the request. |
| Work begins or changes step | The one live avatar/orb changes state and the label updates in place | Derive from typed activity/risk, not English progress text. Do not restart a clock for every status tick. |
| Partial answer arrives | Add text in chunks as the real stream provides them; keep selection and scroll position stable | Do not fabricate a typing speed or wait for a sentence solely to make it look animated. |
| Review appears | Card reveals once and takes accessible focus; surrounding content remains readable | No slide that hides the action or moves an Approve button under the pointer. |
| Choice accepted | Button reflects the click immediately; progress resumes from the existing job | An irreversible action still waits on the gate. No second confirmation. |
| Work completes | Working state settles into a durable result with a brief one-time acknowledgement | Stop all perpetual motion for that job. |

Use `DS.Motion.standard`, `.emphasis`, `.fluid`, `.reveal`, and existing island/ambient tokens before adding one. A new timing value needs a visible reason and goes in `DesignSystem.swift`. Prefer opacity and small transforms over animating text layout. No fixed sleeps, debounces, or waits on the user's turn. The website's auto-cycling demo is a storytelling device, not an app behavior.

## 4. Visual translation rules

UX-11 owns the theme foundation and nothing paints the fixed theme before it lands.
After UX-11, these are the rules:

1. **Fixed light theme everywhere.** Black ink on white, app-wide, set by the app rather
   than inherited from the Mac. Dark mode and the user's accent colour do not apply
   in-app. Every surface — main window, island, HUD, onboarding, Settings — wears it.
2. **Serif display type for headlines.** The site's serif italic accent for the words that
   matter; body text stays a highly legible sans. Never a raw font name in a view: the
   families live in `DS` tokens owned by UX-11.
3. **Glow treatments from the site.** Orb backdrops, dotted fields, glass panes and beams
   on every surface, following the site's own usage (backdrop behind type, one live mark
   per screen, still orbs for empty states). "No gradients on chrome" no longer holds
   where the theme puts glow on chrome.
4. **One primary live mark per screen.** The agent avatar says what the agent is doing. The orb says what the app is doing: listening, weaving meeting tracks, transcribing, composing notes, searching, connecting, or loading. Existing `AGENTS.md` vocabulary is authoritative. A still orb may label another card; several animated canvases may not compete.
5. **Glass is a surface, not decoration.** Use `GlassCard`/`.glassSurface` for a request, review, or result that needs a boundary. Reduce Transparency falls back to solid theme surfaces, never to the system material that would break the fixed look.
6. **No semantic color drift.** Red means recording. A status word carries the meaning with its icon/shape; color only reinforces it.
7. **One foreground action.** If a review is waiting, the review action is visually primary. The next useful action is close to the result. Stop/cancel remains stable and reachable during work.
8. **Words are personal and literal.** “Checking your calendar,” “Ready for your review,” “Added to Notes,” or “I couldn’t reach Notes” describe facts. Do not expose tool ids, schema names, model internals, or vague “magic” claims.

## 5. Boundaries and dependencies

- This roadmap owns presentation and interaction **on existing states**. Agent execution, full duplex, task durability, proactive scheduling, and tool authority remain with [AGENT-OVERHAUL](../AGENT-OVERHAUL/00-README.md). In particular P3-11 owns what a typed message during a running turn means; P3-09 owns island state ownership; P4-04/P4-05 own new proactive meeting content. UI work may integrate those results but must not pre-implement them with a parallel store or timer.
- `AgentView`, `IslandView`, `DesignSystem.swift`, `NextNotesApp`, and acceptance registration overlap active work. Check [BUILD-ORDER](../../BUILD-ORDER.md) and current STATUS ledgers before each implementation task. Keep shared-file edits narrow and serial. `DesignSystem.swift` theme tokens belong to UX-11; later tasks consume them and do not restyle them.
- The iMessage command channel is [in progress](../NextNotes-iMessage/STATUS.md); placing phone calls is [planned](../../backlog/Phone-Calls/STATUS.md). Design a status presentation for these channels when they become real, but do not show them as usable entry points or success states before their own gates pass.
- The Mac app may inspect and act in other apps. The person retains control: show what the agent is doing, yield when they take the Mac, and use the existing review gate for consequential changes. Never put a fake cursor or simulated click over a real app window.
- The single task ledger, audio output scheduler, tool manifest, and usage log remain single. This roadmap adds no second state machine for work, no parallel audit log, and no extra permission gate.

## 6. Release bar

The roadmap is complete when a person can start a turn from the Mac app, watch an honest path through work and an approval if required, see the result, and find it later; the island tells the same story while they are in another app; meeting and dictation states remain legible; every surface wears the site theme; and all paths meet the accessibility and latency gates in the implementation plan. Screenshots alone do not prove the interaction. The app must be as truthful and as fast as the website is theatrical.
