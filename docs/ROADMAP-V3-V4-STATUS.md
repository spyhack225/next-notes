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
| 2. Shared capture | `AudioCaptureHub` and contention self-test exist. System-audio HAL startup is bounded to five seconds on a lifecycle queue; a deterministic late-cleanup test and an installed-app Record → Stop cycle passed. | Hold a real meeting recording while wake and dictation operate; confirm no dropped audio and a nonzero system track. |
| 3. Streaming ASR | Partial/final streaming and transcript bus exist. | Measure live partial latency and word quality on actual microphone/system tracks. |
| 4. Dictation fast path | `CleanupRouter`, deterministic formatting, residency policy and bounded tail exist. | Measure key-up to origin-app injection and compare quality/latency across realistic utterances. |
| 5. Meeting event bus | `TranscriptBus` feeds incremental meeting context and candidate detection. | Measure sentence end to visible action card on a real meeting. |
| 6. Proactive actions | Candidate cards, user-authority rules, reconciliation and the unified action lifecycle exist. | Exercise real passive and user-command scenarios, including edit, dismiss and approved execution. |
| 7. Full duplex | Persistent agent, barge-in, background tasks and async tool handling exist. | Verify simultaneous listening/speech and continued conversation during a live long task. |
| 8. TTS | Apple system TTS and streaming baseline exist; `docs/tts-benchmark-2026-09-13.md` now compares Apple, Kokoro ONNX and Piper on this Mac. Release-build `--selftest-tts` and `--selftest-tts-stream` passed. | Kokoro/Piper remain benchmark-only; real speaker onset, acoustic interruption and comparative listening quality remain open. |
| 9. Multi-round tools | Bounded model/tool/result loop and permissions exist. | Complete a real inspect → click → verify task with the intended apps. |
| 10. Browser | Local CDP and AX fallback exist. Chrome 152 in an isolated profile passed target discovery, inspect, fill, click with state readback, and navigation against a local page in about 0.815 s. | Validate submit/download and AX fallback against intended real tabs. |
| 11. ACP | Structured ACP client exists; nested permission requests reach a reviewable Agent card, and handshake failure offers a one-shot compatibility CLI card with an exact command. Local ACP fixture and production loop self-tests passed. Codex and Claude now resolve through pinned official ACP adapters instead of their ordinary CLIs; the fresh debug binary completed both providers' real `initialize` → `session/new` → prompt flow with `ACP_LIVE_OK`. | Rerun the live check from the final installed app; validate provider permission requests, cancellation and progress. Qwen Code is absent; an OpenCode ACP attempt did not finish `initialize` while stdin remained open. |

## v4 milestones

| Milestones | Code status | Acceptance still needed |
| --- | --- | --- |
| 0. Baseline instrumentation | Stage spans, model/load traces, CPU and RSS diagnostics exist. | Representative end-to-end baseline and GPU/ANE measurement. |
| 1–4. Actions | Durable models/receipts and `ActionOrchestrator` route Meeting, Agent and ACP task submissions; ACP's nested permissions pass through `PermissionBroker` and are included as receipt events. | Prove provider-specific readback and complete meeting edit/approve flows. ACP file changes still lack an independent diff, so its receipts remain unverified. |
| 5–8. Capture, ASR, bus, live actions | Shared fan-out, streaming events and candidate cards exist. | Real microphone/system-audio and approximately two-second visible-card acceptance. |
| 9–10. TTS and duplex | Apple TTS, streaming clauses and barge-in exist. The benchmark measures generated PCM, CPU and RSS for Apple, Kokoro ONNX and Piper; Apple first generated PCM was about 203–211 ms on this M3, Piper about 98–109 ms, while Kokoro returned a full buffer after about 3.2–3.4 s. | Real acoustic interruption, speaker onset and comparative listening quality. |
| 11. Multi-round loop | Bound rounds, calls and wall time; feed tool results back to the model. | End-to-end computer workflow with real permissions and side-effect verification. |
| 12. Scoped permissions | App, path, domain, task and meeting scopes exist. | Confirm grants in real target apps and after relaunch. |
| 13. MCP schemas | Schema and annotations are translated to tool parameters and risk hints. The official Everything v2.0.0 server listed 13 tools and returned `get-sum(2, 3) = 5` through both stdio and Streamable HTTP/SSE after protocol and typed-argument fixes. | Check additional external MCP servers and unexpected nested schema shapes. |
| 14. Browser CDP | Structured tab/DOM operations exist; a real isolated Chrome 152 target completed inspect → fill → click → readback and navigation. | Live submit/download and AX fallback behavior. |
| 15–16. Model runtime and scheduling | Lifecycle state and compute priority infrastructure exist. Release-build self-tests loaded Parakeet and Qwen on Metal; Qwen generated 16 tokens at 5.4 tok/s, and a 130.1 s notes fixture generated 153 tokens in 15.7 s. | Demonstrate actual prewarm/unload and GPU recovery under memory pressure; measure notes inference under simultaneous realtime load. |
| 17. NextMemory | Constrained local entity index is built from existing activity; stored names are serialized as data before model use. | Show improved entity resolution in real sessions without treating stored names as instructions. |

## Cross-cutting acceptance still open

The installed 0.2.4 candidate (build 73) on a MacBook Air M3, 16 GB, macOS 26.5.2
passed the local Workspace CLI signed-in check, the ACP/MCP/browser/tool-loop
self-tests, and the model-backed Parakeet, Metal and notes probes. Live
read-only Google Calendar and Gmail API calls succeeded with one result each.
These establish that the local dependencies load and the account can read;
they do not execute a cloud write or a physical meeting scenario.

Live UI validation exposed a main-actor freeze in `SystemAudioCapture.start` during
`Record meeting now`. The corrected source passed `--selftest-systemaudio-timeout`,
capture/stream/duplex/contention/meeting-live probes, and an installed-app
eight-second Record → Stop cycle without hanging. Both shell and LaunchServices
system-audio probes captured roughly 48,000 zero samples and ended
`SYSTEM_AUDIO_SILENT`; system-audio permission and nonzero playback remain
unverified. The corrected source must be included in the final installed build
and release artifact before this entry becomes a shipped claim.

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
