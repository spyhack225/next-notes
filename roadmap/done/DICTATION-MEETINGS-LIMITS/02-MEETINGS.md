# DICTATION-MEETINGS-LIMITS — 02 Meetings (M-01 … M-16)

> **Historical model assumptions — revised 2026-09-30:** this completed plan/audit
> preserves its dated measurements and implementation history. For new work, follow
> the [independent-role/shared-file contract](../../in-progress/SHARED-BRAIN/00-README.md): Meetings, Agent and cleanup
> may use different appropriate models; exact verified artifacts are reused, with
> workload-specific consent and request ownership. Agent-only file selection,
> universal model defaults and deletion based only on the Agent are superseded.
> MiniCPM cleanup + Apple guard/fallback is concurrent work, not evidence that this
> historical build used it. Re-measure quality/latency on the actual current engine.

This file is the meetings half of the DICTATION-MEETINGS-LIMITS roadmap. `00-README.md` in this
folder is the entry point (workflow, phase gates, rules), `STATUS.md` is the only progress record,
and `01-DICTATION.md` holds D-01 … D-16. Where `00-README.md` is silent or not yet written, use
`roadmap/in-progress/AGENT-OVERHAUL/00-README.md` §5 (per-task workflow), §6 (phase gate), §8
(when you are stuck) and §9 (rules you must never break). Those sections apply here unchanged,
with this roadmap's IDs and `~/Library/Caches/NextNotesBuild/dictation-meetings/<ID>-red.txt` /
`…-green.txt` as the output paths.

Evidence: `roadmap/done/agent-analysis-2026-09-23/I2-caps-meetings.md` (entries #1–#34, tasks M-01 …
M-16 in its §3). Task IDs are I2's. Lettered subtasks (M-16a) are allowed; never renumber.
Paths below are relative to `Sources/NextNotes/` unless they start with `Tests/`, `Scripts/`,
`roadmap/` or name a repo-root file. Every anchor was re-read on 2026-09-24 against the working
tree; the tree has uncommitted changes, so grep the quoted symbol if a line moved.

---

## 1. Overview

### 1.1 Goal

Every call that should be recorded is recorded; it is transcribed accurately in the language that
was spoken; the far-end speakers are told apart and named; the notes cover the whole meeting at
any length on any provider; and a crash, a quit or a `make install` never loses a meeting or the
audio a later stage still needs.

### 1.2 What is wrong today (measured)

All numbers are from I2 unless marked. The six meetings on this Mac were recorded 2026-09-09 …
09-19 (5 WhatsApp/FaceTime, 1 ChatGPT voice in Chrome), 4–26 min, mostly French.

| # | Problem | Evidence | Task |
|---|---|---|---|
| 1 | Finals come from 2–5 s Parakeet windows with a fresh decoder per window; French calls come back partly as invented English | Wrong-language segments by stop-word heuristic: **6 %** (19/329) in C978 on 09-13 with 25 s windows, **16 %** (88/562) CEAC 09-16 and **24 %** (94/393) 6C5E 09-19 with 5 s windows. Samples from the father's French: "Uh it's a good time as a parking lot of it.", "Bueno, it would be this way." The live context then holds the topic "Parking lot". Hard cuts mid-word ("…donc les 5 mi"); 23–33 % of segments under 1 s | M-01 |
| 2 | The browser consent gate never fires: Core Audio reports the helper, not the browser | `callAppsSeen` holds `com.google.Chrome.helper = "Google Chrome Helper"`; meeting 1B6B's `calendarEventID` is `com.google.Chrome.helper@1789326398`. `askOnlyBundleIDs` lists `com.google.Chrome`, so "Always record" is offered and auto-record would record a browser call unasked. Also armed questions for `com.apple.replayd`, `Codex (Service)`, `Cursor Helper` | M-02 |
| 3 | Diarizer runs with no speaker-count hint | 3 of 6 meetings over-split: a 1:1 WhatsApp came back with 3 speakers the user renamed to one name; ChatGPT voice came back as 2 | M-03 |
| 4 | Far-end segments with no overlapping speaker run stay unlabelled | 50 % (55/109), 29 % (82/287), 30 % (30/101) of system segments unlabelled; unlabelled median 0.72–1.36 s | M-04 |
| 5 | Map-reduce silently drops the *oldest* facts when they overflow | `facts.removeFirst()` in `NotesGenerator.mapReduce`. Meeting notes run on Apple FM since P0-01 (`modelRoles.meetingNotes = apple`, AGENT-OVERHAUL STATUS). With the hard-coded 4,096 window, meetings beyond ≈ 35–55 min (estimate) lose their opening facts; with the real 8,192 window (G measured; read after P1-10a) the edge moves to ≈ 90 min (estimate) but the silent drop stays | M-05 |
| 6 | "Record this call?" island card lives 8 s for a detected call | `announceArmed` → `max(islandNotice, start − now)` and a call's `start` is in the past. `callDetectionAutoRecord` defaults to `false`, so a fresh install depends on this card; unanswered, `retire` deletes the armed meeting | M-06 |
| 7 | Transcription backlog is 8 *windows*, i.e. 16–40 s of audio since the 2–5 s change, and the newest window is dropped | `ChunkedTranscriber.maxPendingWindows = 8`; `enqueue` logs "transcription backlog full — dropped window" | M-07 |
| 8 | Interrupted meetings are never resumed | Quit → `.done` without notes, temp audio never released; crash while recording → `.failed` though `transcript.json` is intact; crash while diarizing/summarising → `.done` and **temporary audio deleted** | M-08 |
| 9 | No watchdog on diarization or notes | A hang shows "Writing notes…" until the next launch, which then deletes the audio (row 8) | M-08 |
| 10 | System-audio tap: one 5 s start attempt, then mic-only for the whole meeting | "system audio start timed out; awaiting HAL return for cleanup" fired on 2026-09-23 15:10 | M-09 |
| 11 | Temporary audio deleted as soon as notes land | No "re-identify speakers" or re-transcription is possible afterwards | M-10 |
| 12 | Detected call and calendar meeting are not unified; calendar recording ignores the hang-up | Latent (no calendar meeting recorded here) | M-11 |
| 13 | Apple FM window hard-coded 4,096, 4 chars/token, prompt overhead 512 vs ≈ 630 real, no overflow retry | Code reading; G measured the real window at 8,192 | M-12 |
| 14 | Notes cap 1,500 tokens; `LLMCompletion` has no finish reason, so a cut-off answer is padded with `_None._` | Code reading; no truncation seen yet (longest notes ≈ 600 tokens) | M-13 |
| 15 | Live reconcile schedules on *finals count* (8), now several model passes a minute; reads the last 32 segments; runs the Agent model ungated | Code reading + 6C5E's "Parking lot" topic | M-14 |
| 16 | Speaker identification off by default | `meetingsDiarize ?? false` | M-15 |
| 17 | No per-stage meeting metrics; `transcript.json` rewritten on every segment | `metrics.jsonl` starts 09-22 and has no meeting stage spans | M-16 |

### 1.3 Targets (what "done" means for this file)

| Target | Measured by | Task |
|---|---|---|
| Wrong-language segment rate on the French fixtures ≤ **2 %**, and at least 4× lower than the 2–5 s live path on the same audio | `--selftest-meeting-finals` with `TranscriptLanguageProbe` (M-16a) | M-01 |
| A helper-bundle audio process maps to its owning app **100 %** of the table cases; no browser helper is ever offered "Always record" | `--selftest-calls` | M-02 |
| Detected-call question visible for the whole call (≥ 60 s in the fixture) and gone after `retire` | `--selftest-island` | M-06 |
| **Zero** dropped notes facts on a 90-min fixture on a 4,096-token fake provider | `--selftest-notes-longform` | M-05 |
| Unattributed far-end lines ≤ **10 %** on the diarization fixture | `--selftest-diarize-assign` | M-04 |
| A 1:1 call never comes back with more than 2 far-end clusters on the fixture | `--selftest-diarize-hints` | M-03 |
| 3/3 seeded interrupted meetings reach `.done` with notes; no temporary audio released before its stage finished | `--selftest-meeting-resume` | M-08 |
| 0 seconds of audio lost behind a slow transcriber over 3 min of input | `--selftest-meeting-backlog` | M-07 |
| Final-pass cost ≤ **5 %** of meeting duration (estimate target; measured on the fixtures and on the owner's next real meeting) | `MEETING_FINALS_RTF` line | M-01 |

### 1.4 Order

Metrics first, then the top five by harm, then the rest.

1. **M-16a** — `TranscriptLanguageProbe`, `MeetingQualityProbe`, stage spans and the read-only
   `--meeting-quality-report`. Record the six real meetings' baseline in `STATUS.md` before any
   other meeting task. Every later "better" is measured against it.
2. **M-02** (consent, pure, cheap), **M-06** (consent, small), **M-05** (notes completeness on the
   provider P0-01 already selected), **M-01** (transcript accuracy; the largest win for every
   downstream reader), **M-08** (never lose a meeting; must know M-01's final pass, so after it).
3. **M-04**, **M-03** (speakers; M-04 is pure and cheap), **M-12**, **M-13** (notes budgeting and
   truncation), **M-07**, **M-09**, **M-10** (robustness), **M-11**, **M-14**, **M-15**,
   **M-16b** (after AGENT-OVERHAUL P0-20b), **M-16c**.

If a task's dependency is not `done`, skip to the next task whose dependencies are met; never
start a task out of dependency order to "save time".

### 1.5 Dependencies on AGENT-OVERHAUL (`roadmap/in-progress/AGENT-OVERHAUL/`)

That roadmap is being executed right now by the same executor. As of 2026-09-24 its `STATUS.md`
shows **done**: P0-01, P0-05, P0-06, P0-09, P0-13, P0-15, P0-19; **blocked**: P0-10; everything
else `todo`. Re-read its `STATUS.md` before starting any task below that names one of its IDs.

| AGENT-OVERHAUL task | State (09-24) | What it means here |
|---|---|---|
| P0-01 model state | done | Meeting notes run on **Apple FM** (`modelRoles.meetingNotes = apple`). This is why M-05, M-12 and M-13 are urgent: the 4K map-reduce path is now the path every meeting over ≈ 10–14 min takes. |
| P0-06 warmup lane, cancellable `acquire` | done | M-01's final pass and M-07 use `ComputeScheduler.acquireCancellable` and must not run at `.realtimeASR` after Stop. |
| P1-10a step 0 (Apple FM `contextSize`) | todo | **Owns** `FoundationModelLLMProvider.contextTokens`. M-12 depends on it. If M-12 is reached first, M-12 implements P1-10a step 0 *verbatim*, marks it in **both** `STATUS.md` files ("P1-10a step 0 landed in M-12, commit …"), and P1-10a then skips that step. |
| P0-17 OpenRouter `finish_reason` | todo | **Owns** OpenRouter decoding. M-13 adds `LLMCompletion.finishedByLimit` for every provider and consumes P0-17's result for OpenRouter; M-13's OpenRouter leg waits for P0-17. |
| P0-20 → P0-20a … P0-20e (usage log) | todo (being widened) | P0-20a defines the writer and schema (`feature, pass, provider, modelID, ttftMs, totalMs, errorClass`, correlation ids); **P0-20b** is the meetings usage log. **M-16b** writes the notes and reconcile model passes through P0-20b's writer and depends on it. M-16a (stage spans, counters) does not record model passes and does not wait. Never create a second model-pass log. |
| P0-14 one provider per turn | todo | M-14's reconcile resolves its provider with `LLMProviders.resolve(preferring: Settings.agentModelProvider …)`, outside `ModelRoleStore`. M-14 switches it to the role store only after P0-14 lands; before that, leave the resolution alone. |
| P3-07a capacity lanes | todo | M-14 (live reconcile during a meeting) coordinates with it: until P3-07a lands, M-14 reduces how often the model runs; it does not add a lane. |
| P0-11 store isolation | todo | Does not cover `MeetingStore`. M-08 adds the `MeetingStore` test seam itself. |

### 1.6 Components shared with `01-DICTATION.md`

| Shared component | Dictation task | Meetings task | Who owns the change |
|---|---|---|---|
| `ParakeetModels.shared`, `TranscriptionQueue` (`Meetings/ChunkedTranscriber.swift`) | D-14 (per-pass `.realtimeASR` for dictation, `Transcription/ParakeetEngine.swift`) | M-01 (final-pass caller, `lane:` parameter), M-07 (backlog) | **M-01/M-07 own `ChunkedTranscriber.swift` and `TranscriptionQueue`.** D-14 owns `ParakeetEngine.swift`. If both edit `Core/Compute/ComputeJob.swift`, the second to land rebases; neither changes the other's lane semantics. |
| Parakeet minimum input (FluidAudio rejects < 0.3 s: `ASRConstants.minimumAudioDurationSeconds = 0.3`; the app skips only < 1,600 samples = 0.1 s in both `ParakeetEngine.finish()` and `ChunkedTranscriber.minTranscribableSamples`) | D-04 (pad to 300 ms, plain errors) | M-07 (merged windows), M-01 (final windows) | **D-04 owns the padding helper.** It must live where both paths can call it (for example `Transcription/ParakeetInput.swift`, `static func padded(_ samples: [Float]) -> [Float]`). M-01/M-07 call it; they never write a second copy. If D-04 is not done when M-01/M-07 run, they leave `minTranscribableSamples` as it is. |
| FluidAudio `language:` hint | D-16 (vocabulary spike) | M-01 | Neither. The hint is **script-level only** (Latin / Cyrillic / Greek, `Shared/TokenLanguageFilter.swift` in the FluidAudio checkout), so it cannot tell French from English and is not a fix for M-01. Do not wire it for French. |

### 1.7 Rules that matter most in this file (full list: AGENT-OVERHAUL `00-README.md` §9)

- Build with `make build`, test Swift with `make test`, install with `make install OPEN=0`, run
  self-tests with `Scripts/run-selftest.sh --selftest-…` in the foreground, one at a time. TCC-bound
  tests (microphone, system audio) use `--via-open`, never in a loop. Never bare-invoke the binary.
- A self-test prints one final `<NAME>_OK` / `<NAME>_FAILED: <reason>`; a missing precondition
  prints `<NAME>_ABSENT: <what>`. It must **fail** when the thing it names did not happen.
- A self-test never writes the user's real stores: not `~/Library/Application Support/Next Notes/
  Meetings/`, not `runs.jsonl`, not `UserDefaults` keys such as `callAppAnswers`. `MeetingStore`
  has no test root today (`MeetingStore.shared`, `Meetings/MeetingStore.swift:23`); M-08 adds one,
  and every seeded-meeting test uses it.
- A new property on `Meeting` goes into the hand-written `Meeting.init(from:)`
  (`Meetings/MeetingModels.swift`, the `decodeIfPresent` block from `:320`) as `decodeIfPresent`.
  **Do not add a `MeetingStatus` case**: its decoder throws on an unknown state, so an older build
  would drop every meeting a newer build wrote. The tasks below reuse existing states.
- `MainActor.assumeIsolated` is forbidden; use `await MainActor.run`.
- Red means recording and nothing else; views take every value from `DS` tokens.
- New flags: register in `NextNotesApp.runRequestedSelfTest` (`NextNotesApp.swift:392`), add to the
  AGENTS.md flag list and to `Scripts/acceptance.sh` (tier given per task).
- One commit per task, `M-NN: <title>`, staged by path; never commit `roadmap/`.
- When a task changes a limit AGENTS.md documents as deliberate, the task quotes the paragraph,
  says what new evidence overrides it, and updates AGENTS.md in its *Done when*.

### 1.8 Test fixtures (generated speech, committed)

Created once by M-16a step 1 and used by M-01, M-03 and M-04 (M-07 and M-08 synthesise their own audio in memory). Generated with `say`,
so no real voice is committed (the precedent is `Tests/Fixtures/meeting-2min.wav` and
`Tests/Fixtures/wake/generate.sh`). Voices verified present on this Mac with `say -v '?'`.

`Tests/Fixtures/meetings/generate.sh` (new, `set -euo pipefail`, same shape as the wake script)
renders, for each script in `Tests/Fixtures/meetings/scripts/*.txt` (one turn per line, prefixed
`A:` / `B:` / `C:`):

```bash
render() { # voice text out.wav
  say -v "$1" "$2" -o "$TMP/turn.aiff"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/turn.aiff" "$3"
}
# French: A = "Thomas (French (France))", B = "Flo (French (France))", C = "Grandpa (French (France))"
# English: A = "Samantha (English (US))", B = "Reed (English (US))", C = "Rocko (English (US))"
```

It then concatenates the turns with 0.8 s of silence between them (a short `python3` stdlib
`wave`/`array` helper inside the script, no numpy), writing:

| File | Content | Used by |
|---|---|---|
| `fr-dialogue.wav` | 16 French turns, A and B alternating, ≈ 90 s, mono 16 kHz Int16 | M-01 |
| `en-dialogue.wav` | the same shape in English | M-01 (control: must stay English) |
| `fr-dialogue-phone.wav` | `fr-dialogue` band-limited through 8 kHz (`afconvert -d LEI16@8000` then back to 16000) with white noise at −45 dBFS added by the helper — a stand-in for WhatsApp's codec and comfort noise, which keeps RMS above the 0.01 gate | M-01 |
| `fr-call-mic.wav` / `fr-call-system.wav` | one 3-person French call split into two equal-length tracks: A's turns on the mic track (silence elsewhere), B's and C's on the system track | M-03, M-04 |
| `fr-1to1-system.wav` | B only on the system track (a 1:1 call's far end) | M-03 |
| `manifest.json` | per file: duration, per-turn `{speaker, start, end, text}` in seconds | ground truth for all of the above |

Each file stays ≤ 3 MB (16-bit mono, ≤ 95 s). Write the scripts in natural spoken register with
numbers and names ("On garde le budget à quarante mille", "Marc s'occupe du devis") so the
fixtures carry the kind of content I2 saw mangled. Append a section to `Tests/Fixtures/README.md`
describing the folder and the regenerate command. Synthetic speech is cleaner than a real call:
a fixture passing is necessary, not sufficient, which is why M-01 and M-04 also re-measure the
owner's next real meeting with `--meeting-quality-report`.

### 1.9 Limits we keep on purpose (I2 verdict HELPS)

Do not remove or "tune" these while working on the tasks. Each is measured or documented.

| I2 # | Limit | Where | Why it stays |
|---|---|---|---|
| 22 | Hand-started recordings never auto-stop | `MeetingScheduler.stopFinishedMeeting` (`Meetings/MeetingScheduler.swift:269`) | AGENTS.md "An armed meeting's `end`…": a recording started on purpose is never cut for being quiet. |
| 23 | Call on/off debounce 3 s / 15 s, 5 s backstop poll | `CallPolicy.onThreshold` / `offThreshold` (`Meetings/CallPolicy.swift:29,34`) | AGENTS.md "The microphone flag flickers": measured flicker; lowering `offThreshold` reintroduces the bug. |
| 24 | `deniedBundleIDs` is a denylist, not an allowlist | `CallPolicy.deniedBundleIDs` (`:48`) | AGENTS.md "`corespeechd` holds the microphone…": an unknown conferencing app must work on day one. M-02 adds `com.apple.replayd` by measurement; nothing else. |
| 25 | Detected calls exempt from the overrun rule; 10-min silence backstop | `stopFinishedMeeting` (`:272-283`) | A call has no scheduled end; the detector ends it. |
| 26 | Segment = 600 ms pause, or sentence end once ≥ 2 s, *inside* a window | `ChunkedTranscriber.utteranceGap`, `minSentenceSeconds`, `segments(from:…)` | AGENTS.md "A transcript segment is a sentence…": measured (3 → 20 segments, 1 → 2 speakers). M-01 changes the window around this rule, never the rule. |
| 27 | Writer lead 5 s; 16-bit stereo on disk (≈ 230 MB/h) | `MeetingAudioWriter` | Pads the late side; size is what makes M-10's retention affordable. |
| 28 | Notes model 10-min idle unload; cleanup gate; warm at meeting start | `NotesModelRuntime` (`:50`), `MeetingSession.start` | AGENTS.md "The notes model unloads itself" / "cleanup gate is one-directional". |
| 29 | Brief counted before the single-pass decision; map step without the brief; `emptySection` | `NotesGenerator.notes` / `mapReduce` | AGENTS.md "The Related-context brief is deliberately absent from three places". M-05/M-12 keep all three. |
| 30 | `audioIsTemporary` decided at start; the three-line `releaseAudio` rule | `MeetingSession.start` (`:89-101`), `MeetingStore.releaseAudio` (`:312`) | AGENTS.md "A meeting records audio even when…". M-01 and M-10 change *when* and *why* a temporary file exists, never the rule's shape. |
| 31 | `armedGrace` 10 min, `tickInterval` 30 s, one session at a time | `MeetingScheduler` (`:23,31`) | Documented and sound. |
| 32 | Diarizer `minimumAudioSeconds 2`; voice print `minimumSeconds 3` | `MeetingDiarizer` (`:33`), `SpeakerVoicePrints` (`:25`) | Below these there is nothing to cluster or average. |
| 33 | Frame silence gate RMS 0.01 (≈ −40 dBFS) | `ChunkedTranscriber.silenceThreshold` | No evidence against it. Recheck only with far-field fixtures (not in this roadmap). |
| 34 | Calendar look-ahead 24 h / look-behind 1 h / poll 5 min; declined-only exclusion | `Calendar/CalendarService.swift:29-34` | H3 #34: fine. |

### 1.10 New and extended flags in this file

| Flag | Task | Tier in `Scripts/acceptance.sh` |
|---|---|---|
| `--selftest-meeting-quality` (new) | M-16a | INTEGRATION |
| `--meeting-quality-report` (new diagnostic, not a self-test; reads real meetings read-only) | M-16a | none |
| `--selftest-calls` (extended) | M-02 | EXPERIMENTAL (unchanged) |
| `--selftest-island` (extended) | M-06 | EXPERIMENTAL (unchanged) |
| `--selftest-notes-longform` (new) | M-05, M-12 | INTEGRATION |
| `--selftest-meeting-finals [<dir>]` (new) | M-01 | INTEGRATION |
| `--selftest-meeting-resume` (new) | M-08 | CORE (a lost meeting is a release blocker) |
| `--selftest-diarize-assign` (new) | M-04 | INTEGRATION |
| `--selftest-diarize-hints` (new) | M-03 | INTEGRATION |
| `--selftest-notes-truncation` (new) | M-13 | INTEGRATION |
| `--selftest-meeting-backlog` (new) | M-07 | INTEGRATION |
| `--selftest-meeting-tap-retry` (new) | M-09 | INTEGRATION |
| `--selftest-audio-retention` (new) | M-10 | INTEGRATION |
| `--selftest-calendar` (extended) | M-11 | as today |
| `--selftest-meeting-live` (extended) | M-14 | CORE (unchanged) |
| `--selftest-onboarding` (extended) | M-15 | as today |
| `--selftest-metrics` (extended) | M-16a, M-16c | as today |

---

## 2. Tasks

### M-16a — Measure first: transcript-quality probe, meeting stage spans, fixtures, and a read-only quality report

**Finding(s):** I2 #19 (stage half), #1/#3/#4 (measurement), §1.8 fixtures  **Effort:** 1 d  **Depends on:** none  **Unblocks:** M-01, M-03, M-04, M-05, M-07, M-08 (they reuse the probe, the fixtures or the spans), M-16b

**Why (what the user experiences today):** Nothing records how good a meeting transcript was. I2
had to measure the language flips (6 % → 16 % → 24 %), the unlabelled far-end share (29–50 %) and
the over-split speakers (3 of 6 meetings) by hand from `transcript.json` files, because
`metrics.jsonl` has no meeting stage spans and the notes log line ages out of the unified log
within minutes. Every later task in this file claims an improvement; without this task none of
those claims can be checked on the owner's real meetings.

**Files you will change:**
- new `Meetings/MeetingQualityProbe.swift`: `TranscriptLanguageProbe`, `MeetingQuality`,
  `MeetingQualityProbe` (pure) and `MeetingQualityProbe.runSelfTest()`.
- `Support/LatencyTrace.swift`: five `LatencySpanID` cases, added to the `.meeting` arm of
  `LatencySpanID.pipeline` (`:64-80`).
- `Meetings/MeetingSession.swift` `stop()` (`:233-277`): one `meeting.drain` span.
- `Meetings/DiarizationService.swift` `diarize(_:)` (`:90-160`): one `meeting.diarize` span.
- `Meetings/NotesService.swift` `generate(…)` (`:43`): one `meeting.notes` span.
- `Meetings/ChunkedTranscriber.swift` `enqueue(window:)` (`:186-190`): one
  `meeting.windows_dropped` span per dropped window.
- `NextNotesApp.swift`: `--selftest-meeting-quality` in `runRequestedSelfTest` (`:392`), and
  `--meeting-quality-report` next to `--notes-context-live` (`:212`), before the self-test check.
- new `Tests/Fixtures/meetings/generate.sh`, `Tests/Fixtures/meetings/scripts/*.txt`, the
  generated `*.wav` + `manifest.json` (§1.8); `Tests/Fixtures/README.md` (one section).
- `AGENTS.md` (flag list), `Scripts/acceptance.sh` (INTEGRATION).

**Read for context (do not change):** `Support/MetricsStore.swift` (the harness store is a temp
directory, so `--selftest-metrics` writes nothing real); `LatencyTrace.record(_:seconds:endedAt:note:store:)`
(`Support/LatencyTrace.swift:301`); `runNotesContextLiveProbe` in `NextNotesApp.swift` (`:2557`) —
the pattern for a diagnostic that must read the real stores; `Meetings/MeetingModels.swift`
(`TranscriptSegment`, `Meeting.speakerNames`).

**Current behaviour:** `LatencySpanID` has five meeting cases, all live-path latencies
(`meeting.speech_to_partial`, `meeting.speech_to_final`, `meeting.transcript_to_context`,
`meeting.action_phrase_to_candidate`, `meeting.candidate_to_card`). Nothing times the drain after
Stop, the diarization pass or the notes pass, and a dropped window is only a log line:
```swift
// ChunkedTranscriber.enqueue(window:) — :187-190
guard pendingCount < Self.maxPendingWindows else {
    Log.meeting.error("transcription backlog full — dropped window")
    return
}
```

**Target behaviour:**
1. `TranscriptLanguageProbe.guess(_:)` classifies a line as `.english`, `.french` or `.unknown`
   deterministically, and `MeetingQualityProbe.measure(meeting:segments:)` returns a
   `MeetingQuality` with the fields listed in step 2.
2. `metrics.jsonl` gains `meeting.drain`, `meeting.final_pass` (written by M-01),
   `meeting.diarize`, `meeting.notes` and `meeting.windows_dropped` rows. None of them carries a
   model name, token count or any transcript text (model passes belong to P0-20b / M-16b).
3. `Scripts/run-selftest.sh --meeting-quality-report` prints one line per finished meeting on this
   Mac and never writes anything.
4. The fixtures in §1.8 exist and regenerate byte-for-byte from `generate.sh` on the same macOS.

**Steps:**
1. Write `Tests/Fixtures/meetings/generate.sh` and the scripts exactly as §1.8 describes. Run it
   once. Check with `afinfo` that every WAV is 1 ch, 16000 Hz, Int16 and ≤ 95 s, and that
   `manifest.json` lists every turn. Add the README section.
2. `MeetingQualityProbe.swift`:
   ```swift
   enum TranscriptLanguageProbe {
       enum Guess: String, Sendable { case english, french, unknown }
       /// Lowercase, fold ’ to ', split on anything that is not a letter or an apostrophe,
       /// count tokens in `englishMarkers` and `frenchMarkers`.
       /// english: en ≥ 2 && en > fr.  french: fr ≥ 2 && fr > en.  otherwise unknown.
       static func guess(_ text: String) -> Guess
       static let englishMarkers: Set<String>   // the, and, is, are, it, it's, you, to, of, that, this, with,
                                                // for, have, so, like, what, can, if, don't, was, be, we,
                                                // they, there, just, about, would, going, i'm
       static let frenchMarkers: Set<String>    // le, la, les, et, est, de, des, du, que, qui, un, une, je,
                                                // tu, il, elle, pas, ça, pour, avec, dans, mais, c'est, nous,
                                                // vous, sur, au, aux, très, donc, alors, j'ai, n'est
   }
   struct MeetingQuality: Sendable, Equatable {
       var segments: Int
       var maxSegmentSeconds: Double
       var shortSegmentShare: Double          // segments shorter than 1.0 s / segments
       var dominantLanguage: TranscriptLanguageProbe.Guess
       var guessedSegments: Int               // segments whose guess is not .unknown
       var wrongLanguageSegments: Int         // guessed, and not the dominant language
       var wrongLanguageShare: Double         // wrong / guessed (0 when guessed == 0)
       var systemSegments: Int
       var unattributedSystemShare: Double?   // nil when no system segment carries a speaker (not diarized)
       var speakerLabels: Int                 // distinct non-nil speakers on the system track
       var distinctNames: Int                 // distinct speakerNames[label] ?? label over those labels
       var overSplit: Bool { speakerLabels > distinctNames }
   }
   enum MeetingQualityProbe {
       static func measure(meeting: Meeting, segments: [TranscriptSegment]) -> MeetingQuality
       static func line(for meeting: Meeting, quality: MeetingQuality) -> String   // the report row
       static func runSelfTest() -> [String]                                     // failures
   }
   ```
   Ignore `kind == .agentCommand` segments everywhere. The dominant language is whichever of
   `.english` / `.french` has more guessed segments (ties → `.unknown`, share 0).
3. Spans: add `meetingDrain = "meeting.drain"`, `meetingFinalPass = "meeting.final_pass"`,
   `meetingDiarize = "meeting.diarize"`, `meetingNotes = "meeting.notes"`,
   `meetingWindowsDropped = "meeting.windows_dropped"`, all in the `.meeting` pipeline arm.
   - `stop()`: take `let began = Date()` as the first line after the guard; after
     `store.saveTranscript(segments, for: meeting.id)` call
     `LatencyTrace.record(.meetingDrain, seconds: Date().timeIntervalSince(began), note: "segments=\(segments.count)")`.
   - `diarize(_:)`: time from after `progress[id] = 0` to the return; note
     `runs=<n> speakers=<n> audio=<seconds>s` on success, `error=<type name>` on failure (the type
     name only, never the message, which can contain a path).
   - `generate(…)` in `NotesService`: time the whole call; note `mapReduce=<bool>` (M-05 adds
     `chunks=<n> collapsed=<n>`), or `error=<type name>`.
   - `enqueue(window:)`: in the drop branch, before `return`, record `meetingWindowsDropped` with
     `seconds:` = the dropped window's duration and note `source=<mic|system>`. Keep the log line.
4. `--meeting-quality-report`: in `applicationDidFinishLaunching`, next to the
   `--notes-context-live` branch and for the same reason (it must read the real
   `MeetingStore.shared`, which the harness would not replace but should not be touched under
   `SelfTest.isRunning` either). For every meeting with `status == .done`, newest last, print
   `MeetingQualityProbe.line(…)`:
   `MEETING_QUALITY <first 4 of id> <yyyy-MM-dd> <minutes>min segs=<n> max=<s>s short=<pct>% lang=<en|fr|?> wrong=<pct>% (<w>/<g>) sys=<n> unlabelled=<pct|n/a> labels=<n> names=<n>`,
   then `MEETING_QUALITY_REPORT_DONE: <n> meeting(s)` and terminate. It calls no `save`, no
   `repairInterruptedMeetings`, no pipeline. Honour `--selftest-out <path>` like the other
   diagnostics.
5. `--selftest-meeting-quality`: run `MeetingQualityProbe.runSelfTest()` and print
   `MEETING_QUALITY_OK` or `MEETING_QUALITY_FAILED: <n> check(s) wrong` after one line per failure.
6. Register both flags; add `--selftest-meeting-quality` to AGENTS.md's list and to
   `INTEGRATION_ENTRIES` as `"selftest-meeting-quality|120"`. Mention `--meeting-quality-report`
   in AGENTS.md next to `--notes-context-live` as a diagnostic, not a self-test.
7. Run the report on this Mac and paste the rows into `STATUS.md` under a "Meetings baseline"
   heading. The numbers will not equal I2's (different word lists); these become the baseline.

**Do not:**
- record transcript text, titles or speaker names in `metrics.jsonl` (the note fields above are
  the whole list);
- write model-pass records here; P0-20b / M-16b own those;
- make the report a `--selftest-*` flag (the harness exists to keep tests off real data; this one
  exists to read it — AGENTS.md "`--notes-context-live` is the read-only diagnostic…");
- save, repair or re-run anything from the report;
- commit a fixture made from a real voice or a real meeting.

**Red-first self-test:** `--selftest-meeting-quality`, in `MeetingQualityProbe.runSelfTest()`.
Cases (all in memory, no store):
- a. I2's four samples ("So if you don't have to pass it, you can be very and I use it to be two
  AC sounds like", "Uh it's a good time as a parking lot of it.", "Like on that on that C the power
  of the one parentheses the most the poem and a one DP.", "Bueno, it would be this way.") →
  `.english`.
- b. "Donc on garde le budget à quarante mille pour le moment.", "Oui c'est ça, je t'envoie le devis
  demain.", "Il faut que Marc valide avec la banque.", "Non mais attends, ce n'est pas le même prix."
  → `.french`. "OK." and "Merci." → `.unknown`.
- c. A 20-segment French transcript with 3 English-guessed lines and 2 unknown lines →
  `dominantLanguage == .french`, `guessedSegments == 18`, `wrongLanguageSegments == 3`,
  `wrongLanguageShare == 3/18`.
- d. 10 system segments, 3 with `speaker == nil`, 7 split between "Speaker 1" and "Speaker 2",
  `speakerNames = ["Speaker 1": "Papa", "Speaker 2": "Papa"]` → `unattributedSystemShare == 0.3`,
  `speakerLabels == 2`, `distinctNames == 1`, `overSplit == true`; the same with no speakers at all
  → `unattributedSystemShare == nil`.
- e. Segment lengths 0.5, 0.9, 1.0, 3.0 s → `shortSegmentShare == 0.5`, `maxSegmentSeconds == 3.0`.
- Extend `--selftest-metrics` (`LatencyTrace.runSelfTest`): each of the five new ids round-trips
  through the isolated store with `pipeline == .meeting`.

Confirm RED: land the types with `guess` returning `.unknown` and `measure` returning zeros;
cases a–e must fail (`MEETING_QUALITY_FAILED`).

**Verify:**
```bash
Tests/Fixtures/meetings/generate.sh && afinfo Tests/Fixtures/meetings/fr-dialogue.wav | head -5
make build && make install OPEN=0
mkdir -p ~/Library/Caches/NextNotesBuild/dictation-meetings
Scripts/run-selftest.sh --selftest-meeting-quality 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/M-16a-green.txt
Scripts/run-selftest.sh --selftest-metrics
Scripts/run-selftest.sh --meeting-quality-report
Scripts/run-selftest.sh --selftest-stream           # regression: window config untouched
Scripts/run-selftest.sh --selftest-meeting-live     # regression (CORE)
```

**Success threshold:** `MEETING_QUALITY_OK` (red first); `METRICS_OK`; the report prints one row
per `done` meeting (6 on this Mac as of 09-24) and `MEETING_QUALITY_REPORT_DONE`; `STREAM_OK` and
`MEETING_LIVE_OK` unchanged from their last result.

**Risks & rollback:** Five more span rows per meeting; the `MetricsStore` ring bounds the file.
A wrong word list only mislabels the probe's own numbers; it changes no product behaviour. Revert
the commit to roll back; old `metrics.jsonl` rows are unaffected.

**Done when:**
- [ ] Fixtures generated, committed, README section added.
- [ ] `MEETING_QUALITY_OK` (red first) and `METRICS_OK`.
- [ ] The five spans are written by production code (grep `LatencyTrace.record(.meeting` shows
      drain, diarize, notes, windows_dropped; final_pass arrives with M-01).
- [ ] Baseline rows pasted into `STATUS.md`.
- [ ] AGENTS.md flag list and `acceptance.sh` updated.
- [ ] Committed as `M-16a: …`.

---

### M-02 — Resolve audio helper processes to their owning app before any call policy; migrate helper-keyed answers; deny `replayd`

**Finding(s):** I2 #2, #24  **Effort:** 1 d  **Depends on:** none  **Unblocks:** M-06 (titles), M-11

**Why (what the user experiences today):** On this Mac `callAppsSeen` holds
`com.google.Chrome.helper = "Google Chrome Helper"`, and meeting 1B6B was armed as
`com.google.Chrome.helper@1789326398` with the title "Google Chrome Helper call". The browser
rule in `CallPolicy.askOnlyBundleIDs` names `com.google.Chrome`, so it never matches: Settings
offers "Always record" for "Google Chrome Helper", and with `callDetectionAutoRecord` on (it is on
here) a browser call records without asking. This Mac is safe only because the owner answered
"ask" by hand. The same gap armed "…is on a call. Record it?" for `com.apple.replayd` (screen
recording), `Codex (Service)` and `Cursor Helper`.

**Files you will change:**
- new `Meetings/AudioProcessOwner.swift`: owner resolution (pure core + live lookup) and the
  answer migration.
- `Meetings/CallPolicy.swift`: `AudioProcess` (`:13-20`) gains `reportedBundleID: String?`;
  `deniedBundleIDs` (`:48-59`) gains `"com.apple.replayd"`; `askOnlyBundleIDs` (`:324-330`) gains
  the WebKit process ids (step 5).
- `Meetings/CallDetector.swift`: `audioProcesses()` (`:120-136`) resolves the owner;
  `displayName(pid:bundleID:)` (`:416-436`) takes the owner's name.
- `Support/Settings.swift`: a one-shot migration call for `callAppAnswers` / `callAppsSeen`
  (`:515-528`) guarded by a new key `callAnswersOwnerMigrationV1`.
- `NextNotesApp.swift`: cases in `callPolicyFailures()` (`:3078`) / `callAppListFailures()`
  (`:3400`), and the live table in `runCallsSelfTest()` (`:2986`) prints the owner.
- `AGENTS.md`: the "Chrome is offered only…" paragraph (`:832`).

**Read for context (do not change):** AGENTS.md `:808-846` ("The microphone flag flickers",
"`corespeechd` holds the microphone…", "Chrome is offered only…"); `MeetingScheduler.answer`
(`Meetings/MeetingScheduler.swift:358`) which reads `settings.callAnswer(forApp:)` with
`call.bundleID`; `CallDetector.identity(of:)` (`:408-411`).

**Current behaviour:**
```swift
// CallDetector.audioProcesses() — :126-131
let bundleID = processBundleID(of: object)          // kAudioProcessPropertyBundleID
return CallPolicy.AudioProcess(pid: pid, bundleID: bundleID,
    name: displayName(pid: pid, bundleID: bundleID), …)
```
`kAudioProcessPropertyBundleID` names the process that holds the audio. For Chromium browsers,
Electron apps and Firefox that is a helper inside the app bundle. Every policy check —
`isCall`, `isMicrophoneApp`, `availableAnswers`, `effectiveAnswer`, `recordsWithoutAsking`,
the stored answer lookup — then runs on the helper id. Stored answers today (`defaults read
ai.pivotstudio.nextnotes callAppAnswers`): `com.apple.replayd = ask`,
`com.google.Chrome.helper = ask`, `com.openai.codex.helper = ask`,
`com.todesktop.230313mzl4w4u92.helper = ask`, `net.whatsapp.WhatsApp = ask`. Also seen:
`com.apple.avconferenced` (FaceTime's daemon) and `com.meta.endo`.

**Target behaviour:**
1. Every `AudioProcess` carries the **owning app's** bundle id in `bundleID`, and the id Core Audio
   reported in `reportedBundleID` when the two differ. The owner is the outermost `.app` bundle on
   the process's executable path (`proc_pidpath`). A process not inside any `.app`
   (`/usr/libexec/avconferenced`) keeps its reported id.
2. All policy, the stored answers, `callAppsSeen`, event identity and the title use the owner:
   a Chrome tab call is "Google Chrome call", offered only Ask/Never, never recorded unasked.
3. `com.apple.replayd` is never a call and never an app-list row.
4. Existing helper-keyed answers are moved to the owner once, keeping the more cautious answer on
   a collision, and a browser owner's `always` is clamped to `ask`.
5. A WebKit engine process (`com.apple.WebKit.GPU`, `com.apple.WebKit.WebContent`) is ask-only:
   it could be Safari or any app embedding a web view, the same ambiguity AGENTS.md accepts for
   browsers. (Not measured on this Mac; the path rule cannot map it because WebKit's XPC services
   live in `/System/Library/Frameworks/WebKit.framework`, outside `Safari.app`.)

**Steps:**
1. `AudioProcessOwner.swift`:
   ```swift
   enum AudioProcessOwner {
       /// Outermost path component ending in ".app", scanning from the root.
       /// "/Applications/Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
       ///   → "/Applications/Google Chrome.app". "/usr/libexec/avconferenced" → nil.
       static func outermostAppPath(executablePath: String) -> String?

       /// Pure: `bundleIDAt` is `{ Bundle(path: $0)?.bundleIdentifier }` in production.
       static func owner(reportedBundleID: String?, executablePath: String?,
                         bundleIDAt: (String) -> String?) -> String?

       /// Live: proc_pidpath + Bundle(path:). Cached per (pid, reportedBundleID) in a
       /// @MainActor dictionary cleared of pids no longer in the process list.
       @MainActor static func resolve(pid: pid_t, reportedBundleID: String?) -> (bundleID: String?, appPath: String?)

       /// Pure migration over the two dictionaries. `installedApp` is
       /// `{ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }` in production.
       static func migrate(answers: [String: String], seen: [String: String],
                           installedApp: (String) -> Bool) -> (answers: [String: String], seen: [String: String])
   }
   ```
   `owner`: if `executablePath` yields an outer `.app` whose `bundleIDAt` is non-nil, return it;
   else return `reportedBundleID`. Never return a *different* id without a path proving it.
2. `migrate`: for each key ending in `.helper` or containing `.helper.` (e.g.
   `com.google.Chrome.helper.renderer`), the candidate owner is the key up to `.helper`. Move the
   row only when `installedApp(candidate)` is true; otherwise leave it (never invent an id).
   Collision → keep the more cautious of the two (`never` > `ask` > `always`). Then any owner in
   `askOnlyBundleIDs` with `always` becomes `ask`. Drop every row for an id in `deniedBundleIDs`.
   For `seen`, rename the key and set the name to the old name with a trailing " Helper" and any
   " (Renderer)"/" (GPU)" suffix removed. Idempotent: running it twice changes nothing.
3. `CallDetector.audioProcesses()`: after `processBundleID(of:)`, call `AudioProcessOwner.resolve`,
   build `AudioProcess(pid:, bundleID: owner, reportedBundleID: owner == reported ? nil : reported, …)`.
   `displayName(pid:bundleID:)`: when an app path was resolved, prefer
   `FileManager.default.displayName(atPath: appPath)` stripped of ".app", then the existing
   `NSRunningApplication` / `proc_name` chain. Keep the bidi-mark trimming.
4. `Settings`: on first launch after this change (key `callAnswersOwnerMigrationV1` absent), run
   `migrate` on `callAppAnswers` / `callAppsSeen`, write both back, set the key, and log one
   `Log.calls.info` line listing moved keys (bundle ids are not personal data). Under
   `SelfTest.isRunning` do **not** run it (the harness must not touch the user's defaults); the
   self-test calls the pure `migrate` directly.
5. `CallPolicy`: add `"com.apple.replayd"` to `deniedBundleIDs` with a comment "measured
   2026-09-23: screen recording armed a call question"; add `"com.apple.WebKit.GPU"` and
   `"com.apple.WebKit.WebContent"` to `askOnlyBundleIDs` with the comment from Target 5. Keep the
   Meet web app id out of both.
6. `runCallsSelfTest()`: print `reported → owner` for every live process whose ids differ.
7. AGENTS.md: amend the "Chrome is offered only…" paragraph with two sentences: Core Audio names
   the helper, so every process is resolved to its outermost `.app` before any rule runs, and
   helper-keyed answers were migrated once (`callAnswersOwnerMigrationV1`). Add `replayd` to the
   denylist sentence as measured.

**Do not:**
- turn the denylist into an allowlist, or deny Cursor, Codex, Fathom or any app because it is
  not a "real" conferencing app (AGENTS.md: a conferencing app nobody has heard of must work on
  day one);
- use `responsibility_get_pid_responsible_for_pid` or any other private SPI;
- map a helper to an id that no path or installed app proves (a guessed id is an answer stored
  against nothing);
- offer "Always record" for any browser or WebKit owner, or let a stored `always` survive for one;
- run the migration or write `callAppAnswers` from a self-test.

**Red-first self-test:** extend `--selftest-calls` (marker `CALLS_OK` / `CALLS_FAILED`), in a new
`private static func callOwnerFailures() -> [String]` appended to the existing failure lists:
- a. `outermostAppPath` table: Chrome helper path → `/Applications/Google Chrome.app`; Chrome
  "Helper (Renderer)" path → same; `/Applications/Cursor.app/Contents/Frameworks/Cursor
  Helper.app/Contents/MacOS/Cursor Helper` → `/Applications/Cursor.app`;
  `/Applications/Firefox.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container`
  → `/Applications/Firefox.app`; `/usr/libexec/avconferenced` → nil;
  `~/Applications/Chrome Apps.localized/Google Meet.app/Contents/MacOS/app_mode_loader` → that
  `Google Meet.app`.
- b. `owner(…)` with a fake `bundleIDAt` map: Chrome helper → `com.google.Chrome`; Cursor helper →
  `com.todesktop.230313mzl4w4u92`; avconferenced → `com.apple.avconferenced`; the Meet shim
  reported as `com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan` → unchanged; nil path →
  reported id unchanged. Target: **8/8 table cases map as expected (100 %).**
- c. After resolution, `availableAnswers(forApp: owner)` for the Chrome helper process lacks
  `.always`, and `recordsWithoutAsking(bundleID: owner, autoRecord: true, answer: nil)` is false.
- d. `isCall` / `isMicrophoneApp` are false for a `com.apple.replayd` process holding both flags.
- e. `migrate` on this Mac's real dictionaries (copied as literals into the test):
  `com.google.Chrome.helper=ask` → `com.google.Chrome=ask`; `com.apple.replayd` removed;
  `com.openai.codex.helper` kept unless `installedApp("com.openai.codex")`; a collision
  `always`+`never` → `never`; a helper `always` for Chrome → `ask`; second run is a no-op.
- f. `recordsWithoutAsking(bundleID: "com.apple.WebKit.GPU", autoRecord: true, answer: .always)`
  is false.

Confirm RED: add `AudioProcessOwner` with `owner` returning `reportedBundleID` and `migrate`
returning its input; cases b, c, d, e, f fail.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-calls 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/M-02-green.txt
Scripts/run-selftest.sh --selftest-calendar          # regression: arming rules
Scripts/run-selftest.sh --selftest-ui-strings        # titles and settings rows
```
Owner smoke (not required for green): with Chrome open on a page that uses the microphone,
`Scripts/run-selftest.sh --selftest-calls` lists `com.google.Chrome.helper → com.google.Chrome`,
and Settings ▸ Meetings shows "Google Chrome" with Ask first / Never only.

**Success threshold:** `CALLS_OK` with all six new cases (red first); 8/8 owner-table cases;
`CALENDAR_OK` and `UI_STRINGS_OK` unchanged.

**Risks & rollback:** A wrong outer-bundle rule could merge two unrelated apps' answers: the rule
only moves an id when a path or an installed app proves it, and the log line lists every moved
key. `proc_pidpath` on a pid that has exited returns 0 → the reported id is kept. To roll back,
revert the commit; the migrated `callAppAnswers` stay valid (they are keyed by real app ids),
and the owner can clear them in Settings.

**Done when:**
- [ ] Owner resolution in `audioProcesses()`; titles read "Google Chrome call".
- [ ] `replayd` denied; WebKit ids ask-only.
- [ ] Migration pure + one-shot, never under the harness.
- [ ] `CALLS_OK` (red first), regressions unchanged.
- [ ] AGENTS.md paragraph updated.
- [ ] Committed as `M-02: …`.

---

### M-06 — The detected-call question stays on the island for the life of the call

**Finding(s):** I2 #6 (sibling of H3 #5)  **Effort:** 0.5–1 d  **Depends on:** M-02 (the pill's title uses the owner name; not a hard blocker)  **Unblocks:** none

**Why (what the user experiences today):** A detected call is armed with
`start = call.since`, which is already in the past, so `announceArmed` shows the "Record this
call?" card for `max(8 s, negative)` = 8 s. `callDetectionAutoRecord` defaults to **false**
(`Support/Settings.swift:1052`), so on a fresh install every ad-hoc call depends on that card.
After 8 s the only other place to answer is the notification banner, which macOS also dismisses.
If nobody answers, `MeetingScheduler.retire` deletes the armed meeting when the call ends and the
call is never recorded; a late answer loses the minutes before it.

**Files you will change:**
- `UI/Island/IslandState.swift`: `Kind` (`:77`) gains `callQuestion(MeetingEvent)`;
  `announceArmed(_:)` (`:329-333`), `clearArmed(_:)` (`:336`), `clearArmed(meetingID:)` (`:348`),
  `liveKind()` (`:496`), `handle(_:)` (`:627`), `demandsAttention` (`:154`), identity/title/orb
  switches (`:137`, `:187`, `:258`); an internal `expireNotice()` used by the countdown and the test.
- `UI/Island/IslandView.swift`: the collapsed glyph switch (`:211`) and the expanded card for the
  new kind (reuse the armed card's buttons).
- `NextNotesApp.swift`: `islandStateFailures()` (`:3588`).

**Read for context (do not change):** `MeetingScheduler.arm(…)` (`Meetings/MeetingScheduler.swift:465`,
the `announceArmed` call at `:498`), `retire(_:)` (`:417-440`), `raise(…)` (`:389`);
`CallDetector.event(for:)` (`Meetings/CallDetector.swift:383-399`); AGENTS.md "The island panel
is always the size of its expanded card" and the orb table (`breathing` = waiting on purpose).

**Current behaviour:**
```swift
// IslandState.announceArmed(_:) — :329-333
push(.meetingArmed(event), for: max(DS.Motion.islandNotice, event.start.timeIntervalSinceNow))
```
`notice` is a single slot; any later notice (notes ready, an agent reply) replaces the armed
card, and when that notice expires nothing brings the question back.

**Target behaviour:**
1. For `event.providerID == .detectedCall`, the island remembers the event in a persistent
   `armedCall` slot until the question is answered (Record now / Skip, from the island or the
   notification) or `retire` clears it.
2. The first 8 s are unchanged: the expanded `meetingArmed` notice. After it expires — or is
   replaced by another notice that then expires — `liveKind()` returns `.callQuestion(event)`, a
   collapsed pill (`demandsAttention == false`) that expands on hover to the same Record now / Skip
   card.
3. Priority in `liveKind()`: agent working/listening and dictation stay above it; it sits above
   the meeting-recording readout (there is no recording while it is armed) and above idle.
4. Calendar meetings are unchanged (their card already lives until the start time).
5. Consent is unchanged: nothing records before an answer.

**Steps:**
1. Add `private(set) var armedCall: MeetingEvent?`. In `announceArmed`, set it when
   `event.providerID == .detectedCall`, then push the notice as today.
2. `clearArmed(_:)`, `clearArmed(meetingID:)` and the notification `handle` branch also clear
   `armedCall` when it matches (by `event.id`, or through `MeetingScheduler.shared.meeting(for:)`
   for the id form, as the notice path already does), then `refresh()`.
3. `liveKind()`: after the agent and dictation branches, `if let armedCall { return .callQuestion(armedCall) }`.
4. `Kind.callQuestion`: identity `"call-question:\(event.id)"`, orb `.breathing` (AGENTS.md: an
   armed meeting awaiting an answer), title `event.title`, `demandsAttention == false`. The
   collapsed view shows the `calendar.badge.clock` glyph like `meetingArmed`; the expanded view
   reuses the `meetingArmed` card body. No red anywhere (not recording).
5. Factor the countdown's final `self.clearNotice()` into `func expireNotice()` (internal) so the
   self-test can expire the notice without waiting 8 s.

**Do not:**
- record, or start capture, before an answer;
- make the pill red or use the recording indicator;
- resize the island panel (AGENTS.md: the panel is always the size of its expanded card; collapse
  and expand happen inside the SwiftUI view);
- use a literal duration or size in the view — use `DS` tokens;
- change the calendar-meeting path or `DS.Motion.islandNotice`.

**Red-first self-test:** extend `--selftest-island` (`ISLAND_OK` / `ISLAND_FAILED`), in
`islandStateFailures()`:
- a. A `.detectedCall` event with `start = now − 30 s`: `announceArmed` → `kind == .meetingArmed`,
  expanded. `expireNotice()` → `kind == .callQuestion(event)`, `isExpanded == false`;
  `isHovered = true` → `isExpanded == true`.
- b. With the pill showing, `announceNotesReady(meeting)` → the notes card shows;
  `dismissNotice()` → back to `.callQuestion(event)`.
- c. `clearArmed(event)` → `.hidden`, `armedCall == nil`.
- d. A calendar (`.fake`) event after `expireNotice()` → `.hidden` (no pill for calendar events).

Confirm RED: add the `callQuestion` case and `expireNotice()` only; case a fails at
"`kind == .callQuestion`" (today it is `.hidden`).

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-island 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/M-06-green.txt
Scripts/run-selftest.sh --selftest-orb
Scripts/run-selftest.sh --selftest-calls
Scripts/run-selftest.sh --selftest-ui-strings
```

**Success threshold:** `ISLAND_OK` with cases a–d (red first); `ORB_OK`, `CALLS_OK`,
`UI_STRINGS_OK` unchanged. Owner smoke when a call happens: the pill is still under the notch
60 s into an unanswered call and disappears when the call ends.

**Risks & rollback:** A pill that outlives its call would be a lie; `retire` already runs on the
call's end and now also clears `armedCall`, which case c pins. Revert to roll back.

**Done when:**
- [ ] `armedCall` slot, `callQuestion` kind, view branches with `DS` tokens.
- [ ] `ISLAND_OK` (red first), regressions unchanged.
- [ ] Committed as `M-06: …`.

---

### M-05 — Map-reduce never drops facts: per-chunk fact budget, a collapse pass, and a visible count

**Finding(s):** I2 #5 (and the chunk-size half of #15, which M-12 finishes)  **Effort:** 1 d  **Depends on:** M-16a (the `meeting.notes` span note)  **Unblocks:** M-12, M-13

**Why (what the user experiences today):** When the facts from the map step do not fit the
window, `NotesGenerator.mapReduce` deletes the **oldest** ones until they do, and says nothing.
The comment's reason ("the end of a meeting is where its decisions are") is an assumption. Since
P0-01, meeting notes run on Apple FM. With the window the app assumes today (4,096 − 1,536 =
2,560 transcript tokens), a 2,000-token chunk is 8–11 minutes of this Mac's speech (700–970
characters/min, I2) and each chunk may produce 600 fact tokens, so with a full brief (≈ 700
tokens) only 3–6 chunks of facts fit: a meeting longer than ≈ 35–55 min (estimate) loses its
agenda, first decisions and owners. After P1-10a reads the real window (8,192, measured by G), the
edge moves to ≈ 90 min (estimate); the silent loss remains.

**Files you will change:**
- `Meetings/NotesGenerator.swift`: `Result` (`:22-32`) gains `chunks`, `collapsedGroups`,
  `droppedFacts`; `mapReduce(…)` (`:112-194`) gets the fact budget and the collapse loop; a new
  `static let collapseMaxRounds = 3`.
- `Meetings/NotesPrompts.swift`: `collapseSystem`, `collapseUser(meeting:facts:)`, and an optional
  length sentence in `mapUser` (`:109`).
- `Meetings/NotesService.swift` `generate(…)` (`:43`): log and span note carry the counts.
- new `Meetings/NotesLongformSelfTest.swift`: the fake provider and `--selftest-notes-longform`.
- `NextNotesApp.swift` (register), `AGENTS.md` (flag list, and one sentence in "The Related-context
  brief…" paragraph is **not** needed — the brief rules are unchanged), `Scripts/acceptance.sh`.

**Read for context (do not change):** `NotesGenerator.notes(…)` (`:57-110`: the brief is counted
before the single-pass decision); `NotesGenerator.chunk(…)` (`:237-266`); `NotesFormatter.tidy`,
`emptySection`; `RecordingNotesProvider` in `Meetings/MeetingNotesContextSelfTest.swift:390` (the
shape to copy for a fake provider); AGENTS.md "The Related-context brief is deliberately absent
from three places" (the map step never sees the brief — keep it that way).

**Current behaviour:**
```swift
// NotesGenerator.mapReduce — :172-178
// The facts can themselves outgrow the window on a very long meeting. Trimming the
// oldest is the least-bad answer: the end of a meeting is where its decisions are.
var joined = facts.joined(separator: "\n")
while try await provider.countTokens(joined) + briefTokens > budget, facts.count > 1 {
    facts.removeFirst()
    joined = facts.joined(separator: "\n")
}
```
Every map call asks for `maxTokens: Self.maxFactTokens` (600) regardless of how many chunks share
the reduce window.

**Target behaviour:**
1. Map calls ask for `factBudget = max(150, min(600, (budget − briefTokens) / chunks.count))`
   tokens, and `mapUser` says "Keep this list under about <factBudget × 3 / 4> words."
2. If the joined facts still exceed `budget − briefTokens`, a **collapse pass** merges adjacent fact
   lists into shorter ones with the model, keeping every decision, owner, date, number and open
   question, and repeats until they fit or `collapseMaxRounds` (3) is reached.
3. Only if three rounds do not fit does anything get left out; then the oldest facts are trimmed
   *and* the notes end with a visible line — "_Part of this meeting could not be included in these
   notes (N of M parts left out)._" — and `Result.droppedFacts == N`. Nothing is ever dropped
   without that line.
4. `Result.chunks`, `.collapsedGroups`, `.droppedFacts` reach the log line
   ("notes map-reduce · chunks N · collapsed K · dropped D") and the `meeting.notes` span note.
5. The single-pass path, the brief handling and `emptySection` are unchanged.

**Steps:**
1. In `mapReduce`, after `chunks` is known:
   `let factBudget = max(150, min(Self.maxFactTokens, (budget - briefTokens) / max(1, chunks.count)))`;
   pass it as `maxTokens` and into `NotesPrompts.mapUser(…, wordLimit: factBudget * 3 / 4)`.
2. `NotesPrompts.collapseSystem`:
   ```
   You shorten a list of facts from a meeting so it takes less space.
   Rules:
   - Output a flat list of `-` bullets and nothing else.
   - Keep every decision, commitment, owner, date, number, name and unanswered question.
   - Keep the speaker label at the start of each bullet.
   - Merge bullets that say the same thing. Remove repetition and small talk only.
   - Keep the order. Never add anything that is not in the list.
   ```
   `collapseUser(meeting:facts:)` = the shared header + "Shorten these facts:\n\n<facts>".
3. Collapse loop (replace the `removeFirst` loop):
   ```swift
   var round = 0
   while try await provider.countTokens(joined) + briefTokens > budget, round < Self.collapseMaxRounds {
       round += 1
       // Group adjacent fact lists so each group's prompt fits: target = min(chunkTokens, budget / 2).
       let groups = try await Self.group(facts, targetTokens: min(chunkTokens, budget / 2), count: provider.countTokens)
       var next: [String] = []
       for group in groups {
           if group.count == 1, round > 1 { next.append(group[0]); continue }   // nothing to merge
           let text = group.joined(separator: "\n")
           let groupTokens = try await provider.countTokens(text)
           let completion = try await provider.complete(system: NotesPrompts.collapseSystem,
               user: NotesPrompts.collapseUser(meeting: meeting, facts: text),
               maxTokens: max(150, groupTokens / 2))
           generated += completion.generatedTokens
           let cleaned = NotesFormatter.stripThinking(completion.text).trimmingCharacters(in: .whitespacesAndNewlines)
           next.append(cleaned.isEmpty ? text : cleaned)       // an empty answer never deletes facts
           collapsedGroups += 1
       }
       facts = next
       joined = facts.joined(separator: "\n")
   }
   var dropped = 0
   let totalParts = facts.count
   while try await provider.countTokens(joined) + briefTokens > budget, facts.count > 1 {
       facts.removeFirst(); dropped += 1
       joined = facts.joined(separator: "\n")
   }
   ```
   After the reduce, if `dropped > 0`, append the visible line from Target 3 to the markdown.
   Report progress "Condensing part k of n…" during collapse (same `Step` shape as the map step).
4. `NotesService.generate`: extend the existing log line and the `meeting.notes` span note with
   `chunks=… collapsed=… dropped=…`.
5. `NotesLongformSelfTest.swift`: a `LongformNotesProvider` (copy `RecordingNotesProvider`'s shape):
   `contextTokens` from its init; `countTokens = characters / 4 + 1`; for `mapSystem` it answers
   `"- Speaker 1: FACT-P<part> " + filler` sized to exactly `maxTokens × 4` characters (the worst
   case: a model that always fills its allowance); for `collapseSystem` it keeps every `FACT-P<n>`
   token and halves the filler; for `reduceSystem` it records the user prompt and returns a complete
   notes document (every heading, as `RecordingNotesProvider` does). A variant
   `stubbornCollapse: true` returns its input unchanged from `collapseSystem`.
   The 90-min fixture transcript is generated in memory: 1,800 segments of 3 s, each line
   "Speaker 1: " + 45 characters of text, with the marker `AGENDA-ITEM-ONE` in the first segment.

**Do not:**
- pass the brief to the map or the collapse step (AGENTS.md: the map step writes only what was
  said; context facts there come back as claims someone made);
- drop anything without the visible line and a non-zero `droppedFacts`;
- change the single-pass decision, `reservedTokens`, `maxNotesTokens` or chunk sizes (M-12 and M-13
  own those);
- write to `MeetingStore` from the self-test (the generator takes segments in memory; no store is
  needed).

**Red-first self-test:** new `--selftest-notes-longform`, in `NotesLongformSelfTest.run()`, marker
`NOTES_LONGFORM_OK` / `NOTES_LONGFORM_FAILED: <reason>`. No model, no store.
- a. Provider `contextTokens: 4_096`, the 90-min transcript, a brief of ≈ 2,800 characters: the
  reduce prompt contains `FACT-P1` **and** `AGENDA-ITEM-ONE`'s part marker, every `FACT-P<n>` for
  n in 1…chunks, `result.droppedFacts == 0`, `result.collapsedGroups ≥ 1`, and the markdown does
  not contain "could not be included".
- b. Same with `contextTokens: 8_192`: `droppedFacts == 0`.
- c. `stubbornCollapse: true`, 4,096: `droppedFacts > 0` **and** the markdown ends with the visible
  line naming the count; `collapsedGroups ≥ 1` (it tried).
- d. A 10-min transcript on 4,096 still takes the single-pass path (`usedMapReduce == false`) and
  the brief rules hold (`emptySection` applied when the brief is empty).
Confirm RED on the unmodified generator: case a fails with "FACT-P1 missing from the reduce
prompt" (the old loop removed it).

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-notes-longform 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/M-05-green.txt
Scripts/run-selftest.sh --selftest-notes-context     # brief rules unchanged
Scripts/run-selftest.sh --selftest-notes "$PWD/Tests/Fixtures/meeting-2min.wav"   # real provider (Apple FM here); _FAILED only if it was green in the baseline
Scripts/run-selftest.sh --selftest-metrics
```

**Success threshold:** `NOTES_LONGFORM_OK` with a–d (red first): **0 dropped facts** on the 90-min
4,096-token case; `NOTES_CONTEXT_OK` unchanged; `--selftest-notes` ends as in its last recorded run.

**Risks & rollback:** Each collapse round is one more model call per group (on Apple FM, seconds
each; estimate ≤ 1 min extra for a 90-min meeting). A model that ignores the collapse instruction
hits the three-round cap and the visible line, which is honest. Revert to roll back.

**Done when:**
- [ ] Fact budget per chunk; collapse loop; visible line on the last-resort path.
- [ ] Counts in the log line and the `meeting.notes` span note.
- [ ] `NOTES_LONGFORM_OK` (red first); regressions unchanged.
- [ ] Flag registered, in AGENTS.md and `acceptance.sh` (INTEGRATION, `"selftest-notes-longform|300"`).
- [ ] Committed as `M-05: …`.

---

### M-01 — Long-window finals: keep the 2–5 s windows for the live view, re-transcribe each track in long windows after Stop

**Finding(s):** I2 #1 (and #4's root cause, #16's input)  **Effort:** 2–3 d  **Depends on:** M-16a (probe, fixtures, `meeting.final_pass` span)  **Unblocks:** M-03, M-04 (shorter-segment problem shrinks), M-08 (must resume this pass), M-10

**Why (what the user experiences today):** Since 2026-09-13 every meeting's *final* transcript
comes from 2–5 s Parakeet windows, each decoded with a fresh `TdtDecoderState`. On French calls
the multilingual model (`parakeet-tdt-0.6b-v3`, auto language) turns short stretches of French
into English-sounding text: 6 % of segments read as English in the last meeting before the change
(25 s windows), 16 % and 24 % in the two after it. From the 09-19 call: "Uh it's a good time as a
parking lot of it.", "Bueno, it would be this way." That text became a live-context topic
("Parking lot"), and the notes for that 25-minute business call left Decisions and Open questions
empty. Short windows also hard-cut words ("…donc les 5 mi") and leave 23–33 % of segments under
1 s, which is what M-04's unlabelled lines are made of.

**Where the short windows came from, and what they were for.** Commit `a276c5a` (2026-09-13,
"Enhance self-testing capabilities and agent functionality") implemented
`roadmap/done/Next_Notes_v3_Roadmap.md` §11 "Meeting Transcription Must Become More Realtime",
whose trigger was user feedback that the transcript "is appearing, but not quickly enough to feel
realtime", and whose plan says "Final transcript correctness can improve asynchronously." The
commit moved `ChunkedTranscriber`'s window from 30–60 s to `StreamingASR.meetingProvisionalMinSeconds
= 2` / `meetingProvisionalMaxSeconds = 5` for **both** the provisional events and the finals, and
left the finals half of the plan ("stabilize") unbuilt: `StreamingASR.meetingOverlapSeconds` is
"Reserved for overlapping ASR" and 0. So the latency goal is legitimate and stays; what was never
built is the asynchronous correction. Two more facts from the FluidAudio checkout
(`~/Library/Caches/NextNotesBuild/scratch/checkouts/FluidAudio`):
- `AsrManager.transcribeWithState` pads every input up to `ASRConstants.maxModelSamples` = 240,000
  samples (15 s) before the encoder runs, so a 2–5 s window costs a full 15 s encoder pass
  (estimate: 3–7× the encoder work per second of speech of a 15 s window). Longer windows are
  cheaper per second, not dearer. Input over 15 s goes through `ChunkProcessor` (overlapping
  stateless chunks).
- The `language:` parameter is a **script** filter (Latin / Cyrillic / Greek,
  `Shared/TokenLanguageFilter.swift`). French and English are both Latin, so language-pinned
  decoding is not available for this problem.

**The design and its trade-off.** Two tiers.
- *Live tier (unchanged):* 2–5 s windows produce the provisional text and the in-meeting finals
  that the Transcript tab, `MeetingContextStore`, the wake word handler and the live agent read.
  `meeting.speech_to_partial` / `meeting.speech_to_final` stay where they are.
- *Final tier (new):* after Stop, before diarization, `MeetingFinalPass` re-reads each channel of
  `audio.caf` and transcribes it in long windows cut at pauses, runs the same sentence/pause
  segmentation (`ChunkedTranscriber.segments(from:…)`, unchanged), and replaces `transcript.json`.
  The live transcript is kept as `transcript.live.json`.
- *Cost:* the meeting reaches Diarizing/Summarizing later by the pass time. Target ≤ 5 % of the
  meeting's length (estimate; e.g. ≤ 3 min for an hour), measured as `MEETING_FINALS_RTF` on the
  fixtures and as the `meeting.final_pass` span on the owner's next meeting. The in-meeting text
  (and anything the live agent did with it) is not corrected; M-14 reduces how much the live model
  leans on it.
- *Why not a second live cutter (I2's other option):* two segment streams during the meeting would
  have to be reconciled in `MeetingSession.add`, `MeetingContextStore.ingest`,
  `ActivationController.handleWake(in:)` and the `TranscriptBus` replace contract, and would double
  `.realtimeASR` contention with dictation (D-14) while the meeting runs. Keep it as the fallback
  only if the RTF target fails; record that decision in `STATUS.md` if it happens.
- *Audio is required:* the pass reads `audio.caf`. Today the file exists only when keep-audio or
  diarization is on. This task records a temporary file whenever the final pass is on, which
  changes a documented rule (below).

AGENTS.md paragraphs this task changes, with the evidence that overrides them:
> "**A transcript segment is a sentence, not a window, and punctuation is what makes it one.**
> `ChunkedTranscriber` cuts 30–60 second windows because that is what Parakeet is cheap to run on…"
(`AGENTS.md:686-687`). Stale since `a276c5a`: the windows are 2–5 s. The segmentation rule in the
rest of that paragraph stays exactly as it is and now runs in both tiers.
> "**A meeting records audio even when "Keep the recorded audio" is off.** Diarization reads the
> system channel of `audio.caf`, so turning "Tell the other speakers apart" on makes every meeting
> write the file…" (`AGENTS.md:673-684`). Now the final pass also reads it, so the file is written
> when either consumer is on. The three-line `releaseAudio` rule is unchanged: a recording made only
> for a pipeline stage is `audioIsTemporary` and goes at the end of the pipeline.

**Files you will change:**
- `Transcription/StreamingASR.swift`: `meetingFinalMinSeconds`, `meetingFinalMaxSeconds` (values
  chosen in step 1); `runSelfTest()` (`:40-90`) checks them.
- `Meetings/ChunkedTranscriber.swift`: `WindowConfig.finals` (next to `.default`, `:45-50`);
  `segments(from:text:start:duration:source:)` (`:311`) becomes `static` internal (not private) so
  the final pass reuses it; `TranscriptionQueue.transcribe(_:)` (`:396`) gains
  `lane: WorkClass = .realtimeASR` and uses `acquireCancellable` for non-realtime lanes; the class
  doc comment (`:4-21`).
- new `Meetings/MeetingFinalPass.swift`: the cutter over a whole track, `merge`, `accept`.
- new `Meetings/FinalTranscriptService.swift`: `@MainActor` service owning the pass per meeting
  (shape of `DiarizationService`: `tasks`, `problems`, `process(_:)`, `cancel(_:)`).
- `Meetings/MeetingPipeline.swift`: `afterTranscribing` (`:22-36`) hands off to the service when
  the pass applies; new `afterFinalPass(_:store:)` holds today's body.
- `Meetings/MeetingSession.swift`: the audio condition in `start` (`:90`).
- `Meetings/MeetingStore.swift`: `liveTranscriptFile = "transcript.live.json"`,
  `saveLiveTranscript` / `liveTranscript(for:)`; the folder doc comment (`:5-15`).
- `Meetings/MeetingModels.swift`: `Meeting.transcriptPass: String?` — **in the hand-written
  `init(from:)` as `decodeIfPresent`** next to `audioIsTemporary` (`:330`), plus the memberwise
  init and `CodingKeys`. Values: `"long-window"`, `"live-only:no-audio"`, `"live-only:rejected"`,
  `"live-only:failed"`.
- `Support/Settings.swift`: `meetingsFinalPass: Bool`, default **true**, key `"meetingsFinalPass"`.
- `UI/Settings/MeetingsSettingsTab.swift`: one toggle, "Re-check the transcript after the meeting",
  footnote "Listens to the recording again once the meeting ends, which fixes words the live
  transcript got wrong. Keeps a temporary recording until the notes are written."
- `Meetings/MeetingDiarizer.swift`: the stale `assign` doc comment (`:175-180`, "cuts windows of
  thirty to sixty seconds").
- `Meetings/MeetingQualityProbe.swift` (M-16a): the report also measures `transcript.live.json`
  when present and prints `live-wrong=<pct>%`.
- new `Meetings/MeetingFinalsSelfTest.swift`; `NextNotesApp.swift` (register); `AGENTS.md`;
  `README.md` (the meetings pipeline description, if it names window sizes); `Scripts/acceptance.sh`.

**Read for context (do not change):** `ChunkedTranscriber.nextCut()` (`:166-184`),
`transcribe(window:…)` (`:245-310`), `buildWordTimings` use in `segments(from:…)`;
`DiarizationService.diarize` (`AudioConversion.samples(fromFileAt:sampleRate:channel:)` and
`MeetingAudioWriter.micChannel = 0` / `systemChannel = 1`); `MeetingStore.releaseAudio` (`:312`);
`ActivationController.handleWake(in:)` (why `.agentCommand` segments must survive);
`NextNotesApp.transcribeFile(at:)` (`:2452`, the pattern for driving a transcriber from a file).

**Current behaviour:** `WindowConfig.default` = 2 / 5 s with provisionals; `transcribe(window:…)`
emits the provisional event and then the finals from the **same** window:
```swift
// ChunkedTranscriber.transcribe(window:…) — :299-303
// Finals still respect sentence / pause boundaries for diarization.
for segment in segments(from: result, text: text, start: start, duration: duration, source: source) {
    guard !Task.isCancelled, await shouldContinue() else { return }
    await onSegment(segment)
}
```
`MeetingSession.stop()` saves those segments and calls `MeetingPipeline.afterTranscribing`
directly.

**Target behaviour:**
1. With `meetingsFinalPass` on and `audio.caf` present, a stopped meeting stays `.transcribing`
   while `FinalTranscriptService` runs; then `transcript.json` holds long-window finals,
   `transcript.live.json` holds the live ones, `Meeting.transcriptPass == "long-window"`, and the
   pipeline continues to diarization/notes exactly as today.
2. Final windows are cut at the first ≥ 600 ms pause after `meetingFinalMinSeconds`, hard-cut at
   `meetingFinalMaxSeconds`; the within-window segmentation rule is the unchanged 600 ms / sentence
   ≥ 2 s rule.
3. `.agentCommand` segments from the live transcript are carried over unchanged; final mic
   segments that overlap one in time are dropped (the command was not meeting speech).
4. Safety: if a track's final word count is below 60 % of its live word count, that track keeps
   its live segments (`accept` fails) and `transcriptPass = "live-only:rejected"`. An error keeps
   the live transcript (`"live-only:failed"`) and never blocks the pipeline.
5. No audio → the pass is skipped (`"live-only:no-audio"`) and the pipeline continues.
6. The pass acquires `.background` per window through `acquireCancellable`, so a dictation or a
   live meeting window always goes first.
7. Wrong-language share on `fr-dialogue-phone.wav` ≤ 2 % for the final tier; never above the live
   tier's share on the same audio; `MEETING_FINALS_RTF ≤ 0.05`.

**Steps:**
1. **Measure and choose the final window** (before writing the service). Write the self-test's
   measurement half first (step 7, cases a–c) with a `--finals-window <min>:<max>` modifier, and run
   it for `10:14.5` (every window is one native 15 s encoder pass) and `20:30` (I2's proposal;
   FluidAudio chunks internally). Choose the pair with the lower wrong-language share on
   `fr-dialogue-phone.wav`; on a tie within 1 point, choose `10:14.5` (cheaper, no chunk merge).
   Write both measurements and the choice into `STATUS.md`, then set the constants.
2. `ChunkedTranscriber`: add
   ```swift
   static let finals = WindowConfig(minWindowSeconds: StreamingASR.meetingFinalMinSeconds,
                                    maxWindowSeconds: StreamingASR.meetingFinalMaxSeconds,
                                    overlapSeconds: 0, emitsProvisionals: false)
   ```
   Make `segments(from:…)` `static func` with internal access. Change
   `TranscriptionQueue.transcribe(_ samples: [Float], lane: WorkClass = .realtimeASR)`: for
   `.realtimeASR` keep `acquire`; otherwise `guard let job = await ComputeScheduler.shared.acquireCancellable(lane) else { throw CancellationError() }`
   and release on every exit. The chain (`tail`) is shared, so final-pass windows still never run
   two CoreML passes at once.
3. `MeetingFinalPass`:
   ```swift
   enum MeetingFinalPass {
       struct Outcome: Sendable { var segments: [TranscriptSegment]; var windows: [ClosedRange<TimeInterval>]
                                  var audioSeconds: Double; var elapsed: TimeInterval; var accepted: [AudioSource: Bool] }
       /// Cuts `samples` with the `.finals` rule (same silence frame test as `nextCut`), transcribes
       /// each window through `transcribe`, and segments each result with `ChunkedTranscriber.segments`.
       static func transcribeTrack(_ samples: [Float], source: AudioSource,
           transcribe: @Sendable ([Float]) async throws -> ASRResult) async throws
           -> (segments: [TranscriptSegment], windows: [ClosedRange<TimeInterval>])
       /// Pure. Keeps live `.agentCommand` segments; drops final mic segments overlapping them.
       static func merge(final: [TranscriptSegment], live: [TranscriptSegment]) -> [TranscriptSegment]
       /// Pure. False when the final track has < 60 % of the live track's words.
       static func accept(final: [TranscriptSegment], live: [TranscriptSegment], source: AudioSource) -> Bool
   }
   ```
   Factor the silence test out of `nextCut()` into a `static func cutPoints(in samples: [Float], config: WindowConfig) -> [Int]`
   used by both, so the two tiers cannot drift. Windows shorter than `minTranscribableSamples` are
   skipped exactly as today; windows with no speech frame are skipped (`containsSpeech`).
4. `FinalTranscriptService.process(_ meeting:)`: read both channels with
   `AudioConversion.samples(fromFileAt:sampleRate:channel:)`, run `transcribeTrack` per channel
   (mic first, then system; `lane: .background`), `accept` per track, `merge`, sort by `start`,
   `store.saveLiveTranscript(live)` **then** `store.saveTranscript(final)`, set `transcriptPass`,
   record `LatencyTrace.record(.meetingFinalPass, seconds:, note: "audio=<s>s windows=<n> rtf=<x> accepted=<mic,system>")`,
   log one info line with the same numbers, then `MeetingPipeline.afterFinalPass(meeting, store:)`.
   Guard the meeting still exists before every write (a deleted meeting must stay deleted, as
   `DiarizationService` does). `cancel(_:)` is wired where `DiarizationService.cancel` is (meeting
   deletion).
5. `MeetingPipeline.afterTranscribing`: after the empty-transcript guard, if
   `Settings.shared.meetingsFinalPass && store.audioURL(for: meeting) != nil`, call
   `FinalTranscriptService.shared.process(meeting)` and return the meeting (still `.transcribing`);
   otherwise set `transcriptPass = "live-only:no-audio"` when the setting is on, and fall through to
   `afterFinalPass`, which is today's body (diarize or notes).
6. `MeetingSession.start`: the condition at `:90` becomes
   `Settings.shared.meetingsKeepAudio || Settings.shared.meetingsDiarize || Settings.shared.meetingsFinalPass`;
   `audioIsTemporary = !meetingsKeepAudio` as today. If free disk is under 1 GB
   (`URLResourceKey.volumeAvailableCapacityForImportantUsageKey` on the meetings root) and keep-audio
   is off, do not create the file (M-10 generalises this guard) and log it.
7. Self-test (below). Then the doc and comment fixes: `ChunkedTranscriber` class comment,
   `MeetingDiarizer.assign` comment, AGENTS.md `:686-687` and `:673-684`, `MeetingStore` folder
   comment (`transcript.live.json`; `audio.caf` "when keep-audio, diarization or the final pass is
   on").

**Do not:**
- change `utteranceGap` (0.6 s), `minSentenceSeconds` (2 s) or the punctuation rule (AGENTS.md
  measured it: 3 → 20 segments, 1 → 2 speakers);
- change `WindowConfig.default`, provisional emission, or anything the live path publishes;
- add a `MeetingStatus` case (older builds would drop the meeting); the pass runs in `.transcribing`;
- add `transcriptPass` anywhere but `decodeIfPresent` in `Meeting.init(from:)`;
- run the pass on `.realtimeASR`, or hold one lane ticket across the whole track;
- use FluidAudio's `language:` hint for French (script-level only; it does nothing here);
- delete `transcript.live.json` in `releaseAudio` (it is text, not audio, and it is the evidence);
- write fixtures or meetings into the user's `Meetings/` folder from the self-test.

**Red-first self-test:** new `--selftest-meeting-finals [<fixtures-dir>]` in
`Meetings/MeetingFinalsSelfTest.swift`, marker `MEETING_FINALS_OK` /
`MEETING_FINALS_FAILED: <reason>` / `MEETING_FINALS_ABSENT: <fixtures not found at …|Parakeet not downloaded>`.
Needs Parakeet on disk (`ParakeetModels.isDownloaded`); uses no store (segments in memory).
- a. For each of `fr-dialogue.wav`, `fr-dialogue-phone.wav`, `en-dialogue.wav`: run the live tier
  (a `ChunkedTranscriber(source: .system, config: .default)` fed 1 s at a time, as
  `transcribeFile(at:)` does) and the final tier (`MeetingFinalPass.transcribeTrack` with
  `TranscriptionQueue.shared.transcribe(_:lane: .background)`). Print per file
  `MEETING_FINALS_LANG <file> live=<pct>% final=<pct>%` using `TranscriptLanguageProbe` against the
  file's *expected* language from `manifest.json` (wrong = guessed and not expected).
- b. Every final window except the last is ≥ `meetingFinalMinSeconds` − 0.02 s; print the window
  lengths. (On the unmodified code, where the seam returns the live cut, this fails: windows are
  2–5 s.)
- c. Word recall against the manifest text (lower-cased token multiset overlap): print
  `live=<r> final=<r>`; FAIL if final recall < live recall − 0.02 (the long tier must not lose
  speech).
- d. FAIL if `fr-dialogue-phone` final wrong share > 2 %; FAIL if any file's final wrong share >
  its live wrong share; FAIL if `en-dialogue` final share of French-guessed segments > 2 %.
  Print `MEETING_FINALS_LIVE_TO_FINAL_RATIO=<x>` as a diagnostic (the synthetic voices may not
  reproduce the flip as strongly as a real call; the ratio is evidence, not a gate).
- e. `MEETING_FINALS_RTF=<elapsed / audio seconds>` over the three files; FAIL if > 0.05.
- f. Pure: `merge` keeps a live `.agentCommand` mic segment and drops a final mic segment overlapping
  it; `accept` refuses a final track with half the live words; a no-audio meeting through a pure
  `MeetingPipeline.finalPassDecision(settingOn:hasAudio:)` → `.skip("live-only:no-audio")`.
Confirm RED: land `MeetingFinalPass.transcribeTrack` as a seam that cuts with `.default` and the
rest as stubs; b fails on window length, f fails on `merge`.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-meeting-finals "$PWD/Tests/Fixtures/meetings" 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/M-01-green.txt
Scripts/run-selftest.sh --selftest-stream               # live windows untouched (STREAM_OK)
Scripts/run-selftest.sh --selftest-transcript-bus
Scripts/run-selftest.sh --selftest-meeting-live         # CORE
Scripts/run-selftest.sh --selftest-meeting-reconcile
Scripts/run-selftest.sh --selftest-transcribe "$PWD/Tests/Fixtures/meeting-2min.wav"
Scripts/run-selftest.sh --selftest-notes "$PWD/Tests/Fixtures/meeting-2min.wav" --diarize
Scripts/run-selftest.sh --selftest-contention           # the lane change
Scripts/run-selftest.sh --selftest-scheduler
```
After the owner's next real French call: `Scripts/run-selftest.sh --meeting-quality-report` and
paste its row (now with `live-wrong` and `wrong`) into `STATUS.md`.

**Success threshold:** `MEETING_FINALS_OK` (red first) with `fr-dialogue-phone` final wrong share
≤ 2 %, final ≤ live on every file, final recall ≥ live − 0.02, RTF ≤ 0.05; every regression ends
as in its last recorded run. On the first real French call afterwards, `wrong` ≤ ¼ of `live-wrong`
(recorded; if not met, add a BLOCKED note with both numbers rather than tuning the probe).

**Risks & rollback:** The pass could make a transcript worse on some audio; `accept` and the kept
`transcript.live.json` bound that, and the setting turns it off per machine. More temporary audio
on disk until the pipeline ends (≈ 230 MB/h); the 1 GB guard and M-10's disk rules bound it. The
meeting reaches Done later by the pass time (the span measures it). Roll back by reverting the
commit; meetings written meanwhile keep a `transcriptPass` field older builds ignore, and their
`transcript.json` is a valid transcript either way.

**Done when:**
- [ ] Window choice measured and recorded in `STATUS.md` (both configs' numbers).
- [ ] Final pass runs between Stop and diarization; `transcript.live.json` kept; `transcriptPass`
      decoded with `decodeIfPresent`.
- [ ] `MEETING_FINALS_OK` (red first); regressions unchanged.
- [ ] AGENTS.md `:673-684` and `:686-687` updated (the two paragraphs quoted above), and the
      `MeetingDiarizer.assign` / `ChunkedTranscriber` comments corrected.
- [ ] M-08's resume planner knows that `.transcribing` + audio present = run this pass (note it in
      M-08's row if M-08 is not done yet).
- [ ] Flag in AGENTS.md and `acceptance.sh` (INTEGRATION, `"selftest-meeting-finals|900"`). The
      directory argument is **optional** (`acceptance.sh` leaves argument-requiring flags out of
      every tier, `Scripts/acceptance.sh:53-57`): without it the test reads
      `$NEXTNOTES_FIXTURES/meetings`, and `acceptance.sh` gains one line
      `export NEXTNOTES_FIXTURES="$ROOT/Tests/Fixtures"` next to `ROOT=`. Missing both →
      `MEETING_FINALS_ABSENT`, which the runner counts as SKIP. M-03 and M-04 resolve their
      fixtures the same way (`FixturePaths.meetings(argument:)`, a small helper added here).
- [ ] Committed as `M-01: …`.

---

### M-08 — Resume interrupted meetings at their stage; keep temporary audio until that stage finishes; a stall watchdog on diarization and notes; confirm Quit while recording

**Finding(s):** I2 #8, #9  **Effort:** 2 d  **Depends on:** M-01 (the resume planner must know the final pass; if M-01 is `blocked`, implement without that branch and note it)  **Unblocks:** M-10, M-16c

**Why (what the user experiences today):** `make install` stops a running app with
`pkill -x NextNotes` (`Scripts/install-bundle.sh:11`), a SIGTERM that skips
`applicationWillTerminate`. Agents run it many times a day on this Mac. A meeting recording at that
moment is left `.recording` on disk, and the next launch's `repairInterruptedMeetings` marks it
`.failed("Next Notes quit while this meeting was recording.")` although `transcript.json` is
written after every segment and is intact. A meeting interrupted while diarizing or summarising is
marked `.done` without speakers or notes and its temporary audio is **deleted**, so it can never be
re-diarized. A normal Quit (`endAbruptly`) marks the meeting `.done` with no notes and leaves a
temporary `audio.caf` nothing will ever release. Separately, a diarization or notes pass that hangs
shows "Writing notes…" until the next launch, which then deletes the audio.

**Files you will change:**
- `Meetings/MeetingStore.swift`: an injectable root (`init(root:)`, `:23`, `:57-75`, `:218`,
  `:359` use `Self.root` today); `repairInterruptedMeetings()` (`:92-125`) becomes "plan, then
  resume"; `hadTranscript` / `repairedStatus` (`:127-138`) replaced by the pure
  `resumeAction(for:hasTranscript:hasAudio:)`.
- new `Meetings/MeetingResumer.swift`: executes the plan with injected stage runners.
- new `Meetings/StageWatchdog.swift`: the pure stall rule and the timer.
- `Meetings/MeetingSession.swift` `endAbruptly()` (`:282-300`): leave the meeting resumable.
- `Meetings/DiarizationService.swift` and `Meetings/NotesService.swift`: record progress
  timestamps and accept a watchdog cancel with a plain problem message.
- `NextNotesApp.swift`: the launch call (`:301`) runs the resumer; `applicationShouldTerminate(_:)`
  (new, next to `applicationWillTerminate` at `:5749`); `--selftest-meeting-resume`.
- new `Meetings/MeetingResumeSelfTest.swift`; `AGENTS.md`; `Scripts/acceptance.sh` (CORE).

**Read for context (do not change):** `MeetingPipeline` (whole file; `afterTranscribing`,
`afterDiarizing`, `finish`); `MeetingStore.releaseAudio` (`:312-326`) — its three-line rule is not
changed here, only *when* it is reached; `MeetingController.endForTermination()`
(`Meetings/MeetingController.swift:85-91`); AGENTS.md "A meeting reaches 'Done' minutes after you
press Stop", "A self-test cannot fail by hanging", "Every await in the dictation tail has a
deadline"; `ComputeScheduler.isBusy(_:)` (`Core/Compute/ComputeScheduler.swift:253`).

**Current behaviour:**
```swift
// MeetingStore — :127-138
nonisolated static func hadTranscript(_ status: MeetingStatus) -> Bool {
    status == .diarizing || status == .summarizing || status == .extracting
}
nonisolated static func repairedStatus(_ status: MeetingStatus) -> MeetingStatus {
    guard status.isActive else { return status }
    return hadTranscript(status) ? .done : .failed("Next Notes quit while this meeting was recording.")
}
// repairInterruptedMeetings — :105
if hadTranscript { releaseAudio(for: repaired.id, notesWritten: meeting.status == .extracting) }
```

**Target behaviour:**
1. At launch, every meeting in an active state is resumed at its stage:

   | Status on disk | transcript | audio | Action |
   |---|---|---|---|
   | `.recording` / `.transcribing` | any | yes, final pass on | status `.transcribing`, run the final pass (M-01), then the pipeline |
   | `.recording` / `.transcribing` | non-empty | no (or pass off) | status `.transcribing`, `MeetingPipeline.afterFinalPass` (diarize if possible, then notes) |
   | `.recording` / `.transcribing` | empty | no | `.failed("Next Notes quit before anything was transcribed.")` |
   | `.diarizing` | — | yes | resume diarization, then notes |
   | `.diarizing` | — | no | `afterDiarizing` (notes) |
   | `.summarizing` | — | — | resume notes (`NotesService.summarize(…, announce: true)`) |
   | `.extracting` | — | — | as today: `.done`, queued re-extraction |

   `end` is set to the last segment's end (or now) if missing. Nothing releases audio during repair;
   audio is released by the stage that finishes, through the unchanged `releaseAudio` rule.
2. Resumes run one meeting at a time, after launch settles, waiting while
   `LiveKnowledgeIndexEnvironment.isForegroundBusy || isVoiceBusy` (the same gate the existing
   extraction resume uses, `MeetingStore.swift:115-121`), and never while a new meeting records.
3. `endAbruptly()` saves the transcript and leaves the meeting `.transcribing` (not `.done`), so the
   next launch resumes it.
4. A diarization pass whose progress has not moved for 5 min, or a notes pass whose step has not
   changed for 10 min (both estimates, chosen above the longest single legitimate gap: a
   single-pass generation on the local model), **excluding** time during which
   `ComputeScheduler.isBusy(.realtimeASR) || isBusy(.realtimeAgent)`, is cancelled with the problem
   "This took much longer than it should, so it was stopped. Try again." Audio is kept (diarization
   problems already block `releaseAudio`).
5. ⌘Q / Quit while a meeting is recording shows one alert: "A meeting is being recorded" /
   "Stop the recording and quit? What was said so far is kept." — buttons "Stop and Quit"
   (default) and "Keep Recording". Stop and Quit awaits `MeetingController.shared.stop()` (bounded
   by a 10 s `withBoundedWait`-style latch) and then replies `true`. Never shown under
   `SelfTest.isRunning`. SIGTERM (`pkill`) still cannot be caught and is covered by 1–3.

**Steps:**
1. `MeetingStore`: `init(root: URL = MeetingStore.root)`, store it, replace the three instance uses
   of `Self.root` with it (`KnowledgeIndexer.meetingsRoot` keeps reading the static `root`; that is
   the production store's path). Add `static func isolated() -> MeetingStore` for self-tests
   (a temp directory under `FileManager.default.temporaryDirectory`).
2. Pure planner:
   ```swift
   enum ResumeAction: Equatable, Sendable {
       case finalPass, pipelineAfterTranscript, diarize, notes, fail(String), extractAgain, none
   }
   nonisolated static func resumeAction(for status: MeetingStatus, hasTranscript: Bool,
                                        hasAudio: Bool, finalPassOn: Bool) -> ResumeAction
   ```
   exactly the table in Target 1. `repairInterruptedMeetings()` now: compute actions, write the
   repaired status (`.transcribing` / `.diarizing` / `.summarizing` / `.failed`), fill `end`, and
   return `[(UUID, ResumeAction)]`. No `releaseAudio` call inside it.
3. `MeetingResumer`:
   ```swift
   @MainActor struct MeetingResumer {
       var store: MeetingStore
       var finalPass: (Meeting) -> Void      // FinalTranscriptService.shared.process (M-01)
       var afterTranscript: (Meeting) -> Void   // MeetingPipeline.afterFinalPass
       var diarize: (Meeting) -> Void        // DiarizationService.shared.process
       var notes: (Meeting) -> Void          // NotesService.shared.summarize(_, announce: true)
       var isBusy: () -> Bool                // the foreground/voice gate
       func resume(_ plan: [(UUID, ResumeAction)]) async
   }
   ```
   `resume` waits on `isBusy` (poll 30 s, cancellable), then dispatches one meeting, and waits until
   that meeting leaves its active state before the next (poll the store every 5 s). Launch code
   (`NextNotesApp.swift:301`) keeps calling `repairInterruptedMeetings()` synchronously before the
   scheduler starts, then starts the resumer in a `Task`.
4. `endAbruptly()`: `meeting.status = segments.isEmpty ? .failed("Next Notes quit before anything was transcribed.") : .transcribing`
   — but when a temporary audio file with content exists and M-01's pass is on, keep `.transcribing`
   even with no segments (the pass can recover them). Update the doc comment.
5. `StageWatchdog`:
   ```swift
   enum StageWatchdog {
       /// Pure: `busySeconds` is how much of the silent stretch a more urgent lane was busy.
       static func isStalled(sinceProgress: TimeInterval, busySeconds: TimeInterval, limit: TimeInterval) -> Bool {
           sinceProgress - busySeconds >= limit
       }
       static let diarizeLimit: TimeInterval = 5 * 60
       static let notesLimit: TimeInterval = 10 * 60
   }
   ```
   `DiarizationService.run` and `NotesService.summarize` each start a sibling `Task` that samples
   every 15 s: last progress time (updated wherever `progress[id]` / `steps[id]` is set), and adds
   15 s to `busySeconds` when the scheduler reports a more urgent lane busy. On stall: cancel the
   work task, set the problem text above, log `diarize stalled` / `notes stalled` with the seconds.
   The limits are `static var` so the self-test can shorten them through an explicit test-only
   setter (the `startTimeoutOverrideForTesting` pattern in `Core/SystemAudioCapture.swift:76`),
   never through `SelfTest.isRunning` checks in production logic.
6. `applicationShouldTerminate`: if `!SelfTest.isRunning`, `MeetingController.shared.session?.isRecording == true`,
   run the alert (Target 5) and return `.terminateLater`, replying after the bounded stop; otherwise
   `.terminateNow`. Strings contain no developer words.
7. AGENTS.md: rewrite the repair sentence in "A meeting reaches 'Done' minutes after you press
   Stop" or add a new entry "**An interrupted meeting is resumed, not written off.**" with the
   table, the `pkill` fact, and the watchdog numbers.

**Do not:**
- release audio in repair, or change `releaseAudio`'s rule;
- add a `MeetingStatus` case;
- use a hard wall-clock deadline for a whole stage (long meetings legitimately take minutes; I2 #9);
- block `applicationWillTerminate` (it cannot await) or the resumer on the main actor;
- seed test meetings in the user's `Meetings/` folder — only `MeetingStore.isolated()`;
- call the real `DiarizationService` / `NotesService` from the self-test (inject the runners).

**Red-first self-test:** new `--selftest-meeting-resume`, in `MeetingResumeSelfTest.run()`, marker
`MEETING_RESUME_OK` / `MEETING_RESUME_FAILED: <reason>`. No model, no microphone.
- a. Pure: `resumeAction` over the whole Target 1 table (12 rows including `finalPassOn` false/true).
- b. Isolated store, four seeded folders: A `.recording` + 3-segment transcript + temporary
  `audio.caf` (1 s of stereo silence written with `MeetingAudioWriter`); B `.diarizing` + transcript +
  temporary audio; C `.summarizing` + transcript, no audio; D `.recording`, empty transcript, no
  audio. Run `repairInterruptedMeetings()` then `MeetingResumer` with fake runners that write
  `notes.md` ("fake notes"), set speakers, and advance status the way the real services do (the fake
  notes runner calls `store.releaseAudio(for:notesWritten: true)` exactly where `NotesService` does).
  Assert: A, B, C end `.done` with `notes.md`; D is `.failed`; A's and B's audio still exists after
  `repairInterruptedMeetings()` returns and is gone only after their notes step; the call order is
  A: finalPass (or afterTranscript when the pass is off) → diarize → notes; B: diarize → notes;
  C: notes. **3/3 resumable meetings reach `.done` with notes.**
- c. Watchdog pure cases: 301 s since progress with 0 busy → stalled (diarize); 301 s with 60 s busy
  → not stalled; 599 s notes → not stalled; 600 s → stalled.
- d. A fake notes runner that never reports a step, with `notesLimit` set to 0.5 s through the test
  setter: within 3 s the meeting has a notes problem, is no longer `.summarizing`, and its audio is
  unchanged.
Confirm RED: add `init(root:)`, `isolated()`, `resumeAction` returning today's mapping
(`.done`/`.failed`) and a resumer that does nothing; b fails ("A ended failed").

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-meeting-resume 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/M-08-green.txt
Scripts/run-selftest.sh --selftest-meeting-reconcile
Scripts/run-selftest.sh --selftest-meeting-live
Scripts/run-selftest.sh --selftest-index            # the store's static root unchanged for the indexer
Scripts/run-selftest.sh --selftest-ui-strings       # the Quit alert and the problem text
make acceptance TIER=core
```

**Success threshold:** `MEETING_RESUME_OK` with a–d (red first); 3/3 resumable meetings reach
`.done` with notes; `make acceptance TIER=core` no worse than the roadmap baseline.

**Risks & rollback:** A resume loop on a meeting that fails at the same stage every launch: each
resume either finishes or leaves a problem and a non-active status, so the next launch does not
resume it again (pin this in case b by asserting no meeting is active after the run). The alert
could annoy on logout: it appears only while recording. Revert to roll back; meetings written in
the meantime have only existing statuses.

**Done when:**
- [ ] `MeetingStore(root:)` + `isolated()`; planner + resumer; no audio released in repair.
- [ ] `endAbruptly` leaves `.transcribing`; Quit alert; watchdog on both stages.
- [ ] `MEETING_RESUME_OK` (red first); CORE acceptance not regressed.
- [ ] AGENTS.md entry; flag in the list and in `CORE_ENTRIES` as `"selftest-meeting-resume|300"`.
- [ ] Committed as `M-08: …`.

---

### M-04 — Label short far-end segments from the nearest speaker run or agreeing neighbours

**Finding(s):** I2 #4  **Effort:** 0.5 d  **Depends on:** M-16a (fixtures, probe)  **Unblocks:** M-03 (measured together)

**Why (what the user experiences today):** `MeetingDiarizer.assign` gives a system-track segment
the speaker run with the largest overlap and nothing when no run overlaps it. Short finals fall
between the segmenter's runs (FluidAudio's embedding minimum is 1.0 s), so 50 % (55/109), 29 %
(82/287) and 30 % (30/101) of far-end lines in three meetings stayed "Others", with unlabelled
medians of 1.36 s, 0.76 s and 0.72 s against 2.2–2.4 s for labelled ones. In 6C5E half the call is
attributed to "Others" although one remote speaker was identified, and the notes' action items
then have no owner.

**Files you will change:** `Meetings/MeetingDiarizer.swift` `assign(_:to:)` (`:181-202`) and a new
pure helper; new `Meetings/DiarizeAssignSelfTest.swift`; `NextNotesApp.swift` (register);
`AGENTS.md`; `Scripts/acceptance.sh`.

**Read for context (do not change):** `labelsByCluster` (`:205-212`); `DiarizationService.diarize`
(the only production caller); AGENTS.md "A transcript segment is a sentence…" (why segments are
sentence-sized).

**Current behaviour:**
```swift
// MeetingDiarizer.assign — :197-200
// No overlap at all — a window the segmentation model heard as silence. Left
// unlabelled rather than guessed at, so it falls back to "Others".
guard let best, let label = labels[best.id] else { return segment }
```

**Target behaviour:** Overlap stays the first rule. When a system segment overlaps no run:
1. assign the speaker of the nearest run whose gap to the segment is ≤ 1.0 s (gap = distance
   between intervals); ties → the earlier run;
2. else, if the previous and next **system** segments (in time order) are both labelled with the
   same speaker, assign that speaker;
3. else leave it unlabelled. Mic segments are never touched.
The rule is pure and deterministic, and `assign` keeps its signature.

**Steps:**
1. Add `static let nearestRunTolerance: TimeInterval = 1.0` (FluidAudio's embedding minimum, I2).
2. In `assign`, first pass as today; for an unlabelled system segment compute the nearest run by
   `max(0, max(run.start, segment.start) - min(run.end, segment.end))`; if ≤ tolerance, label it.
3. Second pass over system segments sorted by start: fill any still-unlabelled segment whose nearest
   labelled system neighbours on both sides agree. One pass only (no propagation chains).
4. Update the doc comment of `assign` (drop the stale "thirty to sixty seconds" text if M-01 has not
   already) and describe the three rules.

**Do not:** move a segment that *has* an overlapping run; label mic segments; chain the neighbour
rule (a run of ten unlabelled lines between two "Speaker 1" lines stays unlabelled except where rule
1 applies — honest over tidy); change `labelsByCluster` numbering.

**Red-first self-test:** new `--selftest-diarize-assign` (`DIARIZE_ASSIGN_OK` / `…_FAILED`), pure,
no model:
- a. A 0.8 s segment starting 0.4 s after a "c1" run ends → "Speaker 1".
- b. A segment 3 s from any run, neighbours "Speaker 1" and "Speaker 2" → unlabelled.
- c. A segment 3 s from any run, both neighbours "Speaker 2" → "Speaker 2".
- d. A segment overlapping run c2 by 0.1 s and 0.5 s from c1 → c2's label (overlap wins).
- e. Mic segments with no overlap stay unlabelled.
- f. Fixture-derived: build `SpeakerRun`s from `fr-call-system.wav`'s manifest turns, shrunk by
  0.4 s at each end (the way real runs miss short edges), and system segments from the manifest
  turns split at sentence ends; unattributed share after `assign` **≤ 10 %** (before: print it).
Confirm RED on the current `assign`: a and c fail, and f prints a share above 10 %.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-diarize-assign 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/M-04-green.txt
Scripts/run-selftest.sh --selftest-notes "$PWD/Tests/Fixtures/meeting-2min.wav" --diarize
Scripts/run-selftest.sh --selftest-resolve          # voice prints read labels
```

**Success threshold:** `DIARIZE_ASSIGN_OK` (red first); fixture unattributed share ≤ 10 %; on the
owner's next diarized call, `--meeting-quality-report`'s `unlabelled` ≤ 10 % (recorded in STATUS;
if not met, a note with the number, not a tolerance change).

**Risks & rollback:** A wrong nearest-run label is possible at a turn boundary; the 1 s tolerance
keeps it to edges. Revert to roll back.

**Done when:**
- [ ] Two fallback rules in `assign`, comment updated.
- [ ] `DIARIZE_ASSIGN_OK` (red first); regressions unchanged.
- [ ] Flag in AGENTS.md and INTEGRATION (`"selftest-diarize-assign|120"`).
- [ ] Committed as `M-04: …`.

---

### M-03 — Speaker-count hints, voice-print cluster merge, and "Identify again with N speakers"

**Finding(s):** I2 #3  **Effort:** 1.5 d  **Depends on:** M-04, M-10 (the re-identify action needs audio kept; without M-10 the button is shown only while audio exists)  **Unblocks:** none

**Why (what the user experiences today):** The diarizer runs with `OfflineDiarizerManager(config: .default)`
and no speaker-count hint. Three of six meetings came back with more clusters than voices: a 1:1
WhatsApp call with the owner's father came back as three speakers, all of which the owner renamed
"Mathieu Kadjo"; a ChatGPT voice session came back as two; a two-person call got a third cluster of
12 segments. The notes were written before the rename, so their action items name "Speaker 1".

**Files you will change:**
- `Meetings/MeetingDiarizer.swift`: `loaded()` (`:137-141`) keeps the prepared
  `OfflineDiarizerModels`; `speakerRuns(in:progress:)` (`:103-114`) takes a `SpeakerCountHint`;
  new pure `mergeClusters(_:maxSpeakers:threshold:)`.
- new `Meetings/SpeakerCountHint.swift`.
- `Meetings/DiarizationService.swift` `diarize(_:)` (`:90-160`): builds the hint from the meeting;
  a `reidentify(_:speakers:)` entry.
- `UI/Meetings/…` speaker sheet (grep `speakerNames` under `UI/Meetings/` for the rename sheet):
  "Identify again" with a speaker-count stepper, shown only while `store.audioURL(for:)` is non-nil.
- new `Meetings/DiarizeHintsSelfTest.swift`; `NextNotesApp.swift`; `AGENTS.md`; `Scripts/acceptance.sh`.

**Read for context (do not change):** FluidAudio `Diarizer/Offline/Core/OfflineDiarizerTypes.swift`
(`Clustering.minSpeakers` / `maxSpeakers` / `numSpeakers` / `threshold`, `:120-180`) and
`OfflineDiarizerManager` (`init(config:)` stores a private `let config`; `initialize(models:)` shares
already-prepared models with a new manager); `MeetingVoicePrints.centroids(of:)`
(`Meetings/SpeakerVoicePrints.swift:44`); `CallDetector.event(for:)` (a detected call has no
attendees and `providerID == .detectedCall`).

**Current behaviour:** one manager with `.default` config, cached for the process; no hint; no
post-merge; the rename sheet can only rename.

**Target behaviour:**
1. `SpeakerCountHint.for(meeting)`: a detected call from a messaging/FaceTime-class app with no
   attendees → `maxSpeakers = 2` (one far voice plus slack); a calendar meeting with attendees →
   `maxSpeakers = max(2, attendees.count)` (the mic track already holds "You"); otherwise none.
   Messaging/FaceTime-class = a small table (`net.whatsapp.WhatsApp`, `com.apple.FaceTime`,
   `com.apple.avconferenced`, `com.apple.MobileSMS`, `ru.keepcoder.Telegram`, `com.tinyspeck.slackmacgap`
   huddles are **not** in it) — owners from M-02. A browser or unknown app gets no hint.
2. The run uses a manager built for the hint (`config.clustering.maxSpeakers`), sharing the prepared
   models via `initialize(models:)`; no second model load.
3. After clustering, clusters whose voice-print centroids have cosine similarity ≥
   `mergeThreshold` are merged (and, with a `maxSpeakers`, the closest pairs are merged until the
   count fits). `mergeThreshold` is **measured** in step 1 below, not guessed.
4. "Identify again" re-runs diarization with `numSpeakers = N` from the sheet.

**Steps:**
1. **Measure the threshold first.** With `fr-call-system.wav` (two far voices, B and C) and
   `fr-1to1-system.wav` (one far voice, B), run the diarizer without hints in the self-test's
   measurement mode, print every centroid pair's cosine similarity with whether the pair is the same
   manifest speaker, and choose the midpoint between the highest different-speaker similarity and the
   lowest same-speaker similarity. Record the numbers and the choice in `STATUS.md`. If the two
   ranges overlap, set no merge (hint only) and write that down.
2. `SpeakerCountHint` (pure) and `MeetingDiarizer.speakerRuns(in:hint:progress:)`.
3. `mergeClusters` (pure over `[SpeakerRun]` with embeddings): compute centroids per cluster (reuse
   the averaging in `MeetingVoicePrints.centroids`), merge pairs above threshold, then while
   `clusters > maxSpeakers` merge the most similar pair; relabel runs.
4. `DiarizationService`: build the hint; after assignment, if the meeting already has
   `speakerNames` for labels that no longer exist, keep names only for labels that survive.
5. The sheet action and `reidentify(_:speakers:)` (same path as `retry`, `numSpeakers` set).

**Do not:** hint a browser, an unknown app, or a meeting with no attendee list; force
`numSpeakers` automatically (only the person may); load the diarizer models twice; write voice
prints while the knowledge graph is off (existing rule in `diarize`); show "Identify again" when
the audio is gone.

**Red-first self-test:** new `--selftest-diarize-hints` (`DIARIZE_HINTS_OK` / `…_FAILED` /
`…_ABSENT: diarizer models not downloaded` for the model-backed half):
- a. Pure hints: WhatsApp detected call → max 2; FaceTime → max 2; Chrome → none; calendar with 4
  attendees → max 4; calendar with 0 attendees → none.
- b. Pure merge: three synthetic clusters where two centroids have cosine 0.95 and the third 0.2 →
  two clusters; with `maxSpeakers 1` → one.
- c. Model-backed (ABSENT without the models): `fr-1to1-system.wav` with the WhatsApp hint →
  ≤ 2 far-end clusters (**never more than 2**); `fr-call-system.wav` with no hint → 2 clusters
  after merge.
Confirm RED: `SpeakerCountHint.for` returns nil and `mergeClusters` returns its input; a and b fail.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-diarize-hints 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/M-03-green.txt
Scripts/run-selftest.sh --selftest-diarize-assign
Scripts/run-selftest.sh --selftest-resolve
Scripts/run-selftest.sh --selftest-ui-strings
```

**Success threshold:** `DIARIZE_HINTS_OK` (red first) including c on this Mac (the diarizer models
are on disk here: `meetingsDiarize = 1`); on the owner's next 1:1 call, the report's
`labels ≤ 2` and `overSplit == false`.

**Risks & rollback:** A wrong hint under-splits a 1:1 call that was actually a group call on
WhatsApp; `maxSpeakers 2` still allows two far voices, and "Identify again" fixes it by hand.
Revert to roll back.

**Done when:**
- [ ] Threshold measured and recorded; hints; merge; re-identify action.
- [ ] `DIARIZE_HINTS_OK` (red first); regressions unchanged.
- [ ] Flag in AGENTS.md and INTEGRATION (`"selftest-diarize-hints|600"`).
- [ ] Committed as `M-03: …`.

---

### M-12 — Window-aware notes budgeting: real Apple FM window and token counts, a counted system prompt, a retry on overflow, chunk sizes derived from the window

**Finding(s):** I2 #13, #15  **Effort:** 1 d  **Depends on:** M-05; AGENT-OVERHAUL **P1-10a step 0** (owns `FoundationModelLLMProvider.contextTokens`; see §1.5 for what to do if it has not landed)  **Unblocks:** M-13

**Why (what the user experiences today):** Meeting notes run on Apple FM (P0-01). The app assumes
its window is 4,096 tokens (`FoundationModelLLMProvider.contextTokens`, `:13`) while G measured
8,192 on this Mac, so every meeting over ≈ 10–14 min is forced through map-reduce it does not need.
Tokens are estimated at 4 characters each (`countTokens`, `:26-30`), French tokenises denser, the
prompt overhead is assumed to be 512 tokens while `NotesPrompts.notesSystem` alone is 2,513
characters (≈ 630 tokens, I2), and there is no catch for the framework's context-size error: a
single pass near the edge fails with a raw error instead of falling back to map-reduce (estimate;
not yet observed). Map chunks are fixed (2,000 Apple / 3,000 others) instead of derived from the
window.

**Files you will change:**
- `Formatting/LLM/FoundationModelLLMProvider.swift`: `countTokens` (`:26-30`) uses
  `SystemLanguageModel.default.tokenCount(for:)` under `#available(macOS 26.4, *)`, falling back to
  `characters / 3` (conservative for French; label it an estimate in the comment). `contextTokens`
  only if P1-10a step 0 has not landed (then verbatim from P1-10a, both STATUS files updated).
- `Meetings/NotesGenerator.swift`: `promptOverheadTokens` (`:40`) becomes a counted value per call;
  `chunkTokens` (`:196-205`) derived; the single-pass call wrapped in an overflow retry.
- `Meetings/NotesLongformSelfTest.swift` (M-05): two cases.

**Read for context (do not change):** AGENT-OVERHAUL `02-PHASE-1-TOOLS.md` P1-10a step 0 and
step 3 (the same errors caught for the tool loop); the SDK's
`LanguageModelSession.GenerationError.exceededContextWindowSize` (macOS 26) and
`LanguageModelError.contextSizeExceeded` (macOS 27; this Mac runs 27) in
`FoundationModels.swiftinterface`; P0-20's plan to count Apple FM passes after a stream — **M-12
owns `countTokens`**, and P0-20a/b should call it rather than add a second counter.

**Current behaviour:** `budget = contextTokens − reservedTokens (1,536)`; `outputBudget` subtracts
a fixed 512 overhead; `chunkTokens` is a switch on provider id; `provider.complete` errors propagate
to `NotesService`, which shows the raw message.

**Target behaviour:**
1. `overhead = countTokens(notesSystem) + countTokens(notesUser(meeting:transcript:"" , brief:.empty)) + 64`
   (the 64 is template slack, estimate), computed once per `notes(…)` call and used in both the
   single-pass decision and `outputBudget`.
2. `chunkTokens = min(6_000, contextTokens − overhead(mapSystem) − maxFactTokens − runtimeHeadroomTokens)`,
   floored at 1,000; the per-provider switch is removed.
3. If the single pass (or the reduce) throws a context-size error from any provider
   (`LanguageModelError.contextSizeExceeded`, `GenerationError.exceededContextWindowSize`,
   `LlamaError.inputTooLong`), the generator retries once through map-reduce with chunks at 70 % of
   `chunkTokens`; a second overflow surfaces as `NotesError.contextTooSmall` with the plain message
   "This meeting is too long for the selected model to summarise in one go."
4. On Apple FM with macOS ≥ 26.4, token counts are exact.

**Steps:** implement 1–4; add a `static func isContextOverflow(_ error: Error) -> Bool` in
`NotesGenerator` matching the three error types; keep `reservedTokens` as the lower bound for the
answer (`outputBudget` still clamps to `minNotesTokens…maxNotesTokens`).

**Do not:** change `contextTokens` if P1-10a step 0 has landed (read AGENT-OVERHAUL `STATUS.md`);
count the brief twice; pass the brief to the map step; retry more than once.

**Red-first self-test:** extend `--selftest-notes-longform`:
- e. A fake provider whose `complete` throws a context-size error the first time it is called for a
  single pass: the result has `usedMapReduce == true` and notes are written.
- f. With `contextTokens: 8_192`, a 12-min transcript takes the single pass (it does not today at
  4,096 because the Apple chunk/budget math assumed the smaller window) and `chunkTokens` computed
  for 8,192 is > 3,000.
- g. Apple FM only, ABSENT elsewhere: print `APPLE_FM_TOKENS text=<chars> tokens=<n>` for a French
  and an English paragraph; FAIL if `countTokens` equals `characters / 4` exactly for both (the real
  counter was not used) on macOS ≥ 26.4.
Confirm RED: e fails with the raw error; f fails on the chunk size.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-notes-longform 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/M-12-green.txt
Scripts/run-selftest.sh --selftest-notes "$PWD/Tests/Fixtures/meeting-2min.wav"
Scripts/run-selftest.sh --selftest-notes-context
Scripts/run-selftest.sh --selftest-toolloop-production   # shares FoundationModelLLMProvider; ends as before
```

**Success threshold:** `NOTES_LONGFORM_OK` with e–g; `--selftest-notes` and
`--selftest-toolloop-production` end as in their last recorded run.

**Risks & rollback:** `tokenCount` is async and may be slow on very long text; it runs once per
chunk decision, not per segment (the chunker still uses one ratio). Revert to roll back.

**Done when:**
- [ ] Counted overhead, derived chunks, overflow retry, real Apple counts.
- [ ] P1-10a coordination recorded in both STATUS files if step 0 landed here.
- [ ] `NOTES_LONGFORM_OK` (e–g red first); regressions unchanged.
- [ ] Committed as `M-12: …`.

---

### M-13 — A cut-off answer is visible: `LLMCompletion.finishedByLimit` for every provider, one retry, "cut short" instead of `_None._`, and a cap that scales with length

**Finding(s):** I2 #14  **Effort:** 1 d  **Depends on:** M-12; AGENT-OVERHAUL **P0-17** for the OpenRouter leg only (it owns OpenRouter's `finish_reason` decoding)  **Unblocks:** none

**Why (what the user experiences today):** Notes are capped at 1,500 tokens
(`NotesGenerator.maxNotesTokens`, `:46`). `LLMCompletion` (`Formatting/LLM/LLMProvider.swift:206-214`)
has no finish reason, and `NotesFormatter.tidy` fills every missing section with `_None._`, so a
truncated answer looks complete and says "no decisions" or "no open questions". The OpenRouter
notes model on this Mac (`nvidia/nemotron-3-super-120b-a12b:free`) is a reasoning model whose
reasoning also counts against those tokens (G: ling-3.0 spent 105 of 112 on reasoning). No
truncation has been seen yet (longest notes ≈ 600 tokens); this is latent.

**Files you will change:** `Formatting/LLM/LLMProvider.swift` (`LLMCompletion.finishedByLimit: Bool = false`,
a `var` with a default so every existing memberwise call still compiles);
`Formatting/LLM/FoundationModelLLMProvider.swift` (`complete`: `finishedByLimit` when the counted
reply tokens ≥ `maxTokens − 2`, estimate rule); `Formatting/LLM/LlamaLLMProvider.swift` /
`NotesModelRuntime` (the stop reason is known: max tokens vs end-of-generation);
`Formatting/LLM/OpenAICompatibleLLMProvider.swift` (`finish_reason == "length"`);
`Formatting/LLM/OpenRouterLLMProvider.swift` (only after P0-17: map its `finish_reason` / `cutOff`
to the flag in `complete`); `Meetings/NotesGenerator.swift` (`maxNotesTokens` → a function;
retry; `NotesFormatter.tidy(_:cutShort:)`); new `Meetings/NotesTruncationSelfTest.swift`;
`NextNotesApp.swift`; `AGENTS.md`; `Scripts/acceptance.sh`.

**Read for context (do not change):** AGENT-OVERHAUL `01-PHASE-0-MAKE-IT-ANSWER.md` P0-17
(`OpenRouterError.cutOff(visibleText:)`, `OpenRouterStreamSummary`); `NotesFormatter.tidy` and
`NotesPrompts.headings`.

**Current behaviour:** see Why. `outputBudget` = `max(256, min(1_500, remaining))`.

**Target behaviour:**
1. `maxNotesTokens(minutes:) = min(3_000, 800 + 20 × minutes)` (a 10-min meeting keeps 1,000, a
   60-min one gets 2,000), still clamped by the window.
2. When a single-pass or reduce completion has `finishedByLimit`, retry once with twice the output
   budget if `outputBudget` allows it; if still cut, keep the text and fill every missing section
   with "_The notes were cut short before this section._" instead of `_None._`; log
   `notes cut short · provider … · budget …`.
3. `finishedByLimit` is set by Apple FM, llama, OpenAI-compatible servers and (after P0-17)
   OpenRouter; any provider that cannot tell leaves it false.

**Steps:** implement 1–3; `tidy(_ text: String, cutShort: Bool = false)` switches the filler.

**Do not:** decode OpenRouter's `finish_reason` here before P0-17 lands (P0-17 owns it); retry map
calls (a cut fact list is still facts); change `emptySection` behaviour for the Related section.

**Red-first self-test:** new `--selftest-notes-truncation` (`NOTES_TRUNCATION_OK` / `…_FAILED`):
a fake provider returns Summary + half of Decisions with `finishedByLimit: true` on the first call
and on the retry → the markdown contains "cut short" under Decisions/Action items/Open questions
and no `_None._` there; a fake that is cut the first time and complete the second → complete notes,
exactly 2 calls, the second with twice the budget; `maxNotesTokens(minutes: 60) == 2_000`.
Confirm RED: the first case shows `_None._`.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-notes-truncation 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/M-13-green.txt
Scripts/run-selftest.sh --selftest-notes-longform
Scripts/run-selftest.sh --selftest-openrouter-contract   # only meaningful after P0-17
Scripts/run-selftest.sh --selftest-cleanup-router        # LLMCompletion change compiles everywhere; ends as before
```

**Success threshold:** `NOTES_TRUNCATION_OK` (red first); the others end as in their last run.

**Risks & rollback:** A false `finishedByLimit` from the Apple estimate rule triggers one extra
call; harmless. Revert to roll back.

**Done when:**
- [ ] Field on `LLMCompletion`, set by every provider that can tell.
- [ ] Retry + "cut short" filler; scaled cap.
- [ ] `NOTES_TRUNCATION_OK` (red first); flag in AGENTS.md and INTEGRATION (`"selftest-notes-truncation|120"`).
- [ ] Committed as `M-13: …`.

---

### M-07 — The transcription backlog is bounded by audio seconds, queued windows merge to catch up, and nothing is dropped silently

**Finding(s):** I2 #7  **Effort:** 1 d  **Depends on:** M-01 (after it, anything the live tier sheds is recovered by the final pass from `audio.caf`), M-16a (the drop span)  **Unblocks:** none

**Why (what the user experiences today):** `ChunkedTranscriber.maxPendingWindows = 8` per track
(`:30`) was sized for 30–60 s windows (4–8 min of tolerance). At 2–5 s it is 16–40 s. Both tracks
share one `TranscriptionQueue`, each window must win `.realtimeASR`, `recordNow` starts capture
before Parakeet is warm (cold load ≈ 11 s, AGENTS.md), and a voice-agent turn or a swap-heavy
moment can hold the lane. When the cap is hit the newest window is discarded and the speech is gone
from the transcript for good. Not seen in the retained logs (they age out); latent.

**Files you will change:** `Meetings/ChunkedTranscriber.swift` (`maxPendingWindows`, `enqueue`,
the `pending` task chain → an explicit FIFO with one drain task; a `transcribe` injection seam in
`init`); new `Meetings/MeetingBacklogSelfTest.swift`; `NextNotesApp.swift`; `AGENTS.md`;
`Scripts/acceptance.sh`; `Transcription/StreamingASR.swift` `runSelfTest` (its backlog check
`maxPendingWindows` 1…16 becomes a seconds check).

**Read for context (do not change):** `TranscriptionQueue` (`:385-419`); FluidAudio pads every
input ≤ 15 s to a full 15 s encoder pass (see M-01), so one 14 s pass costs about what one 2 s pass
costs; §1.6 (D-04 owns the 0.3 s minimum helper; D-14 owns dictation's lane).

**Current behaviour:**
```swift
// ChunkedTranscriber — :28-30
/// Maximum number of windows retained by one track while Parakeet catches up. Newest
/// windows are dropped after this point so a stalled model cannot grow memory forever.
static let maxPendingWindows = 8
```

**Target behaviour:**
1. Queued audio per track is bounded by `maxPendingAudioSeconds = 300` (≈ 19 MB of Float32 per
   track, estimate) instead of a window count.
2. When more than one window is queued, the drain task merges adjacent queued windows into one of
   up to 14.5 s before transcribing (fewer encoder passes, so the backlog shrinks faster), keeping
   `start` of the first and the provisional/final contract per merged window.
3. Only past 300 s is a window dropped; each drop writes `meeting.windows_dropped` (M-16a) and
   increments a per-meeting counter logged at Stop ("live transcript skipped N s; the final pass
   covers them" when `audio.caf` exists).
4. Order of segments and `flush()` / `cancel()` semantics are unchanged.

**Steps:** replace the chained `pending` tasks with `queue: [(start: Int, samples: [Float])]` and a
single `drainTask` that loops while the queue is non-empty; `enqueue` appends or drops by the
seconds rule; `flush()` waits for the queue to empty; `cancel()` clears it and bumps `generation`.
Add `init(…, transcribe: @escaping @Sendable ([Float]) async throws -> ASRResult = { try await TranscriptionQueue.shared.transcribe($0) })`.

**Do not:** raise the bound above 300 s without a memory measurement; transcribe two windows of one
track concurrently; change the segmentation rule; merge across a `flush()`.

**Red-first self-test:** new `--selftest-meeting-backlog` (`MEETING_BACKLOG_OK` / `…_FAILED`): a
`ChunkedTranscriber` with an injected fake transcriber that sleeps 1.5 s per call and returns an
`ASRResult` whose text is the window's `[start–end]` in seconds and whose token timings cover it;
feed 180 s of synthetic speech-level noise (0.1 RMS) with a 0.8 s silence every 3 s, at real time
compressed ×10; after `flush()`, the union of emitted segment intervals covers ≥ 99 % of the
non-silent input (**0 s lost**), no `meeting.windows_dropped` span was written, and the fake saw
fewer calls than the number of cut windows (merging happened). Confirm RED on the current code:
windows are dropped once 8 are queued (coverage < 99 %).

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-meeting-backlog 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/M-07-green.txt
Scripts/run-selftest.sh --selftest-stream
Scripts/run-selftest.sh --selftest-transcript-bus
Scripts/run-selftest.sh --selftest-meeting-live
Scripts/run-selftest.sh --selftest-transcribe "$PWD/Tests/Fixtures/meeting-2min.wav"
```

**Success threshold:** `MEETING_BACKLOG_OK` (red first) with 0 s lost; `STREAM_OK` (with the updated
backlog check), `TRANSCRIPT_BUS_OK`, `MEETING_LIVE_OK` unchanged.

**Risks & rollback:** A merged window shows provisional text later (up to one merged window) while
catching up; that is the trade for not losing it. Revert to roll back.

**Done when:**
- [ ] Seconds-bounded FIFO with merging; drops only past 300 s, each one recorded.
- [ ] `MEETING_BACKLOG_OK` (red first); regressions unchanged.
- [ ] Flag in AGENTS.md and INTEGRATION (`"selftest-meeting-backlog|300"`).
- [ ] Committed as `M-07: …`.

---

### M-09 — Retry the system-audio tap while recording, and place the late track at the right time

**Finding(s):** I2 #10  **Effort:** 1 d  **Depends on:** none  **Unblocks:** none

**Why (what the user experiences today):** `SystemAudioCapture.startTimeout = .seconds(5)`
(`Core/SystemAudioCapture.swift:73`). If the tap does not start in time, `MeetingSession.start`
logs "meeting continues on the microphone alone" (`Meetings/MeetingSession.swift:190-192`) and the
meeting stays mic-only for its whole length: no "Others" track, no diarization, no far-end words in
the notes. "system audio start timed out; awaiting HAL return for cleanup" fired on this Mac on
2026-09-23 at 15:10 (not during a meeting), so the timeout does fire.

**Files you will change:** `Meetings/MeetingSession.swift` (a retry task started in the `catch` at
`:183-193`, cancelled in `stop()` / `endAbruptly()` / `abort`); `Meetings/ChunkedTranscriber.swift`
(`func advanceOrigin(toSample:)` — moves `bufferOrigin` forward without transcribing, so late
system segments carry true meeting times); `Core/SystemAudioCapture.swift` (an injection seam for
the start call, following `startTimeoutOverrideForTesting` at `:76`); new
`Meetings/MeetingTapRetrySelfTest.swift`; `NextNotesApp.swift`; `AGENTS.md`; `Scripts/acceptance.sh`.

**Read for context (do not change):** AGENTS.md "A system-audio tap without permission returns
silence, not an error" and "There is no `Permissions.hasSystemAudio`…" (a retry cannot detect a
missing grant — silence is still silence; this task only handles start *errors/timeouts*);
`MeetingAudioWriter.writePairedFrames` (pads the stalled side with silence after 5 s, so the file
stays aligned without help).

**Current behaviour:** one attempt; on error `systemAudioProblem` is set and nothing retries.

**Target behaviour:**
1. While the meeting is `.recording` and `systemAudioProblem != nil`, retry `systemCapture.start`
   every 30 s, at most 10 attempts; on success clear the problem, log "system audio joined late at
   <mm:ss>", and before the first real buffer call
   `systemTranscriber.advanceOrigin(toSample: elapsedSamples)` so the system transcript's times
   match the recording clock.
2. The retry stops on Stop, abort, quit, or after 10 failures (then the log says so once).
3. The same stop-race guard as the first start (`guard !isStopping, meeting.status == .recording`).

**Steps:** as Target; `advanceOrigin(toSample:)` requires an empty buffer (true before the first
buffer) and asserts in debug only via a log, never `precondition` in release.

**Do not:** treat a silent tap as a failure to retry (it is indistinguishable from a quiet call and
from a missing grant); touch TCC or open System Settings; retry after Stop.

**Red-first self-test:** new `--selftest-meeting-tap-retry` (`MEETING_TAP_RETRY_OK` / `…_FAILED`):
a session driven with an injected start function that throws twice and then succeeds, the retry
interval shortened through a test setter to 0.2 s, and a fake capture that yields 1 s of 0.1-RMS
noise: the problem clears, the system transcriber's first segment `start` ≥ the elapsed time at
join − 0.1 s, and no retry fires after `stop()`. Uses no microphone and no real tap (inject the
capture); writes no meeting to the real store (use `MeetingStore.isolated()` from M-08, or skip the
pass it through `MeetingSession.init(meeting:store:)`, `Meetings/MeetingSession.swift:52`; if M-08
is not done yet, this task waits for it).
Confirm RED: the problem never clears.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-meeting-tap-retry 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/M-09-green.txt
Scripts/run-selftest.sh --via-open --selftest-systemaudio   # TCC-bound; once, not in a loop; ends as before
Scripts/run-selftest.sh --selftest-capture
```

**Success threshold:** `MEETING_TAP_RETRY_OK` (red first); `--selftest-systemaudio` ends as in its
last run (OK or `SYSTEM_AUDIO_SILENT`, which is a SKIP).

**Risks & rollback:** A retry that succeeds against a device that then fails mid-call behaves as
today's mid-call failure. Revert to roll back.

**Done when:**
- [ ] Retry loop with the stop guards; `advanceOrigin`.
- [ ] `MEETING_TAP_RETRY_OK` (red first); regressions unchanged.
- [ ] Flag in AGENTS.md and INTEGRATION (`"selftest-meeting-tap-retry|120"`).
- [ ] Committed as `M-09: …`.

---

### M-10 — Keep temporary audio for 72 h or until the speakers are confirmed, with a disk guard; skip the file when the disk is nearly full

**Finding(s):** I2 #11, #21  **Effort:** 1 d  **Depends on:** M-08 (resume must not race the sweeper)  **Unblocks:** M-03's "Identify again" on older meetings

**Why (what the user experiences today):** With `meetingsKeepAudio = 0` (this Mac and the
default), the temporary recording is deleted the moment notes land (`NotesService.summarize`,
`if announce { store.releaseAudio(…) }`). The owner saw three clusters for one voice and could only
rename them; no "Identify again" or re-transcription is possible afterwards. Separately there is no
free-space check before `audio.caf` is created, and write errors are logged per chunk and ignored.

AGENTS.md paragraph this task changes (`AGENTS.md:673-684`, "A meeting records audio even when
'Keep the recorded audio' is off"): "…a recording made only for diarization goes…". The rule's
shape is kept; only its timing changes: a temporary recording goes **72 hours** after the pipeline
ends, or when the speakers are confirmed, or immediately when free disk is under 5 GB. Evidence:
the 3-of-6 over-split meetings (M-03) that could not be re-identified.

**Files you will change:** `Meetings/MeetingModels.swift` (`Meeting.audioReleaseAfter: Date?` —
**`decodeIfPresent` in `init(from:)`**); `Meetings/MeetingStore.swift` (`releaseAudioWhenDue(for:notesWritten:)`,
`sweepExpiredAudio(now:freeBytes:)`; `releaseAudio` unchanged and still the only method that
deletes); `Meetings/MeetingPipeline.swift` `finish` and `Meetings/NotesService.swift` (call
`releaseAudioWhenDue` instead of `releaseAudio`); the speaker sheet's "Done"/confirm action (calls
`releaseAudio` immediately); `Meetings/MeetingScheduler.swift` tick (sweep every 30 min and at
launch); `Meetings/MeetingSession.swift` `start` (skip the file under 1 GB free, set a visible
problem "Not enough disk space to keep a recording; the transcript is still being written.");
`Meetings/MeetingAudioWriter.swift` (stop writing after the first write error and report it once);
new `Meetings/AudioRetentionSelfTest.swift`; `AGENTS.md`; `Scripts/acceptance.sh`.

**Read for context (do not change):** `MeetingStore.releaseAudio` (`:300-326`) and its doc comment;
M-08's resume (a meeting being resumed must never be swept).

**Current behaviour:** see Why. This Mac has 3.3–4.2 GiB free (AGENT-OVERHAUL baseline; I2), so on
this Mac the 5 GB guard means today's behaviour continues until space is freed — say so in the
STATUS evidence.

**Target behaviour:**
1. Temporary audio (`audioIsTemporary == true`) at the end of the pipeline gets
   `audioReleaseAfter = now + 72 h` unless free space < 5 GB (then released now, as today).
2. The sweeper releases every temporary recording past `audioReleaseAfter`, and the oldest first
   while free space < 5 GB; never one whose meeting is active or has a diarization problem.
3. Kept recordings (`audioIsTemporary != true`) follow the unchanged rule.
4. Under 1 GB free at start, no audio file is created; M-01's pass then reports `live-only:no-audio`.

**Do not:** add a second deletion path (every delete goes through `releaseAudio`); read the settings
at release time to decide temporary vs kept (AGENTS.md: decided at start); sweep during a resume.

**Red-first self-test:** new `--selftest-audio-retention` (`AUDIO_RETENTION_OK` / `…_FAILED`), in
`MeetingStore.isolated()`: a finished temporary meeting keeps its file with `audioReleaseAfter ≈
now + 72 h` at 50 GB free (injected); the sweeper at now + 73 h deletes it; at 4 GB free it is
released immediately; a kept recording is untouched by the sweeper; an active meeting is never
swept; a meeting with a diarization problem is never swept; `MeetingSession`'s start decision under
0.5 GB free creates no file (pure function `shouldWriteAudio(keep:diarize:finalPass:freeBytes:)`).
Confirm RED: the first case finds the file already deleted.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-audio-retention 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/M-10-green.txt
Scripts/run-selftest.sh --selftest-meeting-resume
Scripts/run-selftest.sh --selftest-meeting-reconcile
```

**Success threshold:** `AUDIO_RETENTION_OK` (red first); `MEETING_RESUME_OK` unchanged.

**Risks & rollback:** More disk used for up to 72 h (≈ 230 MB per meeting-hour); the 5 GB guard
bounds it. Revert to roll back; a meeting with `audioReleaseAfter` set is then released by the old
path the next time its pipeline ends, and older builds ignore the field.

**Done when:**
- [ ] Retention field (`decodeIfPresent`), sweeper, speaker-confirm release, disk guards, writer error stop.
- [ ] `AUDIO_RETENTION_OK` (red first); regressions unchanged.
- [ ] AGENTS.md `:673-684` updated with the timing rule and the evidence.
- [ ] Flag in AGENTS.md and INTEGRATION (`"selftest-audio-retention|120"`).
- [ ] Committed as `M-10: …`.

---

### M-11 — One recording per real meeting: a call near a calendar event starts that event early, a hang-up ends it, and the overrun rule listens for speech

**Finding(s):** I2 #12, #17  **Effort:** 1.5 d  **Depends on:** M-02 (owner ids), M-06 (the call question UI)  **Unblocks:** none

**Why (what the user experiences today):** A call attaches to a calendar meeting only when that
meeting is already armed or recording (`MeetingScheduler.correlationWindows()`, `:450-460`), and
the default lead is 1 minute (`meetingLeadMinutes = 1` on this Mac). Joining 2–10 minutes early
therefore arms a separate ad-hoc question; at the scheduled start the calendar meeting finds a
session running and, 10 minutes after its end, is written off as "Another meeting was being
recorded when this one started" — a false failure row — while the recording carries the call's
title instead of the event's title and attendees that the notes prompt uses to resolve names. When
a call attaches to an armed calendar meeting that has not started, `.attach` does nothing until the
scheduled start. And a calendar recording ignores the hang-up: it records the room until 10 minutes
of silence or end + 5 minutes, and stops at end + 5 minutes even mid-sentence. Latent: no calendar
meeting has been recorded on this Mac.

AGENTS.md paragraph this task changes (`AGENTS.md:796-802`): "An armed meeting's `end` is the time
the calendar said… That is what the 'stop five minutes after the scheduled end' rule reads…". The
end time stays the calendar's; the rule that reads it becomes "stop at end + 5 min only if nobody
has spoken for 2 min, or when the covering call has ended; never later than end + 60 min".
Evidence: I2 #17 (a rule that cuts a meeting mid-sentence by design) and #12.

**Files you will change:** `Meetings/CallPolicy.swift` (pure `calendarMatch(for:at:events:)` and
`overrunDecision(now:end:lastSpeechAt:coveringCallEndedAt:)`); `Meetings/MeetingScheduler.swift`
(`answer` `:358`, `callChanged` `:337`, `stopFinishedMeeting` `:271-290`, `retire` `:417`);
`Meetings/MeetingModels.swift` (`Meeting.coveringCallID: String?` — **`decodeIfPresent`**);
`Meetings/CallDetector.swift` (`identity(of:)`, `:408`, from `private` to internal);
`NextNotesApp.swift` (`autoRecordDecisionFailures()` `:2333` or a new `calendarCallFailures()` under
`--selftest-calendar`); `AGENTS.md`.

**Read for context (do not change):** `CallPolicy.correlationWindow` (10 min, `:259`) and
`covers(_:at:)` (`:266-271`) — keep both; `MeetingScheduler.shouldAutoRecord` (`:562`),
`recordNow(_:)` (`:148`); `Calendar/FakeCalendarProvider.swift` (one event 90 s out,
attendees `["Test Attendee"]`); AGENTS.md "`--fake-calendar` replaces the real providers…" (a test
run must never arm a recording of an actual meeting).

**Target behaviour:**
1. When a call settles and no session is recording, `calendarMatch` looks at `calendar.upcoming`
   for a non-all-day event covering now ± `correlationWindow`. If one exists and
   `shouldAutoRecord(event)` is true, that event's meeting starts **now** (its title, attendees,
   calendar id) and `coveringCallID = CallDetector.identity(of: call)`; no ad-hoc question is raised.
   If the event exists but is not auto-record, its own armed question is raised now (M-06's card).
2. When the covering call ends, a recording with that `coveringCallID` stops after 60 s unless the
   same call comes back within the grace (the detector's debounce already absorbs flicker).
3. Overrun: stop a calendar recording at `end + 5 min` only if `now − lastSpeechAt ≥ 2 min` or the
   covering call has ended; stop unconditionally at `end + 60 min`. Detected calls keep their
   exemption; hand-started recordings still never auto-stop.
4. The false "Another meeting was being recorded" row is not written when the running session is
   the event's own meeting.

**Do not:** start a calendar meeting whose answer is "ask" without asking; apply any of this to
hand-started recordings; change `correlationWindow`, `armedGrace` or `silenceTimeout`; let
`--fake-calendar` join real providers.

**Red-first self-test:** extend `--selftest-calendar` (`CALENDAR_OK` / `…_FAILED`) with pure cases:
a call at event start − 6 min with an auto-record event → `.startCalendar(eventID)`; − 12 min →
`.none` (outside the window); a non-auto event → `.askCalendar(eventID)`; an all-day event →
`.none`. Overrun: end + 5 min with speech 30 s ago and the call live → keep; speech 3 min ago →
stop; call ended 61 s ago → stop; end + 60 min with speech → stop. Confirm RED: `calendarMatch`
returns `.none` and `overrunDecision` returns today's rule.
Owner-only smoke (an agent never launches the GUI): the owner starts the app with
`--fake-calendar` (a modifier, not a self-test, per AGENTS.md) and places a call within 90 s:
the "Fake meeting (--fake-calendar)" recording starts at once with attendee "Test Attendee" and
stops about a minute after hanging up.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-calendar 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/M-11-green.txt
Scripts/run-selftest.sh --selftest-calls
Scripts/run-selftest.sh --selftest-island
```

**Success threshold:** `CALENDAR_OK` with the new cases (red first); `CALLS_OK`, `ISLAND_OK` unchanged.

**Risks & rollback:** A call that merely happens near an unrelated auto-record event would be filed
under that event; the ±10 min window is the existing, documented correlation rule, now applied one
step earlier. Revert to roll back; `coveringCallID` is ignored by older builds.

**Done when:**
- [ ] Early start with the event's identity; hang-up stop with grace; speech-aware overrun with a 60-min ceiling.
- [ ] `coveringCallID` via `decodeIfPresent`.
- [ ] `CALENDAR_OK` (red first); AGENTS.md `:796-802` updated.
- [ ] Committed as `M-11: …`.

---

### M-14 — Live meeting understanding runs on speech time, reads the last 3 minutes, has its own switch, and never grants model text microphone authority

**Finding(s):** I2 #16  **Effort:** 1 d  **Depends on:** M-01 (not hard); AGENT-OVERHAUL **P0-14** (provider resolution — see Do not) and **P3-07a** (compute lanes; this task only reduces how often the model runs)  **Unblocks:** none

**Why (what the user experiences today):** `MeetingContextReconciler.shouldSchedule` fires on 8
finals **or** 45 s of speech (`Meetings/MeetingContextReconciler.swift:18-22,57-62`). Finals now
average ≈ 2 s and 23–33 % are under 1 s, so 8 finals arrive every 10–20 s and a model pass is
scheduled several times a minute, each seeing only the last 32 segments (≈ 1 minute) capped at
3,000 characters (`:171-173`, `maxTokens: 400` `:192`). The pass runs the **Agent's** model for
every meeting through `LLMProviders.resolve(preferring: Settings.shared.agentModelProvider …)`
(`:176-189`), with no switch of its own — if the Agent is on OpenRouter, live meeting text goes to
the cloud every few seconds with no meeting-specific consent. Topics it writes are tagged
`source: .mic` (`:218`, `:223`), the source that can authorise actions. 6C5E's `context.json` holds
the model topic "Parking lot", made from M-01's hallucinated English.
`MeetingContextStore.recentTranscript(minutes: 3)` is computed (`:218` of `MeetingContextStore.swift`)
and never read by the completer.

**Files you will change:** `Meetings/MeetingContextReconciler.swift` (`shouldSchedule`, the prompt,
the topic source); `Meetings/MeetingContextStore.swift` (`noteIngest` `:177-190`, `runReconcile`
`:203-230`: pass time-based text and track the last pass time); `Support/Settings.swift`
(`meetingLiveUnderstanding: Bool?`, nil = automatic); `UI/Settings/MeetingsSettingsTab.swift`
(toggle "Understand the meeting while it happens", footnote naming where it runs);
`Agent/AgentService.swift` / `Meetings/MeetingContextExtractor.swift` self-test cases.

**Target behaviour:**
1. A pass is scheduled only when ≥ 60 s of new speech has accumulated **and** ≥ 45 s have passed
   since the last pass (the finals count is removed).
2. The prompt carries the transcript of the last 3 minutes by time (`recentTranscript(minutes: 3)`),
   still capped at 3,000 characters from the end.
3. Automatic mode (`nil`): on when the resolved provider is on-device (`.appLLM`,
   `.appleFoundation`), off when it is a cloud or network provider. An explicit `true` with a cloud
   provider is the user's consent. `false` never runs it.
4. Model-written topics and unresolved items are tagged with the least-authority source
   (`.system`) and `confidence: "inferred"`, so they can never authorise execution.

**Do not:** add a compute lane here (P3-07a owns lanes); switch the provider resolution to
`ModelRoleStore` before P0-14 lands (then use the Agent role's provider through the role store);
add an `AudioSource` case (it is a transcript type used everywhere); change the candidate-action
quoting rule (`apply` accepts only candidates whose quoted evidence is in the transcript).

**Red-first self-test:** extend `--selftest-meeting-live` (`MEETING_LIVE_OK` / `…_FAILED`, CORE):
feed 2 min of 2 s finals (60 segments) through the cadence function with a clock → **≤ 3 passes**
(today ≥ 8); the prompt for a pass contains a segment from 2.5 min ago and none from 4 min ago;
automatic mode with an OpenRouter provider → no pass; a parsed model topic has source `.system`.
Confirm RED: the cadence case counts ≥ 8.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-meeting-live 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/M-14-green.txt
Scripts/run-selftest.sh --selftest-meeting-reconcile
Scripts/run-selftest.sh --selftest-meeting-reconcile-llm
Scripts/run-selftest.sh --selftest-meeting-live-tools
Scripts/run-selftest.sh --selftest-ui-strings
```

**Success threshold:** `MEETING_LIVE_OK` with the new cases (red first); the three reconcile/tool
flags end as in their last run.

**Risks & rollback:** Topics appear later in the live view (≥ 60 s of speech). Revert to roll back.

**Done when:**
- [ ] Speech-time cadence, 3-minute window, switch with cloud-off automatic mode, least-authority tagging.
- [ ] `MEETING_LIVE_OK` (red first); regressions unchanged.
- [ ] Committed as `M-14: …`.

---

### M-15 — Speaker identification on by default once its models are on disk; offered after the first multi-voice meeting

**Finding(s):** I2 #18  **Effort:** 0.5 d  **Depends on:** M-10 (temporary audio rules), M-03 (so the default produces good results)  **Unblocks:** none

**Why (what the user experiences today):** `meetingsDiarize` defaults to `false`
(`Support/Settings.swift:1032`). A fresh install labels every remote voice "Others", and the notes'
action items become Unassigned. The owner turned it on by hand. It is off because it needs a model
download and a temporary recording.

**Files you will change:** `Support/Settings.swift` (`meetingsDiarize` becomes `Bool?`-backed: an
explicit user choice wins; with no stored value the effective default is
`MeetingDiarizer.isDownloaded`); `UI/Meetings/MeetingDetailView.swift` (a one-time offer on a
finished meeting whose system track has speech while diarization is off: "Tell the other speakers
apart? This downloads a model and keeps a temporary recording until the notes are written." —
buttons "Turn On" / "Not Now"; "Turn On" starts `LocalModelStore.shared.prepareDiarizer()` and sets
the setting; "Not Now" stores the dismissal); the onboarding self-test.

**Do not:** start a download without the person pressing a button; change an explicit stored
`false`; use developer words in the offer ("diarization", "model id").

**Red-first self-test:** extend `--selftest-onboarding` (`ONBOARDING_OK` / `…_FAILED`) with pure
cases: no stored value + models on disk → on; no stored value + no models → off; stored `false` +
models → off; the offer shows once for a meeting with system speech and diarization off, and not
after "Not Now". Use an isolated `UserDefaults(suiteName:)`, never the user's domain. Confirm RED:
the first case is off.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-onboarding 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/M-15-green.txt
Scripts/run-selftest.sh --selftest-settings
Scripts/run-selftest.sh --selftest-ui-strings
```

**Success threshold:** `ONBOARDING_OK` (red first); `SETTINGS_OK`, `UI_STRINGS_OK` unchanged.

**Risks & rollback:** More disk while the temporary recording exists (M-10 bounds it). Revert.

**Done when:**
- [ ] Effective default follows the models; explicit choices respected; one-time offer.
- [ ] `ONBOARDING_OK` (red first).
- [ ] Committed as `M-15: …`.

---

### M-16b — Meeting model passes in the unified usage log (through AGENT-OVERHAUL P0-20b)

**Finding(s):** I2 #19 (model-pass half)  **Effort:** 0.5 d  **Depends on:** AGENT-OVERHAUL **P0-20a** and **P0-20b**; M-05 (the collapse pass type)  **Unblocks:** none

**Why:** Only a log line records which model wrote a meeting's notes, how many passes it took and
how long each ran, and it ages out within minutes. P0-20b is defined as the meetings leg of the
unified usage log. This task makes sure every meeting model pass reaches it and adds nothing
parallel.

**Steps:**
1. Read P0-20a/P0-20b as they landed (AGENT-OVERHAUL `STATUS.md` + `01-PHASE-0-MAKE-IT-ANSWER.md`).
   If P0-20b already wraps `NotesGenerator`'s single, map and reduce calls and the reconcile pass,
   this task only adds the **collapse** pass from M-05 (`pass: "collapse"`) and the final-pass
   *stage* link (the usage rows carry the meeting id as their correlation id, so they join the
   `meeting.*` spans from M-16a).
2. Otherwise wrap each call site through P0-20a's writer API, with the schema's field names
   (`feature: "meeting.notes"` / `"meeting.reconcile"`, `pass: "single" | "map" | "collapse" |
   "reduce" | "reconcile"`, `provider`, `modelID`, `ttftMs` (nil for non-streamed calls), `totalMs`,
   `errorClass`, and the meeting id as the correlation id).
3. No prompt, transcript, fact or note text in any row.

**Red-first self-test:** extend whichever flag P0-20b introduced for meetings (or
`--selftest-notes-longform`): the 90-min case writes exactly `chunks` map rows, `collapsedGroups`
collapse rows and one reduce row, all with the same correlation id, into the isolated store.

**Verify:** `make build && make install OPEN=0`, then that flag and `--selftest-metrics`.

**Success threshold:** the row counts match `Result.chunks` / `collapsedGroups` exactly.

**Done when:**
- [ ] Every meeting model pass writes one usage row through P0-20b; no second log exists
      (`grep -rn "jsonl" Sources/NextNotes/Meetings` finds none new).
- [ ] Committed as `M-16b: …`.

---

### M-16c — Debounced `transcript.json` writes

**Finding(s):** I2 #20  **Effort:** 0.5 d  **Depends on:** M-08 (crash resume uses the file; the test lives in its flag)  **Unblocks:** none

**Why:** `MeetingSession.add` rewrites the whole `transcript.json` on every segment
(`Meetings/MeetingSession.swift`, the `store.saveTranscript(segments, for: meeting.id)` inside
`add`). With 2–5 s windows a 2-hour meeting is ≈ 2,700 segments of files growing to ≈ 500 KB,
roughly 1 GB of writes (estimate, I2). The comment's crash-safety argument ("a two-hour meeting
that loses everything… at minute 118") still holds at a 5 s interval.

**Steps:** a `TranscriptSaveThrottle` (pure: `shouldWrite(now:lastWrite:pending:) -> Bool`, interval
5 s) in `MeetingSession`; `add` marks pending and writes when due; a trailing write is scheduled so
the last segment is on disk within 5 s; `stop()`, `endAbruptly()` and `abort` write unconditionally.
Update the comment in `add`.

**Do not:** lengthen the interval beyond 5 s; skip the write in `endAbruptly`.

**Red-first self-test:** extend `--selftest-meeting-resume`: 100 segments over 20 simulated seconds
→ ≤ 5 throttled writes plus the final one; after `endAbruptly()` the file holds all 100. Confirm RED:
100 writes.

**Verify:** `make build && make install OPEN=0`; `Scripts/run-selftest.sh --selftest-meeting-resume`;
`Scripts/run-selftest.sh --selftest-meeting-live`.

**Success threshold:** `MEETING_RESUME_OK` with the new case (red first).

**Done when:**
- [ ] Throttled writes with unconditional flushes on every exit path.
- [ ] Committed as `M-16c: …`.

---

## 3. Execution checklist for this file

Copy these rows into `STATUS.md` (the other agent owns that file's layout; use its columns):

| ID | Title | Depends on | Gate flag |
|---|---|---|---|
| M-16a | Quality probe, stage spans, fixtures, report | none | `--selftest-meeting-quality` |
| M-02 | Helper → owning app; answer migration; deny replayd | none | `--selftest-calls` |
| M-06 | Call question stays for the call | M-02 (soft) | `--selftest-island` |
| M-05 | Map-reduce never drops facts | M-16a | `--selftest-notes-longform` |
| M-01 | Long-window finals after Stop | M-16a | `--selftest-meeting-finals` |
| M-08 | Resume interrupted meetings; watchdog; Quit alert | M-01 | `--selftest-meeting-resume` |
| M-04 | Nearest-run / neighbour labels | M-16a | `--selftest-diarize-assign` |
| M-03 | Speaker-count hints, merge, identify again | M-04, M-10 (soft) | `--selftest-diarize-hints` |
| M-12 | Window-aware notes budgeting | M-05, P1-10a step 0 | `--selftest-notes-longform` |
| M-13 | Visible truncation, scaled cap | M-12, P0-17 (OpenRouter leg) | `--selftest-notes-truncation` |
| M-07 | Seconds-bounded, merging backlog | M-01, M-16a | `--selftest-meeting-backlog` |
| M-09 | Tap retry with correct timing | none (M-08 for the isolated store) | `--selftest-meeting-tap-retry` |
| M-10 | 72 h temporary audio, disk guards | M-08 | `--selftest-audio-retention` |
| M-11 | Calls unified with calendar; speech-aware overrun | M-02, M-06 | `--selftest-calendar` |
| M-14 | Live understanding on speech time, own switch | M-01 (soft), P0-14, P3-07a | `--selftest-meeting-live` |
| M-15 | Speaker identification on by default | M-10, M-03 | `--selftest-onboarding` |
| M-16b | Meeting passes in the usage log | P0-20a, P0-20b, M-05 | P0-20b's flag |
| M-16c | Debounced transcript writes | M-08 | `--selftest-meeting-resume` |
