# Website to Mac experience — implementation plan

Read [00-README.md](00-README.md) first. Work top to bottom within a phase. IDs here are presentation tasks; a task that needs new agent behavior waits for the named owning roadmap. Each task ends with a reviewable screen/recording and a specific gate. Do not call a task done because its SwiftUI view compiles.

## Phase 0 — capture the current experience and make one visual contract

### UX-00 — baseline the four journeys

**Do:** Record the fixed-light app at the minimum main-window size and one larger size, including launch from each requested OS appearance. The OS-dark case verifies that the app stays light; it is not a second app theme. Walk (a) typed answer, (b) read → action → approval → result, (c) before/during/after a meeting, (d) dictation hold → insertion. Note which transitions are immediate, blank, duplicated, or detached from actual work. Include the island on a notched display and its floating form on another display if available. Use a non-sensitive fixture or sanitised test account for captures.

**Read:** `UI/MainWindow.swift`, `UI/Sidebar.swift`, `UI/Agent/AgentView.swift`, `UI/Agent/AgentWorkingCard.swift`, `UI/Agent/ToolReviewCard.swift`, `UI/Island/*`, `UI/Meetings/*`, `UI/Dictation/*`, `UI/Onboarding/*`; website `Hero.tsx`, `WhatItDoes.tsx`, `HowItWorks.tsx`, `index.css`.

**Output:** A compact evidence sheet: screenshots or a short capture at each moment; a table of current versus desired behavior; a list of already-present components; measured first visible feedback and main-actor stalls. Mark visual areas that cannot be observed on this machine as unverified.

**Gate:** The baseline names actual event sources and known gaps. It does not infer a missing stream or missing approval from a screenshot alone. Keep the report under `Tests/Reports/website-to-mac/`.

### UX-01 — freeze the shared visual and motion vocabulary

**Do:** Compare the website against `DS` and write a one-page map of hierarchy, spacing, materials, orb/avatar states, and motion. Add only tokens needed by a concrete task below. Decide which states use an ambient orb, a live mark, or no animation. Keep the native interaction shell and existing orb state meanings. The 2026-10-01 owner decision supersedes the original system-type and adaptive-color plan: use the shared fixed-light site palette and bundled site typography.

**Files when implementing:** `UI/DesignSystem.swift` only for justified tokens; existing components in `UI/Components/` for shared rendering. No new theme layer.

**Gate:** One live mark per screen, red only for recording, no literal view values, Reduce Motion freezes the expensive canvases, Reduce Transparency remains readable. `--selftest-orb`, `--selftest-avatar`, `--selftest-ui-strings`, `--selftest-settings` stay green.

### UX-11 — fixed site-theme foundation (owner decision 2026-10-01)

**Do:** Build the one theme every later task paints on, and paint nothing themed before it lands. Fixed light appearance app-wide (forced `NSAppearance`, never inherited): black ink on white surfaces, serif display family for headlines, sans for body, site glow treatments (orb backdrops, dotted fields, glass panes, beams) as `DS` tokens. Main window, island, HUD, onboarding and Settings all read the same tokens. Dark mode and user accent stop applying in-app; Reduce Transparency falls back to solid theme surfaces. Nothing here changes what any turn, meeting or dictation does — it is purely the surface later slices wear.

**Read:** `site/DESIGN-SYSTEM.md` first — it is the normative spec (palette, type,
layout, glass, orb, beam/voice, motion, component pointers). Then `site/src/index.css`
(the `@theme` scale, tracking/leading tokens), `site/src/sections/` (how each treatment
is actually used), `UI/DesignSystem.swift`, `UI/Components/` (existing `OrbBackdrop`,
`DottedField`, `GlassSurface`). Every spec value lands in `DesignSystem.swift` as a token;
views hold no literals. If the site's code contradicts the spec, follow the spec and report
the mismatch to the coordinator.

**Files when implementing:** `UI/DesignSystem.swift` for all theme tokens; narrow appearance-forcing and family-wiring edits only. Later tasks consume these tokens and do not restyle them.

**Gate:** Every existing self-test flag in the UX-01 gate list stays green; `--settings-sheet` renders all panes in the fixed theme with no clipped primary action and readable contrast; Reduce Motion still freezes canvases; no view holds a literal color, font name or gradient. A second theme layer, a per-surface restyle, or any behavior change fails the task.

## Phase 1 — make a real Agent turn feel alive

### UX-02 — received, working, answering

**Do:** Show a typed request as accepted immediately in the conversation. Keep the composer stable and ready for another thought. Map the existing `RealtimeAgent`/`AgentActivityStore` activity to short user-facing verbs. Audit the real text stream: if the UI can receive partial answer text, render those chunks in one stable answer row; if it cannot, show honest progress and the committed answer immediately when ready, then coordinate with the stream owner rather than writing a second buffer. Preserve text selection, Copy, and scroll position. When the person has scrolled up, do not yank them to the bottom for each chunk; offer a “Latest answer” affordance instead.

**Likely files:** `UI/Agent/AgentView.swift`, existing `AgentSession`/activity observers only if an existing event is not exposed, `UI/Components/MarkdownView.swift` for rendered answers. Coordinate with AGENT-OVERHAUL P3-11 before changing send/interrupt behavior.

**Interaction gate:** In a fixture turn, request row appears before any model/tool result; one visible work state persists through a long operation; real partials never duplicate or reorder; Stop works; a second typed turn follows P3-11's ownership once it lands. An answer that never streamed does not animate as though it did. VoiceOver announces new answer content without reading every token.

### UX-03 — the approval beat

**Do:** Present the existing `ToolReviewCard` inline as the focused decision, with plain title, destination, exact content/change, provenance, missing fields, and Approve/Edit/Cancel. Animate its entrance once, without relocating the buttons while hovered or focused. After a click, acknowledge the choice immediately and let the same job continue. An expired, denied, or missing-field review stays truthful. The island and conversation must refer to the same pending request; neither may offer a second approval.

**Likely files:** `UI/Agent/ToolReviewCard.swift`, `UI/Agent/AgentView.swift`, `UI/Agent/AgentWorkingCard.swift`, `UI/Island/IslandView.swift`. Reuse `PermissionGate` and `ToolCallReviewStore`; P3-08 owns spoken approval, P3-09 owns island state ownership.

**Gate:** Existing `--selftest-tool-review`, `--selftest-acp-confirm`, `--selftest-island` and one manual keyboard/VoiceOver pass. A blank recipient, invented destination, or unresolved field cannot become enabled through animation. Approval remains one gate at the irreversible boundary; reads remain immediate.

### UX-04 — a durable finish, not a disappearing card

**Do:** Keep the most recent completed task's result and open/copy/follow-up actions visible in the conversation. `AgentWorkingCard.terminalCard` exists, but `AgentView` currently switches completed tasks to the plain `taskRow`; make the result reachable without duplicating it in a second ledger. Before exposing Retry from a failure, replace the terminal card's hard-coded `.modify` retry risk with the actual tool/action risk. Show a concise “what happened” line and a specific recovery step on failure or interruption. The live avatar stops when the job is done.

**Likely files:** `UI/Agent/AgentView.swift`, `UI/Agent/AgentWorkingCard.swift`, `UI/Agent/FailureCard.swift`.

**Gate:** Complete, fail, cancel, and deny fixture paths each end in a visible terminal state; links open the produced result; a send-risk retry cannot bypass review; `--selftest-agent-panes`, `--selftest-agent-answers`, and task/permission self-tests pass. The result survives navigating away and back through the existing task/session records.

## Phase 2 — carry continuity outside the conversation

### UX-05 — island and HUD as the same story in miniature

**Do:** The island reports the active real stage while the person is in another app: listening, working, needs approval, speaking, done. It should link/open the full review or result when the compressed card cannot show enough. The island must not steal focus during dictation or delay microphone/model/speaker overlap. Keep the existing notch expansion, floating-display treatment, avatar/orb division, and eight-second notice behavior; pending approval must stay discoverable after a notice expires. The dictation HUD remains fast at key-down and preserves its level indication.

**Likely files:** `UI/Island/IslandState.swift`, `UI/Island/IslandView.swift`, `UI/Island/IslandPanel.swift`, `UI/HUDView.swift`, `UI/HUDPanel.swift`. Coordinate P3-09 and AGENT-OVERHAUL latency work before changing state ownership or animation frequency.

**Gate:** `--selftest-island`, `--selftest-avatar`, `--selftest-dictation`, voice/full-duplex gates as applicable. Measure key-down → visible listening, work update → island text, and approval → acknowledgement against the UX-00 baseline; none may regress. Confirm the human can keep talking while the agent speaks and works. On a display without a notch, glass and semantic ink stay readable in the fixed-light appearance, including when the OS requests dark appearance.

### UX-06 — show cross-app work without a fake desktop movie

**Do:** Use `AgentWorkingCard`'s existing live screenshot/AX summary and steps to show where Next Notes is working. A changed real window or completed step can crossfade briefly; a screenshot never stores to disk for this UI. Show when the person has taken control and the run has yielded, with a clear “Carry on” action where the existing behavior offers it. The exact proposed write stays in `ToolReviewCard`; the live preview is context, not permission.

**Likely files:** `UI/Agent/AgentWorkingCard.swift`, `UI/Agent/ActivityView.swift`; reuse `Computer/HumanInputWatch` and current task/activity data. Do not build a new screenshot queue or click animation.

**Gate:** `--selftest-computer-yield`, `--selftest-computer-vision`, `--selftest-tool-review`, existing computer action gates, plus one unlocked-Mac manual run. With no screenshot grant, the summary is useful and no blank frame blocks progress. A user mouse/keyboard touch yields before the next agent event; a review remains available.

## Phase 3 — bring the same rhythm to meetings and dictation

### UX-07 — before/during/after a meeting

**Do:** Make the three states visually continuous: an upcoming meeting card says what Next Notes is ready to do and presents Record/Skip; the live view prioritizes recording state, two audio tracks, provisional versus committed transcript, and the meeting panel; the finished view surfaces decisions and the follow-up proposal with one review action. Keep a person reading notes in place while new text arrives; no auto-scroll once they intentionally scroll back. A prepared message is a draft until the existing approval gate sends it.

**Likely files:** `UI/Meetings/MeetingsView.swift`, `MeetingLiveView.swift`, `MeetingDetailView.swift`, `MeetingConsoleSheet.swift`, `MeetingActionsView.swift`; `UI/Island/*` only for existing meeting states. P4-04/P4-05 own new brief/wrap content. This task draws it only after those facts exist.

**Gate:** `--selftest-meeting-live`, `--selftest-meeting-console`, `--selftest-meeting-reconcile`, `--selftest-meeting-finals`, `--selftest-island`, then a real/sanitised meeting capture. Recording state is unmistakable without color alone; no second live orb in the meeting panel; a skipped meeting never appears as recorded; a follow-up cannot appear sent before approval.

### UX-08 — dictation as a fluent small interaction

**Do:** Carry the website's “say it and stay where you are” moment into the HUD and Dictation pane: key-down answers instantly, live level responds to actual capture, release shows transcribing/cleanup stages, and completion says whether text landed in the captured target. If insertion fails, show the recoverable text and one clear action. Keep the target captured at key-down and the existing two-mechanism focus return. The history list remains a native selectable list.

**Likely files:** `UI/HUDView.swift`, `UI/Dictation/DictationStatusBand.swift`, `UI/Dictation/DictationView.swift`, `UI/Dictation/TranscriptionRow.swift`; only touch `TextInjector` if UX-00 proves the result signal is missing.

**Gate:** `--selftest-dictation`, `--selftest-axreadback`, `--selftest-dictation-hygiene`, correction vectors if correction behavior changes. Measure key-down → listening against baseline; no new await/sleep/debounce in the capture path; switching apps after release still inserts into the key-down target; failed insertion leaves recoverable text.

## Phase 4 — first run, accessibility, and visual sign-off

### UX-09 — one real first success in onboarding

**Do:** Onboarding is the FIRST surface that wears the fixed theme: rework the welcome/all-set framing on UX-11 tokens with the website's outcome language and a still or low-cost ambient orb. Lead with a plain outcome and one action the installed app can perform on this Mac. If an optional demo is useful, label it as an example and give replay/skip; never let a simulated conversation masquerade as the owner's data or delay permissions. Keep the seven-screen model and existing progress persistence unless a measured problem requires a change.

**Reference review, 2026-10-01** (competitor onboarding captures; patterns only — never their
design, fields, or accounts): what the website sells that onboarding still lacks is (1) the
three-moment promise — welcome names permissions, never home/work/meeting; (2) proactive
first value grounded in the person's own data — after the calendar grant, show their real
next event and what Next Notes will do about it, computed on-device, nothing invented;
(3) the follow-through shape — one clearly labeled EXAMPLE approval card showing ask → approve →
done, since "nothing sends without you" is the site's core story and onboarding never shows
it; (4) the anti-account reassurance up front — "no account, stays on this Mac" on welcome,
the explicit contrast with login/phone/card gates. Name-and-face stays (it matches the
reference pattern and is already real). No fake meetings, attendees, or results anywhere.

**Wispr review, 2026-10-02** (four onboarding recordings watched end to end; 30 screens):
steal patterns, never pixels or cloud fields. (a) Benefit-before-ask everywhere: every grant
row earns its payoff preview beside it — reason, action, and what unlocks, on one screen.
(b) First-use intent routing: one screen asking what they want first (dictate a reply /
check today's plan / prepare a meeting), each landing in a real local first success —
same seven screens, different doors in. (c) Tutorial with real artifacts: practice
dictations land in real History; after first success, show where it went and name the
next step. (d) One honest celebration gated on the real receipt producer — never earlier.
(e) Journey labels from step zero: phases named on the dots (Meet → Permissions →
Practice → …), so position and remainder are always visible. (f) Background Brain: the
model fetch never blocks — Continue always works mid-download, resume owns restarts,
copy says "we'll keep fetching quietly." Explicitly NOT taken: accounts, OAuth,
deep-links, referral/pro upsells, cloud connectors, team or mobile prompts — the absence
is the story and welcome says so.

**Likely files:** `UI/Onboarding/OnboardingSteps.swift`, `OnboardingChrome.swift`, `OnboardingWindow.swift` only if its layout needs adjustment. Settings keeps its native `TabView` and grouped-form interactions while consuming the same fixed-light palette, typography and shared surface treatments as the rest of the app.

**Gate:** `--selftest-onboarding`, `--selftest-guided`, `--selftest-settings`, `--selftest-ui-strings`; inspect at supported window sizes. Resume after closing setup; no first-run step asks for a key or terminal command.

### UX-10 — accessibility and performance release pass

**Do:** Review all changed states with VoiceOver, keyboard-only navigation, focus restoration, larger text, high contrast, Reduce Motion, Reduce Transparency, the fixed light theme's contrast ratios, the 900×600 main-window floor, the Settings pane floor, and a larger display. (No dark-appearance pass: the theme is fixed light. Contrast is still gated — the theme must pass it.) Freeze/remove decorative clocks under Reduce Motion; preserve semantic state labels. Profile canvases and main-actor work during voice, dictation, and meetings. Add a deterministic visual fixture sheet only if existing `--avatar-sheet`, `--settings-sheet`, previews, and real captures cannot show the states that need review. A new screenshot fixture is a test surface, not a production state layer.

**Gate:** No clipped primary action, unreadable glass text, hidden keyboard focus, duplicate VoiceOver announcement, or scroll jump. Main-actor stall and voice latency meet AGENT-OVERHAUL Phase 2's measured gates; added motion does not regress UX-00 input-to-feedback or cause continuous drawing in off-screen/collapsed rows. Run relevant existing self-tests and `make build`; record the exact markers and the screenshots/captures in `Tests/Reports/website-to-mac/`. Known unrelated reds are reported, not relabeled green.

## Dependency order and release slices

1. **UX-00 → UX-01 → UX-11**: baseline, visual contract, then the theme foundation. No themed surface work before UX-11 is reviewable. (UX-00 observation may run alongside UX-11; nothing paints until UX-11 lands.)
2. **UX-09 on the new theme**: onboarding is the first surface that wears it. This is the first user-facing release slice.
3. **UX-02 → UX-03 → UX-04**: one complete Agent turn, on theme tokens. P3-11 and answer-stream ownership may require sequencing with AGENT-OVERHAUL; a working, honest non-streaming path may ship before partial-answer rendering.
4. **UX-05 + UX-06** after Agent state mapping is stable; edit shared island files serially with P3-09. The same work follows the person across the Mac.
5. **UX-07 + UX-08** use the established motion grammar on theme tokens. New proactive content waits for P4-04/P4-05.
6. **UX-10** closes the accessibility experience; UX-10 also runs after every earlier slice, with the final pass over the whole app.

## Planning size

| Slice | Focused implementation estimate | What can extend it |
|---|---:|---|
| Baseline and contract (UX-00–01) | 1–2 days | Access to a notched Mac, a second display, and sanitised journey captures |
| Theme foundation (UX-11) | 2–4 days | Forced-appearance edge cases (menus, sheets, file pickers that resist theming); packaged font identity and OFL notices |
| Onboarding on theme (UX-09) | 1–2 days | One real first success on this Mac |
| Real Agent turn (UX-02–04) | 4–7 days | Whether partial answer text is already observable in the pane; coordination with P3-11 |
| Across the Mac (UX-05–06) | 3–5 days | P3-09's island ownership change; unlocked computer-use verification |
| Meetings and dictation (UX-07–08) | 3–5 days | New proactive content from P4-04/P4-05 is a separate dependency |
| First run and final sign-off (UX-09–10) | 2–3 days | Manual accessibility review and any platform-specific fixes |

These are **planning estimates**, not calendar commitments: about 16–28 focused days for presentation work, excluding new agent capabilities and waits on their gates. The first usable slice is onboarding on the new theme (UX-11 → UX-09); it need not wait for the whole roadmap.

Do not make a later surface wait for a feature roadmap that only owns new content: existing meeting/dictation states can improve now. Do not declare the whole roadmap done while an unobserved flow, unsupported channel, or unresolved latency gate remains.
