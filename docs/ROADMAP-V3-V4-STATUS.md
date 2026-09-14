# Next Notes v3/v4 implementation status

Updated 2026-09-13. This is an acceptance ledger for the local planning files
`roadmap/Next_Notes_v3_Roadmap.md` and `roadmap/Next_Notes_v4_Roadmap.md`. A compiled
feature and a passing synthetic self-test establish code behavior, not the
roadmaps' real-device latency or account integration targets. Keep those
acceptance items open until a measured session proves them.

The existing local rolling metrics file is not a performance baseline for the
new runtime: its older first-TTS spans were recorded when text was queued and
cluster near 1 ms, before audio started. Fresh measurements must use the
`AVSpeechSynthesizer.didStart` instrumentation and identify the build and
hardware under test.

## v3 milestones

| Milestone | Code status | Acceptance still needed |
| --- | --- | --- |
| 1. Instrumentation | Timing spans and process CPU/RSS diagnostics exist. | Collect representative Dictation, Meeting, and Agent baselines; GPU/ANE use is not measured. |
| 2. Shared capture | `AudioCaptureHub` and contention self-test exist. | Hold a real meeting recording while wake and dictation operate; confirm no dropped audio. |
| 3. Streaming ASR | Partial/final streaming and transcript bus exist. | Measure live partial latency and word quality on actual microphone/system tracks. |
| 4. Dictation fast path | `CleanupRouter`, deterministic formatting, residency policy and bounded tail exist. | Measure key-up to origin-app injection and compare quality/latency across realistic utterances. |
| 5. Meeting event bus | `TranscriptBus` feeds incremental meeting context and candidate detection. | Measure sentence end to visible action card on a real meeting. |
| 6. Proactive actions | Candidate cards, user-authority rules, reconciliation and the unified action lifecycle exist. | Exercise real passive and user-command scenarios, including edit, dismiss and approved execution. |
| 7. Full duplex | Persistent agent, barge-in, background tasks and async tool handling exist. | Verify simultaneous listening/speech and continued conversation during a live long task. |
| 8. TTS | Apple system TTS and streaming baseline exist; `docs/tts-benchmark-2026-09-13.md` records generated-PCM timing and interruption on this Mac. | Kokoro and Piper are absent locally, so their quality/CPU/RAM comparison and actual speaker latency remain open. |
| 9. Multi-round tools | Bounded model/tool/result loop and permissions exist. | Complete a real inspect → click → verify task with the intended apps. |
| 10. Browser | Local CDP and AX fallback exist. | Validate navigation, fill, click, submit and download against real Chrome-family tabs. |
| 11. ACP | Structured ACP client exists; nested permission requests reach a reviewable Agent card, and handshake failure offers a one-shot compatibility CLI card with an exact command. | Live Codex, Claude Code and Qwen Code handshakes, permission requests, cancellation and progress. |

## v4 milestones

| Milestones | Code status | Acceptance still needed |
| --- | --- | --- |
| 0. Baseline instrumentation | Stage spans, model/load traces, CPU and RSS diagnostics exist. | Representative end-to-end baseline and GPU/ANE measurement. |
| 1–4. Actions | Durable models/receipts and `ActionOrchestrator` route Meeting, Agent and ACP task submissions; ACP's nested permissions pass through `PermissionBroker` and are included as receipt events. | Prove provider-specific readback and complete meeting edit/approve flows. ACP file changes still lack an independent diff, so its receipts remain unverified. |
| 5–8. Capture, ASR, bus, live actions | Shared fan-out, streaming events and candidate cards exist. | Real microphone/system-audio and approximately two-second visible-card acceptance. |
| 9–10. TTS and duplex | Apple TTS, streaming clauses and barge-in exist. The benchmark measures generated PCM, CPU, RSS and write-path interruption. | Real acoustic interruption and alternative-engine benchmarks. |
| 11. Multi-round loop | Bound rounds, calls and wall time; feed tool results back to the model. | End-to-end computer workflow with real permissions and side-effect verification. |
| 12. Scoped permissions | App, path, domain, task and meeting scopes exist. | Confirm grants in real target apps and after relaunch. |
| 13. MCP schemas | Schema and annotations are translated to tool parameters and risk hints. | Check against live external MCP servers, including unexpected schema shapes. |
| 14. Browser CDP | Structured tab/DOM operations exist. | Live Chrome-family workflows and fallback behavior. |
| 15–16. Model runtime and scheduling | Lifecycle state and compute priority infrastructure exist. | Demonstrate actual prewarm, unload and GPU recovery on installed models; measure notes inference under simultaneous realtime load. |
| 17. NextMemory | Constrained local entity index is built from existing activity; stored names are serialized as data before model use. | Show improved entity resolution in real sessions without treating stored names as instructions. |

## Cross-cutting acceptance still open

- v4 §37's `NSEvent.flagsChanged` vs `CGEventTap` hotkey experiment now has a
  bounded pass-through CLI in `Tools/HotkeyExperiment.swift`. It deliberately
  fails when no physical key-down/release cycles are observed. Run it with the
  intended foreground apps before changing the production `CGEventTap` path.
- v4 §§29–33's model prewarming, GPU recovery, and CPU/GPU/ANE strategy require
  installed models and actual contention measurements. A lifecycle registry by
  itself does not prove runtime recovery.
- v3 §42 and v4 §48 scenario acceptance requires the relevant TCC grants,
  account sign-ins, real audio, and target applications. Self-tests should fail
  honestly when those dependencies are absent.
- Do not mark either roadmap complete solely because `make build`, `make test`,
  and synthetic self-tests pass. Record measured results and exact environment
  here as each scenario is exercised.
