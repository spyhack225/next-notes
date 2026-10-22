# C: Voice agent concurrency, what blocks what

> **Historical model assumptions — revised 2026-09-30:** this completed plan/audit
> preserves its dated measurements and implementation history. For new work, follow
> the [independent-role/shared-file contract](../../in-progress/SHARED-BRAIN/00-README.md): Meetings, Agent and cleanup
> may use different appropriate models; exact verified artifacts are reused, with
> workload-specific consent and request ownership. Agent-only file selection,
> universal model defaults and deletion based only on the Agent are superseded.
> MiniCPM cleanup + Apple guard/fallback is concurrent work, not evidence that this
> historical build used it. Re-measure quality/latency on the actual current engine.

Scope: the macOS voice agent in Next Notes. This is a read-only analysis. No source was edited and nothing was built or launched.
All paths are relative to `Sources/NextNotes/` unless noted. Line numbers are from the working tree on 2026-09-23.

---

## 0. Summary

The voice agent already has the *shape* of a two-layer system:

- the conversational frontend is Apple Foundation Models (`LocalVoiceFrontend`);
- background objectives are llama.cpp tool loops (`VoiceConversationCoordinator.submit` → a private `RealtimeAgent(voiceWorker:)`);
- a result is announced by `VoiceAnnouncementQueue`.

It still feels blocking because eight mechanisms couple the two layers again. Six of them are policy, not physics:

1. **One global compute slot.** `ComputeScheduler` has a single `running` job for the whole process (`Core/Compute/ComputeScheduler.swift:85-87`). A frontend turn and a worker's tool-loop round never run at the same time. The frontend preempts the worker (the worker parks at its next token or prefill chunk), and the worker is paused for as long as the frontend is generating.
2. **The voice prewarm holds the frontend's own priority class.** On the first committed utterance, `prewarmWorkerModel` loads the 4B GGUF through `prepareForConversation(workClass: .realtimeAgent)` (`Formatting/LLM/NotesModelRuntime.swift:326`). Preemption is strict `<` (`Core/Compute/ComputeJob.swift:45-47`), so the next frontend turn queues behind a cold load of 11–25 s. That wait counts against the frontend's 25 s deadline (`Agent/VoiceConversationCoordinator.swift:437-438`).
3. **The effect barrier gates thinking, not only effects.** Every planner round and every tool call in a worker first awaits `waitForVoiceInput()` (`Agent/RealtimeAgent+ToolLoop.swift:864, 915, 954, 1000`). For a worker, that is `VoiceConversationCoordinator.waitForInputResolution`, a 20 ms poll on `inputPending` (`VoiceConversationCoordinator.swift:259-263`). `inputPending` rises on any 120 ms of mic energy (`Activation/AgentCaptureController.swift:893-901`). On the answer route it only clears **after the frontend has generated its whole answer** (`VoiceConversationCoordinator.swift:497`). So chatting with the agent pauses all background work, and asking "how's it going?" slows the work down.
4. **A frontend failure leaves the barrier closed on purpose** (`VoiceConversationCoordinator.swift:572-574`). After a deadline, malformed, empty or model-error turn, every background job freezes until the user says something valid or presses Done. The idle close is also disabled while a job is running (`AgentCaptureController.swift:1272-1281`), so the mic stays open and nothing happens.
5. **One llama native context** (`NotesModelRuntime.swift:698-715`) is shared by meeting notes, typed agent turns, dictation cleanup on the app LLM, and every voice worker. The reservation is FIFO by priority and not preemptible, so a voice worker waits behind a multi-minute notes generation. N voice jobs run their planner rounds one after another.
6. **Announcements are dumb and lossy.** A result is spoken verbatim, first two clauses only (`Agent/VoiceAnnouncementQueue.swift:45-50`). It is not phrased by the frontend. It is dropped if the session is not open (`:12-15`) and cleared on session end (`AgentCaptureController.swift:360`). The flush ignores `inputPending` and has no post-speech hold-off.
7. **ACP/coding tasks are invisible to voice.** Voice never reaches the harness router (`Agent/RealtimeAgent.swift:208-211` returns into the coordinator, which only submits local tool loops). `AgentTaskManager` tasks are not in the frontend's work status (`VoiceConversationCoordinator.swift:666-685`). They cannot be queried, cancelled or approved by voice.
8. **There is no spoken permission path.** `PermissionGate` answers only from UI cards (`Agent/Permissions/PermissionGate.swift`, callers in `UI/Agent/AgentView.swift:285-296`). Worse, a spoken correction to a job cancels its pending approval (`VoiceConversationCoordinator.swift:347, 525`).

Two items are physics:

- the single llama context rules out parallel workers;
- on a 16 GB Mac, running Foundation Models and a 4B Metal decode concurrently will contend for the GPU and ANE.

Neither makes duplex *conversation* impossible, because conversation and planning already use different models. What would make duplex impossible is putting both on the one llama context. That is not the design today, but it becomes the design whenever Apple Intelligence is unavailable: there is no fallback conversational lane (`VoiceConversationCoordinator.swift:415-422`).

---

## 1. The concurrency map

### 1.1 Isolation domains

| Domain | Type | Owns | File |
|---|---|---|---|
| **MainActor** | — | Everything below except the three actors. The VAD tick, turn commit, frontend orchestration, worker tool loops (between awaits), session persistence and TTS scheduling all share one executor. | — |
| `AgentCaptureController` | `@MainActor` class | Session lifetime (`isSessionActive`, `captureSessionID`), turn state (`heardSpeech`, `speechBeganAt`, `transcript`, `committedPrefix`, `turnEpoch`, `turnGeneration`, `acousticFloorHeldForTurn`), `vadTask` (100 ms loop), `activeTurnTask` (**one slot**), `turnDetectorTask`, `feedTask`, `consumeTask` | `Activation/AgentCaptureController.swift:92-213` |
| `VoiceConversationCoordinator` | `@MainActor` class | `inputPending` / `inputEpoch` (**the effect barrier**), `responseTask` + `responseID` (**one slot**), `preparationTask` / `preparationEpoch` (speculation debounce), `jobs[]` (background objectives), `pendingIntent`, `clarifiedTexts` | `Agent/VoiceConversationCoordinator.swift:9-40` |
| `RealtimeAgent.shared` | `@MainActor` class | `generation`, `speechGeneration`, `isThinking`, `voiceInputActive`, `localModelTask` (**one slot**), `voiceWork` | `Agent/RealtimeAgent.swift:17-122` |
| `RealtimeAgent(voiceWorker:)` × N | `@MainActor` class | One per job: its own `generation` and `voiceWork` | `Agent/RealtimeAgent.swift:125-162` |
| `RealtimeAudioSession` | `@MainActor` class | `phase`, `isSpeaking`, `listeningHold`, **one** `StreamingSpeechBuffer`, echo references | `Agent/RealtimeAudioSession.swift:39-105` |
| `AgentSpeechSynthesizer` | `@MainActor` class | Clause queue, `outputGeneration`, pause/resume | `Agent/Speech/AgentSpeechSynthesizer.swift:21` |
| `VoiceAnnouncementQueue` | `@MainActor` class | `pending[]`, `inFlight` | `Agent/VoiceAnnouncementQueue.swift` |
| `VoicePlaybackDelivery` | `@MainActor` class | Per-turn clause acknowledgements → `AgentSession.updateSpeech` | `Agent/VoicePlaybackDelivery.swift` |
| `AgentTaskManager` | `@MainActor` class | Persisted task list, `running[id]` Tasks, ACP/local backend execution, `announce` | `Agent/Tasks/AgentTaskManager.swift` |
| `PermissionGate` | `@MainActor` class | **One visible** `pending` request and an ordered queue | `Agent/Permissions/PermissionGate.swift:4-33` |
| `AgentSession` | `@MainActor` class | Conversation rows. **Synchronous JSON encode and atomic write on every append** (`RealtimeAgent.swift:1199-1214`) and on every changed speech-delivery snapshot (`:1134-1141`) | `Agent/RealtimeAgent.swift:813-1251` |
| **`ComputeScheduler`** | actor | **One `running` job process-wide**, plus `queued` and `parked` lists. Classes: realtimeAudio 0 < realtimeASR 1 < realtimeAgent 2 < meetingLive 3 < background 4 | `Core/Compute/ComputeScheduler.swift:79-251`, `Core/Compute/ComputeJob.swift:21-47` |
| **`LocalVoiceFrontend`** | actor | Foundation Models sessions, `speculation` (one slot), `drainBarrier` / `nativeGeneration` (**strictly serial FM inference**; a new stream waits ≤ 2 s for the previous one to stop) | `Formatting/LLM/LocalVoiceFrontend.swift:9-479` |
| **`NotesModelRuntime`** | actor | llama `model` / `context` (**one native context**), `nativeOwner` + `nativeWaiters` (reservation), `loadTask`, `conversationLeases`, idle unload | `Formatting/LLM/NotesModelRuntime.swift:28-110, 656-720, 884-894` |

### 1.2 Lock and wait order

```
NotesModelRuntime.withLane(workClass):              NotesModelRuntime.swift:662-694
    reserveNativeContext   (FIFO by class, NOT preemptible, cancellable while waiting)
      → ComputeScheduler.acquire(workClass)   (preemptive by class; park at checkpoint)
          → loadIfNeeded → awaitCleanupIdle → checkpoint → openNative (blocking, 11–25 s cold)
                                                               NotesModelRuntime.swift:1180, 1183, 1204
          → prefill in 128-token chunks, checkpoint per chunk      :472-493
          → decode, checkpoint per token                           :612-651
      ← release lane
    ← release native (next waiter = lowest priority number)        :884-894

LocalVoiceFrontend.unsharedStream:                  LocalVoiceFrontend.swift:342-479
    wait ≤2 s for previous FM inference (drain barrier)            :312-316, 350
      → prepare() (first time: acquire .realtimeAgent, 12-token warm decode)   :241-275
      → ComputeScheduler.acquire(.realtimeAgent)                   :388
          → split decision: FM route (collect whole LocalVoiceRoute), then FM answer stream  :483-590
      ← release lane                                               :463/466
```

The lock order is consistent: native before lane, and FM never takes native. I found no lock-order deadlock between these two actors.

### 1.3 Long-lived Tasks during a voice session

| Task | Isolation | Lifetime | Awaits |
|---|---|---|---|
| `vadTask` | MainActor | Session | `tick()` every 100 ms (`AgentCaptureController.swift:862-870`). **`tick` awaits `emitTurn`, `endSession` and `LocalVoiceFrontend.clearStagedTurn`**, so any slow await there delays endpointing. |
| `consumeTask` (ASR stream) | MainActor | Session | Apple `SpeechAnalyzer` results |
| `turnDetectorTask` | detached | Session | FluidAudio EOU (`:519-646`), hops to MainActor per event |
| `feedTask` | detached | Session | Converts and feeds audio, hops to MainActor for levels (`:648-740`) |
| `activeTurnTask` | MainActor | One committed turn | `RealtimeAgent.handle` → `VoiceConversationCoordinator.handle` → `respond`. A new commit cancels it (`:1345`). |
| `responseTask` | MainActor | One frontend turn | FM route + answer. Cancelled by `speechStarted` / `handle` / `closeSession`. |
| `preparationTask` | MainActor | Per stable partial | 220 ms debounce → `LocalVoiceFrontend.speculate` (`VoiceConversationCoordinator.swift:162-183`) |
| `jobs[i].task` | MainActor | Per background objective | `worker.runVoiceObjective()` → `runPlannedToolLoop` (120 s budget excluding barrier waits; `RealtimeAgent+ToolLoop.swift:796-798`) |
| `AgentTaskManager.running[id]` | MainActor | Per ACP/local task | `backend.submit(task)`. ACP turns have no wall-clock deadline. |
| prewarm Task | detached into actor | Once per session | `prepareForConversation(.realtimeAgent)` (`NotesModelRuntime.swift:288-330`) |

### 1.4 Too many generation counters

At least ten independent epochs guard stale writes:

- `turnEpoch` and `turnGeneration` (capture);
- `inputEpoch`, `preparationEpoch` and `responseID` (coordinator);
- `generation` and `speechGeneration` (agent);
- `outputGeneration` (synthesizer);
- `stagingEpoch` and `sealedThroughEpoch` (frontend).

Each was added to fix a real race, and each is correct locally. Together, they are why the system is hard to reason about: nothing names "the current turn" or "the current output" once. A frame-based design collapses them into one `TurnID` and one `OutputID` (see §5).

---

## 2. State machine of a voice session (Q1)

### 2.1 Top level (owned by `AgentCaptureController`)

```
                 begin()/beginSession                         (AgentCaptureController.swift:219-294)
   ┌────────┐ ─────────────────────────► ┌──────────┐ mic granted, engine up, startVAD, lease model
   │ Closed │                            │ Opening  │ ──────────────────────────────┐
   └────────┘ ◄──────────────────────────└──────────┘  mic denied / engine error   │
       ▲          endSession(.done)                                                ▼
       │          goodbye (tick :1251-1259)                                   ┌─────────┐
       │          idle 25 s  (tick :1272-1281 — only if no speech,            │  Open   │
       └───────── no RealtimeAgent.isThinking, no coordinator job,            │ (below) │
                  not speaking, no pending turn)                              └─────────┘
```

`endSession` (`:339-379`):

- closes the coordinator;
- cancels `activeTurnTask` and any ACP confirmation;
- cancels `RealtimeAgent.shared` if it is thinking;
- stops audio and **clears the announcement queue**;
- stops VAD and the engine.

Background jobs **survive** (`VoiceConversationCoordinator.swift:256`), but their results can no longer be spoken (`VoiceAnnouncementQueue.swift:13`).

### 2.2 Inside "Open": three orthogonal regions

**Region A: the floor and the turn** (capture owns it; the coordinator holds the barrier flag)

```
             level ≥ 0.06 for ≥120 ms, not speaking (or near candidate)
  ┌──────┐   → inputActivityStarted(): inputPending = true            (:893-901, Coordinator :196-199)
  │ Idle │ ───────────────────────────────────────────────────────► ┌─────────────────────┐
  └──────┘                                                          │ UserProvisional     │
     ▲  ▲                                                           │ • ASR partials       │
     │  │  discard: no words / backchannel / echo / repeat /        │ • speculation on     │
     │  │  revised transcript → discardVoiceInput → inputPending=F  │   stable partials    │
     │  └───────────────────────────────────────────────────────────│ • TTS paused (not    │
     │     (tick :1191-1250)                                        │   stopped) if novel  │
     │                                                              │   words (:1095-1143) │
     │                                                              └──────────┬──────────┘
     │                                     endpoint: EOU model, or 0.9/2.5 s silence + 0.35 s settle
     │                                     (tick :1182-1190) → emitTurn (:1285)
     │                                                                         ▼
     │                                                              ┌─────────────────────┐
     │   hesitation ("um") → noteHesitation: inputPending=T, no     │ UserCommitted        │
     │   model call, keep waiting (:1329-1337, Coord :267-276)      │ userSpeechStarted →  │
     │                                                              │  hard-stop TTS,      │
     │                                                              │  cancel responseTask │
     │                                                              │ interrupt() if       │
     │                                                              │  isThinking          │
     │                                                              │ activeTurnTask = …   │
     │                                                              └──────────┬──────────┘
     │                                                                         ▼
     │                                                              ┌─────────────────────┐
     │   deterministic gates (cancel / name / pending-ack / tool    │ Classifying          │
     │   shape / known noise) resolve instantly (Coord :332-409)    │ RealtimeAgent        │
     │                                                              │  .isThinking = true  │
     │                                                              │ FM route (collect)   │
     │                                                              └──────────┬──────────┘
     │                     newWork/revise/cancel/capabilities: resolveInput(), short fixed reply
     │                     answer: stream FM answer → TTS; resolveInput() only at END (:497)
     │                     failure: reply spoken, inputPending stays TRUE (:572-574)
     │                                                                         ▼
     │                                                              ┌─────────────────────┐
     │  playback finishes / barge-in (commit)                       │ Responding           │
     └──────────────────────────────────────────────────────────────│ isSpeaking = true    │
                                                                    └─────────────────────┘
```

**Region B: output** (owned by `RealtimeAudioSession` and `AgentSpeechSynthesizer`)

```
 Silent ──beginSpokenReply/append──► Speaking ──last clause done──► Silent
                                       │  ▲
             near candidate / novel    │  │ quiet 250 ms or 2.5 s unrecognised
             partial (provisional)     ▼  │ (reviewListeningPause :421-430)
                                    PausedForListening
                                       │
             committed turn / cancel   ▼
                                    Stopped (queue cleared; noteUserSpeech :435-451)

 Announcing is a Speaking entered from VoiceAnnouncementQueue.flush (tick :1268) when:
   no heardSpeech, no pending turn, !RealtimeAgent.shared.isThinking, !isSpeaking, nothing in flight.
```

**Region C: background jobs** (owned by `VoiceConversationCoordinator.jobs`, mirrored into `AgentTaskManager`)

```
 submit(text) ──► running ──runVoiceObjective returns a string──► finished → AgentTaskManager.finishVoiceObjective
                    │                                                         → announce() → feed + island + VoiceAnnouncementQueue
                    ├── revise(text): work.append; PermissionGate.cancelPending(task) ─► running (next round re-plans)
                    └── cancel(id): worker.generation += 1; task.cancel() ─────────────► cancelled
 (No "failed" and no "needs input" state: a planner failure is a *finished* job whose result is an error sentence.)
 Inside running, every round:  waitForVoiceInput (barrier) → [native context → lane] → plan → waitForVoiceInput
                               → per call: waitForVoiceInput → read (bounded) | write (unbounded, may await PermissionGate)
```

**Region D: ACP / typed tasks** (`AgentTaskManager.execute`, `AgentTaskManager.swift:188-276`)

```
queued → running → completed | failed | cancelled | waitingForPermission | waitingForCompatibilityCLI
```

The voice frontend never sees Region D.

### 2.3 Who owns each transition

| Transition | Owner | Trigger |
|---|---|---|
| Barrier up | `AgentCaptureController.noteLevel` / `considerSpeechInterruption` → `Coordinator.inputActivityStarted` | Energy or novel partial |
| Barrier down | `Coordinator.resolveInput(epoch)` (answer end or control route), `discardInput`, `closeSession` | Classification done |
| Output pause / resume | `AgentCaptureController.considerSpeechInterruption` / `considerListeningCandidate` → `RealtimeAudioSession` | Provisional input |
| Output stop | `RealtimeAgent.userSpeechStarted` → `RealtimeAudioSession.noteUserSpeech` | Committed turn |
| Response cancel | `Coordinator.speechStarted` / `handle` (cancels `responseTask`), `AgentCaptureController.emitTurn` (cancels `activeTurnTask`) | Committed turn |
| Job cancel / revise | `Coordinator.respond` (deterministic cancel phrase with exactly one job, or FM route) | Committed turn |
| Job completion → speech | `AgentTaskManager.announce` → `VoiceAnnouncementQueue.enqueue` → `tick` flush | Quiet floor |

---

## 3. Answers to the six questions

### Q2. While a tool loop or delegated task runs, can the user talk?

**Yes, a conversational answer is possible**, and this is the part that is already right. The committed turn goes to a fresh `activeTurnTask` so the VAD keeps endpointing (`AgentCaptureController.swift:1349-1367`). The frontend is Foundation Models, not the worker's llama context. The worker is a separate `RealtimeAgent` instance, so `RealtimeAgent.shared.isThinking` does not reflect it.

What serialises them, in order of user-visible impact:

| # | Shared resource | Effect while a worker runs | Reference |
|---|---|---|---|
| a | **Effect barrier `inputPending`**, which gates *planning* | Every user utterance, including chit-chat and a status question, pauses every worker at its next round or call boundary until the frontend has finished generating its answer (not until playback ends; the barrier drops at the end of generation). A backchannel with energy but no words holds it until discard. | Coordinator `:196-199, 259-263, 497`; ToolLoop `:864, 915, 954, 1000` |
| b | **Barrier left closed on frontend failure** | Workers freeze until the next valid turn. The session cannot idle-close because `hasActiveWork`. | Coordinator `:546-575`; Capture `:1272-1281` |
| c | **Single `ComputeScheduler` slot** | The frontend preempts the worker. The worker parks at the next token or 128-token prefill chunk and resumes only after the frontend releases. No overlap. | ComputeScheduler `:85-87, 99-105`; NotesModelRuntime `:481, 543, 614` |
| d | **Prewarm at `.realtimeAgent`** | A cold 4B load holds the frontend's own class. The next frontend turn queues behind it (equal priority does not preempt). This can reach the 25 s deadline, which then triggers (b). | NotesModelRuntime `:326, 347-359`; ComputeJob `:45-47`; Coordinator `:223-230, 437` |
| e | **Single llama native context** | Jobs plan one round at a time. A worker waits behind meeting-notes generation for minutes; reservation does not preempt. | NotesModelRuntime `:667, 698-715, 884-894` |
| f | **FM strictly serial** | A new committed turn waits up to 2 s for the cancelled previous FM inference to stop. If it does not stop, the turn fails with `Previous voice inference did not stop` → `modelError` → (b). | LocalVoiceFrontend `:214-222, 312-316, 350-356` |
| g | **MainActor** | Worker prompt assembly runs on main: `NextMemory.refreshFromActivity()` (commented as having stalled main before), `contextForCurrentTurn`, `plannerSystem`. So do per-token stream consumption and synchronous `AgentSession` JSON writes on every row and clause-delivery change. The 100 ms VAD tick shares this executor. | ToolLoop `:733-737, 813-816`; RealtimeAgent `:1134-1141, 1199-1214` |
| h | **One `activeTurnTask`, one `responseTask`** | Correct as a design: a newer turn supersedes. Supersession is also what cancels the previous answer's generation. | Capture `:1345`; Coordinator `:295-311` |

**Progress:** the user can ask. The frontend's work context is only `Task N [running]: <prompt>` plus a verified result once finished (`VoiceConversationCoordinator.swift:666-685`), with no step, elapsed time or current tool. The answer can only be "still working on it". The status question itself pauses the job by (a) and (c).

**Cancel:** the user can cancel. The deterministic `isExplicitWorkCancellation` path applies when exactly one job is running (`:332-337`). Otherwise the FM route `cancelRunningTask(n)` applies (`:528-533`). `cancel(id)` bumps the worker generation and cancels its Task (`:710-718`). llama cancellation takes effect at the next token. An in-flight **write** tool is not bounded and completes (`ToolLoop:1035-1036`), which is deliberate.

**Held resources:** the microphone is never held; capture keeps running throughout. The turn is not held either, since each commit gets its own task. The model is time-sliced (c, d, e), and the barrier pauses work (a, b).

**Delegated (ACP) tasks:** voice cannot start them (§0 item 7). Typed-path ACP tasks run in `AgentTaskManager` without touching the barrier or the lane, because they are external processes. The conversation is therefore fully unblocked by them, but it also cannot see them, and their approvals arrive only as cards.

### Q3. Is it the same model? Is full duplex physically possible?

No, they are different models:

| Lane | Model | Runtime | Lane class |
|---|---|---|---|
| Conversational frontend (route + answer) | Apple Foundation Models (system on-device model, about 3B) | FoundationModels framework, own inference service | `.realtimeAgent` (`LocalVoiceFrontend.swift:388`) |
| Voice worker planning | App LLM: the installed GGUF. Qwen3.5-4B per memory notes; Gemma 4 E4B is never downloaded here per AGENTS.md. | llama.cpp on Metal, `NotesModelRuntime`, **one context** | `.background` (`ToolLoop:885-892` → `NotesModelRuntime.stream` default `.background`, `:444-448`) |
| Worker prewarm | same GGUF | same | `.realtimeAgent` ← the bug (`NotesModelRuntime.swift:326`) |
| Typed agent turns and meeting notes | same GGUF (or cloud) | same context | `.background`, or `.realtimeAgent` for interactive typed streaming |

So full duplex is **not** blocked by a shared context: the comment at `LocalVoiceFrontend.swift:4-8` says the two lanes are independent, and that is true of their native state. What stops them overlapping is:

1. **Scheduler policy.** One global slot makes FM and llama mutually exclusive (§Q2 c). That is a choice to protect time-to-first-token, not a hardware limit.
2. **Measured costs, from the codebase's own numbers.** On this 16 GB Mac:
   - a cold GGUF load took 11.78 s, 19.37 s, 22.00 s, 25.06 s (`VoiceConversationCoordinator.swift:213-217`) and 18.1 s (`RealtimeAgent.swift:29-31`);
   - "a planner round costs 45 s of prefill on this machine" (`RealtimeAgent+ToolLoop.swift:739`);
   - notes weights are about 2.7 GB resident (AGENTS.md).

   A worker's 3–4 planner rounds are therefore minutes of GPU. If FM and llama overlapped on one GPU, FM's time to first token would degrade by an unmeasured amount. The current scheduler avoids that by pausing the worker entirely.
3. **Where it would become impossible.** Put the conversational lane on the same llama context, for example as a fallback when Apple Intelligence is unavailable, or on a Mac without it. Then every spoken turn would wait for the worker's in-flight round: up to about 45 s of prefill plus a 256-token decode, and a cold load of 11–25 s the first time. Or the turn would have to cancel the round and lose its KV cache. With one context, duplex conversation *during* work is physically impossible, and with the current code that case simply says the frontend is unavailable (`VoiceConversationCoordinator.swift:415-422`).
4. **Parallel workers are physically impossible today** because of the one native context: N jobs are N-way time-sliced by round. llama.cpp can host several `llama_context`s on one `llama_model` (weights shared, KV cache per context, a few hundred MB at 4–8k tokens for a 4B model). A second context for voice work is the cheapest real fix (§5.6).

### Q4. How do background results return?

```
worker.runVoiceObjective() returns String         (RealtimeAgent.swift:130-139)
 → Coordinator.submit's task: jobs[i].result/status = finished          (Coordinator :694-706)
 → AgentTaskManager.finishVoiceObjective → announce(result)              (AgentTaskManager :98-106, 311-320)
      AgentSession.recordAssistant(contextKind: backgroundTask)   ← the next frontend turn sees it in history
      IslandState.showBackgroundAgentReply
      VoiceAnnouncementQueue.enqueue   ← dropped if !isSessionActive     (VoiceAnnouncementQueue :12-15)
 → AgentCaptureController.tick (every 100 ms) → flush(userHasFloor:)     (Capture :1268)
      speaks first ≤2 clauses (≤300 chars) VERBATIM, or a generic
      "There's an update from your background task…"                     (VoiceAnnouncementQueue :45-50)
 → PlaybackEvent.interrupted → the unfinished clauses go back to the queue head      (:29-33)
```

When results are spoken:

- **They wait for a pause.** The flush requires no heard speech, no pending partial, `!RealtimeAgent.shared.isThinking` and no playback.
- **There is no hold-off after the user's last word.** The flush can fire on the first 100 ms tick after a turn commits, before `beginVoiceFrontend` sets `isThinking`, because of the gap across `activeTurnTask` → `handle` → `respond` (Capture `:1321` `resetTurn` clears `heardSpeech` first). The frontend's answer then cuts the announcement off. It is re-queued, so nothing is lost, but the user hears a clipped start. The flush also does not check `Coordinator.inputPending`.
- **An interruption re-queues** the in-flight clauses. They are not re-phrased.
- **Results can be lost to speech.** This happens when the session is closed at completion time (Done, goodbye, or idle — and idle cannot happen while a coordinator job runs, but *can* happen while an ACP task runs, because `hasActiveWork` only counts coordinator jobs). The text survives in the feed and on the island only.
- **Results are never phrased by the frontend.** The announcement is the worker's raw reply truncated to two clauses, so "it's ready" never sounds conversational. `VoicePlaybackDelivery.receive(.began)` binds the *current agent generation*, so an announcement can inherit the delivery ledger of whichever turn happens to be current (`VoicePlaybackDelivery.swift:28-34`). That is a small cross-talk risk.

### Q5. Interruption and barge-in semantics

| Signal | Detected at | Effect on output | Effect on the frontend response | Effect on jobs |
|---|---|---|---|---|
| Energy ≥ 0.06 for 120 ms (not during own playback unless near candidate) | `noteLevel` `:887-903` | none | none (FM staging warmed) | **barrier up** → all workers pause at next boundary |
| Near-mic candidate during playback | `considerListeningCandidate` `:919-933` | **pause** (reversible), auto-resume after 250 ms quiet or 2.5 s unrecognised | none | none |
| Novel partial (≥ 2 chars, ≥ 250 ms, not echo, backchannel, repeat or hesitation) | `considerSpeechInterruption` `:1095-1143` | pause | speculation starts on stable partials (220 ms debounce, ≥ 4 words) | barrier up (once per turn) |
| Discarded endpoint (no words, backchannel, echo, repeat, revision) | `tick` `:1191-1250` | resume | speculation cleared | **barrier down** |
| Hesitation commit ("um") | `emitTurn` `:1329-1337` | none (not stopped) | none | barrier stays up; hesitation row recorded |
| Committed novel turn | `emitTurn` `:1302-1367` | **hard stop**, queue cleared | previous `responseTask` **cancelled**, new `respond` | none directly. The FM route may revise or cancel a job, and a revision **cancels that job's pending approval**. |
| Explicit "stop that" with exactly one job | Coordinator `:332-337` | — | fixed reply | job cancelled |
| Island Stop / `RealtimeAgent.cancel` | `RealtimeAgent.swift:396-426` | stop | closes the coordinator session | jobs **survive** (closeSession keeps them) |

This matches AGENTS.md: provisional pauses, committed stops output, and work survives unless explicitly cancelled. Two gaps:

- `voiceInputActive` is set and cleared in consecutive statements (`AgentCaptureController.swift:1303, 1307`). `RealtimeAgent.waitForVoiceInput` for the shared agent (`RealtimeAgent.swift:104-106`) and `AgentToolSpeechTracker.maySpeak`'s `!agent.voiceInputActive` (`ToolLoop:101-105`) are effectively no-ops in production. The real barrier is `Coordinator.inputPending`.
- `RealtimeAgent.appendVoiceFollowUp` returns false in production (`guard localModelProviderForTesting != nil`, `RealtimeAgent.swift:78`). Follow-ups always go through the FM route. **`--selftest-voice-work-lifecycle` and parts of `--selftest-voice-conversation` exercise the legacy `localModelProviderForTesting` path** (`VoiceWorkLifecycleSelfTest.swift`, `VoiceConversationSelfTest.swift`), which `handle` routes around the coordinator (`RealtimeAgent.swift:208-211`). Those greens describe a path production does not take. This is the "finished feature with no call site" trap from AGENTS.md, in self-test form.

### Q6. Races, deadlock risks and head-of-line blocking

**Head-of-line blocking** (an await inside a turn or round that waits on unrelated work):

1. **Frontend waits behind the voice prewarm load** (`NotesModelRuntime.swift:326`, equal class). This is the most likely source of a first-minute "it didn't answer" and of `deadlineReply`.
2. **The worker's round waits behind the frontend's entire answer generation** (barrier released at `VoiceConversationCoordinator.swift:497`). It also waits behind the lane, so it pays twice.
3. **The worker waits behind meeting notes, dictation cleanup or typed agent turns** on the single native reservation.
4. **Committed turn → drain barrier ≤ 2 s** for the previous FM inference (`LocalVoiceFrontend.swift:312-316`).
5. **Frontend two-stage route then answer.** The route must be *collected whole* before any answer token (`LocalVoiceFrontend.swift:505`), so time to first audio = route latency + answer TTFT. Speculation hides this only when the committed text equals the speculated key.
6. **`tick` awaits `LocalVoiceFrontend.clearStagedTurn()` inline** on every discard path (`AgentCaptureController.swift:1198-1254`). It is an actor hop. It is usually fast but not guaranteed, because the actor can be busy in a reentrant `stream` await, and it sits on the VAD loop.
7. **The goodbye path awaits the full `handle` inline in `tick`** (`AgentCaptureController.swift:1369`). VAD is stopping anyway, so this is harmless today.

**Stalls that are not strict deadlocks but look like them to the user:**

8. **Frontend failure leaves `inputPending = true`** (`VoiceConversationCoordinator.swift:572-574`). Workers wait forever while the session is open. `hasActiveWork` disables the idle close (`AgentCaptureController.swift:1274`). Only a new valid utterance or Done recovers. A chain that triggers it without any user error: (1) lane contention leads to the 25 s deadline, which leads to the barrier closing.
9. **A worker awaiting `PermissionGate.ask` for a write** (unbounded by design) keeps `hasActiveWork` true, so the session never idles out and the mic stays open. It has no spoken approval, and a spoken revision *denies* the approval (`:347, 525`). A user saying "yes, send it" is likely routed as an answer or revision. A revision cancels the approval, re-plans, and asks again, which is a potential loop.
10. **`RealtimeAgent.shared.isThinking` stuck true** blocks every announcement flush forever. Paths that return without `finish` after `beginVoiceFrontend` (`VoiceConversationCoordinator.swift:459-461`, superseded without a newer turn) rely on a later turn, `interrupt`, or `cancel` to clear it. `closeSession` does not reset `isThinking`. The risk is low, but there is no watchdog.

**Races:**

11. **Announcement vs the committing turn** (§Q4): the flush can start between commit and `beginVoiceFrontend`.
12. **`VoicePlaybackDelivery` turn binding** uses `RealtimeAgent.shared.currentGeneration` at `.began`. An announcement and the next answer can share a generation (`VoicePlaybackDelivery.swift:28-34, 59-63`).
13. **`RealtimeAudioSession.speak` / `beginSpokenReply` cancels whatever is in the one speech buffer** (`RealtimeAudioSession.swift:146-175`). Only the announcement queue guards itself (checks `isSpeaking`). Any other producer that speaks during an answer, such as `RealtimeAgent.finish(speak:)` on a late non-streamed path, silently truncates it.
14. **Workers write global UI state.** `beginWork` → `ActivationController.markWorking()` and `IslandState.showAgentWork` (`RealtimeAgent.swift:516-521`) switch the island to "working" while the user is mid-conversation with the frontend. This is visible, not corrupting.
15. **`runWithLocalToolsOnce` submits a task with `tool == nil`** (`RealtimeAgent+ToolLoop.swift:233-241`). `LocalAgentBackend.submit` refuses any task without a tool (`Agent/Backend/LocalAgentBackend.swift:19-24`), so "I'll work on that locally, once" is always followed by "Nothing local can do that." This is a functional bug on the ACP-missing path.

**Deadlock review:**

- Native → lane ordering is consistent.
- FM takes only the lane.
- `awaitCleanupIdle` inside `load` runs while holding the native context and the lane (`NotesModelRuntime.swift:1180`). It is safe only because no cleanup formatter acquires the lane or native context. `AppLLMCleanupFormatter` avoids the gate, as AGENTS.md documents. Any future cleanup that acquires the lane *and* calls `beginCleanup` would deadlock here, so it is worth a self-test assertion.
- `ParakeetEngine` holds `.realtimeASR` for a whole dictation (`Transcription/ParakeetEngine.swift:87`). Every lane user, frontend included, queues behind a dictation for its full length. Dictation during a voice session is unusual but not prevented.

---

## 4. Ranked blocking points

Ranked by (probability × user-visible cost). Fix effort: S = hours, M = days, L = a milestone.

| Rank | Where | What the user experiences | Fix | Effort |
|---|---|---|---|---|
| **1** | `VoiceConversationCoordinator.swift:572-574` (barrier kept closed on failure) with `AgentCaptureController.swift:1272-1281` (no idle close while jobs run) | After one failed voice reply, "I'm on it" work silently stops. Nothing happens until the user speaks again. | Resolve the barrier for *this* epoch on every terminal outcome, failure included. The reason the barrier exists — do not release an effect planned against superseded words — is better served by a revision check at the effect commit point (rank 3). | S |
| **2** | `NotesModelRuntime.swift:326` (voice prewarm at `.realtimeAgent`), with the equal-priority rule `ComputeJob.swift:45-47` | The second spoken turn of a session takes 11–25 s or fails with "took too long". | Prewarm at `.background`. The load then parks at its checkpoint whenever the frontend acquires. Alternatively, keep `.realtimeAgent` only for the one-token context warm after the load. Add an assertion to `--selftest-voice-scheduling`: a frontend `acquire(.realtimeAgent)` issued during a probe load at the prewarm class returns within N ms. | S |
| **3** | `RealtimeAgent+ToolLoop.swift:864, 915, 954` (barrier before and after every *planning* round) | Talking to the agent pauses background work, and asking about progress slows it. | Narrow the barrier to effects. Planning and reads run through user speech. Only `tool.risk > .read` steps (and `isStillValid`, `:999-1002`) wait on a resolved input epoch. A revision that arrives during a round is folded in by the existing `revision != work.revision → continue` check (`:917`). | S–M |
| **4** | `VoiceConversationCoordinator.swift:497` (barrier released only after the whole answer is generated) | Same as 3, for every conversational answer. | Release as soon as the *route* is known (`answerQuestion` cannot create or revise work), before streaming the answer. With rank 3 done, this matters only for effects. | S |
| **5** | `ComputeScheduler.swift:85-87` (one global slot) | Workers make no progress during any frontend generation. Chatty sessions starve work. | Add a concurrency policy: `.realtimeAgent` (FM) may overlap `.background` (llama) up to a cap, while `.realtimeASR` still preempts both. Measure FM TTFT with and without an overlapping llama decode through a new self-test before turning it on. | M |
| **6** | `NotesModelRuntime.swift:667, 698-715` (one native context, not preemptible) | A voice job waits behind meeting notes (minutes), and a second job waits for the first one's round. | Give voice workers a second `llama_context` on the same `llama_model`. The KV cache is a few hundred MB and the weights are shared. The cheaper alternative is to let `.background` notes release the native context at a round boundary, which requires KV reset and re-prefill. | M |
| **7** | `VoiceAnnouncementQueue.swift:38-52` | Results come out as raw fragments, can clip, and are lost when the session has closed. | Build an output scheduler (§5.4): an insertion window (floor free, `inputPending == false`, ≥ 700 ms since the last user word, no generation), frontend-phrased delivery, delivered-after-playback, and carry-over to the next session. | M |
| **8** | `VoiceConversationCoordinator.swift:666-685` (work status has no progress) | "How's it going?" can only get "still working". | Add the current step, tool title and elapsed time from `AgentActivityStore` to each job's status line. Answer a status route deterministically from the ledger (qwen's `get_agent_task_status`), with no FM call and no barrier. | S |
| **9** | `RealtimeAgent.swift:208-211` + `VoiceConversationCoordinator.swift:688-708` (voice never reaches ACP; jobs and `AgentTaskManager` tasks are separate ledgers) | "Have Claude Code fix X" by voice runs the 4B planner. Coding tasks cannot be queried or cancelled by voice. | Build one task ledger (§5.3). `startExternalTask` → `AgentHarnessRouter` → local tool-loop worker *or* ACP `BackendPort`. | M–L |
| **10** | No spoken permission, plus `VoiceConversationCoordinator.swift:347, 525` (a revision cancels the approval) | Writes stall at a card. A spoken "yes" can deny it. | Add a `respondPermission(decision, id?)` route that is valid only with a pending, owner-scoped request, and stop cancelling approvals on revision unless the revision changes that call. | M |
| **11** | `LocalVoiceFrontend.swift:312-316, 350-356` (2 s drain barrier, then failure) | A fast second question fails with "The local voice model failed…". | On a drain timeout, detach the stuck inference (ignore its output) instead of failing the turn. Otherwise make the timeout a retryable wait, not `modelError`. | S |
| **12** | `LocalVoiceFrontend.swift:483-550` (route collected before the answer) | Extra time to first audio on every answer. | Run the route and the answer as two concurrent FM requests, discarding the answer if the route is not `answerQuestion`. Or stream a typed route whose first field is the intent. Measure FM's concurrency and `concurrentRequests` error first (`VoiceConversationCoordinator.swift:617`). | M |
| **13** | `RealtimeAgent.swift:1134-1141, 1199-1214` (synchronous persistence on MainActor, including per-clause delivery updates) | Jank on the executor that also runs the VAD tick and TTS scheduling. | Debounced writer actor that snapshots on main and encodes and writes off-main. | S |
| **14** | `RealtimeAgent+ToolLoop.swift:233-241` → `LocalAgentBackend.swift:19-24` | "Run locally once" always fails. | Pass a resolved tool, or route to the tool-loop worker rather than `LocalAgentBackend`. | S |
| **15** | `RealtimeAgent.swift:516-521` called on workers | The island flips to "working" mid-chat. | Workers publish progress to the ledger. Only the session owner drives `ActivationController` and `IslandState`. | S |

---

## 5. Target architecture for this codebase

### 5.1 Reference points

**qwen-audio-agent** (`roadmap/references/qwen-audio-agent-main/docs/architecture/*.md`) separates:

- **Realtime frontend.** Full-duplex speech with a *small* tool set: `spawn_thinking`, `get_agent_task_status`, `cancel_agent_task`, `respond_permission`, `respond_agent_input`, `get_current_time`, plus optional lightweight tools. It never waits for the backend: "`spawn_thinking` never waits for the requested work".
- **Gateway control plane.** Deterministic, with no LLM on the routing path. It owns the task ledger, permission arbitration, the announcement policy and the injection defense.
- **Backend.** `BackendPort` (ACP, A2A or custom). One persistent coordinator session per owner, with writes serialised per owner.
- **Task state:** `queued → running → (delegated → finalizing) → completed | cancelling → cancelled | failed`. A task record is a *delivery receipt*, not a mirror of the backend's graph.
- **Progress is observability, not control.** It is projected from `session/update` into generic activity and "never produces spoken status updates". Status questions read the ledger directly.
- **Result delivery.** A result "waits for a safe duplex insertion window". It is injected into realtime context and "marked delivered only after playback finishes". If the user interrupts or is speaking, delivery waits and retries without duplicating context, and the retries are bounded.
- **Continuation.** When a backend needs input, the frontend asks naturally and calls `spawn_thinking` again as a continuation.

**A Pipecat-style frame pipeline** has these properties:

- Frames flow downstream through processors (transport-in → VAD → STT → user aggregator → LLM → TTS → transport-out).
- A system frame (`StartInterruptionFrame`, `StopInterruptionFrame`, `UserStartedSpeaking`) overtakes queued data frames and makes every processor drop its in-flight work.
- `ParallelPipeline` branches run concurrently.
- Background results enter as frames pushed into the LLM context aggregator.
- One place owns interruption semantics, and each processor reacts locally.

Next Notes already has most of the processors. It lacks the typed frame vocabulary, the single ledger and the insertion scheduler.

### 5.2 Components and ownership

```
 ┌──────────────────────────── MainActor (UI + session owner only) ─────────────────────────────┐
 │  VoiceSession (new; replaces the cross-object flags)                                          │
 │   state = reduce(state, VoiceEvent) — pure, unit-testable; owns TurnID/OutputID, floor,       │
 │   barrier epoch; publishes to IslandState/ActivationController (only it does)                 │
 └───────▲───────────────────────────┬───────────────────────────────────────▲───────────────────┘
         │ VoiceEvent (AsyncStream)  │ VoiceCommand                          │ TaskEvent
 ┌───────┴────────┐   ┌──────────────▼───────────┐   ┌────────────────┐   ┌──┴────────────────────┐
 │ InputProcessor │   │ FrontendResponder (actor)│   │ OutputScheduler│   │ TaskBridge (actor)     │
 │ = today's      │   │ = LocalVoiceFrontend +   │   │ (MainActor)    │   │ deterministic ledger:  │
 │ AgentCapture-  │   │ Coordinator.respond      │   │ = RealtimeAudio│   │ jobs + AgentTaskManager│
 │ Controller VAD/│   │ route → Decision         │   │ Session + synth│   │ unified; permission    │
 │ ASR/EOU/echo   │   │ answer → text deltas     │   │ + Announcement │   │ arbitration; progress  │
 │ (unchanged     │   │ phrase(result) for       │   │ queue + Deliv- │   │ projection; delivery   │
 │ logic, emits   │   │ announcements            │   │ ery ledger     │   │ receipts               │
 │ events instead │   └──────────────────────────┘   └────────────────┘   └──┬─────────────────────┘
 │ of calling     │                                                          │ BackendPort
 │ into 4 objects)│                                  ┌───────────────────────▼──────────────────────┐
 └────────────────┘                                  │ Workers: LocalToolLoopWorker (llama, own     │
                                                     │ llama_context) · ACPAgentBackend · Knowledge │
                                                     │ asker. Workers never touch UI or speech.     │
                                                     └──────────────────────────────────────────────┘
 ComputeScheduler: lanes with per-class capacity; realtimeASR preempts; realtimeAgent may overlap background.
```

Ownership rules:

- **Only `VoiceSession` decides who holds the floor**, what the current turn is, and whether output may start.
- **Only `TaskBridge` mutates task state.** The frontend and UI send it commands.
- **Only `OutputScheduler` starts audio.** Every producer (answer stream, announcement, fixed reply) submits an `OutputRequest` with a priority. None of them calls `RealtimeAudioSession.speak` directly, which removes race 13.
- **Workers are headless.** They emit `TaskEvent`s and never read `voiceInputActive` or `inputPending`. The effect gate is a function `TaskBridge.mayCommitEffect(taskID, revision) async -> Bool` that the tool executor calls at the risk boundary.

### 5.3 Message types (Swift sketch)

```swift
struct TurnID: Hashable, Sendable { let raw: UInt64 }
struct OutputID: Hashable, Sendable { let raw: UInt64 }
struct TaskID: Hashable, Sendable { let raw: UUID }

enum VoiceEvent: Sendable {                      // InputProcessor, FrontendResponder, OutputScheduler → VoiceSession
    case sessionOpened(UUID), sessionClosed(reason: EndpointSource)
    case inputActivity(TurnID)                   // energy/near candidate  (today: inputActivityStarted)
    case partial(TurnID, text: String, stable: Bool)
    case inputDiscarded(TurnID, reason: DiscardReason)   // echo, backchannel, no words, revision
    case hesitation(TurnID, text: String)
    case committed(TurnID, text: String)
    case responseStarted(TurnID, OutputID), responseDelta(OutputID, String), responseEnded(OutputID, ResponseOutcome)
    case playback(OutputID, AgentSpeechSynthesizer.PlaybackEvent)
}

enum FrontendDecision: Sendable {                // FrontendResponder → VoiceSession/TaskBridge (typed, no envelopes)
    case answer                                  // stream follows
    case capabilities
    case spawn(objective: String, backend: AgentBackendKind)   // one self-contained instruction (qwen rule)
    case revise(TaskID, text: String)
    case cancel(TaskID)
    case status(TaskID?)                         // answered from the ledger, no model
    case respondPermission(id: String?, decision: PermissionDecision)
}

enum TaskEvent: Sendable {                       // TaskBridge → VoiceSession/OutputScheduler/UI
    case accepted(TaskID, title: String)
    case progress(TaskID, step: Int, title: String, tool: String?)   // observability only; never spoken
    case needsInput(TaskID, question: String)
    case needsPermission(TaskID, PermissionRequest)
    case completed(TaskID, result: String, artifacts: [String])
    case failed(TaskID, reason: String)
    case cancelled(TaskID)
}

enum Interruption: Sendable {                    // the one "system frame"; overtakes queued output
    case provisional(TurnID)                     // pause output; keep generating; keep work running
    case committed(TurnID)                       // stop output, cancel the current response; work survives
    case explicitCancel(TaskID?)                 // only this invalidates work
}

struct OutputRequest: Sendable {
    enum Kind { case answer(TurnID), announcement(TaskID), fixed(TurnID) }
    let id: OutputID; let kind: Kind; let text: AsyncStream<String>; let priority: Int
}
```

The existing `VoiceFrontendEnvelope` / `LocalVoiceRoute` intents map one-to-one onto `FrontendDecision`. Two cases are added: `status` and `respondPermission`. The `VoiceTurnPolicy` gates stay in front and keep the "may only add, never subtract" rule.

### 5.4 How a tool result reaches the live conversation

1. The worker finishes → `TaskBridge` records `completed(id, result)` and appends an `AgentSession` row. This already happens, as `backgroundTask` contextKind. The row is marked `delivery: .pending`.
2. `OutputScheduler` holds a **delivery queue** keyed by `TaskID`. It opens an insertion window when:
   - the floor is free (no `inputActivity` since the last resolution, and the barrier epoch is resolved);
   - no response is generating;
   - there is no playback;
   - at least 700 ms have passed since the last user word (`lastSpeechAt`).

   In Pipecat terms, it waits for `BotStoppedSpeaking` + `UserIdle`.
3. In the window, ask `FrontendResponder.phrase(result, taskTitle, recentTurns)` for a one or two sentence spoken form with a tight token cap. Example: "Your flight search is done — the 7:40 is the cheapest." The deterministic `AgentSpeechPolicy.toolResultSummary` is the fallback when FM is unavailable or exceeds a 1.5 s budget. This is what makes "it's ready" sound natural.
4. Mark it **delivered only on `.completed` playback of every clause** (the `VoicePlaybackDelivery` ledger already has the right shape; bind it by `OutputID`, not by agent generation). On `.interrupted`, keep it pending. The next window re-phrases the remainder rather than replaying a fragment. Bound retries to 3.
5. If the session is closed, keep it pending and persisted. On the next session open, offer the pending results first ("While you were away: …"), or leave them on the island if the user has turned that off.
6. `needsInput` and `needsPermission` use the same queue at a higher priority. They are the only task events that may be spoken unprompted besides completion. `progress` is never spoken; it is readable by `status`.

### 5.5 How barge-in propagates

```
InputProcessor ──inputActivity/partial──► VoiceSession
     VoiceSession emits Interruption.provisional(turn)
        → OutputScheduler: pause current OutputID (today's pauseForListening), keep queue
        → FrontendResponder: keep generating the current answer into its buffer (not audible)
        → TaskBridge: nothing (effects already gated per-commit; planning continues)
InputProcessor ──inputDiscarded──► VoiceSession → OutputScheduler.resume(OutputID)
InputProcessor ──committed(turn,text)──► VoiceSession
     VoiceSession emits Interruption.committed(turn)
        → OutputScheduler: stop + clear queued clauses of the interrupted OutputID; an interrupted
          announcement goes back to the delivery queue as pending (not replayed verbatim)
        → FrontendResponder: cancel the old response task; start route for `turn`
        → TaskBridge: bump "input epoch"; any effect whose plan predates this epoch re-checks
          `mayCommitEffect` → it waits for the new turn's decision (revise/cancel/answer) and then
          proceeds or re-plans. Reads and planning are never paused.
Explicit cancel (phrase, route, Stop button) → Interruption.explicitCancel(taskID)
        → TaskBridge: running → cancelling → cancelled (confirmed, qwen semantics), worker Task.cancel()
```

This keeps every rule in AGENTS.md's closing sections:

- output and work have separate lifetimes;
- provisional input pauses, and a committed turn stops output;
- only explicit cancellation invalidates work;
- effects wait for the latest input to be classified;
- deterministic gates stay additive.

The difference is that the barrier moves from "everything the worker does" to "the moment an effect commits".

### 5.6 Compute

- **Lanes with capacity.** Replace `running: ComputeJob?` with a small table:
  - `realtimeASR` is exclusive and preempts;
  - `realtimeAgent` (FM) and `background` (llama) may run together when a measured policy allows it. Start with an off-by-default flag and a self-test that prints FM TTFT p50 with and without a concurrent llama decode.

  Keep checkpoints, so the policy can still choose to park.
- **Second llama context for voice work**, sharing `model`, with its own native reservation. Meeting notes stop blocking voice. Two voice jobs still serialise on the voice context, and that is acceptable.
- **Prewarm at `.background`** (rank 2) and warm at session open only if a job is plausible. The AGENTS.md reasoning for not loading at mic open still holds.
- **Workers off MainActor for prompt assembly.** Snapshot `AgentSession`, memory grounding and tool catalogue on main, then build the prompt in the worker's own isolation.

---

## 6. Incremental migration path

Each step is a separate, reviewable change. It must keep the existing self-tests green and, per AGENTS.md convention, it adds or tightens a `--selftest-*` flag that fails when the thing it names did not happen.

**Step 0: make the tests describe production (prerequisite).**

- Port `--selftest-voice-work-lifecycle` and the `localModelProviderForTesting` cases of `--selftest-voice-conversation` onto the coordinator path: `streamForTesting` + `workerForTesting`, as `ConcurrentVoiceSelfTest` already does. Today they grade `RealtimeAgent.appendVoiceFollowUp` and `handle`'s legacy branch, which production never reaches (`RealtimeAgent.swift:78, 208-211`).
- Either delete the unreachable `appendVoiceFollowUp` path or make the test assert it is unreachable.

**Step 1: hotfixes that remove blocking without changing the architecture** (ranks 1, 2, 11, 14; each S).

- `finishFailure` resolves its own epoch. Test: extend `--selftest-concurrent-voice`. The fake frontend returns a deadline failure while a fake worker is parked at the barrier, and the test asserts the worker proceeds within 200 ms. Today this should fail.
- Prewarm at `.background`. Test: extend `--selftest-voice-scheduling`. With a probe load holding the lane at the prewarm class, an `acquire(.realtimeAgent)` returns before the probe releases.
- Drain timeout → detach, not fail. Test: a `LocalVoiceFrontend.setGenerationForTesting` producer that ignores cancellation for 3 s. The next committed turn still answers.
- Fix `runWithLocalToolsOnce`. Test: add a case to `--selftest-acp-confirm`.

**Step 2: narrow the effect barrier** (ranks 3, 4).

- Move the wait from the round boundaries (`ToolLoop:864, 915, 954`) into `AgentToolExecutor`'s `isStillValid` for `risk > .read` only.
- Release the barrier when the route is decided.
- New flag `--selftest-voice-duplex-work`. A fake worker runs a three-round plan while the test drives five conversational turns. It asserts:
  - the worker's rounds advance during the conversation (timestamps interleave);
  - no write commits between a revising turn's commit and its classification;
  - the answer routes never wait on the worker.

**Step 3: one task ledger** (ranks 8, 9, 15).

- `TaskBridge` wraps `AgentTaskManager` and absorbs `VoiceConversationCoordinator.jobs`.
- Voice jobs get real states (`failed`, `needsInput`), ACP tasks appear in the frontend's work status, and workers stop touching `IslandState` and `ActivationController`.
- The status route is answered from the ledger with the current step.
- Tests: `--selftest-tasks` gains voice-job rows. `--selftest-voice-turn-routing` gains a "how's it going" turn that must make no model call (`streamForTesting` call count is unchanged) and must name the current step.

**Step 4: output scheduler and natural delivery** (rank 7).

- Insertion window, frontend-phrased announcements, delivered-after-playback by `OutputID`, carry-over across sessions, and an `inputPending` check.
- Tests: extend `--selftest-voice-delivery`:
  - a result that completes mid-turn is spoken only after the answer's playback plus the hold-off;
  - an interrupted announcement is re-phrased, not replayed;
  - a result finishing after `endSession` is spoken at the next `beginSession`.

  The existing `--selftest-duplex` and `--selftest-voice-barge` must stay green unchanged.

**Step 5: event stream and a single reducer.**

- Replace the four-object flag choreography between `AgentCaptureController`, the coordinator, `RealtimeAgent.shared` and `RealtimeAudioSession` with `VoiceEvent` → `VoiceSession.reduce` → commands.
- Keep `AgentCaptureController`'s VAD, EOU and echo logic intact as the input processor, since it is the most measured part of the system and AGENTS.md documents why each rule exists.
- Replace the 50 ms and 20 ms polling waits with continuations on the reducer's state.
- Tests: the reducer is pure, so a new `--selftest-voice-session-reducer` can replay a recorded event trace from `--selftest-voice-pipeline` and assert the command sequence. This is the Pipecat-style "frames in, frames out" test the codebase does not have yet.

**Step 6: compute concurrency** (ranks 5, 6).

- Second llama context for voice workers, then capacity-based lanes behind a flag.
- Tests: extend `--selftest-residency` and `--selftest-scheduler` for the new capacity rules. Add a measurement flag (`--selftest-voice-overlap`) that prints FM TTFT with and without a concurrent llama decode and **fails** if either side produced zero tokens, as the Metal probe does.

**Step 7: voice-driven ACP and spoken permission** (ranks 9, 10).

- `spawn` → `AgentHarnessRouter` → `BackendPort`.
- The `respondPermission` route is valid only with a pending request owned by the session's tasks, never invents consent, and one pending request needs no id.
- A revision no longer cancels an approval unless it changes the pending call's arguments.
- Tests: `--selftest-acp` with the stdio fixtures, and `--selftest-voice-turn-routing` for "yes" / "no" / "yes, but send it to Marcus instead" against a pending fake request.

Steps 1 and 2 alone should remove most of the "laggy and blocking" feel. Step 4 is what makes results come back as conversation rather than as fragments. Steps 5–7 turn the current design into the qwen-style frontend/gateway/backend split without rewriting the audio front end.
