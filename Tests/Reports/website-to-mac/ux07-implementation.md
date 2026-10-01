# UX-07 meeting presentation slice — implementation evidence

**2026-10-01. Status: implemented in source, visual and rebuilt-app gates open.** This consumes the existing scheduler, session, meeting store, and Agent review records. It adds no brief, wrap, task ledger, approval gate, or island ownership.

## Before / producer evidence

- The live pane previously called `proxy.scrollTo(last.id)` on every `session.segments.count` change, regardless of a reader's scroll position (`MeetingLiveView.swift` before this edit). A new final while reading an earlier line therefore instructed the list to jump to the bottom. The segment count is a producer event, not evidence of reader intent.
- `MeetingsView` excluded calendar-claimed meetings from Past while their event remained current, but every calendar row was `.selectionDisabled()`. A recording that had ended before its calendar event could not be reopened from either list section, even though `MeetingController.stop()` selected its saved id.
- The upcoming row offered an unexplained `Record` checkbox and `Record now`; it did not state whether automatic recording was on or off. Finished notes had an Actions tab, but no direct cue when real pending or performed actions existed.

## Changed producer and consumer

- `TranscriptView` now reports near-bottom geometry and scroll phase from its **actual List**, through optional live callbacks. Its existing search-focus jump remains intact. `MeetingLiveView` changes `followsLatest` only during reader scrolling, so content growth from a new final cannot silently flip the choice. It follows new finals only while at the bottom and offers `Latest line` when reading back. The scroll policy has six assertions added to the existing `--selftest-meeting-console` path, covering content growth, reader departure/return, and geometry at the bottom versus earlier in the transcript.
- `MeetingsView` lets a recorded calendar row select its saved meeting after the live session ends. Before recording, the row says whether Next Notes will record automatically, keeps `Record automatically` and `Record now`, and preserves the existing per-event override/skip methods. Once recording has begun, those pre-recording choices disappear; the row states recording, finishing, processing, done, or failure from `MeetingController`/`MeetingStatus`. It does not present a still `breathing` orb for an already recorded event.
- `MeetingDetailView` adds a plain link to the existing Actions tab when reconciled candidates/proposals, an active review pass, or actual action records are present. It uses the same `AgentService.reconciled(for:)` result as the Actions tab; a record counts as complete only when `AgentActionRecord.succeeded` is true, and a failed record is called out as needing attention. The keyed task recomputes reconciliation only when status, Agent revision/thinking, live candidate count, or recorded action count changes, rather than on every notes redraw. Approval and exact preview remain solely in the Actions tab's existing cards.

## Checks and remaining gates

- `swiftc -frontend -parse` passed for the edited meeting UI and local self-test files; `git diff --check` passed.
- A standalone SwiftUI typecheck passed for `onScrollGeometryChange`, `onScrollPhaseChange`, `ScrollViewReader`, and `Button(_:systemImage:action:)` on this macOS 26 SDK. Constructed `ScrollGeometry` values returned `visibleRect.maxY` of 1000 at bottom and 700 at an earlier position for a 1000-point content example.
- The rebuilt app self-tests have **not yet run** in this parallel checkout: `--selftest-meeting-console`, `--selftest-meeting-live`, `--selftest-meeting-reconcile`, `--selftest-meeting-finals`, and `--selftest-island` need the coordinated build. The self-test assertions were not observed red on the old binary or green on a rebuilt binary; do not mark the regression verified from source review alone.
- A sanitised real meeting capture remains required to confirm List phase callbacks on trackpad/scrollbar/keyboard, no scroll jump while selecting earlier text, the 900×600 layout, light/dark appearance, two audio tracks, Stop→saved transition, and approval→performed receipt. No live Mac app UI was running for this agent, and no permission or microphone was exercised. UX-00/UX-10 visual and timing gates remain open.
