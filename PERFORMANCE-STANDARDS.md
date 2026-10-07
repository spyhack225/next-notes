# Performance standards

Owner-requested shared reference, 7 October 2026. Read this before changing capture,
ASR, models, scheduling, meeting processing, dictation, voice, rendering or indexing.
This document collects the existing owner requirements and the measured lessons;
it does not declare unverified targets achieved or introduce a product scheduler.

## Reference machine and acceptance

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
