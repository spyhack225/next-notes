# UX-01: website to Mac visual and motion contract

**2026-10-01.** Source-backed contract for implementation; visual sign-off remains open with UX-00. The three [baseline reports](ux00-agent.md), [meeting/dictation audit](ux00-meeting-dictation.md), and [island/HUD audit](ux00-island-visual.md) trace production event sources. They contain no live screenshots or first-visible-feedback measurements, so neither UX-00 nor the final UX-10 gate is complete.

| Moment | Primary visual signal | Motion and source of truth |
|---|---|---|
| Before work | Native title, one plain outcome, one next action; an empty state may use a still/ambient orb | Use system font, semantic colors, `DS.Space`, `SectionHeading`, and existing glass boundaries. No website serif, fixed black/white palette, gradient rim, or timed story in production. |
| User message accepted | Durable `AgentSession` row, composer still available | Row appears from the accepted turn. A short `DS.Motion.standard` transition may settle it without holding submission. Do not present a send receipt before `recordUser`. |
| Agent working | **One** live saved character plus a short public operation label | `RealtimeAgent` and `AgentActivityStore` own the label/state. Use existing avatar pose; no second animated orb or progress clock. Show actual step changes without restarting animation on every tick. |
| App work or dictation | **One** orb for app processing; red indicator and real meter for recording | `DictationController`, `MeetingSession`, and island state own these phases. Red remains exclusive to recording. Never delay capture or serialize audio/model/speaker for motion. |
| Answer | Real chunks only if a production stream is observable by the pane; otherwise a prompt committed row | No character-by-character replay of a completed answer. Preserve selection and reader scroll position. Motion is opacity or a small transform, never animated text layout. |
| Review | One bounded glass card with exact destination/content, blockers, and the one primary choice | `PermissionGate`/`ToolCallReviewStore` own state. Reveal once with `DS.Motion.reveal` or `.standard`; focus the review without moving action targets under a pointer. Reads do not acquire a new approval. |
| Completed, failed, denied | Durable result or specific recovery in the conversation/Activity | `AgentTaskManager` and actual effect receipts own the outcome. Stop perpetual animation. Never infer success from elapsed time or from approval alone. |

## Native and accessible rules

- Keep `NavigationSplitView`, toolbars, selectable native lists, grouped Settings, system typography, semantic light/dark colors, and the user's accent. Use `GlassCard`/`.glassSurface` to separate a request, decision, or result; keep forms and lists native. Existing `DS` tokens cover the current tasks. Add no token without a concrete view and observed need.
- Agent work uses the one saved character and one history, whether the example is home helper, office associate, or meeting partner. App work uses the orb. A still badge may label a second card; two active canvases must not compete.
- A status word and shape/icon carry meaning without color. Reduce Motion freezes decorative clocks and removes nonessential movement; Reduce Transparency keeps every decision readable. VoiceOver announces phase changes once, not every model token or meter update. Keyboard focus stays on the one actionable review when it appears and returns sensibly afterward.
- The website's automatic loop is an optional labelled example in help/onboarding only. Real Agent, island, meeting, and HUD states follow producers. No fake cursor, synthetic typing, second task ledger, screenshot queue, or approval gate.

## Implementation and evidence boundary

Implement source-grounded, independently testable UI slices under this contract while UX-00 remains open for sanitized light/dark captures, 900×600 and larger windows, notch/floating display, and first-visible-feedback timing. Each implementation task remains **in progress** until its own production-path gate and visual evidence are recorded. The Agent overhaul owns P3-11 typed-turn meaning, P3-09 island state authority, and P4-04/P4-05 new meeting facts. The UI consumes those states when they exist.
