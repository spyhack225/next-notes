# Voice agent end-to-end latency: mic PCM → first audible syllable

> **Historical model assumptions — revised 2026-09-30:** this completed plan/audit
> preserves its dated measurements and implementation history. For new work, follow
> the [independent-role/shared-file contract](../../in-progress/SHARED-BRAIN/00-README.md): Meetings, Agent and cleanup
> may use different appropriate models; exact verified artifacts are reused, with
> workload-specific consent and request ownership. Agent-only file selection,
> universal model defaults and deletion based only on the Agent are superseded.
> MiniCPM cleanup + Apple guard/fallback is concurrent work, not evidence that this
> historical build used it. Re-measure quality/latency on the actual current engine.

Read-only analysis, 2026-09-23. Scope: the live conversational path (Agent voice session), not the background tool worker's own tool latency except where it contends with the voice path.

All paths are relative to `Sources/NextNotes/` unless stated. "Measured" means a number that exists on this machine, with its source. "Estimate" means inferred from code and is labeled as such.

## 0. Headline

| | Speech end → first audio | Source |
|---|---|---|
| File-fed pipeline, 2026-09-14 (builds 18–52, 6 runs) | **2.83 – 3.58 s** | `Tests/Reports/voice-conversation-analysis-2026-09-14.md:352,390-394,406-407,436-444` |
| File-fed pipeline, **today, installed build, warm caches** | **3.10 s** (1.063 s endpoint + 2.033 s to audio) | run in this analysis, `scratchpad/pipeline-run2.txt` |
| Same, **cold process** (first run after install) | **10.4 s** (1.407 + 8.967) | run in this analysis (EOU prepare 12.7 s, Pocket load 12.6 s, first PCM 6.0 s) |
| Real voice sessions 2026-09-22, committed transcript → first model text only (n=15) | median **1.81 s**; 0.03 – 8.76 s; 3 hard failures at ~2.0 s | `~/Library/Application Support/Next Notes/metrics.jsonl` + `agent-audit.jsonl` |
| Real sessions, first model text → first audio callback (n=12) | p50 **0.305 s**, 0.189 – 1.344 s | `metrics.jsonl` `agent.first_token_to_first_tts` |
| Barge-in: voice onset → playback paused (file-fed) | **0.835 – 0.961 s** (today 0.838 s) | report `:44-47,146-149,828`; `scratchpad/barge-run.txt` |

Target for "feels like OpenAI Realtime / Gemini Live": speech end → first syllable **≈ 0.6–0.9 s**, onset → playback ducked/paused **≤ 0.2 s**. The current path is roughly **3–4× the target** in the good case and **10×** when the worker model is loading.

The dominant costs, in order: (1) the worker LLM contending with the voice frontend for the same scheduler lane and the same GPU/ANE, (2) two serial Foundation Models passes (route, then answer) with no prompt prewarm, (3) ~1 s end-of-utterance detection, (4) speculation that almost never hits, (5) barge-in that waits for recognized words.

---

## 1. Hop by hop

### Hop 1 — Capture, conversion, echo cancellation

**What it does.** `AudioCaptureHub` taps the shared input node, converts to 16 kHz mono Float32 on a per-consumer serial `DispatchQueue`, and calls the Agent's `deliver` closure, which runs `AcousticEchoProcessor.process` (SpeexDSP, 10 ms frames) synchronously, then fans the cleaned chunk out to (a) the Apple ASR feed stream, (b) the Parakeet EOU backlog, and (c) a `Task { @MainActor }` that updates level/VAD state.

**Constants.**
- Input tap `bufferSize: 2048` — `Core/AudioCaptureHub.swift:279`. Ignored by the device: delivered batches are **~100 ms** (report `:909-913`, "Capture also arrives in ~100 ms batches").
- Delivery lane `maxPending = 8` buffers — `Core/AudioCaptureHub.swift:387`.
- Speex frame 160 samples (10 ms) — `Agent/AcousticEchoProcessor.swift:60`; wrapper adds a fixed two-frame (20 ms) delay (acoustic-echo report).
- Post-stop echo tail 5 600 samples (350 ms), active ≤ 0.5 s — `Agent/AcousticEchoProcessor.swift:163,558`.
- Output reference tap `bufferSize: 480` — `Agent/Speech/VoicePlaybackReference.swift:11`; actual callbacks **4 800 frames @ 48 kHz = 100 ms**, arriving **~80.6 ms late** (report `:909-912`).

**Streaming?** Yes, chunked at the device's 100 ms cadence.

**Serial where it could be pipelined?** No, but the batch size is the problem: every downstream stage inherits a 0–100 ms (mean ~50 ms) quantization, and AEC alignment suffers from the coarse reference.

**Contribution.** Measured capture→processing **63–71 ms** with normal buffers, **~18 ms** with the experimental `AVAudioSinkNode` path (report `:267,281`). Estimate **~65 ms** on every hop that starts from audio (end of turn and barge-in).

### Hop 2 — ASR (two recognizers in parallel)

**What it does.** Two recognizers run on every chunk:
- Apple `SpeechAnalyzer` with `[.volatileResults, .fastResults]` — `Transcription/AppleSpeechEngine.swift:179`. It supplies user-visible text and is the fallback owner of the partial.
- Parakeet EOU 120M (FluidAudio `StreamingEouAsrManager`) — `Activation/LocalVoiceTurnDetector.swift:8`, `chunkSize: .ms160` (2 560-sample window, 80 ms shift), `eouDebounceMs: 320`. It owns the partial once it has "caught up" and supplies end of turn.

The Apple consumer loop runs on the main actor (`Activation/AgentCaptureController.swift:461-506`); every Parakeet partial/EOU callback hops to the main actor through a new `Task { @MainActor }` (`:1071-1091`).

**Constants.** Startup backlog ≤ 96 000 frames (6 s) — `:26`; "caught up" when lag ≤ 0.4 s — `:576`; lag > 0.5 s resets the decoder — `:589-608`.

**Streaming?** Yes. Parakeet partials arrive every ~80 ms after the first word.

**Contribution.** Measured first Apple result **1.07–1.13 s** after voice onset; first Parakeet word **0.84 s** after onset (today's barge run; report `:392-396`). ASR latency does not sit on the end-of-turn critical path directly (EOU does), but it **is** the critical path for barge-in (Hop 12) and for speculation (Hop 7).

Note: running both recognizers plus Speex, Foundation Models, Pocket TTS and (often) llama.cpp on a 16 GB M3 is itself a contention source (Hop 8).

### Hop 3 — End of utterance

**What it does.** Parakeet's EOU head fires; FluidAudio confirms it only after `eouDebounceMs` of wall-clock silence without new tokens (`FluidAudio …/StreamingEouAsrManager.swift:292-326`), then calls back. `noteModelEOU` stores `modelEOUAt` (`Activation/AgentCaptureController.swift:994-1025`). Nothing commits until the next VAD tick.

**Constants.**
- EOU debounce **320 ms** — `Activation/LocalVoiceTurnDetector.swift:8`.
- Parakeet window 160 ms / shift 80 ms — same line.
- Fallback when the EOU model is ready but silent: **2.5 s** of quiet — `Activation/AgentCaptureController.swift:1186`.
- Fallback before the EOU model is ready: `endpointSilence` **0.9 s** + `transcriptSettle` **0.35 s** — `:100,103,1185-1189`.
- `minSpeech` 0.25 s, `minCharacters` 2 — `:104-105`.
- Endpoint also requires `inputLevel <= silenceLevel (0.04)` unless forced — `:97,1190` (a noisy room or residual echo can hold it).

**Streaming?** Yes, but it waits for silence by design.

**Serial?** The answer model does not start at the EOU *signal*; it waits for the *debounced, tick-sampled* commit (speculation aside, Hop 7).

**Contribution.** Measured voice-end → EOU confirm: **0.998 s** (today), 0.807 s (today, barge), 1.179 s, 1.007 s, 0.695 s (2026-09-14 runs); voice-end → committed endpoint **1.06 – 1.21 s** in the warm runs (report `:352,391,407,436`; today 1.063 s). Real-session evidence of the 2.5 s fallback is described in report `:116-121`. Estimate for the composition: ~65 ms capture + ~80–160 ms window + model trailing-silence recognition + 320 ms debounce + 0–100 ms tick.

### Hop 4 — Endpoint pickup (VAD tick)

**What it does.** A `Task { @MainActor }` loop calls `tick()` then sleeps 100 ms — `Activation/AgentCaptureController.swift:862-870`, `Limits.tick = .milliseconds(100)` at `:108`. The EOU callback does not trigger a tick.

**Contribution.** Measured `VOICE_MODEL_EOU_TO_ENDPOINT` **9 – 106 ms** (today 66 ms and 9 ms; 2026-09-14: 35 ms, 88 ms, 106 ms). Pure polling cost; also delayed by any main-actor stall (Hop 11).

### Hop 5 — Turn commit and coordinator gates

**What it does.** `emitTurn` (`:1285-1371`) hard-stops held playback (`userSpeechStarted`), then `RealtimeAgent.handle` → `VoiceConversationCoordinator.handle` (`Agent/VoiceConversationCoordinator.swift:278-312`) → `respond` (`:314-544`): dictionary correction, hesitation check, explicit cancel, entity/naming, pending-intent ack, deterministic tool-shape route (`:371-378`), known-noise gate, availability, then `frontendRequest` (capability inventory + bounded history + playback status + work status, `:666-686`).

**Side effect on the critical path:** `userSpeechStarted` → `VoiceConversationCoordinator.speechStarted()` → `prewarmWorkerModel()` (`:201-230`), which asks `NotesModelRuntime.prewarm(voice: true)` to load and prefill the 4B worker **at the same scheduler class as the voice frontend** (`Formatting/LLM/NotesModelRuntime.swift:326`). See Hop 8.

**Contribution.** Deterministic work: estimate **< 10 ms**. The prewarm side effect is the single largest source of real-session variance (Hop 8).

### Hop 6 — Frontend model: two serial Foundation Models passes

**What it does.** `LocalVoiceFrontend.stream` → `unsharedStream` → `streamSplitDecision` (`Formatting/LLM/LocalVoiceFrontend.swift:280-310,342-479,483-551`):
1. Waits for any prior inference to drain (bounded **2 s**; timeout becomes a hard `FrontendError.unavailable`) — `:312-316,350-356`.
2. `prepare()` (a one-time "Say ready." warmup per process) — `:241-275`.
3. `ComputeScheduler.acquire(.realtimeAgent)` — `:388`.
4. **Route pass**: a fresh `LanguageModelSession(transcript:)`, `streamResponse(generating: LocalVoiceRoute.self, maximumResponseTokens: 64)`, then `.collect()` — fully materialized before anything else happens (`:493-506`; `Formatting/LLM/LocalVoiceDecision.swift:158`).
5. If `answerQuestion`: a **second fresh session** with the answer transcript, streamed (`:537-595`), `maximumResponseTokens` 256 (`Agent/VoiceConversationCoordinator.swift:10`), 25 s deadline (`:437`).

**Prewarm is not used in production.** `stageNextTurn` is called when sustained near speech starts, but in split mode it runs only the one-time `prepare()` and then **throws the staged session away** (`Formatting/LLM/LocalVoiceFrontend.swift:133-139`). Apple's prompt-specific `prewarm` never runs for the route or answer prompt. The report measured what staging buys: **1.471 s unstaged vs 0.555 s staged** after 20 s idle (report `:818`).

**Streaming?** The answer streams. The route does not, and it gates the answer.

**Serial where it could be pipelined?** Yes — the answer cannot start until the route is fully collected; the two sessions are built and prefilled cold one after the other.

**Contribution.** Measured route pass **0.664 s** (today warm), **1.305 s** (today cold), **0.863 s** (build 52). First answer text **0.85 – 1.17 s after the route**. Transcript → first token **1.546 s** today warm, **1.695 s** build 52, **1.069 s** with a 0.84 s speculation head start (build 47). Real sessions: median **1.81 s** (n=15).

### Hop 7 — Speculation during listening

**What it does.** Each accepted partial calls `prepareResponseIfUseful` (`Agent/VoiceConversationCoordinator.swift:162-183`): requires **≥ 4 words**, sleeps **220 ms**, then `LocalVoiceFrontend.speculate` runs the full route + answer against that exact partial (`Formatting/LLM/LocalVoiceFrontend.swift:155-190`). At commit, `stream` reuses it only if the `RequestKey` — system prompt, every message's full content including the playback-status line and history, maxTokens — matches exactly (`:37-62,288-300`).

**Why it rarely hits.**
- Every new partial (~every 80 ms from Parakeet) cancels the previous speculation and restarts from zero, even when only the last word changed and the route is unchanged. Today's run: speculation for "…what a **haiku**" had already **finished routing (0.686 s)** and was answering when "…haiku **is**" cancelled it; the final text then got **no slot** ("Voice speculation miss no-slot") because EOU arrived inside the 220 ms debounce.
- The key contains `AgentSession.latestVoiceDeliveryContext` (`Agent/VoiceConversationCoordinator.swift:682`, `Agent/RealtimeAgent.swift:1081-1092`). In a barge-in turn the old reply's delivery flips to "interrupted" in `emitTurn` *after* speculation started, so an interruption turn can never hit.
- Measured hits: build 52 head start **21 ms**; build 47 **0.843 s** (still 1.069 s to first token); today **miss**.

**Contribution.** Currently ~0 s saved in most turns; potential **0.5–1.5 s**.

### Hop 8 — Worker-model contention (the real-session outlier)

**What it does.** `speechStarted()` prewarms the worker LLM once per session. `prepareForConversation(workClass: .realtimeAgent)` loads weights and prefills the voice-routing system prompt (~1 100 tokens) while **holding the single `ComputeScheduler` lane at `.realtimeAgent`** (`Formatting/LLM/NotesModelRuntime.swift:326,347-358,684`). The voice frontend acquires the **same class** (`Formatting/LLM/LocalVoiceFrontend.swift:248,388`). Equal priority does not preempt (`Core/Compute/ComputeJob.swift:45-47`); the queue is FIFO within a priority (`Core/Compute/ComputeScheduler.swift:99-122`). `acquire` is a plain `withCheckedContinuation` with **no cancellation handler** (`:142-152`), so a cancelled speculation whose native task is parked in `acquire` stays alive. `serialBarrier()` waits on that `nativeGeneration` (`Formatting/LLM/LocalVoiceFrontend.swift:214-222`), and the next committed turn's 2 s `waitForPriorInference` times out into `FrontendError.unavailable` → "The local voice model failed while preparing that response."

Even when the lane isn't the problem, llama.cpp Metal prefill and Foundation Models share GPU/ANE and memory bandwidth on a 16 GB M3.

**Measured (2026-09-22 real session, `metrics.jsonl` + `agent-audit.jsonl`).**
- 20:17:01 — worker `model.queue` 3.49 s + `model.load` 3.16 s; voice transcript→first token **3.216 s**; next turn 20:17:08 **failed** `frontend_unavailable`.
- 21:50:30 / 21:50:34 — two voice turns fail with `frontend_unavailable` after **2.016 s** and **2.004 s**, which matches the 2 s barrier exactly. Worker `model.queue` 5.93 s at `class=realtimeAgent`; `model.load` 5.71 s; `model.prefill` **8.03 s** for 1 104 tokens (uncontended: 2.2 s).
- 21:50:37 — next voice turn **8.258 s** to first token, overlapping that 8 s prefill.
- 22:17:26 — voice turn **8.764 s** to first token, overlapping `model.load` + prefill.
- Report `:640-646`: in the 16:52 session the background load took 18.3 s and prefill 22.2 s for 258 tokens during the conversation.

**Contribution.** **+1.5 to +7 s** on affected turns, and hard failures. It affects the first turn of every session in which the worker isn't already resident.

### Hop 9 — Clause chunking for TTS

**What it does.** `AgentToolSpeechTracker.receive` (`Agent/RealtimeAgent+ToolLoop.swift:107-129`) → `RealtimeAudioSession.appendSpokenReply` → `StreamingSpeechBuffer.append/flush` (`Agent/Speech/StreamingSpeechBuffer.swift:38-93`). A clause is enqueued only when it ends in `.` `!` `?` `;` or `—` (`:107-113`); **commas are not boundaries**. Each delta re-runs `spokenForm` over the whole buffer. Replies over `shortLimit` 280 characters make `spokenForm` return empty (`Agent/Speech/AgentSpeechPolicy.swift:16,20-32`), so a long answer **goes silent mid-stream** after its early clauses (a correctness issue as well as a perceived-latency one).

**Streaming?** Yes, at clause granularity.

**Contribution.** Measured first token → first TTS **0.618–0.636 s** in 2026-09-14 pipelines, minus synthesis and render, leaves **~0.28–0.30 s of clause buffering**. Today's first clause ("Hey there, I hear you.") arrived almost immediately, so buffering was ≈0 and the span was **0.400 s**. Real sessions: `first_token_to_first_tts` p50 **0.305 s**, max 1.344 s.

Side observation: under the self-test harness the answer opens with filler ("Hey there, I hear you. That's a beautiful way to think —", "Hey there, I know it can feel tricky sometimes —"). That delays *meaningful* audio by one or two clauses (~1–2 s of speech). The user's own `persona.md` says "answer first, no filler", so production may differ; verify on the live persona.

### Hop 10 — TTS synthesis and playback (Pocket, the selected voice here)

**What it does.** `AgentSpeechSynthesizer.enqueueClause` starts the clause if idle, otherwise queues it (`Agent/Speech/AgentSpeechSynthesizer.swift:192-204`). `PocketSpeechBacking.speak` (`Agent/Speech/PocketAgentVoice.swift:170-236`) starts the output engine, calls one-shot `manager.synthesizeStreaming` **per clause** (`:63-72`), and schedules each 80 ms frame (1 920 samples @ 24 kHz) with `.dataPlayedBack`. First-audio acknowledgement = the first frame *finished playing* (`:215,262-279`). When a clause drains, `finishIfDrained` **stops the engine** (`:281-291`). The **next clause's synthesis starts only after the previous clause has fully played** (`advanceQueue`, `Agent/Speech/AgentSpeechSynthesizer.swift:348-359`).

**Constants.** Warmup bounded 8 s (`PocketAgentVoice.swift:47`); a clause waits up to 10 s for `prepare()` (`:68`); ducked volume 0.65 (`Agent/RealtimeAudioSession.swift:49`).

**Serial where it could be pipelined?** Yes, twice:
- No synth-ahead: clause N+1 isn't generated while clause N plays, so each sentence boundary pays first-PCM plus engine start plus one buffer (**estimate 0.25–0.4 s of dead air per boundary**).
- FluidAudio's `PocketTtsSession` (persistent voice KV and Mimi decoder state, `enqueue()` per utterance) is used only for warmup (`PocketAgentVoice.swift:41-60`), not for playback.

**Contribution.** Measured first PCM **0.214–0.281 s** warm (build 52, today), **0.058 s** after warmup in build 26–29, **0.553 s** cold session, **6.03 s** in a cold process (Pocket model load 12.6 s today). Render acknowledgement **0.097–0.118 s**; it includes engine start and one full 80 ms frame, so it overstates true onset by up to 80 ms. Physical output latency is unmeasured (estimate 10–30 ms on built-in speakers).

### Hop 11 — Main-actor hub

Everything that sequences the turn is `@MainActor`: `AgentCaptureController` (ASR consumer, VAD tick, EOU callbacks, per-buffer level `Task`s at 10 Hz, island updates `:496,912`), `RealtimeAudioSession` (echo masking over every partial, `:188-283`), `VoiceConversationCoordinator`, `StreamingSpeechBuffer`, `AgentSpeechSynthesizer`, `PocketSpeechBacking` (the frame loop and every per-frame played callback). `VoicePlaybackReference.stopped()` does a **`lane.sync`** onto the echo lane from the main actor (`Agent/Speech/VoicePlaybackReference.swift:34`) on every clause end and stop.

**Evidence of stalls.** The file feeder is a main-actor task pacing at absolute deadlines. Its max pacing slip was **0.500 s** and **0.633 s** in today's pipeline runs and **0.340 s** in today's barge run, against **0.023–0.067 s** on 2026-09-14 (`VOICE_FILE_MAX_PACING_LAG`). The main actor is now being blocked for up to half a second during a voice turn. The cause isn't attributed (needs an Instruments hang trace), but any such stall delays the endpoint tick, the EOU commit, clause enqueue and frame scheduling equally.

### Hop 12 — Barge-in and interruption

**Path.** Energy alone never pauses output while the assistant is speaking (`noteLevel` requires `!isSpeaking || nearCandidate`, `Activation/AgentCaptureController.swift:893-903`). The acoustic near-candidate pause (`considerListeningCandidate`, `:916-933`) is **not wired to the live mic path**; only self-tests call it. Playback pauses only in `considerSpeechInterruption` (`:1095-1143`), which needs **recognized text of ≥ 2 characters**, speech ≥ `minSpeech` 0.25 s, not a hesitation/backchannel/in-flight repeat, then `pauseForListening` (`Agent/RealtimeAudioSession.swift:389-405`). A pause auto-resumes after `listeningQuietRelease` 0.25 s of quiet or `listeningMaximumUnrecognizedHold` 2.5 s (`:70-71,421-430`). The hard stop happens only at the committed endpoint (`emitTurn` → `userSpeechStarted` → `noteUserSpeech`, `:435-451`).

**Measured.** Voice onset → reversible pause **0.838 s** (today), 0.846, 0.849, 0.835, 0.848, 0.961 s (earlier builds). ASR partial → pause **0.07–1.4 ms**, so the gate is the ASR itself. Onset → hard stop 2.45–2.58 s (audio already paused). `agent.barge_in_to_tts_stopped` in real sessions: p50 **12 ms**, max 15 ms (n=10). The stop operation itself is fast; *detection* costs ~0.85 s.

**Echo handling cost.** Speex runs inline on the delivery lane (a few ms per 100 ms batch, estimate). The larger cost is policy: because echo leaks into ASR (physical runs show the full reply re-recognized by Apple, `voice-investigation/…/nextnotes-voice-echo-default-67.txt`), the system can't trust energy and must wait for words, which is exactly what makes barge-in slow. Output is ducked to 0.65 while speaking.

---

## 2. Latency budget

Speech end → first audible syllable, warm, uncontended unless noted.

| # | Hop | Current (measured unless "est.") | Target | Evidence |
|---|---|---|---|---|
| 1 | Capture batch + convert + Speex AEC | 63–71 ms (18 ms with sink capture) | 15–25 ms | report `:267,281`; `Core/AudioCaptureHub.swift:279`; `Agent/AcousticEchoProcessor.swift:60` |
| 2 | Voice end → Parakeet EOU confirm (160 ms chunk, 320 ms debounce) | 0.70–1.18 s (today 0.998 s) | 0.30–0.45 s | `Activation/LocalVoiceTurnDetector.swift:8`; pipeline logs |
| 3 | EOU → committed endpoint (100 ms tick) | 9–106 ms | ≤ 5 ms | `Activation/AgentCaptureController.swift:108,862-870` |
| 3b | Fallback endpoint (EOU silent / not ready) | 2.5 s, or 0.9 + 0.35 s | ≤ 0.6 s | `:100,103,1186` |
| 4 | Coordinator gates + request build | < 10 ms (est.) | < 10 ms | `Agent/VoiceConversationCoordinator.swift:314-423,666-686` |
| 5 | Frontend route pass (structured, `collect()`) | 0.66–1.31 s | 0 (parallel) or ≤ 0.25 s | `Formatting/LLM/LocalVoiceFrontend.swift:493-506` |
| 6 | Answer session → first answer text | 0.85–1.17 s | 0.25–0.40 s (prewarmed prefix) | `:537-595`; report `:818` |
| 5+6 | **Transcript → first model text** | pipeline 1.07–2.51 s; **real median 1.81 s** (n=15) | ≤ 0.40 s | `metrics.jsonl` |
| 7 | Worker-LLM contention / lane wait / 2 s barrier | +0 to +7 s; 3/15 real turns failed at ~2.0 s | 0 | `NotesModelRuntime.swift:326`; `ComputeScheduler.swift:142-152`; `LocalVoiceFrontend.swift:312-316` |
| 8 | First-clause buffering (`.!?;—` only) | ~0–0.30 s | ≤ 0.10 s | `Agent/Speech/StreamingSpeechBuffer.swift:107-113` |
| 9 | Pocket first PCM | 0.21–0.28 s warm; 0.55 s cold session; 6.0 s cold process | 0.06–0.10 s | pipeline logs; report `:903-907` |
| 10 | Engine start + first 80 ms frame played (ack) | 0.097–0.118 s | 0.03–0.05 s | `Agent/Speech/PocketAgentVoice.swift:215,262-291` |
| 11 | Device output latency | unmeasured (est. 10–30 ms) | same | — |
| | **Total** | **2.83–3.58 s** (2026-09-14), **3.10 s** (today warm), **10.4 s** (today cold) | **0.6–0.9 s** | |
| — | Gap between spoken sentences | est. 0.25–0.40 s per boundary (no synth-ahead) | ~0 | `AgentSpeechSynthesizer.swift:348-359` |
| — | Barge-in: onset → playback paused | 0.835–0.961 s | ≤ 0.20 s (duck), ≤ 0.35 s (pause) | report; `AgentCaptureController.swift:1095-1143` |
| — | Barge-in: stop operation | 4–15 ms | same | `metrics.jsonl` |
| — | Session start: EOU model prepare (per session) | 1.67–3.04 s warm; 9.1–12.7 s cold | 0 (resident) | pipeline/barge logs; `AgentCaptureController.swift:514-523` |

---

## 3. Top 10 causes of lag, ranked by impact, with fixes

### 1. The worker LLM competes with the voice frontend for the same lane and hardware, and a stuck lane becomes a hard failure
**Impact:** +1.5 to +7 s on affected turns (real 3.2 s, 8.3 s, 8.8 s) plus "The local voice model failed…" after exactly ~2.0 s (3 of 15 real turns on 2026-09-22).
**Where:** `Agent/VoiceConversationCoordinator.swift:201-230` (prewarm at first speech), `Formatting/LLM/NotesModelRuntime.swift:326,347-358` (prewarm holds `.realtimeAgent` through load and prefill), `Formatting/LLM/LocalVoiceFrontend.swift:248,388` (frontend takes the same class), `Core/Compute/ComputeScheduler.swift:142-152` (non-cancellable acquire), `Formatting/LLM/LocalVoiceFrontend.swift:214-222,312-316` (barrier waits on a native task stuck in acquire; 2 s timeout → failure).
**Fix:**
- Stop routing Foundation Models through `ComputeScheduler`. FM is a separate system service and needs no llama native-context reservation. If a lane is kept, give it a new class that outranks `.realtimeAgent`, e.g. `.realtimeConversation`.
- Prewarm the worker at `.background`, and only when there is a reason: the route says `startExternalTask`, or the session has been idle for a while. Not on every first utterance. Keep `checkpoint` yielding in prefill so a conversation turn preempts it.
- Make `acquire` cancellation-aware (`withTaskCancellationHandler` that removes the waiter from `queued` and resumes it).
- Replace the 2 s barrier failure with "proceed on a fresh session". Separate FM sessions don't share state.

### 2. Two serial Foundation Models passes, both cold
**Impact:** route 0.66–1.31 s is pure dead time before the answer's own 0.85–1.17 s TTFT. Apple's prompt prewarm, measured at 1.47 → 0.56 s, is disabled for both.
**Where:** `Formatting/LLM/LocalVoiceFrontend.swift:483-551` (route `collect()` then answer), `:133-139` (staged session discarded in split mode).
**Fix:**
- Start the answer stream **concurrently** with the route and hold its deltas in a buffer. Release them if the route resolves to `answerQuestion`; drop them otherwise. The deterministic `toolShapeRoute` already catches most action requests before the model.
- While the user speaks, build the actual route and answer `LanguageModelSession(transcript:)` objects (instructions + history, which are known before the final words) and call `prewarm(promptPrefix:)` on both.
- Cap the route at a single enum token (drop `taskNumber` unless there are running jobs) so its decode is as short as possible.

Expected: −0.7 to −1.2 s.

### 3. End-of-utterance takes ~1 s, with 2.5 s and 1.25 s fallbacks
**Impact:** 0.70–1.18 s measured voice-end → EOU; +9–106 ms tick; 2.5 s whenever EOU is missed while ready.
**Where:** `Activation/LocalVoiceTurnDetector.swift:8` (`eouDebounceMs: 320`), `Activation/AgentCaptureController.swift:862-870,1071-1080` (tick-only commit), `:1186` (2.5 s fallback).
**Fix:**
- Two-phase endpoint. On the **first raw EOU signal** (debounce 0–160 ms), commit a *provisional* turn that starts the answer (no speech sink). Confirm at 320 ms. If speech resumes, cancel. This is the Realtime-API pattern: start generation early and gate audio.
- Call `tick(force:)` directly from `noteModelEOU` instead of waiting up to 100 ms.
- Lower the 2.5 s fallback to about 1.0 s, gated on silence-level VAD.

Expected: −0.4 to −0.6 s.

### 4. Speculation almost never hits
**Impact:** 0.5–1.5 s of available head start is thrown away. Today: miss. Build 52: 21 ms.
**Where:** `Agent/VoiceConversationCoordinator.swift:162-183` (≥ 4 words, 220 ms debounce, cancel on every partial), `Formatting/LLM/LocalVoiceFrontend.swift:37-62,288-300` (exact `RequestKey`, including the playback-status line at `VoiceConversationCoordinator.swift:682`).
**Fix:**
- Split speculation by stage. The **route** is stable under word-appends: keep a completed route if the final text extends the speculated text by one or two words, and re-run only the answer.
- Remove the volatile playback-status line from the key, or freeze it when the turn starts.
- Drop the 220 ms debounce once the local decoder owns the partial.
- Start the speculation directly from the raw EOU signal (see #3).
- Report the hit rate as a metric (`agent.speculation_hit`) so it can be tracked.

### 5. Barge-in waits for recognized words
**Impact:** voice onset → pause 0.84 s. Humans expect well under 0.3 s, so the assistant talks over the user for most of a second.
**Where:** `Activation/AgentCaptureController.swift:893-903,916-933` (acoustic candidate path not wired), `:1095-1143` (lexical gate).
**Fix:**
- Add FluidAudio's Silero `VadManager` (already a dependency, unused) on the AEC-cleaned stream.
- On VAD speech probability above threshold for ~100–150 ms while speaking, **duck** output to ~0.2 (reversible, safe against echo false positives), rather than pausing.
- Pause on the first local partial, as today, and hard-stop on commit.
- Lower `minSpeech` for the pause decision to ~0.15 s. The Parakeet first word already arrives at 0.84 s, so ducking is what buys the sub-200 ms feel.

### 6. TTS is serialized clause by clause, and the first clause waits for sentence punctuation
**Impact:** first-clause wait up to ~0.3 s; est. 0.25–0.4 s of silence at every sentence boundary; a 280-character cap silences long answers.
**Where:** `Agent/Speech/AgentSpeechSynthesizer.swift:192-204,348-359`, `Agent/Speech/PocketAgentVoice.swift:63-72,170-291`, `Agent/Speech/StreamingSpeechBuffer.swift:107-113`, `Agent/Speech/AgentSpeechPolicy.swift:16,31`.
**Fix:**
- Use one `PocketTtsSession` per reply, and `enqueue()` each clause as soon as it completes. This gives continuous frames, synth-ahead and Mimi state continuity.
- Keep the player and engine running for the whole reply.
- Allow the **first** clause to flush at a comma or after about 6–8 words.
- Apply `spokenForm`'s length cap per clause, not to the cumulative buffer.

### 7. Per-session model preparation and cold starts
**Impact:** EOU prepare 1.67–3.04 s warm and 9.1–12.7 s cold, **every session**, because a new `LocalVoiceTurnDetector` is created and `loadModels()` runs in `startEngine` (`Activation/AgentCaptureController.swift:514-523`). Until it's ready, turns endpoint on the 0.9 + 0.35 s VAD fallback and the decoder then catches up on the backlog (report: 5.08 s catch-up lag in a real session). A cold Pocket load (12.6 s) makes the first reply's first PCM take 6.0 s.
**Fix:**
- Keep one EOU detector resident for the app lifetime and just `reset()` per session.
- Prewarm the EOU model and Pocket at launch or wake-word arm, at background priority, when the voice feature is enabled.
- Treat "voice ready" as all three components ready, and show it.

### 8. 100 ms audio I/O granularity in both directions
**Impact:** about 50 ms mean (100 ms worst) on capture. The output reference is 100 ms late, which hurts AEC and so indirectly forces the lexical barge-in gate (#5). The first-audio ack includes a full 80 ms frame.
**Where:** `Core/AudioCaptureHub.swift:277-282`; `Agent/Speech/VoicePlaybackReference.swift:11`.
**Fix:**
- Promote the existing `AVAudioSinkNode` capture (measured 18 ms vs 63–71 ms) independently of the AEC3 experiments.
- Set the device IO buffer duration to ~10 ms for the Agent session.
- Use a source node (already prototyped behind `--voice-pocket-source`) for Pocket output.

Expected: −50 to −100 ms end to end, plus better AEC alignment.

### 9. The main actor sequences everything, and it now stalls
**Impact:** main-actor pacing slip of 0.34–0.63 s measured today (it was 0.02–0.07 s on 2026-09-14). Any stall directly delays endpoint commit, clause enqueue and frame scheduling.
**Where:** `@MainActor` on `AgentCaptureController`, `RealtimeAudioSession`, `VoiceConversationCoordinator`, `StreamingSpeechBuffer`, `AgentSpeechSynthesizer`, `PocketSpeechBacking`; the per-callback `Task { @MainActor }` hops at `AgentCaptureController.swift:662-711,1071-1091`; `lane.sync` at `VoicePlaybackReference.swift:34`.
**Fix:**
- Take an Instruments "Hangs" and "Swift Concurrency" trace during `--selftest-voice-pipeline` to attribute the stall.
- Move the turn state machine, echo masking and TTS frame scheduling onto a dedicated actor (or a serial executor), and publish UI snapshots at a coalesced ≤ 10 Hz.
- Make `VoicePlaybackReference.stopped()` asynchronous.

### 10. Output engine stop/start per clause and conservative first-audio acknowledgement
**Impact:** est. 30–80 ms per clause for engine start, plus up to 80 ms of the ack being a completed frame. This also means the echo reference and playback-status ledger lag real audio.
**Where:** `Agent/Speech/PocketAgentVoice.swift:176-181,281-291` (engine stop on drain, `stop()` when not continuing), `:215` (`.dataPlayedBack`).
**Fix:**
- Keep the engine running across the reply; stop it only at reply end or after a short idle timeout. To keep AEC's "no zero buffers" rule, gate `feedRendered` by epoch rather than stopping the engine.
- Acknowledge first audio from the render tap's first nonzero sample time, not from the completion of the first frame.

---

## 4. Not the problem (so effort isn't wasted there)

- The **stop operation** itself: 4–15 ms real (`agent.barge_in_to_tts_stopped`).
- **Coordinator deterministic gates** and dictionary correction: negligible.
- **Foundation Models warmup and scheduler wait** in an uncontended run: below 1 ms (report `:439`; today `scheduler_acquire_done 0.000`).
- **EOU queue drops/resets**: 0 in all file-fed runs.
- **Speex CPU**: small next to the batching and policy costs.

## 5. Measurement gaps worth closing (cheap, high value)

1. Add durable `metrics.jsonl` spans for `voice.eou_confirm`, `voice.endpoint_commit`, `voice.route`, `voice.answer_first_text`, `voice.first_clause_enqueued`, `voice.first_pcm`, `voice.speculation_hit|miss(reason)`, and `voice.onset_to_pause`. Today only `transcript_to_first_token` and `first_token_to_first_tts` persist, and the split timings exist only under `--selftest-voice-pipeline`.
2. Tag every `agent.transcript_to_first_token` row with `source=voice|text|worker`. Today voice, text and worker rows share one name, which makes real-session analysis manual.
3. Log `frontend_unavailable` with its sub-reason (barrier timeout vs Apple Intelligence unavailable vs missing latest user). They currently collapse into one code (`Agent/VoiceConversationCoordinator.swift:596-606`).
4. Run a physical speaker→microphone TTFA measurement. All figures above are file-fed or callback-based; true acoustic onset is unmeasured.

## 6. Runs performed for this analysis (installed build, 2026-09-23 17:34)

- `Scripts/run-selftest.sh --selftest-voice-pipeline <say-generated haiku WAV> --voice-feed-10ms`
  - Cold: endpoint via VAD fallback (EOU prepare 12.69 s), `VOICE_PIPELINE_FAILED` for that reason; voice→endpoint 1.407 s, endpoint→audio 8.967 s, route 1.305 s, first PCM 6.033 s.
  - Warm (`scratchpad/pipeline-run2.txt`): EOU sinceVoiceEnd 0.998 s, EOU→endpoint 0.066 s, speculation miss (no-slot), route 0.664 s, first answer text at 1.545 s, first PCM 0.281 s, render 0.118 s; voice→endpoint 1.063 s, endpoint→first audio 2.033 s; max main-actor pacing slip 0.50 s.
- `Scripts/run-selftest.sh --selftest-voice-barge <say-generated "Wait, please stop speaking." WAV>` (`scratchpad/barge-run.txt`): `VOICE_BARGE_OK`; voice→pause 0.838 s, ASR→pause 0.3 ms, voice→stop 2.582 s, EOU sinceVoiceEnd 0.807 s, EOU prepare 9.06 s, max pacing slip 0.34 s.

The unified log had already aged out the info-level voice entries for real sessions. Real-session numbers come from `metrics.jsonl` and `agent-audit.jsonl`.
