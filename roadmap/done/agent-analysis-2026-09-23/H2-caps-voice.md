# H2: caps, gates and limits in the voice conversation path

> **Historical model assumptions — revised 2026-09-30:** this completed plan/audit
> preserves its dated measurements and implementation history. For new work, follow
> the [independent-role/shared-file contract](../../in-progress/SHARED-BRAIN/00-README.md): Meetings, Agent and cleanup
> may use different appropriate models; exact verified artifacts are reused, with
> workload-specific consent and request ownership. Agent-only file selection,
> universal model defaults and deletion based only on the Agent are superseded.
> MiniCPM cleanup + Apple guard/fallback is concurrent work, not evidence that this
> historical build used it. Re-measure quality/latency on the actual current engine.

2026-09-23. Read-only audit. No source, roadmap or git state was changed. Paths are relative to
`Sources/NextNotes/` unless stated. "Capture" means `Activation/AgentCaptureController.swift`,
"Coordinator" means `Agent/VoiceConversationCoordinator.swift` and "Frontend" means
`Formatting/LLM/LocalVoiceFrontend.swift`. Line numbers are from today's working tree.

**Scope:** VAD/EOU and silence timers, endpoint fallbacks, speculation, energy gates, echo/AEC
gates, the deterministic coordinator gates, frontend deadlines, ComputeScheduler lanes, session
and idle ends, wake word, TTS limits, announcement caps and barge-in.

**Evidence used:**
- `~/Library/Application Support/Next Notes/agent-audit.jsonl` (659 rows);
- `metrics.jsonl` (573 rows);
- this Mac's `defaults`: `voiceWakeEnabled=1`, `wakeSensitivity=0.48`, `agentVoiceEngine=pocket`,
  `agentResponsiveness=deep`;
- the A and C reports.

The unified log has already aged out the info-level voice lines ("discarded playback echo",
"endpoint …"). Where a limit could only be proven from code, the entry says so.

**What the real sessions show, in brief:**
- Voice transcript → first token: n=76, median **2.09 s**, max **16.1 s**.
- 4 voice turns died on `frontend_unavailable` at ~2.0 s.
- **01:08:35–01:12:30Z (09-24 UTC):** after a "Hey Will" wake, one session answered about 30
  turns of what was plainly a conversation between people (pricing, "DJ Burger King"). There
  were 23 barge-in stops in 4 minutes, so the agent was talking each time a new sentence
  committed. The session never ended.
- **23:59:19–23:59:24Z:** the user pressed **"That wasn't for you" six times in five seconds**
  (`wake.false reason=that-wasnt-for-you` ×6). The session kept listening and committed another
  turn ("Yeah. Yeah.") until Done at 23:59:27.

---

## 1. Summary table (sorted by harm)

**Coverage key:**
- **NEW**: not in the AGENT-OVERHAUL roadmap.
- **P#-NN**: fully covered by that task.
- **partial**: the task touches it but, as written, will not fix it.

| # | Limit / gate | Value | Where | Verdict | Coverage |
|---|---|---|---|---|---|
| V1 | Echo filter erases short answers and restatements | 15 s window, 6 refs; 1-word residual, 2-word edge, ≥3-word spans | `Agent/RealtimeAudioSession.swift:101-102,232-283` | **HURTS** | **NEW** |
| V2 | "That wasn't for you" is telemetry-only | button does not end or drop anything | `UI/Island/IslandView.swift:437-444` | **HURTS** | **NEW** |
| V3 | Tool-id silencer matches ordinary sentence ends | `"meeting."`, `"browser."`, `"computer."`, `"workspace."`, `"mcp."` substrings | `Agent/Speech/AgentSpeechPolicy.swift:292-295,526-531` | **HURTS** | **NEW** |
| V4 | Streaming hard-stop at 400 chars or > 3 lines | `spokenCap = 400`; `synthesizer.stop()` mid-clause | `AgentSpeechPolicy.swift:17,174-184`; `Agent/Speech/StreamingSpeechBuffer.swift:38-63` | **HURTS** | **partial** (P0-09 gap) |
| V5 | Voice reply rewritten on keywords | "quota", "rate limit", "429", "not downloaded" replace the whole answer | `Agent/RealtimeAgent.swift:178-199` | **HURTS** | **partial** (P1-10b; risk of spreading) |
| V6 | Worker warmup on the frontend's lane; 2 s drain barrier; acquire cannot be cancelled | `.realtimeAgent`, `.seconds(2)` | `Formatting/LLM/NotesModelRuntime.swift:326`; Frontend `:312-316`; `Core/Compute/ComputeScheduler.swift:142-152` | HURTS | P0-06 |
| V7 | Cumulative 280-character speakable cap | `shortLimit = 280` | `AgentSpeechPolicy.swift:16,256-258` | HURTS | P0-09 |
| V8 | Input barrier stuck after a failed turn; 120 ms energy pauses planning | `inputPending`, `0.12` s | Coordinator `:572-574`; Capture `:893-901` | HURTS | P0-07, P3-02 |
| V9 | EOU timing | 320 ms debounce, 100 ms tick, 2.5 s / 0.9 + 0.35 s fallbacks | `Activation/LocalVoiceTurnDetector.swift:8`; Capture `:100-108,1185-1190` | HURTS | P0-10, P2-04 |
| V10 | Barge-in waits for words | ≥ 2 chars, ≥ 0.25 s; energy ignored while speaking | Capture `:893-903,1114-1142` | HURTS | P2-05 |
| V11 | Speculation | ≥ 4 words, 220 ms debounce, exact request key | Coordinator `:162-183`; Frontend `:37-62,283-300` | HURTS | P2-03 |
| V12 | Clause-serial TTS, engine stop per clause, sentence-only boundaries | — | `AgentSpeechSynthesizer.swift`, `PocketAgentVoice.swift`, `StreamingSpeechBuffer.swift:113-119` | HURTS | P2-06 |
| V13 | Voice pending-intent and denial rules | "okay"/"ok" are noise; backstop only on the 2nd identical denial | `Activation/VoiceTurnPolicy.swift:56-59`; Coordinator `:479-495` | HURTS | P1-07 |
| V14 | Router sees no history; answer lane may not name models or promise work | `history: []`; answer rules | `Formatting/LLM/LocalVoiceDecision.swift:91-95,145-156` | HURTS | P4-02, P4-03, P1-07 |
| V15 | Session ends only on 25 s of silence; no addressee decision | `idleSession = 25` | Capture `:107,1272-1281` | **MIXED** (missing boundary) | **NEW** |
| V16 | Goodbye matched as a substring anywhere | 11 phrases, `contains` | Capture `:2350-2357`, used at `:1251-1259` | **MIXED** | **NEW** |
| V17 | Background result spoken as 2 clauses ≤ 300 chars, else a fixed line; dropped when the session is closed | `prefix(2)`, `300` | `Agent/VoiceAnnouncementQueue.swift:12-15,38-51` | MIXED | P3-04a |
| V18 | Unspeakable voice reply → "details are easier to read in the conversation" | fixed line | `Agent/RealtimeAgent+ToolLoop.swift:159-169`; `AgentSpeechPolicy.swift:94-95` | MIXED | partial (P1-10b, P3-04a) |
| V19 | Work-status context caps | 5 jobs, prompt 650, result 600 chars | Coordinator `:666-671` | MIXED | partial (P3-03a) |
| V20 | Voice history | 1,400 chars | Coordinator `:677-678` | MIXED | P4-08 |
| V21 | Explicit-cancel phrases: exact list, only with exactly one job | 7 phrases, `active.count == 1` | `VoiceTurnPolicy.swift:32-41`; Coordinator `:332-337` | MIXED | partial (P3-03) |
| V22 | Bare-acknowledgment list | 13 exact phrases, ≤ 3 tokens | `VoiceTurnPolicy.swift:78-87` | MIXED | partial (P1-07, P3-08) |
| V23 | Every committed voice turn cancels the ACP "Run once" card | `ACPConfirmationGate.cancel()` | Capture `:1346` | MIXED | **NEW** (P3-08 excludes it) |
| V24 | Capture delivery lane counts buffers, not audio time | `maxPending = 8` | `Core/AudioCaptureHub.swift:385-387,431` | MIXED | partial (P2-08) |
| V25 | EOU startup backlog below cold-prepare time | 96,000 frames (6 s) vs 9–12.7 s | Capture `:26` | MIXED | P2-07 |
| V26 | Meeting and dictation ASR hold the one lane the frontend needs | `.realtimeASR` beats `.realtimeAgent` | `Transcription/ParakeetEngine.swift:87`; `Meetings/ChunkedTranscriber.swift:402` | MIXED | partial (P3-07a) |
| V27 | Pocket prepare budget on a cold process | 10 s wait, 8 s warmup; cold load 12.6 s | `Agent/Speech/PocketAgentVoice.swift:47,68` | MIXED | P2-07 |
| V28 | Voice worker plan budget | 120 s for all rounds | `RealtimeAgent+ToolLoop.swift:796-798` | MIXED | P1-06 |
| V29 | Agent always speaks at 0.65 volume in a session | `duckedVolume` | `RealtimeAudioSession.swift:49,461-465` | MIXED (low) | **NEW** (after P2-05) |
| V30 | Known-noise exact list, one clarifier per distinct text per session | 13 entries | `VoiceTurnPolicy.swift:56-59`; Coordinator `:386-409` | HELPS | — (okay/ok: P1-07) |
| V31 | Hesitation / non-lexical backchannel rules | uh/um/erm; mm, mhm, uh huh | `VoiceTurnPolicy.swift:9-28` | HELPS | — |
| V32 | Pending intent freshness | 180 s | Coordinator `:50` | HELPS | — |
| V33 | Frontend answer deadline and token caps | 25 s; answer 256, route 64 tokens | Coordinator `:10,437`; `LocalVoiceDecision.swift:158` | HELPS | — |
| V34 | Listening pause auto-release | 0.25 s quiet / 2.5 s unrecognised | `RealtimeAudioSession.swift:70-71,421-430` | HELPS | — |
| V35 | EOU lag reset and catch-up; AEC tail | 0.5 s / 0.4 s; 350 ms tail ≤ 0.5 s | Capture `:576-609`; `Agent/AcousticEchoProcessor.swift:163,557-558` | HELPS | — |
| V36 | In-flight repeat absorb | ≤ 3-word prefix, 2.5 s | Capture `:1216-1232,1841-1852` | HELPS | — |
| V37 | Wake thresholds and phrase confirmation | sensitivity map; closeness 0.65 / 0.95, +2 words | `Activation/WakeWord/WakeWordTuning.swift:64-103`; `WakePhraseConfirmation.swift:46-67` | HELPS | — (AGENTS.md: real-room data, not a lower bar) |
| V38 | Capture finish, idle unload, one-orb rule | 8 s; 10 min; — | `RealtimeAgent.swift:28`; `NotesModelRuntime.swift:50` | HELPS | — |

---

## 2. Detailed entries

### V1: The echo filter drops one-word answers, "yes", and restatements (HURTS, NEW)

**What it is.** `RealtimeAudioSession.playbackEchoMask` (`:232-283`) removes recognised words that
match the agent's own recent speech. Every clause that started rendering in the last **15 s**
(`echoWindow`, `:101`) counts, up to **6** clauses (`maxEchoReferences`, `:102`). Four rules
remove a word:
- any run of ≥ 3 words that matches;
- a 2-word run at an edge of the utterance, or a 2-word utterance (`shortEdge`, `:248-252`);
- the **one remaining word** if it appears anywhere in those references (`:268-281`);
- the fuzzy one-edit form of that word, for words of ≥ 4 characters while playback is active or
  ended < 3 s ago.

The capture tick calls `pendingTurn` → `filterLocalRecognition`/`filterAppleRecognition`. An empty
result is discarded as "speech activity without usable words" (Capture `:1191-1200`), or
`isLikelyPlaybackEcho` discards it as "playback echo" (`:1233-1240`).

**What it guards against.** SpeechAnalyzer re-recognises the agent's own reply through the
speakers, sometimes as late cumulative revisions. The physical echo runs referenced in A Hop 12
showed the full reply re-recognised.

**Why it hurts.** A spoken answer to the agent's own question is exactly the case where the user
repeats the agent's words. Within 15 s of the last played clause, each of these is silently
discarded:
- "Calendar." after "Calendar or email?";
- "Yes." after any reply that contained "yes" ("Yes, I can set that up. Want me to?");
- "No." after "No problem — shall I…?";
- "The calendar" after "…the calendar or the email?";
- "Set a reminder for nine" after "Shall I set a reminder for nine?".

The self-test pins the removal as intended behaviour: `RealtimeAudioSession.swift:764-769`
requires `"calendar."` **10 s** after playback to be erased.

This defeats P1-07's plan: "okay"/"yes" answering a worker question cannot reach the
pending-action slot if the capture layer throws the word away first. There is no real-session
count, because info logs age out. The mechanism is certain from the code and pinned by the
test.

**Proposed change.** Keep acoustic evidence and drop lexical coincidence.
- **Keep** the ≥ 3-word span rule over the 15 s window, and the inherited mask. The inherited
  mask is what actually follows a cumulative recognizer revision.
- Apply the **single-word residual** and **2-word short-edge** rules only while a reference is
  `active`, or within **1.5 s** of its end. That covers the AEC tail and Apple's ~1.1 s first-result
  lag.
- When the agent's last rendered clause ended in "?", do not apply the lexical rules at all to a
  fresh (non-inherited) utterance once playback has ended. A question solicits its own words.
- Flip the `:764-769` case into two cases:
  - `"calendar."` at +0.5 s is still removed;
  - `"Calendar."` at +3 s after "…calendar or email?" survives.
- Re-run `--selftest-duplex`, `--selftest-voice-echo-live` (physical) and
  `--selftest-voice-barge`.

**Phase 1, beside P1-07.**

### V2: "That wasn't for you" does nothing but log (HURTS, NEW)

`IslandView.swift:437-444`: "Telemetry only — the card stays up until Done." The button calls
`WakeWordTelemetry.recordFalseAccept` and nothing else.

Evidence: six presses in five seconds at 23:59:19–24Z, then one more committed turn, then Done.
The label promises that the agent will stop treating this as addressed to it. The only control
that does that is Done.

**Change.** The button:
1. records the telemetry;
2. discards the in-flight turn (the same path as a discard in `tick`: `discardVoiceInput` and
   `clearStagedTurn`), cancelling any response still generating;
3. calls `endSession(source: .done)`, or a new `.disowned` source.

Background jobs keep running, as they do on Done. Self-test: `--selftest-voice-conversation` fails
if a turn commits after the disown call. **Phase 0 (hours).**

### V3: The tool-name silencer matches ordinary sentence ends (HURTS, NEW)

`containsToolName` (`AgentSpeechPolicy.swift:292-295`) does a plain `contains` against
`toolMarks` (`:526-531`). The list includes `"meeting."`, `"browser."`, `"computer."`,
`"workspace."` and `"mcp."`. Any spoken reply with one of these words at the end of a sentence
is a "tool name":
- "You're free until your 3 PM meeting."
- "Open it in your browser."
- "It's on your computer."

The two consequences:
1. `spokenForm` returns "", so a one-shot reply is silent.
2. Mid-stream, `StreamingSpeechBuffer.append` (`:38-50`) sees `isUnsafeForStreaming` and calls
   `synthesizer.stop()`. That cuts the clause that is already playing, and nothing later is
   spoken.

Calendar answers are the most exposed, because they end in "meeting.". The guard exists to keep
ids such as `meeting.search` from being read aloud, which is legitimate.

**Change.** Match ids, not words.
- Now: a regex with a following identifier character, e.g. `\b(meeting|browser|computer|workspace|mcp)\.[a-z_]`.
  Keep the exact ids (`search_email`, `get_agenda`, …) as whole-word matches.
- After P1-03: derive the set from the `AgentCapabilityManifest` ids.

Add these cases to `--selftest-tts`: "…your 3 PM meeting." is spoken and "meeting.search" is
not. **Phase 0; fold into P0-09.**

### V4: The streaming path stops audio at 400 characters or 4 lines (HURTS, partial: P0-09 gap)

`isUnsafeForStreaming` (`AgentSpeechPolicy.swift:174-184`) treats `count > spokenCap (400)` and
`lineCount > 3` as unsafe, the same way it treats URLs. `StreamingSpeechBuffer.append` checks it
against the cumulative buffer before every flush, and on a hit it calls `synthesizer.stop()`.
`finalize` (`:56-63`) does the same.

**P0-09 misses this.** P0-09 changes only `flush`/`spokenForm` to judge length per clause. A
600-character reply still reaches `append`, trips the 400 cap at about character 401, and is cut
mid-sentence. P0-09's own red test (a 600-character reply whose last sentence must be spoken)
therefore stays red unless the implementer also edits `isUnsafeForStreaming`.

The voice answer cap is 256 tokens (about 1,000 characters), so > 400 is reachable, especially
with `agentResponsiveness=deep` on this Mac.

**Change.** Add to P0-09:
- `isUnsafeForStreaming` keeps only the content silencers: URL, tool id (per V3), code, file
  listing.
- Drop `count > spokenCap`. Length is per clause.
- Replace `lineCount > 3` with the whole-reply "long listing" decision in `flush`: no speech,
  but **no stop** of a clause already playing. Or speak list items as clauses, since a four-item
  spoken list is natural speech.

### V5: `voiceSafeReply` replaces real answers that mention quotas or downloads (HURTS, partial)

`RealtimeAgent.voiceSafeReply` (`:178-199`) runs on every `finishVoiceFrontend` reply, including
general-knowledge answers from Foundation Models. Two substring rules replace the whole reply:
- Any reply containing "quota", "rate limit", "you've hit your" or `\b429\b` becomes "You've hit
  the usage limit, so I stopped there."
- Any reply containing "not downloaded" becomes "The voice model isn't ready yet."

"What's a sales quota?" or "the file is not downloaded yet" produce a false error.

- **Streamed reply:** the audio was right, but `conclude` records and displays the rewritten
  sentence, so the history now teaches the next turn that a limit was hit.
- **One-shot reply:** the user hears the false error.

P1-10b moves these rules into `AgentReplyRenderer.scrub(text, outcome: nil)` and extends scrub to
**every** reply, typed included (Phase 1 file `:2887-2891`). Moved as-is, the bug spreads to typed
turns.

**Change.** Key the usage-limit and not-downloaded mappings on the **outcome** (a provider or
handoff error: `.modelUnavailable`, `.handedOffFellBack`), never on answer text. Add "What's a
sales quota?" to the P1-10b scrub test as text that must survive. **Phase 1 (P1-10b amendment).**

### V6–V14: Already covered (HURTS)

These match the roadmap as written. The evidence and values are in the table. Notes:

- **V6 (P0-06):** the 2 s barrier failure matches 4 real `frontend_unavailable` rows (09-15
  21:47, 09-22 20:17, 21:50:30, 21:50:34).
- **V7 (P0-09):** see V4. Without the V4 amendment P0-09 cannot pass.
- **V8 (P0-07/P3-02):** nothing new.
- **V9 (P0-10, P2-04):** nothing new.
- **V10 (P2-05):** keep P2-05's `minSpeechForPause = 0.15`.
- **V11 (P2-03):** nothing new.
- **V12 (P2-06):** also allows the first chunk at a comma. Today `isCompleteClause` accepts only
  `.!?;—` (`StreamingSpeechBuffer.swift:113-119`).
- **V13 (P1-07):** V1 must land first or with it, otherwise the capture layer drops the "yes".
- **V14 (P4-02/P4-03/P1-07):** nothing new.

### V15: A session ends only after 25 s of silence, so side conversation keeps it open (MIXED, NEW)

The idle close (`Capture:1272-1281`) needs `!heardSpeech` for `Limits.idleSession = 25` s. Nothing
else ends a wake-opened session: no addressee decision and no turn budget. Any speech in the room
commits a turn, and the frontend answers it.

Evidence: 01:08:35–01:12:30Z. One wake, about 30 committed turns of human-to-human talk, and 23
`agent.barge_in_to_tts_stopped` rows. Each means the agent was speaking an answer to side talk
when the next sentence committed. 01:56:29 shows the same pattern.

AGENTS.md forbids a deterministic *suppression* gate on shape, and that rule is right: "Can you
hear me?" was eaten by one. So the decision has to be the model's.

**Change.**
- Add a route to the frontend decision (`LocalVoiceRoute.Intent`, later P3-06's
  `FrontendDecision`): `notAddressedToMe`, Gemini's SILENT equivalent. It produces no speech and no
  work.
- After **2 consecutive** `notAddressedToMe` turns, or 60 s without an addressed turn in a
  wake-opened session, close with "Going quiet."
- An explicit re-wake reopens.
- Grade it in `--selftest-voice-turn-routing` with a side-talk corpus taken from these audit
  rows **and** its positive corpus of ordinary questions ("Can you hear me?", "What time is
  it?"). This is the "may only add" discipline applied to a model route.

Keep 25 s as the silence close (C and P3-06 row 30 already carry it). **Phase 3 (with
P3-06a/P3-05)**, or Phase 2 if P2-02's single decision lands first.

### V16: Goodbye is matched as a substring anywhere in the turn (MIXED, NEW)

`isGoodbye` (`Capture:2350-2357`) uses `lowered.contains`. The phrases include "that's it",
"nothing else", "go to sleep" and "we're done". These requests would close the session:
- "Is there nothing else on my calendar?"
- "Remind me to go to sleep at eleven."
- "Tell me when we're done with the deck."

The goodbye path (`:1251-1259`) calls `closeSession()`, `RealtimeAudioSession.end()` and
`VoiceAnnouncementQueue.clear()` **before** handing the text to `emitTurn`. The coordinator's
tracker requires `isSessionActive` to speak (`ToolLoop:112`), so the answer is probably not
spoken, and pending announcements are thrown away.

This is a subtractive deterministic gate matched by fragment, which is the class AGENTS.md bans
for the noise list. No real instance was found: 0 of the audit requests contain a goodbye phrase.

**Change.** Match by exact signature over the normalized utterance, like `knownNoiseFragments`. The
whole turn equals, or ends with, a closing clause from the list ("thanks, that's all", "goodbye",
"stop listening", "that's it for now"). Add a positive corpus of the requests above to the
self-test. **Phase 1 (hours).**

### V17–V18: What a voice-only user hears when a result is not speakable (MIXED)

- **V17 (`VoiceAnnouncementQueue.flush`, `:38-51`):**
  - the first two clauses, ≤ 300 characters;
  - otherwise "There's an update from your background task. The details are in the conversation.";
  - dropped when the session is closed (`:12-15`);
  - an interruption replays everything.

  P3-04a covers the delivery scheduler. One interaction with V3/V4: a result that ends in
  "meeting." is currently unspeakable, so it gets the fixed line even when short.
- **V18 (`spokenFallback`, `ToolLoop:159-169`, and `toolResultSummary`, `AgentSpeechPolicy.swift:46-96`):**
  - agenda: 3 events, 90 characters each;
  - email: count plus the latest sender and subject only;
  - files: count only;
  - everything else: "I have the result, but its details are easier to read in the conversation."

  Keep the "never read ids, paths or URLs" rule. The change: when the model's own answer is
  speakable **per clause** (after V3/V4), speak the answer rather than the fixed line. P1-10b
  (renderer) and P3-04a (frontend phrasing of results) cover the rest. **Partial.**

### V19–V20: Context caps on the frontend request (MIXED)

- **V19:** the work status shows the last 5 jobs, each prompt cut to 650 characters and each
  result to 600 (`Coordinator:666-671`). "What did it find?" is answered from the first 600
  characters of a result. Once P3-03a moves status to the ledger, fit this block to the
  Foundation Models window instead: about 1,200 characters for the newest finished result and
  250 for the others.
- **V20:** the voice history is 1,400 characters. P4-08 covers it.

### V21–V22: Cancel and acknowledgment vocabularies (MIXED, partial)

- **V21:** `isExplicitWorkCancellation` accepts only 7 exact phrases, and the coordinator applies
  it only when **exactly one** job runs (`Coordinator:332`).
  - "Cancel it", "cancel", "stop that task" and "cancel the email one" all go to the model.
  - With two jobs, the model's `cancelRunningTask` needs a task number.

  Change: add the unambiguous forms ("cancel", "cancel it", "cancel that task", "stop that
  task"; not bare "stop", which means stop talking). With more than one job, cancel the most
  recently started one and say which. Fold this into P3-03's `.cancel(TaskID?)`.
- **V22:** `isBareAcknowledgment` misses "yes please", "yeah sure", "go for it", "sure go ahead"
  and "yes do it". P3-08 already defines `approveKeys` with these (Phase 3 file `:3305-3307`).
  Adding phrases only adds a route, so it is safe. Change: one shared acknowledgment vocabulary
  for P1-07 and P3-08, adopted in P1-07.

### V23: A voice turn cancels the ACP "Run once" card (MIXED, NEW)

`emitTurn` calls `ACPConfirmationGate.shared.cancel()` on every committed turn (`Capture:1346`),
and `endSession` does the same (`:354`). If the user sees the "coding harness missing — Run once /
Cancel" card and says anything, even "what's that?", the card is dismissed. P3-08 explicitly
leaves this card out of spoken approvals (Phase 3 file `:3563`).

**Change.** Only an explicit cancellation, a new `newWork` route or session end dismisses it. A
conversational turn leaves it up. **Phase 3, in P3-08's scope note.**

### V24–V28: Resource bounds (MIXED, covered or partial)

- **V24:** `AudioCaptureDeliveryWorker.maxPending = 8` counts callbacks. The comment assumes
  2048-frame buffers, about 1 s. After P2-08's 10 ms IO it is **80 ms** of slack, so any
  main-lane hiccup drops audio and resets the EOU decoder. P2-08 lists "any drop is a failure"
  but does not change the bound. Change: bound by frames (≥ 16,000 at 16 kHz, 1 s), the same
  idea as `TurnAudioBacklog`'s "bound audio time, not callbacks" (`Capture:21-26`).
  **Partial (P2-08).**
- **V25:** the 6 s EOU startup backlog is shorter than a 9–12.7 s cold prepare. The result is a
  discontinuity reset, the 0.9 + 0.35 s VAD fallback, and Apple owning the turn. **P2-07.**
- **V26:** dictation Parakeet holds `.realtimeASR` for the whole dictation, and meeting ASR takes
  it per window. Foundation Models queues behind both, so a voice turn during a recorded meeting
  waits for each window. P3-07a keeps `realtimeASR` exclusive. Change: measure Foundation Models
  time to first token with a concurrent Parakeet window, and if it degrades < 15%, let the
  frontend not queue behind `.realtimeASR`. **Partial.**
- **V27:** **P2-07.**
- **V28:** 120 s for the whole voice-worker plan. **P1-06** (per-round with a ceiling).

### V29: The agent always speaks at 65% volume (MIXED, low, NEW)

`applySpeakingVolumeIfActive` sets `utteranceVolume = 0.65` for all session speech
(`RealtimeAudioSession.swift:49,461-465`). This was presumably done to reduce echo, since there
is no other stated reason ("best-effort ducking only").

Keep it until P2-05 (VAD duck to about 0.2 on onset) and a physical `--selftest-voice-echo-live`
pass. Then restore 1.0 and duck only on onset. **Phase 2, after P2-05.**

### V30–V38: Keep (HELPS)

- **Known-noise exact list, clarifier once per distinct text (V30):** this is the measured rule
  from AGENTS.md. The two live `garble_clarifier` rows date from before the 09-22 fix. Only
  "okay"/"ok" need P1-07's pending-action exception.
- **Hesitation and non-lexical backchannels (V31):** narrow and graded by a positive corpus.
- **Pending-intent freshness, 180 s (V32):** sensible. The problem is where it is set (P1-07), not
  its age.
- **25 s answer deadline and 256/64 token caps (V33):**
  - no real turn hit the voice deadline (0 `deadline` rows);
  - 256 tokens is about 75 s of speech;
  - raising it only matters after V4.
- **Pause auto-release at 0.25 s quiet / 2.5 s unrecognised (V34):** reversible by design, and it
  is what makes provisional holds safe.
- **EOU lag resets, 350 ms AEC tail (V35):** measured in the acoustic reports. Do not touch
  without `--selftest-acoustic-*`.
- **In-flight repeat absorb (V36):** only while thinking, and only for a ≤ 3-word prefix of the
  same request.
- **Wake thresholds (V37):** a 270-config sweep chose them. AGENTS.md says the fix is real-room
  recordings (`--wake-mic-record`), not a lower bar. False accepts on this Mac (01:08, 01:56,
  23:59) argue for V2 and V15, not for a stricter threshold.
- **`captureFinish` 8 s, notes-model idle unload 10 min, one animating orb per screen (V38):**
  none of these blocks function.

---

## 3. NEW items to add to the roadmap

1. **P0-21: "That wasn't for you" ends the session and drops its turn** (V2). Phase 0, about 2 h.
   Real evidence: 6 presses in 5 s at 23:59:19Z with no effect.
2. **P0-09 amendment, or P0-22: speech silencers match ids, not words, and never stop a playing
   clause on length** (V3 + V4).
   - `toolMarks` becomes id-shaped (manifest-derived after P1-03);
   - the `spokenCap`/`lineCount` stop leaves `isUnsafeForStreaming`.

   Phase 0. Without it, P0-09's own red test cannot turn green.
3. **P1-14: the echo filter keeps short answers** (V1). The lexical single-word and 2-word rules
   apply only during playback or ≤ 1.5 s after it, and never to a fresh reply to a question. Flip
   the `"calendar."` +10 s self-test case. Phase 1, landing before or with P1-07.
4. **P1-10b amendment: provider-error phrasing keys on the outcome, never on answer text** (V5).
   Phase 1. It stops "quota"/"not downloaded" answers from being replaced, before the rule spreads
   to typed turns.
5. **P1-15: goodbye by exact signature** (V16). Phase 1, about 2 h, with a positive corpus
   ("nothing else on my calendar?", "remind me to go to sleep at 11").
6. **P3-10: a "not addressed to me" frontend route, and a session close after consecutive
   side-talk turns** (V15). Phase 3, beside P3-05/P3-06a. Evidence: the 4-minute, 23-barge-in
   session of 01:08Z. A model decision graded against side-talk and positive corpora, never a
   shape gate.
7. **Scope notes on existing tasks:**
   - P2-08: frame-based `maxPending` (V24);
   - P3-08: conversational turns leave the ACP card up (V23);
   - P3-03: unambiguous cancel phrases, most-recent job when more than one runs (V21);
   - P1-07: shared acknowledgment vocabulary with P3-08 (V22);
   - P3-07a: measure Foundation Models against a concurrent Parakeet window (V26);
   - after P2-05: restore full volume (V29).
