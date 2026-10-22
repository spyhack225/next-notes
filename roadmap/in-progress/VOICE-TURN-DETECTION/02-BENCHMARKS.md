# Latency, mid-sentence pause and interruption benchmarks

22 October 2026. This is the required benchmark protocol. The [offline scorer](benchmark/README.md)
is executable; native collection/harness extensions remain VTD-06. **No new native result
was produced when writing this roadmap.** All numeric gates below are targets.

## 1. Separate the experiments

| Layer | Native dependencies | What it can establish |
|---|---|---|
| Policy regressions | Scripted probabilities/progress and real policy | Boundaries, stale-result rejection, exactly-once decisions; no model accuracy/latency |
| Smart Turn classification | Actual pinned model, annotated audio | Completion probability, false positives/negatives, preprocessing/inference time |
| Paced input -> commit | Actual Capture, VAD, ASR and endpoint policy | End-to-end endpoint latency and final-word coverage; no audible-output claim |
| Paced input -> audible response | Above + actual selected frontend/TTS/renderer | Real full-turn latency, overlap, pause/resume, post-commit speech |
| Physical routes | Real mic/speaker/headphones, human/loopback output observation | Acoustic echo and hardware/output latency for that route |
| Engine component bake-offs | ASR or TTS owner's isolated component harness | ASR first partial/final or generated-first-PCM; not full voice latency |

Use current policy as control A and candidate as B with the **same** audio, ASR/TTS pair,
frontend configuration, route, source/build optimization and normal features. First do
the classifier/policy comparison; changing voices/recognizers simultaneously prevents
attribution. Then expand the provider matrix. Report all failures/missing cells.

## 2. Ground truth and clocks

Every materialized case must have a versioned annotation file containing WAV SHA-256,
sample rate/channels, exact speech regions, last intended speech sample, protected
mid-thought intervals, expected turns/text or required final-word spans, interruption
onset and permitted completion ranges. A fixture recipe in `cases.json` is **not** an
audio artifact or a measured annotation. Native reports require materialized hashes and
reviewed labels; examples and generated traces cannot satisfy acceptance.

For controlled silence, create the entire phrase from a fixed recording, split at an
audited word boundary and insert exact sample counts; retain the unsplit control. Inspect
the joins for truncation/clicks. Synthetic `say [[slnc]]` recipes already exist but require
waveform inspection; duration difference alone does not prove the intended pause.
Natural speaker recordings provide the held-out acoustic/prosodic evaluation.

Use two distinct clocks:

- **Audio sample time:** ground-truth speech/pause boundaries and model window coverage.
- **Monotonic host time:** captured chunk origin, model request/completion, ASR publication,
  commit, first generated PCM and actual render/audible observation. Map sample positions
  to the shared capture origin; measure feed scheduling error and actual capture rate.

Paced replay must deliver canonical 10 ms chunks on monotonic time through the production
delivery seam, retaining 20/160 ms input variations as additional cells. Decode-a-file-as-fast-
as-possible is a throughput test. A sample-time duck is not wall-clock duck latency.
Do not overwrite late timestamps with expected schedule times or subtract an invented
priming delay. Record both intended and actual feed times. Report pacing p95/max error;
>20 ms p95 scheduling error invalidates a sub-200 ms claim until rerun under an admitted window.

All timing marks have capture/session/turn/revision and, for output, generation identity.
Use the existing VoiceLatencyTimeline/MetricsStore/UsageLog for application events.
Benchmark reports are export artifacts from those events, not a new production logging store.

## 3. Required cases

The machine-readable [recipes](benchmark/cases.json) define deterministic IDs and mandatory
core cases. Record language, speaker/voice, pace, utterance length, noise/SNR and split.

| Family | Required coverage | Primary assertions |
|---|---|---|
| Completed phrases | Short question, request, yes/no answer, final correction | Prompt commit; final word preserved; one response |
| Internal pause | 200, 400, 700, 900, 1200, 1500 ms; beginning/middle/near-end | No commit, audible reply or effect during protected thought; one joined transcript |
| Hesitation | um/uh, repeated word, breath, self-correction | User keeps floor without accidental cancellation or lost suffix |
| Entity entry | Dates, card-like digits, phone/address spelling, names | Preserve complete sequence; no cutoff after partial entity |
| Long input | >8 s and 30–60 s | Rolling context remains bounded and newest suffix survives |
| Adjacent turns | Two genuine turns with short separation | Exactly two commits; no fusion or duplicated late revisions |
| Noise/quiet | Silence, keyboard, breath, quiet speech, room noise | No false speech command; quiet real words retained |
| Overlap | Echo-only, double-talk, backchannel, explicit stop | No echo-only duck/commit; reversible false hold; fast real duck |
| Races | Speech resumes during inference; stale output; new session; ASR lag | Old verdict cannot commit; no missing tail or stale gain |
| Availability | Missing/corrupt/late model, unknown ASR progress | Truthful fallback, continued capture, labelled quality/latency |
| Routes/lifecycle | Built-in, wired/USB, Bluetooth, route swap, sleep/wake | Clock continuity, no retained old output authority |

Longer 2–5 s thinking pauses are exploratory initially and always reported. Do not use
their results to redefine the mandatory 0.2–1.5 s cases. Add human conversational review
for semantically complete clauses followed by continuation; not every inter-clause pause
has one unambiguous correct endpoint. Ambiguous labels stay separate from scored core.

Development: at least 20 phrase bases across at least five speakers/voices, with a
reproducible pause sweep. Held-out acceptance: at least 300 independent unfinished-turn
examples and 300 completed-turn examples, disjoint speakers/phrases from tuning. Do not
count six pause variants of one phrase as six independent speakers/semantic examples.
Include English and French initially; publish per-language cells and expand to supported
deployment languages. Upstream 23-language support does not prove app-level coverage.

## 4. Metric definitions

| Metric | Start -> end / denominator |
|---|---|
| Endpoint latency | Annotated final speech sample mapped to host -> actual commit |
| Audible response latency | Same speech end -> first audible response from this turn |
| ASR first partial | First actual speech sample -> first nonempty current-turn snapshot |
| ASR tail coverage lag | Last intended speech sample -> publication covering required final words |
| Classifier time | Actual request -> completed prediction; preprocessing and queue separately |
| Callback/actor wait | Native callback -> policy handling on MainActor |
| TTS first PCM | TTS synthesis request -> first nonempty generated PCM |
| Render lead | First generated PCM -> actual first rendered audible PCM |
| Onset-to-duck | Annotated near-speech onset -> verified current-output gain change |
| Onset-to-pause / stop | Same onset -> actual renderer pause / last stale-generation sample |
| Premature commit rate | Trials committing before annotated allowed completion / eligible unfinished turns |
| Audible interference rate | Trials with new assistant speech during a protected thought / eligible unfinished turns |
| Tail retention | Trials preserving required final spans in committed text / eligible trials |
| False interruption rate | Echo-only/noise/backchannel trials incorrectly ducking/pausing/stopping / relevant trials |
| Missed endpoint | Completed phrase not committed within 2500 ms / completed eligible trials |
| Speculation reuse | Adopted matching preparation / eligible committed turns, with stale-output count |
| Resource behavior | Queue occupancies, audio gaps/drops, app/model footprint, whole-machine swap, thermal state |

Incomplete probability is not a premature commit. An EOU token is not an audible reply.
Generated PCM before commit is allowed only as muted/cancelable preparation with no sink.
An irreversible effect before commit fails even if no speech played. Do not offset a
negative endpoint latency to zero: it is a cutoff/annotation issue to retain and inspect.
No committed words or expected private text need to be copied into performance exports:
store reviewed tail-coverage booleans/hashes with private authored fixture data separately.

## 5. Run design and engine alignment

Reference workload: optimized release on 16 GB / 256 GB M2 and/or M3 Air, normal ASR and
selected voice active. Record chip/RAM/macOS, power/thermal, route/rate, dependency/model
hashes, binary UUID/signature, features, foreground workload and source snapshot.

Run phases separately:

1. Fresh process/model load with existing cached files; no download in a timed trial.
2. First speech in a fresh capture/output generation, with model already loaded.
3. Warm continuous capture with valid real pre-roll.
4. Session reopen / pressure release and recovery.
5. Concurrent active ASR, voice synthesis and normal background workload; then an admitted
   meeting/voice overlap test. Development builds never run concurrently with acceptance.

Use >=30 warm trials for each mandatory latency cell and >=10 fresh-capture trials;
report p95 as exploratory at n=10 and require >=30 for a promoted p95 claim. Use at least
five fresh-process starts for load distributions, labelled low-n; collect >=30 before
claiming a load-time p95. Counterbalance A/B and case order using a recorded seed. Keep
all attempts, including startup failures, timeouts, outliers and native refusal reasons.
Never rerun until green or silently exclude pressure/failed runs.

Engine matrix:

- Baseline: current Agent Apple + Parakeet EOU text ownership, fixed existing frontend,
  and the selected supported Apple/Pocket/Kokoro voice.
- TTS: Apple, Pocket, supported Kokoro, then Phonon and Qwen when native adapters qualify.
  Qwen whole-clause first PCM includes full synthesis. Kokoro's known macOS 26.4/26.5
  guard yields an unsupported cell, never bypassed to complete the matrix.
- ASR: existing provider first; Qwen3-ASR 0.6B/1.7B, Whistle, Phonon-2, Redux, Ultra and
  Voz are candidates, not current Agent adapters. Per-provider ASR/EOU/progress capabilities
  and actual availability must be established before native endpoint qualification.
- First test each engine against one qualified counterpart, then pairwise coverage of
  capability differences. Before declaring *all supported combinations* ready, run a
  short core smoke corpus on **every shipping ASR x TTS combination**. Pairwise alone is
  insufficient for a universal compatibility claim.

Respect the owner's TTS benchmark lifecycle: one temporary candidate model/child at a
time, save/flush report, join the child/native work, delete only its owned model root,
then start the next candidate. Keep normal user models and shared verified assets.
The simultaneous selected ASR + TTS + turn detector acceptance workload is a different
experiment and must still be exercised; serial component runs do not prove full duplex.

## 6. Gates frozen before held-out runs

| Gate | Requirement | Basis |
|---|---|---|
| G1 | Zero premature commits, audible replies or effects in all mandatory protected intervals | User-requested mid-sentence safety regression bar |
| G2 | Final-word/span retention 100% on the core corpus; exactly-once expected turns | Prevent faster timing through dropped content |
| G3 | Completed clean phrases: commit p95 <=450 ms | Proposed endpoint allocation |
| G4 | Warm actual speech end -> first audible p95 <=900 ms | Existing 900 ms voice goal, explicit statistical interpretation |
| G5 | Actual onset -> duck p95 <=200 ms, cold and warm separate; report max/excursions | Existing interruption target, currently open |
| G6 | Held-out premature-commit point estimate <=1%; 95% Wilson upper bound <=2%; >=300 eligible independent unfinished cases | Proposed promotion bar, not model-card accuracy |
| G7 | Completed-turn timeout rate <=1%; classifier late/error rate <=1%; report denominators separately | Proposed responsiveness/reliability bar |
| G8 | No introduced capture losses; no unbounded queue/memory trend; current regression/owner gates pass | Existing performance/functional requirements |

Report 95% intervals and per-language/speaker cells; do not present 0/20 cutoffs as proof
of a 1% population error rate. Bootstrap latency intervals at phrase/speaker cluster level;
repeated executions of one recording estimate runtime variability, not model accuracy.
For mandatory pause variants G1 is absolute; aggregate percentages cannot hide a known
900 ms phrase regression. Thresholds are selected on development data only.

Cold audible latency has no newly invented 900 ms promise: report preparation and
speech-to-output separately, preserve the inherited startup requirements and qualify it
before making a cold responsiveness claim. G5 still applies to first-capture ducking;
the current 256 ms path does not receive a hidden exemption.

## 7. Harness and report deliverables

VTD-06 adds a native paced collector around existing file-fed Capture. Proposed developer
interface (not implemented flags today): `--selftest-voice-turn-benchmark` with explicit
manifest, original/candidate policy, phase, fixed engine IDs, repeat/seed, isolated root
and report path. Extend `--selftest-smart-turn` for classifier-only cases. Reuse
`Scripts/run-selftest.sh` with an explicitly pinned signed **candidate** bundle; its
default installed-app path must not accidentally benchmark an unrelated binary.

Collector emits one run artifact conforming to [offline trace format](benchmark/README.md).
Include all sampled trials, source/binary/model pins, environment, pacing, capability
availability, ground-truth hashes and timestamps. Nested stage events need identity and
thread/queue provenance where needed to diagnose stalls. First generated PCM from the
TTS owner's `--selftest-tts-benchmark` can be linked as component evidence; do not import
it into the first-audible column.

Export a machine-readable report and a readable comparison: configuration, n, median,
p90, p95, maximum, missing values, cutoff/timeout/tail counts, confidence intervals,
per-engine/language/phase status and named failures. Keep failed trials in denominators;
no metric is green solely because it had no samples.

The included scorer executes G1/G2/G3/G4/G5/G7 subsets on supplied traces and exposes
sample counts. It explicitly leaves G6, corpus breadth, physical routes and G8 to the
native qualification report. It is not a collector and cannot certify full promotion.

## 8. Physical and long-session coverage

At minimum: built-in mic/speakers, wired/USB input/output, Bluetooth headset, output and
input changes mid-session, echo-only playback and real double-talk. Record OS-exposed
formats and conversion, reference availability, gain, false hold/resume and final words.
Do not play adversarial fixtures into an unisolated owner conversation or invoke tools.

Run 30–60 minute selected-engine sessions after short gates pass: repeated turns,
long/short pauses, interruptions, background tasks and at least one controlled route
transition. Evaluate first versus last ten minutes, queue occupancy/drops, process and
whole-machine pressure, thermal degradation, output continuity and app responsiveness.
An idle memory sample or model unload does not establish soak stability. Preserve the
meeting pipeline's own source clocks, saved coverage and normal stop/recovery contracts.

Coordinate the machine window through agent-relay before any build/inference/native
run. Refusal, absent model, unsupported route and interrupted owner usage are explicit
results. Never install, download a multi-GB model or delete another agent's assets to
turn a planning task into a benchmark claim.
