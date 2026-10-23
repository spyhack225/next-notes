# Native TTS integration and serial first-audio comparison

22 October 2026. **Five native comparisons completed.** Qwen3-TTS and Phonon generate audio and
pass muted playback through the production source/renderer. The optimized app links, its headless
source regression passes, and the serial runner saves each result, joins its process and deletes its
owned model before the next starts. No app was installed or default changed.

## Measured results

Same English text: “I found three matching files. The latest is enclosure version seventeen.”
Apple M3, 16 GB RAM, macOS 27.2 (26B5091g). Release `-O`, non-WMO batch compilation, two build workers.
Normal owner apps were retained; no other benchmark/model/build overlapped these timed trials.
Inherited swap pressure was present. This does **not** qualify the ASR-plus-voice reference workload.

| Engine | First synthesis after preparation | Warm median, 5 runs | Preparation, including download/load | Accepted raw result |
|---|---:|---:|---:|---|
| Phonon 31m English, Core ML v0.4.0 | 8.32 ms | **7.80 ms** | 7.00 s | [Phonon](native-results/phonon.json) |
| Qwen3-TTS 0.6B CustomVoice 4-bit, Ryan | 3,093.75 ms | **2,709.30 ms** | 17.68 s | [Qwen](native-qwen-headroom/qwen.json) |
| Apple system-default voice | 1,039.27 ms | **8.98 ms** | 0.001 s | [Apple](native-results/apple.json) |
| Pocket INT8, Alba | 1,096.68 ms | **59.00 ms** | 5.70 s | [Pocket](native-results/pocket.json) |
| Kokoro Core ML 82M, Heart | 904.19 ms | **224.11 ms** | 8.55 s | [Kokoro](native-retry/kokoro.json) |

The boundary is **known text request → first non-empty generated PCM**, not audible speaker output,
speech-end→answer, EOU/ASR or full-duplex latency. Phonon and Pocket stream. Kokoro and the current
Qwen adapter return whole clauses; Qwen's first PCM therefore includes full-clause generation.
Apple reuses one prepared synthesizer across trials. The first column is not a hardware-cold test.
Warm trials repeat the same text back-to-back and can differ from human-paced use; earlier failed
Qwen preparation may have warmed OS/GPU caches. No model/default promotion follows these numbers.

[Accepted comparison](accepted-results.json) links the selected runs. Each raw result retains all six
trials, completion time, audio frames/duration, preparation, model identity and process peak RSS.
RSS is not Mach physical footprint; Apple/Core ML host services are not included in the child's RSS.
Power/thermal metadata is a snapshot, not a continuous trace during timing. See
[environment](resume-environment.json), [binary and Metal resource pins](native-binary.json),
[complete app source pins](source-pins.json) and [verification](verification.json).

## Integration and producer repair

Settings selection/download progress, conversation output and long-form narration use the new native
runtimes through the existing `PocketSourceSpeechBacking` and single `AgentPCMRenderer`. They reuse
output tokens, cancellation and the reverse acoustic reference. No microphone path, playback ledger,
queue, extra model pass or conversational gate was added. Startup prepares only an installed selected
voice; no unselected new voice is fetched. Already-installed Qwen files do not require another download's
free-space reserve. Ordinary downloads retain the existing 4 GiB reserve.

Qwen files are pinned to revision `08c72cad5e2fd0f41730c8bd1f28149585e46361`, individual sizes and
SHA-256, totalling 1,693,602,151 bytes. Phonon's public English 31m archive is pinned to v0.4.0,
137,096,081 bytes and SHA-256. Its writable extracted bundle is moved into place instead of making the
SDK installer's extra full copy. No gated Phonon 40m weights are used.

The native output regression exposed two producer faults:

1. The source accepted a listening pause before its first PCM, but the renderer had no matching token
   yet and ignored the pause. Enqueue now publishes the pending pause before publishing the token.
2. The renderer's two-second write deadline counted deliberate paused wall time. It now counts active
   unpaused IO time with a monotonic clock; the two-second budget itself is unchanged.

The identical authored 16-second PCM case fails original, fails with only the initial-pause repair,
and passes with both repairs. [Original](source-original.log), [pause-only](source-pause-only.log),
[fixed](source-fixed.log), [same-body/source pins](fixed-component-pins.json). The focused fixture compiles
the real source, renderer, rings and conversion with native Core Audio output; only the DSP sink and
unreachable default Pocket/settings branch are substituted. The complete app then runs the same
`--selftest-tts-source` case successfully with its real dependencies: [full-app result](source-full-app.log).
Both real new-provider runs additionally pass muted pause-before-PCM, resume, first-render receipt and
native drain after their timing trials. No microphone is opened by these checks.

Qwen's public SDK stream does not expose a join for its hidden mutable producer. The adapter uses the
joined whole-clause generation task; cancellation stops output immediately and a busy decoder follows
the existing Apple fallback. Low-latency Qwen streaming remains a separate contract.

## One model at a time and preservation

The runner creates one marked temporary root and one engine process, checks headroom, prepares and
measures, durably saves JSON, joins the process/helpers, removes the root, verifies absence, and only
then returns to start a successor. Failures/timeouts also save before deletion. A save failure retains
that one root and stops the whole comparison. An abrupt parent kill/power loss cannot guarantee cleanup.
The child's TMPDIR is inside its root, covering transient downloads/helpers. No audio files are retained.

Compatible Pocket/Kokoro owner caches are reused through APFS copy-on-write snapshots (`cp -cRL`).
Only the snapshot may be changed by model variant repair. Kokoro requires its existing shared G2P files
rather than fetching outside the owned lifetime. All **104 existing cache files are unchanged by SHA-256
and count**: [preservation witness](owner-cache-preservation.json). No benchmark model root remains:
[final cleanup](final-model-cleanup.json). OS-managed compiled/runtime caches are not swept.

Diagnostic admission keeps 2 GiB plus an engine estimate and independently stops its owned process
group below 1.5 GiB actual free disk. Ordinary app downloads retain 4 GiB. The run explicitly admitted
up to 12 GiB pre-existing swap; this is recorded in each preflight and is not a production policy.
No capture/voice turn waits for this development coordination.

## Actual failures and retries, retained

- Original SwiftBuild planning collided on PhononCore/NemoTextProcessing module maps. Native SwiftPM
  compiles both; Makefile build/test and macOS CI use that backend. Original `native-build.log` is retained.
- The earlier full build failed an inherited benchmark-settings Section/footer overload, narrowly repaired.
  A later attempt caught the benchmark's live runtime reference mistakenly placed in its Codable report;
  that source error is corrected. [Failed full build](native-build-resume.log.gz).
- The combined 891-file module typecheck passes, and the optimized full app links:
  [typecheck](native-typecheck.log), [build](native-build-combined.log.gz),
  [build command/exit](native-build-result.json). Full-app source check passes. The peer's isolated
  Google/stream/clock checks also pass at root; its inherited nested production-tool-loop failure remains
  explicitly outside this TTS acceptance (see the archive integration report).
- Qwen and Kokoro were initially refused before downloads by per-engine disk admission. Useful task-owned
  app object/dependency/diagnostic outputs were retired after successful link; binary, modules and SDKs
  remain. [Exact retirement](retired-app-build-artifacts.json) records 211,435,520 allocated bytes unlinked
  and an observed free-space increase of 212,725,760 bytes; the latter is not a unique attribution.
- Raw SwiftPM linking removed the manually prepared Cmlx bundle. Qwen's guard refused **before weights**.
  The normal Makefile already runs the Metal helper after build; the diagnostic build recipe now does too.
  The exact publisher MLX 0.32.3 archive is verified, its 2,352,104-byte macOS library retained and its
  212,871,838-byte temporary archive deleted. [Post-link packaging](metal-packaging-after-link.log).
- A subsequent Qwen load at 4,153,139,200 free bytes was stopped when actual disk fell below 1.5 GiB.
  Its failed result was saved and 1,698,364,895 logical temporary bytes were deleted after process join:
  [pressure failure](native-qwen/qwen.json). Swap grew; the allocating producer is **unconfirmed**.
  A cache-retention hypothesis was not treated as a diagnosis or patched without evidence.
- After headroom recovered to about 5 GiB, Qwen succeeded with the **unchanged native executable and
  unchanged guards**. This is a different-resource retry, not an original/fixed memory claim. Its model
  was removed before finishing. No simultaneous model downloads or model processes occurred.

## Checks, lifecycle and remaining acceptance

Eight runner tests pass (seven fake-child lifecycle cases plus the tiny actual macOS APFS preservation
check): serial lifetime, save-before-delete, owner preservation, timeout, active low-disk stop, refusal,
save-failure retention and child TMPDIR routing. [Test output](runner-tests-resume.log).

Source checkpoint `16020462` preserves the six reviewed producer/benchmark changes on main. No push,
install, branch or worktree was created. Temporary native probe binaries were deleted. Completed verbose
logs are compressed, saving 23,017,387 bytes; compact source/model/binary pins and all real verdicts remain.
The current useful executable, dependency checkouts/SDK objects, modules and 2.2 MB Metal library remain.
No recordings, personal files, owner model caches or unrelated processes were removed.

Physical-device route changes, rapid real-room barge-in, actual first audible output, settings/preview
clicks, narration UI, linguistic quality and full-duplex ASR-plus-voice reference acceptance remain open.
The new native generation/playback and scoped TTFA comparison are verified; broader release readiness
and model/default promotion are not claimed. The older independent Apple/Piper probe remains intact.


## Speaker-start follow-up (source prepared, native measurements pending)

The owner's next request adds five-choice speed/space comparison in Models Settings,
links to the same public benchmark page, and a separate `--tts-speaker-output` mode in
`Tools/tts_compare.py`. Component records have been privacy-reviewed for publication.
The fastest speaker default is deliberately undecided until actual qualified evidence;
existing saved voice selections and the current fallback remain unchanged.

The new observer reads the existing AudioCaptureHub raw subscription and actual rendered
reference; it opens no second microphone or AEC pipeline and saves no microphone recording.
It retains at most 8,000 timestamped 10 ms energy windows per stream/trial. Capture begins
before synthesis; a 700 ms quiet baseline precedes each varied phrase. Actual production
Apple/Pocket/Kokoro playback backings and the existing injected native source backing are
used with the single already-loaded temporary model. Pocket's native reply session is
included, rather than re-labelling its earlier one-shot generation result as playback.

The report separates first post-gain non-silent rendered sample (absolute threshold 0.001),
its native host timestamp, output graph/epoch or renderer token, the output-node maximum
presentation-latency estimate, and microphone pickup. Presentation is an estimate, never
an acoustic receipt. Pickup requires a matching rendered/microphone envelope (correlation
>=0.75 over up to 1.5 s), room RMS <0.01, >=300 ms baseline, onset >max(0.001 RMS, 4x
baseline), consistent input/output device IDs, timestamps and no capture overflow. Missing
qualification remains null/partial and cannot supply an audible median or default winner.
Detection is threshold-dependent at 10 ms energy resolution, not human perceptual onset.
One prepared trial plus 30 varied paced warm trials/model are planned. Each model is saved,
joined and deleted before the next; native runs must wait for the combined build window.

Focused validation before combined compilation: the exact observer compiles under Swift 6;
authored correlated 80 ms pickup controls pass, silence supplies no rendered/acoustic start,
and overflow invalidates a previously qualified observation. Ten actual child-process runner
regressions pass, including qualified pickup, absent acoustic data, save-before-delete,
timeout/low-disk cleanup and owner-model preservation. These controls are not physical data.

Reviewed alignment: [voice-turn detection handoff](../../../roadmap/in-progress/VOICE-TURN-DETECTION/04-TTS-AUDIBLE-ALIGNMENT.md).
Full-turn ASR/EOU, normal concurrent ASR workload, double-talk, language/voice quality,
physical-route matrix and fastest-default qualification remain separate open contracts.


The observer's maximum-latency regression was reproduced before collection: the original
`fa8f72be` source rejects authored microphone pickup 80 ms after render when the reported
maximum presentation latency is 300 ms (correlation 0.219). The producer incorrectly used
that maximum estimate as the acoustic search origin. The repair searches from native
render time and retains the estimate only as a separate reported boundary. The unchanged
external fixture now passes (correlation 1.0, pickup within 10 ms of 280 ms after request,
estimated presentation still 500 ms). Silence/overflow controls also pass. This exact
80/300 ms separation is now in the actual full-app source self-test's observer control.
Original/fixed source and fixture SHA pins/logs are retained in
`output-maximum-latency-{original,fixed}.json`; the shared build was deliberately held
before app compilation while correcting this diagnostic producer.


### Signed physical calibration (before model comparison)

The signed 0.2.24 diagnostic candidate (`32a35bfcf9220dbdc87734466ccd63b9df1dc0a5e2488d1541b7e08a4207c8ed`)
passed the microphone-authorization guard and two Apple output trials on built-in input/output
route IDs 90/83. First-after-preparation microphone pickup was 1246.55 ms; the next varied
phrase was 299.17 ms. Render timestamps were 1170.60/207.93 ms and the separate downstream
maximum presentation estimates 1172.14/209.47 ms. Matched envelope correlations were
0.923/0.928 and quiet-room RMS 0.000877/0.000812. These are threshold-dependent microphone
observations, not an output-latency subtraction or human perceptual-onset measurement.

This calibration has only **one warm sample and no concurrent ASR load**. It proves the
collector works on the physical route; it does not rank models, supply a tail percentile,
qualify a fastest default, or replace the planned 30-sample concurrent-ASR comparison.
`speaker-calibration/apple.json` retains both samples and `summary.json` the exact binary
hash. Its child exited and the result was saved before verified temporary-root deletion;
no model was downloaded. The machine claim was handed directly back to the ASR agent.
The owner still has Pocket/Alba selected; the Apple voice identifier is unset. No preference
was changed by these diagnostics.

For the comparison, the diagnostic-only `Tools/tts_asr_workload.py` reuses the existing
native Parakeet v3 RPC worker and paced authored-English harness, with an owned APFS snapshot
of installed weights. It downloads no recognizer. The TTS parent checks its active worker
before/through/after each child; a stopped workload invalidates timing and prevents the next
model. Twelve TTS lifecycle tests and a real fake-RPC-worker stop/join/cleanup test pass.
The reference worker declares concurrent decoder load; it does not establish the production
microphone/AEC/EOU/turn path or recognition accuracy under physical overlap. Ephemeral health
markers replace atomically without fsync; results/receipts retain durable save-before-delete.


### Physical output follow-up and collector repair (22 October, continuing)

The original signed809 physical attempt under paced cached Parakeet-v3 decoder load is retained in
`speaker-results/`: Apple completed30/30 warm trials (median170.940ms, empirical p95272.869ms).
Phonon was0/31 qualified; Pocket/Kokoro/Qwen were disk-admission skips. These are not a complete
five-engine physical ranking. Both processes joined; each owned TTS root and ASR snapshot was removed.
Existing104 voice cache hashes were pinned before the attempt. Decoder load is not production
microphone/AEC/EOU/endpoint qualification.

Precise diagnostic reproduction (`speaker-phonon-diagnostic3/`) confirms a collector error:
Phonon’s first faint rendered sample preceded the microphone’s fixed threshold crossing by more than
the detector’s arbitrary80ms search window. Correlation was strong, baseline quiet, route stable,
timestamps present, and microphone peak exceeded threshold. The repaired producer searches the
correlation-aligned utterance for the first two consecutive10ms microphone windows above
max(.001RMS,4x baseline), with simultaneous voiced reference. Thresholds/correlation are retained;
the persistence criterion is explicit. This is threshold-qualified arrival, not human perception.
The same authored soft-lead control fails the original collector and passes the repair; existing
maximum-presentation, silent and overflow controls still pass. Timestamp regression is rejected
rather than entering ordered lookup or unsigned timestamp arithmetic. The subsequent Apple process
exit-5 is retained; its actual termination cause is not established by this arithmetic control.

`speaker-results-fixed/` retains the second, incomplete attempt: Qwen hit the existing1.5GiB live
disk stop before a result; its process group was joined and owned model deleted. Three models were
refused at admission. Apple later exited-5 without a saved native report. No physical medians from
this attempt are accepted and no default changed. Free space recovered after workload shutdown;
no user files, shared caches, swap files or another agent’s retained artifacts were deleted.

The diagnostic app is an owned APFS clone of installed809 with ABI-equal targeted app-primary
repairs, original SDK objects and portable resource getters; package rpath/signature are restored
before execution. Two earlier diagnostic packaging failures (missing framework rpath) are retained
in `speaker-phonon-diagnostic{,2}/`; no model loaded. They are not provider failures.
Qwen benchmark-only stderr now records MLX memory snapshots around loading and each clause to
investigate pressure before claiming any allocator fix. Production allocator settings are unchanged.

The VOICE-TURN-DETECTION agent reviewed current source/evidence through agent-relay (message
f823d51e-3466-41bd-9c65-62472de16848). Its existing `04-TTS-AUDIBLE-ALIGNMENT.md` remains the
contract: preserve original failed cells, one repaired same-binary cohort,30 varied warm trials,
clear boundaries/percent denominators, quality and actual selected-ASR/AEC/EOU/interruption checks
before default promotion. English-only model quality and physical double-talk remain open.


### Native microphone-clock boundary

The continuous16k observer run was deliberately stopped once its precise diagnostics established
repeated **regressed microphone host** windows under paced ASR load. Both parent and native ASR
joined, the failed result/log was saved, and the owned TTS/ASR roots were deleted. No later model
started. It did not justify accepting earlier rejected pickups. Continuous capture alone did not
repair the clock boundary; the no-ASR calibration's4/4 pass is a smaller claim.

The observer now requests the hub's native hardware format (48000Hz, mono, noninterleaved Float32)
through the existing consumer seam; it receives owned copies with the hardware frame's original
host time. A read-only diagnostic format getter is the only hub addition. Capture/converter/ASR
production behavior is unchanged. The old16k consumer attached each input timestamp to resampler
output, which is not the exact boundary requested by this experiment. The underlying converted
sample/host overlap cause remains open; selecting native observation is a measurement correction,
not a claimed ASR/capture repair. Under the same ASR decoder load, native-format Apple calibration
passes4/4, without the clock rejection. The subsequent30-trial cohort is separately retained in
`speaker-native/` with source/binary/probe pins in `speaker-native-source-pins.json`.

The same native-format Qwen diagnostic (`speaker-native-calibration/qwen.json`) completes without
a disk stop: first-after-preparation pickup7632.645ms and one qualifying warm pickup3557.724ms.
Two of three warm requests fail the frozen acoustic threshold/persistence; no warm median or
ranking is accepted. MLX reports1.689GB active after loading,1.723GB active/0.55GB cache after a
clause, and4.637GB transient peak during synthesis, distinct from0.965GB peak resident RSS. Its
allocator's default cache limit is16.32GB, but observed post-clause cache is0.55GB; this does not
prove a leak or establish cache limit as the allocating cause. No allocator settings or output
loudness were changed to make a trial pass. The1.698GB temporary model root was removed after
result persistence and native exit. Pressure can still prevent another admitted run.

Per-model diagnostic disk budgets for existing CoW/precompiled Pocket/Kokoro were refined to
750MB/500MB above the unchanged2GiB reserve, based on observed full roots454MB/107MB and additional
296MB/393MB transient allowance. Their old1.5GB blanket admission skips remain recorded. Phonon
and Qwen budgets and the1.5GiB live process-stop floor are unchanged. Production downloads retain
4GiB reserve. All13 runner/lifecycle/workload controls pass after this refinement.


### Environment admission and baseline diagnostic

The owner confirmed that other sound/audio was playing during these physical runs. Physical
experiments and the concurrent reference ASR were stopped; both joined and all current owned model
roots were deleted. No audible default is chosen from this noisy-room cohort. The owner was asked
whether a quiet10–15minute interval is now available; physical work waits for that condition while
code/report/publication work continues. Earlier Apple171ms (30/30 by the original collector) and
299ms calibration values remain historical exploratory outputs, **not current native-clock
qualification**. The public calibration record is amended topartial/superseded.

The new native48k cohort has zero timestamp failures for Pocket, Kokoro and Apple. Warm acoustic
qualification is27/30,26/30 and28/30 respectively. Rejected requests are retained, not replaced by
survivor-only medians. Phonon and Qwen's later30-request cells were refused at disk admission.
Qwen's separate native3-warm calibration has1/3 qualified; its complete four requests and MLX
snapshots remain available. Generated-PCM medians from the earlier five-model experiment remain
valid for their distinct synthesis boundary.

A baseline-contamination hypothesis was checked without changing grading. `speaker-baseline-diagnostic/`
logs the whole baseline, its most recent500ms, and the number of delivered clock windows predating
probe creation. Recent RMS was as high or higher in the observed failures (for example whole.00681,
recent.00703; another whole.00431,recent.00490). Thus discarding an early prefix would not explain or
repair this noisy-room attempt. No baseline, SNR or persistence threshold was loosened. The authored
`output-baseline-tail-original.json` demonstrates a possible earlier-tail false refusal, but is an
open diagnostic case, not a claimed native producer fix or a maintained passing regression.

Pinned Phonon diagnostic preparation now budgets1GB above the same2GiB reserve: observed compiled
roots323.7MB plus137.1MB archive leave >539MB additional transient allowance. This arithmetic is
not a measured transient high-water trace. The actual free-disk1.5GiB stop stays active; production
retains4GiB reserve plus1.5GB preparation allowance. The original stricter refusals remain in evidence.
Task-owned diagnostic executable copies now use APFS CoW as well as model snapshots, avoiding an
unnecessary second full executable allocation. No unrelated caches, user data or recordings were swept.


### Follow-up handoff and publication

The latest diagnostic executable passes `--selftest-tts-source` (actual muted output graph;
`speaker-source-final.log`), and all13 model-free runner controls pass. No microphone or audible
playback was required for this final source check. `owner-cache-speaker-preservation.json` confirms
all104 existing voice files are unchanged; the three voice preferences and installed809 executable
are also unchanged. `speaker-final-disk-installed.json` records about5.6GiB available at handoff;
free space fluctuates as the OS reclaims pressure. No broad user/cache/swap cleanup was performed.
The useful owned diagnostic app and18MB reference probe are retained for the pending quiet retry;
temporary TTS model roots and ASR snapshots have been deleted by their joined runners.

The five `*-speaker-output` registry records deliberately contain no warm acoustic median. The
comparison page displays complete earlier first-generated-PCM values with their own speed/size
percentage denominators, and explicit incomplete/not-run physical results. This is publication of
partial evidence, not a completed audible ranking. The current source makes the Settings speed
label explicit as “Audio ready”; installed809 already has all five choices, serial preparation and
comparison percentages, but this follow-up label/collector source is not yet installed there.
The owner’s Pocket/Alba default remains pending a valid physical comparison and roadmap acceptance.


### Owner-confirmed quiet interval — fresh thirty-warm attempts

The owner confirmed other playback/sound had stopped. No detector threshold, microphone format,
source gain, native source or hardware volume was changed. All fresh trials use diagnostic binary
`685243da8585e7db92622e53a545e104ef169c95b7bd1181f27352ffa38ba64c`, native48k
observation and the same five rotating authored English phrases.
`speaker-quiet-source-pins.json` retains source/runner hashes and environment scope.

| Voice | Warm requests qualified | Accepted microphone median / p95 | Evidence |
|---|---:|---|---|
| Pocket/Alba |30/30|310.080 /466.196ms|`speaker-quiet/pocket.json`|
| macOS |29/30|None: one onset/SNR refusal|`speaker-quiet/apple.json`|
| Kokoro |18/30|None: acoustic refusals retained|`speaker-quiet-remaining/kokoro.json`|
| Phonon |19/30|None: acoustic refusals retained|`speaker-quiet-phonon/phonon.json`|
| Qwen3-TTS |No completed request|None: live disk guard|`speaker-quiet/qwen.json`|

These are threshold-qualified speaker-to-microphone arrivals, including acoustic and input timing,
not human perceptual onset. Pocket's median/p95 use all30 warm requests, with empirical nearest-rank
p95; the first-after-preparation request is separate. No survivor-only medians are calculated for
other voices. A quiet-room declaration does not prove every baseline was uncontaminated. Acoustic
failures are collector qualification failures, not an established model-quality defect or evidence
that the owner failed to stop other playback. Timestamp regressions are absent in these warm cells.
Whole/recent baseline differences and global matching limitations remain diagnostic questions; no
threshold/window changes or claimed repairs follow from this attempt.

Qwen started first with5.137GB free, then crossed the existing1.5GiB live disk floor during its
first synthesis; the process joined and1.698GB owned model was removed. Its diagnostic MLX log
remains retained, with no completed-clause or acoustic timing claim. Kokoro/Phonon were initially
refused before download. After stopping/joining the reference decoder, task-owned current diagnostic
symbols were compressed from424,129,586 to98,551,585bytes, verified by archive integrity and exact
per-file hashes before removing the uncompressed copy. `speaker-quiet-symbol-compression.json`
records this bounded cleanup; the entire subsequent free-space increase is not attributed to it
because the OS was also reclaiming pressure. Installed/baseline809 symbols were untouched.

The continuation used the same binary/phrases/route/detector and a fresh instance of the same paced
reference decoder; it preserves both initial refusals and later complete request sets. Phonon was
refused once more while Kokoro ran, then admitted after Kokoro and its decoder snapshot exited and
headroom recovered. No model retry was used to replace individual rejected acoustic trials.
The three reference sessions are in `speaker-reference-asr-quiet{,-remaining,-phonon}/`; each
receipt confirms native child joined, snapshot deleted and owner ASR weights unchanged. These are
decoder-load windows, not actual selected-ASR/AEC/endpoint/full-conversation acceptance.

`speaker-quiet-preservation.json` confirms all eight attempt roots cleaned, all three reference
children/snapshots joined/deleted,104 existing voice files and three TTS preferences unchanged,
installed809 SHA unchanged, and4,076,355,584bytes free at the final read (about3.8GiB). The current
useful diagnostic app/reference probe and compact symbols remain retained; no unrelated user data,
models, swap or another agent's artifacts were removed. The requested five-model fastest-audible
ranking remains incomplete. Pocket/Alba stays selected; no default promotion is claimed. The five
new `*-speaker-quiet` records supplement rather than overwrite earlier noisy/calibration evidence,
and the comparison page selects these explicitly named later attempts.


### 23 October calibrated serial cohort — incomplete, no default promotion

The owner could not close any apps. No owner app was closed and no unrelated cache,
model, swap file, recording or user document was deleted. The diagnostic output level
was temporarily set from12.5% to38%; the wrapper restored the exact original level.
`calibrated-volume-{before,during,after}.json` retains the witness. Input remained51%.
Each trial's route signature now includes device IDs, gain and mute at start/end.
Unobservable properties carry a sentinel, not an asserted measurement; this does not
prove that no route transition occurred between those observations.

| Voice | Latest warm result | Evidence |
|---|---|---|
| macOS |30/30 qualified;159.863ms median,186.975ms p95|`calibrated-speaker/apple.json`|
| Qwen3-TTS |27/30 qualified; no accepted warm acoustic median|`calibrated-speaker/qwen.json`|
| Phonon |Disk guard stopped process before timing|`calibrated-speaker/phonon.json`|
| Pocket |Refused before download: insufficient headroom|`calibrated-speaker/pocket.json`|
| Kokoro |Refused before download: insufficient headroom|`calibrated-speaker/kokoro.json`|

All31 Qwen requests completed synthesis. Three warm acoustic pickups failed the unchanged
qualification gates. No survivor-only median is used. Apple completed all31 pickups,
with first-after-preparation kept separate from30 warm requests. Native output is the
actual production playback backing with diagnostic selection, not the normal Agent
selection/EOU/AEC path. `reference-progress-audit.json` derives exact host-clock conversion
from mach_timebase_info and checks retained native RPC response times: every Qwen/Apple
request overlaps real responses; maximum within-request gaps1.172/1.046seconds. This is
progressing cached-v3 reference load, not current selected-ASR qualification.

The observer now uses the immediate preceding500ms baseline rather than the entire
historical pre-request tail. The authored original stale-tail case fails once and
fixed case passes; the persistent-noise negative remains refused. Thresholds remain
4x/.001RMS,>=.75 correlation and two consecutive10ms windows. Retained original/fixed
and actual muted-source results are in `final-controls/`. Current binary/source pins
are `calibrated-source-pins.json`; exact command is `calibrated-command.json`.

Qwen's pinned SDK decode producer previously processed up to300codec tokens (24seconds)
in one chunk. The packaging overlay now uses its existing stateful incremental decoder
in25-token (2second) batches, retaining precision and the joined whole-clause return.
Original SDK source/object/interface files stay untouched and exported symbols match.
The completed cohort reports MLX peak3,768,257,346bytes, versus4,637,067,284bytes in the
older diagnostic. This is a scoped lower-peak observation, not proof of waveform
continuity, intelligibility, an allocator leak repair or the total pressure cause.
Long/short boundary/suffix quality verification is still required before installing
this diagnostic repair. Installed809 remains unchanged.

Preparation now finishes before the model's owned reference decoder starts; timing
waits for that decoder to warm. This only changes the headless benchmark, never the
product full-duplex path. Fourteen model-free runner tests pass, including deferred
reference admission, serial lifecycle, save failure and cleanup controls.

Space was recovered by byte-preserving APFS clone deduplication of identical idle
vendor symbols/framework/archive files in existing build caches, and retiring only
superseded task-owned compressed symbols after replacement verification. Hashes,
paths and observations are in `final-controls/deduplicate-*.json` and
`controlled-symbol-cleanup.json`. File bytes/modes/mtime and ordinary xattrs were
checked; macOS creates fresh per-inode provenance. Do not attribute all OS free-space
recovery to these operations. The current useful diagnostic app, compact symbols,
installed809, baseline and rollback remain retained.

The calibrated cohort began with5,694,193,664bytes free. Qwen's model was saved/joined/
deleted, then Apple completed. During Phonon reference warmup disk pressure crossed
the unchanged1.5GiB live floor. The runner stopped/joined both owned children, saved
failure and deleted temporary assets. Pocket and Kokoro were refused at admission.
All owned reference receipts verify child joined, snapshot removed and existing ASR
artifacts unchanged. No guard or production reserve was lowered. Earlier failed
`final-speaker` and `controlled-speaker` attempts are preserved rather than overwritten.

The VOICE-TURN-DETECTION agent reviewed the new source read-only (relay message
90a19136-fb3f-4197-a134-1ae27120b8fc): completing that entire roadmap is not a
prerequisite, but a five-model qualified cohort, winner production consumer and
pause/resume/cancel/reopen checks, actual selected-ASR/EOU smoke and basic speech
quality remain prerequisites to the requested default decision. This cohort does
not meet those contracts. No fastest-five claim or preference change is made.


The exact Qwen overlay packaging candidate is retained as
`final-controls/package-resource-accessors-candidate.py`, matching the packaging-tool
hash in `calibrated-source-pins.json`. The ordinary packaging tool is restored to its
previous resource-only implementation: incomplete waveform/quality verification must
not silently activate the diagnostic decoder change in future normal releases. The
current useful diagnostic bundle and overlay receipts remain available for continuation.
Site typecheck, lint, build and75-record catalog checks pass. The build retains the
existing >500kB bundle-size warning. Last handoff free-space observation is recorded in
`calibrated-preservation.json`; free disk continues to vary with OS pressure recovery.
