# Website to Mac implementation checkpoint — 2026-10-01

**Earlier checkpoint.** The finalization pass below supersedes the source-state gaps, but not the limitations of the recorded earlier binary verdicts.

The roadmap folder is now `roadmap/in-progress/WEBSITE-TO-MAC-EXPERIENCE/`. Three parallel workers implemented bounded Agent, meeting, dictation, island and HUD presentation slices. No task is declared complete without its visual, accessibility and latency gates.

## Implemented source

- Agent: preserve reader scroll with Latest update; expose the latest terminal task card and earlier results; focus the existing review; resolve retry risk from the registered tool and suppress unknown/send retry.
- Meeting: observe reader intent on the actual transcript List; offer Latest line; make saved calendar meetings selectable; describe automatic recording; link notes to actual follow-up records.
- Dictation/HUD: reflect real capture during startup; keep finishing and error messages visible; offer history recovery guidance; disable the ineffective Stop action during finishing.
- Island: keep pending approval still; respect Reduce Motion in expansion; use the existing Reduce Transparency fallback.
- Cross-app card: display task-scoped public step titles. Observable, task-scoped screenshot and yield producers remain required before restoring a verified live preview/Carry on flow.

## Verification already observed

`make build` passed in 265.55 seconds. The rebuilt bare binary reported `AGENT_PANES_OK`, `TOOL_REVIEW_OK`, `AGENT_ANSWERS_OK: 3/3 answered by Gemma 4 E4B`, `ISLAND_OK`, `ORB_OK`, `ONBOARDING_OK`, `UI_STRINGS_OK`, `DICTATION_HYGIENE_OK`, `MEETING_CONSOLE_OK`, `MEETING_LIVE_OK`, and `MEETING_RECONCILE_OK`. These verdicts apply to that build, not later changes by other workstreams. `git diff --check` passed for this UI slice.

`AVATAR_FAILED` was rerun with full output: its sole failure is unavailable vendored avatar parts when launched from the bare build binary. A packaged-app run is required; all other avatar checks passed. `MEETING_FINALS_ABSENT` reported missing fixture location because `NEXTNOTES_FIXTURES` was unset; the fixtures exist under `Tests/Fixtures/meetings` and must be supplied to the next run. Neither result counts as a pass.

The interrupted onboarding edit did not apply: OnboardingSteps.swift is intact and unchanged. Source inspection found that its practice success badge currently follows any nonempty field edit, including manually typed text; UX-09 must not infer dictation delivery from this alone.

## Next work

1. Package the current app and rerun resource-dependent verification with explicit fixtures; reconcile the existing UI failure builder with the now-correct AgentTask failure producer from the durability workstream.
2. Implement truthful production events for real answer chunks, inserted/copied dictation completion, and task-scoped cross-app capture/yield, coordinating runtime ownership with AGENT-OVERHAUL.
3. Finish onboarding outcome framing and verify one real dictation success.
4. Capture sanitized light/dark journeys at minimum and larger sizes; check keyboard, VoiceOver, Reduce Motion/Transparency and first-visible-feedback/voice latency. These remain unverified.

## Finalization source checkpoint

Three additional parallel workers prepared task/step-owned capture and yield, genuine onboarding success attribution, and visual/accessibility fixtures. Root integrated the exact Executor TaskLocal attribution, generation-bound typed answer snapshots, stable partial-to-committed row identity, task-producer-owned failure wording, and one primary animated work mark in the conversation. Reduce Motion now branches at recording, dictation, meeting, conversation-scroll and onboarding presentation sites. These sources are frozen for the coordinated serial compiler; no current-build functional verdict is claimed yet.

The new AgentPresentationSelfTest uses the actual typed handle and planner stream with a suspended fixture provider, then checks the real pane mapping before completion, one stable committed row, Stop/late chunk rejection, hidden tool scaffolding and owner-store isolation. Registration and compiled execution are pending the shared NextNotesApp owner. ExperienceSheet captures actual production leaf components at detail-floor/larger widths, light/dark and reduced settings; its 72 expected images do not constitute four real journeys, a full shell capture, VoiceOver or performance evidence.

Direct CUA inspection of the Mac app failed with ScreenCaptureKit SCStreamError −3811. No real screenshot or manual accessibility pass was obtained. The user has been asked whether the Mac is unlocked and available while isolated work continues.

Confirmed additional source risks: CDP can repeat an acknowledged but unverified click and bypass human-yield checks; the assigned worker is reproducing those through the actual client before repairing them. A standalone pending approval card can overflow the 600pt shell when expanded while inside the composer safeAreaInset; its relocation into the native scrolling thread is proposed to the owner of pending-card restoration. Actual dictation completion attribution and first-success hookup remain pending the pipeline-owner handoff.

Do not close UX00–UX10 against this source checkpoint. Required original regressions, integrated named flags, current visual review, actual insertion/capture/yield/duplex and measured latency remain listed in STATUS.
