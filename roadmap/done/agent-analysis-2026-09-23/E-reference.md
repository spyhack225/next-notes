# E — Reference study (qwen-audio-agent) and framework options for a full-duplex Next Notes agent

> **Historical model assumptions — revised 2026-09-30:** this completed plan/audit
> preserves its dated measurements and implementation history. For new work, follow
> the [independent-role/shared-file contract](../../in-progress/SHARED-BRAIN/00-README.md): Meetings, Agent and cleanup
> may use different appropriate models; exact verified artifacts are reused, with
> workload-specific consent and request ownership. Agent-only file selection,
> universal model defaults and deletion based only on the Agent are superseded.
> MiniCPM cleanup + Apple guard/fallback is concurrent work, not evidence that this
> historical build used it. Re-measure quality/latency on the actual current engine.

Scope: read-only research, 2026-09-23. Part 1 is a close reading of
`roadmap/references/qwen-audio-agent-main` (Apache-2.0, Node/TS, v1.11 / v2.0-dev).
Part 2 evaluates Pipecat and the alternatives against Next Notes' constraints
(Swift 6 `.app`, on-device first, AGPL-3.0, 16 GB Macs, signed + eventually notarised).

All paths in Part 1 are relative to `roadmap/references/qwen-audio-agent-main/`.

---

## Part 1 — What qwen-audio-agent actually does

### 1.1 The one-sentence architecture

A **realtime "frontend" speech model** holds the conversation and has a tiny, bounded tool
set; anything that needs work is handed to **one backend action agent over ACP** through a
single tool (`spawn_thinking`) that returns a receipt in milliseconds. A **Gateway**
(`server/`) sits between them and owns every *fact* (turns, tasks, playback, delivery);
the models only own *expression*. Results come back through a scheduler that waits for a
safe gap in the duplex conversation and has the same voice say them.

> "Gateway 管系统事实，模型管理解与表达" — the Gateway owns system facts; the model owns
> understanding and expression. (`docs/voice-agent-architecture-presentation.zh.md`, "七项架构设计原则")

Layers (`docs/architecture/deep-dive.md` §1, §2, §9; `server/src/README.md`):

| Layer | What it is | Where |
|---|---|---|
| Clients | WebUI, TUI, Electron desktop orb. Capture mic, play audio, report playback receipts. | `web/`, `tui/`, `desktop/` |
| Gateway | Node process. Realtime WS to the model, turn state, interruption, task ledger, announcement scheduler, ACP backend process owner. | `server/src/` |
| Realtime frontend | A cloud or local model speaking the **OpenAI Realtime wire protocol** (GA or beta dialect). | `server/src/voice/providers/*` |
| Backend agent | One ACP agent (OpenCode, Qwen Code, Claude Code via adapter, Codex…) with its own tools/MCP/skills. A persistent "coordinator" session per owner; it may spawn independent sessions for long work. | `server/src/backend/`, `deep-dive.md` §4, §7, §8 |

Frontend models (`shared/realtime-model-catalog.mjs`, `server/src/voice/providers/`):
- DashScope `qwen-audio-3.0-realtime-plus|flash` (default; `turn_detection: smart_turn`),
  `qwen3.5-omni-flash|plus-realtime` (`turn_detection: semantic_vad`, image frames).
- Hugging Face **speech-to-speech** (`s2s.mjs`) — fully local VAD→STT→LLM→TTS exposed
  as an OpenAI Realtime GA endpoint; `turn_detection: { type: 'server_vad', interrupt_response: true }`.
- MiniCPM-o 4.5 (`minicpm-o.mjs`) — native full-duplex, but no function calls, no
  conversation items, no client-triggered responses, so **no task delegation and no
  proactive announcements** (`docs/voice-frontends/minicpm-o.md`, last paragraph). This is
  the key lesson about native full-duplex models: you lose the agent.

Audio path: client captures 16/24 kHz PCM → Gateway WS → provider WS
(`input_audio_buffer.append`); provider emits `response.audio.delta` → Gateway forwards
`AUDIO_DELTA` with `responseId` → client plays and sends `playback.started / ended /
cancelled` receipts back (`server/src/voice/realtime-gateway.mjs` ~L1740–1790).
Echo cancellation lives in the client: the macOS TUI uses **`kAudioUnitSubType_VoiceProcessingIO`
with playback rendered through the same unit**, so the far-end reference is exact
(`tui/native/macos-voice-io.swift` L220–330: "Bus 0 input is the far-end playback
reference; bus 1 output is the echo-cancelled microphone signal"). The WebUI uses
`getUserMedia({echoCancellation:true})` (`web/src/realtime/useRealtimeVoice.js` L873).
VAD/turn detection is delegated entirely to the provider (server_vad / semantic_vad /
smart_turn).

### 1.2 Frontend tools (the whole contract)

`server/src/frontend/frontend-tools.mjs`, `server/src/frontend/tools/features/agent-task-tools.mjs`,
`deep-dive.md` §3:

| Tool | Purpose |
|---|---|
| `spawn_thinking(objective, input_refs?)` | The **only** way to start backend work. Objective must be "faithful, complete and self-contained"; the backend never gets the frontend's chat history, persona or memory (`spawn-thinking-tool.mjs`). |
| `get_agent_task_status(task_id? \| list_all)` | Progress/lifecycle questions. Answered **from the Gateway's own Task record** (latest normalized backend message, recent activity, artifacts) — it does *not* ask the backend or create a task (`agent-task-runtime.mjs` L851–935; `deep-dive.md` §3 "A status check does not create another Task, invoke the coordinator, or enter the asynchronous announcement queue"). |
| `cancel_agent_task(task_id? \| series_id \| all)` | Cancel. Confirmed, not optimistic: task sits in `cancelling` until the stop is confirmed (`deep-dive.md` §7). |
| `respond_permission(permission_id?, decision: task\|always\|reject)` | Only exposed while a real permission is pending. |
| `respond_agent_input(task_id, action, text)` | Answer a backend follow-up question into the *same* task. |
| `get_current_time`, `notes`, `memory`, `schedule_reminder`, `web_search`, `fetch_url`, `recall`, `knowledge`, `enter_sleep` | Optional, cheap, frontend-owned tools. |

Admission rule for a frontend tool (`docs/frontend-agent-roadmap.md` §三, all four required):
**< 2 s latency, no multi-step orchestration, frontend-owned state, low risk / idempotent.**
Anything failing one criterion goes to the backend. Invariants (§五): the frontend never
gains orchestration, execution-policy or session selection; "双工语音全程可打断；后台排队/执行不阻塞对话"
(duplex speech interruptible throughout; backend queueing never blocks conversation).

### 1.3 Task lifecycle

- **Create**: `spawn_thinking` → `executeSpawnThinkingToolCall` (`agent-task-runtime.mjs` L288–505).
  Checks: pending permission blocks new work; backend availability comes from a **cached
  snapshot** ("this receipt only acknowledges intake, so it must not wait on ASR timing or a
  live backend round trip", L326–329); dedupe by `sha256(objective)` per turn; then writes
  an authoritative Task and returns `{status:'accepted', task_id, message:'工作已受理，请自然确认一次，不要再次调用工具。'}`
  ("accepted — confirm naturally once, do not call tools again"). A second spawn in the
  same turn from the follow-up response returns `duplicate` with `createResponse:false`.
- **State machine** (`server/src/task/task-state.mjs`): `scheduled → queued → running →
  (delegated → finalizing) → completed | failed | cancelling → cancelled`. Bounded
  concurrency: 4 global / 2 per owner (`core/config.mjs`), serial per coordinator session,
  and **delegation releases the coordinator slot** so long jobs don't block new requests
  (`deep-dive.md` §7).
- **Progress**: two channels, deliberately separated (`deep-dive.md` §6, `progress-announcement-manager.mjs`):
  1. *Activity* (tool names, plan steps) → UI cards / orb animation only. "Activity never
     produces spoken status updates."
  2. *Agent text messages* → `ProgressAnnouncementManager`, which coalesces them into
     **at most one spoken update per 60 s** (`intervalMs = 60_000`), first no earlier than
     60 s after the task started, debounced by a 350–800 ms quiet window, dropped if the
     user interrupts it ("Replaying the same monologue would be more disruptive than
     omitting it", L225).
- **Ask about progress**: `get_agent_task_status` (above). If the task already completed
  and its announcement is still pending, the status answer *consumes* the notification so
  it isn't said twice (`consumesTaskNotification`, L897–934).
- **Cancel**: see tool table; after a direct adapter abort the Gateway injects a
  cancellation fact into the next coordinator turn to reconcile its history.
- **Result return**: `AnnouncementManager` (`server/src/voice/announcement/announcement-manager.mjs`).

### 1.4 How results are injected ("It's ready")

Pipeline (`docs/voice-agent-architecture-presentation.zh.md` "结果交付必须服从双工会话状态"):
1. wait for the user to finish speaking;
2. wait for the current response and the client's audio queue to finish;
3. wait a short quiet window (`announcementQuietMs` = **350 ms**, `core/config.mjs` L438);
4. batch results that completed together (`batchWindowMs` 120 ms, ≤ 8 items, ≤ 6000 chars);
5. put the result facts into Realtime context;
6. let the *same persona* phrase them;
7. mark delivered only when the **client reports playback started**.

Mechanics:
- The gate is `AnnouncementWindow.isBlocked()` = `userSpeaking || turnPending || audioResponses.size > 0`
  (`announcement-window.mjs`). `turnPending` stays true while a user turn still awaits a
  tool follow-up, so a result never cuts in between a question and its answer.
- Injection = `conversation.item.create` with **`role: 'user'`** and an `input_text` body
  that starts "以下是你先前异步执行工作的最终更新，不是用户的新请求…不要提后台 Agent、协议或 Task，也不要读出 task_id"
  ("the following is the final update of work you previously started, *not a new user
  request*… don't mention the backend, protocol or task, don't read the id")
  (`formatWorkResults`, L462–477), followed by `response.create` with
  `tool_choice: 'none'` and per-response `instructions = resultResponseInstructions`
  (`providers/s2s.mjs` L106–118, `providers/dashscope.mjs` L108–120).
- `resultResponseInstructions` (`frontend-tools.mjs`): not a new request; treat result as
  facts; cover every item in a batch; **open with the actual result, blocker or question —
  no "OK / got it / task complete" filler**; if the screen already shows details, give the
  gist and where to look; never read ids/paths/URLs; no tools; don't call unfinished work finished.
- Delivery modes are provider-neutral values: `handle | context | respond | interrupt`
  (`server/src/delivery/agent-delivery.mjs`). Results use `respond`; only explicit
  gateway events use `interrupt` (cancels the current response first).
- Acknowledgement: `response.done` ≠ heard. Confirmation happens on `playback.started`
  (`realtime-presentation-runtime.mjs` `startPlayback` → `announcements.confirmMany`).
  If playback is cancelled **by user interruption** the result counts as delivered (the user
  chose to talk over it, and it's in context); if cancelled for any other reason it is
  retried with exponential backoff (1 s → 10 s, ≤ 8 attempts), context injected only once
  (`cancelPlayback`, `retryMany`, `scheduleRetry`). A 120 s acknowledgement timeout covers
  lost receipts but never fires while delivery is still blocked.
- Durability: results and notification state are persisted; a renewable claim prevents two
  frontends announcing the same result; unfinished announcements from an older session are
  recovered on reconnect (`deep-dive.md` §7, `task-notification-queue.mjs`).

### 1.5 Interruption / barge-in and dead air

- Barge-in is driven by the provider's `input_audio_buffer.speech_started`
  (`realtime-input-runtime.mjs` `#startSpeech`, L107–131): begin a new turn, **dismiss the
  active announcement batch**, send `PLAYBACK_CLEAR {reason:'user_interruption'}` to the
  client (which stops audio immediately and reports `playback.cancelled`), emit
  `voice.state: listening`, and `frontend.cancel()` → `response.cancel`. Pending queued
  responses are settled as cancelled; a 1 s grace covers cancel/complete races.
- Turn identity is guarded by turn ids + generations (`realtime-turn-state.mjs`,
  `turn-correlation.mjs`): late events from a superseded turn are dropped
  (`isStale`), invalidated turns (`reason: 'turn_invalid'`) discard their transcript.
- Single-slot providers (s2s) refuse concurrent `response.create`; the frontend re-queues
  transparently (`capabilities.singleResponseSlot`, `realtime-provider.mjs` L68–90, ~L897).
- **Dead air policy is the opposite of filler.** PROMPT.md: "不要承诺耗时或用话语填补等待，用户应当能够继续交谈"
  (don't promise durations or fill the wait with talk; the user should be able to keep
  talking) and "没有新信息时不要说话" (don't speak without new information). The only
  speech during a task is: one natural acknowledgement after `accepted`, optional ≤1/min
  progress, and the result. The "presence" is visual: the orb/pet `working` state and
  task cards (`deep-dive.md` §6). `voice.state: processing` is shown only for the
  *foreground* turn's synchronous tool call.
- Response guards: a model reply that contains a reserved protocol envelope is suppressed
  and re-asked once per user turn ("The budget belongs to the user turn, not a Response…
  must never become a self-sustaining response loop", `realtime-presentation-runtime.mjs`
  `#requestGuardCorrection`).

### 1.6 The local speech-to-speech integration

`server/src/voice/providers/s2s.mjs` + `docs/voice-frontends/speech-to-speech.md`. The
Gateway treats HF speech-to-speech as just another OpenAI-Realtime endpoint at
`ws://127.0.0.1:8765/v1/realtime`; it doesn't manage the models. Apple Silicon launch:
`speech-to-speech --stt paraformer --llm_backend mlx-lm --device mps`. Adaptations:
`acknowledgesSessionUpdate:false`, `singleResponseSlot:true`,
`responseMetadataCorrelation:true`, `perResponseInstructions:true`, and a
`responseStartTimeoutMs` raised to **60 s** because "fully local ASR -> LLM -> TTS can
take substantially longer than a cloud model before producing its first response event".

Upstream s2s (Apache-2.0) latency tricks: four stages each on its own thread connected by
queues; LLM streams to TTS by sentence fragment; Smart-Turn validates VAD endpoints;
tunable `--thresh`, `--min_silence_ms`, `--speculative_reopen_ms`; optional compile;
`--mac-optimal-settings` = Parakeet-TDT MLX + 4-bit Qwen3-4B (mlx-lm) + 6-bit Qwen3-TTS,
~7.5 GB of weights; TTS options include Kokoro-82M and **Pocket TTS** (the same voices
Next Notes ships). Speech resuming during a response triggers turn revision and discards
unplayed output. No published latency numbers.

### 1.7 Frontend prompt — key rules (`config/frontend-agent/PROMPT.md`, translated)

- Identity: "a unified assistant in full-duplex voice with the user… never describe yourself
  as a frontend model, backend model or chat-only assistant; never expose Agent, queue,
  Session, tool names or internal routing."
- Routing: answer directly when the conversation suffices; use a dedicated tool when one
  matches; call `spawn_thinking` when backend execution is needed. **"If you judge the work
  will end up in the backend, don't first do exploratory frontend searches and then hand
  off."** Don't go to the backend merely because several tool calls are needed.
- "It is a capability if a registered tool can do it: call it; don't first say you can't."
- **"Don't speak before calling `spawn_thinking`."** `accepted` only means received;
  `duplicate` means already submitted; after all receipts, **confirm naturally once and call
  no more tools. Don't promise durations or fill the wait with speech.**
- Results arrive in a separate result context: relay the actual result, blocker or
  question; don't expose internals; don't call progress a result. Progress updates: relay
  only the new part, briefly, no tools.
- Status/progress/list questions → `get_agent_task_status`, never guess from history.
  Cancel → call `cancel_agent_task` without speaking first; until it returns, only say
  "cancelling".
- Voice: "avoid empty acknowledgements, repeating the request, thanking for waiting,
  promising updates, or filling silence. **When there is no new information, don't
  speak.**" Never read ids, paths, URLs, ports, hashes, timestamps, long numbers.
- Persona file (`ASSISTANT.md`): "say the key point first, concise and natural; expand only
  when a complex question needs it."

### 1.8 Patterns worth copying into Next Notes (ranked)

1. **Receipt-first delegation.** The delegation tool returns in ms from cached state;
   the frontend is instructed to stay silent before the call and speak exactly one
   acknowledgement after. Next Notes' `VoiceConversationCoordinator` already routes
   `newWork/revise/cancel` via an envelope; the missing half is the prompt discipline
   ("don't speak before", "one ack", "no filler") and a hard guard that the frontend's
   reply to a delegation is ≤ 1 clause.
2. **Result delivery as a first-class scheduler** with the 7-step gate above. Compare with
   Next Notes today: `AgentTaskManager.announce` → `VoiceAnnouncementQueue.enqueue`
   speaks the **raw result's first two clauses** (or a fixed fallback sentence) via
   `RealtimeAudioSession.speak` (`Sources/NextNotes/Agent/VoiceAnnouncementQueue.swift`,
   `Sources/NextNotes/Agent/Tasks/AgentTaskManager.swift` L310–320). Differences worth
   closing: (a) have the frontend model *phrase* the result from a "not a new request"
   context item with `resultResponseInstructions`-style rules; (b) a short quiet window
   (~350 ms) after the floor frees; (c) batch simultaneous completions; (d) treat a
   user-interrupted announcement as delivered (it's in context) instead of replaying the
   clause — Next Notes currently re-queues interrupted clauses; (e) confirm on first
   audible frame, not on enqueue; (f) let a status question consume a pending
   announcement.
3. **Status from the ledger, not from the worker.** `get_agent_task_status` reads the
   task record (latest message, activity, artifacts) — zero model latency on the worker
   side, never contends for the worker's context. Next Notes feeds job status into the
   frontend prompt; keep that, but make the task record carry a bounded
   `latestUpdate` fed by the worker's narration.
4. **Two progress channels**: tool activity → island/orb only; worker narration → ≤1
   spoken line per 60 s, dropped on interruption.
5. **`AgentDelivery` modes** (`handle/context/respond/interrupt`) as the single seam
   for everything the agent may say unprompted (results, permissions, reminders, meeting
   events). Only `interrupt` may cut the user off.
6. **Frontend tool admission rule** (<2 s, single call, own state, low risk) as a written,
   testable boundary — directly applicable to what the on-device frontend may do itself.
7. **Self-contained objective**: the worker never sees persona, memory or chat history;
   the frontend resolves references into the objective. Keeps the worker's prefill small
   (important with a 4B local model).
8. **Turn ids + generations** on every response/tool result so stale output is dropped
   — Next Notes already has `inputEpoch`/`responseID`; keep them as the spine.
9. **Echo cancellation via Apple's VoiceProcessingIO with playback through the same
   unit** (`tui/native/macos-voice-io.swift`). Next Notes has SpeexDSP + an AEC3 probe
   and `AcousticEchoProbe` already tries `setVoiceProcessingEnabled`; the reference's
   point is that AEC quality is dominated by having the exact playback reference.
10. What *not* to copy: the multi-process Gateway/ACP topology and the cloud frontend as
    default. Next Notes is a single signed process with in-process models; the patterns
    port, the process layout does not.

---

## Part 2 — Options for Next Notes

### 2.0 What "full duplex" can mean here

- **Transport duplex** (mic keeps streaming while the agent speaks, AEC + barge-in):
  achievable with any cascade; Next Notes already has most of it.
- **Conversational concurrency** (talk while tools/agents run, results return
  naturally): an orchestration problem, framework-independent — this is what
  qwen-audio-agent solves and what the user mostly means.
- **Model-level full duplex** (one model listens and speaks simultaneously, backchannels,
  overlaps): Moshi, MiniCPM-o, PersonaPlex, GPT-realtime/Gemini Live partially. Today these
  trade away tool calling or run in the cloud.

Rough latency budget for a local cascade on Apple Silicon (voice-to-voice, end of user
speech → first audible sample): endpointing 150–400 ms (VAD silence + turn model) +
ASR finalisation 30–100 ms (streaming Parakeet already has the text) + LLM TTFT 150–400 ms
(3–4B, warm KV prefix) + first TTS chunk 80–250 ms + audio I/O 20–40 ms ≈ **0.45–1.2 s**.
Pipecat's reference macOS stack reports "<800 ms" with Gemma-3n-4B/MLX Whisper/Kokoro
(kwindla/macos-local-voice-agents). Cloud speech-to-speech (gpt-realtime, Gemini Live)
lands around 0.3–0.8 s including network. Framework choice moves none of these terms much;
**endpointing and LLM TTFT dominate**, and both are model/config decisions.

### 2.1 Option (a) — Pipecat

**What it is.** `pipecat-ai/pipecat`, **BSD-2-Clause**, Python ≥ 3.11. A pipeline of
`FrameProcessor`s passing typed frames (audio, text, LLM tokens, control); system frames
(`InterruptionFrame`/`StartInterruptionFrame`, `UserStartedSpeakingFrame`,
`BotStartedSpeakingFrame`…) jump the queue so an interruption flushes every downstream
processor's buffers. Transports: SmallWebRTC (serverless local WebRTC), WebSocket,
Daily/LiveKit, local audio. Services include Whisper (incl. MLX), Parakeet-MLX, Kokoro,
Piper, Ollama and any OpenAI-compatible LLM (llama.cpp server, LM Studio), mlx-audio TTS,
OpenAI Realtime and Gemini Live as speech-to-speech services. `ParallelPipeline`,
Pipecat Flows (state machine conversations), multi-agent fan-out/sidecars.

**Function calling while speaking.** Documented behaviour (docs.pipecat.ai
"Function Calling"): with `cancel_on_interruption=False` a call is *async* — "the
conversation is not held while the function runs"; results that return quickly settle as
normal tool results; if the conversation has moved on, the result "is injected back into
the context as a developer message, triggering a new LLM inference at that point".
Intermediate updates via `FunctionCallResultProperties(is_final=False)`. Assistant filler
spoken with `TTSSpeakFrame` does not count as "moving on". This is the same idea as
qwen-audio-agent's announcement, but *without* the floor-aware quiet window, batching or
playback-start acknowledgement — those you'd still write yourself. Open issues show the
edges are still being worked (e.g. #5779 "Interrupting the bot right as it calls a tool can
leave the tool call stuck 'in progress'", #5683 transcription dropped by its own turn's
interruption, PR #5705 deferral rules).

**Smart Turn.** `pipecat-ai/smart-turn` v3.x, BSD-2-Clause, 8 M params (Whisper-tiny
encoder + linear head), audio-only (prosody, not text), last ≤ 8 s of 16 kHz mono, 23
languages, 8 MB int8 / 32 MB fp32 ONNX. Runs once per VAD pause. A **CoreML export
already exists**: `aufklarer/Smart-Turn-v3.2-CoreML` (BSD-2 weights; the Apache-2.0
`soniqo/speech-swift` package wraps it) with the log-mel front-end baked in — 3.5 ms per
window on M5 Pro (CoreML) vs ~20 ms ONNX fp32/4 threads, 92.9 % on 1 000 upstream eval
clips (soniqo.audio/guides/turn). This is the single most transplantable Pipecat asset.

**Feasibility as a bundled sidecar in the signed .app.**
- Runtime: embed python-build-standalone or a PyInstaller/Briefcase build. Pipecat + silero
  (onnxruntime) + mlx + mlx-whisper/mlx-audio + aiortc/websocket deps ≈ 250–500 MB before
  models (estimate; torch pushes it past 1 GB — avoid). Next Notes already ships FluidAudio
  Parakeet/Kokoro/Pocket and llama.cpp, so the Python side would *duplicate* the model
  stack or have to call back into Swift for it.
- Codesigning/notarisation: every `.so`/`.dylib` must be signed inside-out with the
  hardened runtime; some wheels need `allow-unsigned-executable-memory` or
  `disable-library-validation` entitlements; `--deep` is unreliable (Apple forums,
  Spyder/PyInstaller notes). Doable, but a permanent release-engineering tax on a project
  whose AGENTS.md already documents how fragile signing/TCC is (every re-sign invalidates
  grants; a second executable is a second TCC identity — the microphone grant would belong
  to whichever process opens the mic).
- Startup: Python import of pipecat + mlx is seconds; first model load 10–30 s ("30 seconds
  or more" in the kwindla repo on first run). Next Notes already fights cold starts
  (Parakeet 11 s cold).
- IPC: WebRTC (aiortc) or a local WebSocket carrying PCM + JSON events between Swift and
  Python. Adds a hop, clock-domain issues and one more place for the AEC reference to
  drift — and AEC must stay in Swift (it needs the real output device).
- Memory on 16 GB: a second copy of ASR/TTS/LLM in MLX next to the Swift ones is not
  viable; you would move *all* voice models to Python, discarding working, tested Swift
  code (EOU, Speex/AEC3, Pocket/Kokoro session code, self-tests).
- Licence: BSD-2 is AGPL-compatible. Fine.

**Porting its architecture into Swift instead.** Pipecat's valuable ideas are small:
typed frames on one async stream per stage; system/control frames that bypass data queues;
an interruption that flushes every stage's buffer and cancels in-flight generation; turn
analyzer = VAD + smart-turn; async tools with deferred-result injection; observers for
latency metrics (`TurnTrackingObserver`, TTFB per service). In Swift 6 these map onto
`AsyncStream` stages with a separate high-priority control channel, `Task` cancellation,
and actors — Next Notes already has most primitives (`withBoundedWait`, epochs,
`RealtimePCMFloatRing`, `AgentSpeechSynthesizer.PlaybackEvent`).

**Verdict (a):** don't ship Pipecat; **steal smart-turn (CoreML) and the async-tool /
interruption-frame semantics**. Sidecar cost (size, signing, TCC, startup, duplicated
models, IPC) buys no latency the Swift stack can't reach, and the hard part (floor-aware
result delivery) isn't in Pipecat either.

### 2.2 Option (b) — other frameworks and models

| Candidate | Licence | On-device Apple Silicon | Tool calling / agent | Latency | Fit |
|---|---|---|---|---|---|
| **LiveKit Agents** | Framework Apache-2.0; **turn-detector weights under "LiveKit Model License": "not to use any LiveKit Models on a standalone basis or with any frameworks other than LiveKit Agents"** | Python/Node; expects a LiveKit SFU (or console mode) | Yes | similar to Pipecat | Poor: server-shaped, Python, and its best asset's licence is restricted. Exclude the turn model. |
| **HF speech-to-speech** | Apache-2.0 | Yes via MLX (`--mac-optimal-settings`, ~7.5 GB weights) | Tool calls over its Realtime-GA server | not published; qwen-audio-agent needed a 60 s response-start timeout for local mode | Useful as a *reference* (threads+queues, sentence streaming, `speculative_reopen_ms`, smart-turn). Same Python-sidecar problems as Pipecat. |
| **Kyutai Moshi / moshi-mlx** | code MIT/Apache, weights CC-BY-4.0 | Yes (MLX) | **No tool calling**; 7B, weak reasoning | ~160 ms theoretical, ~200 ms on L4 | Real model-level duplex, but can't be the agent. At most a "chit-chat" persona — not worth 7B of RAM. |
| **Kyutai Unmute** | STT/TTS models CC-BY-4.0; wraps any text LLM | Reference servers are CUDA; community MLX bridge exists (nwalker85/unmute-mlx-bridge) | Yes (via the text LLM) | low | Architecturally identical to what Next Notes already is (streaming STT + LLM + streaming TTS). Nothing to adopt beyond ideas. |
| **NVIDIA PersonaPlex** (via speech-swift) | check model licence (NVIDIA open model terms) | Yes, RTF ~0.94 on M2 Max | No | full duplex | Too heavy, barely real-time, no tools. |
| **MiniCPM-o 4.5** | code Apache-2.0, weights under MiniCPM model licence (commercial use needs registration) | Local server | No structured function calls in its realtime protocol (per qwen-audio-agent docs) | full duplex | Exactly the failure mode: qwen-audio-agent lost delegation and announcements with it. |
| **Qwen3.5-Omni Realtime** | DashScope cloud API | No (cloud). Open-weight Omni models are 7B–30B-A3B, too big for a 16 GB Mac beside everything else | Yes, `semantic_vad` | cloud-class | Cloud opt-in only; China-hosted endpoint is a privacy/data-residency question for a notes app. |
| **OpenAI Realtime (gpt-realtime-2.x)** | proprietary API | cloud | Yes; **async function calling built in** ("the model can continue a fluid conversation while waiting on results"), `semantic_vad` | ~0.3–0.8 s | Best cloud opt-in frontend; same wire protocol qwen-audio-agent targets. |
| **Gemini Live API** | proprietary API | cloud | Yes; `behavior: NON_BLOCKING` functions and per-response `scheduling: INTERRUPT \| WHEN_IDLE \| SILENT` — i.e. announcement policy in the API. Caveat: "not yet supported in Gemini 3.1 Flash Live", only 2.5 Flash Live preview | ~0.3–0.8 s | Good opt-in; its three scheduling modes are a neat vocabulary to copy locally (≈ qwen's interrupt/respond/context). |
| **Smart Turn v3.2 standalone** | BSD-2 | **Yes — CoreML export, 3.5 ms/window** (or ONNX via onnxruntime, MIT) | n/a | shaves the fixed silence timeout | **Adopt.** |
| **FluidAudio** (already a dependency) | Apache-2.0 | Yes | n/a | Parakeet TDT batch ~190× RTF; Parakeet **EOU 120M streaming (English only)**; Silero VAD CoreML (256 ms hop); Kokoro 3–11× RTFx; **PocketTTS streaming**; streaming diarization | Keep as the core. No smart-turn today. |
| **soniqo/speech-swift** | Apache-2.0 | Yes (CoreML/MLX) | has a `VoicePipeline` state machine (VAD turns, interruption, eager STT), Silero, Smart Turn v3.2, DeepFilterNet3, LocalVQE AEC | — | Take the Smart-Turn CoreML model and, optionally, study its `VoicePipeline`; don't adopt wholesale (overlaps FluidAudio). |
| **sherpa-onnx** (already dlopen'd for KWS) | Apache-2.0 | Yes (CPU ONNX) | n/a | Silero VAD, streaming zipformer, Kokoro | Could host an ONNX smart-turn only via raw onnxruntime; CoreML route is simpler. |

### 2.3 Option (c) — Hybrid (recommended)

Keep native Swift audio I/O and on-device ASR/TTS/LLM; adopt Pipecat's *pipeline
semantics* and qwen-audio-agent's *frontend/backend task split and delivery scheduler*;
add a cloud realtime frontend as an explicit opt-in that plugs into the same seams.

Concretely:

1. **Turn-taking** — Silero/Parakeet-EOU as the fast gate, **Smart Turn v3.2 CoreML** as
   the arbiter on each pause (8 s window, ~4 ms). Lets `eouDebounceMs`/silence thresholds
   drop (today `StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: 320)` in
   `Sources/NextNotes/Activation/LocalVoiceTurnDetector.swift`) without cutting people off,
   and works in the 23 languages Parakeet-EOU (English-only) doesn't. Per AGENTS.md
   convention: a `--selftest-smart-turn` that fails on a mid-sentence pause fixture
   classified as complete. Keep the "a gate may only add, never subtract" rule — smart-turn
   decides *when*, never *whether* the model hears the user.
2. **Frame semantics in Swift** — one control channel (interrupt, user-started,
   bot-started/stopped, playback-started acks) that bypasses data queues; interruption =
   cancel LLM task + flush TTS queue + clear the PCM ring in one step; every emitted chunk
   carries (turn id, generation). Mostly a naming/structuring pass over what
   `AgentCaptureController`, `RealtimeAudioSession`, `AgentSpeechSynthesizer` already do.
3. **Frontend/backend split, qwen style** — the on-device frontend (Foundation Models or
   the small GGUF) gets a fixed, tiny tool set: `delegate(objective)`, `task_status`,
   `cancel_task`, `respond_permission`, plus <2 s own-state tools. `delegate` returns a
   receipt synchronously; prompt rules "don't speak before delegating / one ack / no
   filler / don't speak without new information" copied almost verbatim. The worker
   (`RealtimeAgent` voice worker / tool loop) receives only the self-contained objective.
4. **Delivery scheduler** — upgrade `VoiceAnnouncementQueue` into an `AgentDelivery`
   scheduler with modes `context | respond | interrupt` (≈ Gemini's SILENT/WHEN_IDLE/INTERRUPT),
   gate = user floor ∨ pending turn ∨ audio queued, 350 ms quiet window, 120 ms batching,
   model-phrased results under result-specific instructions, ack on first played clause,
   interrupted ⇒ delivered-in-context, bounded retries, status query consumes pending
   announcements, progress ≤ 1/60 s.
5. **Model residency** — the frontend must never wait behind the worker's model. AGENTS.md
   already records the single native Foundation-Models context and the scheduler-ticket
   ordering; the hybrid keeps frontend and worker on separate engines (e.g. frontend =
   Foundation Models, worker = GGUF via llama.cpp, or vice versa) so a delegation never
   blocks the next reply.
6. **Opt-in cloud frontend** — an `OpenAI Realtime` / `Gemini Live` provider implementing
   the same frontend protocol (inject context item, create response with per-response
   instructions, cancel, speech_started). Local AEC/capture stays in Swift; the cloud model
   replaces local ASR+frontend-LLM+TTS; the local worker and delivery scheduler are
   unchanged. Needs explicit consent (audio leaves the Mac), a Keychain-stored key, and a
   grounding rule that the cloud frontend sees only what the local-vs-cloud brief policy
   already permits (AGENTS.md "a brief allowed for a local reader is not allowed for a
   cloud one").

### 2.4 Comparison

| | (a1) Pipecat sidecar | (a2) Port Pipecat into Swift | (b) Native duplex model (Moshi/MiniCPM-o) | (b') Cloud realtime only | **(c) Hybrid** |
|---|---|---|---|---|---|
| Voice-to-voice latency | ~0.6–1.0 s local (their macOS demo <0.8 s) + IPC hop | ~0.5–0.9 s local | ~0.2 s | ~0.3–0.8 s | ~0.5–0.9 s local; ~0.3–0.8 s with cloud opt-in |
| Talk while tools run | yes (async tools), delivery policy DIY | yes, you write it | **no tools** | yes (OpenAI async fn; Gemini NON_BLOCKING) | yes, with qwen-grade delivery |
| Effort | high (bundle, sign, IPC, move all models) | medium | high, dead end | medium | **medium, incremental on existing code** |
| Risk | high: notarisation, TCC identity, 16 GB RAM, cold start, two runtimes | medium | high | medium (cost, outages) | low–medium |
| Licence | BSD-2 OK | n/a | CC-BY / custom model terms | proprietary APIs (not distributed) | BSD-2 (smart-turn) + Apache (FluidAudio/speech-swift) |
| Privacy | local | local | local | audio to cloud | local default, cloud opt-in |
| Fit with existing Swift | poor (replaces it) | good | poor | good as a provider | **best** |

### 2.5 Recommendation

**Do not adopt Pipecat (or LiveKit, or s2s) as a runtime. Build option (c).** The
lag/blocking the user feels is not a transport problem that a Python framework fixes; it is
(1) conservative endpointing, (2) the frontend waiting on or contending with the worker's
model, and (3) results that are spoken as raw text at an unmanaged moment. Pipecat's own
answer to (3) is thinner than qwen-audio-agent's, and adopting it would cost a second
runtime, a second TCC identity, duplicated models on a 16 GB machine and a notarisation
burden — to reach latencies the in-process Swift stack can already reach.

Take from Pipecat: **Smart Turn v3.2 (CoreML, BSD-2)**, the control-frame/interruption
discipline, async-tool deferred-result semantics, and per-stage TTFB observers. Take from
qwen-audio-agent: the receipt-first `spawn_thinking` contract, the ledger-backed status
tool, the two progress channels, the `AgentDelivery` modes and the 7-step floor-aware
announcement scheduler with playback-start acknowledgement, and the frontend prompt's
"no filler, no speech without new information" rules. Add OpenAI Realtime (first) and
Gemini Live (second, once NON_BLOCKING reaches the current Flash Live model) as opt-in
frontends behind the same seam, for users who want sub-500 ms and accept cloud audio.
Treat Moshi-class native full-duplex models as a watch item until one ships tool calling
at ≤ 4B.

Suggested order: (1) smart-turn gate + latency observers (measure before/after with a
`--selftest-voice-latency` that prints per-stage TTFB); (2) delivery scheduler rewrite of
`VoiceAnnouncementQueue` with model-phrased results; (3) frontend prompt + tool contract
tightening; (4) cloud realtime provider.

---

## Sources

Local: `roadmap/references/qwen-audio-agent-main/` — README.md; docs/architecture/deep-dive.md;
docs/voice-agent-architecture-presentation.zh.md; docs/frontend-agent-roadmap.md;
docs/voice-frontends/{speech-to-speech,qwen-omni-realtime,minicpm-o}.md; docs/guides/tasks.md;
config/frontend-agent/{PROMPT,ASSISTANT}.md; server/src/frontend/frontend-tools.mjs;
server/src/frontend/tools/{spawn-thinking-tool,agent-task-runtime,tool-call-handler}.mjs;
server/src/frontend/tools/features/agent-task-tools.mjs; server/src/delivery/agent-delivery.mjs;
server/src/voice/announcement/*.mjs; server/src/voice/{realtime-presentation-runtime,realtime-provider,realtime-input-runtime,realtime-gateway,realtime-agent-delivery-runtime}.mjs;
server/src/voice/providers/{s2s,dashscope}.mjs; server/src/task/task-state.mjs; server/src/core/config.mjs;
shared/realtime-model-catalog.mjs; tui/native/macos-voice-io.swift; web/src/realtime/*.js.
Next Notes: Sources/NextNotes/Agent/{VoiceAnnouncementQueue,VoiceConversationCoordinator,VoiceConversationWork,VoicePlaybackDelivery}.swift;
Sources/NextNotes/Agent/Tasks/AgentTaskManager.swift; Sources/NextNotes/Activation/{LocalVoiceTurnDetector,AgentCaptureController}.swift; Package.swift.

Web:
- [pipecat-ai/pipecat](https://github.com/pipecat-ai/pipecat) · [Pipecat function calling](https://docs.pipecat.ai/pipecat/learn/function-calling) · issues [#5779](https://github.com/pipecat-ai/pipecat/issues/5779), [#5683](https://github.com/pipecat-ai/pipecat/issues/5683), PR [#5705](https://github.com/pipecat-ai/pipecat/pull/5705)
- [pipecat-ai/smart-turn](https://github.com/pipecat-ai/smart-turn) · [pipecat-ai/smart-turn-v3 (HF)](https://huggingface.co/pipecat-ai/smart-turn-v3) · [Soniqo Smart Turn v3.2 CoreML guide](https://soniqo.audio/guides/turn) · [soniqo/speech-swift](https://github.com/soniqo/speech-swift)
- [kwindla/macos-local-voice-agents](https://github.com/kwindla/macos-local-voice-agents)
- [huggingface/speech-to-speech](https://github.com/huggingface/speech-to-speech)
- [LiveKit turn-detector licence](https://huggingface.co/livekit/turn-detector/blob/main/LICENSE) · [LiveKit turn detector docs](https://docs.livekit.io/agents/logic/turns/turn-detector/)
- [kyutai-labs/moshi](https://github.com/kyutai-labs/moshi) · [moshi-mlx](https://pypi.org/project/moshi-mlx/) · [unmute-mlx-bridge](https://github.com/nwalker85/unmute-mlx-bridge)
- [Gemini Live tools / async function calling](https://ai.google.dev/gemini-api/docs/live-tools)
- [Introducing gpt-realtime](https://openai.com/index/introducing-gpt-realtime/) · [OpenAI Realtime VAD](https://developers.openai.com/api/docs/guides/realtime-vad)
- [FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio)
- Codesigning Python in .app: [Spyder codesigning notes](https://github.com/spyder-ide/spyder/wiki/Dev:-Codesigning-the-macOS-Standalone-Application), [Apple forum 744471](https://developer.apple.com/forums/thread/744471)

Figures marked "estimate" (Python bundle size, cascade budget per stage) are reasoned, not measured.
