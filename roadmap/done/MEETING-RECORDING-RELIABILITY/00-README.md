# Meeting recording reliability and resource use

**Written:** 2026-10-01. **Updated:** 2026-10-13. **Status:** in progress; whole-pipeline investigation/design requested before further implementation, acceptance pending.

Read [the full pipeline plan](01-FULL-PIPELINE-PLAN.md) for the owner’s expanded device-independent audio, preparation, participant identity, proactive completion/review, automatic correction, notes and acceptance requirements. Original MR-01–MR-06 contracts remain required.
**Owner request:** prevent or better manage recordings silently ending mid-meeting;
explain and reduce memory/storage costs even when retained audio is disabled.
**Source baseline:** `5de382a`, with an existing dirty working tree. Recheck production
call sites and coordinate existing source owners before any implementation.

## 1. Confirmed incident and limits

The latest owner meeting started at 09:59:59 EDT on 2026-10-01. Shared capture
delivery logged 773 buffer-drop events from 10:02:51.107 to 10:04:26.880. These
messages do not identify the consumer and cannot be converted into a meeting-loss
duration. At 10:02:47.048 APFS logged ENOSPC for NextNotes. At 10:04:26.879 the
kernel triggered its no-paging-space action. macOS explicitly reported NextNotes
PID 740 exiting with `domain:jetsam(1) code:low-swap(13)`; termination was reported
as `(1, 13, 9)`. This was OS termination, not an ordinary meeting Stop.

The 10:55 restart repaired the meeting and processed 261.3 seconds of surviving
audio. It generated notes and released temporary audio, then left status `done`
without persisted capture-interruption metadata. Processing completion must not
imply whole-meeting capture. An app killed by the OS cannot show a final warning;
prevention and earlier warning have to happen before that boundary.

The incident metrics reported a process-lifetime resident-memory high-water mark of
2,010,857,472 bytes (about 1.87 GiB); the largest retained sample in the inspected
09:50–10:09 interval was 1,021,034,496 bytes. RSS/high-water marks are not total
memory footprint or swap attribution; the peak need not have occurred during the
meeting. They do not establish an app leak, which
model was resident at death, or which application exhausted system resources.
Missing pressure/unload logs are not proof those callbacks never happened.

Read-only investigation found approximately 1.1 GiB free on the volume and
12,705,646,159 bytes of local files under the app's Models directory. These are
post-incident measurements, not incident-time capacity or resident model bytes.
No user files were deleted or modified. Private incident evidence is in the local
build cache under `meeting-diagnostics/2026-10-01/`; do not copy meeting content,
attendees, calendar links, or raw owner logs into committed fixtures/reports.

## 2. What streaming saves — investigated baseline

| Resource | Investigated behavior before these repairs | Consequence |
|---|---|---|
| Retained audio | `meetingsKeepAudio` defaults false; `audioIsTemporary = !keep` is saved at recording start | Keep controls retention, not whether audio is ever written |
| Temporary full audio | `MeetingSession.shouldWriteAudio` writes when keep **or** diarization **or** final pass needs it, if available important-use capacity is at least 1 GB | Final pass defaults true, so keep-off normally still writes the whole meeting temporarily |
| Audio format | `MeetingAudioWriter`: 16 kHz, two channels, 16-bit PCM; bounded pairing and write pieces | About 230.4 MB/hour; incident audio approximately 16.7 MB, not gigabytes |
| Temporary retention | `MeetingStore`: normally 72 hours after processing; earlier release below 5 GB available, through existing deletion guards | Keep-off can leave recoverable full audio on disk after notes; current Settings copy understates this |
| Live ASR backlog | Two `ChunkedTranscriber`s, 300 seconds queued per track at 16 kHz Float32 | About 19.2 MB per track at the queue limit, plus active windows/copies and upstream packet buffers |
| Upstream delivery | Hub workers and two 1,024-packet streams; packet sizes can vary | Window limits are not a bound for all audio allocations; measure total buffer bytes |
| Models | Shared Parakeet inference, optional local language runtime and its working context; caches and other active features | Streaming does not remove model weights, inference allocations or their load peaks |
| Meeting notes warm-up | `MeetingSession.start` can prepare the built-in notes runtime after starting capture | Optional future-use weights can be resident during the meeting; actual incident residency remains unproven |
| Pressure handling | Existing `ModelResidencyGuardian` drops embeddings/cache and then notes/diarization; active native operations defer shutdown | Existing behavior needs actual effect/latency proof and pressure-aware admission, not another scheduler |

The saved incident row has `audioIsTemporary: true`. Under the current producer
that means keep was false when this recording started. The owner recalls enabling
the feature. Preserve that discrepancy as an investigation item: current global
settings or a later toggle cannot establish the start-time choice. Do not silently
rewrite metadata or attribute the discrepancy to user error.

## 3. Product and implementation constraints

- Capture starts immediately; resource checks run off the start/turn path. No
  confirmation, fixed startup delay, or new global lock. Reuse the existing capture
  hub, writer, runtime ownership, scheduler, meeting store and diagnostic logs.
- Memory/storage pressure reduces optional work first. Do not evict a model used
  by an active voice/dictation operation or serialise microphone/model/speaker.
- Never automatically switch providers, send audio/text to cloud, change model
  choices, delete kept recordings or change the owner's retention choice.
- Keep capture integrity separate from processing state in the existing Meeting
  record. Old rows load losslessly; absent metadata means unknown, not verified
  complete. Notes regeneration, diarization, extraction and restart preserve it.
- Warnings say what is known. Quiet audio is not a stalled capture. A failed disk
  check is unknown capacity, not unlimited space or permission to delete files.
- Keep capture timestamps distinct from file modification times, which processing
  or repair can change. Claim a last captured time only from suitable evidence.
- No companion watchdog/service or automatic recording restart in this first
  scope. A host/relaunch proposal needs separate lifecycle, consent and receipt
  contracts; it cannot restore sound produced while the app was dead.

## 4. Tasks and acceptance

See [STATUS.md](STATUS.md) for current ownership and evidence. Required gates remain unchanged. Implement the
smallest producer repair that satisfies each contract and preserve foreign edits.

### MR-01 — reproduce and attribute resource pressure

**Depends on:** none. **Owners/seams:** existing latency/usage diagnostics,
MeetingSession, capture delivery, model residency/runtime registry.

- Reproduce the incident-shaped flow in an isolated meeting store: two tracks,
  live ASR, enabled final pass, and realistic model/feature overlap on a 16 GB Mac.
- Record bounded, content-free measurements of actual loaded models, load/unload
  effects, available storage, pressure transitions, audio bytes on disk, total
  queued audio bytes, missed frames, app memory footprint and available system
  swap/capacity where obtainable. Extend existing logs; no new usage log.
- Separate optional notes prewarm, active Agent/voice requests, embeddings, model
  files on disk and native allocations. Test the keep/final-pass/diarization matrix.
- Explain the owner keep-choice discrepancy using the real setting-to-start-to-
  saved-record call sites. Pin the producer snapshot and later-toggle behavior.

**Acceptance:** reproducible inputs and before-fix failure/evidence; attributable
measurements with missing values identified. Do not exhaust or force-kill the
owner's live app to simulate this. A scripted pressure event proves policy wiring,
not that the app survives real system exhaustion.

### MR-02 — persist interruption and missing-capture facts

**Depends on:** MR-01 regression characterization; independent of attribution of
the machine's biggest memory consumer. **Seams:** MeetingModels, MeetingSession,
MeetingStore repair, existing pipeline producers and meeting projections.

- Add backward-compatible bounded capture-integrity metadata to Meeting, rather
  than overloading `done` or adding a parallel ledger.
- At launch, a row left recording becomes interrupted with best-supported capture
  boundary and unknown cause unless actual evidence establishes one. A row left
  only processing is not automatically a capture interruption.
- Persist known capture gaps/write failures at their producers; every notes/final-
  pass/regeneration save preserves the facts. Recovery may establish coverage of
  skipped live-ASR windows only if saved audio actually covers them. It cannot
  erase uncaptured audio or an abrupt end.
- Show "Recording interrupted — partial notes recovered" with supported time in
  the meeting list/detail, recovery notification and relevant notes presentation.
  Do not invent the unknown remainder duration.

**Acceptance:** actual-store restart fixture reproduces `recording → repair →
final pass → notes → done → fresh reader`, and the partial marker survives every
stage. Old-format, normal-stop, processing-only interruption and missing-audio
fixtures distinguish those cases. Original false-complete case fails before the
fix and passes afterward through the production consumer.

### MR-03 — pressure-aware optional work and measurable release

**Depends on:** MR-01. **Seams:** ModelResidencyGuardian, NotesModelRuntime,
MeetingSession prewarm, existing background jobs/ComputeScheduler.

- Make the existing pressure state observable early enough for admission checks;
  audit installation timing and warning/critical handling.
- Suppress or cancel optional meeting-notes prewarm and prevent immediate reload
  while resource pressure persists. Yield background work through existing seams.
- Release unused runtime/cache allocations safely; record whether release really
  occurred or was deferred by active native work. Do not free active native state.
- Evaluate a capture-preserving fallback that delays live meeting transcription
  only when a functioning audio writer can save the speech for later processing.
  Bound/drop the live queue honestly; do not keep minutes of audio in RAM as an
  alternative to unavailable disk. Preserve ongoing voice/dictation ownership.
- Say "Recording continues. Live transcript is paused" only after writer/capture
  health establishes that claim; otherwise report the actual degraded state.

**Acceptance:** injected pressure reaches real production admissions/releases,
normal-condition behavior stays fluent, active operations remain safe, pressure
does not cause unload/reload thrashing, and saved sample coverage survives fallback.
Measure real-model memory savings and warning-to-action latency; simulated policy
tests alone do not prove resource savings or physical survival.

### MR-03a — lower normal-operation memory, compute and disk costs

**Owner steering, 2026-10-01:** system-wide low swap explains termination but is
not an excuse for unnecessary app resource use. Efficiency is a first-class goal,
not only a fallback after memory becomes critical.

**Depends on:** MR-01 baseline; coordinate with MR-03. **Seams:** existing model
loaders/runtime, audio delivery/conversion, ChunkedTranscriber and writer.

- Attribute steady-state, cold-load and per-inference peaks separately. Profile
  capture-only, capture + live ASR, then optional notes/Agent work on equal audio
  and settings. Measure native/Metal/CoreML allocations where possible; model
  file sizes and RSS alone cannot identify the allocations that need repair.
- Define a measured operating envelope for minimum supported hardware: per-model
  fixed cost, total buffered audio bytes, optional-work headroom, cold-load peak,
  and long-meeting growth. Publish numeric budgets with measurement/build/model
  provenance before changing behavior. Do not declare 1.9 GiB acceptable or promise
  a much smaller total without establishing the selected speech model's floor.
- First candidate: avoid loading a notes model solely because recording began
  when notes will only be needed at the end. Compare removing speculative prewarm
  with conditional warm-up using actual headroom. Preserve independent model choices
  and the shared active runtime; do not unload a model used by an interactive turn.
- Audit the complete audio allocation chain, not only the 300-second ASR queues:
  native tap copies, conversion, packet arrays, 1,024-packet streams, queued/merged
  windows and writer pairing. Remove redundant allocation/copy/array-shift work
  only where profiling establishes the producer cost and ownership remains safe.
  Do not add a second queue/ring buffer merely because it sounds efficient.
- Existing live windows of 2–5 seconds invoke a batch model whose minimum padded
  input is 15 seconds. Measure native work/cost per actual speech second and
  whether repeated short passes dominate CPU, wakeups or allocation peaks. Any
  batching/window adjustment must preserve current live latency, language accuracy
  and provisional/final contracts; a truly streaming/smaller ASR model is a separate
  measured candidate, never an implicit model/default change in this fix.
- Audio buffer memory must plateau at the documented byte bounds as a meeting
  lengthens; transcript/metadata growth is measured separately. Reduce proven
  unnecessary retained allocations instead of raising backlog limits. A lower
  buffer bound must not buy a smaller memory number by losing speech.
- Distinguish incremental recording storage (~230 MB/hour) from model downloads
  and system paging. Temporary audio currently supports quality/recovery; remove
  or shorten whole-recording storage only with proven equivalent coverage or an
  explicit feature/retention contract, not by discarding recovery capability.
  Installed-model reclamation uses existing verified ownership/user choices.

**Acceptance:** publish an allocation breakdown and equal-configuration before/
after report with cold peak, sustained footprint, queued bytes, CPU/wakeups,
disk growth and model warm/notes latency. Demonstrate a measured reduction in the
targeted producer cost without introduced capture loss, accuracy regression or
interactive latency/full-duplex regression. If no safe reduction is demonstrated,
keep the optimization task open rather than crediting MR-03's pressure handling
as normal-operation efficiency. Long-duration fixtures must verify plateauing
audio memory; sampled process RSS alone cannot prove the absence of a leak.

### MR-04 — ongoing storage and capture health with accurate warnings

**Depends on:** MR-01, MR-02. **Seams:** session's existing lifecycle tick, writer,
capture error producers, existing Notifications and meeting/island views.

- Check storage asynchronously throughout capture, using the existing capacity
  query and an evidence-based headroom policy. A startup 1 GB check is insufficient
  proof of space for both recording and system paging. Select warning thresholds
  and cadence from measured reaction cost/headroom, not arbitrary guarantees.
- Track delivered buffers and successfully written sample progress. Distinguish
  silence, stopped delivery, missing system track, ASR lag and storage-write error.
- Reuse authorized expiry cleanup for eligible completed temporary recordings;
  never reclaim active, retry-protected, kept or unknown-choice recordings. Model
  cleanup remains governed by verified artifact ownership and existing user flow.
- Present a persistent in-app warning plus one appropriately updated notification.
  Fix the producer that routes capture gaps to a storage-only notification. Denied
  notifications must leave the in-app warning intact. Measure UI scheduling delay
  under load; a queued MainActor warning is not proof that the user saw it.

**Acceptance:** real writer failure and buffer-loss fixtures reach durable integrity
metadata and the visible consumer. Silence does not cause a false stall; storage
unknown does not look safe; recovery transitions do not spam notifications. No
extra await on input capture/interactive turns and no busy polling/log flood.

### MR-05 — truthful audio-use and retention contract

**Depends on:** MR-01; coordinate existing Settings/UI owners.

- Explain keep vs temporary processing audio, enabled final transcript re-check,
  speaker identification and the actual 72-hour/low-space retention behavior in
  plain language. Do not claim keep-off means no audio exists under today's code.
- Keep existing choices and quality behavior. If a true no-full-audio mode is
  pursued, specify and verify its speaker/final-pass/recovery tradeoffs separately;
  do not silently disable those features or introduce another confirmation.
- Verify start-time keep intent, persisted snapshot, mid-meeting toggles and restart
  consistently; repair a producer mismatch if MR-01 reproduces one.

**Acceptance:** settings and stored policies agree across the full matrix; owner-
requested retained/unknown audio is never deleted by pressure cleanup. Copy passes
the existing UI lint and has a by-eye check; test evidence covers actual producers.

### MR-06 — integrated acceptance and measured operating envelope

**Depends on:** MR-02 through MR-05, including MR-03a.

- Extend existing installed flags for meeting resume/backlog/audio retention;
  add a focused registered self-test only where those cannot prove the new path.
- Use generated nonprivate audio and isolated actual stores for abrupt process
  death/fresh-reader recovery, disk-write failure, missing track, capture overflow,
  denied notification, unknown disk capacity and pressure during model load/use.
- Run relevant existing resume, backlog, final-pass, tap-retry, audio-retention,
  capture, residency, UI-string, usage and store-isolation regressions. Shared
  runtime/capture edits also require appropriate dictation/voice/full-duplex checks
  and any actual task/roadmap quality gates; no threshold is changed here.
- Validate long meetings with representative app overlap on suitable real hardware;
  report peak memory/footprint, storage growth, audio coverage, capture/ASR latency,
  warning latency and recovery outcome. Compare equal builds/configurations.

**Exit:** original false-complete regression resolved, production warnings proven,
normal-operation and pressure resource reductions measured, stored choices preserved and physical coverage
reported. Missing grants/models/hardware and inherited unrelated failures remain
explicit. No claim of immunity to OS force-kill, automatic continued recording
after termination, or whole-meeting capture from successful partial notes.

**Owner decision 2026-10-04: positioning and low-end floor.** See
[POSITIONING-AND-LOCAL-MODEL](../POSITIONING-AND-LOCAL-MODEL/00-README.md). MR-06's
"suitable real hardware" now includes the reference floor: an M2/M3 MacBook Air with
16 GB RAM and 256 GB storage, running the benchmark-selected local model and meeting ASR.
The 2026-10-01 incident (low-swap termination, about 1.1 GiB free, 12.7 GB of local
models) is the profile that machine is most exposed to, so MR-03/MR-03a reductions and
MR-04 warnings are judged there too. No threshold in this roadmap changes.

## 5. Order and coordination

Start with MR-01 and the bounded MR-02 integrity repair. Then MR-03/MR-04 address
measured resource/capture producers; MR-03a reduces normal-operation costs.
MR-05 aligns product copy/choices, and MR-06
verifies the integrated outcome. MR-02 does not wait for identification of another
application's memory use. Do not build a new recording architecture in advance.

`NotesModelRuntime` is shared with independent Agent/Dictation role work; coordinate
with SHARED-BRAIN, AGENT-OVERHAUL P3-07 and the existing cleanup executor.
Capture/latency seams overlap DICTATION-MEETINGS-RATES-AND-GATES and Agent duplex.
Meeting UI, Settings, Notifications and NextNotesApp already have foreign edits;
recheck file ownership before modifying them. The owner authorized parallel implementation on 2026-10-01; task claims and acceptance
remain in STATUS.md. Existing readiness gates and production choices remain binding.

References: [Apple memory-pressure API](https://developer.apple.com/documentation/dispatch/dispatchsourcememorypressure),
[Apple storage-capacity queries](https://developer.apple.com/documentation/foundation/checking-volume-storage-capacity),
[XNU pressure notification semantics](https://github.com/apple-oss-distributions/xnu/blob/main/doc/vm/memorystatus_notify.md).

## 6. Owner follow-up and current failures — 13 October2026

The owner authorized auditing three retained long meetings (recorded7/9/13 October), updating this roadmap, verifying the current installed app and producing an actionable repair plan covering partial audio, speaker errors near the end, diarization no-speech errors, missing automatic titles and poor notes. The [13 October audit](../../../Tests/Reports/meeting-reliability/2026-10-13-audit/README.md) pins the artifacts/build and distinguishes measured failures from source hypotheses. The [prioritized repair plan](../../../Tests/Reports/meeting-reliability/2026-10-13-audit/ACTION-PLAN.md) supplies responsible seams and original/fixed acceptance. No original task gate is weakened.

Two newer recordings persist saved-system omissions despite zero capture-drop counters. Live system timestamps end around half the recorded wall duration; the remaining38min CAF system channel is digitally zero after its first few seconds. Existing cumulative sample clocks plus5s writer lead explain propagation under half-cadence input, but actual native buffer/converter first mismatch remains to prove. Fix accepted PCM cadence/time preservation before speaker/note polishing; suppressing warnings or stretching timestamps is not a repair.

MR-06 now explicitly includes accurate whole call timestamp domains and speaker projection through the final utterance; automatic full event titles when matched evidence exists, honest fallback and preserved manual titles; channel-specific no-speech/unavailable-audio diagnostics; factual note coverage, action ownership and freshness against pinned transcript/map inputs. Name rosters cannot establish voice binding. A successful final model response does not establish semantic completeness.

Current installed0.2.24 SHA503e0e40 passes strict/deep signature/UUID checks and matches installing-peer provenance; fresh functional tests are unrun under current memory admission. Do not inherit earliered673 meeting checks or announce installation of a new repair. Preserve private replay evidence and other agents' staged work; coordinate native builds/tests through existing relay ownership only.

The owner confirms AirPods audio. Include actual Bluetooth route/profile/format transitions and aggregate input-stream layout in the source reproduction; exact headset/microphone/profile/switching is unobserved. The current-note audit identifies27 selected material omissions plus directional/temporal/attribution errors; preserve exact private anchored cases as original failures, not a model ranking or exhaustive accuracy score.

## 7. Whole-pipeline owner direction —13October2026

The scope covers all OS-exposed supported inputs/outputs and route transitions, not a headset brand. It includes premeeting context/title/readiness, observed participants and timed speaking evidence, a nonmodal completion card with quick uncertain-speaker/correction review, admitted background notes updates, and semantic/action freshness through restart/next calls. See [18 implementation milestones](01-FULL-PIPELINE-PLAN.md#10-implementation-milestones-and-required-proof), [20device/15transition matrix](../../../Tests/Reports/meeting-reliability/2026-10-13-full-pipeline/audio/README.md), [provider access table](../../../Tests/Reports/meeting-reliability/2026-10-13-full-pipeline/identity/PROVIDERS.md) and [experience contracts](../../../Tests/Reports/meeting-reliability/2026-10-13-full-pipeline/experience/EXPERIENCE-PLAN.md). No product implementation began in this planning cycle.

The owner explicitly removed the arbitrary free-memory diagnostic launch cutoff. Current signed503 baseline ran without that floor:21distinct flags have scoped green evidence after the explicit native speech-fixture repeat; isolation retains inherited nested failures. Corrected fixture path does not erase initialABSENT; historical185private temporary corpus is now unavailable and its attempted repeat refused. Owner20original artifacts and source1179 stay unchanged. These results update prior memory-refused functional status, not long-device/proactivity acceptance. A native constructor shape probe rejects tested mismatches; deliberately stale rate accepts half-duration authored evidence. Actual incident rate/frame/route first cause remains unproved.
