# I2: caps, gates and limits in the meeting pipeline (recording → transcript → speakers → notes)

> **Historical model assumptions — revised 2026-09-30:** this completed plan/audit
> preserves its dated measurements and implementation history. For new work, follow
> the [independent-role/shared-file contract](../../in-progress/SHARED-BRAIN/00-README.md): Meetings, Agent and cleanup
> may use different appropriate models; exact verified artifacts are reused, with
> workload-specific consent and request ownership. Agent-only file selection,
> universal model defaults and deletion based only on the Agent are superseded.
> MiniCPM cleanup + Apple guard/fallback is concurrent work, not evidence that this
> historical build used it. Re-measure quality/latency on the actual current engine.

Date: 2026-09-23. This was a read-only audit. No source, settings or roadmap file was changed, and
nothing was built or launched. Paths are relative to `Sources/NextNotes/` unless stated. Line numbers
are from today's working tree.

**Scope:** call detection and arming, two-track capture, auto-stop, `ChunkedTranscriber`, the live
context reconcile, diarization, notes generation, pipeline recovery, the store's audio rules, and
calendar arming.

**Out of scope:** `MeetingAgent` proposals, pre- and post-meeting briefs and notification caps. The
proactivity auditor covers those, and H3 already lists the brief caps (#18) and the calendar
look-ahead (#34). They are cited here, not repeated.

## Evidence used

The main evidence is the six meetings under `~/Library/Application Support/Next Notes/Meetings/`,
recorded 2026-09-09 to 2026-09-19. All six are detected calls: 5 WhatsApp or FaceTime, 1 ChatGPT
voice in Chrome. They last 4 to 26 minutes, most are in French, and all were `done` with
`notesModel = Qwen3.5-4B`. For each meeting the audit read `meeting.json`, `transcript.json`,
`context.json`, `notes.md`, `notes.json` and `speakers.json`.

It also used:
- `defaults read ai.pivotstudio.nextnotes`: `meetingsDiarize=1`, `meetingsKeepAudio=0`,
  `meetingsDeleteAudioAfterNotes=1`, `callDetectionAutoRecord=1`, `meetingLeadMinutes=1`,
  `modelRoles.meetingNotes=builtin`, and the `callAppAnswers` and `callAppsSeen` lists;
- the unified log (20 days requested, but info level has aged out);
- `metrics.jsonl`, which holds no meeting spans because it starts on 09-22;
- the FluidAudio checkout at `~/Library/Caches/NextNotesBuild/scratch/checkouts/FluidAudio`;
- the macOS SDK's `FoundationModels.swiftinterface`;
- free disk: **4.2 GiB**.

**Three facts that change how the existing documentation should be read:**

1. **Meeting ASR windows are 2–5 s, not 30–60 s.** Commit `a276c5a` (2026-09-13, "roadmap §11")
   moved `WindowConfig.default` to `StreamingASR.meetingProvisionalMinSeconds = 2` and
   `meetingProvisionalMaxSeconds = 5` (`Transcription/StreamingASR.swift:24-25`). Several things still
   describe the old sizes:
   - AGENTS.md ("`ChunkedTranscriber` cuts 30–60 second windows", line 686);
   - `MeetingDiarizer.assign`'s doc comment (`Meetings/MeetingDiarizer.swift:175-180`);
   - every cap that counts windows or segments, which was tuned for the old sizes.

   The transcripts on disk show the change. Meetings recorded before 09-13 21:30 have segments up to
   25–35 s long. Every meeting after that has a maximum segment length of 4.8–5.04 s.
2. **The browser "ask-only" gate never matches a real browser call.** Core Audio reports the
   *helper* process (`com.google.Chrome.helper`, "Google Chrome Helper"), not `com.google.Chrome`.
3. **P0-01 tells the owner to put Meeting notes on Apple's model during Phase 0.** That turns the
   4K-window map-reduce limits below (#4, #13) from theory into the path every meeting would take.

---

## 1. Summary table (most harmful first)

Coverage: **P#-NN** means an AGENT-OVERHAUL task already handles it. **partial** means a task
touches it but misses the part named here. **NEW** means nothing in `roadmap/in-progress/AGENT-OVERHAUL`
handles it. Almost everything in this area is NEW, because that roadmap is about the agent.

| # | Limit / gate | Value | Where | Verdict | Coverage |
|---|---|---|---|---|---|
| 1 | Meeting finals come from 2–5 s ASR windows, with a fresh decoder state per window | min 2 s, hard cut 5 s | `Transcription/StreamingASR.swift:24-25`; `Meetings/ChunkedTranscriber.swift:45-50,183,407` | **HURTS** (measured) | NEW |
| 2 | Browser ask-only gate matches parent bundle ids, but Core Audio reports helpers | `askOnlyBundleIDs = com.google.Chrome, …` | `Meetings/CallPolicy.swift:324-339,362-376`; `CallDetector.swift:75,130` | **HURTS** (consent gate fails open) | NEW |
| 3 | Diarizer runs with no speaker-count hint and the default threshold | `OfflineDiarizerManager(config: .default)` | `Meetings/MeetingDiarizer.swift:138` | **HURTS** (3 of 6 meetings over-split) | NEW |
| 4 | System segments with no overlapping run are left unlabelled | `guard let best … else { return segment }` | `Meetings/MeetingDiarizer.swift:191-200` | **HURTS** (29–50 % unlabelled) | NEW |
| 5 | Map-reduce silently drops the *oldest* facts when they overflow the window | `facts.removeFirst()` | `Meetings/NotesGenerator.swift:172-178` | **HURTS** on 4K windows (arithmetic) | NEW |
| 6 | "Record this call?" island card lives 8 s for a detected call | `max(islandNotice, start − now)`, where start = call start | `UI/Island/IslandState.swift:329-333`; `CallDetector.swift:383-398` | **HURTS** (default is ask) | NEW (sibling of H3 #5) |
| 7 | Transcription backlog counts windows, not audio time; the newest window is *dropped* | `maxPendingWindows = 8` (now 16–40 s of audio) | `Meetings/ChunkedTranscriber.swift:30,187-190` | **MIXED → high** (latent loss) | NEW |
| 8 | An interrupted meeting is never resumed: quit → `done` without notes; crash → `failed`; interrupted pipeline → `done` and temporary audio deleted | as named | `MeetingSession.swift:282-300`; `MeetingStore.swift:92-138` | **MIXED → high** (latent) | NEW |
| 9 | No watchdog on the diarization or notes stages | none | `DiarizationService.swift:74-87`; `NotesService.swift:129-192` | MIXED | NEW |
| 10 | System-audio tap start: 5 s timeout, then mic-only for the whole meeting with no retry | `.seconds(5)`; no retry | `Core/SystemAudioCapture.swift:73`; `MeetingSession.swift:168-193` | MIXED (the timeout fired 09-23 15:10) | NEW |
| 11 | Temporary audio deleted as soon as the pipeline ends, so re-identifying speakers is impossible | `releaseAudio` | `MeetingStore.swift:312-326`; `NotesService.swift:168` | MIXED | NEW |
| 12 | Detected call and calendar meeting are not unified (early join, early hang-up) | `correlationWindow 10 min`, lead 1 min, attach = do nothing | `MeetingScheduler.swift:361-386,457-468`; `CallPolicy.swift:259-271` | MIXED | NEW |
| 13 | Apple FM window hard-coded at 4,096; 4 chars/token estimate; prompt overhead 512 < the real ~630; no retry on overflow | as named | `Formatting/LLM/FoundationModelLLMProvider.swift:13,26-30`; `NotesGenerator.swift:37-44` | MIXED (estimated; verify) | partial (P0-01 raises urgency) |
| 14 | Notes output cap 1,500 tokens; `LLMCompletion` has no finish reason, so a cut-off answer is padded with `_None._` | `maxNotesTokens 1_500` | `NotesGenerator.swift:46,217-223,303-338`; `LLMProvider.swift:206-214` | MIXED | partial (P0-17 for OpenRouter only) |
| 15 | Map chunk sizes fixed, not derived from the window | 3,000 local/cloud, 2,000 Apple; facts 600 | `NotesGenerator.swift:48-51,201-209` | MIXED | NEW |
| 16 | Live reconcile cadence counts finals, runs the agent model ungated, and reads the last 32 segments | `finalsThreshold 8`, `speech 45 s`, `suffix(32)`, `maxTokens 400` | `MeetingContextReconciler.swift:18-22,171-193`; `MeetingContextStore.swift:175-230` | MIXED | NEW |
| 17 | Calendar overrun stops at end + 5 min even mid-sentence | `overrunGrace 5 min` | `MeetingScheduler.swift:26,272-290` | MIXED (not yet exercised here) | NEW |
| 18 | Speaker identification off by default | `meetingsDiarize ?? false` | `Support/Settings.swift:1032` | MIXED | NEW |
| 19 | Notes pipeline records no per-meeting spans (stage durations, map-reduce, chunk count, dropped facts) | none | `NotesService.swift:88-94` (log only) | MIXED | partial (P0-20) |
| 20 | `transcript.json` rewritten in full on every segment | per segment | `MeetingSession.swift:355-358` | MIXED (low) | NEW |
| 21 | No free-space preflight for `audio.caf`; write errors logged and ignored | none | `MeetingSession.swift:90-103`; `MeetingAudioWriter.swift` `writeChunk` | MIXED (low) | NEW |
| 22 | Hand-started recordings never auto-stop | by design | `MeetingScheduler.swift:268-271` | HELPS (optional ask) | — |
| 23 | CallPolicy on/off debounce 3 s / 15 s, 5 s backstop poll | as named | `CallPolicy.swift:29,34`; `CallDetector.swift:45` | HELPS (measured) | — |
| 24 | `deniedBundleIDs` denylist | 6 daemons + own bundle | `CallPolicy.swift:48-59` | HELPS (add `com.apple.replayd`, see #2) | — |
| 25 | Detected calls are exempt from the overrun rule; 10-min silence backstop | as named | `MeetingScheduler.swift:272-283` | HELPS | — |
| 26 | Segment = 600 ms pause or sentence end ≥ 2 s (within a window) | as named | `ChunkedTranscriber.swift:75,83,351-362` | HELPS (keep; #1 changes the window around it) | — |
| 27 | Writer lead 5 s, 16-bit stereo on disk (≈230 MB/h) | as named | `MeetingAudioWriter.swift` | HELPS | — |
| 28 | Notes model 10-min idle unload; cleanup gate; warm at meeting start | as named | `NotesModelRuntime.swift:50`; `MeetingSession.swift:216-227` | HELPS (measured) | — |
| 29 | Brief counted before the single-pass decision; map step without the brief; `emptySection` | as named | `NotesGenerator.swift:71-101,148-159,361-375` | HELPS (documented) | — |
| 30 | `audioIsTemporary` decided at start; the three-line `releaseAudio` rule | as named | `MeetingSession.swift:90-103`; `MeetingStore.swift:312-326` | HELPS (see #11 for timing only) | — |
| 31 | `armedGrace` 10 min, `tickInterval` 30 s, one session at a time | as named | `MeetingScheduler.swift:23,31` | HELPS | — |
| 32 | Diarizer `minimumAudioSeconds 2`; voice print `minimumSeconds 3` | as named | `MeetingDiarizer.swift:33`; `SpeakerVoicePrints.swift:25` | HELPS | — |
| 33 | Chunk-level silence gate: RMS 0.01 (≈ −40 dBFS) per 20 ms frame | as named | `ChunkedTranscriber.swift:66-70,241-250` | HELPS (no evidence of harm; recheck with far-field fixtures) | — |
| 34 | Calendar look-ahead 24 h / look-behind 1 h / poll 5 min; declined-only exclusion | as named | `Calendar/CalendarService.swift:29-34`; `EventKitCalendarProvider.swift:72-74` | HELPS | H3 #34 |

---

## 2. Detailed entries

### 1. Meeting finals come from 2–5 s ASR windows (HURTS, NEW)

- **Value and code:**
  - `WindowConfig.default` sets min 2 s and max 5 s (`StreamingASR.swift:24-25`).
  - `nextCut()` cuts at the first 600 ms pause after 2 s. It hard-cuts at 5 s when there is no pause
    (`ChunkedTranscriber.swift:167-184`).
  - `TranscriptionQueue.transcribe` builds a fresh `TdtDecoderState` for every window (`:405-408`).
  - Parakeet is `parakeet-tdt-0.6b-v3`, the multilingual model with automatic language detection
    (`Transcription/ParakeetEngine.swift:344,398`).
- **What it guards:** live-pane latency. Provisional text appears within seconds rather than after a
  30–60 s window.
- **Evidence it hurts:**

  **(a) Language flips.** The share of segments that read as English inside French calls, measured
  with a stop-word heuristic over `transcript.json`:

  | Meeting | Date | Longest window | English segments |
  |---|---|---|---|
  | C9781051 | 09-13 | 25 s | 6 % (19/329) |
  | CEACD80D | 09-16 | 5 s | 16 % (88/562) |
  | 6C5EBA1B | 09-19 | 5 s | 24 % (94/393) |

  A sample of 6C5EBA1B's "English" system-track segments shows that most of them are not English that
  was spoken. They are English-sounding text produced from the father's French:
  - "So if you don't have to pass it, you can be very and I use it to be two AC sounds like";
  - "Uh it's a good time as a parking lot of it.";
  - "Like on that on that C the power of the one parentheses the most the poem and a one DP.";
  - "Bueno, it would be this way."

  **(b) The errors spread downstream.** The live context for that meeting holds the topic
  "Parking lot" (`context.json`, created 19:49:15). The notes model was then handed this text.
  Its notes say "The speaker noted…" and leave Decisions and Open questions empty on a 25-minute
  business call.

  **(c) Hard cuts mid-word.** Examples: "…donc les 5 mi" and "…40 000 avec moins". WhatsApp's
  comfort noise often keeps the RMS above 0.01, so the pause detector finds no gap and the 5 s cap
  fires.

  **(d) Short segments.** With short windows, 23–33 % of all segments are under one second
  (129/393, 131/562). That feeds entry #4.

  **Caveat:** the speakers do sometimes code-switch. The fixture test proposed in M-01 is how to
  separate the causes, because no audio was kept (`meetingsKeepAudio=0`).
- **Verdict:** HURTS. The 2–5 s window was the right answer for *provisional* text. It is the wrong
  unit for the *final* transcript that diarization, notes, the knowledge index and the agent all read.
- **Proposed change:** use two tiers.
  - Keep 2–5 s windows for provisionals only.
  - Produce finals from 20–30 s windows cut at pauses: the "overlap/finals" path the comment reserves
    (`StreamingASR.swift:26-28`).
  - The simplest version keeps a second, long cutter on the same samples, and its output replaces the
    provisional rows.
  - Alternatively, run one re-transcription pass per track over `audio.caf` after Stop and before
    diarization. Parakeet is far faster than real time, so this costs seconds per meeting. It needs
    the audio, and M-08 keeps it.
  - Fix AGENTS.md line 686 and the `MeetingDiarizer.assign` comment either way.

### 2. The browser ask-only gate never fires (HURTS, NEW)

- **Value:** `askOnlyBundleIDs` contains `com.google.Chrome`, `com.apple.Safari`,
  `org.mozilla.firefox`, `com.microsoft.edgemac` and `company.thebrowser.Browser`
  (`CallPolicy.swift:324-330`).
- **Evidence:**
  - `callAppsSeen` on this Mac lists `com.google.Chrome.helper = "Google Chrome Helper"`.
  - Meeting `1B6B0944` has `calendarEventID "com.google.Chrome.helper@1789326398"` and
    `calendarName "Google Chrome Helper"`.
  - `CallDetector.audioProcesses()` reads `kAudioProcessPropertyBundleID` of the process that holds
    audio. For Chromium that process is the helper, not the app.
  - Therefore:
    - `availableAnswers(forApp:)` offers **"Always record"** for "Google Chrome Helper";
    - `recordsWithoutAsking` returns `autoRecord` when no answer is stored;
    - with `callDetectionAutoRecord` on, which it is here, a browser call records without asking.

  That is the one thing AGENTS.md says can never happen ("Chrome is offered only 'Ask first' and
  'Never'"). This Mac is safe only because the user answered "ask" by hand.
- **The same helper issue produces false "calls":** `callAppsSeen` also lists `com.apple.replayd`
  (Apple's screen-recording daemon), `Codex (Service)` and `Cursor Helper`. Each has an explicit
  "ask" answer, which means each one armed a "…is on a call. Record it?" question.
- **Verdict:** HURTS. A consent gate that fails open, plus titles like "Google Chrome Helper call".
- **Proposed change:**
  - Resolve every audio process to its owning app before any policy check. Walk `proc_pidpath` up to
    the outermost `.app` bundle, or use the responsible pid.
  - Keep the helper id only as a fallback.
  - Match `askOnlyBundleIDs` and stored answers on the owning id.
  - Migrate stored `*.helper` answers.
  - Add `com.apple.replayd` to `deniedBundleIDs`. It is measured here and is never a call.
  - Extend `--selftest-calls` with helper-to-owner cases.

### 3. The diarizer has no speaker-count hint (HURTS, NEW)

- **Value:** `OfflineDiarizerManager(config: .default)` (`MeetingDiarizer.swift:138`).
  FluidAudio's config accepts `clustering.numSpeakers`, `minSpeakers`, `maxSpeakers` and
  `clusteringThreshold` (`Offline/Clustering/SpeakerCountConstraints.swift`,
  `Offline/Core/OfflineDiarizerManager.swift:305-324`).
- **Evidence:** three of the six meetings came back with more clusters than there were voices, and the
  user merged them by hand in the rename sheet:

  | Meeting | Call | What the diarizer returned | What the user did |
  |---|---|---|---|
  | 1B6B | ChatGPT voice | 2 speakers | named both "ChatGPT" |
  | C978 | 1:1 WhatsApp with Dad | 3 speakers | named all three "Mathieu Kadjo" |
  | CEAC | call the user named with 2 people | a third cluster with 12 segments | left the third unnamed |

  The notes were written before the rename, so their action items name "Speaker 1".
- **Verdict:** HURTS.
- **Proposed change:** build a `SpeakerCountHint` from the meeting.
  - A detected call from a messaging or FaceTime app with no attendees gets `maxSpeakers = 2` (one far
    voice plus slack).
  - A calendar meeting gets `maxSpeakers = max(2, attendees.count)` (the mic track already holds "You").
  - Otherwise, pass nothing.
  - After clustering, merge clusters whose voice-print centroids (already computed by
    `MeetingVoicePrints.centroids`) have cosine similarity ≥ a measured threshold.
  - Add "Re-identify with N speakers" to the speaker sheet. It needs the audio (see #11).

### 4. System segments with no overlapping run stay "Others" (HURTS, NEW)

- **Value:** `assign` gives a segment the run with the largest overlap, and nothing when no run
  overlaps it (`MeetingDiarizer.swift:191-200`).
- **Evidence:** system-track segments left without a speaker:

  | Meeting | Unlabelled | Median length, unlabelled | Median length, labelled |
  |---|---|---|---|
  | 6C5E | 55/109 (50 %) | 1.36 s | — |
  | CEAC | 82/287 (29 %) | 0.76 s | 2.4 s |
  | C101 | 30/101 (30 %) | 0.72 s | 2.24 s |

  The short finals from #1 are what fall between the segmenter's runs. FluidAudio's embedding
  `minSegmentDurationSeconds` is 1.0.
- **Verdict:** HURTS. Half of one call is attributed to "Others" although a single remote speaker was
  identified.
- **Proposed change:** keep the overlap rule. When there is no overlap:
  - assign the nearest run within 1.0 s;
  - else assign the speaker of both neighbouring system segments when they agree;
  - otherwise leave it unlabelled.

  This is a pure function, so a self-test can cover it without a model. Doing #1 also shrinks the
  problem.

### 5. Map-reduce drops the oldest facts when they overflow (HURTS on 4K, NEW)

- **Value:** after the map step, `while countTokens(joined) + briefTokens > budget { facts.removeFirst() }`
  (`NotesGenerator.swift:172-178`). The comment's reason, "the end of a meeting is where its decisions
  are", is an assumption, not a measurement.
- **Arithmetic on Apple FM, the model P0-01 tells the owner to use for notes:**
  - The transcript budget is 4,096 − 1,536 = 2,560 estimated tokens.
  - A map chunk is 2,000 tokens, about 8,000 characters. At this Mac's measured 700–970 characters
    per minute, that is 8–11 minutes of meeting per chunk. Each chunk may produce up to 600 fact tokens.
  - With a full brief (≈ 2,800 chars ≈ 700 tokens), about 1,860 tokens are left for facts. That is
    3–6 chunks' worth.
  - So a meeting longer than about 35–55 minutes silently loses its opening facts: the agenda, the
    first decisions, who owns what.
  - Single-pass on Apple FM fits only 10–14 minutes of speech. Four of the six meetings here would
    already go through map-reduce.
- **Verdict:** HURTS. The loss is silent: nothing in the notes, the log or the UI says part of the
  meeting was left out.
- **Proposed change:**
  - Give each chunk a fact budget of `(budget − brief) / chunks`, with a floor of 150 tokens.
  - If the facts still overflow, run a collapse pass that condenses groups of facts into shorter facts
    until they fit, instead of dropping any.
  - Log `notes map-reduce · chunks N · collapsed K`, and never drop silently.

### 6. The detected-call question disappears after 8 s (HURTS, NEW)

- **Value:** `announceArmed` pushes the card for `max(DS.Motion.islandNotice, event.start − now)`.
  For a detected call, `start = call.since`, which is already in the past, so the card lives 8 s
  (`IslandState.swift:329-333`; `CallDetector.swift:383-398`).
- **Why it matters:** `callDetectionAutoRecord` defaults to **false** (`Settings.swift:1052`), so on a
  fresh install every ad-hoc call depends on this question.
  - After 8 s the only remaining place to answer is the notification banner, which macOS also
    auto-dismisses unless the user set Alerts style.
  - If nobody answers, `retire` deletes the armed meeting when the call ends, and the call is never
    recorded.
  - A late answer loses the minutes before it.
- **Verdict:** HURTS. This is the same failure as H3 #5 (approval cards), in a different place.
- **Proposed change:**
  - For `providerID == .detectedCall`, keep a compact armed pill on the island for the life of the
    call. `retire` already takes it down.
  - Expand it on hover.
  - Do not record anything before the answer: consent stays as it is.

### 7. The transcription backlog counts windows, then drops the newest (MIXED → high, NEW)

- **Value:** `maxPendingWindows = 8` per track (`ChunkedTranscriber.swift:30`). On overflow the code
  logs "transcription backlog full — dropped window" and discards the audio (`:187-190`).
- **What changed:** at the old 30–60 s windows, 8 windows was 4–8 minutes of tolerance. At 2–5 s it is
  16–40 s. Both tracks share one `TranscriptionQueue`, and each window must also win `.realtimeASR`
  (H2 V26). A cold Parakeet load (11 s per AGENTS.md), a voice-agent turn, or a swap-heavy moment now
  gets close to that ceiling.
- **Evidence:** none in the retained log, which has aged out. This is latent, but when it fires the
  speech is permanently missing from the transcript. `recordNow` also starts capture before Parakeet
  is warm (`MeetingSession.swift:203-207`).
- **Proposed change:**
  - Bound the backlog by seconds of audio (e.g. 300 s ≈ 19 MB of float samples).
  - On overflow, merge queued windows rather than drop them.
  - Keep a counter in the meeting's log line.

### 8. Interrupted meetings are never resumed (MIXED → high, NEW)

- **Value:**
  - On quit, `endAbruptly` marks the meeting `.done` (or `.failed` if it has no segments) and runs no
    pipeline. It leaves a temporary `audio.caf` on disk that nothing will ever release, because
    `repairInterruptedMeetings` only visits active states (`MeetingSession.swift:282-300`).
  - After a crash while recording, repair writes `.failed("Next Notes quit while this meeting was
    recording.")`, although `transcript.json` is written after every segment and is intact
    (`MeetingStore.swift:135-138`; `MeetingSession.swift:355-358`).
  - After a crash while diarizing or summarising, repair writes `.done` and **deletes the temporary
    audio** (`MeetingStore.swift:92-106`). The meeting ends up without speakers and without notes, and
    it can never be re-diarized.
- **Why it matters here:** `make install` replaces a running app, and agents run it often on this Mac.
- **Evidence:** none of the six meetings shows it. Latent.
- **Proposed change:**
  - At launch, a meeting interrupted at `.recording` or `.transcribing` that has segments becomes
    `.transcribing`, and `MeetingPipeline.afterTranscribing` runs on it.
  - `.diarizing` and `.summarizing` resume at their stage.
  - Temporary audio is kept until the resumed stage finishes.
  - Also add an `applicationShouldTerminate` confirmation while a meeting is recording.

### 9. No watchdog on the diarization or notes stages (MIXED, NEW)

- **What is missing:** `DiarizationService.run` and `NotesService.summarize` have no deadline and no
  stall detection. Notes run at `.background`, which the voice lanes preempt without limit.
- **How it fails:** a hang shows "Writing notes…" until the next launch, and the next launch then
  deletes the audio (#8). The dictation tail has deadlines for exactly this reason (AGENTS.md).
- **Proposed change:** do not add a hard wall-clock deadline, because long meetings legitimately take
  minutes. Add a stall watchdog instead: if the progress fraction and the token counter have not moved
  for 5 minutes and the model is not queued behind a higher lane, set a problem, keep the audio, and
  offer Retry.

### 10. The system-audio tap is never retried (MIXED, NEW)

- **Value:** `SystemAudioCapture.startTimeout = .seconds(5)` (`Core/SystemAudioCapture.swift:73`).
  On any error, the meeting continues on the microphone only, for its whole length
  (`MeetingSession.swift:183-193`).
- **Evidence:** "system audio start timed out; awaiting HAL return for cleanup" fired on 2026-09-23
  at 15:10. It was not during a meeting, but it shows the timeout does fire on this Mac. A meeting
  that hits it has no "Others" track at all, so it gets no diarization and no far-end words in the
  notes.
- **Proposed change:** retry the tap every 30 s while recording and `systemAudioProblem` is set, for
  up to 10 attempts. The writer already pads the silent side. Also report "the other side joined late"
  in the log.

### 11. Temporary audio is deleted as soon as the pipeline ends (MIXED, NEW)

- **Value:** `releaseAudio` runs at the end of the automatic pass. With `meetingsKeepAudio = 0` (this
  Mac and the default), the recording goes as soon as notes land (`NotesService.swift:168`).
- **Cost:** the user saw three clusters for one speaker (#3) and could only rename them. No
  "Re-identify" or "final re-transcription" (#1) is possible afterwards.
- **Proposed change:**
  - Hold temporary audio for 72 h, or until the speaker sheet is confirmed, whichever comes first.
  - Delete early when free disk is under 5 GB. At ≈ 230 MB/h this costs little; this Mac has
    4.2 GiB free, so the disk guard matters.
  - Keep the three-line keep-or-drop rule. Only its timing changes.

### 12. Detected calls and calendar meetings are not unified (MIXED, NEW)

- **Current behaviour:**
  - A call attaches to a calendar meeting only if that meeting is already armed or active
    (`correlationWindows`). The default lead is 1 min.
  - A call joined 2–10 min early therefore arms its own ad-hoc question. At the scheduled start the
    calendar meeting finds a session running, and 10 minutes after the end it is written off as
    "Another meeting was being recorded when this one started": a false failure row. Meanwhile the
    recording carries the call's title, not the calendar title and attendees that the notes prompt
    uses to resolve names.
  - When a call attaches to an armed calendar meeting that has not started, nothing starts until the
    scheduled start. `attach` does nothing.
  - A calendar recording ignores the covering call's end. It records the room until 10 minutes of
    silence or end + 5 min.
- **Proposed change:**
  - A call inside ±`correlationWindow` of an auto-record calendar event starts *that* event's meeting
    right away, with its title and attendees.
  - When the covering call ends, stop after a 60 s grace.
  - Keep `correlationWindow` itself; it helps.

### 13. Apple FM window and token estimate are hard-coded (MIXED, partial)

- **Value:**
  - `contextTokens = 4_096` and `charactersPerToken = 4` (`FoundationModelLLMProvider.swift:13,26-30`).
  - `promptOverheadTokens = 512`, while `NotesPrompts.notesSystem` is 2,513 characters, about 630
    tokens before the header.
  - There is no catch for `LanguageModelError.contextSizeExceeded`.
  - The SDK on this Mac exposes `SystemLanguageModel.contextSize` (macOS 26, dynamic on 27) and
    `tokenCount(for:)` (macOS 26.4). Neither is used.
- **Risk (estimated):** French tokenises denser than 4 chars/token. A single pass near the 2,560-token
  edge, plus about 630 system tokens and a 768-token answer, overruns 4,096. The notes then fail with
  a raw error instead of falling back to map-reduce.
- **Proposed change:**
  - Read `contextSize` and use `tokenCount(for:)` where the OS has them.
  - Count the system prompt instead of assuming 512.
  - On `contextSizeExceeded`, retry once through map-reduce with chunks at 70 % of their size.

  P0-01 routes notes to Apple FM, so this belongs early.

### 14. Notes cap of 1,500 tokens with no finish reason (MIXED, partial P0-17)

- **Value:** `maxNotesTokens = 1_500` (`NotesGenerator.swift:46`). `LLMCompletion` has no
  `stoppedAtLimit` field. `NotesFormatter.tidy` fills every missing section with `_None._`.
- **How it fails:** a truncated answer looks complete and says "no decisions" or "no open questions".
  On OpenRouter the configured notes model (`nvidia/nemotron-3-super-120b-a12b:free`) is a reasoning
  model, and its reasoning also counts against the 1,500 tokens.
- **Evidence:** none truncated here. The longest notes are about 600 tokens.
- **Proposed change:**
  - Add `finishedByLimit` to `LLMCompletion` for all providers. P0-17 adds `finish_reason` for
    OpenRouter only.
  - On a limit stop, retry once with 2× the budget where the window allows. Otherwise append "(notes
    were cut short)" rather than `_None._` for the missing sections.
  - Scale the cap: `min(3_000, 800 + 20 × minutes)`.

### 15. Map chunk sizes are constants (MIXED, NEW)

- **Value:** 2,000 tokens for Apple and 3,000 for everything else, with 600-token facts
  (`NotesGenerator.swift:48-51`). These are not derived from the window.
- **Arithmetic:** on 4K, the map prompt is about 200 system tokens + 2,000 + 600, which leaves about
  1,000 tokens unused. Chunks 50 % larger would mean a third fewer chunks and fewer facts to overflow
  (#5).
- **Proposed change:** `chunk = window − mapSystem − maxFactTokens − headroom`, with a ceiling of
  6,000 tokens for quality.

### 16. The live reconcile is tuned for the old segment sizes (MIXED, NEW)

- **Values:**
  - `finalsThreshold 8` or `speechSecondsThreshold 45 s`, then a 2 s debounce
    (`MeetingContextReconciler.swift:18-22`).
  - The prompt carries the last 32 segments and `.suffix(3_000)` characters, with `maxTokens 400`
    (`:171-193`).
  - The pass runs on the Agent's model for every meeting. It is not gated by `agentLiveDuringMeeting`
    or by any other switch (`MeetingContextStore.swift:175-230`).
  - `recentTranscript(minutes: 3)` is computed but `ModelCompleter` never reads it.
- **Effect of the new segment sizes:**
  - Segments now average about 2 s, and 23–33 % are under one second.
  - Eight finals arrive every 10–20 s of conversation, so a model pass is scheduled several times a
    minute.
  - Each pass sees only about 1 minute of speech.
  - Every topic the model writes is tagged `source: .mic`.
- **Evidence:** 6C5E's `context.json` holds the model-written topic "Parking lot", taken from the
  hallucinated text in #1.
- **Proposed change:**
  - Schedule on speech seconds only: ≥ 60 s of new speech, and ≥ 45 s since the last pass.
  - Feed the prompt the last 3 minutes by time.
  - Give it an explicit switch that defaults to on only when a local model is resident.
  - Stop tagging model topics as `.mic`.

### 17. Overrun cut at end + 5 min (MIXED, NEW)

- **Value:** `overrunGrace = 5 min` (`MeetingScheduler.swift:26`).
- **Behaviour:** a calendar recording stops 5 minutes past its scheduled end even while people are
  talking. Detected calls are exempt, which is correct.
- **Evidence:** not exercised on this Mac. No calendar meeting has been recorded here.
- **Proposed change:** stop at end + 5 min only if nobody has spoken for 2 minutes, or when the
  covering call ends (#12). Keep a hard ceiling at end + 60 min.

### 18. Speaker identification is off by default (MIXED, NEW)

- **Value:** `meetingsDiarize ?? false` (`Settings.swift:1032`).
- **Effect:** a fresh install labels every remote voice "Others", and the notes' action items become
  **Unassigned**. The owner turned it on by hand.
- **Why it is off:** a model download and a temporary audio file (≈ 230 MB/h, deleted afterwards).
- **Proposed change:** turn it on by default once the diarizer models are on disk, and offer it (with
  the download) the first time a meeting finishes with more than one remote voice.

### 19. The notes pipeline has no metrics (MIXED, partial P0-20)

- **Current state:** only a log line records model, tokens, seconds and map-reduce, and it ages out
  within minutes. `metrics.jsonl` has no meeting spans.
- **Proposed change:** add spans for `meeting.drain`, `meeting.diarize`, `notes.map` (per chunk),
  `notes.reduce`, `notes.collapse`, and `transcript.windows_dropped`. P0-20's provenance record covers
  the model passes. It does not cover the pipeline stages or the dropped-audio counters, which are
  what #5 and #7 need.

### 20–21. Low-cost robustness (MIXED, low, NEW)

- **#20:** `saveTranscript` rewrites the whole transcript on every segment. A 2-hour meeting is about
  2,700 segments × up to ~500 KB, roughly 1 GB of writes. Debounce to every 5 s plus Stop. The
  crash-safety argument still holds at 5 s.
- **#21:** there is no free-space check before `audio.caf`, and `file.write` errors are logged per
  chunk and ignored. Skip the audio file, with a banner, when free space is under 1 GB.

### 22–34. Keep (HELPS)

- **#22:** hand-started recordings are never stopped for silence, by design. An optional "Still
  recording?" card after 60 min of silence would be kind, but it is not needed.
- **#23–#25:** the call debounce, denylist and detected-call exemptions are measured and documented.
  Keep them. Add `com.apple.replayd` (#2).
- **#26:** the segmentation rule inside a window (600 ms pause, or 2 s plus a sentence end) is correct.
  #1 is about the window around it, not this rule.
- **#27–#32:** the writer, notes-model residency, brief handling, audio rules, armed grace and diarizer
  minimums are all documented and sound.
- **#33:** the −40 dBFS frame gate has no evidence against it. Recheck it when far-field fixtures
  exist.
- **#34:** calendar polling and exclusions (H3 #34) are fine.

---

## 3. Proposed tasks for a dedicated dictation/meetings roadmap (M-##)

These are ordered by harm. Following the repo convention, each task gets a `--selftest-*` flag that
fails when the thing it names did not happen. "Phase" gives the nearest AGENT-OVERHAUL phase when there
is a coupling; otherwise it is the tier within the meetings roadmap (**M0** correctness and consent,
**M1** quality, **M2** robustness).

| ID | Title | Fixes | Tier / phase | Self-test (fails when…) |
|---|---|---|---|---|
| **M-01** | Long-window finals: keep 2–5 s provisionals, cut finals at 20–30 s pauses (or run a post-Stop re-transcription pass); fix the AGENTS.md and `MeetingDiarizer` comments | #1 | M0 | `--selftest-meeting-finals <fr-wav>`: fails if finals come from windows < 15 s, or if the French fixture's final text has more than 5 % non-French segments while the 5 s provisional path is kept for comparison |
| **M-02** | Resolve audio helpers to their owning app before `CallPolicy`; migrate `*.helper` answers; add `com.apple.replayd` to the denylist | #2 | M0 (consent) | extend `--selftest-calls`: `com.google.Chrome.helper` → `.ask`-only, no "Always"; `replayd` never a call |
| **M-03** | Speaker-count hints plus voice-print cluster merge, and "Re-identify with N speakers" | #3 | M1 | `--selftest-diarize-hints`: 1:1 WhatsApp → `maxSpeakers 2`; two fixture clusters with cosine ≥ threshold merge |
| **M-04** | Nearest-run and neighbour fallback in `MeetingDiarizer.assign` | #4 | M1 | `--selftest-diarize-assign`: a 0.8 s segment 0.4 s from a run is labelled; one 3 s from any run is not |
| **M-05** | Map-reduce never drops facts: per-chunk fact budget plus a collapse pass; log chunk and collapse counts | #5, #15 | M0 (P0-01 routes notes to Apple FM) | `--selftest-notes-longform`: fake 4K provider over a 90-min fixture; fails unless a fact from part 1 reaches the reduce prompt |
| **M-06** | The detected-call question stays as a compact island pill for the life of the call | #6 | M0 | extend `--selftest-island`: armed detected call still shown at t = 60 s; gone after `retire` |
| **M-07** | Backlog bounded by audio seconds and merged, never dropped | #7 | M1 | `--selftest-meeting-backlog`: slow fake transcriber, 3 min of input; fails if any second of audio is missing from the windows |
| **M-08** | Resume interrupted meetings at their stage; hold temporary audio until done; confirm quit while recording; stall watchdog on diarize and notes | #8, #9 | M0 | `--selftest-meeting-resume`: seeded `.recording`/`.diarizing`/`.summarizing` folders reach `.done` with notes and correct audio release; a stalled fake provider raises a problem, not an endless "Writing notes…" |
| **M-09** | Retry the system-audio tap while recording | #10 | M1 | `--selftest-meeting-tap-retry`: the start fails twice then succeeds; fails if the meeting stays mic-only |
| **M-10** | Keep temporary audio 72 h or until speakers are confirmed, with a disk guard | #11, #21 | M1 | extend `--selftest-meeting-reconcile` or a new `--selftest-audio-retention` |
| **M-11** | Unify calls with calendar meetings: start early, inherit title and attendees, stop on hang-up; speech-aware overrun | #12, #17 | M1 | `--selftest-calendar` + `--fake-calendar`: call at start − 6 min starts the calendar meeting; its end stops it 60 s later |
| **M-12** | Window-aware notes budgeting: read Apple's `contextSize` and `tokenCount`, count the system prompt, retry on overflow, derive chunk sizes | #13, #15 | M0 (P0-01) | `--selftest-notes` variant with a fake provider that throws `contextSizeExceeded` once; fails unless notes are written |
| **M-13** | Truncation is visible: `LLMCompletion.finishedByLimit` for every provider, retry or mark "cut short"; scale the notes cap with length | #14 | M1 (with P0-17) | `--selftest-notes-truncation`: fake provider stops at the limit mid-Decisions; fails if the output shows `_None._` there |
| **M-14** | Live reconcile by speech time, with a 3-minute window and its own switch | #16 | M2 (coordinate with P3-07a) | `--selftest-meeting-live`: 2 s finals for 2 min trigger ≤ 3 passes, not ≥ 8 |
| **M-15** | Speaker identification on by default once models exist; offer at first multi-voice meeting | #18 | M2 | `--selftest-onboarding` addition |
| **M-16** | Meeting pipeline spans in `metrics.jsonl`; debounced transcript writes | #19, #20 | M2 (with P0-20) | `--selftest-metrics`: a fixture meeting writes `meeting.diarize`, `notes.map`, `notes.reduce` and `transcript.windows_dropped` |

The top five by harm are **M-01**, **M-02**, **M-05**, **M-06** and **M-08**. Three of them are
cheap and pure: M-02, M-04 and the M-05 collapse can each be pinned with a self-test that needs no
model and no grant. M-01 is the one that most improves every downstream consumer: diarization, notes,
the knowledge index and the agent's meeting tools.
