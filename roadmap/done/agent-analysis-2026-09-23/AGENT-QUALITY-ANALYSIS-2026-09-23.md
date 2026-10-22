# Agent quality analysis: decision document

> **Historical model assumptions — revised 2026-09-30:** this completed plan/audit
> preserves its dated measurements and implementation history. For new work, follow
> the [independent-role/shared-file contract](../../in-progress/SHARED-BRAIN/00-README.md): Meetings, Agent and cleanup
> may use different appropriate models; exact verified artifacts are reused, with
> workload-specific consent and request ownership. Agent-only file selection,
> universal model defaults and deletion based only on the Agent are superseded.
> MiniCPM cleanup + Apple guard/fallback is concurrent work, not evidence that this
> historical build used it. Re-measure quality/latency on the actual current engine.

2026-09-23. This consolidates five read-only analyses of the macOS voice and typed Agent. The
raw reports, with every measurement and the reasoning behind it, are in
[`roadmap/done/agent-analysis-2026-09-23/`](./):

- [A — latency](A-latency.md): mic PCM to first audible syllable, hop by hop
- [B — tool calling](B-tools.md): why it says "I don't have access" and why it goes silent
- [C — concurrency](C-concurrency.md): what blocks what during a voice session
- [D — answer quality and proactivity](D-quality.md): which model answers, what it is told, graded real turns
- [E — reference study](E-reference.md): qwen-audio-agent, Pipecat and the alternatives

All source paths below are relative to `Sources/NextNotes/` unless stated. `ToolLoop` means
`Agent/RealtimeAgent+ToolLoop.swift` and `Coordinator` means
`Agent/VoiceConversationCoordinator.swift`. Line numbers are the ones the reports recorded
against the working tree on 2026-09-23. Finding IDs (L1, T3, C2, Q5…) are used for
cross-references throughout.

---

## 1. Verdict

The complaint: laggy, not proactive, often no answer, wrong tool calling ("it says it has no
access although the tool is there"), bad audio latency, and a wish for OpenAI-Realtime or
Gemini-Live style conversation with work running in the background. Every part is real and
measured, and most of it is self-inflicted rather than a hardware limit.

**(a) Today the agent has no usable model.** The Agent role points at
`mtp-gemma-4-E4B-it-Q4_0.gguf`, a ~60 MB *draft head*, not a model. The "switch and delete old"
download setting deleted the real weights after a check that only *opened* the new file, which
a draft head passes. The last two typed turns ("Hi", "hi") got "Inference could not start."
Every path now falls to Apple Foundation Models (~3B, 4,096-token window), which the
~3,000-token planner prompt was never sized for. As of 21:46Z the head is gone too,
`library.json` is empty, the role still names the head, a 4B model (`K2-Horizon-4B`) is
downloading, and 4.3 GB of disk is free.

**(b) The plumbing turns small mistakes into refusals or silence.** Qwen's chat template is
used for every model; special tokens are stripped from output, so tool calls leak as prose
(`name="reminders">`); the parser takes one format; typed turns first run a *tool-less*
112-token pass that tends to say "I don't have access… would you like me to?"; a typed plan
gets 18 s; any error ends the turn with no repair; the prompt names tools that are not in the
schema; MCP and Composio tools are never exposed.

**(c) Latency is 3–4× the target.** End of speech → first audio is **3.10 s** warm, 8–9 s or a
hard failure when the worker model loads on the same scheduler lane. Barge-in takes **0.84 s**.

**(d) Conversation and background work are coupled by policy.** The worker's warmup takes the
frontend's priority; a failed frontend turn leaves the input-pending flag stuck and freezes all
work; that flag pauses planning, not just effects; there is one compute slot and one llama
context; results are read out as raw fragments at unmanaged moments.

**(e) Proactivity is unwired.** No routines, no goals; the digest and podcast are called only
by self-tests. Of 153 real requests, **27%** got a substantive answer; of 20 clean requests
graded by hand, **3** were fully useful; none was started by the agent.

Pipecat is not the fix (section 2). The fix is a model that answers, plumbing that tolerates
the model, a latency pass over five hops, and finishing a frontend/worker split that half
exists.

### Headline numbers

| Measure | Today | Target | Source |
|---|---|---|---|
| End of speech → first audio, warm | **3.10 s** (2.83–3.58 s) | **≤ 0.9 s** | A §0 |
| Same, cold process | 10.4 s | voice marked "ready" only once models are resident | A §0 |
| Transcript → first model text, real sessions | median 1.81 s (n=15) | ≤ 0.4 s | A §0 |
| Voice end → end-of-utterance confirmed | 0.70–1.18 s | 0.30–0.45 s | A §2 |
| Voice turns that failed at ~2.0 s (lane barrier) | 3 of 15 on 09-22 | 0 | A Hop 8 |
| Turns overlapping a worker load | 3.2–8.8 s to first token | no difference from an uncontended turn | A Hop 8 |
| Barge-in: user onset → agent pauses | 0.84 s | ≤ 0.2 s (duck) | A Hop 12 |
| Silence between spoken sentences | est. 0.25–0.4 s | ~0 | A Hop 10 |
| Real requests with a substantive first reply | 27% of 153 | ≥ 80% on the eval set | D §4 |
| Clean requests fully useful (hand-graded) | 3 of 20 | ≥ 25 of 30 on the eval set | D §4 |
| Typed first-pass output cap | 112 tokens | the persona's budget (500 at "deep") | D §0 |
| Typed tool-plan budget | 18 s for all rounds | ~30 s per round, ~120 s ceiling | B D4 |
| Agent-initiated turns in the log | 0 | pre-meeting brief and post-meeting wrap offered by default | D §4 |
| Memory facts after 200 review runs | 2 | explicit user statements always saved | D §3 |

The eval-set targets are proposed here. They are graded by the real-model self-test in Phase 1.

---

## 2. Pipecat decision

**Recommendation: do not bundle Pipecat, LiveKit Agents or Hugging Face speech-to-speech.**
Take specific pieces instead:

- **Smart Turn v3.2** (BSD-2, 8M parameters), through its existing CoreML export. It takes
  about 3.5 ms per window and scores 92.9% on the upstream eval.
- **Pipecat's frame and interruption discipline**, rebuilt natively in Swift.
- **qwen-audio-agent's frontend/backend task split and delivery scheduler.**
- **Later, OpenAI Realtime and then Gemini Live as opt-in cloud frontends**, behind the same
  frontend interface.

The reasoning comes from E:

- **A framework cannot remove the lag.** The measured costs are endpointing, a frontend waiting
  on the worker's model, two serial model passes, and results spoken at unmanaged moments. None
  of these is a transport problem.
- **Pipecat does not solve the hardest part either.** Its async tool calls re-inject late
  results, but it has no floor-aware quiet window, no batching and no confirmation that a
  result was actually played. qwen-audio-agent has all three.
- **A Python sidecar is a permanent tax on this app:**
  - 250–500 MB of runtime before any models;
  - every `.so` signed inside-out under the hardened runtime;
  - a second TCC identity, so the microphone grant belongs to whichever process opens it;
  - Python startup measured in seconds;
  - an IPC hop between the AEC reference and the output device;
  - a duplicate ASR/TTS/LLM stack on a 16 GB Mac, or else throwing away the tested Swift
    stack (EOU, Speex/AEC3, Pocket/Kokoro, their self-tests).
- **Native full-duplex models give up the agent.** Moshi, MiniCPM-o and PersonaPlex have no
  usable tool calling. qwen-audio-agent lost delegation and announcements when it tried
  MiniCPM-o.
- **LiveKit's turn detector is not usable here.** Its weights are under a licence that forbids
  use outside LiveKit Agents.

| | Pipecat sidecar | Port Pipecat's ideas to Swift | Native duplex model | Cloud realtime only | **Hybrid (recommended)** |
|---|---|---|---|---|---|
| Voice-to-voice | ~0.6–1.0 s + IPC | ~0.5–0.9 s | ~0.2 s | ~0.3–0.8 s | ~0.5–0.9 s local; 0.3–0.8 s cloud opt-in |
| Talk while tools run | yes; delivery is DIY | yes | **no tools** | yes | yes, with qwen-grade delivery |
| Effort / risk | high / high | medium / medium | high / dead end | medium / medium | **medium / low–medium, incremental** |
| Privacy | local | local | local | audio leaves the Mac | local default, cloud opt-in |
| Fit with existing Swift | replaces it | good | poor | good as a provider | **best** |

**What Next Notes already has.** The split qwen-audio-agent is built around already exists
here, at least in shape:

- The conversational frontend is Apple Foundation Models (`LocalVoiceFrontend`).
- Background objectives run as llama.cpp tool loops in a separate `RealtimeAgent(voiceWorker:)`.
- Results come back through `VoiceAnnouncementQueue`.
- The frontend and the worker use different models and different native state.

What is missing:

- a receipt-first tool contract with prompt discipline;
- one task ledger;
- a delivery scheduler;
- turn-taking that does not wait a second for silence.

The frame vocabulary is mostly a renaming and restructuring pass over `AgentCaptureController`,
`RealtimeAudioSession` and `AgentSpeechSynthesizer`.

---

## 3. Findings by area

Ranked by probability × user-visible cost. Effort: **h** = hours, **d** = days, **w** = a week
or more. A finding that several reports made is listed once, where its fix lives, and
cross-referenced elsewhere. Section 5 says how each fix is proven.

### 3.1 Latency

| # | What the user sees | Root cause | Fix | Effort |
|---|---|---|---|---|
| **L1** | First turns of a session take 3–9 s, or fail with "The local voice model failed while preparing that response" at ~2 s (3 of 15 real turns on 09-22) | The worker prewarm fires on the first committed speech (`Coordinator:201-230`) and loads the 4B GGUF at `.realtimeAgent` (`Formatting/LLM/NotesModelRuntime.swift:326,347-358`), the frontend's own class (`Formatting/LLM/LocalVoiceFrontend.swift:248,388`); equal priority does not preempt (`Core/Compute/ComputeJob.swift:45-47`). `acquire` cannot be cancelled (`Core/Compute/ComputeScheduler.swift:142-152`), so the 2 s drain barrier (`LocalVoiceFrontend.swift:214-222,312-316`) times out into `FrontendError.unavailable`. AGENTS.md already forbids warmup at the frontend's priority | Prewarm at `.background`, only when work is plausible; cancellation-aware `acquire`; on drain timeout, detach and use a fresh session. (A #1, C ranks 2 and 11) | h |
| **L2** | ~1 s pause before every answer | Two cold Foundation Models passes in series: the route is `collect()`ed before the answer session is built (`LocalVoiceFrontend.swift:483-551`); the staged session is discarded (`:133-139`), so Apple's prewarm never runs (measured 0.56 s staged vs 1.47 s not) | Prewarm route and answer sessions during speech; one streamed structured decision (intent first), or concurrent passes if measured safe. −0.7 to −1.2 s | d |
| **L3** | ~1 s wait after you stop | EOU debounce 320 ms (`Activation/LocalVoiceTurnDetector.swift:8`); commit waits for a 100 ms tick (`Activation/AgentCaptureController.swift:108,862-870`); fallbacks of 2.5 s (`:1186`) and 0.9 + 0.35 s (`:100,103`) | `tick(force:)` from `noteModelEOU` (h); start the answer on the raw EOU with audio gated; **Smart Turn v3.2** as arbiter so thresholds can drop; fallback ~1.0 s. −0.4 to −0.6 s | h–d |
| **L4** | Speculation almost never helps | Each partial restarts it; reuse needs an exact key (`LocalVoiceFrontend.swift:37-62,288-300`) that includes a volatile playback line (`Coordinator:682`); ≥ 4 words and 220 ms debounce (`Coordinator:162-183`) | Keep a completed route when the final text only appends words; drop the playback line from the key; start from the raw EOU; log hit rate. Up to 0.5–1.5 s | d |
| **L5** | The agent talks over you for 0.84 s | Barge-in waits for recognised words (`AgentCaptureController.swift:1095-1143`); the acoustic candidate pause (`:916-933`) is wired only in self-tests; energy is ignored while speaking (`:893-903`) | FluidAudio Silero VAD (already a dependency) on the cleaned stream; **duck** after ~100–150 ms of speech; pause on first partial; stop on commit | d |
| **L6** | Gaps between sentences; long answers go silent partway | Clause N+1 is synthesised only after N has played (`Agent/Speech/AgentSpeechSynthesizer.swift:192-204,348-359`); the engine stops per clause (`Agent/Speech/PocketAgentVoice.swift:176-181,281-291`); commas are not boundaries (`Agent/Speech/StreamingSpeechBuffer.swift:107-113`); replies over 280 characters make `spokenForm` empty (`Agent/Speech/AgentSpeechPolicy.swift:16,20-32`) | One `PocketTtsSession` per reply with synth-ahead, engine kept running, first chunk at a comma or ~6–8 words, length cap per clause (h), ack on first audible sample (`PocketAgentVoice.swift:215`) | h–d |
| **L7** | Slow first reply; 10 s cold | A new EOU detector loads per session (`AgentCaptureController.swift:514-523`): 1.7–3.0 s warm, 9–12.7 s cold; Pocket cold load 12.6 s | Resident EOU detector with `reset()`; prewarm EOU and Pocket at launch or arm; "voice ready" only when all are | h–d |
| **L8** | ~50–100 ms on everything; weaker AEC | 100 ms capture batches (`Core/AudioCaptureHub.swift:277-282`); output reference 100 ms late (`Agent/Speech/VoicePlaybackReference.swift:11`) | Promote the `AVAudioSinkNode` capture (18 ms vs 63–71 ms); ~10 ms IO buffer; source-node output | d |
| **L9** | Random extra delay up to 0.6 s | Main-actor stalls of 0.34–0.63 s (0.02–0.07 s on 09-14). Unattributed; candidates are synchronous `AgentSession` JSON writes per row and per clause (`Agent/RealtimeAgent.swift:1134-1141,1199-1214`) and `lane.sync` per clause end (`VoicePlaybackReference.swift:34`) | Instruments Hangs trace first (A and C agree it is not attributed); then an off-main debounced writer | d |
| **L10** | (diagnosis) | Only two voice spans persist; voice, text and worker rows share a name; `frontend_unavailable` folds three causes (`Coordinator:596-606`) | Persisted per-stage spans tagged `source=voice\|text\|worker` | h |

Not the problem: the stop operation itself (4–15 ms), the deterministic gates, Speex CPU, and
the uncontended scheduler wait.

### 3.2 Tool calling

| # | What the user sees | Root cause | Fix | Effort |
|---|---|---|---|---|
| **T1** | "Inference could not start"; after today's build, silent fallback to Apple FM | `ModelLibraryStore.decide(.switchDeleteOld, loadSucceeded:)` deletes the old model after a check that only opens the file (`Support/ModelLibrary/ModelLibraryStore.swift:557-561`; `prepare()` at `Formatting/LLM/NotesModelRuntime.swift:334`, where `prepareForConversation` at `:347` decodes a token). `ModelRoleStore.provider(for:)` guards with `model(withID:)`, which includes auxiliary files (`Support/ModelLibrary/InstalledModelLibrary.swift:171-173`), and re-sets the head as active on every turn (`Support/ModelRoles/ModelRoleStore.swift:573-578`) | Verify = one decoded token; guard with `usableModels`; repair a bad role at launch and say so once; name the answering model in the pane. (B D1, D P0-1/2) | h |
| **T2** | Tool-call fragments as the reply (`name="reminders">`) | ChatML + Qwen `<think>` for every model, stop on `<\|im_end\|>` (`NotesModelRuntime.swift:1030-1044`); special tokens parsed in (`Formatting/LLM/LlamaHelpers.swift:23-31`) but stripped out (`:43,46`), so the literal-tag check (`ToolLoop:934`) misses and `:950` returns the rest as the answer | The GGUF's own template (`llama_chat_apply_template`) or a per-family table; `<think>` for Qwen3 only; render special tokens in planner output | h–d |
| **T3** | "I don't have access to your email… would you like me to?" five times while the user says "yes", "use them" | Typed turns first run a pass with **no tools**, 112 tokens, and a header to pick (`ToolLoop:399-419`, prompt `:494-537`). No typed pending-intent slot (voice has one, `Coordinator:359-367`). The deterministic gates run only for voice (`Coordinator:371-378`; typed reaches them only after `<use_tools/>`, `ToolLoop:741-745`) | **Remove the header pass for typed turns**; the planner already answers directly when no tool is needed. Add a typed pending-intent slot | d |
| **T4** | "Invalid response header / invalid tool request"; XML shown as the answer | Exact-match header parse (`Agent/VoiceConversationWork.swift:45-65`) ends the turn (`ToolLoop:432-433,462-464`); Hermes-only parser, `"parameters"` silently emptied (`Agent/AgentToolCall.swift:26-38,44-51`); the 256-token cap truncates write calls (`ToolLoop:888,891,934-935`) | Now: unknown header or bare call = `<use_tools/>`, tolerant parser, ≥ 1,024 tokens for writes, one repair round. Then **native/constrained tool calling**: Apple FM `Tool` + `@Generable`; GBNF for llama, reusing `Agent/FunctionCalling/LocalModelFunctionCallProposer.swift:187-198`; OpenAI `tools` for cloud | d / w |
| **T5** | "I stopped the tool plan because it took too long" on two-step typed requests | 18 s for all rounds of a typed local plan (`ToolLoop:796-798`), plus 18 s for the first pass (`Agent/RealtimeAgent.swift:31`, `ToolLoop:386-388`); a round is 2.5–5.2 s of prefill alone. Voice workers get 120 s | ~30 s per round, ~120 s ceiling, visible progress; answer from the last verified result on timeout | h |
| **T6** | "The tool computer.open_app did not run: Nothing is connected that can do…"; "requested an unavailable tool" | An unknown name abandons the plan (`ToolLoop:962-967`); any tool error ends the turn (`:1072-1081`); `Agent/Tools/ToolRouter.swift:16-40` is unused; "app not installed" becomes `.noIntegration` (`Computer/ComputerToolExecutor.swift:79`), rendered as an access problem (`Agent/AgentModels.swift:286`) | Three error kinds: denial ends the turn; recoverable goes back to the model with valid options (≤ 2 repairs); infrastructure ends it in plain words. Fuzzy name resolution. `.notFound` for missing apps | d |
| **T7** | "I cannot access past meetings / reminders / skills" while the tools exist; MCP and Composio never usable | 9 core + 15 keyword-picked tools (`ToolLoop:603-633`, `Agent/Skills/SkillPromptIndex.swift:92-100`), while the grounding lists the full roster (`ToolLoop:1093-1101`, `Persona/AgentGrounding.swift:139-155`), the rules name dropped tools (`:683-691`) and forbid unlisted ones (`:677-678`). The refusal guard uses the filtered roster (`:831,942`). `RealtimeToolSelection.allowedIDs` is hard-coded (`ToolLoop:29-58`), so `Integrations/MCP/MCPClient.swift:173` registrations are never plannable | **One per-turn `AgentCapabilityManifest`**: schema, prose, guard, allowlist and "what can you do" all derive from it. Select by namespace intent, never keyword top-k. MCP/Composio join by risk class | d |
| **T8** | Voice denials, reworded each time; "okay" to "Shall I set it for 10?" gets "Sorry — I didn't catch that." | The voice answer streams to TTS unchecked (`Coordinator:446-447`); the backstop needs a second *identical* denial (`:484-495`); `toolShapeMatch` needs verb AND noun (`Agent/AgentDirectIntent.swift:193-253`); the answer lane may not act or promise (`Formatting/LLM/LocalVoiceDecision.swift:145-156`); "okay"/"ok" are noise (`Activation/VoiceTurnPolicy.swift:56-59`) and `pendingIntent` is set only on the answer path (`Coordinator:479-481`) | Rebuttal on the voice answer with speech held; escalate on the first contradicted denial; question-form gates for calendar, reminders, meetings, knowledge ("may only add" holds); a worker question sets a pending action, during which "okay" is not noise | d |
| **T9** | False refusals and forced re-plans | Phrase matching (`Agent/AgentRefusalGuard.swift:35-68`) misses "Drive", "tools", "would you like me to…"; "I don't have enough information" trips it | Clause-scoped matching; the manifest (T7) makes most of it unnecessary | h |
| **T10** | "open youtube and play the latest Cortech video" → "Opened youtube.com." | Shortcuts fire on any site or file word (`Agent/AgentDirectIntent.swift:121-124,283-293`) before the planner (`ToolLoop:741-745`); `parse == nil` is used as a veto (`Support/ModelRoles/ModelRoleStore.swift:795`) | Shortcut only when the whole sentence is consumed | h |
| **T11** | "Ask the agent what's on my calendar" → "I don't have that information." | "ask agent/app" prefixes route to a tool-less path (`Agent/AgentTurnIntent.swift:61-65,75-83,112-119`; `Agent/RealtimeAgent.swift:563-574`) | Drop those prefixes; allow read tools on the on-device path | h |
| **T12** | Every mail is "from unknown sender"; "last 10 emails" impossible | Query required, 5 results fetched one by one, ids and subjects only (`Agent/WorkspaceToolRunner.swift:19,55-83`); header parse misses the JSON shape (`:450-456`); no read tool | Default `in:inbox`, `maxResults`, metadata batch with date/from/snippet, `read_email(id)`, header fix, repair hint | d |
| **T13** | "The tool planner failed…" after one large result | Uncapped results (`Agent/AgentToolLoop.swift:35-45`) overflow 4K (`ToolLoop:927-929`; llama `NotesModelRuntime.swift:586-588`) | Cap ~1,200 characters per result; count tokens per round | h |
| **T14** | "Did search_email (step 1/8). Timed out on get_agenda."; raw Codex errors and URLs | Ids in the timeout sentence (`ToolLoop:849-862`), required by `Agent/RealtimeAgentToolLoopSelfTest.swift:549-553`; raw handoff errors (`ToolLoop:364-369`) | One user-facing renderer on every path; ids in the audit log only | h |
| **T15** | "Run locally once" always ends in "Nothing local can do that." | A task with `tool == nil` (`ToolLoop:233-241`) that `Agent/Backend/LocalAgentBackend.swift:19-24` refuses (C rank 14) | Pass a resolved tool, or route to the tool-loop worker | h |

### 3.3 Duplex and concurrency

L1 is the most visible concurrency bug; it is listed under latency and is Phase 0.

| # | What the user sees | Root cause | Fix | Effort |
|---|---|---|---|---|
| **C1** | After one failed voice reply, background work silently stops and the mic stays open | Failure leaves `inputPending` true (`Coordinator:572-574`); no idle close while a job runs (`Activation/AgentCaptureController.swift:1272-1281`). L1 → 25 s deadline (`Coordinator:437`) → stuck | Resolve the epoch on every terminal outcome. **C does not raise this:** AGENTS.md requires effects to wait until the latest input is classified, so releasing on failure is safe only with C2's write-time gate. Ship them together: planning and reads resume; writes wait for the next classified epoch | h–d |
| **C2** | Talking pauses background work; "how's it going?" slows it | Every round and call awaits `waitForVoiceInput()` (`ToolLoop:864,915,954,1000`), a 20 ms poll (`Coordinator:259-263`) on a flag raised by 120 ms of energy (`AgentCaptureController.swift:893-901`) and cleared only after the whole answer is generated (`Coordinator:497`) | Gate only where an effect commits (`mayCommitEffect` for `risk > .read`); release when the route is known | h–d |
| **C3** | Workers stall while the frontend talks | One running job per process (`Core/Compute/ComputeScheduler.swift:85-87`) | Lanes with capacity. **A and C disagree:** A would take Foundation Models out of the scheduler (a system service with no llama state); C would measure GPU/ANE contention first. Resolution: measure (`--selftest-voice-overlap`); if FM time to first token degrades < ~15% under a concurrent llama decode, take A's route | d |
| **C4** | A voice job waits minutes behind meeting notes | One llama context, non-preemptible (`NotesModelRuntime.swift:667,698-715,884-894`) | A second `llama_context` on the shared `llama_model` for voice work (a few hundred MB of KV) | d |
| **C5** | Results arrive as raw fragments, clipped, or lost after the session closes | First two clauses verbatim (`Agent/VoiceAnnouncementQueue.swift:45-50`); dropped when closed (`:12-15`), cleared on end (`AgentCaptureController.swift:360`); flushed on any 100 ms tick without checking `inputPending` (`:1268`) | The delivery scheduler (section 4) | d |
| **C6** | "How's it going?" → "still working on it" | Status is `Task N [running]: <prompt>` (`Coordinator:666-685`) | Step, tool and elapsed time from `AgentActivityStore`; answered from the ledger, no model call | h |
| **C7** | Coding tasks by voice run the 4B planner and cannot be queried or cancelled | Voice never reaches the harness router (`Agent/RealtimeAgent.swift:208-211`); two ledgers (`Coordinator:688-708`) | One ledger (`TaskBridge`); `spawn` → `AgentHarnessRouter` → local worker or ACP | w |
| **C8** | Writes stall at a card; a spoken "yes" can deny it | No spoken permission (`Agent/Permissions/PermissionGate.swift`); a revision cancels the approval (`Coordinator:347,525`) | `respondPermission` route, valid only with a pending, session-owned request; revisions keep approvals unless they change that call | d |
| **C9** | Occasional clipped or cross-wired speech | Delivery bound by agent generation (`Agent/VoicePlaybackDelivery.swift:28-34`); any `speak` cancels the one buffer (`Agent/RealtimeAudioSession.swift:146-175`); `isThinking` can stick with no watchdog (`Coordinator:459-461`) | Only the output scheduler starts audio; bind by `OutputID` | d (with C5) |
| **C10** | The island flips to "working" mid-conversation | Workers drive it (`Agent/RealtimeAgent.swift:516-521`) | Workers publish to the ledger; only the session owner drives the island | h |
| **C11** | No conversation when Apple Intelligence is unavailable | No fallback lane (`Coordinator:415-422`); the one llama context would make duplex impossible | The C4 context doubles as the fallback lane; or the cloud frontend (Phase 5) | d |
| **C12** | (maintainability) | Ten independent epoch counters; nothing names "the current turn" once | `TurnID` and `OutputID` owned by one reducer | w |

No lock-order deadlock was found (native before lane; FM takes only the lane). Two latent
traps: `awaitCleanupIdle` runs while holding both (`NotesModelRuntime.swift:1180`), which
deserves a self-test assertion; and `ParakeetEngine` holds `.realtimeASR` for a whole
dictation (`Transcription/ParakeetEngine.swift:87`), blocking the frontend meanwhile.

### 3.4 Answer quality and proactivity

| # | What the user sees | Root cause | Fix | Effort |
|---|---|---|---|---|
| **Q1** | Every answer comes from a ~3B, 4K model, or none | T1, plus: background voice work is pinned to `.appLLM` though not real-time (`Support/ModelRoles/ModelRoleStore.swift:727`); cloud is gated by the wrong consent (`ModelRoleStore.swift:735`, `ToolLoop:765`); the configured OpenRouter model is a 2.6B free one | Pin only the conversational frontend; typed turns and background work use a capable configured model behind **its own** consent | h–d |
| **Q2** | Clipped typed answers even at "deep" | 112-token typed cap (`ToolLoop:414,418`); "be brief" five times (`ToolLoop:535,562`, voice rules, planner's 220 characters); "deep" reaches only "ask the model" (`Agent/RealtimeAgent.swift:643`); "These rules override anything above." (`Persona/AgentPromptContext.swift:119`) beats the persona on tone, not just safety | Typed turns use `localAnswerTokenBudget`; typed rules say "answer completely, lead with the answer"; scope the override line to safety | h |
| **Q3** | "Who am I?" → "I'm Will, Serge's autonomous alter ego…" | Up to four identities: persona, grounding, and rule lines at `ToolLoop:500,554,671` | Grounding is the only identity; add "'I/me/my' in the user's turns means the user" | h |
| **Q4** | "What is the LLM under the hood?" → "I don't have visibility into that" | "Never mention tools, files, settings, models" (`LocalVoiceDecision.swift:151`, `ToolLoop:565`) | Allow the model name and paths when asked; update `PersonaCareEval` in the same change | h |
| **Q5** | "What about your tools?" → "I couldn't interpret that." ×4 | The voice router sees only the latest utterance (`history: []`, `Formatting/LLM/LocalVoiceDecision.swift:91-95`); the answer lane cannot act (`:145-156`) | Pass the previous exchange; a deflection re-routes once as work | h |
| **Q6** | "Tell me the exact name of the reminder" | "Wait for the user's yes before `schedule.create`" and "never infer…" (`ToolLoop:686-688`) contradict the persona's "decide and continue" | Create fully dictated reminders and say how to undo; act on the clearly likely reading and state it; writes in the user's name still go to the card | h |
| **Q7** | Wrong dates; "what's next?" needs a tool round | No "now" context on the first pass or voice lanes | A cached "Now" section in `AgentPromptContext`: time, next 2 events, meeting in progress, active app, jobs, pending cards | d |
| **Q8** | Voice ignores most of the persona; new installs send an editor hint to models | `PersonaStore.shortCard` stops at the first blank line (`Persona/PersonaStore.swift:169`); "Add below: …" in `Resources/agent-persona-base.md:15-16` and `PersonaStore.builtInBaseText:81-82` (kept byte-identical per AGENTS.md) | Short card = first paragraph + "Voice"/"Rule of thumb"; move the hint to the editor placeholder in both copies | h |
| **Q9** | "Summarise those" forgets the list | History of 2,500 characters (`ToolLoop:382`) and 1,400 on voice (`Coordinator:678`) | Scale with the reader's context; store results as summary + pointer | h |
| **Q10** | Library questions overflow on Apple FM | 20 × 700 characters, not fitted (`Knowledge/KnowledgeAsk.swift:157-158`); typed library questions skip `KnowledgeAsker` | Fit to `contextTokens`; route typed library questions there | h–d |
| **Q11** | It never remembers what it is told | 200 review runs saved 2 facts | Save explicit statements directly; seed from meeting attendees | d |
| **Q12** | It never speaks first | 0 routines, 0 goals; digest and podcast have no production caller; `meetingStarting` has no default instance; the meeting prompt says an unasked follow-up "is worse than none… often zero" (`Agent/AgentPrompts.swift:24-25`) with a quote per write (`:40-42`) and no suggestion lane; routines cap at three sentences (`Agent/Schedules/ScheduledRunner.swift:441`); owed items only in `DecisionThreadView` | Phase 4 | w |
| **Q13** | A stale "Hey Next" help reply | `capabilitiesReply` (`Agent/RealtimeAgent.swift:456-478`), mostly unreachable | Delete it or derive it from the manifest | h |

### 3.5 Where the reports disagree

1. **Which model was deleted.** B says Gemma answered earlier on 09-23; D reads `lastUsedAt` as
   Qwen3.5-4B → MiniCPM5-2B → head; C assumes Qwen3.5-4B. The library is now empty, so it
   cannot be checked, and it does not change the fix: a real GGUF was resident until today
   (A's 09-22 contention numbers were measured against it) and none is now.
2. **Quiet window.** C: 700 ms after the last word. E (qwen, measured): 350 ms after the floor
   frees and playback ends. **Adopt 350 ms** as a named constant, tuned with L10's metrics.
3. **Interrupted announcement.** C re-phrases and replays the remainder. qwen counts a *user*
   interruption as delivered (the result is in context; replaying is worse) and retries only
   other cancellations. **Adopt qwen**; C's re-phrasing covers the non-user case.
4. **When "delivered" is recorded.** C: after every clause. qwen and A: first audible frame.
   **Adopt first audible frame**, plus rule 3.
5. **Frontend concurrency.** A: run route and answer concurrently. C: Foundation Models may
   refuse concurrent requests (`Coordinator:617` maps `.concurrentRequests`). **Try one
   streamed structured decision first**; concurrent sessions only if measured safe.
6. **Foundation Models inside `ComputeScheduler`.** See C3.
7. **Filler.** The harness shows filler openings ("Hey there, I hear you…") against a persona
   that forbids them; unverified in production. It becomes an eval check in Phase 1.

---

## 4. Target architecture

```
 mic ──► Audio I/O (AVAudioSinkNode capture, 10 ms IO, source-node playback)
          │  AcousticEchoProcessor (SpeexDSP / AEC3) with the exact playback reference
          ▼
 InputProcessor  = today's AgentCaptureController logic, emitting events instead of calling 4 objects
          │  Silero VAD (FluidAudio)  ── speech prob ≥ θ for ~120 ms while speaking ──► Interruption.provisional (duck)
          │  Parakeet EOU (resident)  ── raw EOU ──► provisional commit (speculative answer starts, audio gated)
          │  SmartTurnArbiter (Smart Turn v3.2, CoreML) ── decides WHEN, never WHETHER the model hears the user
          │  Apple SpeechAnalyzer / Parakeet partials ── ASR text
          ▼  VoiceEvent (AsyncStream)                                  Interruption (control channel, overtakes data)
 VoiceSession  (@MainActor, pure reducer: state = reduce(state, VoiceEvent))
          │  owns TurnID / OutputID, the floor, the input epoch; the only writer of IslandState/ActivationController
          ├──────────────► FrontendResponder (actor) = LocalVoiceFrontend + Coordinator.respond
          │                   one streamed decision: FrontendDecision { answer | capabilities | spawn | revise |
          │                   cancel | status | respondPermission }; prewarmed during speech
          │                   frontend tools (admission: < 2 s, one call, own state, low risk):
          │                     spawn_task(objective)  → receipt in ms, then ONE natural ack, no filler
          │                     task_status(id?)       → read from the ledger, no model call
          │                     cancel_task(id?)       → confirmed, "cancelling" until it is
          │                     respond_approval(id?, decision) → only while an approval is pending
          │                     cheap reads: time, next events, memory recall, knowledge search
          │                   ▲ phrase(result) for deliveries, under result-only instructions
          ▼                   │
 TaskBridge (actor) ── one ledger: voice jobs + AgentTaskManager + ACP tasks
          │   states: queued → running → (delegated → finalizing) → completed | failed | needsInput |
          │           needsPermission | cancelling → cancelled
          │   progress = observability only (never spoken unless ≤ 1 line/60 s narration)
          │   mayCommitEffect(task, revision) ← the ONLY place the input barrier applies
          ▼  BackendPort
 Workers (headless; never touch UI, speech or the input flag)
          LocalToolLoopWorker (llama, its own llama_context, its own lane class) · ACPAgentBackend · KnowledgeAsker
          each receives a self-contained objective (no persona, no chat history), uses AgentCapabilityManifest,
          native/constrained tool calls, repair loop, per-round budget
          │  TaskEvent
          ▼
 OutputScheduler (AgentDelivery) — the only component that starts audio
          modes: context | respond | interrupt   (≈ Gemini SILENT / WHEN_IDLE / INTERRUPT)
          window: user floor free ∧ no turn pending ∧ no audio queued, then ~350 ms quiet
          batch completions within 120 ms (≤ 8 items); frontend phrases them ("not a new request",
          open with the result, no "task complete" filler); ack on first audible frame;
          user barge-in ⇒ delivered-in-context; other cancel ⇒ bounded retry; status question consumes
          a pending delivery; undelivered results carry over to the next session
          ▼  OutputRequest(OutputID, kind, text stream, priority)
 Streaming TTS — one PocketTtsSession per reply, clause N+1 synthesised while N plays, engine kept running,
          first chunk at a comma / ~6–8 words, per-clause length cap ──► speaker (and back to AEC as reference)

 ComputeScheduler: lanes with capacity — realtimeASR exclusive; realtimeAgent (FM) may overlap background (llama)
          behind a measured flag; worker warmup never at the frontend's class; acquire is cancellable.
```

**Swift types to add or rename**, from C §5, plus B's manifest and E's delivery modes:

| New | Replaces or absorbs |
|---|---|
| `TurnID`, `OutputID`, `TaskID` | the ten epoch counters (C12) |
| `VoiceEvent`, `Interruption` (`provisional`, `committed`, `explicitCancel`) | direct calls between `AgentCaptureController`, the coordinator, `RealtimeAgent.shared` and `RealtimeAudioSession` |
| `VoiceSession` (reducer) | the cross-object flags `inputPending`, `voiceInputActive`, `isThinking`, `heardSpeech` |
| `InputProcessor` | `AgentCaptureController` (the VAD/EOU/echo logic is kept intact; it is the most measured code in the system) |
| `SmartTurnArbiter` (proposed name) | the fixed silence thresholds in `AgentCaptureController` |
| `FrontendResponder`, `FrontendDecision` | `LocalVoiceFrontend` + `Coordinator.respond`; `LocalVoiceRoute` maps one-to-one, plus `status` and `respondPermission` |
| `TaskBridge`, `TaskEvent` | `VoiceConversationCoordinator.jobs` + `AgentTaskManager`'s voice mirror |
| `OutputScheduler` (`AgentDelivery` modes), `OutputRequest` | `VoiceAnnouncementQueue`, the direct `RealtimeAudioSession.speak` callers, `VoicePlaybackDelivery`'s generation binding |
| `AgentCapabilityManifest` | `RealtimeToolSelection.allowedIDs`, `relevantTools`, grounding roster prose, the refusal guard's roster |
| `LocalToolLoopWorker` | `RealtimeAgent(voiceWorker:)` + `runPlannedToolLoop`, now with its own `llama_context` |

The rules in AGENTS.md's closing sections survive intact. Output and work have separate
lifetimes. Provisional input pauses output and a committed turn stops it. Only explicit
cancellation invalidates work. Effects wait until the latest input is classified. Deterministic
gates may only add. The difference is that the barrier moves from everything a worker does to
the one moment an effect commits.

---

## 5. Phased plan

The repo's convention applies: each exit criterion is a self-test that **fails today** and
passes only when the thing it names happened. A test that needs a model it cannot find prints
`*_ABSENT` (SKIP in `make acceptance`), never `*_OK`.

### Phase 0 — make it answer (hours each, ~2 days total)

| Work | Exit criterion (fails today) |
|---|---|
| T1: download verify decodes a token before `switchDeleteOld` deletes anything | `--selftest-model-roles`: a fixture that opens but cannot build a context must not cause the previous model's deletion |
| T1: roles resolve only answerable models (no `mtp-`/draft/auxiliary); bad roles repaired at launch with one notice | `--selftest-model-roles` fails if a role naming an auxiliary file resolves to an installed provider (it does today, `ModelRoleStore.swift:573`) |
| Restore a working model on this Mac (user action, section 7) | `--selftest-llm-metal` generates tokens through the Agent role |
| T2: per-family chat templates; special tokens rendered in planner output | New `--selftest-chat-template`: fails if a Gemma fixture is rendered with `<\|im_start\|>`, or a tool-call control token vanishes from decoded text |
| Q2 (part): typed 112-token cap lifted to the persona budget | `--selftest-toolloop` asserts typed first-pass `maxTokens` ≥ `localAnswerTokenBudget` |
| L1: warmup at `.background` and only on plausible work; cancellable `acquire`; drain timeout detaches | `--selftest-voice-scheduling`: a frontend `acquire(.realtimeAgent)` returns while a probe load holds the prewarm class; a generation that ignores cancellation for 3 s does not fail the next turn |
| C1 + write half of C2: failure resolves its epoch; writes wait for a classified epoch | `--selftest-concurrent-voice`: after a fake deadline failure, a parked worker's read round resumes within 200 ms and its write waits |
| T15: run-locally-once passes a tool | `--selftest-acp-confirm` gains that case |
| L6 (part): 280-character cap applied per clause | `--selftest-voice-delivery`: a 600-character streamed reply produces audio for its last clause |
| L3 (part): `tick(force:)` from `noteModelEOU` | `--selftest-voice-pipeline`: `VOICE_MODEL_EOU_TO_ENDPOINT` ≤ 10 ms (today 9–106 ms) |

### Phase 1 — tools that work (1–2 weeks)

| Work | Exit criterion (fails today) |
|---|---|
| **The real-model eval first**, so every later change is measured: `--selftest-toolloop-live`, ~30 canonical requests (calendar today/tomorrow, "summarise my last 5 emails", "remind me at 9 to…", "what did we decide last meeting", "open youtube and search cats", "who am I?", "what LLM are you?", "okay" after a question…) on whatever model resolves | Fails on refusal of an available tool, timeout, wrong tool, leaked syntax or ids, or a filler opening. Target ≥ 25/30 |
| T3: remove the typed tool-less first pass; typed pending intent | eval: "summarise my emails" then "yes" |
| T7, T9, Q13: one `AgentCapabilityManifest`; namespace selection; MCP/Composio by risk class | New `--selftest-capability-manifest`: fails if a tool id named in any prompt section is missing from that turn's schema, or a registered MCP fixture tool is not plannable |
| T4, T6: tolerant parser and repair loop now; native tool calling next (Apple FM `Tool`, GBNF over the manifest, OpenAI `tools`) | `--selftest-toolloop`: a `"parameters"` key, a Gemma XML call, an unknown alias and a recoverable tool error each end in a successful call |
| T5: per-round budget with a ceiling | eval: "check my email then summarise the last one" completes |
| T8: voice rebuttal, first-denial escalation, question-form gates, pending action from a worker question | `--selftest-voice-turn-routing` gains "what's on my calendar", "any new emails?" and a worker-question → "okay" case, beside its positive corpus |
| T10, T11: whole-sentence shortcuts; no "agent/app" answer-only prefixes | eval: "open youtube and play…", "ask the agent what's on my calendar" |
| T12: Gmail defaults, metadata batch, `read_email`, header fix | `--selftest-gws` gains a `+read`-shaped fixture whose sender must parse |
| T13, T14: capped results; one renderer; no ids | The assertion at `RealtimeAgentToolLoopSelfTest.swift:549-553` is inverted: it fails if a tool id reaches the user |

### Phase 2 — latency (1–2 weeks). Targets: ≤ 0.9 s end of speech → first audio (warm), ≤ 200 ms barge-in duck

| Work | Exit criterion (fails today) |
|---|---|
| L10, L9: per-stage spans; Instruments pass on the main-actor stall | New `--selftest-voice-latency`: fails if any stage is missing or main-actor slip > 100 ms (today 0.34–0.63 s) |
| L2: prewarmed sessions; one streamed decision | `--selftest-voice-pipeline`: transcript → first model text ≤ 0.6 s warm (today 1.55 s) |
| L4: append-tolerant speculation from the raw EOU | `--selftest-voice-pipeline` prints a speculation hit (today a miss) |
| L3: Smart Turn v3.2 (CoreML) arbiter; lower debounce and fallbacks | New `--selftest-smart-turn`: fails on a mid-sentence pause judged complete, or a finished question held > 400 ms; voice end → endpoint ≤ 0.45 s |
| L5: VAD ducking barge-in | `--selftest-voice-barge`: onset → duck ≤ 200 ms (today 0.84 s to pause) |
| L6: TTS pipelining, persistent engine, comma-first chunk, first-frame ack | `--selftest-voice-delivery`: inter-clause silence ≤ 50 ms on three sentences |
| L7: EOU and Pocket resident, prewarmed at launch/arm | two sessions in one process: the second's EOU prepare is 0 |
| L8: smaller I/O buffers | capture → processing ≤ 25 ms |

### Phase 3 — full duplex (2–4 weeks)

| Work | Exit criterion (fails today) |
|---|---|
| **Step 0: tests describe production.** Port `--selftest-voice-work-lifecycle` and the `localModelProviderForTesting` cases of `--selftest-voice-conversation` onto the coordinator path; delete the unreachable `appendVoiceFollowUp` branch (`Agent/RealtimeAgent.swift:78,208-211`) | The ported tests fail with the C1 bug reintroduced |
| C2: effect gate at write time; barrier released when the route is known | New `--selftest-voice-duplex-work`: a fake worker's rounds interleave with five conversational turns, and no write commits between a revising turn's commit and its classification |
| C6, C7, C10: `TaskBridge`, one ledger incl. ACP, status from the ledger | `--selftest-tasks` gains voice jobs; "how's it going?" in `--selftest-voice-turn-routing` makes **no** model call and names the step |
| C5, C9: `OutputScheduler`/`AgentDelivery` (350 ms window, batching, frontend phrasing, first-frame ack, qwen interruption rule, carry-over) | `--selftest-voice-delivery`: a mid-answer completion is spoken only after playback + 350 ms; two simultaneous completions are one utterance; a post-`endSession` result is offered at the next `beginSession` |
| Receipt-first contract and no-filler rules (adapted from qwen's PROMPT.md) | eval: the reply to a delegation is ≤ 1 clause with no "please wait" filler |
| C12: `VoiceSession` reducer and event stream | New `--selftest-voice-session-reducer` replays a recorded pipeline trace and asserts the command sequence |
| C3, C4, C11: capacity lanes; second `llama_context` | New `--selftest-voice-overlap` prints FM time to first token with and without a concurrent llama decode, failing if either side produced zero tokens; `--selftest-residency` covers two contexts |
| C8: spoken approvals | `--selftest-voice-turn-routing`: "yes", "no", "yes, but send it to Marcus instead" against a pending fake request |

### Phase 4 — proactive and useful (2–3 weeks)

| Work | Exit criterion (fails today) |
|---|---|
| Q7: cached "Now" block | New `--selftest-now-block`: fails if the typed, voice-answer or planner prompt lacks today's date and, under `--fake-calendar`, the next event |
| Q5: router sees the previous exchange; deflection re-routes | eval: "what about your tools?", "use them" |
| Q2–Q4, Q6, Q8: one identity, typed depth, act on the likely reading, persona scoping, fuller voice card | `--selftest-persona` fails on more than one "You are" identity, a short card missing its "Voice" section, or "Add below" in the base persona |
| Q12: pre-meeting brief on `meetingStarting` (built-in, offered once) | New `--selftest-proactive`: under `--fake-calendar`, a brief built from `MeetingNotesBrief` is produced 3–5 min before the event |
| Q12: post-meeting "what you owe" wrap; a suggestion lane beside the proposal lane | `--selftest-proactive`: an owed item in a fixture meeting yields one suggestion and no write |
| Q12: morning digest offered once; owed-item nudges; a next-step offer stored as a pending intent | `--selftest-digest` fails unless a production path creates the routine after an accepted offer |
| Q11: explicit statements saved | `--selftest-memory-review`: "I'm the CEO of ProductFlo" and "my brother is Cyril" are both saved |
| Q9, Q10: longer history; fitted `KnowledgeAsker` for typed library questions | `--selftest-ask` fails if the prompt exceeds the provider's `contextTokens` |
| Q1: capable model for typed and background work, with its own consent | `--selftest-model-roles`: background voice work follows the Agent role; a cloud reader without the new consent is refused |

### Phase 5 — optional cloud realtime frontend

OpenAI Realtime first (async function calling, `semantic_vad`), then Gemini Live once
`NON_BLOCKING` functions reach the current Flash Live model. Each is a `FrontendResponder`
behind the same seam: inject a context item, create a response with per-response instructions,
cancel, `speech_started`. Capture and AEC stay local, and the workers and the delivery
scheduler are unchanged. It needs explicit consent (audio leaves the Mac), a key in the
Keychain, and the existing rule that a brief allowed for a local reader is not allowed for a
cloud one. Exit: `--selftest-realtime-cloud` against a loopback fixture server fails if a
result is delivered while the fixture reports `speech_started`, or if `spawn_task` blocks the
response.

---

## 6. Housekeeping found along the way

- **Self-tests write into the user's real stores.** `agent-tasks.json` holds 9 "Self-test
  observe the front app" tasks. `agent-audit.jsonl` holds 09-13 fixture replies and 42
  `memory.remember`/`memory.forget` rows (09-23 00:54Z–06:36Z) with no request. These feed
  routine suggestions, the memory review and task status. It is the same bug class as the
  `RunLog.record` rule in AGENTS.md: add `record`-style seams and clean the rows.
- **Tests that grade a path production never takes.** `--selftest-voice-work-lifecycle` and
  parts of `--selftest-voice-conversation` exercise `localModelProviderForTesting` /
  `appendVoiceFollowUp` (`Agent/RealtimeAgent.swift:78,208-211`), which `handle` routes
  around. `modelTurnSystem`/`modelTurnRules` (`ToolLoop:548-585`) have no production caller,
  but `RealtimeAgentToolLoopSelfTest.swift:330-430` and `PersonaSelfTest.swift:124` grade them.
  `AgentTurnIntent.resolve` never produces most of its cases.
- **`--selftest-toolloop` is green on a scripted fake model** and proves nothing about a real
  one. That is how everything in section 3.2 coexists with `TOOLLOOP_OK`. Phase 1's live eval
  closes this gap.
- **AGENTS.md is stale in four places:**
  - It says `gws auth status` reports no credentials. It is signed in, with a refresh token and
    21 scopes including Gmail, Calendar, Drive and Docs, so "I don't have access to your email"
    is false on this Mac.
  - B reports that aliases are now resolved before the allowlist, which the realtime tool-loop
    paragraph still describes the other way round.
  - Its rule that warmup must not share the frontend's priority is violated at
    `NotesModelRuntime.swift:326` (L1).
  - It says every notes and agent run has gone through Apple Foundation Models. `metrics.jsonl`
    shows installed GGUFs loading for agent turns on 09-22 and 09-23, before this regression.
- **The island switches to "working" mid-conversation** because workers drive it (C10).
- **A stale help reply** says "Hey Next" (Q13).
- **The persona template's "Add below" hint** is sent to models on fresh installs (Q8).
- **Latent deadlock guard:** add a self-test assertion for `awaitCleanupIdle` inside `load`
  (`NotesModelRuntime.swift:1180`) so a future cleanup formatter that takes the lane cannot
  deadlock it.
- **Meeting notes are set to the built-in Gemma**, which is not on disk, so notes fall back to
  Apple FM as well; T1's verify fix protects that path too.

---

## 7. Recommended next step: this week

This is the smallest set that changes what the user experiences: Phase 0, the top three of
Phase 1, and the top two of Phase 2.

The Phase 1 top three, picked by value per day:

1. the live eval, plus removing the typed tool-less first pass (T3) with a per-round budget
   (T5);
2. the capability manifest (T7), which also exposes MCP and Composio;
3. the tolerant parser, the error split and the repair loop (T4 short term, T6).

Native tool calling (the rest of T4) is a week on its own, and it should consume the manifest,
so it comes next. The Phase 2 top two, by measured gain: the prewarmed single frontend decision
(L2, −0.7 to −1.2 s) and TTS pipelining (L6: no gaps between sentences, a first chunk that does
not wait for a full stop).

**Expected result.** Answers from a real model. No 2 s failures and no 8 s outliers. Typed
requests that use tools instead of offering to. Warm voice latency drops from ~3.1 s to roughly
1.8–2.2 s; the ≤ 0.9 s target needs Phase 2's Smart Turn and speculation work too. The live
eval gives a number to watch.

**The user's part, before any code lands:**

1. Let the `K2-Horizon-4B` download finish, or install Gemma 4 E4B once there is ~9 GB free
   (4.3 GB free right now).
2. Switch the post-download policy away from "switch and delete old" until T1 ships.
3. Reset the Agent role to the new model. The stored role still names the deleted head.

### Implementation brief

Six agents with disjoint file ownership. `NextNotesApp.runRequestedSelfTest` is the one shared
file: each agent adds its flags in one contiguous block, and the verifier merges them last.
Every agent follows AGENTS.md:

- build with `make`;
- install with `make install OPEN=0`;
- self-test through `Scripts/run-selftest.sh`;
- write each new self-test to fail first, before its fix.

Agents F and D should start first, because D's work is graded by F's eval.

| Agent | Owns (files, relative to `Sources/NextNotes/`) | Delivers | Proven by |
|---|---|---|---|
| **A: model availability** | `Support/ModelLibrary/ModelLibraryStore.swift`, `InstalledModelLibrary.swift`, `ModelFitEstimator.swift`, `ModelLibrarySelfTests.swift`, `Support/ModelRoles/ModelRoleStore.swift` | T1: a one-token verify before any deletion (calls `NotesModelRuntime.prepareForConversation`, no edit there); `usableModels` guard; launch-time role repair with a one-time notice; the pane names the answering model. Q1: background voice work follows the Agent role | `--selftest-model-roles`, `--selftest-hf-search` |
| **B: llama runtime and scheduler** | `Formatting/LLM/NotesModelRuntime.swift`, `Formatting/LLM/LlamaHelpers.swift`, `Core/Compute/ComputeScheduler.swift`, `Core/Compute/ComputeJob.swift` | T2: per-family templates and special-token rendering. L1: `prewarm(voice:)` at `.background`; cancellation-aware `acquire` | new `--selftest-chat-template`; `--selftest-voice-scheduling` prewarm case |
| **C: voice turn and frontend** | `Agent/VoiceConversationCoordinator.swift`, `Formatting/LLM/LocalVoiceFrontend.swift`, `Formatting/LLM/LocalVoiceDecision.swift`, `Activation/AgentCaptureController.swift`, `Activation/VoiceTurnPolicy.swift` | L1: prewarm trigger only on plausible work; drain timeout detaches. C1: epoch resolved on failure (with D's write gate). L3: `tick(force:)` from `noteModelEOU`. L2: route and answer sessions prewarmed during speech, one streamed structured decision (or measured concurrent passes) | `--selftest-concurrent-voice`, `--selftest-voice-scheduling`, `--selftest-voice-pipeline` |
| **D: typed tool loop** | `Agent/RealtimeAgent+ToolLoop.swift`, `Agent/RealtimeAgent.swift`, `Agent/VoiceConversationWork.swift`, `Agent/AgentToolCall.swift`, `Agent/AgentToolLoop.swift`, `Agent/AgentRefusalGuard.swift`, `Agent/AgentTurnIntent.swift`, `Agent/AgentDirectIntent.swift`, `Agent/Backend/LocalAgentBackend.swift`, new `Agent/AgentCapabilityManifest.swift` | Q2: typed token cap. T15: run-locally-once. T3: header pass removed, typed pending intent. T7: the manifest, with MCP/Composio exposed. T4 short term + T6: tolerant parser, error split and repair loop. T5: per-round budget. The write-time effect gate (`mayCommitEffect`) that C1 depends on; C calls it, D owns it | `--selftest-toolloop` (new scripted cases), new `--selftest-capability-manifest`, F's live eval |
| **E: speech output** | `Agent/Speech/StreamingSpeechBuffer.swift`, `AgentSpeechSynthesizer.swift`, `PocketAgentVoice.swift`, `AgentSpeechPolicy.swift`, `VoicePlaybackReference.swift` | L6: per-clause length cap (Phase 0); one `PocketTtsSession` per reply with synth-ahead; engine kept running; comma-first chunk; first-audible-frame ack | `--selftest-voice-delivery` (long reply, inter-clause silence), `--selftest-tts-pocket-session` |
| **F: eval harness** | new `Agent/RealtimeAgentLiveEvalSelfTest.swift`, its fixture list, `Scripts/acceptance.sh` (INTEGRATION tier entry) | `--selftest-toolloop-live`: ~30 canonical requests on the resolved model; fails on refusal of an available tool, timeout, wrong tool, leaked syntax or ids, opening filler; prints `TOOLLOOP_LIVE_ABSENT` with no model; writes nothing to the user's audit log, tasks or memory | itself: it must be red on today's build once a model is installed |

The verifier's acceptance for the week: every flag above reports `*_OK`, the live eval reports
its score (target ≥ 20/30 this week, ≥ 25/30 at the end of Phase 1), and
`--selftest-voice-pipeline` reports end of speech → first audio for the warm run, compared
against today's 3.10 s.
