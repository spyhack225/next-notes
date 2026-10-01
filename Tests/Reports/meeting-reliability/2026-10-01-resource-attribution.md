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
Until the real final-pass consumer regression passes, this product risk remains
open; writer readback by itself does not prove its resolution.

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
capture callbacks and MainActor. A 30-second lifecycle sample incurs approximately
1.92 MB incremental stereo PCM between observations; this explains the recording
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
notes load → notes inference → safe unload. It samples physical footprint every
20 ms and reports CPU, RSS and runtime-registry state without transcript text.
It refuses unknown/<8 GB capacity before native loads, absent installed models
or ongoing pressure; no automatic download or cloud fallback. That safeguard
prevented the initial native run when immediately available capacity was below
1 GB. A later read-only capacity check found about 25 GiB available; the disk
guard no longer blocks a coordinated run. No native run has been performed by
this diagnostic yet. Native/device allocation
breakdown, per-model fixed floor, CPU/wakeups, real notes latency and physical
capture/interactive overlap remain open. MR-03 pressure policy and the rejected
copy hypothesis do not complete MR-03a's normal-efficiency acceptance.
