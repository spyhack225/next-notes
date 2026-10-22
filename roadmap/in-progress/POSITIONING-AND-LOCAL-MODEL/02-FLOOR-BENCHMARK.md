# The low-end floor benchmark (spec) and PL-01

If it is fast on the cheapest Mac, it is fast everywhere. Competitors publish numbers from
M5 Max-class machines; we publish numbers from a MacBook Air with 16 GB and 256 GB, with
the rest of the app running. This file defines that measurement once, so every task in this
folder and every sibling gate that cites "the floor" means the same thing.

A floor number is a claim only when it comes from a run that follows this spec, is saved
under `Tests/Reports/floor/`, and names its exact artifact, build and conditions.

---

## 1. Reference machine

| Item | Requirement |
|---|---|
| Model | MacBook Air with Apple M2 or M3 (base chip; `ModelFitEstimator`/`HardwareProfile` treat both as 100 GB/s) |
| Memory | 16 GB unified |
| Storage | 256 GB class SSD (the owner's Mac reports a 245.1 GB container) |
| OS | The macOS the app ships for (Apple Foundation Models needs macOS 26) |
| Power | On the power adapter for gate runs; Low Power Mode off. One extra battery run is recorded for information (owner decision open: whether it gates) |
| Owner's machine | `Mac15,12` (MacBook Air 13-inch, M3), 16 GB, checked 2026-10-04. It qualifies. An M2 Air run is needed before a public sentence names M2 |

**Clean-run conditions.** No other build, install or self-test running (check
`~/Library/Caches/NextNotesBuild/install.lock` and active processes first); the app installed
with `make install OPEN=0`; thermal state `nominal` at start; at least the downloader's 4 GiB
reserve plus the artifact size free on disk; Spotlight not indexing a fresh volume. Record the
open apps. A run that breaks a condition is labelled *contended* and is a diagnostic, not a
gate run — the same rule the P1-31a report already applied to its shared-machine numbers.

## 2. Load conditions

| ID | What is running while the model decodes | Why |
|---|---|---|
| **C0** | Only the model | Upper bound; compares with published numbers |
| **C1** | Live-meeting transcription of a fixture WAV fed at real-time rate, through the same `ChunkedTranscriber` a meeting uses (`Sources/NextNotes/Meetings/ChunkedTranscriber.swift`, Parakeet underneath) | A meeting is being transcribed while the agent works |
| **C2** | A full voice turn: capture → end of turn → model → Pocket TTS reply, file-fed, as `--selftest-voice-latency --voice-latency-fixture <wav>` already runs it | Full duplex: listening and speaking around the model |

**Gates apply to C1 and C2.** C0 is recorded but never passes a gate alone.

## 3. Metrics

| Metric | Definition | Existing source |
|---|---|---|
| Decode tok/s | `completionTokens / (totalMs − ttftMs)` over a fixed 256-token generation; median and p10 over 10 runs | `UsageRecord.tokensPerSec` (`Sources/NextNotes/Support/Usage/UsageRecord.swift`) |
| Prefill tok/s | prompt tokens not reused ÷ time to first token, for a fixed 2,000-token prompt, cold | `promptTokens`, `cachedTokens`, `ttftMs` in the same row |
| Time to first token, warm | voice-route prompt with the cached prefix (P0-18) and ≤300 new tokens | `ttftMs`; `--selftest-llm-prefix-cache` proves reuse |
| Load time | cold load of the artifact | `loadMs`, `warm == false` |
| Speech end to first audio | the Phase 2 metric, unchanged | `--selftest-voice-latency` medians |
| Peak app memory | peak resident bytes of the app process during the run | the `peakResidentBytes()` helper in `NextNotesApp.swift`; toolloop-live reports "App peak RSS" |
| Memory pressure | worst `ModelResidencyPolicy.PressureLevel` seen (`normal` / `warning` / `critical`) | the existing `DispatchSource` pressure observer |
| Swap growth | `vm.swapusage` used, end minus start | **gap** (PL-01) |
| Disk | verified artifact bytes, plus the total of every model file the default path needs | library row / `VerifiedModelArtifact`; Models folder listing |
| Thermal | `ProcessInfo.thermalState` every 10 s; decode tok/s in minute 1 vs minute 10 of a sustained run | `HardwareProfile.thermalState` exists; sustained run is a **gap** (PL-01) |
| Agent quality | fixed quick score, full score, owner cases, persona sets | `--selftest-toolloop-live` |
| Cleanup quality | guarded failures and per-case time over the cleanup corpus | `--selftest-cleanup app-llm-compare` |
| Notes quality | SB-07's predeclared meeting rubric | `--selftest-notes <wav>` plus SB-07 corpus |

## 4. Pass thresholds

Marked **(proposed)** where the owner has not yet confirmed the number. A proposed number may
be reported against but may not close a gate until confirmed in STATUS.

| Gate | Threshold |
|---|---|
| Decode speed | **Floor: p10 ≥ 20 tok/s under C1 and C2. Target: median 25–30 tok/s.** (owner decision 2026-10-04) |
| Sustained | After 10 minutes of continuous C1 decode, the last-minute rate is still ≥ 20 tok/s; thermal state recorded, not gated **(proposed)** |
| Warm first token | ≤ 0.4 s for the voice-route prompt under C2, so the model fits inside Phase 2's 0.9 s speech-end-to-first-audio budget **(proposed)** |
| Speech end to first audio | AGENT-OVERHAUL Phase 2's gate unchanged (≤ 0.9 s warm median), now judged on this machine |
| Memory | App peak ≤ 6 GB with model, ASR and voice resident under C2; pressure never leaves `normal`; swap growth ≤ 256 MB **(proposed)**. For reference, `ModelFitEstimator.safelyUsableMemoryBytes` leaves about 10.5 GB for a model on 16 GB; this gate is stricter because the person has other apps open |
| Disk | The one shipped language-model artifact ≤ 3.0 GB; every model file the default path needs (speech, wake, cleanup, language model, embeddings) ≤ 5 GB together; the downloader's 4 GiB free reserve is never breached **(proposed)** |
| First turn after launch | Never waits on a cold load, because the existing launch prewarm (`LaunchWarmup`, `Sources/NextNotes/Formatting/AppleModelWarmth.swift`) already ran; load time is recorded, not gated |
| Quality | AGENT-OVERHAUL's gates unchanged (quick 9/10; full ≥ 25/30 on two consecutive runs; O01–O09); SB-07's cleanup and notes rubrics. Speed never buys a lower quality bar |

A candidate passes the floor only when **every** row passes on the same artifact and build.

## 5. How it is measured with what already exists

All runs go through `Scripts/run-selftest.sh`, one at a time, in the foreground, against the
installed bundle and the harness's isolated stores. Nothing touches the owner's settings,
history or downloads.

| Question | Command | Status |
|---|---|---|
| Agent quality, speed per turn, peak RSS, thermal | `Scripts/run-selftest.sh --selftest-toolloop-live --model <id> --quick --report Tests/Reports/floor/<date>/<id>-quick.md` (full: drop `--quick`) | exists |
| Cleanup quality and time per candidate | `Scripts/run-selftest.sh --selftest-cleanup app-llm-compare` | exists; iterates every GGUF in the Models folder |
| Notes speed and peak RSS | `Scripts/run-selftest.sh --selftest-notes <wav>` (prints tok/s and peak RSS for the meetingNotes role) | exists |
| Model decodes on Metal at all | `Scripts/run-selftest.sh --selftest-llm-metal` (32 tokens on the Agent role's model) | exists; too short for speed |
| Prefix reuse | `--selftest-llm-prefix-cache` | exists |
| Voice end to end under C2 | `--selftest-voice-latency --voice-latency-fixture <wav>` | exists |
| Scheduling stays correct under load | `--selftest-voice-scheduling`, `--selftest-concurrent-voice`, `--selftest-contention`, `--selftest-residency` | exist; correctness, not speed |
| Prediction before a download | `--selftest-model-fit` | exists; estimate only |
| Field evidence after shipping | `--usage-report --usage-days 7 --usage-feature agent` on the owner's real log (read-only, outside the harness) | exists |

**Gaps** (closed by PL-01, no new harness):
1. `--selftest-llm-metal` cannot target a named candidate; it always uses the Agent role's model.
2. Nothing decodes a fixed long generation repeatedly or sustains decode for 10 minutes.
3. Nothing decodes while a file-fed Parakeet stream runs (C1).
4. `--selftest-voice-latency` prints span medians but not the model pass's decode tok/s or
   warm first-token time, although it already joins the turn's usage rows.
5. No run samples swap growth or the worst pressure level.

---

## PL-01 — Floor modifiers on the existing speed flags

**Goal.** Make the floor measurable with the flags we already have, so PL-02 and every later
gate run the same commands.

**Current state (verified 2026-10-04).** `--selftest-llm-metal` builds a
`NotesModelRuntime` for the Agent role's spec and decodes `metalProbeTokens = 32`
(`Sources/NextNotes/NextNotesApp.swift`). `ModelPassRecorder` writes `tokensPerSec`,
`ttftMs`, `loadMs` and `cachedTokens` per pass into the harness's isolated `usage.jsonl`.
`--selftest-voice-latency` runs real file-fed native voice turns
(`Sources/NextNotes/Agent/Voice/VoiceLatencySelfTest.swift`). `--selftest-transcribe` and
`--selftest-notes` already feed a WAV through `ChunkedTranscriber` "the way a live meeting
does" (the shared `transcribeFile` helper in `NextNotesApp.swift`), though not paced at
real time. `HardwareProfile` reads chip, memory, disk, thermal
state and Low Power Mode. The pressure observer lives in
`Sources/NextNotes/Core/Compute/ModelResidencyPolicy.swift`.

**Work.**
1. Add a `--floor` modifier to `--selftest-llm-metal` (marker `LLM_METAL_OK` unchanged when
   the modifier is absent). With it: `--floor-model <library id>` selects a verified library
   artifact through the existing awaited runtime `select` (never writing the saved choice);
   decode a fixed 256-token generation 10 times and a fixed 2,000-token cold prefill once;
   optional `--floor-asr <wav>` feeds the WAV through the existing `transcribeFile` /
   `ChunkedTranscriber` path, paced at real time and looped for the whole run (C1);
   optional `--floor-sustain <seconds>`.
2. Print one `LLM_FLOOR:` line per condition with the artifact, build, chip, memory, free
   disk, power state, median/p10 decode, prefill, warm/cold first token, peak RSS, worst
   pressure level, swap growth and thermal samples. Read every number from the pass's own
   usage row or an existing helper; add only the `vm.swapusage` read.
3. In `--selftest-voice-latency`, print the joined model passes' decode tok/s and
   `ttftMs` beside the existing medians (no new store; the rows are already joined).
4. A clean-run precheck: if another install/self-test holds the lock, or the start state is
   not `nominal`, label every line `CONTENDED` rather than refusing — the number is still
   useful, it just cannot pass a gate.
5. Verdicts: no candidate resolves → `LLM_FLOOR_ABSENT` (never OK); any decode of zero tokens
   → `LLM_METAL_FAILED`; the flag reports numbers and does not itself judge the thresholds
   (the report does, so a threshold change never needs a code change).

**Acceptance evidence.** Red first: the new lines are absent on the current build. Then one
C0, one C1 and one C2 report on the owner's Mac under `Tests/Reports/floor/`, with the exact
command lines; a deliberate mutation (feeding zero ASR frames) shows the C1 line reports the
missing load rather than a C0 number; `--selftest-llm-metal` without the modifier prints the
same verdict as before; `--selftest-store-isolation` and `--selftest-usage-log` pass.

**Must not.** Add a benchmark store, metrics file or second usage log; write
`activeAgentModelID` or any role choice; download a file; hold the install lock; add a wait to
any production path; change `metalProbeTokens` for the default run; change any gate
threshold in code.
