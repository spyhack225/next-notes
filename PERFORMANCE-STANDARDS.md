# Performance standards

Owner-requested shared reference, 7 October 2026. Read this before changing capture,
ASR, models, scheduling, meeting processing, dictation, voice, rendering or indexing.
This document collects the existing owner requirements and the measured lessons;
it does not declare unverified targets achieved or introduce a product scheduler.

## Benchmark evidence catalog

The [benchmark hub](Benchmarks/README.md) indexes model and workflow evidence across current reports, roadmaps, branches and worktrees. Use the [shared result format](Benchmarks/FORMAT.md) for new runs; website builds consume registered, explicitly reviewed public summaries. Existing measurement boundaries, privacy and acceptance requirements below remain authoritative. Historical imports do not qualify the current application.

## Reference machine and acceptance

Subsequent explicit owner choice: Phonon is now the saved temporary TTS preference
(`phonon-owner-selection.json` in the23October TTS report). This is not a fastest-five
qualification. Current process/model readiness/playback remain unverified: UI access
fails and disk space prevents ordinary guarded Phonon installation. All five Settings
choices remain. Earlier unchanged-default statements below describe their run times.

23 October resumed TTS work: [cleanup and external compiler lifetime](Tests/Reports/tts-2026-10-23/README.md).
Owner-authorized obsolete installer/module cleanup and verified old-symbol compression recover an
observed1.43GiB; current/rollback/runtime builds stay. New60% physical cohort completes Phonon30/30
264.393/322.068ms and Pocket30/30 293.466/369.349ms median/p95 under paced v3 decoding. Disk stops
remaining engines. Root-only cleanup missed external CoreML compiler bundles (1.783GB in diagnostic
runtime-probe cache, including a PID98720 bundle created during the failed reference window) and pinned Phonon compiler temporary outputs.
Boundary mitigation now deletes only new compiler artifacts after durable save/native join, preserving
existing caches. Native interruption at an actual new compiler bundle passes join/deletion and original
ASR-file preservation;18 model-free controls pass. This fixes the diagnostic artifact-lifetime gap,
not external compiler behavior or the whole VM/Qwen pressure cause. Default route then changed to
AirPods; the owner then authorized built-in-route continuation and restoration. Further verified
artifact archiving/transparent compression briefly reached4.3GB free. Qwen prepared then hit the
live disk guard before timed synthesis; Kokoro stopped during reference warmup, its newly created
compiler cache was removed after join, and macOS was refused. Last light preflight refused below1GiB
with owned models unloaded/deleted. Underlying VM/swap pressure remains open; no disk guard was
relaxed. Built-in levels restored; disconnected AirPods reconnection is blocked by failed macOS UI
access. Installed app and Pocket/Alba default unchanged; full comparison/winner/quality/EOU open.


23 October 2026 TTS calibrated follow-up: [serial speaker evidence](Tests/Reports/tts-2026-10-22/README.md#23-october-calibrated-serial-cohort--incomplete-no-default-promotion).
Apple completes30/30 warm threshold-qualified microphone pickups under progressing cached-v3
reference decoding:159.863ms median,186.975ms p95. Qwen completes synthesis but qualifies27/30;
no acoustic median is accepted. Smaller pinned incremental decode batches report3.768GB MLX
peak versus4.637GB in an earlier diagnostic; waveform boundary quality and the total disk-pressure
producer remain open. Exact overlay candidate is retained in the report; normal packaging and
installed809 do not activate that unqualified decoder change. Phonon hits the unchanged live disk guard; Pocket/Kokoro are refused before
download. Every owned model/reference child joins and temporary assets are deleted before next.
Immediate500ms baseline has original/fixed authored stale-tail evidence and persistent-noise negative;
route snapshots now include gain/mute. Fourteen runner controls pass. Existing apps remain open;
only identical idle build artifacts were CoW-deduplicated and superseded owned symbols retired.
Installed809 and Pocket/Alba selection remain unchanged. Public latest records preserve failures;
full five-model/winner production consumer/selected-ASR/EOU and quality acceptance remain open.


22 October 2026 signed-app ASR follow-up: [eight-model application integration](Tests/Reports/asr-app-integration-2026-10-22/README.md). All8 optimized/signed candidate model cases pass45 warmed paced holds through the actual factory, segmented engine, scheduler and transcript consumer, with SDK fallback bundles hidden. Median English first/final: Phonon424/5ms; Voz448/28ms. French: Whistle417/38ms (fastest raw), Voz450/58ms. Owner-requested Automatic chooses Phonon for English and Voz for Multi; existing manual choices survive. Current Whistle short French wording matches Voz; earlier longer-fixture accuracy remains separate, not current full-app quality. Phonon cold preparation223s excludes later warm-shape passes. Physical mic/UI/polish/insertion/concurrent voice remain unverified. Original native usage attribution fails2, repaired same case passes0. All candidate children joined and owned models/HTTP files deleted,6.1GiB free at handoff; one candidate at a time. Process context now records only PID/CPU/RSS because macOS comm can include arguments. Release installation/publication remain separately verified actions.

Earlier pressure-limited ASR attempt (superseded by the later serial/app reports):

22 October 2026 ASR live work: [paced latency and Whistle CoreML audit](Tests/Reports/asr-live-latency-2026-10-22/README.md).
Whistle alone completed three paced short holds per language under memory/storage pressure: median first provisional text
421 ms EN / 420 ms FR; native commitment 2,443 / 1,439 ms; release-to-ASR-final 68 / 86 ms. This excludes physical capture,
UI, polish/insertion and duplex qualification. Its 10-second EN internal first-token audit is 12.4–14.7 ms, close to the
vendor's 11.1 ms M4 Pro claim; that returned statistic is not live-word latency. French short-hold accuracy is poor (6/22 edits).
Cached v3 short-prefix warmup was stopped as disk/swap pressure rose; its allocating producer is unconfirmed and no accepted
live result exists. Six other variants remain unrun. All 23 original model hashes are unchanged; temporary Whistle files and
the 19.37 MB linked probe were removed, both machine claims released, no defaults/app install changed. Ten harness checks pass.
RPC containment now preserves failure requests and checks disk while waiting; it does not repair or explain the pressure cause.
No published Whistle CoreML artifact/exporter was found; its custom CPU .cact needs a validated conversion/integration project.

22 October 2026 TTS work: [native engines and serial first-PCM benchmark](Tests/Reports/tts-2026-10-22/README.md).
Owner requires one disposable model/process at a time: save results, exit/unload, delete owned files, then
start the next. Five optimized native comparisons now complete: warm median first generated PCM (5 runs)
Phonon31m 7.80 ms, Apple8.98 ms, Pocket59.00 ms, Kokoro224.11 ms, Qwen3-TTS0.6B4bit2,709.30 ms.
Qwen returns whole clauses. These back-to-back same-text timings are not audible output, speech-end latency
or ASR-plus-voice reference qualification. Both new providers pass actual muted pause/resume/render/drain;
full-app source regression and all eight runner lifecycle/copy-on-write checks pass. Native original and
initial-pause-only regressions fail; the producer repair publishes the pending pause before the renderer
token and excludes deliberate paused time from the unchanged two-second active IO budget. Source16020462.
All temporary model roots are removed; all104 existing voice-cache files are SHA/count unchanged. No owner
model/default/installed app changed. The matching MLX0.32.3 Metal resource must be packaged after raw SwiftPM
linking, which can remove the manual bundle. An earlier Qwen load was stopped below1.5GiB free disk; its
allocating producer is unconfirmed. The unchanged binary later passed with more headroom: no memory/cache
repair is claimed. About211MB of task-produced app outputs were retired; SDKs/modules/current binary stay.

TTS follow-up prepares separate native render/estimated-presentation/acoustic pickup reporting,
without a second microphone/AEC path. Its authored original/fixed control proves that a maximum
presentation estimate must not gate an earlier observed pickup (80 ms pickup versus 300 ms estimate:
original correlation0.219/refused; repaired correlation1.0/accepted; not physical evidence). Ten serial
runner controls pass; public generated-PCM records are reviewed. Physical model runs and any fastest
speaker-default decision remain pending the coordinated candidate build and qualification. See the
same TTS report and [voice-turn review](roadmap/in-progress/VOICE-TURN-DETECTION/04-TTS-AUDIBLE-ALIGNMENT.md).

The reference is a **16 GB / 256 GB M2–M3 MacBook Air with ASR and voice running**.
The current observations are from the owner's M3. An M3 result is not an M2 result.
Record macOS, power/thermal state, app build/signature, exact model artifact and
concurrent workload. Use the optimized release build for user-facing measurements.
Keep cold startup, warm execution, pressure recovery and concurrent execution separate.

| Requirement | Status and interpretation |
|---|---|
| Local decode floor ≥20 tokens/s; target 25–30 | Existing owner requirement. Measure actual decode after first token under ASR/voice load; completion tokens divided by total job duration is not decode throughput. No default promotion from a quiet model-only run. |
| Fluent full-duplex voice | Microphone, model and speaker overlap. A fix must preserve barge-in, streamed replies, approvals and background-work responsiveness. Follow the actual Agent phase acceptance contracts. |
| Dictation text within a few hundred ms of release; universal 2s acceptance target | Existing dictation roadmap/follow-up targets, not achieved results. Measure complete polished text delivery with dictionary, structure, context and insertion features enabled. ASR readiness alone does not pass. |
| Warm voice first audio 0.9s | Existing Agent latency target, still open in the referenced phase evidence. Measure first audible PCM from actual speech end, not first model text. |
| Meetings remain responsive while both tracks save and transcribe | No freeze, lost accepted recording audio or accumulating memory growth. Measure UI/browser response and live transcript lag. A saved `.done` record alone does not establish uninterrupted capture or factual notes. |
| Whole-app memory near 2 GB | Existing design direction, not an approved universal production ceiling. The positioning roadmap leaves exact memory/disk/TTFT thresholds open. Calibrate combined workloads before enforcing a numeric gate. |

Sources: [AGENTS.md](AGENTS.md), [positioning benchmark decisions](roadmap/in-progress/POSITIONING-AND-LOCAL-MODEL/00-README.md#7-open-owner-decisions),
[Agent latency contracts](roadmap/in-progress/AGENT-OVERHAUL/03-PHASE-2-LATENCY.md),
[dictation latency](roadmap/in-progress/DICTATION-LATENCY/00-README.md).
Read their amendments before applying an older model/residency recommendation.
The quick 9/10 quality bar and all required functional, privacy, authority and latency
checks remain unchanged. A bounded producer repair may land with its own regression
green while an inherited aggregate gate remains open; that does not promote a default,
complete a roadmap phase or establish product readiness.

## Measure the user path

Capture the original input and failure before editing. Follow the real producer and
consumer, pin the original/fixed source and bundle, and keep the same regression inputs.
State exactly which dependency is native, substituted, unavailable or not observed.
Avoid retries, longer deadlines, downstream sanitizers or easier fixtures that conceal
the broken contract. A plausible explanation remains a hypothesis until measured.

For each native performance run, retain:

- The build hash/UUID, signature, source revision, model identity and test arguments.
- The complete visible user flow, feature settings and any browser/native permission limits.
- Stage latency, queue wait, first output, final output, cancellation and consumer receipt.
- Baseline, peak and trend of process footprint; RSS separately; allocation categories
  at growth; system swap/compression, storage headroom, CPU/load and thermal state.
- Capture/writer counts by consumer and track, native frame/clock coverage, dropped input,
  partial/final transcript lag, stop/drain and post-stop progress.
- Relevant accuracy, factuality, language and speaker checks against independent truth.
- Every verdict, including inherited failures, timeouts, unavailable checks and ambiguous logs.

Report distributions and sample counts when available. A single run is an observation,
not a percentile or general benchmark. Faster synthetic replay is not a wall-clock
long meeting. A successful helper is not proof that its production consumer used it.
Record the concurrent workload: a test under contention is useful stress evidence,
but cannot be presented as an uncontended latency result.

## Memory and audio accounting

Use Mach physical footprint for charged process growth and RSS for resident memory;
do not substitute one for the other. Footprint can exceed physical RAM because it
accounts for compressed/swapped charges. Summing process footprints is not a unique
physical-RAM measurement. `IOAccelerator`/graphics categories can include GPU compute
as well as rendering; they do not by themselves identify a UI leak.

File-backed/mapped weights are not free under paging. Apple-hosted inference still
uses machine memory/compute even if the app's own footprint is small. Measure the
whole machine as well as the app. Sharing an exact verified weights file does not
share prompts, history, KV state, role choices or permission. Reuse the existing model
library, runtime ownership, scheduler and telemetry; preserve stored selections.

`MeetingAudioWriter.writerBytes` is **cumulative saved PCM**, not pending memory.
Use queue occupancy, capacity, active inputs and allocation categories to explain RAM.
The current bounded writer/ASR queues did not explain the captured tens-of-GB runaway.

Never attribute generic microphone backlog messages to a meeting without identifying
the emitting consumer. `AudioCaptureHub`'s default overflow log does not name one;
`MeetingSession` installs a separate overflow callback and records its own counters.
Zero reported drops establish only the instrumented path, not an unmeasured hardware
guarantee. Normal stop, writer coverage, saved integrity and actual file readback must agree.
Restart recovery or final re-transcription cannot recreate audio never captured/saved.

The existing resource policy did not contain runaway growth while OS pressure stayed
`normal`/`warning`, and its MainActor health cadence stalled. Footprint growth and paging
headroom need independent consideration at the existing responsible seam. This remains
optimization work, not a shipped production safeguard. Preserve audio-saving coverage
and full duplex; do not add a second queue/store, serial turn gate or arbitrary global cap.

## Confirmed meeting startup repair

The live Google Meet incident on 7 October grew from roughly 1.72 GB to **10.904 GB**.
The paused heap was **10.486 GB Malloc Small**, and the stack contained approximately
510 consecutive `NeedleServer.ensureRunning` frames plus `swift_task_alloc`.
This identifies the allocating producer for that incident. Earlier 20.998/44.489 GB
incidents have compatible symptoms but no equivalent retained allocation stack.

Meeting transcript events warm the helper concurrently. Originally, one task returned
a launched child while its caller separately adopted it and cleared `startTask`.
Another caller could resume first, repeatedly await the same completed task and recurse;
`try?` also swallowed startup failure. The repair makes the existing startup task adopt
or reject its child and clear itself **before it completes**, and propagates failures
to the existing fallback. No model change, extra turn-path await, store or timer was added.

**Commit `422ba5f` on canonical main** changes only:

- `Sources/NextNotes/Agent/FunctionCalling/NeedleServer.swift`.
- `Sources/NextNotes/Agent/FunctionCalling/FunctionCallSelfTest.swift`.
- New `Sources/NextNotes/Agent/FunctionCalling/NeedleServerStartupSelfTest.swift`.

Original actual-source concurrent failure and cached-native cold-warm regressions hit
their bounded memory watchdog around 187 MB from a 1.7 MB baseline. Repaired cases settle
around 5–6 MB; sixteen native cold warms share one child and complete a real inference.
The maintained regression is wired into `--selftest-function-calls`; its full-app startup
case passes. It uses temporary state and no owner-store writes.

The repaired optimized app passed health 90, integrity 67, resource/writer and reconcile-LLM
checks. The aggregate function-call flag is **not green**: debug finishes with a native
confidence/expected-call mismatch; release completes that phase with the same raw result,
then times out in the local-model fallback under competing load. Preserve these verdicts.

The actual visible-window 395-second recording saved and reached final transcript/notes:
sampled live peak **1.421 GB**, normal-stop footprint 1.266 GB, no meeting-counter losses or
write failure. Startup recovery/post-stop work brought the overall sampled peak to 2.068 GB.
There were 53 live and 48 final segments. Segment counts do not prove transcription accuracy.
Median/max live final lag was 2.017/6.463s under contention. Final-pass/diarization/notes
metrics in that interval also include the earlier interrupted recording's recovery.

Responsiveness acceptance **failed** while other builds/native tests and heavy paging
were present; UI observations took 114s/72s and the owner reported stalls. After competing
work exited, checks of the same app took 0.41–0.67s. That supports contention but does not
exclusively attribute every stall or pass a fresh uncontended physical recording.
An adopted helper child was not captured in this physical check, so that consumer
observation remains open despite independent native startup proof.

The 146 generic backlog logs cannot be labelled146 meeting drops: observed meeting
missedFrames/missedBuffers and saved integrity are zero. Initial stronger attribution
was corrected. Notes also contain a duration mismatch, and Workspace actions report a
10s CLI timeout. These quality/availability findings remain open.

Full evidence and reproducible source pins:
[pipeline audit](Tests/Reports/meeting-reliability/2026-10-07-investigation/README.md),
[live findings](Tests/Reports/meeting-reliability/2026-10-07-investigation/LIVE-FINDINGS.md).
The original source remains available at `422ba5f^:Sources/NextNotes/Agent/FunctionCalling/NeedleServer.swift`.

## Diagnostic containment and native acceptance

The initial live diagnostic sampled the heavy `footprint` command. It timed out and
exited before its threshold protected the Mac. The replacement uses direct libproc
`proc_pid_rusage` v0, binds process-start identity and collects heavy snapshots separately.
A disposable 200 MB process was actually paused at a 100 MB fixture threshold. In the
repaired recording, the largest observed sampling gap was 1.263s under paging.

The external **2.5 GB SIGSTOP cutoff is a temporary diagnostic boundary**, not a production
memory ceiling or guarantee. Sampling can be delayed by OS scheduling. A pause preserves
the allocation state but interrupts recording; force-quit requires the owner's decision
for the actual app/recording state. No diagnostic may silently disable the failing feature
or discard owner audio. Keep saved evidence and explain any failed guard honestly.

Acceptance still needs an uncontended short physical call, then 30–60 minute calls and a
long saved fixture on the reference machine, with both audio sources, ASR, voice and
normal live features. Include the actual visible meeting window and a hidden-window
comparison; the latter does not replace the former. Verify responsiveness, bounded
steady-state memory, capture continuity, language/speakers, factual notes and approval
behavior through normal stop/recovery. Set workload-specific numeric budgets before
evaluating them; an absent budget or missing native exercise remains open.

Post-stop whole-channel Float reads scale with duration (about 230 MB/hour/channel at
16 kHz), and full indexing/native model setup can compete for memory/I/O. Optimize these
through existing readers/admission seams with timeline, speaker and quality regressions.
They are separate work; they did not produce the captured first-minute async recursion.

## Agent-relay coordination

All agents working in this repository must consult this document and publish meaningful
performance discoveries, actual implementation scope, original/fixed verdicts and open
contracts through the existing **agent-relay** project. Persist important facts here or
in linked evidence rather than relying only on a chat or broadcast. No owner transcript,
meeting title/participants, credentials or raw payload belongs in a broadcast.

Before running builds/model tests/native benchmarks on the owner's Mac, check the relay's
active agents/claims, current processes and whether the owner is using a live meeting or
voice/dictation flow. Agree a test window. Serialize competing **development heavy work**
through agent-relay's existing machine claims/gate when available; publish the resource
name, owner and duration, and release your own claim on exit. Do not apply this development
coordination gate to the product's microphone/model/speaker overlap. A coarse relay gate
passing does not authorize contention with an active owner test or prove enough RAM.

Do not pause/kill another agent's processes or replace the installed app without verifying
ownership and coordination. Broadcast delivery means persisted/sent, not proof every
agent read it; state unread/acknowledgement limits honestly. Keep future agents covered
through the AGENTS.md reference. Recheck file ownership before edits; never replace a
stale whole-file snapshot or commit another agent's staged changes.

The 7 October meeting handoff was broadcast to all four registered project peers as
`meeting-performance-20261007-422ba5f-installed` (cursor338), with this standard,
AGENTS.md, the investigation, and producer/self-test sources attached. Persistence was
verified in a recipient inbox; the active dictation chat also received a direct notice.
This proves delivery, not reading or agreement. The compact [relay receipt](Tests/Reports/meeting-reliability/2026-10-07-investigation/agent-relay-broadcast-result.json)
records recipients and attachment hashes. The [owned AGENTS insertion](Tests/Reports/meeting-reliability/2026-10-07-investigation/AGENTS-performance-section.md)
is retained separately because root AGENTS.md also contains other agents' unintegrated work.

## Installed build and artifact lifecycle

On7 October the owner explicitly requested installation. `/Applications/Next Notes.app`
now matches the tested release exactly: SHA-256
`a00ac67934f9357c708c2c17f32ee685ee87734ff72471ed14232b4f1ba95046`, UUID
`8F85CDCD-3E0A-3814-B275-F02C864C844E`, stable `Next Notes Local Signing` identity.
The source pins were checked against `422ba5f`; the installed binary was checked against
the tested staged binary and its strict signature. This build also contains the shared
checkout's pre-existing changes; only the repair and reported checks are this investigation's proof.
It runs normally against owner data, with no fixture/settings override. Current process
IDs and rollback location are recorded in the report's `installed-release.json`.

Installation used the existing install lock, gracefully quit only the verified previous
normal process with no active recording, retained the original bundle for rollback and
swapped a fully verified copy. It did not sweep other agents' builds/caches or touch data.
Keep only the useful current build and explicitly needed rollback/reproduction artifacts.
After an owned staged copy is superseded and no process uses it, remove that exact copy,
retain compact hashes/patches/logs, and report reclaimed space. Do not clear model caches,
recordings, owner stores or active worktrees to make a performance test pass.

## Dictation and other subsystem evidence

The dictation agent owns those production changes. Its current
[pipeline analysis](Tests/Reports/dictation-latency/2026-10-07-pipeline-analysis.md) and
[follow-up](Tests/Reports/dictation-latency/2026-10-07-followup.md) distinguish producer
repairs from still-red complete-delivery/cleanup quality and native acceptance. Reuse
their exact artifacts and regression seams; do not infer a polished-delivery pass from
recognition replay, a pre-clean count, a different model's answer or a pressure fallback.
Historical architecture estimates, model-only speeds and competitor marketing numbers
remain labelled as such. They must not override newer measured contracts or stored choices.

Seven dictation producer repairs now have original/fixed regression evidence: partial
rules manufactured sentence endings; session cancellation missed entered cleanup;
Apple layout deadlines joined an uncancellable response; rejected heads kept running;
expired usable heads admitted work after delivery; nonstreaming cancellation discarded
valid native KV; and the router waited for a plan after its own rules had already rendered
final structure. The latest actual router cases fail3 and1 before repair and pass afterward.
The actual native dictation runtime entry originally reused0/649tokens after cancellation;
the repair reuses649, decodes one and matches a cleared-context control exactly. Genuine
decode errors still clear cache. This private S1 runtime proof is not MiniCPM quality or
the20tokens/s ASR+voice floor. All formatting features, schema and deadlines are retained.

An owner11-word hold spent128ms finishing ASR and12.86s in cleanup. Earlier optimized
full-path public replays under competing load also remain slow (warm8s/121s holds ready
in14.96/40.89s). They predate the latest three repairs and are not clean paired speed proof.
Selected pre-clean group counts include rules fallback; the additive optional
`precleanAnsweredGroups` records selected nonempty completion boxes, also including
formatter fallbacks. Neither proves accepted semantic repairs. Ordinary-prose native
layout quality and universal2s polished delivery remain open. Coordinate the next optimized
consumer checks and sequential complete-path replays through agent-relay; do not replace
the installed app or contend with the owner's pending Meet check. Exact logs and source
pins are in the linked follow-up/evidence.

## Long-call quality and identity acceptance — 7 October 2026

The latest [Zoom audit](Tests/Reports/meeting-reliability/2026-10-07-zoom-audit/README.md)
covers a 40m05 recording. The owner reports responsive operation. First 7m43 and last
approximately ten minutes of retained footprint samples peak at 1.007 and 1.168 GB;
the middle interval is unobserved. Capture integrity and retained meeting counters show
no missing capture frames or writer failure. Machine-wide swap does not identify an
allocating app. Final ASR, speaker processing and notes took 34.155, 9.958 and 123.881s;
context/write medians below 4ms do not justify optimizing them ahead of notes quality.

Generation success, full prompt fit and an untruncated response are insufficient quality
gates. This full 14,062-token input produced only 137 tokens and missed a follow-up while
misattributing experience. Audit factual coverage, attribution, commitments and uncertainty
against the actual transcript; compare alternatives on the same copied input and model.
Retain latency, strategy, pass counts and quality together. Keep owner speech, generated
notes and voiceprint vectors private. A replay OK marker means completion, not quality.

A wake detector is a meeting data producer: false wakes label ordinary speech as agent
commands, exclude it from notes and can prioritize it over final ASR. The actual text
producer accepted ordinary They will, Well and I will for Hey Will. Original/fixed
real-source probes fail 8 / fail 0 unchanged ordinary-speech cases with the native
lexicon; the optimized full-app wake flag passes. Complete word boundaries and a matching phonetic
onset preserve the existing positive/accented and microphone-authority contracts. Never
hide this defect by retaining every command as ordinary transcript speech. Text regression
success does not prove acoustic wake recall or next-call behavior.

Participant identity requires separate evidence for roster and voice-to-person binding.
Reuse existing calendar enrichment, Meeting.speakerNames and the speaker naming UI.
Provider participant IDs linked to transcript entries or observed active-speaker intervals
may supply the binding; roster order, count and model guesses do not. Emails are optional
provider data, never inferred. Keep user-confirmed names and uncertain labels. Provider
account/grant requirements and live UI contracts must be verified before promising universal
Zoom/Meet naming. Run participant collection off the capture callback without serializing
microphone, model or speaker. The completed detected call has no retained identity evidence.

Long-run monitoring must retain bounded per-meeting aggregates/coverage through an existing
recording/usage seam. A bounded global metrics ring that drops the middle of a long call
cannot establish a complete soak. Do not add a second metrics ledger or unbounded samples
as a substitute for meaningful whole-session counters and sampling-coverage metadata.


The [meantime CPU optimization](Tests/Reports/dictation-latency/2026-10-07-meantime.md)
integrates commit35559e4: spoken-name scoring, lazy file-tag preparation and immutable
compiled spoken-structure patterns. Exact original/current producer and actual narrowing
consumer comparisons pass2,183checks; the existing structure corpus,32profile/toggle
comparisons and four concurrent scanner suites pass. Optimized public fixtures narrow
200candidates in38–40ms instead of81–87ms and tag67loose names in13.04ms instead of25.93ms.
An unchanged-text structure reuse fixture drops6.29ms to1.81ms; two actual router reuse
expressions remain in the canonical working tree. These are implementation CPU savings,
not complete polished delivery or reference-machine ASR+voice throughput acceptance.

The owner has now completed a responsive40m05Zoom call. The meeting agent acknowledged
stable sources including35559e4 and owns the agreed development-heavy window for one
shared optimized build, actual cleanup-router/structure checks and sequential notes replay.
Dictation has released its light-check claim and runs no competing compiler/model.
The remaining native dictation quality, live UI, external delivery and universal2s targets
remain open. Use the new report's source pins and task patch; preserve foreign staging.

Native comparison on the same copied transcript fails factuality across MiniCPM
whole/three-part, Apple, Qwen3-4B and Qwen3.5-4B outputs (63/160/162/261/98s). Bigger or
slower is not a quality guarantee. Qwen3.5 invents a deadline. No default is promoted.
Two original native MiniCPM maps hit length but the completed reduce disclosed no partial
coverage. The extraction producer now carries incompleteFacts through its typed result
and notes. The unchanged original native assertion fails before and passes after repair:
the same 3 maps / 1 reduce, 1860 tokens and byte-identical generated body plus a coverage notice.
No additional model pass or retry; disclosure does not recover the missing facts.
Three live context candidates misclassify descriptive discussion despite exact quote
checks: provenance is not intent or semantic confidence. That classification gate and
final-speaker projection into live context remain open. Never treat empty structured-note
arrays as a true negative when generated-note input already failed coverage.

The source-invariant optimized candidate is installed at /Applications/Next Notes.app,
SHA256 ed67302fae3c246bbfc377be77e954a0070f17b3b4c5771cfe5e1a04e0d628ad.
Commits d729747/8df94cb integrate both producer fixes. Final native wake, cleanup-router/
structure, meeting-context, longform/truncation, health90, integrity 67 and isolation
21files33defaults pass; isolation's embedded 18 browser tool-loop failures reproduce an
inherited open gate. Normal startup shows the real owner history and leaves all eight
original meeting files unchanged. Passive startup footprint spans889–894MB, not a new
meeting soak. Nonstreaming notes do not expose first-token/prefill timing; comparisons
are not reference-machine ASR+voice throughput proof or causal speed improvements.


[Current shared dictation verification](Tests/Reports/dictation-latency/2026-10-07-shared-release.md)
uses installed-equivalent30744 with all retained repairs. Actual router/structure and
 dictation/hygiene/capture pass. Warm 8s holds reach isolated insertion in128/116ms;
121s holds still take6.20/6.32s: recognition22/46ms, tail generation365/370ms and a
rejected six-second layout wait. Live text exists at release in every run. Retained
cleanup timings principally cover round2 and reuse1,297tokens; answered-head counts
may include fallback. Cold startup21.5s, long-layout quality, universal2s and external
delivery stay open. No paired quiet speedup or ASR+voice throughput-floor claim.
All owned diagnostics joined and the development claim is released. Full formatting,
schema, validation and budgets remain; CPU improvements are in the installed build.

## Continued dictation producer verification — 7 October

The [continued optimization report](Tests/Reports/dictation-latency/2026-10-07-layout-preparation.md) keeps the long6.1–6.25s failed preparation experiment separate from retained producer repairs. Fixed-regex reuse saves about0.96ms per fixture pass and the exact-output ASCII sentence path about0.55ms per14KB split; these are component observations, not complete-path gains. Cancelled router layout now receives cancellation while semantic cleanup is still held. Local planner availability is inside the unchanged caller budget, and a timeout no longer joins an uncancellable responder. Native work still requires its own owner join.

A correct native French plan exposed destructive renderer unit mismatch: `D'abord` counted as two lexical pieces, then two whitespace words were removed, losing `on`. Original actual renderer/router fails7 assertions; optimized45909 passes the same assertions and existing router/structure checks. Verified whole-prefix words are now removed in the same unit as the eight-word guide; later matches preserve opening words and nine spoken words remain rejected. Existing non-prefix evidence policy remains, so semantic false-list inference is still open.

Native private MiniCPM full grammar, after completed weight preparation and an ungraded initial generation, preserves the exact French content but still fails3 mixed-layout assertions; six case durations2.117–5.795s are model-only observations. Full and conditional typed native Apple schemas each fail14 assertions; no representation/model/default is promoted. Universal2s polished delivery, cold ASR, paired accuracy and physical external insertion remain open. Staged optimized dictation/hygiene/segments/commandkey/duplex pass; the two inherited duplex reducer divergences remain reported. Native-shutdown installation hold and all quality/permission/latency contracts remain.

## Meeting native quality loop — 7 October 2026

Quality gates reject a model completion that omits the real follow-up, invents its date
or owner, or makes ordinary discussion actionable. A valid exact quotation proves
source provenance, not future intent. Positive recall and safe non-actions must pass
together through the actual producer, application and saved consumer path.

First optimized native evidence: source-evidence23, extractive-contract18, health90,
integrity67 and agent-evidence89 passed. Performance failed2/17 because the new summary
used the existing ISO8601 date codec, which drops fractional seconds; summary-specific
reference-date doubles repair that producer boundary without changing legacy clocks.
Original actual-codec probe fails3; corrected passes3. Native19 remains pending. Speaker
projection failed1/39 on a test comparing unsaved dates with normalized saved dates;
its test now preserves separate durable and in-memory baselines, with producer unchanged.
The isolated store check preserves21files33defaults while embedded production browser
admission still fails18 assertions; record both verdicts.

The copied full meeting quote selector failed with zero admitted rows in71.63s, including
49.407s prefill and13.220s generation. The original early throw lost raw selection;
diagnostic failure visibility is now repaired in source. The mapped evidence writer
completed in203.57s with7passes, three600-token length finishes, two dropped parts and
one retained fact. The actual follow-up was missing. Historical same model/window
159.56s is context, not a controlled paired speed comparison. Native cost and quality
are rejected; no default or writer promotion. Bounded source-ID selection through the
existing map/collapse seams is under investigation. Eight targeted action comparison
passes completed in29.50s wall, but the true future follow-up was missed. Wire format,
production schema decoding, quoted source and semantic action meaning are scored
separately; original unsaved inference snapshots were not available.

Raw owner speech stays in private diagnostics. Signed candidate identity, source
invariance, numeric usage, failures, corrected producer proof and remaining acceptance
limits are retained in the [native loop report](Tests/Reports/meeting-reliability/2026-10-07-quality-loop/README.md).
Meeting and dictation compiler/model windows remain serialized by agent-relay machine
claims so development cannot recreate the owner's memory-pressure incident.

Copied meeting diagnostic payloads must bypass the public system-log mirror. Redirected private stdout alone was insufficient with the former `writeSelfTest` recorder. Current source routes copied notes/action/extractive replay through a private writer; native absence proof is pending, and historical local logs are not erased.

Second source-ID map/collapse and six reconstructed actual production-window action diagnostics are staged for optimized native proof. An unchanged14-check speaker helper probe rejects original lost identity4 and intermediate lost explicit-manual-map4; corrected passes14. Native saved service/consumer checks remain pending. Source/build coordination overlap was corrected before accepting any native snapshot; all subsequent heavy windows require canonical source freeze.

Native gates are separate: source syntax/admission, durable consumer behavior, semantic coverage and physical performance. Second release performance19/speaker51/evidence30/extractive36 pass only their explicit scope. A 54.97 s mapped Mini replay with five of 519 selected utterances fails substantive coverage even with valid IDs and no cut output. Reject such a candidate; do not replace recall with a record quota or claim `incompleteFacts=false` means all topics were covered. Two-second process samples are sampled values, never continuous peaks or reference-machine ASR/voice acceptance. System-log privacy absence must state retained process-entry count and control limitations.

Third-loop admission: faster source-ID summaries are experimental and require explicit
SelfTest opt-in; production keeps its original single/map/collapse/reduce prompt and
budget contract. Corrected source parity and explicit production opt-in guard pass;
initial shim failures remain retained. JSON shape, source evidence, semantic meaning,
whole-meeting coverage and physical speed are distinct gates. Actual Mini action windows
returned incomplete objects below400tokens; the producer now retains complete labelled
utterances under the same3000-character boundary and sends one400-token constrained
call. Source-owned primary evidence must still select the correct utterance; it does
not prove future intent, recipient identity or an action permission. Original source
contract fails11/27, corrected passes27, using substituted external boundaries; native
sampler/semantic acceptance is pending. Source IDs cannot rescue a model that selects
only greetings, and an empty result from malformed output is not a safe negative.

Third release compilation failures are retained, with joined children before repairs:
first the test writer actor annotation, then two pure JSON helpers required nonisolated
annotations for scripted Sendable provider closures. These change test isolation only.
The reused-cache build has an explicit6.5GB-free/8GB-swap coordination gate; the default
10GB gate is not claimed to pass. Compilerjobs2 does not cap Swift's internal WMO threads.
New physical ASR/voice soak, actual provider participant/name bindings, legacy full-note
semantic omissions and the inherited browser production gate remain open.


Fourth source loop — verified evidence remains separate from open quality. Third signed
release cff85f47 is uninstalled: 16 focused native checks pass, including action-input27,
evidence33, performance19 and committed speaker51; six shared extras report OK, but
embedded browser production18 failures and two duplex divergence diagnostics remain.
Six Mini action windows now complete valid schema, yet miss the real future follow-up.
Qwen selects an antecedent partial utterance rather than the required complete primary.
Stronger experimental source-ID Mini notes take148.34s, add three collapse passes and
still omit material content. Valid shape/source IDs are not semantic coverage. These
experiments stay behind explicit SelfTest opt-in; legacy production prompts/budgets and
owner model/default choices remain unchanged.

Actual old and third model output reveals a shared topic/unresolved producer defect:
punctuation-only text normalizes to a space, substring/shared-token matching replaces
and deletes distinct retained facts, and capacity append can evict earlier identities.
The unchanged actual-source save/fresh-read probe fails58/185 before and passes185 after.
The existing merger now ignores empty/exact duplicates, adds inferred enrichment only
within40 rows and preserves all existing facts and metadata. Native full-app proof is
pending in the fourth frozen release. This does not certify new model generalizations,
recover already erased facts, or solve future-intent recall.

Participant names require actual observation and voice binding. The explicit one-shot
Zoom/Meet diagnostic is guarded before startup, uses existing authorization and unique
process/target identity, and writes raw labels/URLs only to private0700/0600 diagnostics.
Its proposed19 generic contracts have not yet passed native execution. It assigns no
names, polls nothing, and changes no meeting/defaults. AX wall deadlines and full CDP
reply bounds remain open; do not move it onto the recording path. Provider roster data
alone cannot identify which voice produced an utterance. Physical Zoom/Meet evidence,
reference-machine ASR/voice soak and whole-meeting factual quality remain open.


Fourth native acceptance, 8 October UTC (7 October owner local time): signed candidate
476d1c67 has1170 invariant Sources/Resources pins and remains uninstalled. All18 focused
native flags and six shared extras report OK. Topic retention passes185 unchanged
save/fresh-reader checks; participant selectors/authorization pass19 contracts and six
actual invalid/conflicting preflight launches refuse before startup. Performance19,
committed speaker51, action-input27, evidence33/extractive36, usage27, health90,
integrity67 and agent-evidence89 remain green. Isolated owner21files/33defaults stay
unchanged; embedded browser18 failures and two duplex divergence diagnostics remain.

The real original/fixed Mini six-window comparison uses identical prompts AND raw
replies. Five original outputs erase9,11,13,13,12 prior topic texts; fixed preserves all
prior texts in every window. Both workflows run six existing model calls and take33.58
and33.60s; this is no speedup claim. The future follow-up is still missed, so semantic
intent remains FAILED. Whole-note first loss remains unlocalized; exact existing-pass
private diagnostic forwarding is cache-staged/uncompiled for the next coherent gap.
Normal legacy prompts/budgets and owner roles/defaults remain unchanged.

This Mac is Apple M3/16GB. Compiler workload temporarily reaches swap8.77GB; the checked
max8 heavy gate refuses further inference until recovery. Sequential scripted nonmodel
contracts run only under an explicit max9/free6.5GB gate with65% free memory; this does
not claim the max8 gate passed. The actual Mini replay starts after max8 recovery at
swap7.977GB/free6.707GB. Reference hardware capacity is not ASR/voice soak or decode-floor
acceptance. A full310-file matching duplicate current bundle is removed only after no
active executable uses its path, reclaiming140,738,560 allocated bytes. Installed useful
build, repaired rollback, original crash reproduction, comparison and candidate remain.


### Quiet speech and exact pass causality — fifth loop

Keep amplitude segmentation hints separate from proven recognition coverage. The meeting live/final admission gate can refuse below0.01 RMS blocks despite saved audio and zero queue drops. Offline source-algorithm classification is not actual native recognition. A DC/sine control and fabricated ASR marker cannot prove a spoken phrase; whole final/live agreement is circular when both use the same admission gate. Native direct recognition and the actual meeting consumer must receive identical pinned PCM, with independently aligned words, silence/noise controls and complete elapsed cost. Any conservative admission change remains a hypothesis until those controls and fullSession persistence/workload proof pass.

Copied note diagnostics may wrap only existing calls, forwarding the exact tokenizer, plain/grammar arguments, current recorder, completion/error and cancellation once. Keep raw prompts/replies private. Record map/reduce topology, callcount, feature/pass and first-loss source intervals. A copied replay using brief.empty differs from original production context; disclose it. Neither schema validity nor unused output allowance proves semantic coverage. Retain both missing facts and fabricated claims. The fifth compiler starts under explicit max8/free6.5 coordination at7.870GB swap/7.376GB free; default10GB and ASR/voice soak are not claimed.


Fifth native findings: direct recognition of the independently aligned52,566sample quiet window recovers7/7words, but the actual meeting gate emits0segments before ASR. Zero capture/queue loss therefore cannot certify word coverage. The actual dictation engine still emits1or2words on the same input; no quiet fix is declared. Test noise/silence and complete isolated MeetingSession capture/final/save/fresh readback before adopting conservative admission. RMS pause fragmentation requires native emitted-word evidence, including mixed loud/quiet speech, rather than complete partition alone.

Signed7b3c7349 has1,171 invariant pins and19 focused native flags reportingOK; isolated owner21files/33defaults stay unchanged and embedded browser18 failures remain. It is uninstalled. The whole copied legacy note pass reads13,062prompt tokens and returns175/1,600allowed tokens with normal stop; missing substantive facts are already absent from its raw reply. Its empty brief differs from original production context. A second intended8,192window run supplied an unsupported modifier and is retained only as a whole observation, not mapped acceptance. Full timings/resource limits and remaining gates are in [fifth native acceptance](Tests/Reports/meeting-reliability/2026-10-07-quality-loop/fifth-native-acceptance.md). No model/default, prompt/budget or extra production pass is promoted.


Fifth corrected semantic review: three native map calls and one reduce preserve all519
source lines and raw intermediate replies, yet final complete coverage remains0/10.
Nine material distinctions first fail at map and one at reduce; first two maps spend
their600-token limit copying opening speech and filler. Disclosure is not recovery.
Direct native zero/DC/noise controls emit no words; explicit complete-audio engine
extras hallucinate two words on digital zero. Quiet7/7 direct versus0 actual meeting
segments establishes the admission failure, not an adopted fix. Read the
[fifth acceptance report](Tests/Reports/meeting-reliability/2026-10-07-quality-loop/fifth-native-acceptance.md).
The obsolete fourth candidate is safely removed with125,845,504allocated bytes
reclaimed. Sixth source experiments and the actual speaker-name save repair remain
uncompiled and uninstalled; preserve default prompts/roles until native acceptance.


Sixth loop: signed8d079a72 has1,173 invariant pins and is uninstalled. Actual old speaker-name sheet callback passes prior51 but fails10/81; actual repaired View save/current-row/context/audio/fresh-reader path passes81. Physical sheet/banner interaction remains unobserved. Legacy notes prompt hashes and strict opt-in/provider contracts pass; native semantic arms are unrun. Actual isolated Session/writer/Stop/same-final-task/save/fresh-reader scripted original134 and conservative138 pass only their declared transport/omission scope. Original quiet speech is omitted at all four stages; native words, pause/noise and workload are not accepted. Normal max8/min6.5 refuses after compilation; reviewed three-flag nonmodel max9/min6/free60% exception is separate. No model/default/prompt promotion. Third obsolete bundle cleanup reclaims125,661,184allocated bytes; fifth remains the peer's original ASR baseline. Read [sixth acceptance](Tests/Reports/meeting-reliability/2026-10-07-quality-loop/sixth-native-acceptance.md).

For long saved meetings, a chunked read that appends into one whole Float array still has duration-scaled memory. A40m05 selected16kHz channel is146.79MiB; final channels are sequential, so do not claim simultaneous two-channel retention or attribute whole process footprint from that estimate. Prefer the existing FluidAudio AudioSampleSource seam only after actual bit/channel/cut/tail parity, save/fresh-reader, native word/global speaker identity, read-error/cancellation and measured IO/memory checks. Cache-only bounded PCM candidate is unapplied/uncompiled; no new store, queue, pass, mono mixing or independent-window speaker clustering is authorized by its source review.


Sixth actual native quiet Session joins23.351s, all6calls succeed, source domains/save/freshread pass, but2/23 gold-word checks fail. Both final tracks recover7/7; both live tracks corrupt the last two words after RMS pause cuts32,000+20,566samples. Output wordcount7 is not seven correct words. Explicit conservative admission alone is not a production repair. Fix the responsible pause detector with independent quiet/mixed/noise/workload proof; preserve product rules meanwhile. Eleven samples peak197,412,352footprint/659,636,224RSSbytes. Cold first queue compute21.681s includes preparation; nativeprocessing0.093s, later warm0.060–0.069s. Separate single-ASR8.5swap/min7disk/free60%/1GBsample exception, not normal8gate or ASR/voice acceptance. Read [native word review](Tests/Reports/meeting-reliability/2026-10-07-quality-loop/sixth-quiet-session-native-word-review.json).

Bounded saved-audio component: the existing chunked reader retains a whole Float channel. Cache-only candidate uses the existing AudioSampleSource seam for native LPCM16/16k/stereo CAF with legacy fallback. Actual FinalTranscriptService/same Task original/fixed60s and40m05 orderedPCM/source-time/save projections match;1,174 maintained boundary assertions pass. First-call held incremental footprint40m05 is156,254,352B versus2,261,016B, one snapshot per fresh process—not full-run peaks or nativeASR/Session/store/globaldiarizer/voice/speed proof. Houroriginal232,816,832B completes; fixedhour prelaunch reported-free60% admission refuses, UNRUN. Compiler glue/dependency/stat-call failures retained; candidate source remains unapplied/uninstalled. Read [bounded-reader evidence](Tests/Reports/meeting-reliability/2026-10-07-quality-loop/bounded-audio/README.md).


Meeting follow-up, 2026-10-08: corrected quiet-pause component uses the same 174 assertions; original fails 30, fixed passes all. This proves boundaries/transport, not native words/noise or speed. Participant walker/selector component original fails 6 of 11, fixed passes 11; actual capture/call state/voice binding remain open. Reviewed native notes profiles 55/50 and separately 55/40 both join at guards without a result; do not relax another threshold or retry automatically. Wired/compressor growth and app RSS/footprint are distinct observations, not allocator attribution; reported free percentage is not a byte allowance. Investigate existing runtime n_batch512 versus actual128 prefill and default n_ubatch before promotion. Separately prove Session sorted insertion versus context append-only ingestion through existing producers; it does not explain complete reconstructed semantic inputs. Keep unproved meeting candidates behind exact SelfTest opt-ins. Read [the next increments](Tests/Reports/meeting-reliability/2026-10-07-quality-loop/2026-10-08-next-increments.md), coordinate source ownership and broadcast real verdicts with agent-relay.

Source7 meeting producer adoption, 2026-10-08: exact late-track Session sorted insertion versus context append cursor is reproduced; original5 coupled/14of25 maintained failures, corrected all coupled/25of25 pass through actual Store/Extractor and copied exact Session/reader with declared substitutions. Working source supplies exact incoming finals, reuses source-aware keys and maintains chronological order only in the existing360-row buffer. Broader overlap clock/model semantic recall are separate. Bounded audio/pause and participant coverage source is applied but full-app/native acceptance and owner installation are pending; exact SelfTest guards retain ordinary paths. Monitor lifecycle repairs have original/fixed authored controls, not product performance proof. Read [Source7 adoption](Tests/Reports/meeting-reliability/2026-10-07-quality-loop/source7/ADOPTION.md); coordinate shared task-store release readiness before owner launch and broadcast real verdicts through agent-relay.

Source7 release evidence, 2026-10-08: compiler2 exposed one unqualified nested SpeakerRun type; the one-line MeetingDiarizer qualification is applied and retained with the original failure. Compiler3 then joined at the unchanged3GB summed owned-process footprint guard after66.465s, peak3,192,787,480bytes, owner8/source1176unchanged and no8GiBswap crossing. No candidate/native verdict follows. A separately reviewed compiler-only single-worker flag preserves release/WMO/resource guards and requires actual owned frontend identity/numthreads1; this is a memory hypothesis, not an app performance result. Exact installed-associated App source was recovered for startup/shutdown parity review; task-store hashes alone do not establish broader release readiness. Zoom/Meet provider-name routes require actual grants/session/timing evidence; roster order never assigns a voice. Read [compiler evidence](Tests/Reports/meeting-reliability/2026-10-07-quality-loop/source7/compiler3-guarded-stop/README.md) and [identity options](Tests/Reports/meeting-reliability/2026-10-07-quality-repair/speaker-projection/NATIVE-RECORDER-IDENTITY-NEXT.md). Persist and broadcast exact scope with agent-relay; keep owner payloads private.

Source7 current acceptance, 2026-10-08: the minimal four-file live-ingest producer/test patch is eligible only for bounded source integration, not an owner install. Working-source original/fixed component checks are 14/25 failed versus 25/25 passed with declared substitutions; exact HEAD-relative integration and actual app entry remain native-unverified. Audio/pause experiments stay opt-in and uncommitted. Actual SwiftBuild overrides requested single-worker compilation to eight; the reviewed native-backend build-only workaround has no completed compiler result. Its first fresh admission records free54% against required55%, swap7.081543GiB and disk8.192543GiB, refusing before any child. No automatic retry, guard relaxation or installed-app change follows. Existing owner app remains ed67302f. Keep original/fixed word quality, notes semantic coverage, real participant voice binding and concurrent ASR/voice soak open. Read [current acceptance and next steps](Tests/Reports/meeting-reliability/2026-10-07-quality-loop/source7/CURRENT-ACCEPTANCE.md); share exact verdicts via agent-relay.

Resumed meeting acceptance, 2026-10-08: initial headroom checks refuse before launch; owned cleanup retires456,404,992 allocated bytes, with425,250,816-byte immediate root available-space gain. After the owner closes Chrome windows, native7 starts at62%/swap4.180GiB and proves single main compiler thread, but cleanly joins at3GB guard (peak3,165,213,472B). Independently reviewed compiler-only native8 raises charge cap to5GB with stronger start60/ongoing45/maxswap6/disk8 bounds; it also joins at the cap (peak5,011,527,872B). Both preserve owner8/source1176/protected cache; neither produces a candidate/native verdict/install. No further cap increase follows. Existing installeded67302f reopens asPID29701 after graceful idle UI quit; physical UI readback fails with a capture error. Repaired rollback and useful fifth/sixth comparisons, source/failure evidence, owner data/models remain. Read [the resumed check](Tests/Reports/meeting-reliability/2026-10-07-quality-loop/source7/RESUMED-CHECK-20261008.md); retain exact refused and unrun scopes and share via agent-relay.

Attributed meeting context, 2026-10-08: text-only duplicate detection erases matching words from another stored speaker/source. Exact actual Extractor apply/merge50 checks fail27 before and0 after; retained actual ContextStore/parser/apply/atomic save/fresh-reader15fixtures185checks pass with declared scripted boundaries. Root applies the three-file producer/same fixture/existingTopicMergehook, current1177pins. Duplicate attribution now requires text/source/storedspeaker; actual inferred-model-summary echoes and40-row bound remain. No new store/queue/pass/action authority or automatic person identity. Native current App/bus/complete factual notes/speed proof and installation remain pending; installeded67302f unchanged. Read [attribution evidence](Tests/Reports/meeting-reliability/2026-10-07-quality-loop/attributed-context-dedup/README.md); keep private payloads out of reports/relay and retain actual original/fixed scopes.

Meeting batch-build outcome, 2026-10-08: Native9 explicit optimized/noWMO/batch32/singlejob diagnostic proves actual32-primary main compile and last-j1/noWMO driver. It joins135.246s at reported-free48<50 guard, sampled summed ownedpeak726,141,856B; swap samples4.126→3.930GiB. Lower sampled compiler charge is not a completed paired benchmark, allocation cause or runtime parity. Source1177/owner8/protectedcache unchanged, all CLI descendants joined; no candidate/native functional verdict/install. Installeded67302f remains singlePID29701, owner files retained. Source attribution commitc6d850c retains actual50/185 bounded proof; semantic omissions/quiet native words/naming/ASR+voice soak remain open. Owner restart requested; no cap increase/automaticretry, heavy/source claims released and useful shared partial cache retained. Read [actual batch outcome](Tests/Reports/meeting-reliability/2026-10-07-quality-loop/source7/native9-outcome.json) and [resumed evidence](Tests/Reports/meeting-reliability/2026-10-07-quality-loop/source7/RESUMED-CHECK-20261008.md).


Three-meeting audit,13October2026: current installed0.2.24 SHA503e0e40/UUID61DC74FF passes strict/deep signature; installing-peer relay1067 and eight matching snapshot producers supply bounded source provenance, not fresh functional proof. Native start55 refuses reportedfree39%; no build/model/test/install. Two newer long calls save22,782,827/18,220,683 system-trimmed frames despite captureDrops0; system live timestamps end near half walltime. Remaining38m CAF Others has39,680nonzeroframes only infirstfewseconds then digitalzero, whileliveASR succeeds. Writer/transcriber cumulative sample clocks propagate half-cadence into5s-bound padding/trimming; actual HAL/ABL/conversion first broken contract unproved. RetainedM2/M3 sampledfootprint peaks1.027/0.802GB; this is not the prior helper runaway or continuous allocation/ASR+voice acceptance. Diarization no-speech refers to saved systemaudio; automatic knownloss guard differs from manual Identify path. Current full titles are manual and rosters empty; repeatedcalendarfetcherrors unlocalized. Current cloud note versions require pinned semantic audits; notes.json.model describes separate knowledge extraction. Preserve exact audio privately for original/fixed replay, no ownerdata/default changes. Owner confirms AirPods audio; profile/format cause unproved. Current notes have27 selected material omissions plus directional/temporal/attribution errors; counts nonexclusive, raw cloud firstloss unlocalized. Read [audit and plan](Tests/Reports/meeting-reliability/2026-10-13-audit/README.md), updated [roadmap status](roadmap/done/MEETING-RECORDING-RELIABILITY/STATUS.md), and share actual verdicts via agent-relay.
Whole meeting scope, 13 October 2026: the owner requests coverage across OS-exposed inputs, outputs and route transitions, sourced preparation and full titles, participant evidence, and an automatic completion/review card with background note corrections before implementation. The arbitrary 55% free-memory diagnostic gate is removed for this authorized cycle. Installed build `503e0e40` has scoped green evidence for 21 distinct flags after the explicit three-file ASR replay; isolation retains inherited nested failures. A historical private 185-case corpus replay refuses missing temporary inputs. All owned native processes joined; 20 original meeting artifacts and 1,179 source/resource files stayed unchanged. Sampled owned peaks of 174 MB / 145 MB do not establish whole-machine or ASR-plus-voice acceptance. Current UI confirms the speech warning and disabled speaker renaming. The borrowed-buffer probe rejects the tested layout mismatches; a deliberately stale 48k declaration for authored 24k time is accepted as half duration, a boundary hazard rather than the confirmed incident cause. The [18-milestone whole-pipeline roadmap](Tests/Reports/meeting-reliability/2026-10-13-full-pipeline/ROADMAP.md) includes 20 device configurations, 15 transitions and dated official provider constraints. Physical routes, actual person/voice joins, proactive UI, the 27 selected semantic cases and reference-workload qualification remain open. No product source, default, grant or installation changed. Require original/fixed native-producer proof, shared playback/echo ownership, current-input/output admission, source coverage, manual-edit and retention preservation, and the existing external-action approval boundary.


## ASR candidate probes — 22 October 2026

The [candidate report](Tests/Reports/asr-candidates-2026-10-22/README.md) retains eight M3 runtime comparisons across all requested model families, exact artifact sizes, source/module/model hashes, raw fixture transcripts and one-at-a-time cleanup receipts. Settings live-text copy is repaired in source. New app provider integration, a native app build/install, larger-corpus quality and full-duplex/reference-workload acceptance remain open. Cached FluidAudio Git alternates are missing; object/module fingerprints establish the probe inputs, not a clean rebuild or installed-app equivalence. Vendor throughput is not substituted for these measurements. No model/default promotion follows.

Resumed ASR live suite,22 October2026: [all eight paced runtime candidates](Tests/Reports/asr-live-latency-2026-10-22-resumed/README.md) completed in coordinated serial windows. Three warmed holds per supported language use the same400ms first prefix/1s updates and an independent release clock, including in-flight drain. English speed-first candidate Phonon: median421ms first provisional word/52ms release-to-final; French candidate Voz:446/83ms. Whistle shows French provisional text sooner429ms but final156ms and substantive short-excerpt substitutions; native commitment remains later. Qwen1.7B has the best limited whole-file French WER3.97%, but601ms first/1297ms final and1.608GB weights. These callback timings exclude physical capture/UI/polish/insertion/concurrent ASR+voice qualification and cannot establish minimum latency under another feed cadence. Single-fixture WER is not broad accuracy; numeral rendering is separated from content errors. Default Phonon startup exceeded120s; the retained subsequent5/10s short-graph configuration succeeded with identical model/audio. Harness original/fixed pipe-drain and owned-descendant timeout regressions fail/pass; all13 model-free tests pass. All eight children exited0/joined, one candidate downloaded/run/deleted before the next; original installed v3 assets retained with23 unchanged hashes. Final owned cache contains only a zero-byte lock, no native child;3.73GiB disk free. Cold model preparation, actual app integration/default promotion and broader quality remain open. Earlier pressure results and Whistle internal batch TTFT/CoreML feasibility remain separate evidence, not pooled live benchmarks. No installed app/default changed.

22 October 2026 archived source integration: [review, exact pins and current verdicts](Tests/Reports/archive-integration-2026-10-22/README.md). Reviewed stream output (`8e4243d6` + `0be933e6`), round-five Google grant/cache/cancellation backend and pinned evaluation-clock defaults are applied to current app source, preserving newer capture/authority/runtime and native voice work. Same 658-case component fixture fails 552 assertions against the old decoded-piece adapter and passes all after; optimized executable `6369272f` passes eleven native root flags, including Google 402 assertions, stream 658/0 plus vocabularies, notes truncation and scripted clock 2/2. Whole-module typecheck and release link pass. Isolation preserves 21 files; an external owner-domain witness preserves all 89 preference keys without retaining values. Its inherited nested browser 18 failures remain open. Real Google/physical UI/voice, aggregate model quality and performance/default promotion are unproved. Latest archived ACK2 still fails its own retained cache regression; unsupported parallel Catch-up playback and rejected model experiments stay excluded. Catalog link production now uses tracked/staged evidence: the unchanged peer-report regression fails before, all 12 catalog tests pass after. Once-only CPU/private-S1 prefix cache passes with 646/666 tokens reused; owner files/preferences and model hash remain unchanged. Its prefill observations are diagnostic, not performance/default acceptance.

22 October main release: installed optimized 0.2.24 build809, executable SHA-256 `bce5ef99b315110ef535122ded59329eb6bec1d7a53d6e573ac9a07f4af95620`. [Release record](Tests/Reports/release-2026-10-22/README.md) retains packaging original/fixed evidence, final33/34 native checks, inherited worker missingSnapshot and nested tool-loop failures, owner preservation and rollback. All1,185 support files and91 current preferences match admission after installation; original89 saved values and62 taskIDs retained. Normal startup runs; visible UI inspection unavailable because Computer Use capture failed. Diagnostic harness persistence now uses the existing isolation seam for all self-tests and its history is guarded/restored exactly. Eight-model45-hold ASR app timings exclude physical mic/UI/cleanup/insertion/concurrentvoice; physical TTS suite remains separate and no audible-voice default promotion is claimed.


22 October TTS speaker follow-up: [retained native-clock experiments](Tests/Reports/tts-2026-10-22/README.md) separate first generated PCM, first post-gain render, queried presentation estimate and threshold-qualified microphone pickup. Original fixed-onset-window control rejects a faint lead; repaired aligned/persistent onset passes the same control, retaining thresholds and failed requests. Native hardware-format observation removes timestamp regressions seen in the converted16k observer; the underlying converted sample/host overlap remains unexplained, and production capture/conversion is unchanged. Under paced native ASR decoder load, Pocket27/30, Kokoro26/30 and macOS28/30 warm pickups qualify; Qwen's separate three-warm diagnostic qualifies1/3. Phonon/Qwen's30-request cells are disk-admission refusals. The owner confirms other sound/audio was playing: no survivor-only acoustic medians, fastest-audible claim or default promotion is accepted. Physical tests and the reference decoder are stopped/joined pending a quiet interval. Qwen MLX transient peak4.637GB differs from0.965GB peak RSS and does not establish a leak. Diagnostic budgets use observed pinned prepared roots plus explicit allowance; production4GiB reserve and diagnostic1.5GiB live stop remain. All13 runner controls pass; latest muted actual source contract passes. Existing104 voice-cache files, three voice choices and installed809 executable remain unchanged. VOICE-TURN-DETECTION review retains30 varied same-cohort warm requests plus actual selected-ASR/AEC/EOU, interruption, quality/language and physical negative controls before promotion; decoder load alone is narrower evidence. Public benchmark records disclose incomplete acoustic scope, alongside the earlier five-model generated-PCM measurements.


22 October owner-confirmed quiet TTS continuation: [fresh native-clock attempts](Tests/Reports/tts-2026-10-22/README.md) retain Pocket30/30 warm qualified arrivals, median310.080ms/p95466.196ms, separately from first-after-preparation. Apple29/30, Kokoro18/30 and Phonon19/30 retain acoustic refusals with no survivor medians; Qwen crosses the unchanged1.5GiB live disk floor before a completed request. All use the same diagnostic binary, native48k route and frozen detector with paced native v3 decoder load; the resumed provider windows are explicit, not selected-ASR/AEC/EOU acceptance. Quiet declaration is not proof of uncontaminated baselines; no acoustic failure is labelled a model-quality defect. Owned symbols compress424.1→98.6MB with exact hash verification; original refusal cells remain. All eight TTS attempt roots and three reference snapshots are cleaned after result persistence/join,104 voice files/three preferences/installed809 are unchanged, final available4.076GB. Five-model ranking, actual full conversation, physical negatives and quality gates remain open, Pocket/Alba default unchanged. New public quiet records supplement earlier evidence.


Voice turn candidate, 23 October 2026: native Silero32ms + Smart Turn v3.2
source is implemented behind an explicit opt-in, not installed or promoted. Final
optimized application build passes1060.07s, final authored policy controls and
21 offline scorer controls pass. Native production21-trial paced replay fails:
15/15 trials with400–1500ms protected pauses commit prematurely and again later;
nine exact final-tail checks fail. Three complete-question endpoints occur
304–362ms after authored speech end, but wording fails, so this is not usable
answer or900ms audible acceptance. Native CoreML completed-question prediction
median2.50ms/p954.20ms over30 repeated calls is a graph boundary, not independent
accuracy or total response time. Seven paced Silero onset observations93–126ms
are not physical duck or zero-preroll cold proof. Independent pinned upstream
ONNX matches all13 CoreML decisions (max probability delta0.00150), including
six unfinished-prefix failures; no threshold/text-shape workaround or rollout
promotion follows. All children join before own-artifact cleanup;25 owner
store/settings and143 meeting files remain byte/mtime/hash-identical across
native runs, including the separately owner-selected Phonon choice. Read
[implementation evidence](Tests/Reports/voice-turn-2026-10-23/README.md) for exact
source/binary/model/fixture pins, original failures, resource refusal/recovery,
ASR/TTS alignment and remaining physical/provider/pressure/soak gates.
