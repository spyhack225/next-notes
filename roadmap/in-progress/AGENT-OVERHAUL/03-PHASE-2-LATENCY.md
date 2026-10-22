# Phase 2 — Latency (P2-01 … P2-08)

**Schema-probe producer, 2026-10-04:** original423 observes two validated
schema-version reads in each actual C03/F09 receipt path; unchanged fixed424
observes one, with only two TaskStore lines changed across1,141 compiler inputs.
The same transaction still checks complete schema, foreign keys, marker and file
identity; connection, synchronization and checkpoint behavior remain unchanged.
The duplicate-read assertions now pass. Both strict5ms targets still fail, so this
is a verified producer simplification, not latency closure. Original423's separate
legacy revision-worker budget failure is retained without scheduler attribution;
it occurs before the added observers and is absent in424. Related424 completes
20/22 PASS; strict5ms and actual ACP100ms fail (small117.090959ms,
history140.089459ms). All functional storage/authority/read-isolation checks pass;
no current full-suite or latency acceptance is claimed.
[Actual pair](../../../Tests/Reports/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/schema-probe423424-qualified-results.json).


## Current evidence — 2026-10-03

P2-01 is in progress: spans/usage joins exist, but measured warm first audio2.894s
still misses0.9s. Original cold duplicate-commit/stall acceptance and the missing
original WAV repeat remain open. P2-02…08 retain their uncompleted contracts;
related helper tests or shutdown/session work do not complete them. Prescribed
tts-pipeline/voice-duck/smart-turn exit flags have no matching Swift implementation/
dispatch references in the current audit. Implement the actual acceptance paths,
then measure the real producers; do not substitute helper markers or relax budgets.
See [the remaining checklist](REMAINING-WORK.md#latency-and-full-duplex) and STATUS.

## Implementation sequencing amendment — owner decision 2026-10-01

Read [README §4.1](00-README.md#41-implementation-eligibility-and-quality-gates--owner-decision-2026-10-01).
Implementation follows the task's actual contracts and isolated production-path
proof; an inherited aggregate quality failure does not block an independent
foundation. Required quick/full evaluations keep their real verdicts and bars.
Phase acceptance, model/default promotion and product-readiness claims remain
gated. This amendment changes entry sequencing, not implementation state.

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

Written 2026-09-23 against the working tree of that day. Source paths are relative to
`Sources/NextNotes/` unless they start with `Scripts/`, `roadmap/`, `Tests/` or `~`. Every
`file:line` below was re-opened and checked on 2026-09-23; the symbol name is given beside it
so you can `grep` for it if lines move. Numbers are **measured** (with their source) or
labelled **estimate**.

Evidence: `roadmap/done/agent-analysis-2026-09-23/A-latency.md` (hop-by-hop latency, the budget
table, the runs), `E-reference.md` §2.1 and §3 (Smart Turn), `C-concurrency.md` (scheduler),
and the decision document `roadmap/done/agent-analysis-2026-09-23/AGENT-QUALITY-ANALYSIS-2026-09-23.md` §3.1 (L1–L10),
§3.5 (where the reports disagree) and §5 (Phase 2 exit criteria).

---

## 0. Phase overview

### 0.1 What the user experiences today (measured baseline)

| Measure | Today | Source |
|---|---|---|
| End of speech → first audio, file-fed, warm, installed build | **3.10 s** (1.063 s speech end → endpoint + 2.033 s endpoint → first audio) | A §0, A §6 (run of 2026-09-23 17:34) |
| Same, 2026-09-14 builds 18–52 (6 runs) | 2.83–3.58 s | A §0 |
| Same, cold process (first run after install) | 10.4 s (EOU prepare 12.7 s, Pocket load 12.6 s, first PCM 6.0 s) | A §0 |
| Real sessions 2026-09-22, committed transcript → first model text (n=15) | median 1.81 s; range 0.03–8.76 s; **3 hard failures at ~2.0 s** ("The local voice model failed while preparing that response.") | A §0, Hop 8 |
| Turns overlapping a worker-model load | 3.2 s, 8.3 s, 8.8 s to first token | A Hop 8 |
| Barge-in: voice onset → playback paused | **0.838 s** today (0.835–0.961 s across builds) | A Hop 12 |
| Barge-in: stop operation itself | 4–15 ms (p50 12 ms, n=10) — not the problem | A Hop 12 |
| Main-actor pacing slip during a voice turn | 0.34–0.63 s today (0.02–0.07 s on 2026-09-14) | A Hop 11 |
| Gap between spoken sentences | 0.25–0.40 s per boundary (**estimate**; never measured) | A Hop 10 |

The 8–9 s outliers and the ~2.0 s failures are fixed by **P0-06** (worker warmup off the
voice lane, cancellable `ComputeScheduler.acquire`, drain timeout detaches), not by this
phase. This phase assumes P0-06 has landed; without it every number here is noise.

### 0.2 Per-hop budget (A §2) — current vs target, and which task owns it

Speech end → first audible syllable, warm, uncontended.

| # | Hop | Current (measured unless "est.") | Target | Owner |
|---|---|---|---|---|
| 1 | Capture batch + convert + Speex AEC | 63–71 ms (18 ms with `AVAudioSinkNode`) | 15–25 ms | P2-08 |
| 2 | Voice end → Parakeet EOU confirmed (160 ms chunk, 320 ms debounce) | 0.70–1.18 s (today 0.998 s) | 0.30–0.45 s | P2-04 (+ P2-03 starts work before it) |
| 3 | EOU → committed endpoint (100 ms VAD tick) | 9–106 ms | ≤ 5 ms | P0-10 (verified by P2-01) |
| 3b | Fallback endpoint (EOU silent / not ready) | 2.5 s, or 0.9 + 0.35 s | ≤ 0.6 s (with Smart Turn), ceiling 1.0 s | P2-04 |
| 4 | Coordinator gates + request build | < 10 ms (est.) | < 10 ms | — (P2-01 measures it) |
| 5 | Frontend route pass (structured, `collect()`) | 0.66–1.31 s | ≤ 0.25 s, or hidden by overlap | P2-02 |
| 6 | Answer session → first answer text | 0.85–1.17 s after the route | 0.25–0.40 s (prewarmed prefix) | P2-02 |
| 5+6 | Transcript → first model text | pipeline 1.07–2.51 s; real median 1.81 s | ≤ 0.40 s (≤ 0.60 s is the P2-02 gate) | P2-02, P2-03 |
| 7 | Worker-LLM contention / 2 s barrier | +0 to +7 s; 3/15 real turns failed | 0 | **P0-06** |
| 8 | First-clause buffering (`. ! ? ; —` only) | ~0–0.30 s | ≤ 0.10 s | P2-06 |
| 9 | Pocket first PCM | 0.21–0.28 s warm; 0.55 s cold session; 6.0 s cold process | 0.06–0.10 s | P2-06, P2-07 |
| 10 | Engine start + first 80 ms frame played (ack) | 0.097–0.118 s | 0.03–0.05 s | P2-06 |
| 11 | Device output latency | unmeasured (est. 10–30 ms) | same | — |
| | **Total** | 2.83–3.58 s; **3.10 s** today warm; 10.4 s cold | **≤ 0.9 s** | all |
| — | Gap between sentences | est. 0.25–0.40 s | ≤ 50 ms | P2-06 |
| — | Barge-in onset → duck | 0.84 s (to pause; no duck exists) | ≤ 0.20 s | P2-05 |
| — | EOU model prepare per session | 1.67–3.04 s warm; 9.1–12.7 s cold | 0 (resident) | P2-07 |
| — | Main-actor stall during a turn | 0.34–0.63 s | ≤ 0.10 s | P2-01 |

### 0.3 Targets (the phase exit numbers)

1. **≤ 0.9 s** end of speech → first audio, warm, **median over 5 runs** of
   `--selftest-voice-latency` on the haiku fixture (`voice.speech_end_to_first_audio`).
2. **≤ 200 ms** barge-in: user voice onset → output ducked (`voice.onset_to_duck`,
   `--selftest-voice-barge`).
3. **≤ 50 ms** inter-clause silence on a three-sentence reply (`--selftest-tts-pipeline`).
4. **≤ 100 ms** worst main-actor stall inside a voice turn (`--selftest-voice-latency`).

How the 0.9 s is reached (all **estimates**, to be replaced by P2-01's measurements):
speech end → endpoint 0.35–0.45 s (P2-04) + endpoint → first model text 0.0–0.2 s with a
speculation hit (P2-03) or 0.4–0.6 s without (P2-02) + first clause ≤ 0.10 s + first PCM
0.06–0.10 s + ack 0.03–0.05 s = **0.55–0.9 s with a hit, 1.0–1.3 s without**. The median
target therefore needs speculation to hit in at least 3 of 5 runs. P2-03 is on the critical
path, not an optional polish. The figure is file-fed and callback-based: true acoustic onset
(speaker → air → ear) is not measured by any test (A §5 item 4).

### 0.4 Task order

1. **P2-01 first.** Every later task is measured against the same spans, fixtures and
   self-test. Do not start another Phase 2 task until `--selftest-voice-latency` exists and
   prints a baseline you have written into STATUS.md.
2. **P2-07** (resident EOU + Pocket). Small, and it turns "cold/warm" noise into a stable
   warm baseline for everything after it.
3. **P2-02** (prewarmed frontend, one streamed decision). Largest single gain (−0.7 to −1.2 s,
   A §3 #2).
4. **P2-06** (TTS pipelining). Second item of the decision doc's "this week" list.
5. **P2-04** (Smart Turn arbiter, lower debounce and fallbacks).
6. **P2-03** (append-tolerant speculation). After P2-02 (shares `LocalVoiceFrontend`) and
   after P2-04 (its trigger interacts with the endpoint rules).
7. **P2-05** (VAD ducking barge-in).
8. **P2-08** (smaller I/O buffers). Last: it touches the capture hub that dictation and
   meetings also use, so it has the widest blast radius.

`Activation/AgentCaptureController.swift` is edited by P2-01, P2-03, P2-04, P2-05, P2-07 and
P2-08. Do them **one at a time in the order above**, rebuild and re-run the regression set
between them; never have two of these tasks open at once.

### 0.5 Dependencies

| Task | Phase 0 | Phase 1 | Phase 3 (downstream) |
|---|---|---|---|
| P2-01 | **P0-20a** (the unified usage log `usage.jsonl`: one `UsageRecord` per model pass; P2-01 writes each voice turn's headline stages onto a `pass: "turn"` row there, H-audit 2026-09-24). P0-06/P0-11 admission/isolation and P4-01 current-prompt contracts also precede this baseline. Early work keeps every usage-row assertion | none | every Phase 3 task reuses its spans |
| P2-02 | **P0-06** (frontend must not queue behind a warmup; drain timeout detaches) | P1-03 (the capability inventory text inside the frontend request comes from `AgentCapabilityManifest`; the staging key must be computed from the same text), P1-07 (the voice rebuttal hook must keep working in whichever decision mode is adopted) | P3-05 (receipt-first contract rewrites the frontend prompt: re-run P2-02's measurement after it), P3-07 (lanes) |
| P2-03 | P0-06 | P1-07 (pending-intent/rebuttal logic reads the committed text, never a speculated one) | P3-06 (VoiceSession owns TurnID; speculation keys move to TurnID) |
| P2-04 | **P0-10** (`tick(force:)` from `noteModelEOU`) | none | P3-06 (`SmartTurnArbiter` becomes an `InputProcessor` component) |
| P2-05 | none | none | P3-04, P3-06 (`Interruption.provisional` is introduced here and reused) |
| P2-06 | **P0-09** (280-character cap applied per clause) | none | P3-04 (`OutputScheduler` feeds the streaming backing added here; first-audible ack is the delivery ack) |
| P2-07 | none | none | P3-07 (residency of the second llama context) |
| P2-08 | none | none | none |

If a Phase 0 dependency is not marked done in `STATUS.md`, stop and do not start the task.

### 0.6 Shared conventions for this phase

**Fixtures (created by P2-01, used by every task).** All real-audio tests in this phase are
file-fed: the WAV enters the same `deliver` closure as live microphone audio
(`AgentCaptureController.startEngine`, `deliver` at AgentCaptureController.swift:687), so they
need **no** microphone grant and run with plain `Scripts/run-selftest.sh`. They are generated
with `say` + `afconvert`, exactly as A-latency did (A §6 used a 3.24 s Float32/16 kHz/mono
`haiku16k.wav` and `stop16k.wav`; those run logs, `pipeline-run2.txt` and `barge-run.txt`,
lived in the analysis session's scratchpad and are **not** in the repository — A §6 quotes
their numbers, and the relevant ones are repeated in this file).

| Fixture (in `~/Library/Caches/NextNotesBuild/voice-fixtures/`) | Spoken text | Used by |
|---|---|---|
| `haiku16k.wav` | "Hello there. Please tell me briefly what a haiku is." | P2-01 latency runs, `--selftest-voice-pipeline`, P2-02, P2-03, P2-06, P2-07 |
| `stop16k.wav` | "Wait, please stop speaking." | `--selftest-voice-barge`, `--selftest-voice-rapid` (second), P2-05 |
| `question16k.wav` | "What time is it in Tokyo right now?" | P2-04 (a finished question must not be held) |
| `pause-mid16k.wav` | "I want to book a table for [[slnc 900]] four people tomorrow evening." | P2-04 (a mid-sentence pause must not end the turn) |
| `pause-um16k.wav` | "So I was thinking we could [[slnc 700]] maybe move the meeting." | P2-04 |
| `nopause16k.wav` | "I want to book a table for four people tomorrow evening." | P2-04 (same sentence without the pause; also proves `[[slnc]]` worked) |

`[[slnc N]]` is the macOS speech synthesizer's embedded "silence for N ms" command. The
script verifies it took effect by checking the duration grew.

**Which tests need `--via-open`** (TCC grant, LaunchServices launch, never loop it):
`--selftest-microphone` / `--selftest-microphone-sink` (P2-08), `--selftest-dictation`
(regression for P2-08), `--selftest-acoustic-live`, `--selftest-voice-echo-live`,
`--selftest-voice-suspend-live`. **Everything else in this phase runs directly**, including
all file-fed voice tests, Pocket, Foundation Models, Silero VAD and Smart Turn.

**Models this phase loads.** Parakeet EOU (FluidAudio, `~/Library/Application Support/FluidAudio/Models/parakeet-eou-streaming`, 429 MB on disk, present), Pocket TTS (FluidAudio, `~/.cache/fluidaudio/Models/pocket-tts`, 433 MB, present), Silero VAD (FluidAudio, `~/Library/Application Support/FluidAudio/Models/silero-vad-coreml`; v6.0.0 is on disk but FluidAudio 0.15.6 asks for `silero-vad-unified-256ms-v6.2.1`, so its `ModelHub` fetches ~1 MB on first use), Smart Turn v3.2 CoreML (new, 16.8 MB, P2-04). Disk free on this Mac is ~4–6 GB: nothing in this phase may download a GGUF.

**Span vocabulary.** P2-01 defines `VoiceMark`s and `voice.*` span ids. Later tasks add marks
only through `VoiceLatencyTimeline.shared.mark(_:)`; they never invent a second clock.

### 0.7 Phase exit gate

All of the following, run in this order on an installed build (`make install OPEN=0`), each
in the foreground, one at a time:

```bash
Scripts/make-voice-fixtures.sh
Scripts/run-selftest.sh --selftest-voice-latency --voice-latency-runs 5 --voice-latency-budget 0.9 --selftest-timeout 600
Scripts/run-selftest.sh --selftest-voice-barge ~/Library/Caches/NextNotesBuild/voice-fixtures/stop16k.wav --voice-feed-10ms
Scripts/run-selftest.sh --selftest-voice-duck
Scripts/run-selftest.sh --selftest-tts-pipeline
Scripts/run-selftest.sh --selftest-smart-turn
Scripts/run-selftest.sh --selftest-voice-pipeline ~/Library/Caches/NextNotesBuild/voice-fixtures/haiku16k.wav --voice-feed-10ms
make acceptance TIER=core
```

Pass criteria: `VOICE_LATENCY_OK` with median `speech_end_to_first_audio` ≤ 0.900 s and
`main_stall_max` ≤ 0.100 s in every run; `VOICE_BARGE_OK` with `VOICE_BARGE_VOICE_TO_DUCK` ≤
0.200; `VOICE_DUCK_OK` (zero false ducks); `TTS_PIPELINE_OK` (max inter-clause silence ≤
0.050 s); `SMART_TURN_OK`; `VOICE_PIPELINE_OK` with `Voice speculation hit`; and
`make acceptance TIER=core` with no entry that was PASS before Phase 2 now FAIL. Then move
`--selftest-voice-latency` to the CORE tier with `--voice-latency-budget 0.9` (P2-01 step 12)
and write the before/after table (§0.2 columns, "today" vs "after") into `STATUS.md`.

---

### P2-01 — Per-stage voice latency spans, `--selftest-voice-latency`, and the main-actor stall

**Current-source audit, 2026-10-01:** `VoiceLatencyTimeline`, `MainActorStallProbe`,
`VoiceLatencySelfTest` and the app flag registration already exist, with capture
call sites. The todo row is not proof that these are absent. Start by auditing
those production callers, current fixture/isolation behavior and prior evidence,
then rebaseline the existing flag. Reuse the instrumentation; do not add a second
timeline, usage record or duplicate flag. No new latency result is claimed by
this documentation audit.

**Finding(s):** L10, L9, G N8 (extends P0-20's record)  **Effort:** 2 days (1 d instrumentation + self-test, 1 d stall attribution and fix)  **Depends on:** P0-06 (admission contract), P0-11 (isolated stores), P4-01 (current-prompt baseline), P0-20a (one `UsageRecord` row per model call in `usage.jsonl`: provider, model, feature, pass, tokens, first-token and total time; this task adds the per-stage voice spans around it, writes one per-turn summary row to the same log, and must not create a parallel "which model" field — H-audit 2026-09-24: P0-20 was widened from a `metrics.jsonl` span to the usage log)  **Unblocks:** P2-02, P2-03, P2-04, P2-05, P2-06, P2-07, P2-08 (all are measured with it)

**Why (what the user experiences today):** Nobody can say where a voice turn's three seconds
go on a real session: only two voice spans persist (`agent.transcript_to_first_token`,
`agent.first_token_to_first_tts`), voice, typed and worker rows share one name, and the split
timings exist only as `SelfTest.diagnostic` lines under `--selftest-voice-pipeline`. The
unified log had already aged out the voice lines when A-latency looked (A §6). Separately, the
main actor is now blocked for up to half a second during a turn: the file feeder's pacing slip
(`VOICE_FILE_MAX_PACING_LAG`, printed by `feedFile` at AgentCaptureController.swift:824) was **0.500 s** and **0.633 s** in the 2026-09-23 pipeline runs and
**0.340 s** in the barge run, against 0.023–0.067 s on 2026-09-14 (A Hop 11). Any such stall
delays the endpoint, clause enqueue and frame scheduling by the same amount.

**Files you will change:**
- `Support/LatencyTrace.swift` — new `LatencySpanID` cases, optional `source` field on `LatencySpan`, `persist` mirrors spans for the new self-test.
- `Support/MetricsStore.swift` — off-main writer (`recordAsync`).
- **new** `Agent/Voice/VoiceLatencyTimeline.swift` — `VoiceMark`, per-turn marks, span emission.
- **new** `Agent/Voice/MainActorStallProbe.swift` — lateness probe + `MainActorSection` site labels + `OSSignposter`.
- **new** `Agent/Voice/VoiceLatencySelfTest.swift` — `--selftest-voice-latency`.
- `Activation/AgentCaptureController.swift` — stamps (listed below), `beginFileSession` sets file-fed ownership of voice marks.
- `Agent/VoiceConversationCoordinator.swift` — stamps, `source` tag, `frontend_unavailable` sub-reason.
- `Formatting/LLM/LocalVoiceFrontend.swift` — stamps, speculation hit/miss marker.
- `Agent/RealtimeAgent+ToolLoop.swift` — first-token stamp in `AgentToolSpeechTracker.receive` (one line; Phase 1 owns the rest of this file).
- `Agent/RealtimeAgent.swift` — `source` tag on the typed/worker `agentTranscriptToFirstToken` trace; wrap `AgentSession.save` call sites in `MainActorSection`.
- `Agent/Speech/StreamingSpeechBuffer.swift`, `Agent/Speech/AgentSpeechSynthesizer.swift`, `Agent/Speech/PocketAgentVoice.swift`, `Agent/RealtimeAudioSession.swift`, `Agent/Speech/VoicePlaybackReference.swift` — stamps and (if attributed) stall fixes.
- `NextNotesApp.swift` — register `--selftest-voice-latency`.
- **new** `Scripts/make-voice-fixtures.sh`; `Scripts/acceptance.sh` (EXPERIMENTAL entry); `AGENTS.md` (flag list + a paragraph on the spans).

**Read for context (do not change):** `roadmap/done/agent-analysis-2026-09-23/A-latency.md` §1–§2, §5, §6; `Activation/AgentCaptureController.swift` `runVoicePipelineSelfTest` (:1456) and `runVoiceBargeSelfTest` (:1533) — the new test is built from the same pieces; `NextNotesApp.swift` `SelfTest` (:62–160) for `value(after:)`, `diagnostic`, `timeout`.

**Current behaviour:**
- `LatencySpanID` (Support/LatencyTrace.swift:11–106) has agent cases `agentSpeechEndToTranscript`, `agentTranscriptToFirstToken`, `agentFirstTokenToFirstTTS`, `agentBargeInToTTSStopped`, … Only these call sites exist for voice: `LatencyTrace.start(.agentTranscriptToFirstToken)` at VoiceConversationCoordinator.swift:426 (voice) and RealtimeAgent.swift:226 (typed/worker — same name), `LatencyTrace.start(.agentFirstTokenToFirstTTS)` at RealtimeAgent.swift:772 (`beginFirstTTSTrace`), `LatencyTrace.record(.agentBargeInToTTSStopped, …)` at RealtimeAgent.swift:60 and :434. `agentSpeechEndToTranscript` has **no** call site.
- `LatencyTrace.persist` (LatencyTrace.swift:321) calls `MetricsStore.record` synchronously on whatever actor ended the span — usually the main actor. `MetricsStore.record` (MetricsStore.swift:47–59) JSON-encodes and opens/seeks/writes/closes `metrics.jsonl` under a lock, and every ~1,024 lines rewrites the whole file (`rewriteLockedContents`, :110). `LatencySpan.init` also samples `ProcessSnapshot.current()` (`task_info` + `getrusage`). Under a self-test the store lives in a temp dir (MetricsStore.swift:13–16), so self-tests never touch the user's `metrics.jsonl`.
- Per-stage timing exists only as diagnostics: `VOICE_MODEL_EOU=sinceVoiceEnd …` (AgentCaptureController.swift:1016–1024), `VOICE_MODEL_EOU_TO_ENDPOINT` (:1295), `VOICE_FRONTEND_TIMING … event=typed_route_collect_done / first_answer_text` (LocalVoiceFrontend.swift:329–340, 506, 586), `Pocket TTS first PCM` / `first played` (PocketAgentVoice.swift:203–207, 268–271), `VOICE_PIPELINE_VOICE_TO_ENDPOINT` and `…ENDPOINT_TO_FIRST_AUDIO` (AgentCaptureController.swift:1516–1521). All are gated on `--selftest-voice-pipeline`.
- `frontend_unavailable` folds three causes: `LocalVoiceFrontend.FrontendError.unavailable(String)` carries the reason ("Previous voice inference did not stop.", Apple's availability string, "native_history_missing_latest_user", "split_route_missing_latest_user", "split_answer_missing_latest_user"), but `VoiceConversationCoordinator.errorCode(for:)` maps every one of them to `"frontend_unavailable"` (VoiceConversationCoordinator.swift:600).
- Main-actor work during a turn (every item is `@MainActor`): the Apple ASR consumer loop (`startEngine`, AgentCaptureController.swift:461–503, including echo masking through `RealtimeAudioSession.userSpeechExcludingPlayback`, RealtimeAudioSession.swift:188–283); a `Task { @MainActor }` per capture batch for levels (:703–711) and per Parakeet partial/EOU (:1071–1091); `IslandState.shared.showAgentListening(…)` on every level update (:912) and ASR result (:496); the Pocket frame loop and one main-actor hop per played frame (PocketAgentVoice.swift:189–234, 215–218); `VoicePlaybackReference.stopped()` doing `lane.sync` (VoicePlaybackReference.swift:34) from `PocketSpeechBacking.stop` (:242) and `finishIfDrained` (:288); `AgentSession.updateSpeech` (RealtimeAgent.swift:1134) and `AgentSession.append` (:1199) re-encoding and atomically writing the whole conversation file per clause event and per row (production only — under a self-test `AgentSession.shared` has no file); SwiftUI rendering of the island, which since 2026-09-21/23 wears the animated agent avatar (`AgentAvatarView` in UI/Island/IslandView.swift:534). The stall grew between 2026-09-14 and 2026-09-23; the avatar landed in that window. **That is a hypothesis, not a finding** — attribute before fixing.

**Target behaviour:**
1. Every voice turn (live or file-fed) writes one `voice.*` span per stage to `metrics.jsonl` (off the main actor), tagged with the session id and turn number, so a real session can be analysed from the file alone.
2. `agent.transcript_to_first_token` rows carry `source` = `voice` | `text` | `worker`.
3. `frontend_unavailable` failures are logged and audited with a sub-reason: `barrier_timeout`, `apple_unavailable`, `missing_latest_user`.
4. `--selftest-voice-latency` runs one warm-up turn plus N measured turns through the production pipeline, prints a per-run span table and medians, and fails when any required span is missing, when the main actor stalled more than 100 ms inside any measured turn, or (when a budget is passed) when the median exceeds it.
5. The main-actor stall is attributed to a named site (Instruments and/or the in-app probe) and fixed so the worst stall inside a turn is ≤ 100 ms.

**Steps:**

1. **Fixture script.** Create `Scripts/make-voice-fixtures.sh` (executable, `set -euo pipefail`):
   ```bash
   #!/usr/bin/env bash
   # Generates the file-fed voice fixtures used by the Phase 2 self-tests.
   # Float32 / 16 kHz / mono WAV, the format --selftest-voice-pipeline was measured with.
   set -euo pipefail
   DIR=${1:-"$HOME/Library/Caches/NextNotesBuild/voice-fixtures"}
   mkdir -p "$DIR"
   duration() { afinfo "$1" | awk '/estimated duration/ {print $3}'; }
   make_fixture() { # name text
     say -o "$DIR/$1.aiff" "$2"
     afconvert -f WAVE -d LEF32@16000 -c 1 "$DIR/$1.aiff" "$DIR/$1.wav"
     rm -f "$DIR/$1.aiff"
     echo "$1.wav $(duration "$DIR/$1.wav")s"
   }
   make_fixture haiku16k     "Hello there. Please tell me briefly what a haiku is."
   make_fixture stop16k      "Wait, please stop speaking."
   make_fixture question16k  "What time is it in Tokyo right now?"
   make_fixture pause-mid16k "I want to book a table for [[slnc 900]] four people tomorrow evening."
   make_fixture pause-um16k  "So I was thinking we could [[slnc 700]] maybe move the meeting."
   make_fixture nopause16k   "I want to book a table for four people tomorrow evening."
   # [[slnc]] must have produced real silence: pause-mid must be >= 0.7 s longer than nopause.
   awk -v a="$(duration "$DIR/pause-mid16k.wav")" -v b="$(duration "$DIR/nopause16k.wav")" \
     'BEGIN { if (a - b < 0.7) { print "error: [[slnc]] ignored by this voice"; exit 1 } }'
   ```
   Output lands outside the iCloud-synced repo on purpose. Record the voice used (`say -v '?' | head -1` is not the default; the default is whatever System Settings › Spoken Content says) in STATUS.md next to the baseline.

2. **Span ids.** In `LatencySpanID` add, all with `pipeline == .agent` (extend the `pipeline` switch) and no `target`:
   ```swift
   case voiceSpeechEndToEOU        = "voice.speech_end_to_eou"
   case voiceEOUHop                = "voice.eou_hop"              // FluidAudio callback → main actor
   case voiceEOUToEndpoint         = "voice.eou_to_endpoint"
   case voiceSpeechEndToEndpoint   = "voice.speech_end_to_endpoint"
   case voiceEndpointToRequest     = "voice.endpoint_to_request"
   case voiceRequestToLane         = "voice.request_to_lane"      // ComputeScheduler wait
   case voiceRoute                 = "voice.route"
   case voiceRouteToFirstToken     = "voice.route_to_first_token"
   case voiceTranscriptToFirstToken = "voice.transcript_to_first_token"
   case voiceFirstTokenToClause    = "voice.first_token_to_clause"
   case voiceClauseToFirstPCM      = "voice.clause_to_first_pcm"
   case voiceFirstPCMToAudible     = "voice.first_pcm_to_audible"
   case voiceSpeechEndToFirstAudio = "voice.speech_end_to_first_audio" // headline
   case voiceOnsetToDuck           = "voice.onset_to_duck"        // P2-05 fills it
   case voiceOnsetToPause          = "voice.onset_to_pause"
   case voiceOnsetToStop           = "voice.onset_to_stop"
   case voiceInterClauseGap        = "voice.inter_clause_gap"     // P2-06 fills it
   case voiceSpeculation           = "voice.speculation"          // marker, 0 s; note hit/miss
   case voiceMainActorStall        = "voice.main_actor_stall"     // max lateness in the turn
   case voiceFrontendUnavailable   = "voice.frontend_unavailable" // marker, 0 s; note sub-reason
   case voiceEOUPrepare            = "voice.eou_prepare"          // per session; P2-07 drives it to 0
   ```
   `LatencyTrace.runSelfTest` already fails on duplicate raw values; keep it green.

3. **`source` field.** (Rewritten, H-audit 2026-09-24.) P0-20a does **not** add a model field to `LatencySpan`; the
   per-pass record lives in `usage.jsonl` (`UsageRecord`, features `agent.voice` / `agent.typed` / `agent.worker`).
   Use `voice` / `text` / `worker` for `source`, and in `--selftest-voice-latency` assert that each counted run's
   `agent.voice` usage rows (`frontend-route` / `frontend-answer`, read from `UsageLog.shared`, a temp directory
   under the harness) share the voice turn's `turnID`. Do not add a provider or model field to `LatencySpan`. Add `var source: String?` to `LatencySpan` (optional ⇒ synthesized `Codable` uses `decodeIfPresent`, so old rows still decode — `--selftest-metrics` has a legacy-row check; extend it with a row lacking `source`). Add a `source:` parameter (default `nil`) to `LatencyTrace.end`, `LatencyTrace.record`, and `LatencySpan.init`. Pass `"voice"` at VoiceConversationCoordinator.swift:426 (via `AgentToolSpeechTracker`'s `finishPendingFirstTokenTrace` / `receive` path: store the source on the tracker) and `"text"` / `"worker"` at RealtimeAgent.swift:226 (`isVoiceWorker ? "worker" : "text"`).

4. **Off-main metrics writer.** In `MetricsStore` add `private let writer = DispatchQueue(label: "ai.pivotstudio.nextnotes.metrics", qos: .utility)` and `func recordAsync(_ span: LatencySpan) { writer.async { self.record(span) } }`. Change `LatencyTrace.persist` to call `store.recordAsync(span)` and keep returning the span. Keep `record` synchronous for `runSelfTest` (it reads back immediately) — add `func flushForTesting() { writer.sync {} }` and call it in `runSelfTest` before reading the file. Also move `ProcessSnapshot.current()` out of the caller: `LatencySpan.init` keeps its default, but `persist` builds the snapshot inside the writer block when the caller passed none (add an init parameter `process: ProcessSnapshot? = nil` and fill it on the writer queue).

5. **`VoiceLatencyTimeline`** (new file `Agent/Voice/VoiceLatencyTimeline.swift`). Not `@MainActor`; `final class … @unchecked Sendable` with an `NSLock`; every method O(1) and callable from the capture lane, FluidAudio's callback thread, any actor, or the main actor.
   ```swift
   enum VoiceMark: String, CaseIterable, Sendable {
       case voiceOnset = "voice_onset", lastVoice = "last_voice", asrFirstPartial = "asr_first_partial"
       case eouRaw = "eou_raw", eouCallback = "eou_callback", eouConfirmed = "eou_confirmed"
       case smartTurn = "smart_turn", endpoint = "endpoint", frontendRequest = "frontend_request"
       case schedulerAcquired = "scheduler_acquired", routeDone = "route_done"
       case frontendFirstToken = "frontend_first_token", firstClauseEnqueued = "first_clause_enqueued"
       case ttsFirstPCM = "tts_first_pcm", firstAudible = "first_audible"
       case bargeOnset = "barge_onset", bargeDuck = "barge_duck", bargePause = "barge_pause", bargeStop = "barge_stop"
   }
   final class VoiceLatencyTimeline: @unchecked Sendable {
       static let shared = VoiceLatencyTimeline()
       struct ClosedTurn: Sendable { let number: Int; let sessionID: UUID?; let marks: [VoiceMark: UInt64]
                                     let notes: [String: String]; let maxStallNanos: UInt64; let stallSite: String? }
       static func nowNanos() -> UInt64            // clock_gettime_nsec_np(CLOCK_UPTIME_RAW), same clock as LatencyTrace
       static func nanos(hostTime: UInt64) -> UInt64 // AVAudioTime.seconds(forHostTime:) * 1e9 — for captureHostTime
       func beginSession(_ id: UUID)                // resets turn counter; closes any open turn as "session_end"
       func mark(_ m: VoiceMark, at nanos: UInt64 = nowNanos(), overwrite: Bool = false)
       func note(_ key: String, _ value: String)   // e.g. "speculation" = "hit headstart=0.843"
       func noteStall(nanos: UInt64, site: String?) // keeps the max for the open turn
       func discardTurn()                            // tick() discarded the input: forget marks, no spans
       func closeTurn(reason: String)                // emits spans (step 6) and moves to closedTurnsForTesting
       var fileFedOwnsVoiceMarks: Bool { get set }   // see step 7
       func closedTurnsForTesting() -> [ClosedTurn]; func resetForTesting()
   }
   ```
   Rules: `voiceOnset` opens a turn when none is open (turn number = previous + 1) and, if `RealtimeAudioSession.shared.isSpeaking` was true at that moment (pass it as a parameter from the caller — the timeline must not touch main-actor state), also stamps `bargeOnset`. `lastVoice` is the only mark written with `overwrite: true`, and it stops moving once `endpoint` exists. Every other mark keeps its **first** value. `firstAudible` closes the turn (`reason: "first_audio"`); an open turn is also closed by the next `beginSession`, by `endSession` (`"session_end"`), or discarded by `discardTurn()`. Marks that arrive while no turn is open are ignored, except barge marks, which attach to the most recently closed turn if it closed < 30 s ago (a barge interrupts the previous reply) — keep a `lastClosed` slot for that and emit barge spans when `bargeStop` arrives.

6. **Span emission** (`closeTurn`, then `MetricsStore.shared.recordAsync` for each): for each row whose both marks exist, emit a span with `startedAt/endedAt` converted from the monotonic marks, `durationSeconds = (to − from) / 1e9`, `correlation = LatencyCorrelation(sessionID:, workID: nil, revision: turnNumber)`, `source: "voice"`, `note` = the turn's notes joined as `k=v` pairs. If a computed duration is negative (a speculated stage finished before the endpoint), emit `0` and add `note += " speculated"`.

   | Span | from → to | Required in `--selftest-voice-latency` |
   |---|---|---|
   | `voice.speech_end_to_eou` | lastVoice → eouConfirmed | yes |
   | `voice.eou_hop` | eouCallback → eouConfirmed | yes |
   | `voice.eou_to_endpoint` | eouConfirmed → endpoint | yes |
   | `voice.speech_end_to_endpoint` | lastVoice → endpoint | yes |
   | `voice.endpoint_to_request` | endpoint → frontendRequest | yes |
   | `voice.request_to_lane` | frontendRequest → schedulerAcquired | unless speculation hit |
   | `voice.route` | schedulerAcquired → routeDone | unless speculation hit or single-decision mode (P2-02) |
   | `voice.route_to_first_token` | routeDone → frontendFirstToken | same as above |
   | `voice.transcript_to_first_token` | endpoint → frontendFirstToken | yes |
   | `voice.first_token_to_clause` | frontendFirstToken → firstClauseEnqueued | yes |
   | `voice.clause_to_first_pcm` | firstClauseEnqueued → ttsFirstPCM | yes (Pocket) |
   | `voice.first_pcm_to_audible` | ttsFirstPCM → firstAudible | yes (Pocket) |
   | `voice.speech_end_to_first_audio` | lastVoice → firstAudible | **yes (headline)** |
   | `voice.onset_to_duck` / `_pause` / `_stop` | bargeOnset → bargeDuck / bargePause / bargeStop | only in barge tests |
   | `voice.main_actor_stall` | duration = max lateness observed while the turn was open; note `site=` | yes |
   | `voice.speculation` | marker (0 s), note `hit headstart=S` or `miss reason=no-slot|mismatch|cancelled` | yes |

6b. **One per-turn row in the usage log** (H-audit 2026-09-24; the owner asked for one persistent sink). In
   `closeTurn`, after the spans, write one `UsageRecord` with `feature: "agent.voice"`, `pass: "turn"`, the turn's
   `turnID` and `conversationID`, `totalMs` = `speech_end_to_first_audio`, `ttftMs` = `transcript_to_first_token`,
   and `stages` = the headline durations `speech_end_to_endpoint`, `transcript_to_first_token`,
   `first_token_to_clause`, `clause_to_first_pcm`, `speech_end_to_first_audio`, `main_actor_stall` (seconds), plus
   `counts["speculationHit"]` 0/1. `metrics.jsonl` keeps every stage span (it is a ~31-hour ring, measured
   2026-09-24); `usage.jsonl` keeps the per-turn summary for weeks (`--usage-report` reads it).

7. **Stamp sites** (call `VoiceLatencyTimeline.shared.mark(…)`; each is one line):
   - `voiceOnset` / `lastVoice`, live mic: in the `deliver` closure (AgentCaptureController.swift:687–711) right after `let cleanedLevel = Self.cleanedMicLevel(cleaned.buffer)` (:702): if `!timeline.fileFedOwnsVoiceMarks && cleanedLevel >= Limits.speechLevel`, stamp `voiceOnset` (first) and `lastVoice` (overwrite) at `chunk.captureHostTime` converted with `nanos(hostTime:)` when present, else `nowNanos()`. `Limits.speechLevel` is `nonisolated`-safe (a `static let` in a nested enum of a `@MainActor` class — if the compiler objects, copy the constant into the timeline as `static let speechLevel: Float = 0.06` with a comment pointing at `Limits.speechLevel`). Pass `isSpeaking` for the barge rule by reading an atomic mirror: add `nonisolated(unsafe) static var outputActiveHint = false` guarded by a lock in `VoiceLatencyTimeline`, set from `RealtimeAudioSession` when `isSpeaking` changes (a `didSet`).
   - `voiceOnset` / `lastVoice`, file-fed: `beginFileSession` (AgentCaptureController.swift:298) sets `timeline.fileFedOwnsVoiceMarks = true` (and `endSession` sets it false); `feedFile` stamps both where it already sets `fileFirstVoiceAt` / `fileLastVoiceAt` (:797–798). This keeps `voice.speech_end_to_endpoint` identical in meaning to today's `VOICE_PIPELINE_VOICE_TO_ENDPOINT` (source level, not cleaned level).
   - `asrFirstPartial`: in the Apple consumer loop when `userTurn` first becomes non-empty (:463–503) and in `noteModelPartial` (:1027) — first one wins.
   - `eouCallback`: inside the closure returned by `makeEOUCallback` (:1071), **before** `Task { @MainActor in`.
   - `eouConfirmed`: in `noteModelEOU` next to `modelEOUAt = Date()` (:1010).
   - `endpoint`: first line of `emitTurn` (:1285); also add `note("endpoint_source", source.rawValue)`. On every discard branch in `tick` (:1195–1250) call `timeline.discardTurn()`.
   - `frontendRequest`: VoiceConversationCoordinator.swift, immediately before `let tracker = AgentToolSpeechTracker(…)` (:425).
   - `schedulerAcquired`: LocalVoiceFrontend.swift right after `let jobID = await ComputeScheduler.shared.acquire(.realtimeAgent)` in `unsharedStream` (:388). Speculative generations (`timing.revision` belongs to a speculation) stamp it too; the "first wins" rule plus the negative-duration rule in step 6 make that honest.
   - `routeDone`: after `let routeResponse = try await routeStream.collect()` (:505).
   - `frontendFirstToken`: `AgentToolSpeechTracker.receive` (RealtimeAgent+ToolLoop.swift:109–111), where `firstTokenTrace` is ended.
   - `firstClauseEnqueued`: `StreamingSpeechBuffer.flush`, before the first `synthesizer.enqueueClause(clause)` of a reply (:90).
   - `ttsFirstPCM`: `PocketSpeechBacking.speak` where `firstProducedAt` is first set (PocketAgentVoice.swift:199–208). For the Apple and Kokoro backings there is no PCM mark; `--selftest-voice-latency` therefore requires Pocket (step 9).
   - `firstAudible`: `AgentSpeechSynthesizer.didBeginAudio` (:317) when it emits `.startAcknowledged` — backend-agnostic; closes the turn.
   - `bargePause`: `RealtimeAudioSession.pauseForListening` where `lastListeningPauseAt = Date()` (:403). `bargeStop`: `RealtimeAudioSession.noteUserSpeech` (:435) when `wasSpeaking`.
   - Speculation marker: `LocalVoiceFrontend.stream` (:280–310): on hit `note("speculation", "hit headstart=%.3f")`; on miss `note("speculation", "miss reason=mismatch")` / `"miss reason=no-slot"`.
   - `voiceEOUPrepare`: `LatencyTrace.record(.voiceEOUPrepare, seconds:, source: "voice")` where `VOICE_EOU_PREPARE` is printed today (AgentCaptureController.swift:535, inside the `MainActor.run` after `detector.prepare`) — but for **every** session, not only file-fed ones.
   - `frontend_unavailable` sub-reason: in `VoiceConversationCoordinator.errorCode(for:)` (:596–606) return `"frontend_unavailable:barrier_timeout"` when the associated string is `"Previous voice inference did not stop."`, `"frontend_unavailable:missing_latest_user"` when it contains `missing_latest_user`, else `"frontend_unavailable:apple_unavailable"`; record a `voice.frontend_unavailable` marker with that note. Grep for consumers of the literal `"frontend_unavailable"` first (`grep -rn '"frontend_unavailable"' Sources/`) and switch them to `hasPrefix`.

8. **Main-actor stall probe** (new `Agent/Voice/MainActorStallProbe.swift`):
   ```swift
   final class MainActorStallProbe: @unchecked Sendable {
       static let shared = MainActorStallProbe()
       func start(interval: Duration = .milliseconds(10))  // DispatchSourceTimer on a .userInteractive queue
       func stop()
       func maxLatenessSeconds(since nanos: UInt64) -> (seconds: Double, site: String?, atNanos: UInt64)
   }
   enum MainActorSection {
       /// Labels main-actor work so a stall can be attributed without Instruments.
       @MainActor static func run<T>(_ site: StaticString, _ body: () throws -> T) rethrows -> T
   }
   ```
   The timer fires every 10 ms; if no ping is outstanding it records `sent = nowNanos()` and does `DispatchQueue.main.async { lateness = nowNanos() - sent; … }` (never `Task { @MainActor }` — that would itself queue behind cooperative work; and never `MainActor.assumeIsolated`, which crashes the process, AGENTS.md). When a ping lands late by > 16 ms, store the lateness, the landing time, and the **site label that was active when the ping was sent** (an atomic `currentSite` that `MainActorSection.run` sets on entry and clears on exit), and call `VoiceLatencyTimeline.shared.noteStall(nanos:site:)`. `MainActorSection.run` also opens an `OSSignposter(subsystem: "ai.pivotstudio.nextnotes", category: "voice")` interval named by `site` so Instruments shows the same labels. The probe runs only while a voice session is open (`AgentCaptureController.beginSession` / `endSession`) — it costs one main-queue block per 10 ms.
   Wrap these candidate sites (one wrapper each, no behaviour change): the Apple ASR loop body (AgentCaptureController.swift:464–502) as `"asr.apple"`; `noteModelPartial` / `noteModelEOU` bodies as `"asr.local"`; each `IslandState.shared.showAgentListening` call in the capture controller as `"island.listening"`; the per-frame body in `PocketSpeechBacking.speak` (:196–219) as `"tts.frame"`; `framePlayed` as `"tts.played"`; `VoicePlaybackReference.stopped()` callers as `"echo.stopped"`; `AgentSession.updateSpeech` (:1134) and `AgentSession.append` (:1199) as `"session.save"`; `RealtimeAudioSession.userSpeechExcludingPlayback` (:188, :202) as `"echo.mask"`. Label SwiftUI rendering by exclusion: a stall whose site is nil while the island is visible is reported as `site=unlabelled` (likely rendering — confirm with Instruments).

9. **`--selftest-voice-latency`** (new `Agent/Voice/VoiceLatencySelfTest.swift`, `@MainActor enum VoiceLatencySelfTest { static func run() async -> Bool }`). Arguments (all optional; read with `SelfTest.value(after:)` so a flag is never taken as a value):
   `--voice-latency-fixture <wav>` (default `~/Library/Caches/NextNotesBuild/voice-fixtures/haiku16k.wav`), `--voice-latency-runs <n>` (default 5), `--voice-latency-budget <seconds>` (default none), `--voice-latency-max-stall <seconds>` (default 0.100), `--voice-latency-start-delay <seconds>` (default 0; prints `VOICE_LATENCY_PID=<pid>` then sleeps, for attaching `xctrace`), `--voice-latency-island off` (self-test-only switch; see step 10), `--voice-no-speculation` (P2-02 uses it to measure without speculation).
   Procedure:
   - Preconditions, each printing `VOICE_LATENCY_ABSENT: <reason>` as the **last** line and returning `false` without running: fixture missing ("run Scripts/make-voice-fixtures.sh"); `FoundationModelFormatter.unavailableReason != nil`; Pocket model directory absent (resolve the path FluidAudio's `PocketTtsModelStore` uses — `~/.cache/fluidaudio/Models/pocket-tts` on this Mac — and never trigger a download from a self-test). `SelfTest.failed` stays false for ABSENT; the acceptance runner classifies it as SKIP.
   - Force Pocket without touching the user's settings: add `var engineOverrideForTesting: String?` to `AgentSpeechSynthesizer`, consulted in `prepareForStream` (:154–190) before `Settings.shared.agentVoiceEngine`, honoured only when `SelfTest.isRunning`. Set it to `"pocket"`, `defer` reset. Changing `Settings` would write the user's defaults.
   - Start `MainActorStallProbe.shared`; `VoiceLatencyTimeline.shared.resetForTesting()`.
   - Run `runs + 1` times: `try await capture.beginFileSession(wav:)` (the same call `runVoicePipelineSelfTest` makes, AgentCaptureController.swift:1461), wait (≤ 55 s, as that test does) until `fileCommittedTurns == 1`, `lastReply` non-empty and a `.startAcknowledged` event arrived (install an `onPlaybackEvent` observer exactly as :1468–1476), then wait until `!RealtimeAudioSession.shared.isSpeaking` (≤ 20 s) so the next run starts from silence, then `await capture.endSession(source: .done)` and sleep 1 s. Run 0 is the warm-up and is printed but never counted.
   - After each run take the latest `ClosedTurn` from the timeline and print one line (seconds, 3 decimals, `-` for absent):
     ```
     VOICE_LATENCY_RUN=1 speech_end_to_eou=0.998 eou_hop=0.004 eou_to_endpoint=0.066 speech_end_to_endpoint=1.063 endpoint_to_request=0.002 request_to_lane=0.000 route=0.664 route_to_first_token=0.881 transcript_to_first_token=1.546 first_token_to_clause=0.001 clause_to_first_pcm=0.281 first_pcm_to_audible=0.118 speech_end_to_first_audio=3.096 speculation=miss:no-slot main_stall_max=0.500 stall_site=unlabelled eou_prepare=0.000 endpoint_source=localEOU
     ```
     (Values shown are the 2026-09-23 run from A §6; your run 1 on unmodified code should look similar.) Run 0 prints `VOICE_LATENCY_RUN=0 kind=warmup …`.
   - Then `VOICE_LATENCY_MEDIAN …` and `VOICE_LATENCY_P90 …` over the counted runs for every numeric column, and `VOICE_LATENCY_TTS=<backing type>` and `VOICE_LATENCY_FIXTURE=<path> duration=<s>`.
   - Failures, each printed as `VOICE_LATENCY_WRONG: <text>`: a required span (step 6) missing in any counted run; `main_stall_max` > max-stall in any counted run (print the site); a run that did not commit exactly one turn or produced no first audio; `endpoint_source != localEOU`; with a budget, `median(speech_end_to_first_audio) > budget`.
   - Last line: `VOICE_LATENCY_OK` or `VOICE_LATENCY_FAILED: <first failure>`.
   - Writes nothing to user stores: `MetricsStore.shared` and `AgentSession.shared` are already isolated under the harness (MetricsStore.swift:13–16; RealtimeAgent.swift:817–818). The audit log is not isolated yet — that is P0-11; until P0-11 lands, run `grep -c "local conversational frontend" ~/Library/Application\ Support/Next\ Notes/agent-audit.jsonl` before and after and report any growth in STATUS.md rather than hiding it.
   Register the flag in `NextNotesApp.runRequestedSelfTest` next to `--selftest-voice-pipeline` (:1363):
   ```swift
   if arguments.contains("--selftest-voice-latency") {
       Task { @MainActor in
           SelfTest.failed = !(await VoiceLatencySelfTest.run())
           if SelfTest.outputPath != nil { writeSelfTest(SelfTest.failed ? "VOICE_LATENCY_FAILED" : "VOICE_LATENCY_OK") }
           NSApp.terminate(nil)
       }
       return true
   }
   ```
   (Follow the ABSENT convention of existing tests: when ABSENT, `writeSelfTest` the ABSENT line instead.) Timeout: 1 + 5 runs × ≤ 60 s can exceed the 300 s default — callers pass `--selftest-timeout 600`; add that in `acceptance.sh`.
   Extend `LatencyTrace.persist`'s mirror (LatencyTrace.swift:323) to also print `VOICE_PIPELINE_SPAN=…` when `SelfTest.requested == "--selftest-voice-latency"`.

10. **Attribute the stall.** Run the self-test on the unmodified pipeline (after steps 1–9 only). Then:
    - **In-app attribution:** read `stall_site` per run. Then run once with `--voice-latency-island off`: a self-test-only switch (`IslandState.suppressUpdatesForTesting = true`, honoured only when `SelfTest.isRunning`) that makes `IslandState` ignore updates so the island does not re-render. If `main_stall_max` drops below 0.1 s with the island off, the stall is SwiftUI rendering (the avatar/orb hypothesis); if not, it is in a labelled site.
    - **Instruments** (`xcrun xctrace` 27.0 is installed; templates present include `Time Profiler`, `Swift Concurrency`, `SwiftUI`, `Foundation Models`, `Audio System Trace`; instruments include `Hangs`, `os_signpost`, `Points of Interest`). Never bare-invoke the app binary (AGENTS.md); attach instead. In one Bash call started with `run_in_background: true`:
      ```bash
      mkdir -p ~/Library/Caches/NextNotesBuild/traces
      for i in $(seq 1 120); do pid=$(pgrep -nx NextNotes) && break; sleep 0.5; done
      xcrun xctrace record --template 'Time Profiler' --instrument Hangs --instrument os_signpost \
        --attach "$pid" --time-limit 90s \
        --output ~/Library/Caches/NextNotesBuild/traces/voice-latency-$(date +%Y%m%d-%H%M%S).trace
      ```
      then, in the foreground: `Scripts/run-selftest.sh --selftest-voice-latency --voice-latency-runs 3 --voice-latency-start-delay 8 --selftest-timeout 600`. Repeat with `--template 'SwiftUI'` if the in-app probe said `unlabelled`, and with `--template 'Swift Concurrency'` if the stall sits in a `Task` hop. Export and read:
      ```bash
      T=~/Library/Caches/NextNotesBuild/traces/<name>.trace
      xcrun xctrace export --input "$T" --toc > /tmp/toc.xml     # confirm the table schema names first
      xcrun xctrace export --input "$T" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="potential-hangs"]' > /tmp/hangs.xml
      xcrun xctrace export --input "$T" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > /tmp/profile.xml
      xcrun xctrace export --input "$T" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]' > /tmp/signposts.xml
      ```
      In `hangs.xml` take each hang's start/duration; in `profile.xml` filter samples on the main thread inside those windows and list the top frames. If `xctrace` refuses to attach (it may need Developer Mode / `DevToolsSecurity -enable`, which is a system setting you must **not** change), record that in STATUS.md and rely on the in-app attribution.
    - Write the attribution (site, share of the worst stall, evidence file) into STATUS.md before fixing.

11. **Fix what was attributed** — only the attributed sites, smallest change first; re-run after each:
    - `VoicePlaybackReference.stopped()` (VoicePlaybackReference.swift:28–35): replace `lane.sync { … }` with `lane.async { … }`. Ordering is preserved because `lane` is a serial FIFO queue and every queued feed callback re-checks the epoch that `stopped()` has already bumped.
    - `AgentSession.updateSpeech` / `append` (RealtimeAgent.swift:1134, :1199): keep the in-memory mutation synchronous; move `Self.save(messages, to:)` to a debounced writer (`DispatchQueue(label: "…agent-session", qos: .utility)`, coalesce 250 ms, copy the array value first, flush synchronously on `NSApplication.willTerminateNotification` and in `endSession`). `AgentSession.persistenceSelfTest()` (RealtimeAgent.swift:1233) must stay green — flush the writer before it reads the file back.
    - Island: coalesce `showAgentListening` to ≤ 10 Hz and skip when transcript and level (quantised to 0.05) are unchanged; if the avatar/orb animation is the cost, run it at `DS.Motion.avatarAmbientFrameInterval` during a voice turn instead of display cadence (a DS token, never a literal — AGENTS.md design-system rule). Do **not** `scaleEffect` or re-architect the avatar.
    - Pocket per-frame copy (PocketAgentVoice.swift:213): `frame.samples.withUnsafeBufferPointer { memcpy(samples, $0.baseAddress!, $0.count * 4) }`.

12. **Register everywhere.** `Scripts/acceptance.sh`: add `"selftest-voice-latency|600"` to `EXPERIMENTAL_ENTRIES` now (ABSENT → SKIP is already handled by `*_ABSENT`). At the phase exit gate, move it to `CORE_ENTRIES` and make `--voice-latency-budget 0.9` its default. `AGENTS.md`: add `--selftest-voice-latency [--voice-latency-runs n] [--voice-latency-budget s]` to the flag list and a short paragraph: what `voice.*` spans are, that `metrics.jsonl` now carries them for real sessions, and how to read one turn (`grep '"revision":<n>' metrics.jsonl`).

**Do not:**
- Build with bare `swift build` (iCloud folder; use `make build`), omit `OPEN=0` on `make install`, loop `--via-open`, or launch the app binary directly — attach Instruments instead.
- Use `MainActor.assumeIsolated` anywhere in the probe or timeline; it asserts and crashes (AGENTS.md).
- Write spans or anything else from a self-test into the user's stores; do not change `Settings` from a self-test (use `engineOverrideForTesting`).
- Let the self-test pass when a stage did not happen: a missing span is a failure, a missing model is ABSENT, never OK.
- Add a second clock: every mark uses `CLOCK_UPTIME_RAW` nanoseconds, like `LatencyTrace`.
- "Fix" the stall before it is attributed, or fix a site the attribution did not name.
- Mutate `@State` inside a `Canvas` draw closure if you touch island drawing (AGENTS.md).

**Red-first self-test:** `--selftest-voice-latency`, in `Agent/Voice/VoiceLatencySelfTest.swift`. Fixtures: the generated WAVs; fakes: none (production pipeline, isolated stores). Assertions and markers as in step 9: `VOICE_LATENCY_OK` / `VOICE_LATENCY_FAILED: <reason>` / `VOICE_LATENCY_ABSENT: <reason>`. **Red confirmation:** after steps 1–9 and before step 11, run it on the unmodified pipeline: expect `VOICE_LATENCY_FAILED: main-actor stall 0.3xx–0.6xx s > 0.100 s` (A measured 0.34–0.63 s) and a `speech_end_to_first_audio` median near 3.1 s. If it is green at that point, the probe is not measuring what the file feeder measured — compare `main_stall_max` with `VOICE_FILE_MAX_PACING_LAG` in the same run before continuing.

**Verify:**
```bash
make build
make install OPEN=0
Scripts/make-voice-fixtures.sh
Scripts/run-selftest.sh --selftest-metrics
Scripts/run-selftest.sh --selftest-voice-latency --voice-latency-runs 5 --selftest-timeout 600
Scripts/run-selftest.sh --selftest-voice-pipeline ~/Library/Caches/NextNotesBuild/voice-fixtures/haiku16k.wav --voice-feed-10ms
Scripts/run-selftest.sh --selftest-voice-barge ~/Library/Caches/NextNotesBuild/voice-fixtures/stop16k.wav
```
Regression flags: `--selftest-voice-turns`, `--selftest-voice-delivery`, `--selftest-playback-ledger`, `--selftest-voice-conversation`, `--selftest-voice-speculation`, `--selftest-tts-pocket`, `--selftest-realtime`, then `make acceptance TIER=core`.

**Success threshold:** every counted run prints all required spans; `main_stall_max` ≤ 0.100 s in 5/5 runs; `VOICE_LATENCY_OK`; `--selftest-metrics` green; a real voice session (the user's, next time they talk to it) leaves `voice.*` rows in `~/Library/Application Support/Next Notes/metrics.jsonl` — check with `grep -c '"voice.speech_end_to_first_audio"' ~/Library/Application\ Support/Next\ Notes/metrics.jsonl`, and the same session leaves `"pass":"turn"` rows in `usage.jsonl` (H-audit 2026-09-24). The baseline medians are written to STATUS.md.

**Risks & rollback:** the probe adds one main-queue block per 10 ms during a session (cost ~µs; if Instruments shows otherwise, raise the interval to 20 ms). Async metrics writes can lose the last spans on a crash — acceptable for diagnostics. A debounced `AgentSession` writer can lose ≤ 250 ms of conversation on a crash; the flush on terminate covers normal quits. Each fix in step 11 is independent; revert it alone if a regression flag turns red.

**Done when:**
- [ ] `Scripts/make-voice-fixtures.sh` exists and produces the six WAVs (the `[[slnc]]` check passes).
- [ ] New span ids, `source` field, async writer; `--selftest-metrics` green.
- [ ] Marks stamped at every site in step 7; `frontend_unavailable` sub-reasons.
- [ ] `--selftest-voice-latency` registered, in `acceptance.sh` (EXPERIMENTAL) and AGENTS.md.
- [ ] Red run recorded in STATUS.md (baseline medians + worst stall + site).
- [ ] Stall attributed (site + evidence) and fixed; `main_stall_max` ≤ 0.100 s in 5/5 runs.

---

### P2-02 — Prewarmed frontend sessions and one streamed frontend decision

**Finding(s):** L2  **Effort:** 2–3 days  **Depends on:** P2-01, **P0-06**; coordinate with P1-03 and P1-07 (§0.5)  **Unblocks:** P2-03

**Why (what the user experiences today):** There is a pause of about a second before every
spoken answer. After the endpoint, the frontend builds a fresh Foundation Models session, runs
a structured route pass and waits for it to finish completely (**0.664 s** warm, **1.305 s**
cold on 2026-09-23), then builds a second fresh session for the answer (first answer text
**1.545 s** after the endpoint in the same run). Apple's prompt prewarm is never used in
production, although it was measured here to cut an idle first response from **1.471 s to
0.555 s** (A Hop 6, report `:818`).

**Files you will change:**
- `Formatting/LLM/LocalVoiceFrontend.swift` — staged split turn, prewarm, decision modes.
- `Formatting/LLM/LocalVoiceDecision.swift` — intent-only route type, `LocalVoiceTurnDecision`, `LocalVoiceFrontendMode`.
- `Agent/VoiceConversationCoordinator.swift` — `stagingRequest()`, `hasActiveJobs` pass-through, `--voice-no-speculation`.
- `Activation/AgentCaptureController.swift` — `stageFrontendIfNeeded` passes the staging request.
- `Formatting/LLM/LocalVoiceFrontendSelfTest.swift` — `--voice-frontend-routing-only` and `--voice-frontend-mode`.
- `Agent/Voice/VoiceLatencySelfTest.swift` — `--voice-latency-first-token-budget`.

**Read for context (do not change):** `Formatting/LLM/LocalVoicePrompt.swift` (`plan`, `transcript(for:)`); the FoundationModels interface — `LanguageModelSession.prewarm(promptPrefix: Prompt? = nil)` (macOS 26+) and `LanguageModelSession.Error.concurrentRequests` / `GenerationError.concurrentRequests` exist in the installed SDK (`FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface`, lines 1961 and 2027/3566); decision doc §3.5 item 5.

**Current behaviour:**
- Production always takes the split path: `LocalVoiceSplitResponse.isEnabled` is true unless a self-test passes `--voice-legacy-envelope` (LocalVoiceDecision.swift:80–84).
- `LocalVoiceFrontend.stageNextTurn(system:)` (LocalVoiceFrontend.swift:128–144) is called from `AgentCaptureController.stageFrontendIfNeeded` (AgentCaptureController.swift:940–952) after 120 ms of sustained near speech (`noteLevel`, :893–903) or on a novel partial (`considerSpeechInterruption`, :1127). In split mode it only runs the one-time `prepare()` and throws the session away:
  ```swift
  if LocalVoicePrompt.isEnabled || LocalVoiceTypedResponse.isEnabled
      || LocalVoiceSplitResponse.isEnabled {
      stagedSession = nil
      return
  }
  ```
- `unsharedStream` (:342–479) acquires `ComputeScheduler.acquire(.realtimeAgent)` (:388), then `streamSplitDecision` (:483–551) builds `LanguageModelSession(transcript: LocalVoicePrompt.transcript(for: routePlan))` (:490), streams `LocalVoiceRoute` with `maximumResponseTokens: 64` (`routeMaximumResponseTokens`, LocalVoiceDecision.swift:158) and `collect()`s it (:505). Only for `answerQuestion` does it build a second fresh session from `answerPlan` (:542–544) and stream prose (`streamSplitAnswer`, :555–596).
- What each session contains: the **route** plan drops system messages and history — `routePlan(messages:)` (LocalVoiceDecision.swift:91–96) returns `instructions = routeInstructions`, `history = []`, `latestUser = <Work status…\n\nLatest user speech:\n<text>>`. The **answer** plan (`answerPlan`, :111–116) = `answerInstructions` + the capability inventory and playback-status system message + bounded history + the same latest user message. Everything except the words after `Latest user speech:\n` is known while the user is still talking (`VoiceConversationCoordinator.frontendRequest`, :666–686).
- `LocalVoiceRoute` always carries an optional `taskNumber` (LocalVoiceDecision.swift:61–77) even when there are no running jobs.
- A single typed decision already exists as a legacy experiment: `LocalVoiceDecision` (intent, taskNumber, speech; LocalVoiceDecision.swift:7–26) streamed by `streamTypedResponse` (LocalVoiceFrontend.swift:600–682), reachable only with `--voice-legacy-envelope --voice-typed-response`. The split replaced it because "routing is deliberately a smaller structured response than the spoken answer, so the model cannot fill an answer field while it is deciding" (LocalVoiceDecision.swift:57–59).
- The routing corpus in `--selftest-voice-frontend` (LocalVoiceFrontendSelfTest.swift:106–129, ~15 fixtures with expected routes) cannot run on this Mac today: it requires the built-in worker GGUF (`guard NotesModels.isDownloaded`, :8–12) and prints `VOICE_FRONTEND_MISSING_WORKER_MODEL`.

**Target behaviour:**
1. While the user speaks, the route and answer sessions for the coming turn exist and have been prewarmed with everything but the final words.
2. At commit, a staged session whose context still matches is used; otherwise a fresh one (never a stale one).
3. With no running jobs the route generates only an intent.
4. The frontend runs in one of three measured modes — `split` (today, prewarmed), `splitOverlapped` (answer generated concurrently with the route, released only for `answerQuestion`), `single` (one streamed structured decision, intent first) — and production uses the mode that the measurement in step 7 selects.
5. Warm `voice.transcript_to_first_token` median ≤ **0.60 s** over 5 runs with speculation disabled (today 1.546 s); routing accuracy on the corpus not lower than today's split path.

**Steps:**

1. **Staging request.** In `VoiceConversationCoordinator` split `frontendRequest(_:)` (:666–686) into a builder that returns the messages with the last user message's content ending exactly at `"Latest user speech:\n"`, and the committed variant that appends the text. Add:
   ```swift
   /// Everything the frontend will see for the next turn except the user's words.
   func stagingRequest() -> (system: String, messages: [LLMChatMessage], hasActiveJobs: Bool)
   ```
   `hasActiveJobs = jobs.contains { $0.status == "running" }`. Pass `hasActiveJobs` through `stream(…)` and `speculate(…)` as a new parameter and include it in `RequestKey`.
2. **Staged split turn.** In `LocalVoiceFrontend` replace `stagedSession` with:
   ```swift
   private struct StagedSplitTurn {
       let key: StagingKey                 // see step 3
       let routeSession: LanguageModelSession
       let answerSession: LanguageModelSession
       let createdAt: ContinuousClock.Instant
   }
   private var stagedSplit: StagedSplitTurn?
   func stageNextTurn(system: String, messages: [LLMChatMessage], hasActiveJobs: Bool) async throws
   ```
   Body: `stagingEpoch &+= 1`; `try await prepare()` (unchanged one-time warmup); build `routePlan = LocalVoiceSplitResponse.routePlan(messages:)` and `answerPlan = LocalVoiceSplitResponse.answerPlan(system:messages:)` from the staging messages (their `latestUser` is the prefix); create both sessions from `LocalVoicePrompt.transcript(for:)`; call `routeSession.prewarm(promptPrefix: Prompt(routePlan.latestUser))` and `answerSession.prewarm(promptPrefix: Prompt(answerPlan.latestUser))`; store. Do **not** acquire the `ComputeScheduler` lane for `prewarm` — it is not an inference and returns immediately. Drop a staged turn older than 60 s, on `clearStagedTurn()` (:146–150), and after it has been used once (a session that has responded carries that response in its transcript; never reuse it).
   `AgentCaptureController.stageFrontendIfNeeded` (:940–952) becomes:
   ```swift
   let staging = VoiceConversationCoordinator.shared.stagingRequest()
   Task { try? await LocalVoiceFrontend.shared.stageNextTurn(system: VoiceConversationCoordinator.systemPrompt,
                                                            messages: staging.messages, hasActiveJobs: staging.hasActiveJobs) }
   ```
   (keep the existing error log.) Re-stage once more on the first novel partial if more than 5 s passed since staging (history may have changed because a worker finished).
3. **Staging key and reuse.** `StagingKey` = route instructions + answer-plan instructions + answer-plan history entries (role + content) + the latest-user prefix + `hasActiveJobs`. In `streamSplitDecision` (:483), compute the key from the commit messages with the user's words removed (cut at the last `"Latest user speech:\n"`); if `stagedSplit?.key == key`, take its sessions (`takeStagedSplit()` clears the slot); else build fresh ones. Route reuse and answer reuse are independent: the route key ignores the answer instructions/history, so a changed playback-status line (it lives in the answer's system message) invalidates only the answer session. Record `VoiceLatencyTimeline.shared.note("staging", "route=hit|miss answer=hit|miss")`.
4. **Intent-only route.** Add
   ```swift
   @Generable(description: "The route for one voice turn when no task is running.")
   struct LocalVoiceRouteIntentOnly { @Guide(description: "<same text as LocalVoiceRoute.intent>") var intent: LocalVoiceRoute.Intent }
   static let routeIntentOnlyMaximumResponseTokens = 24   // estimate; the JSON is ~8–12 tokens
   ```
   Use it when `!hasActiveJobs`; `reviseRunningTask` / `cancelRunningTask` from it (no task number possible) map to `answerQuestion` — there is nothing to revise — and log `voice route · revise without task`.
5. **Decision modes.** Add `enum LocalVoiceFrontendMode: String { case split, splitOverlapped, single }` in LocalVoiceDecision.swift with `static var current: LocalVoiceFrontendMode` = a production constant (start with `.split`) that a self-test may override with `--voice-frontend-mode <m>` (read with `SelfTest.value(after:)`, honoured only when `SelfTest.isRunning`).
   - `split`: steps 2–4 only.
   - `splitOverlapped`: in `streamSplitDecision`, start the answer stream in a child `Task` at the same time as the route `collect()`; collect its deltas into a small actor buffer (pattern: `SpeculativeVoiceBuffer`, LocalVoiceFrontend.swift:725–762). When the route resolves to `answerQuestion`, yield `"<answer/>"`, replay the buffer, then forward live deltas; for any other route, cancel the answer task and never yield its text (it must not reach the envelope, the tracker or TTS). If either stream throws `.concurrentRequests` (either enum), fall back to sequential for this turn and record `note("overlap", "concurrent_requests")`.
   - `single`: add
     ```swift
     @Generable(description: "The decision and spoken answer for one voice turn.")
     struct LocalVoiceTurnDecision {
         @Guide(description: "<LocalVoiceRoute.intent guide text>") var intent: LocalVoiceRoute.Intent   // declared first: generated first
         @Guide(description: "<LocalVoiceRoute.taskNumber guide text>") var taskNumber: Int?
         @Guide(description: "The spoken answer, only for answerQuestion; empty otherwise.") var speech: String
     }
     ```
     Session from `answerPlan` with instructions = `answerInstructions` + `"\n\n" + routeRules`. Stream with `streamResponse(to:generating:options:)` and reuse the structure of `streamTypedResponse` (:600–682): once `partial.intent` is set, a later different intent throws `typedDecisionRevised`; for `answerQuestion` yield `"<answer/>"` then speech deltas as they grow; for the other intents yield the same control envelopes `streamSplitDecision` yields today (`<capabilities/>`, `<use_tools/>`, `<revise id=…/>`, `<cancel id=…/>`). Stamp `routeDone` when the intent first appears.
6. **Measurement seams.** In `LocalVoiceFrontendSelfTest.run` add `--voice-frontend-routing-only`: skip the worker-model requirement (:8–12) and the worker-overlap part; run the routing corpus (:106–129) through `LocalVoiceFrontend.shared.stream` in the current mode, 3 repeats; print per fixture `voice frontend route fixture=<n> expected=<r> got=<r> first_text=<s>` and a summary `VOICE_FRONTEND_ROUTING correct=<k>/<n> median_first_text=<s> concurrent_errors=<c>`; final line `VOICE_FRONTEND_OK` only if every repeat classified every fixture as expected, else `VOICE_FRONTEND_FAILED`. In `VoiceConversationCoordinator.prepareResponseIfUseful` (:162) return early when `SelfTest.isRunning && CommandLine.arguments.contains("--voice-no-speculation")`. In `VoiceLatencySelfTest` add `--voice-latency-first-token-budget <s>`: fail when `median(transcript_to_first_token) > s`.
7. **Choose the mode** (record the table in STATUS.md):
   ```bash
   for m in split splitOverlapped single; do
     Scripts/run-selftest.sh --selftest-voice-frontend --voice-frontend-routing-only --voice-frontend-mode $m
     Scripts/run-selftest.sh --selftest-voice-latency --voice-no-speculation --voice-frontend-mode $m --voice-latency-runs 5 --selftest-timeout 600
   done
   ```
   Adoption rule: among modes whose routing result is `correct = n/n` in all repeats **and** zero concurrent-request errors, pick the lowest median `transcript_to_first_token`. If none beats `split`, keep `split` (still prewarmed). Set `LocalVoiceFrontendMode.current`'s production constant to the winner and leave the other modes reachable only from self-tests.

**Do not:**
- Reuse a `LanguageModelSession` that has already responded, or a staged session whose key differs — a stale transcript answers the previous turn.
- Let the answer text of a non-`answerQuestion` route reach `AgentToolSpeechTracker`, speech or the envelope (the answer lane may not act or promise; P1-07's rebuttal and pending-intent logic read the committed route).
- Route Foundation Models prewarm through the `ComputeScheduler` lane, or give any warmup the frontend's priority (AGENTS.md: background warmup must not acquire the conversational frontend's priority).
- Delete the `split` path or the legacy flags; `--selftest-voice-prompt-probe` and `--selftest-voice-conversation` use them.
- Put the Agent's name into the new instructions (AGENTS.md: "The Agent's name is never in a prompt"); `--selftest-persona` checks this.
- Weaken the routing corpus to make a faster mode pass.

**Red-first self-test:** extend `--selftest-voice-latency` with `--voice-latency-first-token-budget` (step 6) and run `Scripts/run-selftest.sh --selftest-voice-latency --voice-no-speculation --voice-latency-first-token-budget 0.6 --voice-latency-runs 5 --selftest-timeout 600` **before** steps 2–5: expect `VOICE_LATENCY_FAILED: median transcript_to_first_token 1.5xx s > 0.600 s` (A measured 1.546 s). The routing guard is `--selftest-voice-frontend --voice-frontend-routing-only` (`VOICE_FRONTEND_OK` / `VOICE_FRONTEND_FAILED`; Apple Intelligence unavailable → print `VOICE_FRONTEND_ABSENT: <reason>` last). Record the `split` baseline (unprewarmed) with it before changing anything.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-voice-frontend --voice-frontend-routing-only
Scripts/run-selftest.sh --selftest-voice-latency --voice-no-speculation --voice-latency-first-token-budget 0.6 --voice-latency-runs 5 --selftest-timeout 600
Scripts/run-selftest.sh --selftest-voice-pipeline ~/Library/Caches/NextNotesBuild/voice-fixtures/haiku16k.wav --voice-feed-10ms
```
Regression flags: `--selftest-voice-speculation`, `--selftest-voice-conversation`, `--selftest-voice-turn-routing`, `--selftest-voice-capabilities`, `--selftest-voice-grounding`, `--selftest-persona`, `--selftest-concurrent-voice`, `--selftest-voice-scheduling`, then `make acceptance TIER=core`.

**Success threshold:** median `transcript_to_first_token` ≤ 0.600 s over 5 warm runs with `--voice-no-speculation`; `route` ≤ 0.25 s median when `split`/`splitOverlapped` is chosen; routing corpus n/n in 3/3 repeats in the adopted mode; `VOICE_PIPELINE_OK` still explains "three" lines in the haiku answer.

**Risks & rollback:** prewarming two sessions per turn spends ANE/GPU time while the user speaks (small; FM sessions share one system service). A wrong staging key answers with stale history — the key compares full history text, so the failure mode is a miss, not a stale hit. `single` may reintroduce the routing errors the split fixed — that is why it must pass the corpus. Rollback: set `LocalVoiceFrontendMode.current` to `.split` and stop calling `prewarm`; both are one-line changes.

**Done when:**
- [ ] `stagingRequest()`, `StagedSplitTurn`, prewarm of both sessions, staging hit/miss note.
- [ ] Intent-only route when no job runs.
- [ ] Three modes implemented; comparison table in STATUS.md; production constant set.
- [ ] `--voice-frontend-routing-only`, `--voice-no-speculation`, `--voice-latency-first-token-budget` exist.
- [ ] Median transcript → first token ≤ 0.60 s (no speculation); routing n/n.

---

### P2-03 — Append-tolerant speculation, started on quiet and on the early EOU

**Finding(s):** L4 (and the "raw EOU" half of L3)  **Effort:** 2 days (+ optional upstream PR)  **Depends on:** P2-01, P2-02, P2-04 (the trigger interacts with the endpoint rules), P0-06  **Unblocks:** the phase target (§0.3 needs speculation hits)

**Why (what the user experiences today):** The app already tries to start answering while the
user is still talking, but it almost never helps. On 2026-09-23 the speculation for "…what a
**haiku**" had finished routing (0.686 s) and was answering when the next partial "…haiku
**is**" cancelled it; the final text then got **no slot** ("Voice speculation miss no-slot")
because the end-of-utterance arrived inside the 220 ms debounce (A Hop 7). Measured hits:
build 47 head start 0.843 s (first token still 1.069 s), build 52 21 ms, today a miss. A
barge-in turn can never hit, because the playback-status line inside the request key flips to
"interrupted" after speculation started.

**Files you will change:**
- `Agent/VoiceConversationCoordinator.swift` — trigger, frozen playback status, word threshold.
- `Formatting/LLM/LocalVoiceFrontend.swift` — two-level speculation (route, answer), policy-based reuse, test seams.
- **new** `Formatting/LLM/VoiceSpeculationPolicy.swift` — pure reuse rules.
- `Agent/RealtimeAgent.swift` — `AgentSession.voiceDeliveryContext(assumingInterruptedWith:)`.
- `Activation/AgentCaptureController.swift` — quiet trigger.
- `Formatting/LLM/LocalVoiceFrontendSpeculationSelfTest.swift` — new cases.

**Read for context (do not change):** `Agent/AgentDirectIntent.swift` — `actionVerbs` (:235), `toolShapeMatch(in:allowedIDs:)` (:244), `capabilityMention(in:allowedIDs:)` (:260); FluidAudio `StreamingEouAsrManager` (checkout at `~/Library/Caches/NextNotesBuild/scratch/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/Streaming/EOU/StreamingEouAsrManager.swift`, revision 4dbf4f9 = 0.15.6): `evaluateEouDebounce` (:300–327) and the confirmation block (:655–679).

**Current behaviour:**
- `VoiceConversationCoordinator.prepareResponseIfUseful(_:)` (VoiceConversationCoordinator.swift:162–183) runs for every accepted partial (`AgentCaptureController.prepareResponseForRecognizedSpeech`, AgentCaptureController.swift:1149–1167, called from both recognizers, from `noteModelEOU` :1015 and on ownership changes). Each call cancels older speculation (`cancelSpeculation(through: epoch - 1)`), returns if the text has fewer than 4 words, sleeps 220 ms, then calls `LocalVoiceFrontend.speculate` with the **full** request:
  ```swift
  await LocalVoiceFrontend.shared.cancelSpeculation(through: epoch - 1)
  guard text.split(whereSeparator: \.isWhitespace).count >= 4 else { return }
  do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
  ```
- `LocalVoiceFrontend.speculate` (:155–190) replaces the slot unless key and epoch are identical; `stream` (:280–310) reuses a speculation only if `RequestKey` (:37–62) — system prompt, every message's content, max tokens, mode flags — is equal, with only the final speech canonicalised (`VoiceTranscriptCanonical.key`, :702–720).
- The key contains `AgentSession.shared.latestVoiceDeliveryContext` (RealtimeAgent.swift:1081–1092) through `frontendRequest` (VoiceConversationCoordinator.swift:682).
- Parakeet EOU: FluidAudio fires the EOU callback only after `eouDebounceMs` (320 here, LocalVoiceTurnDetector.swift:8) of processed audio without new tokens since the head's first EOU signal; the anchor `eouFirstDetectedAt` is private and there is no public callback for the raw signal. After a confirmation `eouDetected` stays true until `reset()`, so the same utterance never confirms twice (`alreadyConfirmed`, StreamingEouAsrManager.swift:663).

**Target behaviour:**
1. Speculation is split by stage. A completed **route** is reused when the final text only appends an inert tail of ≤ 2 words to the speculated text; the **answer** is reused when the tail is in a small filler set, otherwise it is regenerated immediately on the prewarmed answer session (P2-02).
2. The playback-status line is frozen per turn at the first partial, so speculation and commit see the same string (and a barge-in turn can hit).
3. Speculation starts when the user goes quiet (≥ 100 ms under the silence level with a usable partial) — not after a fixed 220 ms sleep — and a partial that only appends an inert tail does not cancel it.
4. `--selftest-voice-pipeline` prints a speculation **hit** (today a miss); `--selftest-voice-latency` reports hits in ≥ 4 of 5 runs.

**Steps:**

1. **Policy** (new `Formatting/LLM/VoiceSpeculationPolicy.swift`, pure, `nonisolated`):
   ```swift
   enum VoiceSpeculationPolicy {
       static let maximumTailWords = 2
       static let negations: Set<String> = ["not", "no", "don't", "dont", "never", "cancel", "stop", "instead", "but", "wait"]
       static let fillerTail: Set<String> = ["please", "now", "thanks", "thank", "you", "is", "are", "it", "again", "then", "for", "me"]
       /// Word tail by which `final` extends `speculated` (canonical keys), or nil if it does not extend it.
       static func appendedTail(speculated: String, final: String) -> [String]?
       /// The completed route may be reused.
       static func routeReusable(speculated: String, final: String, allowedIDs: Set<String>) -> Bool
       /// The completed or in-flight answer may be reused.
       static func answerReusable(speculated: String, final: String) -> Bool
   }
   ```
   `routeReusable`: tail exists, `tail.count <= 2`, no tail word in `negations`, no tail word in `AgentDirectIntent.actionVerbs`, `AgentDirectIntent.capabilityMention(in: tail.joined(separator: " "), allowedIDs:) == nil` and `toolShapeMatch(in: final normalized, allowedIDs:)` returns the same value as for the speculated text. An empty tail (exact canonical match) is reusable. `answerReusable`: empty tail, or every tail word in `fillerTail`. Both use `VoiceTranscriptCanonical.key` for normalisation.
2. **Two-level slot** in `LocalVoiceFrontend`. Refactor the split path into `routeDecision(plan:hasActiveJobs:) async throws -> LocalVoiceRoute` and `answerStream(plan:maxTokens:) -> AsyncThrowingStream<String, Error>` so they can run separately. Replace `speculation: Speculation?` with:
   ```swift
   private struct RouteSpeculation { let routeKey: RouteKey; let speech: String; let epoch: UInt64; let task: Task<LocalVoiceRoute, Error> }
   private struct AnswerSpeculation { let answerKey: AnswerKey; let speech: String; let epoch: UInt64; let buffer: SpeculativeVoiceBuffer; let producer: Task<Void, Never> }
   ```
   `RouteKey` = route instructions + the latest user message **without** the words after `Latest user speech:\n` + `hasActiveJobs`; `AnswerKey` = answer instructions (with the frozen playback line, step 3) + history + that same prefix. `speculate(…)` starts the route; when it resolves to `answerQuestion` it starts the answer into the buffer. A new speculation for text T' keeps an existing route speculation if `routeReusable(speculated:final:)` holds for T → T', and an existing answer if `answerReusable` holds; otherwise it cancels only what is no longer reusable (use the existing `drainBarrier` / `cancelSpeculation` mechanics, :192–235, per slot).
   At commit, `stream(…)` checks: route slot matches `RouteKey` and `routeReusable(speculated, final)` → use its (possibly still running) result; answer slot matches `AnswerKey` and `answerReusable` → replay its buffer (`SpeculativeVoiceBuffer.stream(cancelProducer:)`, :745); route reusable but answer not → start `answerStream` now on the P2-02 staged answer session; neither → today's path. Record `VoiceLatencyTimeline.shared.note("speculation", "hit route=<y/n> answer=<y/n> headstart=<s>")` or `"miss reason=no-slot|mismatch|negated|capability|cancelled"`.
   Keep `sealSpeculation` / `cancelSpeculation(through:)` epoch semantics exactly (the existing test proves a late cancel cannot erase a newer turn).
3. **Frozen playback status.** Add to `AgentSession` (RealtimeAgent.swift, beside `latestVoiceDeliveryContext` :1081):
   ```swift
   /// What the playback-status line will say once the current reply is interrupted by the user.
   func voiceDeliveryContext(assumingInterruptedWith completedText: String) -> String
   ```
   producing the same sentences as the `.interrupted` branch of `latestVoiceDeliveryContext`. In `VoiceConversationCoordinator` add `private var turnPlaybackStatus: String?`, set at the first `prepareResponseIfUseful` of a turn: if `RealtimeAudioSession.shared.isSpeaking` use `voiceDeliveryContext(assumingInterruptedWith:)` with the completed clauses so far (from `AgentSession`'s speech delivery of the last assistant message), else `latestVoiceDeliveryContext`. `frontendRequest` uses `turnPlaybackStatus ?? latestVoiceDeliveryContext`; clear it in `handle` after the commit request is built, in `discardInput` and in `closeSession`. Output is paused (not advanced) while the user speaks, so the confirmed-heard text does not grow between the first partial and the commit.
4. **Quiet trigger.** In `AgentCaptureController.noteLevel` (:884) track `quietSince: Date?` (set when `level < Limits.silenceLevel` after `heardSpeech`, cleared when `level >= Limits.speechLevel`). In `tick` (:1169) — which runs every 100 ms and, after P0-10, also right after an EOU — when `quietSince` is at least 0.1 s old and `pendingTurn()` is a usable candidate (same filters as `prepareResponseForRecognizedSpeech`), call `VoiceConversationCoordinator.shared.prepareResponseIfUseful(candidate, immediate: true)`. `immediate: true` skips the 220 ms sleep. Keep the per-partial call but make it keep reusable slots (step 2) instead of cancelling unconditionally. Lower the word minimum from 4 to 3 (**estimate**; "what time is it" must speculate) and keep the minimum as a named constant.
5. **Early EOU.** With P2-04 the EOU debounce is 160 ms of audio, so the confirmed EOU callback is itself the earliest EOU signal available through FluidAudio's public API; `noteModelEOU` already calls `prepareResponseForRecognizedSpeech` (:1015) — make that call `immediate: true`. Stamp `eouRaw` at the same point (it equals `eouCallback` until step 6).
6. **Optional, upstream only (P2-03b):** propose a FluidAudio PR adding `public func setEouSignalCallback(_ callback: @escaping @Sendable () -> Void)` invoked when `evaluateEouDebounce` first sets the anchor (StreamingEouAsrManager.swift:~655–666, where `eouFirstDetectedAt = decision.anchorSamples` goes from nil to non-nil). Pin the release that contains it in `Package.resolved` when it ships, then start speculation from that signal. **Do not fork the package** and do not vendor a patched copy.
7. **Hit-rate reporting.** `VoiceLatencySelfTest` prints `speculation_hits=<k>/<n>` in the median line and fails when a `--voice-latency-min-hits <k>` argument is given and not met.

**Do not:**
- Reuse a route across a negation, a capability noun or an action verb in the appended tail — "tell me about my" → "tell me about my emails" must re-route.
- Let a speculated answer speak, call tools, set a pending intent or reach the audit log before the committed turn takes it (the existing comment: "This path records no turn and has no speech/tool sink").
- Break the epoch rules proven by `--selftest-voice-speculation` (late cancel cannot erase a newer turn; a sealed revision never starts a model request).
- Add a shape heuristic that **suppresses** input — speculation may only add work (AGENTS.md: "a deterministic gate may only add, never subtract").
- Fork FluidAudio.

**Red-first self-test:** extend `--selftest-voice-speculation` (`Formatting/LLM/LocalVoiceFrontendSpeculationSelfTest.swift`). Add fake seams `setSplitStagesForTesting(route: @Sendable (LocalVoicePrompt.Plan) async throws -> LocalVoiceRoute.Intent, answer: @Sendable (LocalVoicePrompt.Plan) -> AsyncThrowingStream<String, Error>)` that count calls. New cases, each a `fail("…")` on violation:
(a) speculate "hello there please tell me briefly what a haiku", commit "Hello there. Please tell me briefly what a haiku is." → route fake called **once**, answer fake called **once**, committed text equals the speculated answer;
(b) speculate "tell me about my", commit "tell me about my emails" → route fake called **twice**;
(c) speculate "set a reminder for nine", commit "set a reminder for nine not" → route called twice;
(d) speculate while the fake playback status is "finished", then flip `AgentSession`'s delivery to interrupted before commit → still a hit (frozen status);
(e) all existing cases unchanged.
Final marker unchanged: `VOICE_SPECULATION_OK` / `VOICE_SPECULATION_FAILED: <reason>`. **Red on unmodified code:** case (a) fails with "append-only tail did not reuse the route" (today the exact key differs, so a fresh stream starts).

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-voice-speculation
Scripts/run-selftest.sh --selftest-voice-pipeline ~/Library/Caches/NextNotesBuild/voice-fixtures/haiku16k.wav --voice-feed-10ms
Scripts/run-selftest.sh --selftest-voice-latency --voice-latency-runs 5 --voice-latency-min-hits 4 --selftest-timeout 600
```
Regression flags: `--selftest-voice-conversation`, `--selftest-voice-turn-routing`, `--selftest-voice-turns`, `--selftest-voice-rapid <haiku16k.wav> <stop16k.wav>`, `--selftest-concurrent-voice`, then `make acceptance TIER=core`.

**Success threshold:** `VOICE_SPECULATION_OK`; the pipeline run prints `Voice speculation hit` with head start ≥ 0.10 s; `speculation_hits` ≥ 4/5; median `transcript_to_first_token` ≤ 0.30 s (**estimate** of what a hit buys; record the measured value).

**Risks & rollback:** a reused route that should have changed sends a request to the answer lane instead of the worker — the tail rules and the unchanged deterministic tool-shape gate (which runs on the committed text before the frontend, VoiceConversationCoordinator.swift:371–378) bound this; P1-07's rebuttal is the backstop. Extra speculative generations cost ANE time while the user speaks. Rollback: make `routeReusable`/`answerReusable` return `tail.isEmpty` only (exact reuse), which restores today's semantics with the new trigger.

**Done when:**
- [ ] `VoiceSpeculationPolicy` + two-level slot + frozen playback status + quiet trigger.
- [ ] New `--selftest-voice-speculation` cases green (red first).
- [ ] Pipeline prints a hit; ≥ 4/5 hits in `--selftest-voice-latency`.
- [ ] Upstream FluidAudio issue/PR for the raw EOU signal filed (link in STATUS.md) or explicitly skipped.

---

### P2-04 — Smart Turn v3.2 (CoreML) as the end-of-turn arbiter; lower debounce and fallbacks

**22 October 2026 execution clarification:** use the detailed
[VOICE-TURN-DETECTION roadmap](../VOICE-TURN-DETECTION/00-README.md) for current ASR/TTS
alignment, task breakdown and latency/mid-sentence-pause benchmarks. P2-04 remains todo.
The draft's unconditional 0.80 s override of an incomplete verdict is superseded by
that roadmap's fresh-verdict policy: it would cut off the existing 900 ms pause fixture.
The proposed download-reserve exception below is also historical; preserve current
downloader policy unless an independently justified change is agreed with the TTS owner.
Other numeric settings below are calibration proposals, not achieved or automatically
approved defaults. Current Silero ducking is implemented but its cold 200 ms target is
still open; the separate VTD-02 feasibility task addresses the 256 ms window constraint.

**Finding(s):** L3  **Effort:** 3 days  **Depends on:** P2-01, **P0-10** (`tick(force:)` from `noteModelEOU`)  **Unblocks:** P2-03 (trigger), the ≤ 0.9 s target

**Why (what the user experiences today):** After the user stops talking the app waits about a
second before it even starts to answer: voice end → EOU confirmed **0.998 s** today (0.70–1.18 s
across runs), voice end → committed endpoint **1.063 s** (A Hop 3). When the EOU model is
loaded but does not fire, the turn waits **2.5 s** of quiet; before it is loaded, 0.9 + 0.35 s.
These thresholds cannot simply be lowered, because silence alone cannot tell "I want to book a
table for… four people" from a finished question. Smart Turn v3.2 is a small audio model that
answers exactly that question from prosody in ~3.5 ms (E §2.1).

**Model facts (verified 2026-09-23 on the Hugging Face Hub and GitHub):**

| | |
|---|---|
| Upstream | `pipecat-ai/smart-turn` (GitHub, **BSD-2-Clause**); weights `pipecat-ai/smart-turn-v3` on the Hub (`license: bsd-2-clause`), ONNX only: `smart-turn-v3.2-cpu.onnx` (8.7 MB int8), `smart-turn-v3.2-gpu.onnx` (32.4 MB fp32). The upstream ONNX expects Whisper log-mel features computed by the caller. |
| CoreML export used here | `aufklarer/Smart-Turn-v3.2-CoreML`, commit **`75f069717f500947195fa1945c46ddb472559cff`** (2026-09-02), `license: bsd-2-clause`, LICENSE "Copyright (c) 2024-2025, Daily". Converted from `pipecat-ai/smart-turn-v3` revision `f766f81d3cfdf7737ac64aad813d91bbfd56bf93`, file `smart-turn-v3.2-gpu.onnx`. |
| Input | `audio`, Float32 `[1, 128000]` = 8 s of 16 kHz mono, **most recent audio last, zeros at the front**. The Whisper log-mel front end (n_fft 400, hop 160, 80 mels, 800 frames) and the zero-mean/unit-variance normalisation are **inside** the CoreML model — feed raw PCM, compute no features in Swift. |
| Output | `probability`, Float32 `[1, 1]`; turn complete if > 0.5. |
| Size / speed / accuracy | 16.8 MB; 3.5 ms mean / 5.4 ms p95 per window on M5 Pro, CPU+ANE; 92.90 % accuracy, FPR 8.48 % (unfinished turns cut off), FNR 5.61 % on 1,000 upstream test clips (model card). Deployment target macOS 14. 23 languages (Parakeet EOU is English-only). |
| Usage advice (model card) | Run after a VAD pause on the whole current turn (up to 8 s); if the user resumes, run again on the full turn. |

Files at that commit (sizes and SHA-256 from the Hub's `x-linked-etag`/`x-linked-size`
headers — the LFS object id is the SHA-256 — read on 2026-09-23 without downloading):

| Path in repo | Bytes | SHA-256 |
|---|---|---|
| `smart_turn.mlmodelc/weights/weight.bin` | 16,714,240 | `b6295316741a0149e1fcab7cdf030e1b9bfb0eef778207accee91a2a9703a39c` |
| `smart_turn.mlmodelc/coremldata.bin` | 643 | `9245ac99889c9d738cba6c89da9e851fd16488bf8effbc15a109d06b401c9383` |
| `smart_turn.mlmodelc/analytics/coremldata.bin` | 243 | `1646746d0029e78d26be065e62602d4f89e51013ec238b653adf7d7d21057f89` |
| `smart_turn.mlmodelc/model.mil` | 69,968 | not an LFS file (git blob `3dbc6890a17b354e148209072f79a4f4475c5c73`): compute the SHA-256 on the first verified download and pin it before merging (the `ModelDownloader` logs it when `expectedSHA256` is nil) |

**Files you will change:**
- **new** `Activation/SmartTurn/SmartTurnModels.swift` — four `ModelSpec`s, download, assembly into an `.mlmodelc` directory.
- **new** `Activation/SmartTurn/SmartTurnModel.swift` — CoreML wrapper.
- **new** `Activation/SmartTurn/SmartTurnArbiter.swift` — turn audio ring, evaluation, pure `EndpointPolicy`.
- **new** `Activation/SmartTurn/SmartTurnSelfTest.swift` — `--selftest-smart-turn`.
- `Support/ModelDownloader.swift` — `minimumFreeBytesAfter:` parameter.
- `Activation/LocalVoiceTurnDetector.swift` — debounce as an init parameter.
- `Activation/AgentCaptureController.swift` — feed the arbiter, apply `EndpointPolicy` in `tick`, decoder-progress watermark.
- `NextNotesApp.swift`, `Scripts/acceptance.sh`, `AGENTS.md`, `THIRD-PARTY-NOTICES.md`.

**Read for context (do not change):** `Knowledge/EmbeddingModels.swift` (pinned-commit `ModelSpec` convention), `Agent/FunctionCalling/NeedleEngine.swift` (`overrideDirectory` for self-tests, :72–80), `roadmap/done/agent-analysis-2026-09-23/E-reference.md` §2.1 and §3 item 1.

**Current behaviour:**
- `LocalVoiceTurnDetector` constructs `StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: 320)` (LocalVoiceTurnDetector.swift:8). FluidAudio counts the debounce in processed audio from the first EOU signal and resets it only when new tokens decode (`evaluateEouDebounce`, StreamingEouAsrManager.swift:300–327).
- `AgentCaptureController.tick(force:)` (AgentCaptureController.swift:1169–1283) commits when, among other checks, `modelEOUAt != nil` or the quiet time since `lastSpeechAt` reaches `turnDetectorReady ? 2.5 : Limits.endpointSilence` (:1186), the transcript settled for `Limits.transcriptSettle` (0.35 s, :103) unless EOU fired, and `inputLevel <= Limits.silenceLevel || force` (:1190):
  ```swift
  (wordlessEndpoint || modelEOUAt != nil || now.timeIntervalSince(lastSpeechAt) >=
       (turnDetectorReady ? 2.5 : Limits.endpointSilence)),
  ```
- After P0-10, `noteModelEOU` calls `tick(force: true)` directly, so EOU → endpoint is ≤ 10 ms. Nothing evaluates whether a pause is the end of the turn except the EOU head.
- `ModelDownloader.download` refuses when free space after the download would drop below `minimumFreeBytesAfterDownload` = **4 GiB** (ModelDownloader.swift:40, :52–55). This Mac has ~4–6 GB free, so a 17 MB download would be refused today.
- `ModelSpec.fileURL` is `Models/<fileName>` (ModelDownloader.swift:22); `download` creates only `ModelSpec.directory`, not subdirectories (:87), so an `.mlmodelc` directory tree cannot be downloaded file-by-file under its own relative paths.

**Target behaviour:**
1. A `SmartTurnArbiter` holds the last ≤ 8 s of the current turn's **echo-cleaned** 16 kHz audio and returns a completion probability on demand in ≤ 50 ms (else "no opinion").
2. It decides **when** a turn ends, never **whether** the app hears it: it can only shorten or lengthen the wait within fixed bounds; every held turn commits at a ceiling; no text is dropped or classified by it.
3. With the model present: a finished question commits ≤ 0.45 s after the last voiced audio; a mid-sentence pause of ≤ 0.9 s does not end the turn.
4. Without the model (not downloaded, load error): behaviour is today's except the 2.5 s fallback becomes 1.5 s.

**Steps:**

1. **Model specs and download.** In `SmartTurnModels.swift`:
   ```swift
   enum SmartTurnModels {
       static let commit = "75f069717f500947195fa1945c46ddb472559cff"
       static func url(_ path: String) -> URL { URL(string: "https://huggingface.co/aufklarer/Smart-Turn-v3.2-CoreML/resolve/\(commit)/\(path)")! }
       static let weights = ModelSpec(displayName: "Turn detection", fileName: "smart-turn-v3.2.weight.bin",
           url: url("smart_turn.mlmodelc/weights/weight.bin"), expectedBytes: 16_714_240,
           expectedSHA256: "b6295316741a0149e1fcab7cdf030e1b9bfb0eef778207accee91a2a9703a39c")
       static let coreMLData = ModelSpec(…, fileName: "smart-turn-v3.2.coremldata.bin", url: url("smart_turn.mlmodelc/coremldata.bin"),
           expectedBytes: 643, expectedSHA256: "9245ac99889c9d738cba6c89da9e851fd16488bf8effbc15a109d06b401c9383")
       static let analytics = ModelSpec(…, fileName: "smart-turn-v3.2.analytics.bin", url: url("smart_turn.mlmodelc/analytics/coremldata.bin"),
           expectedBytes: 243, expectedSHA256: "1646746d0029e78d26be065e62602d4f89e51013ec238b653adf7d7d21057f89")
       static let program = ModelSpec(…, fileName: "smart-turn-v3.2.model.mil", url: url("smart_turn.mlmodelc/model.mil"),
           expectedBytes: 69_968, expectedSHA256: nil /* pin after first verified download */)
       static var all: [ModelSpec] { [coreMLData, analytics, program, weights] }
       static var compiledModelURL: URL { ModelSpec.directory.appendingPathComponent("smart-turn-v3.2.mlmodelc", isDirectory: true) }
       nonisolated(unsafe) static var overrideDirectory: URL?   // --smart-turn-dir <dir>; self-tests only
       static var isDownloaded: Bool
       static func downloadIfNeeded() async throws   // each spec via ModelDownloader, then assemble()
       static func assemble() throws                 // mlmodelc/{coremldata.bin, model.mil, weights/weight.bin, analytics/coremldata.bin}; hard-link (FileManager.linkItem) or copy
   }
   ```
   `displayName` is user-visible in progress messages; keep it plain ("Turn detection"). Add `minimumFreeBytesAfter: Int64 = minimumFreeBytesAfterDownload` to `ModelDownloader.download` and pass `512 * 1_024 * 1_024` for these four files — the 4 GiB reserve exists because other models are gigabytes (comment it). Download trigger: `Task.detached(priority: .utility) { try? await SmartTurnModels.downloadIfNeeded() }` from `AgentCaptureController.beginSession` when not downloaded (and from P2-07's warmer), never on the turn's critical path; failures are logged, not shown. Nothing downloads during a self-test (Needle precedent: a self-test that installs a model "is not a self-test, it is an install").
2. **`SmartTurnModel`** (actor):
   ```swift
   actor SmartTurnModel {
       static let windowSamples = 128_000
       private var model: MLModel?
       func loadIfNeeded(url: URL) throws            // MLModelConfiguration().computeUnits = .cpuAndNeuralEngine
       func probability(of window: UnsafeBufferPointer<Float>) throws -> Float
   }
   ```
   Fill `MLMultiArray(shape: [1, 128000], dataType: .float32)` through `dataPointer` with `memcpy` (zeros first, then the tail right-aligned) — never 128,000 `NSNumber`s. Read `output.featureValue(for: "probability")!.multiArrayValue![0].floatValue`. Load once per process (P2-07 makes it resident).
3. **`SmartTurnArbiter`** (`final class … @unchecked Sendable`, `static let shared`):
   - `append(_ buffer: AVAudioPCMBuffer)` — called from the capture `deliver` closure (AgentCaptureController.swift:687–711) with the **cleaned** chunk, off the main actor; keeps a ring of the last 128,000 samples under a lock.
   - `beginTurn()` — called from `resetTurn()` (AgentCaptureController.swift:1634): clears the ring.
   - `func evaluate() async -> Verdict?` — copies the ring, runs the model on a dedicated actor, returns `nil` if unavailable, on error, or if it took > 50 ms. `struct Verdict { let probability: Float; let complete: Bool; let seconds: Double; let evaluatedAt: Date }`. Stamp `VoiceLatencyTimeline.shared.mark(.smartTurn)` and note `smart_turn=p:0.xx`.
   - `var isAvailable: Bool`.
   Do not route it through `ComputeScheduler` (3.5 ms ANE call; the lane would add queueing, not safety).
4. **Decoder watermark.** In the EOU drain loop (`turnDetectorTask`, AgentCaptureController.swift:519–647) after each `try await detector.process(chunk)` (:619) store the chunk's `capturedAt` in a lock-protected `eouProcessedThrough` (a tiny `final class` box; no main-actor hop per chunk). A commit that relies on Parakeet's partial text (not its EOU) is only allowed once `eouProcessedThrough ≥ lastSpeechAt + 0.16 s` — otherwise the last word may not have been decoded yet.
5. **Pure endpoint policy** (in `SmartTurnArbiter.swift`, `nonisolated`, unit-testable):
   ```swift
   struct EndpointInputs { var now: Date; var heardSpeech: Bool; var lastSpeechAt: Date?; var speechBeganAt: Date?
       var eouConfirmedAt: Date?; var quietSince: Date?; var partialStableFor: TimeInterval
       var decoderCaughtUpToSpeechEnd: Bool; var detectorReady: Bool; var arbiterAvailable: Bool
       var verdict: SmartTurnArbiter.Verdict?  /* only if evaluated after lastSpeechAt */ }
   enum EndpointDecision: Equatable { case wait, evaluate, commit(String) }
   enum EndpointPolicy { static func decide(_ i: EndpointInputs) -> EndpointDecision }
   ```
   Constants (named, in `enum SmartTurnPolicy`; all **estimates** to tune with the fixtures, record final values in STATUS.md):

   | Constant | Today | With the model | Without the model |
   |---|---|---|---|
   | `eouDebounceMs` (LocalVoiceTurnDetector) | 320 | 160 | 320 |
   | quiet before the first evaluation | — | 0.20 s | — |
   | re-evaluate while quiet | — | every tick (100 ms) and on each EOU | — |
   | `completeThreshold` | — | 0.5 (model card) | — |
   | EOU confirmed, p < 0.5: hold until | — | 0.80 s after last speech | — |
   | EOU model ready but silent: ceiling | 2.5 s | 1.0 s | 1.5 s |
   | EOU model not ready: commit after | 0.9 + 0.35 s | 0.6 s quiet with p ≥ 0.5, ceiling 1.0 s | 0.9 + 0.35 s (unchanged) |
   | evaluation timeout | — | 50 ms → treat as no opinion | — |

   Rules, in order: (1) no speech / under `minSpeech` → `wait`. (2) arbiter available, quiet ≥ 0.20 s, no fresh verdict → `evaluate`. (3) fresh verdict complete **and** (`eouConfirmedAt != nil` or (`decoderCaughtUpToSpeechEnd` and `partialStableFor ≥ 0.1`)) → `commit("smart_turn")`. (4) `eouConfirmedAt != nil` and (arbiter unavailable or no verdict within 50 ms) → `commit("eou")`. (5) `eouConfirmedAt != nil`, verdict incomplete → `wait` until 0.80 s after last speech, then `commit("eou_hold_ceiling")`. (6) no EOU: quiet ≥ ceiling → `commit("fallback")`. New speech (level ≥ `speechLevel`) at any point invalidates the verdict.
   Note on rule 3: the Parakeet EOU for an utterance fires at most once (`alreadyConfirmed`, StreamingEouAsrManager.swift:663) — if the user resumes after an EOU, endpointing for the rest of that utterance comes from rules 2–3 and 6. `resetTurn` → `resetForNextTurn` (:1638–1645) re-arms the decoder after every commit, as today.
6. **Wire into `tick`.** Replace the time-threshold part of the commit condition (AgentCaptureController.swift:1182–1190) with `EndpointPolicy.decide(inputs)`; keep every text rule after it (`pendingTurn`, backchannel, echo, revision, goodbye — :1191–1256) unchanged. On `.evaluate`, start one `arbiterTask` (never two), which stores the verdict and calls `tick(force: false)` when it returns. Record `note("endpoint_rule", …)`. Keep `inputLevel <= Limits.silenceLevel || force` as is. Add `case smartTurn` to `AgentCaptureController.EndpointSource` (:111–118) and pass it to `emitTurn` for `commit("smart_turn")`. Three tests assert the endpoint source and must accept it: `runVoicePipelineSelfTest` (`lastEndpoint != .localEOU`, :1490), `runVoiceRapidTurnsSelfTest` (`$0.source != .localEOU`, :1444) and `P2-01`'s `endpoint_source` check — change each to "`.localEOU` or `.smartTurn`" (a model-backed endpoint either way). Leave `--selftest-realtime`'s `vad` expectation alone: it simulates speech without audio, so no arbiter verdict exists and the fallback rule still produces `.vad`.
7. **Debounce.** Give `LocalVoiceTurnDetector` an `init(eouDebounceMs: Int = 320)` and build the manager with it; `startEngine` passes `SmartTurnModels.isDownloaded ? 160 : 320`.
8. **Licence and notices.** Add a row to the "Downloaded at runtime, not distributed" table in `THIRD-PARTY-NOTICES.md`: `| Smart Turn v3.2, CoreML export (aufklarer/Smart-Turn-v3.2-CoreML @ 75f0697, converted from pipecat-ai/smart-turn-v3) — 16.8 MB | end-of-turn audio model | BSD-2-Clause (Copyright (c) 2024-2025, Daily) |`. BSD-2-Clause is permissive and AGPL-compatible; the weights are fetched at runtime, not committed (AGENTS.md licence section). Re-check the Hub card's `license:` field for **both** repositories before merging and write the date in the notice.

**Do not:**
- Let the arbiter drop, rewrite or classify text, or skip a turn: every held turn commits at its ceiling (AGENTS.md: a gate on the conversational path may only add; "decides when, never whether").
- Run evaluation on the raw microphone signal — use the echo-cleaned chunk, or the agent's own voice will look like an unfinished turn.
- Commit on partial text before the decoder has processed past the end of speech (step 4).
- Download the model inside a self-test, or into the repo; never commit weights.
- Lower the bar when a fixture disagrees: if the real model judges a `say`-generated pause as complete, first try a different phrasing and record both results — synthetic prosody is a known limitation (the wake-word fixtures hit the same class of problem).
- Put the model on the `ComputeScheduler` lane.

**Red-first self-test:** new `--selftest-smart-turn [--smart-turn-dir <dir>]` in `Activation/SmartTurn/SmartTurnSelfTest.swift`, registered in `NextNotesApp.runRequestedSelfTest`.
- Preconditions: model files present (installed, or in `--smart-turn-dir`) else last line `SMART_TURN_ABSENT: model not downloaded`; fixtures present else `SMART_TURN_ABSENT: run Scripts/make-voice-fixtures.sh`.
- Stage A — policy (no model): table-driven `EndpointPolicy.decide` cases for every rule in step 5, including "EOU + incomplete verdict + 0.81 s → commit(eou_hold_ceiling)" and "no EOU + 1.01 s quiet → commit(fallback)". Print `SMART_TURN_WRONG: policy <case>` on mismatch.
- Stage B — model: probability for `question16k.wav` (+0.3 s zeros) ≥ 0.5; `nopause16k.wav` (+0.3 s zeros) ≥ 0.5; `pause-mid16k.wav` cut 0.3 s into its silence < 0.5; `pause-um16k.wav` cut likewise < 0.5; print `SMART_TURN_P fixture=<f> p=<0.xx> ms=<t>` for each; every evaluation ≤ 50 ms.
- Stage C — pipeline, no frontend or TTS (install `turnHandlerForTesting` like `runVoiceRapidTurnsSelfTest`, AgentCaptureController.swift:1386–1454, and use `beginFileSession(wav:prepareResources: false)`): `pause-mid16k.wav` → exactly one committed turn and it contains "four people"; `pause-um16k.wav` → one turn containing "move the meeting"; `question16k.wav` ×3 → one turn each, median `voice.speech_end_to_endpoint` ≤ 0.45 s.
- Last line `SMART_TURN_OK` or `SMART_TURN_FAILED: <first failure>`.
**Red on unmodified code:** implement Stages A–C and the model loader first, with `tick` unchanged: Stage C's question fixture measures ≈ 1.06 s (A: 1.063 s) → `SMART_TURN_FAILED: speech_end_to_endpoint 1.0xx s > 0.450 s`.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/make-voice-fixtures.sh
# one-time model fetch outside the self-test (the app downloads on the next voice session; or fetch into a scratch dir and pass --smart-turn-dir)
Scripts/run-selftest.sh --selftest-smart-turn
Scripts/run-selftest.sh --selftest-voice-rapid ~/Library/Caches/NextNotesBuild/voice-fixtures/haiku16k.wav ~/Library/Caches/NextNotesBuild/voice-fixtures/stop16k.wav
Scripts/run-selftest.sh --selftest-voice-eou ~/Library/Caches/NextNotesBuild/voice-fixtures/haiku16k.wav
Scripts/run-selftest.sh --selftest-voice-latency --voice-latency-runs 5 --selftest-timeout 600
```
Regression flags: `--selftest-voice-turns`, `--selftest-voice-conversation`, `--selftest-realtime`, `--selftest-voice-barge <stop16k.wav>`, `--selftest-ui-strings` (the "Turn detection" display name), then `make acceptance TIER=core`. Add `"selftest-smart-turn|300"` to the INTEGRATION tier (it prints ABSENT → SKIP when the model is missing).

**Success threshold:** `SMART_TURN_OK`; median `speech_end_to_endpoint` ≤ 0.45 s on the haiku fixture in `--selftest-voice-latency` (today 1.063 s); `VOICE_RAPID_OK` unchanged (both rapid turns still close from the local model, or from `smart_turn` — update that test's `lastEndpoint` assertion to accept `.localEOU` **or** the new `smartTurn` endpoint source, and add that case to `EndpointSource`).

**Risks & rollback:** cutting people off mid-thought is the worst failure of this feature; the model's FPR is 8.48 % on its own eval — the EOU/decoder gates in rule 3 and the 0.2 s minimum quiet reduce it, and nobody has measured it on this user's speech. The real-room check is a person talking to it; say so in AGENTS.md's "What has never run" list until that happens. Rollback: delete the model directory (or set `SmartTurnModels.isDownloaded` false) → the "without the model" column applies.

**Done when:**
- [ ] Specs pinned (incl. the computed `model.mil` hash), assembly, `minimumFreeBytesAfter:`.
- [ ] `SmartTurnModel`, `SmartTurnArbiter`, `EndpointPolicy`; `tick` uses the policy; debounce 160/320.
- [ ] `--selftest-smart-turn` red then green; registered; INTEGRATION tier; AGENTS.md flag list + "never run in a real room" entry.
- [ ] `THIRD-PARTY-NOTICES.md` row.
- [ ] Median speech end → endpoint ≤ 0.45 s recorded in STATUS.md.

---

### P2-05 — VAD-driven ducking barge-in (FluidAudio Silero VAD)

**Finding(s):** L5  **Effort:** 2 days  **Depends on:** P2-01; best after P2-08 for the last 50–100 ms (see Risks)  **Unblocks:** P3-04, P3-06 (reuse `Interruption.provisional`)

**Why (what the user experiences today):** When the user starts talking over the agent, the
agent keeps talking at full level for **0.838 s** (0.835–0.961 s across builds), because
playback only pauses once a recognizer has produced at least two characters of novel text
(A Hop 12; the ASR partial → pause step itself is 0.07–1.4 ms, so the gate is the ASR). Energy is
deliberately ignored while the agent speaks, since its own voice leaks into the microphone, and
the acoustic candidate path (`considerListeningCandidate`) is not wired to the live microphone.
FluidAudio's Silero VAD is already a dependency and unused.

**Files you will change:**
- **new** `Agent/Voice/VoiceActivityMonitor.swift` — Silero probes on the cleaned stream + echo gate.
- **new** `Agent/Duplex/VoiceContracts.swift` — for now only `enum Interruption: Sendable, Equatable { case provisional, committed, explicitCancel }` (the decision doc's name, no payloads yet because `TurnID`/`TaskID` do not exist before Phase 3). P3-06a owns this file (Phase 3 file §2.2): it adds the payloads (`provisional(TurnID)`, `committed(TurnID)`, `explicitCancel(TaskID?)`) and the other contracts and updates this task's call sites. Never create a second `Interruption` type or a second contracts file.
- `Activation/AgentCaptureController.swift` — feed the monitor, `noteVoiceActivity`, `Limits.minSpeechForPause`.
- `Agent/RealtimeAudioSession.swift` — `duckForListening(captureID:)`, `releaseDuck(captureID:)`, `bargeDuckGain`.
- `Agent/Speech/AgentSpeechSynthesizer.swift` — `setOutputGain(_:)` in `AgentSpeechBacking` (default no-op extension) and a synthesizer method.
- `Agent/Speech/PocketAgentVoice.swift` (and `KokoroAgentVoice.swift`, `AVSpeechBacking` in AgentSpeechSynthesizer.swift if they own a player node) — implement `setOutputGain`.
- **new** `Agent/Voice/VoiceDuckSelfTest.swift` — `--selftest-voice-duck`; extend `runVoiceBargeSelfTest` (AgentCaptureController.swift:1533).
- `NextNotesApp.swift`, `Scripts/acceptance.sh`, `AGENTS.md`, `THIRD-PARTY-NOTICES.md`.

**Read for context (do not change):** FluidAudio 0.15.6 VAD sources in the build checkout `~/Library/Caches/NextNotesBuild/scratch/checkouts/FluidAudio/Sources/FluidAudio/VAD/` — `VadManager.swift`, `VadManager+Streaming.swift`, `VadTypes.swift`; `Agent/AcousticEchoProcessor.swift` `Evidence` (:10–23) and how it is computed (:680–702).

**FluidAudio VAD API (verified in the resolved checkout, revision 4dbf4f9, 0.15.6):**
- `public actor VadManager`; `public static let chunkSize = 4096` (256 ms at 16 kHz), `public static let sampleRate = 16000`; the model input is 4096 new samples + a 64-sample context.
- `public init(config: VadConfig = .default, progressHandler: ProgressHandler? = nil) async throws` — loads `silero-vad-unified-256ms-v6.2.1.mlmodelc` through `ModelHub` from `FluidInference/silero-vad-coreml` (MIT) into `~/Library/Application Support/FluidAudio/Models/`, **downloading it if missing** (~1 MB; this Mac has only v6.0.0). Also `init(config:vadModel:)` and `init(config:modelDirectory:progressHandler:)`.
- `public struct VadConfig { defaultThreshold: Float = 0.85; debugMode = false; computeUnits: MLComputeUnits = .cpuAndNeuralEngine }`.
- `public func process(_ samples: [Float]) async throws -> [VadResult]` — splits into 4096-sample chunks and runs them **from a fresh LSTM state** each call; one 4096-sample window → exactly one `VadResult { probability: Float; isVoiceActive: Bool; processingTime: TimeInterval; outputState: VadState }`.
- `public func makeStreamState() -> VadStreamState` and `public func processStreamingChunk(_ audioChunk: [Float], state: VadStreamState, config: VadSegmentationConfig = .default, returnSeconds: Bool = false, timeResolution: Int = 1) async throws -> VadStreamResult` (`state`, `event: VadStreamEvent?` with `.speechStart`/`.speechEnd`, `probability`). A chunk shorter than 4096 is **padded by repeating its last sample** and a longer one is truncated (`processChunk`, VadManager.swift:162–181) — never feed it short chunks.
- `VadSegmentationConfig(minSpeechDuration: 0.15, minSilenceDuration: 0.75, maxSpeechDuration: 14, speechPadding: 0.1, …)`; it `assert`s `speechPadding <= minSpeechDuration`.

**Current behaviour:**
- `noteLevel` (AgentCaptureController.swift:884–917): a level ≥ 0.06 sustained 0.12 s raises the input barrier and stages the frontend only if `!RealtimeAudioSession.shared.isSpeaking || nearCandidate`; energy never touches output.
- `considerListeningCandidate` (:919–933) would pause on an acoustic near-candidate, but its comment says "Kept off the live mic path until the physical false-near gate passes", and no production caller exists.
- `considerSpeechInterruption` (:1095–1143) pauses output via `RealtimeAudioSession.pauseForListening` (RealtimeAudioSession.swift:389–405) only for recognized text ≥ `Limits.minCharacters` (2) after `Limits.minSpeech` (0.25 s), and not for a hesitation, backchannel or in-flight repeat. A pause auto-resumes after 0.25 s of quiet or 2.5 s without recognized speech (`listeningQuietRelease`, `listeningMaximumUnrecognizedHold`, :70–71; `reviewListeningPause`, :421–433). The hard stop is at the committed endpoint (`emitTurn` → `userSpeechStarted` → `noteUserSpeech`, :435–451).
- Output level: `RealtimeAudioSession.duckedVolume = 0.65` is the level the agent speaks at during a session (:48–49), applied per clause through `AgentSpeechSynthesizer.utteranceVolume` → `PocketSpeechBacking.speak` sets `engine.mainMixerNode.outputVolume` at clause start (PocketAgentVoice.swift:192). Nothing can change the level of a clause that is already playing.
- AEC evidence per processed chunk: `recentReference` (reference seen < 0.3 s ago), `nearCandidate` (trust ≥ 1, echo coherence < 0.70, cleaned > 0.6 × raw …), `independentNearCandidate` (coherence in (0, 0.55) with raw RMS > 0.025 for ≥ 480 frames) — AcousticEchoProcessor.swift:680–702. The `deliver` closure already reads it (`acoustic = AcousticEchoProcessor.shared.evidenceSnapshot()`, AgentCaptureController.swift:689).

**Target behaviour:**
1. While the agent is speaking, sustained user speech on the cleaned stream **ducks** output to ~20 % of full level within ≤ 200 ms of voice onset — `Interruption.provisional`, reversible.
2. Echo alone never ducks (0 false ducks on the echo-only replay).
3. The existing lexical pause remains (minimum speech lowered to 0.15 s) and the committed endpoint still hard-stops; a duck with no recognized novel speech releases after 300 ms of VAD silence.

**Steps:**

1. **Monitor** (`VoiceActivityMonitor`, `final class … @unchecked Sendable`, `static let shared`):
   ```swift
   struct Probe: Sendable { let probability: Float; let echoOK: Bool; let endSampleIndex: Int; let at: UInt64 }
   func load() async throws                       // try await VadManager(config: VadConfig(defaultThreshold: 0.5, computeUnits: .cpuAndNeuralEngine))
   func ingest(_ cleaned: AVAudioPCMBuffer, evidence: AcousticEchoProcessor.Evidence, capturedAt: UInt64)
   var onProbe: (@Sendable (Probe) -> Void)?
   func reset()
   static let hopSamples = 800                    // 50 ms; two probes per 100 ms capture batch today
   ```
   `ingest` appends to a 4096-sample ring; each time ≥ `hopSamples` new samples have arrived it takes the **last 4096 samples** and, if no probe is in flight (never queue probes), runs `let r = try await vad.process(window)` on a private `Task`; `probability = r.first?.probability ?? 0`. This is a stateless sliding window (fresh LSTM state per call) chosen for latency: the stateful `processStreamingChunk` needs a full 4096-sample hop (256 ms) per step. `echoOK = !evidence.recentReference || evidence.independentNearCandidate || evidence.nearCandidate`, taken from the evidence of the chunk that completed the window. Call it from the `deliver` closure (AgentCaptureController.swift:687–711) right after `AcousticEchoProcessor.shared.process(chunk)`; load it at session start (P2-07 keeps it resident). If the model cannot load, the monitor is inert and today's behaviour applies.
2. **Decision** (in `AgentCaptureController`, main actor, reached by `DispatchQueue.main.async` from `onProbe` — not one `Task` per probe):
   ```swift
   enum VoiceDuckPolicy { static let onThreshold: Float = 0.6; static let offThreshold: Float = 0.35
                          static let requiredConsecutive = 2; static let releaseAfter: TimeInterval = 0.30 }  // estimates
   private func noteVoiceActivity(_ probe: VoiceActivityMonitor.Probe)
   ```
   Count consecutive probes with `probability ≥ onThreshold && echoOK`; at `requiredConsecutive`, if `RealtimeAudioSession.shared.isSpeaking`, call `RealtimeAudioSession.shared.duckForListening(captureID:)` and stamp `.bargeDuck`. Count probes with `probability < offThreshold` since the duck; after `releaseAfter` with no novel recognized text (`transcript` empty or only a hesitation/backchannel), call `releaseDuck`. A duck never raises the input barrier, cancels work, or starts a turn — it is output-only.
3. **Duck mechanics.** `RealtimeAudioSession`: `static let bargeDuckGain: Float = 0.3` (on top of the 0.65 speaking level ⇒ ≈ 0.2 of full — the A §3 #5 target), and
   ```swift
   @discardableResult func duckForListening(captureID: UUID) -> Bool   // same guards as pauseForListening: isActive, isSpeaking, synth.isSpeaking, outputGeneration binding
   func releaseDuck(captureID: UUID)
   ```
   `AgentSpeechBacking` gains `func setOutputGain(_ gain: Float)` with a default empty implementation in a protocol extension; `PocketSpeechBacking` sets `player.volume = gain` (the player node is upstream of the main mixer, so the mixer tap that feeds the echo canceller sees the ducked signal — the reference stays truthful). `AgentSpeechSynthesizer.setOutputGain(_:)` forwards to the backing and remembers it; **reset to 1.0** in `prepareForStream` (:154), `stop` (:209), `restoreSystemBacking` (:301) and `RealtimeAudioSession.noteOutputFinished`/`stopOutput`, or a new reply would start ducked.
4. **Lexical pause earlier.** Add `Limits.minSpeechForPause: TimeInterval = 0.15` and use it instead of `Limits.minSpeech` only in the `considerSpeechInterruption` pause condition (:1123). Keep `minSpeech` (0.25 s) for endpoints and speculation.
5. **Leave `considerListeningCandidate` unwired.** The duck is the reversible, lower-risk replacement for it; the physical false-near gate its comment mentions still has not passed.
6. **Notices.** Add Silero VAD to the runtime-download table in `THIRD-PARTY-NOTICES.md`: `| Silero VAD, CoreML (FluidInference/silero-vad-coreml, via FluidAudio's ModelHub) — ~1 MB | voice activity model | MIT |` (Hub metadata `license: mit`, checked 2026-09-23).
7. **(Optional last step, owner-gated) Full speaking level; duck only on onset.** (H-audit 2026-09-23, H2 V29.)
   Today every reply in a session plays at 65 % of full level, whether or not anyone is talking:
   ```swift
   // Agent/RealtimeAudioSession.swift:48-50
   /// Lowered playback while the agent is speaking. Best-effort ducking only.
   static let duckedVolume: Float = 0.65
   static let fullVolume: Float = 1.0
   // RealtimeAudioSession.applySpeakingVolumeIfActive @ :461-465
   AgentSpeechSynthesizer.shared.utteranceVolume = duckingEnabled ? Self.duckedVolume : Self.fullVolume
   ```
   That constant was the only echo defence before this task. Do this step **only when all three
   hold**: (a) steps 1–6 are green (`VOICE_DUCK_OK`, the barge duck assertion); (b) the one physical
   `Scripts/run-selftest.sh --via-open --selftest-voice-echo-live` run with speakers on has printed
   `VOICE_ECHO_LIVE_DUCKS=0`; (c) the owner has written "V29 go" in the P2-05 row of STATUS.md. If
   any is missing, skip the step, write "V29 not run: <which condition>" in STATUS.md, and the task
   is still done. When all three hold:
   - make `applySpeakingVolumeIfActive` assign `Self.fullVolume` and delete `duckedVolume` (grep
     it: today its only other readers are the `--selftest-duplex` assertions in
     `RealtimeAudioSession.speakingStateFailures`, :971-982);
   - change `bargeDuckGain` from 0.3 to **0.2**, so a duck still lands at ≈ 0.2 of full level
     (step 3 computed 0.3 on top of 0.65);
   - in `speakingStateFailures` replace "speaking should duck utterance volume to 0.65" with two
     checks: while speaking and not ducked, `utteranceVolume == fullVolume`; after
     `duckForListening`, the backing's gain is `bargeDuckGain` and it returns to 1.0 at the next
     reply boundary (`prepareForStream`, step 3's reset list);
   - re-run the echo-live test **once** at the user's normal speaker level: it must still print
     `VOICE_ECHO_LIVE_DUCKS=0` and commit no turn from the agent's own voice. If it does not,
     restore 0.65 (one constant), record both runs' numbers in STATUS.md, and stop.

**Do not:**
- Raise the speaking level (step 7) before the physical echo-live run and the owner's "V29 go" — a louder reply is more echo on the microphone, and the file-fed tests cannot measure a real room (H-audit 2026-09-23). Never loop `--via-open` to get a passing run.
- Pause or stop output from VAD alone — the duck is the only VAD effect; a committed turn is still the only hard stop (AGENTS.md: provisional recognition pauses reversibly, only a committed user turn stops output).
- Treat energy or VAD during playback as user speech without the echo gate.
- Feed the stateful streaming API chunks shorter than 4096 samples.
- Run VAD inference on the Core Audio callback or the main actor; the capture lane only appends to the ring.
- Disable Speex denoise to "help" the VAD — that also bypasses residual echo suppression (AGENTS.md).
- Forget to reset the gain at the next reply.

**Red-first self-test:**
- **Extend `--selftest-voice-barge`** (`runVoiceBargeSelfTest`, AgentCaptureController.swift:1533–1632): observe `.bargeDuck` (add a `lastListeningDuckAt` on `RealtimeAudioSession` like `lastListeningPauseAt`, :62), print `VOICE_BARGE_VOICE_TO_DUCK=<s>` measured from `fileFirstVoiceAt`, and fail with `VOICE_BARGE_WRONG: voice to duck <s> > 0.200` when `--voice-feed-10ms` is passed (the 80 ms default feed cadence alone adds up to 80 ms of quantisation), and `VOICE_BARGE_WRONG: no duck before pause` if the duck came after the pause or never. Existing assertions stay (reversible pause before hard stop; no clause restarts after barge-in). **Red today:** no duck exists → "no duck before pause".
- **New `--selftest-voice-duck [far-wav] [near-wav]`** (`Agent/Voice/VoiceDuckSelfTest.swift`), no devices, deterministic, in **sample time** (not wall clock): a fresh `AcousticEchoProcessor()` (its initializer is internal; the replay self-tests at AcousticEchoProcessor.swift:790+ construct their own) and a fresh `VoiceActivityMonitor` with a synchronous test entry point. Far = `haiku16k.wav` fed with `feedRendered` in 480-sample buffers; (1) near = far delayed 30 ms × 0.35 (pure echo) through `process` → the monitor → `VoiceDuckPolicy` must produce **zero** duck decisions; (2) near = the same echo + `stop16k.wav` mixed in at 1.0 s → a duck decision within 0.200 s of `stop16k`'s first sample ≥ 0.06 (sample index / 16,000). Defaults from `~/Library/Caches/NextNotesBuild/voice-fixtures/`. Last line `VOICE_DUCK_OK` / `VOICE_DUCK_FAILED: <reason>` / `VOICE_DUCK_ABSENT: <VAD model or fixtures missing>`. Red today: the monitor does not exist (write the test against the new type; it fails to decide anything → "no duck on double talk").

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-voice-duck
Scripts/run-selftest.sh --selftest-voice-barge ~/Library/Caches/NextNotesBuild/voice-fixtures/stop16k.wav --voice-feed-10ms
Scripts/run-selftest.sh --selftest-voice-barge ~/Library/Caches/NextNotesBuild/voice-fixtures/stop16k.wav
```
Regression flags: `--selftest-voice-turns` (reversible listening and backchannel cases), `--selftest-duplex`, `--selftest-acoustic-replay`, `--selftest-voice-suspend`, `--selftest-playback-ledger`, `--selftest-voice-delivery`; once, with speakers on and nobody talking, `Scripts/run-selftest.sh --via-open --selftest-voice-echo-live` (must report no duck — add a `VOICE_ECHO_LIVE_DUCKS=<n>` diagnostic and fail on n > 0); then `make acceptance TIER=core`. Add `"selftest-voice-duck|300"` to the INTEGRATION tier.

**Success threshold:** `VOICE_BARGE_VOICE_TO_DUCK` ≤ 0.200 s with `--voice-feed-10ms` (today: no duck; 0.838 s to pause); `VOICE_BARGE_VOICE_TO_PAUSE` ≤ 0.838 s (no regression; expected lower with 0.15 s minimum); `VOICE_DUCK_OK` with 0 false ducks; `VOICE_ECHO_LIVE_DUCKS=0` on the one live run. Step 7, if run (H-audit 2026-09-23): `DUPLEX_OK` with the new speaking-level checks, and `VOICE_ECHO_LIVE_DUCKS=0` again at full level.

**Risks & rollback:** VAD fires on the agent's own residual echo in a real room (the echo gate uses the same evidence that has not passed the physical false-near test) — the cost of a false duck is a brief dip in volume, which is why the effect is a duck and not a pause. With today's 100 ms capture batches the detection may land at 200–250 ms (**estimate**); if so, record it and re-measure after P2-08. Rollback: `VoiceActivityMonitor.load` not called → inert; the minimum-speech change is one constant. Step 7 (H-audit 2026-09-23): full level can bring back echo turns in a loud room — notice it as `discarded playback echo` lines or a committed turn that repeats the agent's words; rollback is restoring `duckedVolume = 0.65` and `bargeDuckGain = 0.3`.

**Done when:**
- [ ] `VoiceActivityMonitor`, `VoiceDuckPolicy`, `Interruption` enum, duck/release, gain reset on every reply boundary.
- [ ] `--selftest-voice-duck` new (red → green); `--selftest-voice-barge` duck assertion (red → green).
- [ ] Echo-live run shows 0 ducks (or marked "not run: no speakers" in STATUS.md).
- [ ] Notices row; AGENTS.md flag list and a short "barge-in ducks first" paragraph.
- [ ] (H-audit 2026-09-23, optional) Step 7: full speaking level + `bargeDuckGain` 0.2 landed after the echo-live pass and the owner's "V29 go", or "V29 not run: <reason>" recorded in STATUS.md.

---

### P2-06 — TTS pipelining: one `PocketTtsSession` per reply, synth-ahead, engine kept running, comma-first chunk, first-audible ack

**Finding(s):** L6  **Effort:** 2–3 days  **Depends on:** P2-01, **P0-09** (per-clause length cap — this task rewrites the same flush code), P2-07 recommended first (warm Pocket)  **Unblocks:** P3-04 (`OutputScheduler` drives the streaming backing; its delivery ack is this task's first-audible ack)

**Why (what the user experiences today):** The agent pauses between its own sentences, and its
first word waits for a full stop. Clause N+1 is not synthesised until clause N has finished
playing, and the audio engine is stopped and restarted per clause, so every sentence boundary
pays first PCM (0.21–0.28 s warm) + engine start + one 80 ms buffer — **estimated 0.25–0.40 s of
dead air per boundary** (A Hop 10; never measured). The first clause waits for `. ! ? ; —`
(~0–0.30 s of buffering, A Hop 9). The first-audio acknowledgement is the *completion* of the
first 80 ms buffer, so it overstates onset by up to 80 ms (render ack 0.097–0.118 s). FluidAudio's
persistent `PocketTtsSession` (voice KV cache and Mimi decoder state kept across utterances) is
used only for warmup.

**Files you will change:**
- **new** `Agent/Speech/AgentStreamingSpeechBacking.swift` — protocol + `RecordingStreamingSpeechBacking` fake.
- `Agent/Speech/PocketAgentVoice.swift` — `PocketSpeechBacking` conforms; spare session in `PocketAgentVoice`.
- `Agent/Speech/AgentSpeechSynthesizer.swift` — streaming mode for the clause ledger.
- `Agent/Speech/StreamingSpeechBuffer.swift` — comma-first first chunk, offset-based flushing, `finishStream()` call.
- `Agent/RealtimeAudioSession.swift` — `finalizeSpokenReply` / `speak` call `finishStream`.
- **new** `Agent/Speech/TTSPipelineSelfTest.swift` — `--selftest-tts-pipeline`; `Agent/VoiceDeliverySelfTest.swift` — fake streaming backing stage.
- `NextNotesApp.swift`, `Scripts/acceptance.sh`, `AGENTS.md`.

**Read for context (do not change):** FluidAudio `PocketTtsSession` (checkout `…/FluidAudio/Sources/FluidAudio/TTS/PocketTTS/Pipeline/PocketTtsSession.swift`) and `PocketTtsManager.makeSession(voice:temperature:seed:)` (`PocketTtsManager.swift:281`); `Agent/Speech/PocketTtsSessionSelfTest.swift` (proves the session emits two utterances in order with `utteranceIndex` 0 and 1); `Agent/VoicePlaybackDelivery.swift` and `RealtimeAudioSession.receivePlaybackEvent` (RealtimeAudioSession.swift:325–339) — the per-clause events they depend on.

**FluidAudio `PocketTtsSession` API (0.15.6, verified):** `public actor PocketTtsSession`;
`public nonisolated let frames: AsyncThrowingStream<PocketTtsSynthesizer.AudioFrame, Error>`
(80 ms / 1,920 samples at 24 kHz each); `public nonisolated func enqueue(_ text: String)` —
non-async, callable from anywhere, may be called repeatedly while earlier text is synthesising;
`public nonisolated func finish()` — completes `frames` after all enqueued text;
`public func cancel() async` — returns only after CoreML predictions stopped. `AudioFrame`
carries `samples`, `frameIndex`, `chunkIndex`, `chunkCount` and **`utteranceIndex: Int?`**
(set in session mode: one index per `enqueue` call, in order). The generation loop **skips
whitespace-only text without consuming an index** (`guard !trimmed.isEmpty else { continue }`,
PocketTtsSession.swift:223–224), so never enqueue empty text or indices will drift. Creating a
session runs the voice prefill (~125 tokens) once.

**Current behaviour:**
- `AgentSpeechSynthesizer.enqueueClause` (AgentSpeechSynthesizer.swift:192–204) starts a clause only when idle, else appends to `pendingClauses`; `advanceQueue` (:348–359) starts the next clause only from `didFinishAudio`, i.e. after the previous clause has **played**.
- `PocketSpeechBacking.speak` (PocketAgentVoice.swift:170–235) calls `PocketAgentVoice.frames(for:voice:)` → `manager.synthesizeStreaming(text:voice:)` (:63–72), a one-shot synthesis per clause; it starts the engine if needed (:193), schedules each frame with `.dataPlayedBack` (:215–218) and acknowledges first audio when the **first frame finished playing** (`framePlayed`, :261–279). `finishIfDrained` (:281–290) stops the player and the engine and calls `VoicePlaybackReference.stopped()` after every clause.
- `StreamingSpeechBuffer.flush` (StreamingSpeechBuffer.swift:79–93) recomputes `splitIntoClauses(spokenForm(buffer))` over the whole buffer on every delta and enqueues clauses past `flushedCount`; a clause is complete only when it ends in `. ! ? ;` or `—` (`isCompleteClause`, :103–108). Commas never flush.
- The per-clause ledger (`PlaybackEvent.enqueued / startAcknowledged / completed / interrupted(wasRendered:)`) feeds echo masking (`receivePlaybackEvent`: a clause becomes an echo reference only once `startAcknowledged`) and `VoicePlaybackDelivery` (what the user has confirmably heard). `--selftest-playback-ledger`, `--selftest-voice-delivery`, `--selftest-voice-suspend` pin it.
- `--selftest-tts-pocket` (PocketAgentVoice.swift:74–137) asserts the one-clause `speak` path stops its engine after draining (`!playback.isPlaybackEngineRunning`, :112).

**Target behaviour:**
1. One reply = one `PocketTtsSession`: each clause is enqueued the moment it is complete, so clause N+1 synthesises while clause N plays; frames of consecutive clauses are scheduled back-to-back on one running player.
2. The engine runs for the whole reply and stops after the last clause drained (or on stop/barge-in). A single-clause `speak` still stops after draining (the Pocket self-test stays true).
3. The per-clause ledger is unchanged in meaning: each clause gets `.startAcknowledged` when its **first audible samples** played and `.completed` when its last frame played, in order.
4. First audible acknowledgement ≤ ~20 ms after the first samples start playing (not 80 ms).
5. The first clause of a reply may flush at a comma after ≥ 4 words, or at a word boundary after ≥ 8 words without punctuation; later clauses keep sentence boundaries.
6. Inter-clause silence on a three-sentence reply ≤ 50 ms.

**Steps:**

1. **Protocol** (new file):
   ```swift
   @MainActor protocol AgentStreamingSpeechBacking: AgentSpeechBacking {
       func beginReply() throws                                 // takes a prepared PocketTtsSession, starts engine + player
       func enqueue(_ clause: String, token: UInt64)            // returns immediately; synth-ahead
       func finishReply()                                       // no more clauses; engine stops after drain
       var onClauseStarted: ((UInt64) -> Void)? { get set }     // first audible samples of that clause
       var onClauseFinished: ((UInt64) -> Void)? { get set }    // last frame of that clause played
   }
   ```
   `stop()`, `pauseForListening()`, `resumeAfterListening()`, `setOutputGain(_:)` (P2-05) come from `AgentSpeechBacking`.
2. **Spare sessions.** In `PocketAgentVoice` add `private var spare: (voice: String, session: PocketTtsSession)?` and `func takeSession(voice: String) async throws -> PocketTtsSession` (returns the spare when the voice matches, else `try await manager.makeSession(voice:)`) followed by a detached `.utility` refill of the spare. `warmFirstPrediction` (:44–61) creates the first spare instead of discarding its session: after the warm "Ready." completes, `await session.cancel()` stays as is (a session that has produced audio carries Mimi state), then make a fresh spare. Cancel the spare on memory pressure (P2-07 hook).
3. **`PocketSpeechBacking` streaming mode.** State per reply: `session`, `clauseTokens: [UInt64]` (index = `utteranceIndex`), per-clause `scheduledFrames` / `playedFrames` counters, `producerDoneThrough: Int` (highest utterance whose last frame was produced — known when the first frame of the next utterance arrives, or when `frames` ends), `replyFinished: Bool`, one consumer `Task { @MainActor }` iterating `session.frames`.
   - `beginReply()`: take a session (bounded 10 s wait as `frames(for:)` does today, :68–70; on timeout or error throw so the synthesizer falls back per clause, step 5); set `engine.mainMixerNode.outputVolume` and `player.volume`; `if !engine.isRunning { try engine.start() }`; `player.play()`; start the consumer.
   - `enqueue(clause, token)`: guard `!clause.trimmed.isEmpty`; append token; `session.enqueue(clause)`.
   - Consumer, for each frame: map `frame.utteranceIndex!` to its token; for the **first frame of an utterance**, schedule it as two buffers — the first **240 samples (10 ms)** with a `.dataPlayedBack` callback that fires `onClauseStarted(token)`, then the remaining 1,680 samples — so the start acknowledgement comes ~10 ms after audible onset instead of after 80 ms (this replaces the first-frame ack at :263–276). All other frames: one buffer, `.dataPlayedBack` → count played frames; when an utterance's `playedFrames == scheduledFrames` and `producerDoneThrough >= its index`, fire `onClauseFinished(token)`.
   - `finishReply()`: `replyFinished = true`; `session.finish()`. When `frames` ends and every clause finished → `player.stop()`, `engine.stop()`, `VoicePlaybackReference.stopped()` — once per reply, not per clause.
   - `stop()`: cancel the consumer, `player.stop()`, `engine.stop()`, `VoicePlaybackReference.stopped()`, then `Task.detached { await session.cancel() }` (do not await CoreML teardown on the main actor), clear state.
   - `pauseForListening()` / `resumeAfterListening()`: unchanged semantics (`player.pause()` / `player.play()`); synthesis keeps running ahead while paused — bound it: if more than 3 s of audio is scheduled and unplayed, stop enqueuing new clause text into the session until playback resumes (keep them in a local queue).
   - Keep the old one-shot path as `speakOneShot` and make `speak(text, volume, token)` = `beginReply(); enqueue(text, token); finishReply()` so every existing caller (and `--selftest-tts-pocket`) sees one clause per reply with the engine stopped after drain.
4. **Synthesizer streaming mode.** In `AgentSpeechSynthesizer`, when `backing` conforms to `AgentStreamingSpeechBacking`: `prepareForStream` (:154) calls `beginReply()` lazily on the first clause; `enqueueClause` (:192) assigns `playbackTokenCounter &+= 1`, appends `(token, clause)` to an ordered `inFlight` list, emits `.enqueued`, and calls `backing.enqueue(clause, token:)` immediately (no `pendingClauses` wait). `currentClause`/`currentPlaybackToken` = the head of `inFlight`. `onClauseStarted(token)` → for the head: `.startAcknowledged`, first-audio callback (`onFirstAudio`, :56–59) as `didBeginAudio` does (:317–326). `onClauseFinished(token)` → `.completed` for the head, pop, and the new head is current. When `inFlight` empties and the reply is finished → `RealtimeAudioSession.shared.noteOutputFinished()` (what `advanceQueue` does today, :352–354). `stop()` (:209) emits `.interrupted(clause, wasRendered:)` for every in-flight clause (true only for the head if it started). `isSpeaking` = backing speaking or `inFlight` non-empty. Add `func finishStream()` → `backing.finishReply()`; call it from `StreamingSpeechBuffer.finalize` (after its flush) and at the end of `speak(_:)` (:140–150). The non-streaming backings (Apple, Kokoro, recorder) keep today's clause-at-a-time code path unchanged.
5. **Fallback.** If `beginReply()` throws or the session fails mid-reply, route the clauses that have not started to today's per-clause path (`fallbackCurrentClause`, :372–383, then the system voice) — never drop them silently. Log the reason.
6. **Comma-first chunk.** In `StreamingSpeechBuffer` replace `flushedCount` with `flushedCharacters` (offset into `spokenForm(buffer)`, which only trims — the offset is stable as the buffer grows; after P0-09 re-check this: if P0-09 made `spokenForm` transform text, flush by clause index again and apply the rule below only to the first clause). While nothing has been enqueued in this reply (`!didEnqueue`), also accept as complete: text up to and including the first `,` / `:` / `、` when ≥ 4 words precede it and the next character is whitespace (so "1,000" never splits), or the first 8 words when there is no boundary yet (cut at the 8th word's trailing space). Use named constants `firstChunkMinimumWords = 4`, `firstChunkForceWords = 8` (**estimates**). Later clauses use `isCompleteClause` unchanged.
7. **Ledger compatibility checks.** `RealtimeAudioSession.receivePlaybackEvent` must still see `.startAcknowledged(text)` before echo masking learns a clause, and `.completed(text)` with the same text. `VoicePlaybackDelivery` must still mark only started-and-completed clauses as heard.
8. **Spans.** P2-01's `ttsFirstPCM` / `firstAudible` stamps move with the code (first produced frame / the 240-sample head's played callback). Emit `voice.inter_clause_gap` per boundary from the playback timeline (step 9's formula) with `note="boundary=<n>"`.
9. **`--selftest-tts-pipeline`** (new, model-backed, `Agent/Speech/TTSPipelineSelfTest.swift`): preconditions — Pocket model present (same check as P2-01) else `TTS_PIPELINE_ABSENT: Pocket voice not downloaded`. Use a dedicated `PocketSpeechBacking` behind `AgentSpeechSynthesizer.useTestingBacking` (volume 0 via `utteranceVolume = 0`, as `--selftest-tts-pocket` plays at volume 0). Add a test-only observer `bufferPlayedForTesting: ((_ utterance: Int, _ frames: Int, _ playedAt: UInt64) -> Void)?` on the backing. Stream "The first note is ready. I will keep working while we talk. You can interrupt me at any time." through a `StreamingSpeechBuffer` in three `append` calls 50 ms apart, then `finalize`. For each boundary n: `gap = playedAt(first buffer of n+1) − playedAt(last buffer of n) − duration(first buffer of n+1)`. Assert: max gap ≤ 0.050 s; engine started exactly once for the reply (count `engine.start` calls in the backing); ledger shows 3 × `.startAcknowledged` then `.completed` in order with the exact clause texts; first-audible ack arrived ≤ 0.030 s after the first head buffer was scheduled plus one IO cycle. Print `TTS_PIPELINE_GAP boundary=<n> s=<gap>`; last line `TTS_PIPELINE_OK` / `TTS_PIPELINE_FAILED: <reason>`.
   **Fake stage in `--selftest-voice-delivery`:** add `RecordingStreamingSpeechBacking` (records `enqueue` order, lets the test fire `onClauseStarted`/`onClauseFinished`) and assert: all three clauses reach `enqueue` before the first finishes (synth-ahead); a stop after clause 1 started emits `.interrupted(c1, wasRendered: true)`, `.interrupted(c2, false)`, `.interrupted(c3, false)`; the delivery ledger marks only c1 as heard.

**Do not:**
- Change what a clause event means — echo masking and "what the user heard" depend on it (AGENTS.md: "a completed clause is not proof of physical audibility"; results are acknowledged on first audible frame, decision doc §3.5 items 3–4).
- Keep the engine running between replies: idle zero buffers would reach the echo canceller as a live reference (see the note in `AcousticEchoProcessor.feedRendered`, :226–240). Engine lifetime = one reply.
- Await `PocketTtsSession.cancel()` on the main actor, or enqueue empty/whitespace text.
- Speak the comma-first chunk as a separate sentence in the ledger text — the ledger text is exactly what was enqueued.
- Remove the one-shot path; it is the fallback.

**Red-first self-test:** `--selftest-tts-pipeline` as above. **Red on unmodified code:** write the test against a thin adapter that uses today's clause-at-a-time `speak` when the backing is not streaming — expect `TTS_PIPELINE_FAILED: boundary gap 0.2xx–0.4xx s > 0.050 s` (A's estimate; the first real measurement of it) and "engine started 3 times". The fake stage in `--selftest-voice-delivery` is red because `enqueue` sees clause 2 only after clause 1 finished.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-tts-pipeline
Scripts/run-selftest.sh --selftest-voice-delivery
Scripts/run-selftest.sh --selftest-tts-pocket
Scripts/run-selftest.sh --selftest-tts-pocket-session
Scripts/run-selftest.sh --selftest-voice-latency --voice-latency-runs 5 --selftest-timeout 600
```
Regression flags: `--selftest-playback-ledger`, `--selftest-voice-suspend`, `--selftest-tts-stream`, `--selftest-voice-barge <stop16k.wav>`, `--selftest-realtime`, `--selftest-acoustic-replay`, `--selftest-duplex`, then `make acceptance TIER=core`. Add `"selftest-tts-pipeline|600"` to the EXPERIMENTAL tier (model-backed, like `selftest-tts-pocket`).

**Success threshold:** max inter-clause silence ≤ 0.050 s; in `--selftest-voice-latency`, median `first_pcm_to_audible` ≤ 0.05 s (today 0.118 s), median `clause_to_first_pcm` ≤ 0.10 s (today 0.281 s) and median `first_token_to_clause` ≤ 0.10 s; all ledger/suspend tests green.

**Risks & rollback:** a comma chunk synthesised as its own utterance may get sentence-final prosody (Pocket normalises each enqueued text; the `isMidSentence` flag is internal to its own chunker) — only a human can judge it; add "comma-first prosody unheard" to AGENTS.md's never-run list and keep the two constants easy to disable (`firstChunkMinimumWords = .max`). Synth-ahead spends ANE time on clauses a barge-in will discard; the 3 s cap bounds it. Rollback: make `PocketSpeechBacking` stop conforming to `AgentStreamingSpeechBacking` → the synthesizer's old path runs unchanged.

**Done when:**
- [ ] Streaming protocol, Pocket implementation, spare session, synthesizer streaming mode, fallback.
- [ ] Comma-first first chunk with named constants.
- [ ] `--selftest-tts-pipeline` new (red → green); fake stage in `--selftest-voice-delivery`.
- [ ] Gap ≤ 50 ms and ack ≤ 50 ms recorded in STATUS.md; AGENTS.md updated (flag + unheard-prosody entry).

---

### P2-07 — EOU and Pocket resident; prewarmed at launch or arm

**Finding(s):** L7  **Effort:** 1 day  **Depends on:** P2-01  **Unblocks:** stable warm measurements for P2-02 … P2-06; P3-07 (residency accounting)

**Why (what the user experiences today):** Every voice session loads the Parakeet EOU model
again: **1.67–3.04 s** warm, **9.1–12.7 s** cold (today's runs: 3.04 s and 9.06 s). Until it is
ready, turns end on the 0.9 + 0.35 s fallback and the decoder then works through a backlog (a
5.08 s catch-up lag was seen in a real session). A cold Pocket load (12.6 s) made the first
reply's first PCM take 6.0 s (A Hop 10, §3 #7).

**Files you will change:**
- `Activation/LocalVoiceTurnDetector.swift` — resident instance, `prepareIfNeeded`, `attach`, debounce parameter (shared with P2-04).
- `Activation/AgentCaptureController.swift` — use the resident detector; never `close()` it at session end.
- **new** `Agent/Voice/VoiceModelWarmer.swift` — warm EOU, Pocket, VAD (P2-05), Smart Turn (P2-04); `VoiceReadiness`.
- `Core/Compute/ModelResidencyPolicy.swift` — `ResidentModel.voice`, unload order, protection while a session is open.
- `Activation/ActivationController.swift` (`beginAgent`), `NextNotesApp.swift` (launch hook), wake-arm hook (`WakeWordAudioMonitor.sync` call site when the wake phrase is enabled).
- Island listening card (`UI/Island/`) — "Getting ready…" subtitle while not ready.
- `Agent/Voice/VoiceLatencySelfTest.swift` — per-session prepare assertion.

**Read for context (do not change):** `Core/Compute/ModelResidencyPolicy.swift` (policy + guardian), `Agent/Speech/PocketAgentVoice.swift` `prepare()` (:19–38), AGENTS.md "The notes model unloads itself" and the residency rule for the 4B model (opening the microphone must not load the 4B worker — this task does not touch the GGUF).

**Current behaviour:**
- `startEngine` creates a new detector per session (`let detector = LocalVoiceTurnDetector()`, AgentCaptureController.swift:514), prepares it in a detached task (`detector.prepare`, :522 → `manager.loadModels()` + a silent priming `process`, LocalVoiceTurnDetector.swift:85–107) and closes it when the drain loop ends (`await detector.close()`, :646 → `manager.cleanup()`).
- Pocket is prepared when `AgentSpeechSynthesizer.shared` is first created (its `init`, AgentSpeechSynthesizer.swift:123–131) if the selected engine is Pocket, and on first use via `frames(for:)` (bounded 10 s).
- `ActivationController.beginAgent` (ActivationController.swift:51–76) prewarms the 4B worker (`NotesModelRuntime.shared.prewarm(voice: true)`, :58 — L1, P0-06's subject) but none of the voice models.
- `ModelResidencyPolicy.ResidentModel` = `notes`, `diarization`, `asr`, `wake`; pressure unload order `notes` → `diarization` (ModelResidencyPolicy.swift:39–57).

**Target behaviour:**
1. One EOU detector per process, prepared once; each session re-attaches callbacks and resets decoder state. The second session in a process spends 0 s preparing it.
2. EOU, Pocket (with a spare session, P2-06), Silero VAD and Smart Turn are warmed at background priority at launch when the wake phrase is enabled, when the wake phrase is switched on, and at `beginAgent` — never on a turn's critical path.
3. `VoiceReadiness` says which are ready; the island shows "Getting ready…" under the listening card until EOU and TTS are ready.
4. Under memory pressure, voice models unload after notes and diarization, and never while a voice session is open.

**Steps:**

1. `LocalVoiceTurnDetector`: add `static let shared = LocalVoiceTurnDetector()` (the actor's `init(eouDebounceMs:)` from P2-04; if the debounce needed changes because Smart Turn became available, replace the shared instance between sessions only); `func prepareIfNeeded() async throws` (the body of `prepare` without callbacks; no-op when `ready`); `func attach(onEndOfUtterance:onPartial:) async` (= `resetForNextTurn` without the `ready` guard issue: `manager.reset()` + callbacks). Keep `operationBusy` serialisation for every operation (AGENTS.md: "FluidAudio EOU operations must remain serialized across awaits; its actor can reenter during inference").
2. `AgentCaptureController.startEngine` (:439–743; detector at :514–522): use `LocalVoiceTurnDetector.shared`; in the detached task `try await detector.prepareIfNeeded()` then `await detector.attach(onEndOfUtterance: eouCallback, onPartial: partialCallback)`; record `voice.eou_prepare` with the time spent (≈ 0 when resident). Replace `await detector.close()` (:646) with `await detector.resetForDiscontinuity()`. Nothing else in the drain loop changes.
3. `VoiceModelWarmer` (`@MainActor final class`, `static let shared`):
   ```swift
   @Observable final class VoiceReadiness { var eou = false; var tts = false; var vad = false; var turnModel = false
                                            var isReady: Bool { eou && tts } }
   func warm(reason: String)   // idempotent; Task.detached(priority: .utility) for each model; logs per-model durations
   ```
   EOU → `LocalVoiceTurnDetector.shared.prepareIfNeeded()`; TTS → `PocketAgentVoice.shared.prepare()` only when `Settings.shared.agentVoiceEngine == "pocket"` **and** the Pocket model is already on disk (never download it here); VAD → `VoiceActivityMonitor.shared.load()`; turn model → `SmartTurnModels.downloadIfNeeded()` then load. Call sites: at launch after a 10 s delay when `Settings.shared.voiceWakeEnabled` (NextNotesApp's launch path, after `ActivationController.start()`), from the wake-phrase toggle's `didSet` (Settings.swift:640–643 already calls `WakeWordAudioMonitor.shared.sync()` — call the warmer next to that call site's owner, not inside `Settings`), and first thing in `ActivationController.beginAgent`. Do **not** warm during a self-test unless the test asks (`SelfTest.isRunning` guard).
4. Residency: add `case voice` to `ResidentModel`; `pressureUnloadPriority = [.notes, .diarization, .voice]`; `unloadOrder(resident:wakeNeeded:asrNeeded:voiceNeeded:)` protects `.voice` while `voiceNeeded` (a voice session is open). The guardian's unload for `.voice`: `LocalVoiceTurnDetector.shared.close()`, drop Pocket's spare and `manager.cleanup()`, set readiness false. Keep the existing signatures working (default `voiceNeeded: true`) so current callers compile.
5. Island: while `!VoiceReadiness.isReady` show the subtitle "Getting ready…" on the agent-listening card (a plain string; no developer words — `--selftest-ui-strings` scans `UI/`). Red still means recording only; do not add colour.
6. Self-test: in `VoiceLatencySelfTest`, fail with `VOICE_LATENCY_WRONG: session <n> spent <s> s preparing the EOU model` when `eou_prepare > 0.050` for any counted run (runs 1…N are the 2nd…N+1th sessions in the process), and with `…first PCM <s> s in a warm session` when `clause_to_first_pcm > 0.12` in run 1. Extend `ModelResidencyPolicy`'s self-test (`--selftest-residency`): `.voice` never appears in the unload order while `voiceNeeded`, and appears after `.diarization` otherwise.

**Do not:**
- Load or prefill the 4B GGUF from the warmer (AGENTS.md: opening the microphone must not load the worker; the P0-06 rule on warmup priority).
- Download Pocket, or any GGUF, from the warmer; Pocket downloads only when the user asks in Models settings.
- Close the resident detector at session end, or call its operations without the operation gate.
- Warm on the main actor or at `.userInitiated` during a turn.

**Red-first self-test:** the `eou_prepare` assertion in `--selftest-voice-latency` (step 6). **Red today:** each session prepares again — expect `VOICE_LATENCY_WRONG: session 2 spent 1.6–3.1 s preparing the EOU model` (A: 1.67–3.04 s warm). `--selftest-residency` red on the new `.voice` cases before step 4.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-residency
Scripts/run-selftest.sh --selftest-voice-latency --voice-latency-runs 5 --selftest-timeout 600
Scripts/run-selftest.sh --selftest-voice-rapid ~/Library/Caches/NextNotesBuild/voice-fixtures/haiku16k.wav ~/Library/Caches/NextNotesBuild/voice-fixtures/stop16k.wav
Scripts/run-selftest.sh --selftest-voice-eou ~/Library/Caches/NextNotesBuild/voice-fixtures/haiku16k.wav
Scripts/run-selftest.sh --selftest-ui-strings
```
Regression flags: `--selftest-voice-pipeline <haiku16k.wav> --voice-feed-10ms` (its `10ms cold capture lost EOU input` check must still hold), `--selftest-voice-barge <stop16k.wav>`, `--selftest-tts-pocket`, `--selftest-wake-live`, then `make acceptance TIER=core`.

**Success threshold:** `eou_prepare` ≤ 0.050 s in every counted run; run-1 `clause_to_first_pcm` ≤ 0.12 s; process resident memory after warm-up (print `ProcessSnapshot.current().residentMemoryBytes` before/after in the latency test as `resident_mb_before/after`) recorded in STATUS.md (**estimate** +0.4–0.8 GB; there is no measurement yet).

**Risks & rollback:** ~0.5 GB more resident memory on a 16 GB Mac while the voice feature is on; the pressure path is the mitigation. A resident decoder left in a bad state carries it into the next session — `attach` resets it and `resetForDiscontinuity` runs at session end. Rollback: restore the per-session detector (one line in `startEngine`) and stop calling the warmer.

**Done when:**
- [ ] Resident detector with `prepareIfNeeded` / `attach`; no `close()` at session end.
- [ ] `VoiceModelWarmer` + `VoiceReadiness` + island subtitle; call sites wired.
- [ ] `.voice` residency and pressure order; `--selftest-residency` green.
- [ ] `eou_prepare` ≤ 0.05 s from the second session on; memory delta recorded.

---

### P2-08 — Smaller audio I/O buffers (capture and output)

**Finding(s):** L8  **Effort:** 1.5 days  **Depends on:** P2-01; do it last in the phase  **Unblocks:** the last 50–100 ms of every audio hop; better AEC alignment (and so, later, a safer acoustic barge-in)

**Why (what the user experiences today):** Every stage that starts from audio inherits a
0–100 ms (mean ~50 ms) delay because the input tap delivers ~100 ms batches although it asks for
2,048 frames; capture → processing measured **63–71 ms**, and **~18 ms** with the experimental
`AVAudioSinkNode` capture (A Hop 1; `Tests/Reports/voice-conversation-analysis-2026-09-14.md`
:260–281). The output reference for the echo canceller arrives in 4,800-frame (100 ms) callbacks
~80.6 ms late, which weakens echo cancellation and is part of why barge-in cannot trust energy.

**Files you will change:**
- `Core/AudioCaptureHub.swift` — sink capture by default; IO buffer size while the Agent consumer is subscribed.
- `Agent/AcousticEchoProcessor.swift` — capture → process timing on the Speex path.
- `Agent/Speech/PocketAgentVoice.swift` — output IO buffer size for the reply engine.
- **new** `Core/AudioDeviceBufferSize.swift` — get/set/restore `kAudioDevicePropertyBufferFrameSize`.
- `Core/AudioCaptureHub.swift` `runLiveMicrophoneSelfTest` (:499–543) — latency report.
- `AGENTS.md` (`--capture-tap` escape hatch).

**Read for context (do not change):** `Core/AudioSinkCaptureRing.swift` (hardware callback → drain lane), `Agent/Speech/PocketSourceSpeechBacking.swift` and `AgentPCMRenderer` (source-node output — **not** promoted here), `Tests/Reports/voice-conversation-analysis-2026-09-14.md` :250–290 (why the hybrid AEC3/source experiments were not promoted).

**Current behaviour:**
- `AudioCaptureHub.startEngine` (AudioCaptureHub.swift:253–296) installs `input.installTap(onBus: 0, bufferSize: 2048, …)` (:277–282) unless `sinkSelected` — which is true only with `--capture-sink` or `--selftest-microphone-sink` (:44–46), in which case an `AVAudioSinkNode` feeds `AudioSinkCaptureRing` (32 slots × 4,096 frames).
- Per-consumer delivery lane `maxPending = 8` (:387).
  (H-audit 2026-09-23, H2 V24) That bound counts **callbacks**, not audio. `AudioCaptureDeliveryWorker`
  @ `Core/AudioCaptureHub.swift:384`; its comment (:385-386) reads "Eight 2048-frame buffers is about
  one second at 16 kHz", and `enqueue(source:level:captureHostTime:)` (:425) drops as soon as
  `pending < Self.maxPending` fails (:431). At 2,048 frames that is ~1 s of slack. After this task's
  10 ms IO it is 8 × 10 ms = **80 ms**, so any main-lane hiccup longer than 80 ms drops agent audio
  and resets the EOU decoder. The same lesson is already written down for the EOU backlog:
  `TurnAudioBacklog` (`Activation/AgentCaptureController.swift:21-26`, "Bound queued *audio time*,
  not the number of callbacks", `maxFrames = 96_000`).
- `AcousticEchoProcessor` records capture → process timing only on the AEC3 evaluation path (`captureTiming.add`, AcousticEchoProcessor.swift:504–513); the production Speex path records none.
- `VoicePlaybackReference.install` taps the output mixer with `bufferSize: 480` (VoicePlaybackReference.swift:11); callbacks actually arrive as 4,800 frames at 48 kHz (A Hop 1).
- No code sets a device IO buffer size.

**Target behaviour:**
1. Capture uses the sink node by default (`--capture-tap` restores the tap for comparison/rollback).
2. While the Agent consumer is subscribed, the input device's IO buffer is ~10 ms (480 frames at 48 kHz, clamped to the device's range) and restored when it unsubscribes; the Pocket reply engine's output device likewise for the reply's duration.
3. Live capture → processing p50 ≤ 25 ms, p95 ≤ 40 ms; no dropped buffers.
4. (H-audit 2026-09-23) Every delivery lane holds at least **1.0 s of audio** before it drops,
   whatever the callback size: at least 16,000 frames' worth at 16 kHz (48,000 source frames at
   48 kHz). A 10 ms callback cadence no longer shrinks the slack to 80 ms.

**Steps:**

1. **Measure first.** In `AcousticEchoProcessor.process` (:458) record `captureTiming.add((now − AVAudioTime.seconds(forHostTime: chunk.captureHostTime)) × 1000)` for every path when `captureHostTime != nil`, and add `func captureLatencySnapshot() -> (p50: Double, p95: Double, count: Int)` (keep a bounded array of the last 512 samples). In `runLiveMicrophoneSelfTest`, subscribe a 16 kHz consumer through the same `deliver`-style path, compute capture-host-time → delivery latency per buffer, and print `MICROPHONE_CAPTURE_TO_DELIVERY_MS p50=<ms> p95=<ms> buffers=<n> frames_per_buffer=<n> path=<tap|sink>` before the verdict; fail when `p50 > 25` only if `--microphone-latency-budget 25` is passed (so the existing test's meaning does not change by default). Run it once on the unmodified tap path to record the baseline (expect ~63–71 ms).
2. **Sink by default.** `sinkSelected` becomes `!probe && !CommandLine.arguments.contains("--capture-tap")` (keep accepting `--capture-sink` as a no-op). The sink path already exists and is covered by `--selftest-microphone-sink`.

2b. **Bound the delivery lane by audio time, not callbacks** (H-audit 2026-09-23, H2 V24). Land
   this **before** step 3 shrinks the IO buffer, or step 5's "any drop is a failure" fails for a
   reason that is not the buffer size. In `AudioCaptureDeliveryWorker` (AudioCaptureHub.swift:384):
   ```swift
   /// At least one second of audio may wait for a slow consumer, whatever the callback size.
   /// 10 ms sink callbacks made "eight buffers" 80 ms (H2 V24).
   static let maxPendingSeconds: Double = 1.0
   /// Memory backstop for pathological tiny buffers; never the operative bound for real audio.
   static let maxPendingItems = 512
   private var pendingSeconds: Double = 0          // guarded by `lock`, like `pending`

   func enqueue(source: AVAudioPCMBuffer, level: Float, captureHostTime: UInt64? = nil) -> Bool {
       let seconds = Double(source.frameLength) / source.format.sampleRate   // source rate, before conversion
       lock.lock()
       guard isActive else { lock.unlock(); return false }
       guard pending < Self.maxPendingItems,
             pendingSeconds + seconds <= Self.maxPendingSeconds || pending == 0 else {
           // … unchanged drop + coalesced overflow report …
       }
       pending += 1; pendingSeconds += seconds
       …
   }
   // deliver(_:)'s defer subtracts the same `seconds` (carry it on `Item`), clamped at 0.
   ```
   `pending == 0` always admits one item, so a single buffer longer than 1 s is never dropped
   on an empty lane. Delete `maxPending` and its "Eight 2048-frame buffers" comment; update the
   type's doc comment (:380-383 "the small pending count puts a hard ceiling on memory") to say
   the ceiling is one second of audio per consumer (at 48 kHz stereo Float32 that is ≈ 384 KB —
   compute it from the format in the comment, do not guess). Every consumer (wake, meeting,
   dictation, agent) gets the same bound; none of them is hurt by 1 s of slack, and the wake and
   meeting consumers are exactly the ones that today can lose audio to a hiccup.

   Then update the existing bounded-lane case in `AudioCaptureHub.runSelfTest` (`--selftest-capture`,
   :550; the loop at ~:590-615 feeds 32 buffers of 32 frames, i.e. 64 ms at 16 kHz, into a
   handler that sleeps 10 ms, and requires `report.overflow > 0`). With a time bound those 64 ms no
   longer overflow, so change that case to two cases:
   - **(a) small callbacks are not dropped:** 80 buffers × 160 frames at 16 kHz (80 × 10 ms =
     0.8 s) into a handler that sleeps 10 ms → `report.overflow == 0`, order and host times intact.
     Failure: `"delivery worker dropped audio under one second of backlog"`. **Red today** (the
     old `maxPending = 8` drops from the ninth callback).
   - **(b) the bound still holds:** 160 buffers × 160 frames (1.6 s) into the same slow handler
     → `report.overflow > 0`. Failure: keep the existing `"delivery worker accepted an unbounded backlog"`.
3. **IO buffer size** (`AudioDeviceBufferSize`):
   ```swift
   enum AudioDeviceBufferSize {
       static func deviceID(of unit: AudioUnit) -> AudioDeviceID?     // kAudioOutputUnitProperty_CurrentDevice, global scope
       static func frames(of device: AudioDeviceID) -> UInt32?         // kAudioDevicePropertyBufferFrameSize
       static func range(of device: AudioDeviceID) -> ClosedRange<UInt32>? // kAudioDevicePropertyBufferFrameSizeRange
       @discardableResult static func set(_ frames: UInt32, on device: AudioDeviceID) -> Bool
   }
   ```
   In `AudioCaptureHub.subscribe(.agent, …)` remember the input device's current frames and set `clamp(sampleRate × 0.010)`; restore it in `unsubscribe(.agent)` (:241–250) and on engine teardown. Read back after setting and log both values; if the read-back differs, log and continue. Do the same in `PocketSpeechBacking.beginReply` for `engine.outputNode.audioUnit`'s device, restored when the reply ends. The HAL treats this as a per-process setting on current macOS (Apple's documentation for `kAudioDevicePropertyBufferFrameSize`) — **verify it**: while the Agent session holds 10 ms, `afplay` a file and confirm it plays normally; write the result in STATUS.md; do not claim it if you could not check.
4. **Output reference.** Leave `VoicePlaybackReference`'s tap in place; after step 3 read `AcousticEchoProcessor.timingSnapshot()`'s `render frames` in the latency test and record whether the callbacks shrank. Promoting the source-node output (`--voice-pocket-source`) is **out of scope**: the hybrid probes failed near-speech preservation (report :260–281) — note it as a follow-up in STATUS.md.
5. **Load check.** With 10 ms buffers, watch `eouDroppedChunks` (AgentCaptureController.swift:691–700) and the sink ring's `overflow` callback during `--selftest-voice-latency` and the live microphone test; any drop is a failure of this task.

**Do not:**
- Change the tap/sink choice for dictation or meetings in a way their self-tests do not cover — run `--selftest-dictation` and `--selftest-capture` (the hub is shared).
- Leave a device buffer size changed after the Agent session ends.
- Bound the delivery lane by a callback count again, or shrink `maxPendingSeconds` below 1.0 s to "keep latency low" — a backlog is latency only while a consumer is behind; a drop is lost speech and an EOU reset (H-audit 2026-09-23, H2 V24).
- Block or allocate on the Core Audio callback in `enqueue` — the frame arithmetic is two integer/float operations under the existing lock, nothing more.
- Promote the source-node output or AEC3 in this task.
- Loop `--via-open` runs; run each TCC-bound test once.

**Red-first self-test:** extend `--selftest-microphone` (via-open) with the latency line and `--microphone-latency-budget 25` (step 1). **Red today:** `Scripts/run-selftest.sh --via-open --selftest-microphone --microphone-latency-budget 25` → `MICROPHONE_FAILED: capture to delivery p50 6x ms > 25 ms` (A: 63–71 ms on the tap path). Also `--selftest-voice-latency` prints `capture_to_process_ms` as `-` for file-fed runs (no host time) — that is expected; the live number comes from the microphone test.
(H-audit 2026-09-23) Also `--selftest-capture` (no grant needed): add step 2b's case (a) first and run
`Scripts/run-selftest.sh --selftest-capture` on the unmodified code — **red:**
`CAPTURE_WRONG: delivery worker dropped audio under one second of backlog` then `CAPTURE_FAILED`.
After step 2b: `CAPTURE_OK` with both (a) and (b).

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --via-open --selftest-microphone --microphone-latency-budget 25
Scripts/run-selftest.sh --via-open --selftest-microphone-sink
Scripts/run-selftest.sh --via-open --selftest-dictation
Scripts/run-selftest.sh --selftest-capture
Scripts/run-selftest.sh --selftest-voice-latency --voice-latency-runs 5 --selftest-timeout 600
```
Regression flags: `--selftest-acoustic-replay`, `--selftest-duplex`, `--selftest-voice-barge <stop16k.wav>`, `--selftest-voice-duck`, `--selftest-stream`, once `--via-open --selftest-acoustic-live` if speakers are available (record "not run" otherwise), then `make acceptance TIER=core`.

**Success threshold:** live capture → delivery p50 ≤ 25 ms and p95 ≤ 40 ms on the sink path with 10 ms IO; 0 dropped chunks; `DICTATION_OK`, `CAPTURE_OK`, microphone tests OK; no regression in `--selftest-voice-latency` medians. (H-audit 2026-09-23) `--selftest-capture` case (a): 0 overflow for 0.8 s of 10 ms callbacks; case (b): overflow > 0 at 1.6 s; `grep -n "maxPending = 8" Sources/NextNotes/Core/AudioCaptureHub.swift` empty.

**Risks & rollback:** smaller buffers mean more wakeups and a higher chance of underruns when Foundation Models, Pocket and a llama decode run together on a 16 GB machine; dictation and meeting capture share the hub. Rollback: `--capture-tap` (runtime) or flip the default back; set the IO-buffer target to `nil` to skip step 3.

**Done when:**
- [ ] Latency measured on the tap path (baseline) and the sink path; numbers in STATUS.md.
- [ ] Sink default + `--capture-tap`; IO buffer set/restored for capture and reply output.
- [ ] (H-audit 2026-09-23) Delivery lane bounded by ≥ 1.0 s of audio (`maxPendingSeconds`), landed before the 10 ms IO; `--selftest-capture` case (a) red → green, case (b) green.
- [ ] p50 ≤ 25 ms, p95 ≤ 40 ms; no drops; dictation/capture/microphone tests green.
- [ ] AGENTS.md: `--capture-tap`, the per-process IO-buffer finding (verified or not), source-node output still experimental.

---

## Appendix — what this phase does not claim

- All end-to-end numbers are file-fed and callback-based. True acoustic onset (speaker → air)
  and a person's perception are not measured by any self-test (A §5 item 4). After the phase,
  add to AGENTS.md's "What has never run" list: Smart Turn on the user's own speech in a real
  room, VAD ducking against real speaker bleed (beyond the one echo-live run), comma-first
  prosody by ear.
- The phase does not change which model answers, the tool loop, or delivery timing of
  background results — those are Phases 0, 1 and 3.
- Foundation Models stays inside `ComputeScheduler` in this phase; taking it out (A §3 #1,
  decision doc C3) is P3-07, after the overlap measurement.
