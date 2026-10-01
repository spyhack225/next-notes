# Real typed answer presentation — 2026-10-01

## Confirmed cause

The production planner already sends its cumulative real answer through AgentToolSpeechTracker.receive. That producer returned at its allowSpeech guard for typed turns before exposing any usable snapshot to the conversation. AgentView therefore received only the saved assistant message at finish. The responsible producer callback now exposes the existing filtered snapshot through the observable RealtimeAgent, before the speech-only guard. No extra actor hop, model pass, timer, typing replay or history write was added.

The typed-only presentation is generation bound and ephemeral. Actual Stop/interrupt/new-turn/finalization clears it. A final assistant commit takes the existing presented message ID and timestamp, so the real pane mapping replaces one answer row rather than duplicating or moving it. Partial rows never enter saved history, model context or usage. Raw tool markers stay withheld and a prose-to-tool response clears presentation through the existing tracker cancellation. Voice and worker speech routing remain unchanged.

## Original red / producer green

Extracted the exact original HEAD receive method and the exact current receive method into tiny Swift probes with unrelated presentation/audio shells. Both were executed serially with speech disabled, a real cumulative text snapshot and no model completion:

- Original: exit 1, UX02_PRODUCER_FAILED: typed real snapshot was withheld by the speech-only guard.
- Current: exit 0, UX02_PRODUCER_OK: actual receive method publishes typed snapshots; raw tags withheld.

These confirm the producer defect and its repair. They do not exercise the actual model entry, session commit, native view rendering or latency. The scripts are /tmp/nextnotes-ux02-original-producer.swift and /tmp/nextnotes-ux02-current-producer.swift; source can be reconstructed from the recorded HEAD/current method.

## Consumer and original-flow gate

AgentPresentationSelfTest is prepared for --selftest-agent-presentation. Its suspended fixture provider drives the actual RealtimeAgent.handle(_:source:.text), planner and shared AgentView.presentedMessages mapping, inspecting the first chunk while the model is still pending. It checks the request already exists, partials are absent from saved history, later chunks keep identity, final commit keeps one ID/date, Stop removes the row, late actual stream chunks cannot republish, raw scaffolding is hidden, and the owner-store guard is unchanged. Registration and compiled execution are pending the coordinated build. No actual-flow pass is claimed.

Conversation scrolling retains the reader’s intent and shows Latest update for scrollback. Stream changes do not replay a scrolling animation. Explicit user jumps respect Reduce Motion. Only one work card animates alongside the foreground thinking mark; other task portraits use the existing still frame. Final results use the task’s own truthful failure producer and remain visible through the existing task ledger.

## Remaining release evidence

Packaged build, actual AGENT_PRESENTATION verdict, related Agent/permission/voice gates, selection/scroll/keyboard/VoiceOver observation, and input-to-visible-answer/main-actor measurements remain open. New typed-turn ownership and island authority belong to P3-11/P3-09; this source change does not complete those contracts.
