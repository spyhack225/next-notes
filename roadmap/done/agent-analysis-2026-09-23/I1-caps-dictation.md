# I1: caps, gates and limits in dictation

> **Historical model assumptions — revised 2026-09-30:** this completed plan/audit
> preserves its dated measurements and implementation history. For new work, follow
> the [independent-role/shared-file contract](../../in-progress/SHARED-BRAIN/00-README.md): Meetings, Agent and cleanup
> may use different appropriate models; exact verified artifacts are reused, with
> workload-specific consent and request ownership. Agent-only file selection,
> universal model defaults and deletion based only on the Agent are superseded.
> MiniCPM cleanup + Apple guard/fallback is concurrent work, not evidence that this
> historical build used it. Re-measure quality/latency on the actual current engine.

2026-09-23. Read-only audit. No source, roadmap or git state was changed. Paths are relative to
`Sources/NextNotes/` unless stated, and line numbers come from today's working tree.
"Controller" means `Core/DictationController.swift`, "FMF" means
`Formatting/FoundationModelFormatter.swift` and "Router" means `Formatting/CleanupRouter.swift`.

**Scope:** push-to-talk and hold handling, the `DictationController.Limits` deadlines, the ASR
engines, the cleanup router (engine choice, per-call timeouts, chunking, the layout pass, the
guard and salvage), output profiles and injection, dictionary learning, the screen-context
harvest, the HUD error state and run history. Meetings are covered only where dictation holds a
shared resource.

**Evidence used:**
- `~/Library/Application Support/Next Notes/runs.jsonl`: 226 runs from 09-10 to 09-24 UTC, all
  `Parakeet (batch)`. 51 of them (09-20 onwards) carry a `cleanup` record.
- `metrics.jsonl`: the `dictation.*` spans, 19 holds from 09-22 21:38Z onwards.
- The unified log. Error-level entries survive for 14 days. The info lines ("dictation tail",
  "Parakeet: reused partial") have already aged out.
- This Mac's `defaults`: `engine=parakeet`, `cleanupEngine=s1Mini`, `cleanupFixesGrammar=1`
  (so Apple FM is the engine that actually runs), `cleanupSkipsModelWhenBusy=1`,
  `dictionaryLearning=automatic`, `hudPlacement=notch`.
- `dictionary.txt` (39 lines).

**What the real runs show, in brief:**
- **The tail is the cleanup.** Across 15 metric holds, key-up → ASR final has a median of
  **0.38 s**, and ASR final → cleanup done has a median of **5.19 s** (max 11.5 s). Injection
  takes 0.15 s.
- **About a third of cleanup time produces nothing.** In 50 model runs, 9 timed out (18%) and 3
  were rejected by the guard. Together those account for **81.8 s of the 242.6 s** spent in
  cleanup. Each one was waited out in full and then discarded.
- **The layout pass almost never lands.** It was asked 6 times. 5 answers were not used, 4 of
  them because the pass hit its 3.5 s budget. Only 1 model plan was ever applied.
- **Holds were lost in ways `runs.jsonl` cannot show**, because only successful runs are filed.
  At 03:06:49Z, key-down → capture took 4.4 s, and the hold filed nothing. At 22:03:10Z, a 1.5 s
  hold filed nothing. At 22:07:03Z, a tap raised a raw FluidAudio error.
- **The error log is mostly self-test noise.** Every "transcription did not finish within 2.0
  seconds", "Transcription didn't finish in time" and "still starting up" line on 09-23 (8 + 4
  + 4) is `--selftest-dictation` with its 2 s injected limits (`NextNotesApp.swift:2752`). The
  production `Limits` have never fired in the retained log.

---

## 1. Summary table (sorted by harm)

**Coverage key:** **NEW** means not in `roadmap/in-progress/AGENT-OVERHAUL`. **partial** means an
AGENT-OVERHAUL task touches it but, as written, will not fix the dictation case.

| # | Limit | Value | Where | Verdict | Coverage |
|---|---|---|---|---|---|
| I1-01 | Apple cleanup per-call timeout floor | `min(14, 4.0 + 0.07·words)` s, where a cold first call is 4.69 s | FMF:260-264 | **HURTS** | NEW |
| I1-02 | Chunked cleanup runs 2 groups at once, each with a solo-call timeout | width 2, per-call `timeout(for:)` | `SentenceChunker.swift:150`, Router:343-354 | **HURTS** | NEW |
| I1-03 | Layout (Stage D) deadline independent of the cleanup it runs beside | `min(6, max(3.5, 0.3·sentences))` s | `StructurePlanner.swift:110-111` | **HURTS** | NEW |
| I1-04 | Microphone opens only after `engine.start()`; a release during `.starting` drops the hold | capture after model load, `fail(...)` | Controller:740-866, 914-918 | **HURTS** | partial (P0-06: cancellable acquire only) |
| I1-05 | An empty transcript from a hold with audio goes silently idle, and the audio is discarded | `finishIdle()` | Controller:1002-1014, 1334-1382 | **HURTS** | NEW |
| I1-06 | Parakeet minimum-audio mismatch | skip below 1,600 samples, FluidAudio rejects below 4,800 | `ParakeetEngine.swift:203` | **HURTS** (small) | NEW |
| I1-07 | `.error` state refuses the next press for 3 s | `guard case .idle`, `sleep(3)` | Controller:622, 1379-1382 | **HURTS** (small) | NEW |
| I1-08 | Correction learner: multi-word spans at 0.45 similarity, auto-added with no dedupe | 0.45, 1–3 words, `tooCommon` single-word only | `CorrectionLearner.swift:42,57-80`; `DictionaryStore.swift:49` | **HURTS** | NEW |
| I1-09 | S1-mini loaded at launch when grammar-on routes cleanup to Apple | gate on `cleanupEngine == .s1Mini` | `NextNotesApp.swift:278-282` | **HURTS** (low) | NEW |
| I1-10 | Salvage works per sentence, so an unpunctuated run-on is all-or-nothing | `CleanupGuard.salvage` by `SentenceChunker.sentences` | `CleanupGuard.swift` salvage; FMF:129-158 | MIXED | NEW |
| I1-11 | Cleanup starts only at key-up | whole transcript after release | Controller:1036-1054 | MIXED (largest latency term) | NEW |
| I1-12 | One hold at a time: `.finishing` refuses a new press for the whole tail | `guard state.isActive, state != .finishing` | Controller:622, 905 | MIXED | NEW |
| I1-13 | Timeouts do not record whether the session was prewarmed | `noteSessionPrewarmed` only on success | FMF:127 | MIXED (observability) | NEW |
| I1-14 | Screen-context adapters exist only for Cursor, Windsurf and VS Code | 3 bundle ids | `Context/AXAppAdapters.swift:44-75` | MIXED (low) | NEW |
| I1-15 | Dictation holds the single `.realtimeASR` lane for the whole hold | start → finish | `ParakeetEngine.swift:87`, `ComputeJob.swift:34-47` | MIXED (latent) | partial (P0-06) |
| I1-16 | Silent audio drops in the dictation feed | `.bufferingNewest(64)`, hub `maxPending = 8` | Controller:812, `AudioCaptureHub.swift:387` | MIXED (low) | partial (P2-08: "0 dropped chunks") |
| I1-17 | `runs.jsonl` has no retention and is reloaded whole on every write | unbounded | `Support/RunLog.swift`, `RunStore.swift:18-20` | MIXED (low) | NEW |
| I1-18 | Clipboard restore at a fixed 500 ms, with no `changeCount` check | 40 + 80 + 420 ms | `Core/TextInjector.swift:353-364` | MIXED (low) | NEW |
| I1-19 | `DictationController.Limits` (startup 45, drain 10, transcribe 90, cleanup 30, narrow 2, command 60 s) | — | Controller:322-347 | HELPS | — |
| I1-20 | `ChunkedFormatter` whole-pass budget 26 s, `maxWords` 120 | — | `SentenceChunker.swift:110,128` | HELPS | — |
| I1-21 | `CleanupGuard` rules: invention, length ratio 0.35–1.7, rewrite budget n/4, phonetic budget ≤ 3 | — | `CleanupGuard.swift:40-180, 435` | HELPS | — |
| I1-22 | Token caps: Apple cleanup 1,200, layout 500, app-LLM `min(1200, max(64, 4·words))` | — | FMF:241, `StructurePlanner.swift:144`, `AppLLMCleanupFormatter.swift:152` | HELPS | — |
| I1-23 | Parakeet partial cadence 1.0 s, reuse below 0.5 s leftover, one queued partial | — | `Transcription/StreamingASR.swift` | HELPS | — |
| I1-24 | Command Mode hold threshold of 400 ms; push-to-talk with no threshold | — | Controller:546; `HotkeyMonitor.swift:230` | HELPS | — |
| I1-25 | Return-to-app polling 600 + 400 ms, AX write verified by caret movement | — | `TextInjector.swift:115-139, 250-300` | HELPS | — |
| I1-26 | Bias and prompt caps: `biasLimit` 40, `promptNameLimit` 120, harvest 250 ms / 1,500 nodes / 200 names, Apple ASR wait 60 ms | — | `DictionaryCorrector.swift:139`, `ScreenContext.swift:318`, `AXHarvester.swift:31-48`, `AppleSpeechEngine.swift:151` | HELPS (inert on this Mac: Parakeet, no adapter apps) | — |
| I1-27 | `cleanupSkipsModelWhenBusy` (opt-in, on here), `shortWordLimit` 20 | — | Router:32, 510-543 | HELPS | — |
| I1-28 | `CleanupSessionWarmer.capacity` 3, taken once | — | FMF:319 | HELPS | — |
| I1-29 | `CorrectionLearner.maxCandidates` 5 | — | `CorrectionLearner.swift:34` | HELPS | — |

---

## 2. Detailed entries

### I1-01: Apple cleanup times out below its own measured cold start (HURTS, NEW)

**Limit.** `FoundationModelFormatter.timeout(for:)` (FMF:260-264) is
`min(14.0, 4.0 + words × 0.07)` seconds. On timeout the answer is thrown away, the rules output
is typed (`KeepAsIsFormatter`), and the user has waited the full budget for nothing.

**Why it exists.** A stalled model must not sit on the tail. The comment records that the first
formula, 1 s per 40 words, timed out on an 84-word dictation.

**The contradiction is in the same file.** The `CleanupSessionWarmer` table (FMF:279-283) records
a **4.69 s** first call in a fresh process, 1.42–1.58 s for later fresh sessions, and 0.94 s for
a prewarmed one. The floor is 4.0 s. So any dictation of 10 words or fewer that lands on a cold
model is guaranteed to time out, and one of about 20 words usually will. Dev reinstalls happen
several times a day on this Mac, and every one makes the next dictation a first call.

**Evidence (runs.jsonl, `fallbackReason: "on-device cleanup timed out"`):**

| date (UTC) | words | budget | waited | reasons |
|---|---|---|---|---|
| 09-20 18:01 | 10 | 4.7 s | 4.71 s | shortAndClean |
| 09-22 01:54 | 18 | 5.3 s | 4.99 s | disfluent |
| 09-22 21:38 | 16 | 5.1 s | 5.15 s | shortAndClean |
| 09-22 21:50 | 36 | 6.5 s | 6.53 s | long |
| 09-20 15:17 | 90 | 10.3 s | 5.07 s (older formula) | long, spokenList |
| 09-20 16:06 / 21:07 | 123 / 79 | 12.6 / 9.5 s | 12.3 / 9.4 s | long, disfluent |

In total, 9 of 50 model runs timed out, and they account for 69.6 s of 242.6 s of cleanup time.
The next dictation after 21:50 (09-22 21:52) was prewarmed and cleaned 40 words in 2.87 s.

**Proposed change:**
1. **Warm Apple FM at launch and after idle.** Call `CleanupSessionWarmer.stage` for the
   cleanup and layout prompts from `applicationDidFinishLaunching` (next to
   `prepareParakeet()`), and again after a wake from sleep, whenever
   `preferredEngine(...) == .apple`. The cold 4.69 s is then paid when nobody is waiting.
2. **Make the budget aware of the prewarm.** Pass `prewarmed` into the timeout. With a staged
   session, keep today's formula. Without one, add the measured cold-start penalty:
   `min(16, 8.5 + 0.07 × words)`. A true stall still ends, and a cold start is allowed to
   finish.
3. See I1-13 for recording the prewarm state on timeouts.

**Self-test:** extend `--selftest-cleanup-router` so a fake formatter delayed by 4.8 s with
`prewarmed=false` on a 10-word input must be *accepted*, and one delayed by 20 s must still
time out.

### I1-02: Two sentence groups share one model, and each is timed as if it ran alone (HURTS, NEW)

**Limit.** `ChunkedFormatter.width = 2` (`SentenceChunker.swift:150`) sends two groups to Apple
FM at once. Each group's ceiling is `FoundationModelFormatter.timeout(for: group)`, which is
calibrated for a call running alone.

**Evidence.** `modelSeconds` in the run record sums both calls, while `seconds` is wall time:

| date (UTC) | words | groups | Σ model | wall | outcome |
|---|---|---|---|---|---|
| 09-23 00:00 | 186 | 2 | 18.79 s | 9.77 s | timed out (at least one group) |
| 09-23 03:10 | 175 | 2 | 19.46 s | 11.51 s | timed out (at least one group) |
| 09-23 03:12 | 133 | 2 | 9.71 s | 7.16 s | accepted |

Two calls of about 90 words each ran about 9.5 s apiece at the same time. That is roughly twice
the solo cost, so the on-device model largely serialises them, and each hit its ~10.5 s ceiling.
Two of the three two-group runs since 09-23 lost cleanup. The whole-pass budget (26 s) was
nowhere near exhausted, so the per-call bound is the only thing that fired.

**Proposed change.** For the Apple engine, the ceiling of a call in a wave of `n` becomes
`timeout(for: group) × n`. The whole-pass 26 s budget still caps the wave, which keeps the
outer 30 s guarantee intact. Alternatively, run Apple at `width = 1` and keep width 2 for
engines that really parallelise. Also stage one extra cleanup session per extra group in the
first wave, because only group 1 gets the key-down prewarm today. Record the per-group verdict
in the trace, since the last writer currently wins.

**Self-test:** the existing mid-pass budget fixture in `structureThroughRouterFailures`
(Router:866-915) gains a case where two 200 ms calls serialise to 400 ms and must not be timed
out at 200 ms.

### I1-03: The layout pass is cut at 3.5 s while the user is still waiting 7–11 s for cleanup (HURTS, NEW)

**Limit.** `AppleStructurePlanner.budget(forSentences:)` is
`min(6.0, max(3.5, 0.3 × sentences))` (`StructurePlanner.swift:110-111`). The pass is started
beside Stage B (Router:139-153) and awaited only after Stage B returns (Router:216-217).

**Evidence.** The layout pass was asked 6 times. The only applied plan is 1 run with
`structureSource: "model plan"`. Four of the other answers are "the layout pass ran out of time
after 3.5s":

| date (UTC) | plan | cleanup wall | words |
|---|---|---|---|
| 09-23 00:00 | 3.53 s | 9.77 s | 186 |
| 09-23 03:10 | 3.52 s | 11.51 s | 175 |
| 09-23 03:12 | 3.51 s | 7.16 s | 133 |
| 09-23 22:02 | 3.50 s | 6.87 s | 109 |

In every case the user kept waiting 3.4–8 s *after* the layout deadline had discarded the plan.
The deadline saved nothing. The one dictation where the user dictated about this exact failure
(09-20 20:48, "The list never get triggered, the formatting doesn't go through") is in the same
record set.

**Proposed change.** Anchor the deadline to the cleanup pass. The plan may run until
`max(budget(forSentences:), cleanupFinishedAt + 0.5 s)`, and never past the 26 s whole-pass
budget. The fixed budget still applies on the rules route, where no model wait covers it.

**Risk.** Two requests on one on-device model slow each other (see I1-02). Measure the cleanup
wall time with and without the longer plan using `StructurePlanProbe`. If cleanup gets slower
by more than the plan saves, start the plan only after Stage B instead of beside it, and give it
its own staged session (the staged layout session exists already).

### I1-04: Speech during model start-up is lost, and so is a hold released during it (HURTS, partial P0-06)

**Limit.** `beginDictation` subscribes the microphone only after `engine.start()` has returned
and the session guard has passed (Controller:740-866). Anything said between key-down and
`.listening` is never captured. A release in `.starting` bumps the session and fails with "Next
Notes was still starting up, so that recording was lost. Hold the key again."
(Controller:914-918). The `ParakeetEngine.start()` comment (line 99-100) assumes "the user
waits before speaking". The HUD says nothing that tells them to.

**Why it exists.** A superseded start must not open the microphone for a recording nobody asked
for (Controller:829-831), and Apple's analyzer needs its contextual strings set before the first
buffer. Both hold, and neither needs the *capture* to wait: buffers can be held and replayed.

**Evidence:**
- **09-23 03:06:49Z:** `dictation.keyDown_to_capture` = **4.40 s**. It followed an app-LLM
  `model.load` of 52.3 s at 03:04:28Z (memory pressure on a 16 GB Mac). The first partial never
  arrived (`note: key-up` at 1.59 s after capture), transcription took 1.77 s, and **no run was
  filed**. The user spoke for about 6 s and got nothing.
- Parakeet is "~11 s cold" (Controller:302) and "~20 s from disk" (`NextNotesApp.swift:270`).
  The launch prewarm covers most launches but not a hold within the first 20 s.
- `keyDown_to_capture` p50 is 0.066 s, so the warm case is fine. The harm is concentrated in
  exactly the moments the machine is already struggling.

**Proposed change.** Add a key-down pre-roll. Subscribe `.dictation` on the hub at key-down into
a bounded in-memory buffer (cap 30 s, 16 kHz mono, about 2 MB), and replay it into the engine
once `start()` returns, before switching to live feed. On a superseded session the buffer is
dropped. If the user releases in `.starting`, keep the buffer and transcribe it when the engine
is ready rather than failing. For Apple, replay after `AnalysisContext` is set. The HUD shows
"Listening…" from key-down, which is then true. AGENT-OVERHAUL P0-06 makes `acquire`
cancellable. That helps the lane wait, but it does not capture the speech.

**Self-test:** `--selftest-dictation` with a `SelfTestEngine` whose `start()` takes 1.5 s. The
fixture words spoken in the first second must appear in the inbox, and a release at 1.0 s must
still produce a transcript.

### I1-05: A hold with audio but no words vanishes silently, and every failure discards the audio (HURTS, NEW)

**Limit.** When the transcript is empty and transcription "finished", the controller calls
`finishIdle()` with no message (Controller:1009-1010). Only zero captured frames gets a message.
`fail(...)` disowns the engine and buffers (Controller:1341-1364), so no path can retry the
recording. `runs.jsonl` files only successes, so these holds leave no record at all.

**Evidence.** Two real holds in 24 h left metrics spans and nothing else:
- 03:06:49Z (above);
- 09-23 22:03:10Z: capture 0.05 s, first partial `key-up` at 0.82 s, transcribe 1.45 s, no run.
  The user held the key again two seconds later (22:03:12Z) and that run was filed.

**Proposed change:**
1. `DictationAudioCounter` also tracks peak and RMS. An empty transcript over audio above a
   speech threshold says "I heard you but couldn't make out the words. Try again, or hold a
   little longer." Silence still goes idle quietly.
2. Keep the last failed hold's PCM in memory (one slot, dropped on the next success), and let
   the HUD or island error offer "Try again", which re-transcribes it.
3. File every hold outcome as `dictation.outcome` in `metrics.jsonl`: `inserted`, `empty`,
   `tap`, `lostAtStartup`, `failed:<reason>`. That makes the next audit countable instead of
   inferred.

### I1-06: A 0.1–0.3 s tap produces a raw FluidAudio error (HURTS small, NEW)

**Limit.** `ParakeetEngine.finish()` skips below 1,600 samples (0.1 s) (`ParakeetEngine.swift:203`).
FluidAudio rejects anything under 4,800 samples (0.3 s). A hold in between throws, and
`consumeTask` routes the throw to `fail(error.localizedDescription)`.

**Evidence.** 09-23 22:07:03Z: key-down → capture 0.04 s, key-up at 0.18 s. The log shows
`Parakeet failed: Invalid audio data provided. Must be at least 300ms of 16kHz audio.`, and the
same string went to the island as the dictation error (`[app]` category, 22:07:04.06). A
developer string was shown to the user for a stray tap.

**Proposed change.** If `1_600 ≤ samples.count < 4_800`, pad with zeros to 4,800 and transcribe:
a clipped "yes" is real speech. If the padded result is empty, go idle quietly. Make the
threshold one named constant shared with the partial path (`:266`).

### I1-07: The error card blocks the retry it asks for (HURTS small, NEW)

**Limit.** `fail` sets `.error(message)` and clears it after 3 s (Controller:1379-1382).
`beginDictation` begins with `guard case .idle = state else { return }` (Controller:622), so a
press in those 3 s does nothing: no HUD, no sound, no log. The two failures most likely to be
retried at once are "still starting up … Hold the key again." and "Couldn't switch back …".

**Evidence.** From code only. No refused press is logged anywhere (see I1-12).

**Proposed change.** Treat `.error` as idle for a new press: clear the message and start. The card
has already been seen. Log a refused press whenever one does happen.

### I1-08: The learner writes rewrites into the dictionary as rules for every app (HURTS, NEW)

**Limit.** `CorrectionLearner.candidates` accepts 1–3-word spans whose *whole-span* Levenshtein
similarity is ≥ 0.45 (`CorrectionLearner.swift:42, 57-80`). `tooCommon` protects only
single-word spans. With `dictionaryLearning = automatic` (this Mac), every candidate is appended
by `DictionaryStore.add` (`DictionaryStore.swift:49`), which does not deduplicate. The diff is
always against the original transcript, so re-saving an edited run re-adds the same rules.

**Evidence (`dictionary.txt` today):**
- `of a product -> for ProductFlo` came from the 09-18 13:07Z edit "a nice jump plugin of a
  product" → "an Altium plugin for ProductFlo". Its span similarity is **0.57**. From now on
  every "of a product" in any app becomes "for ProductFlo". By the same arithmetic,
  `of the -> for the` (0.71) would also be learned.
- Duplicates: `OLAMA -> Ollama` ×3, `Quentin 2.5 -> Qwen3.5` ×2, `quen 2.54b -> Qwen 3.5 4b` ×2,
  `chatgpd cloud -> ChatGPT Claude` ×2.

**Why the current shape exists.** Proper nouns, which are the most useful rules, are often
multi-word and case-only ("claude code" → "Claude Code"). The threshold was set to keep those.

**Proposed change:**
- Align multi-word spans token by token. Every changed token pair must pass 0.5 on its own, or be
  a case-only change, and at least one changed token must be outside `tooCommon`. "of→for,
  a→∅, product→ProductFlo" then fails on "of→for" (both common).
- In `automatic` mode, auto-add only single-token and case-only changes. Anything else goes to
  the Ask sheet.
- `DictionaryStore.add` becomes idempotent by `entry.id`.
- Diff a re-edit against the previous `editedText`.
- Add the "of a product" and "of the → for the" pairs to the learner's self-test (`--selftest-learn`)
  as must-refuse cases.

**Note:** the one rule already on disk should be offered for removal. Do not delete it silently;
the file is the user's.

### I1-09: S1-mini is loaded at every launch and never used (HURTS low, NEW)

**Limit.** `NextNotesApp.swift:278-282` loads S1-mini when `cleanupEngine == .s1Mini`. But
`CleanupRouter.preferredEngine` (Router:328-338) sends `s1Mini + fixesGrammar` to Apple. This
Mac has exactly that setting, so 484 MB (`s1-mini-q4_k_m.gguf`) are resident for nothing, on a
16 GB machine that already spent 52 s loading a model under pressure at 03:04Z. Meanwhile Apple
FM, the engine that does run, is not warmed at launch (I1-01).

**Proposed change.** Gate the launch prewarm on `preferredEngine(choice:fixesGrammar:)`: load
S1-mini for `.s1Mini`, and stage Apple sessions for `.apple`.

### I1-10: One unexplained word in an unpunctuated run-on discards the whole cleanup (MIXED, NEW)

**Limit.** `CleanupGuard.salvage` re-judges a rejected answer sentence by sentence. A
Parakeet transcript with no internal full stops is one "sentence", so salvage has nothing to
keep.

**Evidence.** There were 3 whole-answer rejections in 50 model runs. Two are already fixed in
code: the unchanged "Okay, go for it." length-ratio case (commit `1799ef8`, 09-21) and the
"need→needs" inflection. The third still holds. At 09-22 03:42Z, a 110-word single-sentence
dictation was rejected for "invented word: interface", almost certainly "ui ux" expanded to
"user interface". Every filler removal and repair in the other 108 words was lost (5.2 s
waited). Three salvages worked as designed (09-20 20:47, 20:48; 09-22 02:55).

**Verdict.** The guard itself HELPS: invention is the failure it exists for. The *granularity*
hurts.

**Proposed change.** When salvage finds a single sentence longer than about 30 words, fall back
to clause-level salvage: split on commas and conjunctions, and use a word-alignment splice that
keeps the model's tokens outside a ±3-word window around each unexplained word. Keep the guard
thresholds as they are.

### I1-11: Cleanup waits for key-up (MIXED, NEW; largest latency term)

**Limit.** The whole transcript goes to the cleanup model after release (Controller:1036-1054).
Parakeet already produces a stable partial every 1 s while the key is held (`StreamingASR`).

**Evidence.** In the metrics, cleanup is 93% of the release → text tail (5.19 s median against
0.38 s ASR and 0.15 s injection).

**Proposed change.** Clean completed sentences of the partial transcript during the hold. Use the
chunker's sentence split, with sentences at least one partial old and unchanged across two
partials. Cache each cleaned group keyed by its raw text, so key-up only cleans groups whose raw
text changed plus the tail. This preserves the chunked architecture (I1-02) and the guard. It
must respect the one-model contention measured in I1-02: run it at width 1, and cancel on
release if the tail is short.

### I1-12: A press during the tail is dropped without a trace (MIXED, NEW)

**Limit.** `.finishing` is active (Controller:114-117), and `beginDictation` returns silently.
With a tail of 5–12 s (I1-01..03), a user who starts the next thought right away loses the press.

**Why it exists.** AGENTS.md documents the "stuck in `.finishing`" history, and one set of
controller slots per hold.

**Evidence.** None can be collected today: a refused press writes nothing.

**Proposed change.** First, count it with a `dictation.press_refused` metric that carries the
state. If the count is material, pipeline the holds. Capture into the pre-roll buffer of I1-04,
start the new session once the old tail has released the engine slot, and inject in order.

### I1-13: A timed-out cleanup never says whether it was prewarmed (MIXED, NEW)

`trace?.noteSessionPrewarmed(prewarmed)` runs only after the task group returns a result
(FMF:127). All 9 timeouts therefore have `sessionPrewarmed: null`, and I1-01 cannot be proven
per run. Record `staged != nil` *before* `session.respond` (for example, return it from `take`
into the trace first). This is a one-line fix and should be made before I1-01 so its effect can
be measured.

### I1-14: Screen names exist only for three editors (MIXED low, NEW)

`AXAppAdapter.all` covers Cursor, Windsurf and VS Code. On this Mac the targets were Terminal
19×, Claude 19×, Muse 4×, Chrome 3× and others, with zero Cursor runs since 09-20. So
`dictation.names` is 0.00 s on all 15 metric holds, and the cleanup prompt has no names. AGENTS.md's
AX-readback measurement says Terminal and Electron apps expose no text, so an AX adapter is not
the answer. Instead, derive a working directory from the Terminal window title (`AXTitle`) and
feed file names from the existing file index for that folder. Low priority: only worth it if
spoken file names in Terminal dictations turn out to be common. They do occur ("move the writer
roadmap to the in-progress folder").

### I1-15: The single `.realtimeASR` lane is held for the whole hold (MIXED latent, partial P0-06)

`ParakeetEngine.start()` acquires `.realtimeASR` and releases it in `finish()`. That is the
whole hold, including a 98 s one. Meeting windows (`ChunkedTranscriber.swift:402`) and the
agent's capture take the same class. Equal priority does not preempt, so they queue FIFO. A
dictation during a recorded meeting delays that meeting's windows by the length of the hold,
and a dictation started while a meeting window runs waits for it. There is no evidence of harm
in the retained log ("dropped window" ×0). Keep for now. When P0-06 lands a cancellable
`acquire`, make the dictation hold per-pass: acquire around each partial or final `transcribe`
call, not around the hold.

### I1-16: Dropped audio is invisible to the run (MIXED low, partial P2-08)

The controller's feed stream is `.bufferingNewest(64)` (Controller:812). If the engine lags, the
*start* of the utterance is dropped with no log. The hub's per-consumer worker drops at
`maxPending = 8` and does log. The only three hub drops in 14 days (09-23 17:32:04 local, three
consumers in the same millisecond) came 10 s after a `--selftest-dictation` run and cannot be
attributed. Proposed: count both kinds of drop into the run record (`droppedBuffers`). P2-08's
"0 dropped chunks" gate is the right target, but it measures the hub, not this stream.

### I1-17: History has no retention and is reloaded whole (MIXED low, NEW)

`RunLog` appends forever, and `RunStore.reload()` re-parses the whole file on every mutation.
Today that is 226 rows and 177 KB. With cleanup records, rows are now about 1.5 KB, which at
this user's pace (≈ 15–40 holds a day) is roughly 10–20 MB a year, re-read on the main actor
after every dictation. The file also keeps `rawText` indefinitely. Proposed: an in-memory append
on record, a full reload only on edit or delete, and an opt-in retention setting (for example 90
days, or 5,000 rows).

### I1-18: Clipboard restore can overwrite a copy the user made meanwhile (MIXED low, NEW)

The pasteboard path restores the saved clipboard 500 ms after writing, unconditionally
(`TextInjector.swift:353-364`). If the user copies something inside that window, it is
replaced. `cleanup_to_injection` is p50 0.15 s, and nothing suggests the 500 ms is too short for
the target apps. The fix is a `changeCount` check before restoring; keep the timing.

### I1-19..I1-29: Keep (HELPS)

- **I1-19 `Limits`.** No production deadline has fired in the 14-day error log. Every such line
  comes from `--selftest-dictation`'s injected 2 s limits. They exist for the documented "stuck in
  `.finishing`" failure and cost nothing when unused. (Side note: the self-test writes
  error-level lines into the user's unified log, which made this audit harder. Tag them, or run
  the self-test under its own log category. That is adjacent to P0-11, which covers stores and
  not logs.)
- **I1-20 Chunk budget.** 26 s under the 30 s outer bound, and no run records "left as spoken".
  The 335-word maximum fits in two waves.
- **I1-21 Guard.** It rejected 3 of 50 answers, two of them already fixed. The per-sentence
  salvage recovered three more. The issue is granularity (I1-10), not the thresholds.
- **I1-22 Token caps.** Never reached: groups are ≤ 120 words, and the layout answer is a few
  dozen tokens.
- **I1-23 Partial cadence.** `speech_to_first_partial` p50 is 2.06 s. That is mostly the time
  before the user starts speaking (an empty partial is not emitted), not the 1 s cadence.
  Final-pass reuse keeps `transcribe` at 0.14–0.5 s for normal holds.
- **I1-24 Hold thresholds.** Push-to-talk fires on key-down, which is what makes it feel
  instant. The one stray tap is handled by I1-06, not by adding a threshold.
- **I1-25 Injection.** Key-down origin, two-mechanism return and the caret-moved check are all
  measured decisions in AGENTS.md, and there are no couldNotReturn errors in the log.
- **I1-26 Bias and prompt caps.** Correct as measured. On this Mac they are inert: the engine is
  Parakeet, which takes no contextual strings, and the targets have no adapter. Note for the
  roadmap: dictionary *terms* ("ProductFlo.io") therefore do nothing for Parakeet users; only
  `X -> Y` corrections apply. Whether FluidAudio's Parakeet supports vocabulary boosting is
  worth a spike, not a cap change.
- **I1-27 Busy shortcut.** Opt-in, and it fired once in 51 runs (09-22 03:39Z, 40 words, rules
  only). It behaves as documented.
- **I1-28 Warmer capacity 3.** Two prompts plus one spare; residency is real.
- **I1-29 `maxCandidates` 5.** A larger edit is a rewrite. The real problem is the per-span test
  (I1-08), not this cap.

---

## 3. Proposed tasks for a dictation and meetings roadmap

Each task follows the repo convention: a failing self-test or fixture first, then the fix. The
"Phase" column maps to the AGENT-OVERHAUL scale for ordering: 0 = make it work (nothing lost),
2 = latency.

| ID | Title | From | Phase | Effort | Proof |
|---|---|---|---|---|---|
| **D-01** | Record prewarm state before the call, and file every hold outcome (`dictation.outcome`, `press_refused`, dropped buffers) | I1-13, I1-05.3, I1-12, I1-16 | 0 | 0.5 d | `--selftest-dictation` asserts one outcome metric per hold, including tap and empty |
| **D-02** | Key-down pre-roll: capture from key-down, replay into the engine after start, and transcribe instead of failing on a release in `.starting` | I1-04 | 0 | 1.5 d | `--selftest-dictation` slow-start fixture: words in the first second survive |
| **D-03** | Never lose a hold silently: speech-energy check on empty transcripts, keep the last failed PCM, "Try again" | I1-05 | 0 | 1 d | fixture: a speech-level buffer with an empty engine result gives a message, not idle |
| **D-04** | Parakeet short-audio padding to 300 ms, and plain-language errors only | I1-06 | 0 | 0.25 d | fixture: a 0.2 s buffer is transcribed or goes quietly idle, never a raw error |
| **D-05** | A press during `.error` starts a new hold | I1-07 | 0 | 0.25 d | `--selftest-dictation`: fail, then press at +0.5 s, reaches `.listening` |
| **D-06** | Warm Apple FM at launch and after wake; gate the S1-mini load on `preferredEngine` | I1-01.1, I1-09 | 2 | 0.5 d | `--selftest-cleanup-router` checks the launch prewarm decision table |
| **D-07** | Prewarm-aware Apple cleanup timeout (cold: `min(16, 8.5 + 0.07·w)`) | I1-01.2 | 2 | 0.5 d | router fixture: a 4.8 s cold answer is accepted, a 20 s stall is not |
| **D-08** | Width-aware per-call ceilings for chunked Apple cleanup, staged sessions per group, per-group verdicts | I1-02 | 2 | 1 d | chunker fixture: serialised calls are not timed out at the solo ceiling |
| **D-09** | Anchor the layout-pass deadline to the cleanup pass it runs beside | I1-03 | 2 | 0.5 d | `StructurePlanProbe` before and after; router fixture: plan at 5 s, cleanup at 7 s, plan used |
| **D-10** | Learner safety: per-token alignment, auto-add only single-token or case-only, idempotent add, diff against the last edit; offer to review `of a product -> for ProductFlo` | I1-08 | 0 | 1 d | `--selftest-learn` must-refuse cases: "of a product→for ProductFlo", "of the→for the" |
| **D-11** | Clause-level salvage for long single-sentence answers | I1-10 | 2 | 1 d | `--selftest-cleanup` case: 110-word run-on with one expansion keeps the other repairs |
| **D-12** | Incremental cleanup of stable sentences during the hold | I1-11 | 2 | 2–3 d | `--selftest-dictation` + router: key-up cleanup touches only changed groups; tail p50 target ≤ 2 s |
| **D-13** | Pipelined holds (only if D-01 shows refused presses) | I1-12 | 2 | 2 d | fixture: two holds 1 s apart inject in order |
| **D-14** | Per-pass `.realtimeASR` acquisition for dictation (after P0-06) | I1-15 | 2 | 0.5 d | `--selftest-contention` with a meeting window and a hold interleaved |
| **D-15** | History hygiene: in-memory append, retention option, clipboard `changeCount` check, self-test log tagging | I1-17, I1-18, I1-19 note | — | 0.5 d | `--selftest-dictation` still `DICTATION_OK`; restore is skipped when `changeCount` moved |
| **D-16** | Spike: vocabulary boosting for Parakeet (FluidAudio), and title-derived context for Terminal | I1-26 note, I1-14 | — | 1 d spike | a written measurement in `Tests/Reports/` |

**Order:** D-01 first, because every later claim needs it. Then D-04, D-05 and D-10 (small and
correctness-only), then D-02 and D-03. After that, D-06 → D-07 → D-08 → D-09 as one latency
series, measured against `runs.jsonl` cleanup `seconds` and the timeout rate (today 18%, 29% of
cleanup time). D-11 and D-12 come last.
