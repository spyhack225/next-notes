# Meeting resource attribution — 2026-10-01

Scope: MR-01 and MR-03a. Generated audio only; no owner meeting content, paths,
calendar data or raw logs are reproduced here. No owner app was killed, no
recording was made, no model was downloaded and no owner store was seeded.

## Confirmed incident and attribution limits

The incident had APFS ENOSPC, shared delivery drops and explicit OS low-swap
termination. The retained metrics showed a **process-lifetime** RSS high-water
mark of 2,010,857,472 bytes; this neither measures the meeting-only peak nor
attributes system-wide swap exhaustion to a particular app allocation. Local
model file bytes are disk cost, not native resident weights/Metal/CoreML bytes.

The measured installed file total and incident audio are already characterized
in the roadmap. Approximate full stereo recording cost is 64,000 bytes/second,
230,400,000 bytes/hour. The incident's 261.3 seconds would be approximately
16,723,200 bytes of PCM, plus its container overhead. That does not explain
gigabytes of system paging by itself.

## Allocation chain and numeric bounds

These are source-derived **payload** bounds, not a promised minimum-hardware app
footprint. Actual retained capacity is separately measured by the new producer
snapshots; allocator overhead, packet descriptors, conversion scratch and native
model memory remain outside these formulas.

| Producer | Bound/cost at current settings |
| --- | --- |
| Hardware tap | Borrowed storage copied once before returning; requested microphone tap size 2,048 native frames; actual packet size may differ |
| Optional sink ring | 32 slots × 4,096 frames × native channel count × bytes/sample; 524,288 bytes at mono Float32, twice that for stereo |
| Meeting microphone delivery worker | 256 accepted native packets; at 2,048 mono Float32 frames, 2,097,152 bytes; packet-count limit alone is not a universal byte bound |
| Microphone/system conversion | Native owned packet plus converted mono Float32 packet; output capacity `ceil(inputFrames * 16000 / nativeRate) + 64` |
| Session packet streams | 1,024 mono Float32 packets **per track**. At 2,048 native frames/44.1kHz, nominal converted payload is about 3.04 MB per stream; variable system packets require observed sizes |
| Live ASR waiting queue | 300 × 16,000 × 4 = 19,200,000 bytes per track; 38,400,000 bytes for both logical queues |
| Live ASR forming window | 2–5 seconds; maximum ordinary cut payload 320,000 bytes, plus the incoming packet during append |
| Active merged model input | Up to 15 × 16,000 × 4 = 960,000 bytes per ordinary live track batch; still retained while the native call awaits, even if result ownership is invalidated |
| Writer unmatched lead | 5 × 16,000 × 4 = 320,000 logical bytes after an ordinary append; incoming large packet/padding can temporarily exceed this |
| Writer native chunk | Up to 30 × 16,000 × 2 × 4 = 3,840,000 bytes Float32 PCM; 16-bit stereo disk output is half this |
| Saved audio | 16kHz × 2 channels × 2 bytes = 64,000 bytes/second; not held as one whole meeting array during capture |

The source-derived sum is useful for distinguishing tens of MB of bounded
live audio from unknown native model allocations. It is **not** a measured
whole-process ceiling: streams and upstream buffers have packet-count limits,
native packet sizes vary, array capacities can exceed logical counts, and other
app features overlap. Full physical capture and long-running native overlap
remain required before publishing a supported-hardware operating envelope.

## Measured and rejected candidate

`MeetingAudioWriter.alignedSamples` appeared to copy every packet with
`Array(samples.dropFirst(0))`. A Swift storage-identity probe using a 1,600-sample
Float32 packet showed **equal base addresses** for the input and zero-overlap
result. Swift shares that storage. Nonzero trimming uses different storage,
which is necessary to discard overwritten frames. No zero-overlap optimization
is credited or shipped: replacing this operation with an explicit early return
does not demonstrate an allocation reduction.

## Confirmed producer failure and measured repair

At the first rejected writer chunk, the original producer latched failure and
refused all future packets, but retained unmatched audio arrays that could never
be saved. The fixture feeds six seconds of microphone-only audio to the actual
writer, rejects its first synchronous file write with ENOSPC, then reads the
producer's content-free counters.

| Same fixture | Original failure branch | Repaired producer |
| --- | --- | --- |
| Accepted packet | false | false |
| Written frames | 0 | 0 |
| Retained logical audio | 320,000 bytes | 0 bytes |
| Retained array capacity | 458,688 bytes | 0 bytes |
| `--expect-release` exit | 1 (original assertion fails) | 0 |
| Standalone maximum RSS | 15,040,512 bytes | 15,319,040 bytes |
| Standalone physical footprint peak | 6,078,992 bytes | 6,193,680 bytes |

The measured repair removes **458,688 bytes of abandoned writer capacity** for
this fixture; sampled process peak is dominated by launch/framework overhead and
does not show a lower total process peak. This is a pressure-response repair,
not evidence of reduced normal-operation model memory. The comparison compiles
the identical producer/fixture with only the two queue-release lines removed
for the original branch. Instrumentation and the synchronous external-write
injection are identical in both variants. `WriterAllocationProbe.swift` is the
standalone compiler fixture; the integrated `--selftest-meeting-resources` adds
channel readback, a one-shot callback, and rejection of later packets.

## Successful write versus visible audio at Stop

The installed held-write fixture found a separate producer contract failure:
`finish()` flushed its pairing queues but retained the open `AVAudioFile`.
Core Audio had accepted 96,000 frames, while a fresh final-pass reader saw only
94,208. This was a real six-second recording made from generated samples, with
the first synchronous write held and then released. The writer actor remained
strongly referenced while readback ran, matching the handoff to a final pass.

| Identical standalone fixture | Before deterministic close | After deterministic close |
| --- | --- | --- |
| Producer accepted frames | 96,000 | 96,000 |
| Fresh file-reader frames | 94,208 | 96,000 |
| Exact six-second sample coverage assertion | exit 1 | exit 0 |

The responsible producer now releases its file in `finish()` before returning,
rejects later appends, and makes repeated finish harmless. This finalizes the
converted tail before the consumer reads it. Successful live-write counters
remain API acceptance facts: they do not promise fsync or power-loss durability.
The resource fixture retains the exact 96,000-frame reader assertion.

## Saved originals and transcript replacement

An independently delayed track can arrive behind the writer's bounded pairing
cursor. `alignedSamples` deliberately trims those originals instead of moving
speech to the wrong timestamp. In the generated ten-second fixture, one fully
trimmed second followed by two partially trimmed seconds produces 48,000 missing
system originals: the actual final-pass reader has silence over seconds 1–4,
while all microphone originals and subsequent system samples retain their values.
File length alone still reports ten seconds.

The first missing contract was the producer's failure to export that source loss.
It now publishes cumulative, saturating `missingSavedMicFrames` and
`missingSavedSystemFrames` in the same bounded progress snapshot, including after
finish. Recovery admission derives from those facts and cannot regain authority
after later successful packets. Consumer integration must preserve these facts
in the existing meeting integrity record and refuse final transcript replacement
for the affected source. The existing 60% word-count heuristic alone cannot
prove sample coverage; partial saved audio can pass it while omitting live speech.
The signed integrity fixture now exercises the real final-pass consumer: the
damaged system candidate passes the old word-count threshold but must preserve
the live system transcript, while the complete microphone candidate improves.
Disabling the producer repair and track-coverage gates produced ten failures;
restoring them passed the signed `MEETING_INTEGRITY_OK: 69 checks` flag, including
rendered interruption projections after a separate temporary-path validator
repair. Writer readback alone would not establish this consumer behavior.

## Storage query cost and policy implications

200 fresh-URL `volumeAvailableCapacityForImportantUsage` calls on this Mac:

- p50: 11.26 ms; p95: 82.42 ms; maximum: 502.24 ms; no missing answers.
- Latest reported important-use capacity: 774,279,168 bytes.
- Actual available filesystem blocks immediately afterward: 192,764 KiB
  (197,390,336 bytes).
- A standalone linker encountered real errno 28 ENOSPC, then succeeded on a
  small retry. No storage was intentionally exhausted by the fixture.

Important-use capacity includes reclaimable space and is not a guarantee that
the next write can obtain it immediately. A storage query must run away from
capture callbacks and MainActor. The implemented five-second sample incurs approximately
0.32 MB incremental stereo PCM between observations; this explains the recording
reaction cost, **not** a guaranteed system paging reserve. Unknown capacity must
stay unknown. Thresholds cannot promise immunity to OS low-swap termination.

## Start-time keep choice

Production `MeetingSession.start` reads `meetingsKeepAudio` once into `keep`.
The same value participates in `shouldWriteAudio`, sets `audioIsTemporary = !keep`
when writer construction succeeds, and is saved before capture starts. Final
pass/diarization also request temporary full audio. Later global toggles do not
rewrite that meeting snapshot. A saved temporary incident row therefore conflicts
with the recalled start-time intent; current settings cannot settle which value
was present at start. No producer mismatch has been reproduced. The policy
matrix is pinned without silently changing settings or incident metadata.

## Remaining evidence

`--selftest-meeting-resources` streams generated two-hour input through actual
windowing, records logical/capacity plateaus, and checks ordered sample coverage
at the model seam. It also drives a held model across pressure and resume,
requiring one native owner, fenced stale output and correct resumed timestamps.
These are deterministic production-path facts; they do not measure ASR accuracy
or survival under physical low swap.

`--selftest-meeting-resources-live` is an explicit isolated native diagnostic:
writer-only → ASR cold load → first/steady inference → the former speculative
notes load → notes inference → actual pressure-guardian unload. It samples total
process physical footprint every 20 ms and reports CPU, RSS, two task wakeup
counter deltas, and runtime-registry state without transcript text. Each ASR
track must complete real native calls; swallowed model errors fail this probe.
The injected warning runs the shared release producer, requires actual notes
teardown within five seconds and denied optional reload, and keeps ASR loaded.
It creates no OS memory pressure and restores admission only after observing
native teardown. Physical-footprint deltas are process observations, not a
model-specific Metal/CoreML attribution.
It refuses unknown/<8 GB capacity before native loads, absent installed models
or ongoing pressure; no automatic download or cloud fallback. That safeguard
prevented the initial native run when immediately available capacity was below
1 GB. A later read-only capacity check found about 25 GiB available; the disk
guard no longer blocks a coordinated run. The first native result is recorded
below. Native/device allocation breakdown, per-model fixed floor, representative
notes latency and physical capture/interactive overlap remain open.
MR-03 pressure policy and the rejected
copy hypothesis do not complete MR-03a's normal-efficiency acceptance.


## First actual native measurement (16 GB Mac)

Signed diagnostic bundle completed `MEETING_RESOURCES_LIVE_OK` on Apple M3,
16 GiB RAM, macOS 27.2 build 26B5091g. Installed Parakeet v3 used CPU/Neural
Engine; local GGUF file was 1,561,318,368 bytes. No download or private audio.
The input was the same generated 20-second, two-track tone for each audio stage.
This is a short controlled diagnostic, not a realistic speech/long-meeting run.
All values below are decimal MB, and footprint is total process accounting.
The 20 ms sampler contributes to reported CPU/wakeups; these counters are
whole-diagnostic totals, not isolated engine costs. The test ran in signed staged
bundle `install-9867`, with only integrity regression guards disabled for the
before-proof experiment; resource/runtime producers were the measured versions.
An exact model digest/configured-role provenance still needs recording before a
model-specific envelope claim.

| Stage | Wall s | CPU s | Footprint after MB | Sampled footprint peak MB | RSS after MB | Interrupt / idle wakeups |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Writer only | 0.026 | 0.015 | 125.37 | 125.40 | 161.94 | 6 / 0 |
| ASR cold load | 59.716 | 3.019 | 98.68 | 180.77 | 112.67 | 1746 / 8 |
| ASR first inference | 11.776 | 1.483 | 110.71 | 110.74 | 142.18 | 44 / 0 |
| ASR next inference | 10.821 | 1.386 | 112.40 | 115.61 | 127.68 | 34 / 0 |
| Optional local notes load | 150.778 | 3.641 | 151.39 | 162.73 | 773.37 | 1528 / 0 |
| Notes first inference | 14.574 | 1.868 | 271.58 | 283.89 | 465.81 | 139 / 1 |
| Injected warning / native release | 0.248 | 0.058 | 181.19 | 271.58 | 100.71 | 1 / 0 |

The real guardian released the native notes owner in **219 ms**, denied an
optional reload during warning, and retained the actual loaded speech owner.
Process footprint fell **90,391,728 bytes** across that stage. It also released
existing optional embedding/vector caches, so that total delta is not a precise
per-model allocation. This is injected policy plus actual native effect, not an
OS exhaustion survival result.

The optional load increased footprint by **38,995,144 bytes** but RSS by much
more; clean mapped weights and device/service allocation cannot be inferred from
one process RSS. These results do not explain the incident's lifetime 1.87 GiB
peak or establish a supported total ceiling. The cold notes load took 150.8 s:
removing startup prewarm moves a possible cold cost to notes generation, and a
representative latency comparison remains required.

A diagnostic inconsistency was exposed: `ParakeetModels.isLoaded` was true and
real native calls completed, while the runtime registry still said unloaded.
Direct meeting/batch loads bypass the dictation engine's registry transitions.
The next diagnostic logs actual owner booleans beside registry state; registry
state alone must not establish loaded-model attribution. Native/device allocation
breakdown, equal-build normal-meeting before/after, longer growth and physical
capture/Agent/voice overlap remain open.

## Model verification and independent live refinement

The targeted comparison exposed a model-verification peak before any native model
loaded. The exact prior hashing producer retained autoreleased Foundation chunks;
the repaired per-chunk pool reduced the selected model's standalone physical-
footprint peak from 1,570,473,448 to 7,586,224 bytes with the identical digest.
Twelve focused contracts and the signed actual model-library consumer pass. See
[the verification report](2026-10-01-model-verification-memory.md). This does not
attribute the historical meeting's lifetime resident-memory peak.

The first signed normal-comparison attempt failed its strict owner-store guard;
the changed key/file detail was unavailable in that version. It remains failed,
and the unused second arm supplies no evidence. Subsequent diagnostics retain the
same guard and report bounded key/basename differences at stage boundaries.

A fixed-hashing comparison with live understanding left at its local automatic
setting exposed a separate real workload: the generated recording emitted two
`meeting.reconcile` usage rows. That background context producer loaded the shared
local language model during capture (8.194 s load), even without startup prewarm.
Its recorded process peak RSS reached 1,911,439,360 bytes; the later recorded
physical footprint was 246,270,376 bytes. These different measures cannot identify
native/device allocations or establish incident-time residency. Streaming speech
does not eliminate this independent language-model work.

The removed arm consequently failed its no-notes-load invariant, so that pair is
not accepted as an isolated prewarm comparison. The next pair explicitly sets
the existing live-understanding preference to false in **both disposable harness
arms**, restores it afterward, and logs that configuration. Product settings and
automatic live refinement remain intact; representative feature-overlap acceptance
is separate. This trace also exposed an optional-refinement pressure-admission
bypass. The [responsible producer repair](2026-10-01-live-refinement-pressure.md)
passes all 46 new checks and existing grounding; original routing fails 23 checks.

The isolated former arm in `install-23179` aborted its resource guard after 118 s.
Its metrics independently record an actual, uninjected pressure teardown of notes
in 116 ms. This is a real observer/release effect during generated capture, not
an accepted normal-condition comparison or an OS-exhaustion survival result.

The final attempt (`install-25062`) uses the fully regression-verified runtime,
same generated fixtures/model hashes and explicit live understanding off. ASR
fresh-process loading takes 17.101 s/1.754 CPU s with sampled physical-footprint
peak 142,427,576 B. Generated capture takes 182.854 s/18.258 CPU s; sampled peak
footprint is 178,964,808 B, after footprint 174,737,736 B, with 9,867 interrupt
and 40 idle wakeups. Fresh channel readback confirms exactly 2,908,098 frames
per track and zero missing saved originals. These are measurements of that arm,
including replay/sampler overhead and filesystem warmed by identity reads.

The stage guard then rejects changes in owner audit/conversation/metrics files.
Abort diagnostics report normal pressure (generation zero), 8,301,473,792 B
immediate capacity and no cancellation. The failed exit is retained, and the
removed arm is not run. No paired reduction, steady-state ceiling, native device
allocation or post-Stop notes-latency comparison is credited from this attempt.


## Resumed native acceptance

The [resumed acceptance report](2026-10-01-resumed-acceptance.md) records a clean
former-prewarm arm with all saved frames, real native inference and unchanged
owner stores. Its steady process footprint is 151,816,520 bytes. The paired
removed arm fails on actual warning pressure; a reverse-order retry fails when
immediate capacity falls below 8 GB. Reclaiming three obsolete staged test copies
restores disk headroom, but a 60-second preflight still observes warning pressure
and launches no further native test. No paired reduction or full native-allocation
envelope is credited. Short physical microphone/system-tap checks now pass;
representative long physical overlap and visible warnings remain open.
