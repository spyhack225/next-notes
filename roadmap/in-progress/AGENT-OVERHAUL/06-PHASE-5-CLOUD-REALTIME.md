# Phase 5 — optional cloud realtime frontend (P5-01 … P5-04)

## Current scope — 2026-10-03

All four P5 tasks remain planned. Optional cloud work does not replace the local
full-duplex/ledger/output/consent contracts. Implement P5-01 then loopback P5-04
before provider integrations; reverify the dated API assumptions below at that
time. Gemini retains its declared non-blocking admission condition. No current
cloud implementation, live acceptance or account approval is claimed by the
shutdown and durable-task fixes. See STATUS and
[the remaining checklist](REMAINING-WORK.md#computer-product-journeys-and-optional-cloud).

## Model ownership amendment — 2026-09-30

The owner approved independent appropriate models for Agent, meeting notes and
Dictation cleanup, reusing exact verified artifacts through the existing library.
Read [SHARED-BRAIN](../SHARED-BRAIN/00-README.md) and
[MODULES-ACTIVATION](../MODULES-ACTIVATION/00-README.md) before changing
model selection/loading/download/deletion. Their revised SB tasks own artifact
identity, role independence and request binding; this roadmap owns Agent behavior,
latency/full duplex and capacity. Coordinate shared files in BUILD-ORDER.

Existing one-resident-file/Agent-centric descriptions below are baseline or migration
constraints, not permission to force meetingNotes or cleanup onto the Agent choice.
Keep existing tokens and per-role cloud IDs/consent. MiniCPM cleanup + Apple guard/
fallback is concurrent OpenCode work; reuse its verified file, not its settings or
prompt. An awaited deferred swap cannot execute as if the requested file loaded.
Do not add a runtime/store/queue per module or sacrifice a voice lease to background
work. Same weights can serve independent requests; separate contexts/residency are
measured capacity decisions under P3-07. Implementation/gate states remain unchanged.

**This phase is optional and gated on Phase 3.** Do not start it until P3-03 (`TaskBridge`),
P3-04 (`OutputScheduler` / `AgentDelivery`), P3-05 (receipt-first frontend contract), P3-08 (spoken approvals: `respond_approval` is offered only
under its rule) and P3-06
(`VoiceSession` reducer with `TurnID`/`OutputID`/`TaskID`) are merged and their self-tests are
green. P4-01 (Now block) and P4-09 (`agentCloudConsent`) must also be merged, because the cloud
frontend reuses both. If any of those is missing, stop and record "blocked on P3-xx" in
`STATUS.md`.

Paths are relative to `Sources/NextNotes/` unless stated. API facts were checked on 2026-09-23
against the vendors' documentation (links at the end). Vendor model names change often: every
model id below is a **default stored in Settings**, never a constant compiled into logic.

---

## Overview

### What this phase adds

An opt-in mode in which the conversational frontend is a cloud speech-to-speech model (OpenAI
Realtime first, then Gemini Live), for people who want ~0.3–0.8 s replies (E §2.2, estimate
including network) and accept that their voice leaves the Mac. Everything else is unchanged:

| Stays local, unchanged | Replaced in cloud mode |
|---|---|
| microphone capture, Speex/AEC3 echo cancellation (`Agent/AcousticEchoProcessor.swift`), the playback reference ring (`Agent/Speech/AgentPCMRenderer.swift`) | local ASR + EOU for the conversational turn |
| Silero VAD ducking (P2-05) | the Apple Foundation Models frontend (`LocalVoiceFrontend`) |
| `VoiceSession` reducer, `TaskBridge` ledger, `OutputScheduler` timing and acknowledgement rules | local TTS (Pocket/Kokoro) for the conversational reply |
| workers (`LocalToolLoopWorker`, ACP), every tool, every approval | |
| the brief/consent rules for what a cloud reader may see | |

The frontend only talks. It gets the Phase 3 frontend tools (`spawn_task`, `task_status`,
`cancel_task`, `respond_approval`) and no others. Work still runs on this Mac.

It also closes C11 for users who opt in: today there is no conversation at all when Apple
Intelligence is unavailable (`Coordinator:415-422`, `FoundationModelFormatter.unavailableReason`).

### Verified API facts (2026-09-23)

| | OpenAI Realtime | Gemini Live |
|---|---|---|
| Default model id | `gpt-realtime-2.1` (update of `gpt-realtime-2`; 128K context, 32K max output) | `gemini-3.8-live` (stable; replaces `gemini-3.1-flash-live-preview`) |
| Transport | WebSocket `wss://api.openai.com/v1/realtime?model=<id>`, `Authorization: Bearer <key>` (verify the exact URL on the day; the GA dialect needs no beta header) | WebSocket `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent`; key as `?key=` query parameter per the docs (try the `x-goog-api-key` header first; see P5-03) |
| Input audio | PCM16 LE mono **24 kHz**, base64 in `input_audio_buffer.append` (`session.audio.input.format {type:"audio/pcm", rate:24000}`) | PCM16 LE mono **16 kHz**, `realtimeInput.audio` with `mimeType "audio/pcm;rate=16000"` |
| Output audio | PCM16 24 kHz in `response.output_audio.delta` | PCM16 24 kHz in `serverContent.modelTurn.parts[].inlineData` |
| Turn detection | `session.audio.input.turn_detection {type:"semantic_vad", eagerness:"low\|medium\|high\|auto", create_response, interrupt_response}`; server events `input_audio_buffer.speech_started` / `speech_stopped` | automatic activity detection (`realtimeInputConfig.automaticActivityDetection`, `startOfSpeechSensitivity`, `endOfSpeechSensitivity`, `prefixPaddingMs`, `silenceDurationMs`); manual `activityStart`/`activityEnd`; interruption as `serverContent.interrupted` |
| Context injection | `conversation.item.create` (`message` with role `user`/`assistant`/`system`, or `function_call_output {call_id, output}`) | `clientContent {turns, turnComplete}` |
| Per-response control | `response.create {instructions, tool_choice, metadata, conversation:"auto"\|"none", output_modalities, input}`; `response.cancel`; `conversation.item.truncate {item_id, content_index, audio_end_ms}` | none per response; function responses carry `scheduling: INTERRUPT \| WHEN_IDLE \| SILENT` |
| Async tools | built in: "the model can continue a fluid conversation while waiting on results" | `behavior: NON_BLOCKING` per function declaration; **default** on `gemini-3.8-live`; **not supported** on `gemini-3.1-flash-live`; `BLOCKING` still selectable on 3.8 |
| Limits | 128K context | audio-only session 15 min; `goAway`, `sessionResumptionUpdate`; context window compression |
| Price | `gpt-realtime-2.1`: audio in $32 / 1M tokens, cached audio in $0.40, audio out $64, text in $4, text out $24 | not checked here — read the pricing page before shipping |

Known edge (not ours, but instructive): LiveKit's Gemini 3.8 plugin (issue #7302, opened
2026-09-16) sets `behavior`/`scheduling` per session instead of per tool and holds tool results
until queued speech finishes, which defeated async tools in their tests. This design sets
`behavior` per declaration and never lets the transport hold a result: timing is
`OutputScheduler`'s job.

A trap from qwen-audio-agent's GA adapter
(`roadmap/references/qwen-audio-agent-main/server/src/voice/providers/ga-protocol.mjs`): if the
client supplies conversation item ids, the GA dialect requires a type prefix (`msg_`, `fc_`,
`fco_`) and rejects anything else. Do not supply item ids; read the server-assigned ones.
The same adapter tags `response.create` with `metadata` to tell a requested response from one
the server VAD started — copy that.

A trap from this repo (AGENTS.md, `--selftest-cdp`): JSON must go out as **text** WebSocket
frames. `BrowserCDPClient` sends `.string(...)` for this reason (`Computer/BrowserCDPClient.swift:841`).

### Cost and latency notes

- Latency (estimate, E §2.2 and §2.4): 0.3–0.8 s voice-to-voice including network, versus the
  local target of ≤ 0.9 s after Phase 2. The gain is real only on a good connection; a 150 ms
  RTT adds ~0.3 s per turn (two hops). P5-04 prints the fixture's turn latency; the real number
  must be measured with `--selftest-voice-latency` (P2-01) against the live service and recorded.
- Cost (estimate): OpenAI bills audio by tokens. Assuming ~10 audio tokens per second of user
  speech and ~20 per second of model speech (estimate; confirm from `response.done.usage` on the
  first live run), one minute of balanced conversation is ~300 in + ~600 out tokens ≈ **$0.05**,
  plus text context re-sent per response (mostly cached at $0.40/1M). Long sessions cost more
  because instructions and history are billed per response. Guards in P5-02: idle close after
  60 s without speech, a per-session cap of 15 minutes, a daily cap (default 60 minutes), and a
  visible "online voice used today" counter.

### Order

P5-01 (seam, settings, consent, key store, converter) → P5-04 (fixture server and self-test,
red against a stub) → P5-02 (OpenAI) → P5-03 (Gemini, only if the gate in P5-03 passes).

### Exit gate for Phase 5

1. `Scripts/run-selftest.sh --selftest-realtime-cloud` → `REALTIME_CLOUD_OK` for every provider
   implemented (the OpenAI scenario always; the Gemini scenario only if P5-03 shipped).
2. With the setting off (default), `--selftest-voice-conversation`, `--selftest-concurrent-voice`,
   `--selftest-voice-delivery`, `--selftest-voice-session-reducer` are unchanged and green.
3. `make acceptance TIER=core` — no regression.
4. `--selftest-ui-strings` OK.
5. One live run per shipped provider, recorded in `STATUS.md` (not CI; needs a key the executor
   may not have — if none, record "live run pending, key not available"): end of speech → first
   audio median over 10 turns, one spawned task delivered after a turn, one barge-in.

### Rules from AGENTS.md that apply to every task here

- A brief allowed for a local reader is not allowed for a cloud one. Every piece of context the
  cloud frontend receives is assembled for a cloud reader, with each source's own consent.
- Output and work have separate lifetimes; only explicit cancellation invalidates work; effects
  wait for the latest input to be classified (`mayCommitEffect`); a deterministic gate may only add.
- Echo suppression requires the real producer: cloud audio must be played through
  `AgentPCMRenderer` so the reverse stream is exact. A fake playback callback proves nothing.
- Red means recording only. The island keeps the red dot while the microphone is open.
- API keys live only in the Keychain (data-protection keychain, as `OpenRouterKeyStore` and
  `HuggingFaceAccessStore` do). Never in `UserDefaults`, logs, URLs you print, or crash reports.
- Self-tests never touch the network or the user's stores. The loopback fixture is the only
  server a self-test talks to.
- `MainActor.assumeIsolated` crashes; never use it.
- Build with `make build`; install with `make install OPEN=0`; self-tests with
  `Scripts/run-selftest.sh`, one at a time, foreground.

---

### P5-01 — `FrontendResponder` seam for cloud frontends

**Finding(s):** E §2.3 item 6; decision doc §5 Phase 5; C11  **Effort:** 3 days  **Depends on:** P3-03, P3-04, P3-05, P3-06, P3-08, P4-01, P4-09  **Unblocks:** P5-02, P5-03, P5-04

**Why (what the user experiences today):** voice replies take 3.10 s warm from end of speech to
first audio (A §0); Phase 2 targets ≤ 0.9 s. Some users will trade privacy for ~0.5 s, and users
without Apple Intelligence have no conversation at all. Phase 3's `FrontendResponder` was built
for a text frontend (Apple FM route/answer, then local TTS); a speech-to-speech frontend owns its
own turn detection, transcript and audio, so the seam needs capability flags and an audio path.

**Files you will change:**
- `Agent/Duplex/FrontendResponder.swift`, where P3-05 declared the concrete `actor FrontendResponder`
  (grep `actor FrontendResponder`). Turn `FrontendResponder` into a `protocol FrontendResponder: Actor`
  with P3-05's surface (`stream`, `speculate`, `cancelSpeculation`, `phrase`) plus `capabilities`, and
  rename the actor to `LocalFrontendResponder: FrontendResponder`. Its call sites (coordinator,
  `OutputScheduler`) reach the responder the `VoiceSession` shell selected instead of `.shared`.
  Extend, do not fork: one protocol, one local conformer.
- new `Agent/CloudFrontend/CloudFrontendCapabilities.swift`
- new `Agent/CloudFrontend/CloudRealtimeTransport.swift` (WebSocket abstraction; the fixture implements the same wire)
- new `Agent/CloudFrontend/RealtimePCMConverter.swift`
- new `Agent/CloudFrontend/RealtimeCloudKeyStore.swift`
- new `Agent/CloudFrontend/CloudFrontendPolicy.swift` (consent, context assembly, result sharing)
- new `Agent/CloudFrontend/CloudStreamSpeechBacking.swift` (cloud PCM → `AgentPCMRenderer`)
- `Agent/Duplex/VoiceSession.swift` (the P3-06 shell) — frontend selection and fallback live in the
  shell; the pure reducer in `VoiceContracts.swift` only gains events if a new one is needed
- `Support/Settings.swift` — new keys
- new `UI/Settings/RealtimeCloudSection.swift`, `UI/Settings/RealtimeCloudConsentSheet.swift`; `UI/Settings/AgentSettingsTab.swift` (insert after `FastListeningSection()`, `:22`)

**Read for context (do not change):** `Formatting/LLM/LocalVoiceFrontend.swift` (today's frontend);
`Activation/AgentCaptureController.swift:445-452` (canonical capture format Float32/16 kHz/mono);
`Agent/Speech/AgentPCMRenderer.swift:10-60, 246-420` (16 kHz Float32 source node, reverse
reference ring written in the render callback, `enqueue(_:token:volume:)`, `renderedSamples`);
`Agent/Speech/PocketSourceSpeechBacking.swift` (the backing shape to copy);
`Formatting/LLM/OpenRouterLLMProvider.swift:63-140` and `Support/ModelLibrary/HuggingFaceAccessStore.swift`
(Keychain pattern); `Knowledge/KnowledgeTools.swift:166-177`, `Knowledge/Files/FileIndexTools.swift:60-68`
(reader-based consent gates); `Meetings/MeetingNotesContext.swift:127-181` (per-reader brief);
`roadmap/references/qwen-audio-agent-main/server/src/voice/realtime-provider.mjs` (capability flags:
`singleResponseSlot`, `perResponseInstructions`, `acknowledgesSessionUpdate`).

**Current behaviour:** no cloud realtime code exists (grep for `realtime` providers finds none;
`--selftest-realtime` at `NextNotesApp.swift:784` (grep `"--selftest-realtime"`) is an unrelated local test — flags match by exact
`Set` membership, so `--selftest-realtime-cloud` is a distinct flag). `LLMProviderID`
(`Formatting/LLM/LLMProvider.swift:11-18`) has one cloud case, `.openRouter`, and every consent gate
reads it as "a cloud reader".

**Target behaviour:**
1. `FrontendResponder` exposes `capabilities: FrontendCapabilities`:
   ```swift
   struct FrontendCapabilities: Sendable, Equatable {
       var ownsAudioOutput: Bool          // speech-to-speech: produces PCM, no local TTS
       var ownsTurnDetection: Bool        // server VAD decides end of turn
       var producesUserTranscript: Bool
       var perResponseInstructions: Bool  // OpenAI yes, Gemini no
       var singleResponseSlot: Bool       // queue response requests; never two in flight
       var leavesDevice: Bool             // true for every cloud frontend
   }
   ```
   `LocalFrontendResponder` reports all false. The `VoiceSession` shell branches on flags, never on
   provider names.
2. Cloud frontends consume audio and emit events. Add to the protocol (or a sub-protocol
   `AudioFrontendResponder: FrontendResponder`):
   ```swift
   func start(context: CloudSessionContext) async throws      // opens the socket, sends session config
   func appendInput(_ pcm16k: AVAudioPCMBuffer) async          // cleaned, post-AEC, 16 kHz Float32
   func inject(_ item: FrontendContextItem) async throws       // result facts etc., "not a new request"
   func requestResponse(_ request: FrontendResponseRequest, output: OutputID) async throws  // the OutputID is minted by OutputScheduler (Phase 3 §2.1: only the VoiceSession shell and OutputScheduler mint ids)
   func cancelResponse(_ id: OutputID, playedMilliseconds: Int?) async
   func stop(reason: String) async
   var events: AsyncStream<FrontendEvent> { get }
   ```
   `FrontendEvent`: `.userSpeechStarted`, `.userSpeechStopped`, `.userTranscript(TurnID, String)`,
   `.decision(TurnID, FrontendDecision)` (a frontend tool call mapped to P3's decision cases:
   `spawn_task` → spawn, `task_status` → status, `cancel_task` → cancel, `respond_approval` →
   respondPermission), `.audio(OutputID, AVAudioPCMBuffer)` (already converted to 16 kHz Float32),
   `.responseDone(OutputID, usage: CloudUsage?)`, `.failed(CloudFrontendError)`.
   `.userSpeechStarted` is turned into `interrupt(.provisional(turn))` by the `VoiceSession` shell; a transcript into
   the committed turn.
3. **Audio.** Capture stays in `AgentCaptureController` and the AEC processors; the cloud frontend
   receives the cleaned 16 kHz stream (the same one Parakeet/EOU read today). Output goes through
   `CloudStreamSpeechBacking` → `AgentPCMRenderer.enqueue`, so the reverse reference ring carries the
   exact played samples and `OutputScheduler` gets its first-audible-frame acknowledgement exactly as
   for Pocket. No `AVAudioPlayer`, no second output graph.
4. **`RealtimePCMConverter`** (one `AVAudioConverter` per direction, reused for the session):
   - 16 kHz Float32 → 24 kHz PCM16 LE (OpenAI input): resample, clamp to [-1, 1], scale by 32767,
     round, little-endian `Data`, base64. Chunk to 40 ms (960 samples at 24 kHz) or the capture batch,
     whichever is smaller once P2-08 lands.
   - 16 kHz Float32 → 16 kHz PCM16 LE (Gemini input): no resample.
   - 24 kHz PCM16 LE → 16 kHz Float32 (both outputs): decode base64, Int16 → Float/32768, resample.
   - Keep a converter tail between chunks (do not reset per chunk) to avoid clicks.
5. **Key store.** `RealtimeCloudKeyStore` — same shape as `HuggingFaceAccessStore`: data-protection
   keychain, `service = "ai.pivotstudio.nextnotes.realtime.<provider>"` (`openai`, `gemini`),
   `account = "api-key"`, synchronous `key` never called on the main actor, `keyAsync()` cached,
   `save`, `clear`, `invalidateCache()`. If the user already has an OpenAI key elsewhere, do not read it.
6. **Settings** (`Support/Settings.swift`, `UserDefaults` keys in `Keys`):
   `realtimeCloudProvider: String` (`off`|`openai`|`gemini`, default `off`),
   `realtimeCloudModelOpenAI: String` (default `gpt-realtime-2.1`),
   `realtimeCloudModelGemini: String` (default `gemini-3.8-live`),
   `realtimeCloudConsentVersion: Int` (0 = never agreed; the sheet's current version is 1),
   `realtimeCloudDailyMinutes: Int` (default 60), `realtimeCloudUsageDay: String`,
   `realtimeCloudUsageSeconds: Int`.
7. **Consent.** Cloud mode starts only if `realtimeCloudProvider != off`, a key exists, and
   `realtimeCloudConsentVersion >= RealtimeCloudConsent.currentVersion`. Changing provider re-asks.
   The sheet (plain words, no developer terms) says exactly:
   - Title: `Talk to an online voice model?`
   - Body: `While this is on, what you say to the Agent is sent as audio to <OpenAI|Google>, and its
     spoken replies come back from there. Your conversation, your name, how you asked the Agent to
     sound, the time and your next meetings go with it. The Agent's work — reading your mail,
     calendar and files, and anything that needs your approval — still happens on this Mac.
     Results are read back through the online model only when you have allowed that kind of
     information online. Dictation and meetings never use this.`
   - Buttons: `Turn on`, `Cancel`. A `Turn off` switch stays in `RealtimeCloudSection`.
8. **What the cloud frontend sees** (`CloudFrontendPolicy.sessionInstructions()`), always assembled
   with the reader bound to a cloud reader —
   `KnowledgeGraphScope.$reader.withValue(.openRouter) { … }`, the one cloud value every existing
   gate understands (document this proxy in a comment):
   - the P3-05 frontend rules (receipt-first, no filler, one acknowledgement) and the frontend tool
     schemas;
   - persona short card (P4-03's voice card) — covered by this consent;
   - grounding `text(compact: true)` — folders are withheld automatically unless the file index's
     cloud consent is on (`FileIndexScope.mayRead`);
   - Now block (P4-01) `.compact` — calendar and front-app lines only when `agentCloudConsent`
     (P4-09) is on; otherwise time only;
   - memory profile only when `agentCloudConsent` is on;
   - never: `MeetingNotesBrief`, passages, file names, graph nodes, tool results, meeting transcripts.
   A context string assembled for a local reader is never passed to a cloud frontend: the policy
   builds its own strings; add a `precondition`-free runtime check that fails the session start (and
   logs) if a string built under a local reader is passed in (tag strings with a `ReaderClass`).
9. **Results.** `CloudFrontendPolicy.mayShare(_ event: TaskEvent) -> Bool`. P3-03's
   `TaskEvent.completed(TaskID, result:artifacts:)` case gains a fourth associated value
   `sources: Set<ResultSource>` (update every pattern match; `TaskRecord` gets the same field) (`calendar, mail, drive, docs, files, knowledge, graph,
   memory, web, app, unknown`); the tool executor fills it from the tool namespaces used. Allowed
   online: `calendar, mail, drive, docs, web, app` (covered by the consent text);
   `files` only with the file index cloud consent; `knowledge, graph` only with
   `knowledgeGraphCloudConsent`; `memory` only with `agentCloudConsent`; `unknown` never. When not
   allowed, `OutputScheduler` injects only `A task you asked for is finished. The result is on screen.`
   and the island shows the result; the full text never leaves the Mac.
10. **Selection and fallback** (the `VoiceSession` shell): on `sessionOpened`, if cloud mode is ready, the session's
    frontend is the cloud responder; otherwise the local one. On `.failed` (socket closed, auth
    error, 5xx, daily cap reached) mid-session: switch to the local responder for the rest of the
    session, speak once locally `I lost the online voice, so I'm answering on this Mac now.`, and
    show the reason in `RealtimeCloudSection`. Work in flight is not touched (separate lifetimes).
11. **UI** (`RealtimeCloudSection`, strings free of developer words): title `Online voice`; picker
    `Off` / `OpenAI` / `Google Gemini`; a secure field for the key with `Save` / `Remove`; `Model`
    text field prefilled with the default; line `Used today: 12 of 60 minutes`; the consent sheet on
    first enable.

**Steps:**
1. Read P3's `FrontendResponder`, `FrontendDecision`, `VoiceSession`, `TaskBridge`, `TaskEvent`,
   `OutputScheduler`, `OutputRequest` as merged. Adapt the signatures above to them; keep the
   requirements.
2. Add `FrontendCapabilities` and the audio protocol; make the local responder report all-false.
3. Implement `RealtimePCMConverter` with unit checks inside the P5-04 self-test (below).
4. Implement `RealtimeCloudKeyStore` by copying `HuggingFaceAccessStore` and changing service/account.
5. Implement `CloudFrontendPolicy` (session instructions, `mayShare`, `ReaderClass` tagging).
6. Implement `CloudStreamSpeechBacking` by copying `PocketSourceSpeechBacking`'s renderer use:
   one renderer token per `OutputID`; `finish` on `.responseDone`; `stop` on interruption.
7. Implement `CloudRealtimeTransport`:
   ```swift
   protocol CloudRealtimeTransport: Sendable {
       func connect(url: URL, headers: [String: String]) async throws
       func sendText(_ json: String) async throws         // always a text frame
       func receive() async throws -> String              // text frames; binary = protocol error
       func close() async
   }
   ```
   Live implementation with `URLSessionWebSocketTask` (`.string` frames, as
   `BrowserCDPClient.swift:828-867`), created from `PrivateURLSession.shared` (P0-19: ephemeral, no
   disk cache), never from `URLSession.shared`. The URL passed to `Log` is the host only.
8. `VoiceSession` shell: frontend selection and the fallback in Target 10; `userSpeechStarted` →
   `interrupt(.provisional(turn))` (duck/pause via `OutputScheduler`), transcript → committed turn with `TurnID`.
9. Settings keys, section, consent sheet. Add the section to `AgentSettingsTab`.

**Do not:**
- Do not send anything before consent and a key exist (P5-04 asserts zero connections).
- Do not move AEC, capture or the playback graph into the provider code.
- Do not let the cloud frontend call any tool except the four frontend tools; do not expose the
  worker catalogue to it.
- Do not pass a brief, tool result, transcript, memory or file name that was assembled for a local
  reader.
- Do not add `LLMProviderID` cases for the cloud frontends (a realtime frontend is not an
  `LLMProvider`, and new cases ripple through ten switch statements and the `init?(rawValue:)` that
  must keep decoding stored values); bind `.openRouter` as the cloud-reader proxy instead.
- Do not store keys anywhere but the Keychain; do not print them; do not put them in a URL you log.
- Do not start cloud mode for dictation or meetings.

**Red-first self-test:** covered by `--selftest-realtime-cloud` (P5-04), which is written first
against a stub responder whose `start` does nothing. Seam-specific assertions that live there:
converter round-trip (1 kHz sine, 16 kHz → 24 kHz PCM16 → 16 kHz; RMS error < 1% after the
converter's group delay), `mayShare` truth table, consent/key gating (0 connections), and
`sessionInstructions()` containing neither a fixture folder name nor a fixture graph node when those
consents are off.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-realtime-cloud
Scripts/run-selftest.sh --selftest-voice-conversation
Scripts/run-selftest.sh --selftest-voice-delivery
Scripts/run-selftest.sh --selftest-concurrent-voice
Scripts/run-selftest.sh --selftest-ui-strings
make acceptance TIER=core
```

**Success threshold:** the seam cases in `--selftest-realtime-cloud` pass; with the setting off,
every existing voice self-test is byte-for-byte unchanged in outcome.

**Risks & rollback:** the seam touches the `VoiceSession` shell; the setting defaults to `off`, so production
behaviour is unchanged until a user opts in. Rollback: hard-return the local responder in frontend
selection.

**Done when:**
- [ ] capabilities, audio protocol, converter, key store, policy, backing, transport exist
- [ ] settings, consent sheet, section with no developer words
- [ ] seam cases green in `--selftest-realtime-cloud`

---

### P5-02 — OpenAI Realtime frontend (opt-in, Keychain key, consent)

**Finding(s):** E §2.2 (OpenAI row), §2.5; decision doc §5 Phase 5  **Effort:** 4 days  **Depends on:** P5-01, P5-04 (fixture first)  **Unblocks:** —

**Why (what the user experiences today):** see P5-01. OpenAI is first because async function
calling is built into the model ("the model can continue a fluid conversation while waiting on
results"), `semantic_vad` exists, and per-response `instructions` let `OutputScheduler` phrase a
result under result-only rules — the same wire protocol qwen-audio-agent targets.

**Files you will change:** new `Agent/CloudFrontend/OpenAIRealtimeFrontend.swift` (actor
conforming to the P5-01 protocol); new `Agent/CloudFrontend/OpenAIRealtimeEvents.swift` (Codable
event types, only the fields used); `Agent/CloudFrontend/ProviderRegistry` switch in the `VoiceSession`
shell's frontend selection; `--selftest-realtime-cloud` OpenAI scenario (P5-04 file).

**Read for context (do not change):** `roadmap/references/qwen-audio-agent-main/server/src/voice/providers/ga-protocol.mjs`
(GA dialect differences, item id prefixes, metadata correlation);
`…/server/src/voice/announcement/*.mjs` and `…/server/src/frontend/frontend-tools.mjs`
(`resultResponseInstructions`); E §1.4–1.5.

**Current behaviour:** none.

**Target behaviour — the wire contract.**
1. **Connect:** `wss://api.openai.com/v1/realtime?model=<realtimeCloudModelOpenAI>` with header
   `Authorization: Bearer <key>`. Wait for `session.created`, then send:
   ```json
   {"type":"session.update","session":{
     "type":"realtime",
     "model":"<model id>",
     "instructions":"<CloudFrontendPolicy.sessionInstructions()>",
     "audio":{
       "input":{"format":{"type":"audio/pcm","rate":24000},
                "turn_detection":{"type":"semantic_vad","eagerness":"auto",
                                  "create_response":true,"interrupt_response":true}},
       "output":{"format":{"type":"audio/pcm","rate":24000},"voice":"<setting, default marin>"}},
     "tools":[<spawn_task>,<task_status>,<cancel_task>,<respond_approval if a request is pending>],
     "tool_choice":"auto"}}
   ```
   Wait for `session.updated` before streaming audio. Input transcription: request
   `audio.input.transcription` with the model the docs name on the day (verify; the user transcript
   is needed for `AgentSession` and the task objective). Tool schemas are generated from P3-05's
   frontend tool definitions, not hand-written here.
   `respond_approval` is added with a new `session.update` when `PermissionGate` gains a pending,
   session-owned request, and removed when it clears (P3-08's rule).
2. **Audio in:** `input_audio_buffer.append {audio: <base64 PCM16 24k>}` per chunk. Never
   `input_audio_buffer.commit` while semantic VAD is on.
3. **Server events → `FrontendEvent`:**

   | Server event | Action |
   |---|---|
   | `input_audio_buffer.speech_started` | `.userSpeechStarted`; the reducer ducks/pauses local playback now (server `interrupt_response` cancels generation, but audio already queued locally must be cleared here). Then `conversation.item.truncate {item_id: <playing item>, content_index: 0, audio_end_ms: playedMs}` where `playedMs = AgentPCMRenderer.renderedSamples(for OutputID) / 16` |
   | `input_audio_buffer.speech_stopped` | `.userSpeechStopped` |
   | `conversation.item.input_audio_transcription.completed` | `.userTranscript(turnID, transcript)`; dictionary-corrected before recording (`Coordinator.corrected` rule) |
   | `response.created` | map `response.metadata.nn_output_id` → `OutputID`; a response without metadata is one the server VAD created → ask `OutputScheduler` for a new `OutputID` (it and the `VoiceSession` shell are the only minters, Phase 3 §2.1) |
   | `response.output_audio.delta` | decode, convert, `.audio(outputID, buffer)` |
   | `response.output_audio_transcript.delta` / `.done` | text of what was said, recorded as the assistant row |
   | `response.function_call_arguments.done` (or `response.output_item.done` with `type: function_call`) | decode `{name, call_id, arguments}` → `.decision`; for `spawn_task` see 4 |
   | `response.done` | `.responseDone(outputID, usage)`; add `usage` audio tokens and elapsed seconds to the daily counter |
   | `error` | map `code` to `CloudFrontendError` (`auth`, `rateLimited`, `invalidRequest`, `server`); `auth` and repeated `server` → `.failed` |
4. **Receipt-first `spawn_task`:** on the call, `TaskBridge.shared.spawn(objective:userWords:origin:backend:)`
   returns a `TaskReceipt` synchronously from cached state (Phase 3 §2.5, P3-05). Immediately send
   `conversation.item.create {item:{type:"function_call_output", call_id, output:"{\"status\":\"accepted\",\"task\":\"<short label>\"}"}}`
   then `response.create {response:{instructions:"Confirm naturally in one short clause. Do not call tools again. Do not promise a duration.", tool_choice:"none", metadata:{"nn_output_id":"<id>"}}}`.
   The model's spoken acknowledgement is one clause (P3-05 guard). Never read the task id aloud:
   the output carries a label, not an id. `task_status`, `cancel_task`, `respond_approval` answer
   from the ledger the same way (function_call_output, then `response.create`).
5. **Result delivery** (only when `OutputScheduler` opens a window: floor free, no turn pending, no
   audio queued, then 350 ms): if `CloudFrontendPolicy.mayShare(event)`,
   `conversation.item.create {item:{type:"message", role:"user", content:[{type:"input_text",
   text:"Result of work you started earlier — not a new request. Relay it: <facts>"}]}}`, then
   `response.create {response:{instructions:<result instructions>, tool_choice:"none",
   metadata:{"nn_output_id":…}}}`. Result instructions (adapted from qwen's
   `resultResponseInstructions`): `This is not a new request. Open with the actual result, blocker
   or question — no "okay", "got it" or "task complete". Cover every item. If details are on screen,
   give the gist and say they're on screen. Never read ids, paths or links. Do not call tools. Do
   not call unfinished work finished.` Batching (120 ms, ≤ 8 items) happens in `OutputScheduler`;
   this frontend receives one call per batch. Acknowledged on first audible frame; a user barge-in
   counts as delivered (it is in context); any other cancellation is retried by the scheduler.
   `context`-mode deliveries: `conversation.item.create` only, no `response.create`.
6. **Cancel:** `cancelResponse(outputID, playedMs)` → `response.cancel`, then
   `conversation.item.truncate` as above; the renderer token is stopped.
7. **Single slot:** never send `response.create` while a response is in flight; queue it
   (`singleResponseSlot = true` for safety even though the service may accept more).
8. **Guards:** idle close after 60 s without user speech or pending delivery (reopened on the next
   wake/press); per-session cap 15 minutes (reconnect with a fresh session and a short recap of the
   last 3 turns assembled by the policy); daily cap from Settings — at the cap, `.failed(.dailyCap)`
   and fall back locally.
9. **Reconnect:** one automatic reconnect on a dropped socket within 2 s; otherwise fall back.

**Steps:**
1. Write the Codable event structs for exactly the events in the table; unknown `type`s are ignored
   and counted (printed by the self-test).
2. Implement the actor over `CloudRealtimeTransport`; one receive loop task; one send queue.
3. Wire `appendInput` to the converter; `events` to an `AsyncStream` continuation.
4. Implement receipt, delivery, cancel, truncate and caps as above.
5. Register in the `VoiceSession` shell's frontend selection for `realtimeCloudProvider == "openai"`.
6. Make the P5-04 OpenAI scenario green.

**Do not:**
- Do not supply conversation item ids (GA namespace trap).
- Do not send binary frames.
- Do not let the server VAD's automatic response and a scheduled result delivery overlap: a
  delivery waits for the slot.
- Do not speak a result whose sources are not allowed online (P5-01 Target 9).
- Do not log instructions, transcripts or audio; log event types, sizes and timings only.

**Red-first self-test:** the OpenAI scenario of `--selftest-realtime-cloud` (P5-04). It is red
against the P5-01 stub ("no session.update received by the fixture").

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-realtime-cloud
Scripts/run-selftest.sh --selftest-voice-delivery
Scripts/run-selftest.sh --selftest-voice-session-reducer
Scripts/run-selftest.sh --selftest-ui-strings
make acceptance TIER=core
```
Then, only with a real key and the user's consent given in the app (never by the executor on the
user's behalf): a live run measured with `--selftest-voice-latency`, recorded in `STATUS.md`.

**Success threshold:** OpenAI scenario green; fixture turn latency (speech_stopped → first audio
delta forwarded to the renderer) ≤ 50 ms of local overhead; live median end of speech → first
audio ≤ 0.8 s on a normal connection (record, do not gate CI on it).

**Risks & rollback:** vendor event names change — the Codable layer is the only place that knows
them, and unknown events are counted, not fatal. Cost overrun — daily cap. Rollback: provider
picker hides `OpenAI`.

**Done when:**
- [ ] OpenAI frontend implemented; scenario green
- [ ] caps, reconnect, fallback in place
- [ ] live measurement recorded or marked pending (no key)

---

### P5-03 — Gemini Live frontend (gated on NON_BLOCKING support)

**Finding(s):** E §2.2 (Gemini row), decision doc §5 Phase 5  **Effort:** 3 days  **Depends on:** P5-02, P5-04  **Unblocks:** —

**Gate (check first, record the result in `STATUS.md`):** proceed only if the configured model
supports `behavior: NON_BLOCKING` function declarations. On 2026-09-23 the Gemini docs say:
`gemini-3.8-live` — async execution is the default, `BLOCKING` still selectable, function
scheduling supported; `gemini-3.1-flash-live` — "Asynchronous function calling is not yet
supported"; the 2.5 Flash Live preview supports both. Encode this as
`GeminiLiveModels.supportsNonBlocking(_ id: String) -> Bool` (allowlist: ids with prefix
`gemini-3.8-live`, and `gemini-2.5-flash-live` previews), and refuse to start (fall back locally,
tell the user `This Gemini model can't keep talking while it works. Pick a newer one.`) for any
other id. Re-read the docs on the day; if 3.8 Live has changed, update the allowlist, not the logic.

**Why (what the user experiences today):** see P5-01. Gemini's `scheduling` values
(`INTERRUPT | WHEN_IDLE | SILENT`) are the same vocabulary as `AgentDelivery`'s
`interrupt | respond | context`, which makes it a natural second provider.

**Files you will change:** new `Agent/CloudFrontend/GeminiLiveFrontend.swift`; new
`Agent/CloudFrontend/GeminiLiveMessages.swift`; new `Agent/CloudFrontend/GeminiLiveModels.swift`;
`VoiceSession` shell's frontend selection; the Gemini scenario in the P5-04 self-test.

**Read for context (do not change):** the OpenAI frontend (P5-02); Gemini docs listed at the end.

**Current behaviour:** none.

**Target behaviour — the wire contract.**
1. **Connect:** `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent`.
   Try the header `x-goog-api-key: <key>` first; if the fixture/live server rejects the upgrade,
   fall back to the documented `?key=<key>` query parameter, and in that case never log the URL.
   (Record which one worked in `STATUS.md`.)
2. **First message** `setup`: `model: "models/<id>"`, `generationConfig.responseModalities:
   ["AUDIO"]`, `systemInstruction` = `CloudFrontendPolicy.sessionInstructions()` with the result
   instructions appended (Gemini has no per-response instructions),
   `realtimeInputConfig.automaticActivityDetection` enabled with `silenceDurationMs` 500 and
   `prefixPaddingMs` 20, `inputAudioTranscription: {}`, `outputAudioTranscription: {}`,
   `sessionResumption: {}`, `contextWindowCompression` enabled, `tools: [{functionDeclarations:
   [spawn_task {behavior: NON_BLOCKING}, task_status {behavior: BLOCKING}, cancel_task
   {behavior: BLOCKING}, respond_approval {behavior: BLOCKING}]}]` — `behavior` set per
   declaration, never left to the default. Wait for `setupComplete`.
3. **Audio in:** `realtimeInput {audio: {mimeType: "audio/pcm;rate=16000", data: <base64>}}`;
   `audioStreamEnd` when the session's microphone closes.
4. **Server messages → `FrontendEvent`:**

   | Message | Action |
   |---|---|
   | `serverContent.interrupted` | `.userSpeechStarted` semantics: clear local playback now, mark the output interrupted (delivered-in-context if it was a result) |
   | `serverContent.inputTranscription` | accumulate; on `turnComplete` or `generationComplete` emit `.userTranscript` |
   | `serverContent.modelTurn.parts[].inlineData` (audio) | convert 24k → 16k, `.audio(outputID, …)`; the first audio part after a `turnComplete` starts a new `OutputID` |
   | `serverContent.outputTranscription` | assistant row text |
   | `serverContent.turnComplete` | `.responseDone` |
   | `toolCall.functionCalls[]` | `.decision`; answer per 5 |
   | `toolCallCancellation.ids` | drop pending answers for those ids; never cancel the `TaskBridge` task (only explicit cancellation invalidates work) |
   | `goAway` | reconnect with the last `sessionResumptionUpdate.newHandle` before the deadline |
   | `usageMetadata` | daily counter |
5. **Receipt-first `spawn_task`:** `toolResponse {functionResponses: [{id, name: "spawn_task",
   response: {status: "accepted", task: "<label>"}, scheduling: "WHEN_IDLE"}]}` immediately.
   `task_status` / `cancel_task` / `respond_approval`: answered from the ledger with no scheduling
   field (they are BLOCKING).
6. **Result delivery** when `OutputScheduler` opens a window and `mayShare` allows:
   `clientContent {turns: [{role: "user", parts: [{text: "Result of work you started earlier — not a
   new request. Relay it: <facts>"}]}], turnComplete: true}` (`respond` mode). `context` mode:
   the same with `turnComplete: false` (≈ `SILENT`). `interrupt` mode is used only for explicit
   gateway events, as locally. Do not deliver a result as a late `toolResponse` for the original
   `spawn_task` call: that call was answered by the receipt, and timing belongs to the local scheduler.
7. **Limits:** audio-only sessions end at 15 minutes; rely on session resumption; if resumption
   fails, start a new session with the policy's 3-turn recap.
8. Guards, fallback and daily cap exactly as P5-02.

**Steps:** mirror P5-02's steps with this message set; add `GeminiLiveModels`; register for
`realtimeCloudProvider == "gemini"`; make the Gemini scenario in P5-04 green.

**Do not:**
- Do not start with a model outside the NON_BLOCKING allowlist.
- Do not rely on the default `behavior`; set it on every declaration.
- Do not put tool results into `systemInstruction`; results go through `clientContent` at the
  scheduler's moment.
- Do not treat `toolCallCancellation` as a user cancel.
- Do not log the URL when the key is in it.

**Red-first self-test:** the Gemini scenario of `--selftest-realtime-cloud` (P5-04), red against
the stub ("no setup message received"), plus `GeminiLiveModels.supportsNonBlocking` truth table
(`gemini-3.8-live` true, `gemini-3.1-flash-live` false, empty false).

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-realtime-cloud
Scripts/run-selftest.sh --selftest-voice-delivery
Scripts/run-selftest.sh --selftest-ui-strings
make acceptance TIER=core
```

**Success threshold:** Gemini scenario green; the gate refuses 3.1 Flash Live with the user-facing
sentence; live run recorded or marked pending.

**Risks & rollback:** preview/stable churn in Gemini Live model ids and message fields; the
allowlist and the message structs are the only places that know them. Rollback: hide `Google
Gemini` in the picker.

**Done when:**
- [ ] gate recorded; Gemini frontend implemented; scenario green
- [ ] allowlist refusal path tested

---

### P5-04 — `--selftest-realtime-cloud` loopback fixture server

**Finding(s):** decision doc §5 Phase 5 exit criterion  **Effort:** 2.5 days  **Depends on:** P5-01  **Unblocks:** P5-02, P5-03

**Why (what the user experiences today):** nothing yet — this is the proof. The decision doc's exit
criterion: the test "fails if a result is delivered while the fixture reports `speech_started`, or
if `spawn_task` blocks the response". Without a fixture, the cloud path can only be tested with a
key, money and a network, and a self-test must never touch any of those.

**Files you will change:** new `Agent/CloudFrontend/RealtimeCloudFixtureServer.swift`; new
`Agent/CloudFrontend/RealtimeCloudSelfTest.swift`; `NextNotesApp.swift` (register the flag);
`AGENTS.md` (flag list, one paragraph); `Scripts/acceptance.sh` (INTEGRATION:
`"selftest-realtime-cloud|300"`).

**Read for context (do not change):** `Support/ModelRoles/ModelRoleSelfTest.swift:773-913` — the
existing loopback fixture (`private actor FixtureServer`: `NWListener(using: .tcp, on: .any)`,
OS-assigned port, `ContinuationBox` because `.ready` can fire twice, connections cancelled in
`stop()`). Copy that pattern; do not make it public from that file.

**Current behaviour:** no such test.

**Target behaviour:**
1. **Fixture server** — an actor like `ModelRoleSelfTest.FixtureServer`, but WebSocket:
   ```swift
   let parameters = NWParameters.tcp
   let ws = NWProtocolWebSocket.Options()
   ws.autoReplyPing = true
   parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
   let listener = try NWListener(using: parameters, on: .any)
   ```
   - Binds loopback only: set `parameters.requiredInterfaceType = .loopback` (and/or
     `requiredLocalEndpoint` = 127.0.0.1); the test fails if the listener is reachable on another
     interface.
   - Records: every received frame (type, opcode text/binary, parsed JSON `type`), the upgrade
     request headers (to assert `Authorization: Bearer fixture-key` / `x-goog-api-key`), the
     request path and query (to assert the model id), connection count.
   - Plays a **script**: an ordered list of steps `send(json)`, `expect(type, within: ms)`,
     `sleep(ms)`, `sendAudio(ms)` (24 kHz PCM16 base64 deltas of a 440 Hz tone), `close(code)`.
   - Two dialects: `openAI` and `gemini`.
2. **The frontend under test** points at `ws://127.0.0.1:<port>/…` through an injected base URL
   (a `realtimeCloudBaseURLForTesting` seam honoured only when `SelfTest.isRunning`) and the key
   `fixture-key` injected through a key-store seam (the real Keychain is never read or written).
3. **Harness:** a fake `TaskBridge` (spawn returns a `TaskID` synchronously and records calls), the
   real `OutputScheduler` with a fake floor clock, `AgentPCMRenderer` replaced by a recording backing
   that timestamps "first audible frame" when the first buffer is enqueued (real renderer is not
   required: this test is about protocol and timing, the acoustic tests own the renderer), fake
   `PermissionGate` state. No user store is written (P0-11 seams).
4. **Scenarios (OpenAI dialect; mirror them for Gemini once P5-03 exists):**
   - **S1 consent/key gate:** provider `off`, or no key, or consent version 0 → start refused;
     fixture connection count **0**.
   - **S2 session setup:** fixture receives `session.update` with `session.type == "realtime"`,
     `audio.input.format.rate == 24000`, `turn_detection.type == "semantic_vad"`, tools named exactly
     `spawn_task`, `task_status`, `cancel_task` (no `respond_approval` while none is pending), header
     `Authorization: Bearer fixture-key`, query `model=` the configured id. All frames are **text**;
     one binary frame fails the test.
   - **S3 receipt does not block:** fixture sends a `spawn_task` function call; the frontend must send
     `conversation.item.create` with `function_call_output` whose `output` has `"status":"accepted"`
     within **100 ms**, then `response.create` with `tool_choice == "none"` within **100 ms** after
     that. Fails if `TaskBridge.spawn` is awaited on anything slower (the fake spawn records
     wall time; it returns immediately) or if the task id appears in the output text.
   - **S4 no delivery while the user speaks:** after S3, the fake worker completes the task while the
     fixture has sent `input_audio_buffer.speech_started` and not yet `speech_stopped`. Assert **no**
     `conversation.item.create` carrying the result and **no** `response.create` is sent until
     `speech_stopped` has been sent **and** the fixture's audio for any in-flight response has been
     played (recording backing drained) **and** 350 ms (± 60 ms) have passed. Then exactly one
     result item + one `response.create` whose `instructions` contain `not a new request`.
   - **S5 barge-in truncates:** fixture streams 2 s of audio deltas; after the backing has consumed
     800 ms, fixture sends `speech_started`. Assert local playback stopped within 50 ms and the
     frontend sent `conversation.item.truncate` with `audio_end_ms` in 800 ± 60.
   - **S6 two completions, one utterance:** two tasks complete 50 ms apart → one result item listing
     both, one `response.create`.
   - **S7 brief rule:** with file-index and graph cloud consents off, and `agentCloudConsent` off,
     `session.update.session.instructions` contains the date but not the fixture folder name
     `FixtureFolder`, not the fixture graph node `Fixture Project`, not the fixture event title; a
     task result whose `sources` contains `files` is delivered as `A task you asked for is finished.
     The result is on screen.` only.
   - **S8 failure fallback:** fixture closes with code 1011 mid-session → one reconnect attempt, then
     the session's frontend becomes the local responder (assert via the `VoiceSession` shell's selected responder) and the
     in-flight fake task is **not** cancelled.
   - **S9 converter:** 1 kHz sine round-trip 16k→24k PCM16→16k, RMS error < 1% after alignment.
   - **S10 policy truth table:** `mayShare` for each `ResultSource` × consent combination.
   - **Gemini (after P5-03):** S1–S8 with the Gemini message set (`setup` with per-declaration
     `behavior`, `toolResponse` receipt with `scheduling: "WHEN_IDLE"` within 100 ms, result via
     `clientContent` only after `serverContent.interrupted` has settled + 350 ms, 3.1 Flash Live
     refused by the gate with zero connections).
5. **Markers:** each scenario prints `REALTIME_CLOUD_CASE <name> ok|failed: <reason>`; the final
   line is `REALTIME_CLOUD_OK: <n> scenarios` or `REALTIME_CLOUD_FAILED: <first failed scenario>:
   <reason>`. No model and no network are needed, so there is no `_ABSENT`. If the listener cannot
   bind, print `REALTIME_CLOUD_FAILED: could not start the loopback fixture` (a failure, not a skip —
   binding loopback always works on a healthy Mac).
6. The test finishes in < 30 s (all waits bounded with `withBoundedWait`; a stuck scenario fails,
   it never hangs — AGENTS.md "a self-test cannot fail by hanging").

**Steps:**
1. Write the fixture server and the harness, with the frontend stub from P5-01. Run: S1 passes
   trivially, S2 fails → **red confirmed**. Commit.
2. Register `--selftest-realtime-cloud` in `NextNotesApp.runRequestedSelfTest`
   (`Task { @MainActor in … NSApp.terminate(nil) }`, like `--selftest-model-roles` at `:384-392`).
3. Add the flag to AGENTS.md's list with one paragraph: loopback only, no key, no network; the
   scenarios; the exit criterion it enforces.
4. Add `"selftest-realtime-cloud|300"` to `INTEGRATION_ENTRIES` in `Scripts/acceptance.sh`.
5. P5-02 and P5-03 then turn their scenarios green.

**Do not:**
- Do not contact `api.openai.com` or `googleapis.com` from any self-test.
- Do not read or write the real Keychain items; use the key-store seam.
- Do not bind anything but loopback.
- Do not assert on real audio quality here (the acoustic tests do that); assert protocol and timing.
- Do not let any wait be unbounded.

**Red-first self-test:** this task *is* the test; red is S2 failing against the stub.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-realtime-cloud
Scripts/run-selftest.sh --selftest-model-roles        # its own fixture must still work
make acceptance TIER=core
make acceptance --dry-run                             # shows the new INTEGRATION entry
```

**Success threshold:** all OpenAI scenarios green after P5-02; all Gemini scenarios green after
P5-03; runtime < 30 s; zero non-loopback sockets (check with `lsof -p <pid> -i` during a manual run
if in doubt).

**Risks & rollback:** `NWProtocolWebSocket` server behaviour differs slightly from the vendors'
servers (e.g. compression); the live run in the exit gate covers the difference. The test is
additive; rollback is removing the flag.

**Done when:**
- [ ] fixture + harness + ten scenarios; red confirmed before P5-02
- [ ] flag registered, AGENTS.md and acceptance updated
- [ ] green for every shipped provider

---

## Sources (checked 2026-09-23)

- OpenAI Realtime client events: https://developers.openai.com/api/reference/resources/realtime/client-events
- OpenAI Realtime conversations (server events, function calling, out-of-band responses, truncate): https://developers.openai.com/api/docs/guides/realtime-conversations
- OpenAI Realtime VAD (`semantic_vad`, `speech_started`/`speech_stopped`): https://developers.openai.com/api/docs/guides/realtime-vad
- `gpt-realtime-2.1` model page (context, pricing): https://developers.openai.com/api/docs/models/gpt-realtime-2.1
- Introducing gpt-realtime (async function calling): https://openai.com/index/introducing-gpt-realtime/
- Gemini Live tools (`behavior: NON_BLOCKING`, `scheduling`, 3.1 Flash Live not supported): https://ai.google.dev/gemini-api/docs/live-api/tools
- Gemini 3.8 Live model page (async by default): https://ai.google.dev/gemini-api/docs/models/gemini-3.8-live
- Gemini Live capabilities (audio formats, VAD config, limits): https://ai.google.dev/gemini-api/docs/live-api/capabilities
- Gemini Live WebSocket reference (message fields, auth): https://ai.google.dev/api/live
- LiveKit agents issue #7302 (Gemini 3.8 Live async edge cases): https://github.com/livekit/agents/issues/7302
- Local reference: `roadmap/references/qwen-audio-agent-main/server/src/voice/providers/ga-protocol.mjs`, `…/server/src/frontend/frontend-tools.mjs`, E §1.4–1.8
