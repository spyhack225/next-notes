# Implementation contracts and work packages

22 October 2026. Product work below is **todo**. Read [overview](00-README.md),
[alignment](03-ASR-TTS-ALIGNMENT.md), root AGENTS and PERFORMANCE-STANDARDS before editing.
Use existing producers; names below are proposed where no implementation exists.

## VTD-00 — source baseline and shared contracts

1. Re-read live Capture, ASR and renderer sources after the parallel agents' work lands.
   Pin revision, dirty-file hashes, dependency lock, binary UUID/signature, settings,
   selected model files and physical route. Retain the original endpoint implementation.
2. Record engine capabilities: incremental text, immutable prefix, input sample rate,
   audio progress observability, learned EOU, streaming PCM, pause/resume, dynamic gain,
   actual render reference, native cancellation join. Unknown is not supported.
3. Reuse current voice fixtures and capture file-feed seams for a real original run.
   Reproduce slow completion and an actual mid-pause cutoff before changing policy.
4. Establish corpus splits and targets before tuning. Pin the ASR/TTS pair in the endpoint
   comparison; engine bake-offs are separate experiments.
5. Agree file ownership and a development test window with ASR/TTS peers. Do not touch
   Package.swift, ASR settings, speech backings or shared entrypoints while peers own them.

Exit: original report plus exact provenance and shared capability fields. No model speed
or native result is assumed from source review. Original already passing a case is a
regression baseline, not evidence that the original was broken there.

## VTD-01 — artifact and model wrapper

Initial runtime: direct CoreML through existing Swift APIs. Reuse ModelSpec,
ModelDownloader and the existing model library; add no second asset store/downloader.
Coordinate with the TTS owner's in-flight downloader directory parameter.

The older P2-04 plan pins `aufklarer/Smart-Turn-v3.2-CoreML` commit
`75f069717f500947195fa1945c46ddb472559cff`, converted from upstream revision
`f766f81d3cfdf7737ac64aad813d91bbfd56bf93`. Re-verify that exact revision and all four
compiled-model files before adoption. Preserve the existing published sizes/hashes in
P2-04; resolve and pin its still-missing `model.mil` SHA-256 before promotion. Never use a
moving Hub URL or accept a same-size file as verified identity. Stage/verify the complete
directory and publish it atomically; interrupted assembly cannot appear ready.

Contract:

- Raw Float32 mono 16,000 Hz; `[1,128000]` input named `audio`.
- Use the current turn's latest eight seconds, right-aligned with leading zeros when
  shorter. Never truncate the end or include the previous committed turn.
- CoreML export contains normalization and log-mel processing; do not normalize twice.
- Read finite `[0,1]` `probability`; malformed feature/shape/NaN output is unavailable.
- Model owner retains weights across normal sessions, uses CPU/Neural Engine as qualified,
  and runs off MainActor and realtime callbacks. Copy with typed buffers, not 128,000 NSNumber allocations.
- One in-flight inference and at most one newest pending request; replace obsolete pending
  work. Bound memory and do not create one detached task per 10 ms chunk.
- A timeout revokes the result's authority; CoreML may still be running. Join that native
  owner before reuse/disposal. Task cancellation alone does not establish native exit.
- Proposed 50 ms useful-result deadline; record late results and retain safe fallback.
  Calibrate on M2/M3. Do not fail the whole audio path because optional inference is absent.
- Optional preparation is cache-only and asynchronous. No synchronous turn-path download,
  no self-test download, no automatic multi-GB engine download. Preserve existing disk policy;
  any model-specific reserve change needs evidence, not the old draft's blanket 512 MB exception.
- Recheck BSD-2 upstream/export notices and record exact source attribution at adoption.

Suggested files: `Activation/SmartTurn/SmartTurnModels.swift`, `SmartTurnModel.swift`,
`SmartTurnSelfTest.swift`. Extend existing model UI/library requirements only where needed.

Exit: actual native prediction on pinned fixture, preprocessing/padding/output parity,
missing/corrupt/partial-download tests, load failure, deadline and drain/reopen tests.

## VTD-02 — Silero across listening and playback

Extend Capture's existing `CaptureVoiceActivityInput`; do not add another VAD manager
with a separate audio subscription. Separate capture identity from playback identity:

- Listening-time scoring requires capture/session identity, not an active TTS generation.
- Speech start/continuation/pause use sample-time intervals and explicit hysteresis.
- Duck/pause effects additionally require current output generation and valid echo evidence.
- Late VAD callbacks cannot act after capture close or on a successor reply.
- Keep shared PCM continuity distinct from generation-bound echo/duck evidence. Never
  carry old output evidence into new playback merely to keep a warm VAD window.
- Initial pause-to-evaluation setting: ~200 ms quiet; speech/confidence thresholds and
  hop lengths are calibration inputs, not product copy or hard-coded benchmark outcomes.

### Resolve the cold onset constraint before claiming 200 ms

The current FluidAudio path waits for 4096 real samples (256 ms), then two confirmations
with >=800 new samples (50 ms). A fresh window cannot meet 200 ms. Lowering a timer or
preparing weights does not remove the audio requirement.

Implement a bounded feasibility spike, in order:

1. Verify the current dependency's supported native model contracts. Measure true input
   windows, overlap, context/state resets and output latency; pin the artifact and SDK.
2. Evaluate a supported shorter-window Silero runtime/export (for example an upstream
   512-sample/32 ms contract), through a compatible native wrapper. Do not slice a 4096-sample
   graph arbitrarily or present synthetic padded speech as a cold native pass.
3. If preserving 256 ms inference, valid pre-roll from the same continuous capture may
   improve warm onset. Qualify it separately; it cannot prove fresh-capture latency.
4. Compare speech miss/noise false-start/echo-only/double-talk rates on exactly the same
   recordings. Preserve near-evidence freshness, gain verification and held-output resume.
5. If no path meets the cold target, leave that cell failed. Do not silently rename warm
   results as cold, relax 200 ms or promote an unsupported artifact.

Duck remains reversible; do not wait for Smart Turn to duck. Endpoint timing and
interruption timing are different paths.

Exit: native cold/warm onset distributions; no echo-only duck; normal quiet/speech events
without playback; old generations rejected; missing-model fallback stays usable.

## VTD-03 — current-turn context and recognizer progress

Add a small current-turn audio buffer within Capture's input ownership, fed directly
after echo cleaning. Use 128,000 samples (~512,000 PCM bytes) plus documented bounded
snapshot/in-flight copies. Preserve enough pre-speech audio to avoid clipping the onset,
but do not include audio preceding the previous committed boundary. Capture's existing
six-second decoder backlog is a work queue, not this retained context.

Represent an evaluation using values equivalent to:

```swift
struct TurnAudioRevision: Sendable {
    let captureID: UUID
    let turnEpoch: Int
    let speechRevision: UInt64
    let firstSample: Int64
    let endSampleExclusive: Int64
    let lastSpeechEndSample: Int64
}
struct CompletionVerdict: Sendable {
    let revision: TurnAudioRevision
    let probability: Float
    let requestedAtNanos: UInt64
    let completedAtNanos: UInt64
}
```

These describe state in the existing input component, not a new event bus/store.
Validate continuity across sample-rate conversion; count actual input samples, preserve
first-sample host time and map it to one monotonic session origin. Route/format changes
invalidate or deliberately rebase the turn with a recorded reason. Never silently stretch
timestamps or pretend missing buffers were silence.

ASR collaboration contract:

- Keep cumulative snapshots and optional immutable prefixes. `isFinal` currently means
  session finality; it must not be reused as arbitrary mid-session turn completion.
- Distinguish **fed through**, **processed through**, **published words through**,
  **stable prefix** and **EOU confirmed**. Returning from `feed` may only enqueue work.
- For Parakeet, capture processed-through evidence at the actual native processing
  completion, in audio-sample coordinates. Startup `localDecoderCaughtUp` is not sufficient
  to prove that this turn's final word has been decoded.
- If a provider cannot expose a reliable progress/finalization boundary, declare unknown;
  keep its conservative transcript-settle/finalization path. Do not synthesize certainty.
- Preserve Apple/local transcript ownership and late-revision suppression when committing
  from a Smart Turn verdict before Parakeet EOU. Resetting the decoder must not discard
  queued speech belonging to the next turn.
- Batch-only candidate ASR uses explicit endpoint-segment submission and a separately
  measured first-transcript delay. Do not fake incremental capabilities.

Exit: final-word coverage at early endpoints; 8+ second input truncates only old context;
mid-pause resumption retains both clauses; no duplicate turn from a late ASR revision;
gap/reset/route-change cases invalidate old inference.

## VTD-04 — one endpoint policy

Implement a pure decision function behind Capture's existing `tick`/callback seam. States
may be represented as listening, speaking, pause-pending, evaluating, incomplete,
complete-awaiting-transcript, committed and unavailable. Reuse turn IDs/epochs and the
existing VoiceSession state; do not introduce a parallel conversation state machine.

| Observation | Decision |
|---|---|
| Fresh sustained speech | Open/continue current turn; cancel authority of older completion; retain context |
| ~200 ms real quiet and model available | Evaluate latest turn revision; keep ASR/speculation running |
| Fresh complete verdict + usable sufficiently processed transcript + still quiet | Exactly-once existing commit |
| Complete verdict but recognizer behind | Wait only for necessary transcript progress; no lost last word |
| Incomplete verdict | Keep listening and current transcript; reevaluate on resumed speech/new pause |
| Parakeet EOU | Trigger evaluation/prepare work immediately; do not independently override fresh incomplete verdict |
| Model unavailable/late/error | Use explicit existing conservative fallback, report reason and degraded mode |
| User explicitly finishes | Existing manual finish authority, without manufacturing audio completion |
| No words / playback echo / backchannel | Existing discard/resume policy; no speculative tool effects |
| Session closes/reopens or input gap | Invalidate old revision; drain outside the capture path |

Rules:

1. Evaluate on pause and new relevant evidence, not continuously on every audio chunk.
   A bounded quiet recheck may run at the existing 100 ms cadence when useful; cap work.
2. A verdict must cover the current speech revision, have been requested after its last
   speech evidence and still be within its qualified freshness window. Recheck after every
   await. New speech invalidates a verdict even if its old model call later completes.
3. No unconditional 0.8/1.0 s completion override of a fresh incomplete verdict. The
   required protected corpus includes 0.9 and 1.5 s pauses. Incomplete-input idle recovery
   may release a provisional hold/session through existing idle policy; it is not a
   completed command and must not erase a usable pending thought silently.
4. Persistent false-incomplete predictions on finished questions must fail the bounded
   completion benchmark. Any proposed new timeout/clarification behavior needs its own
   user-flow and pause tests before adoption, not an undocumented escape hatch.
5. Preserve model-absent fallback initially; all fallback commits count in cutoff and
   latency results. Model-unavailable rows cannot establish Smart Turn quality.
6. Current Parakeet 320 ms debounce remains the control. Experiment with 160 ms only
   once Smart Turn and transcript-progress checks work. Select it from measured results;
   do not require both detectors' waits in series.
7. Existing lexical hesitation/backchannel/echo rules remain; Smart Turn only answers
   when a thought is complete, not whether it is addressed to the assistant.

Suggested integration: `SmartTurnArbiter.swift` owns buffer/evaluation and pure policy;
Capture remains the producer of commit and reset. Parameterize the existing Parakeet
constructor only if the debounce experiment proves necessary.

Exit: original/fixed same-input proofs, protected pauses, finished questions, rapid
adjacent turns, stale result races, unknown-progress fallback and exactly one commit.

## VTD-05 — speculation, playback and lifecycle

- Keep `prepareResponseForRecognizedSpeech` active on useful partials. Completion allows
  adoption of the matching preparation; a revised transcript/context cancels stale work.
- Preparing an answer has no speech/tool sink. No audio or irreversible effect may escape
  while the user is still inside a protected thought. Keep existing inputPending/effect
  barriers; do not add a new product-wide turn lock.
- Preserve duck -> provisional pause -> committed stop progression. False speech/echo
  restores the same output token and queued clauses; newer generations cannot inherit
  a delayed resume or gain change.
- Use actual rendered post-gain PCM for the AEC reference. Engine synthesis PCM and
  output start callbacks are not evidence of speaker output. Respect capability-unknown
  system voice paths and run physical echo checks.
- Qwen whole-clause generation remains a declared TTS limitation until native producer
  cancellation/join is proved. Dropping PCM must not cause another decode on live mutable
  state; microphone and playback must remain responsive while native work drains.
- Close: reject new PCM/results first, join owned work, clear turn/sample/echo evidence,
  release gain/hold and retain only healthy optional weights. New session gets new IDs.
- Handle pressure, sleep/wake, microphone removal, route/rate changes, app quit, failed
  model preparation, cancellation during load/inference, long turns and rapid reopen.
- Reuse existing idle preparation and role-based residency. Do not keep all candidate
  ASR/TTS models resident; preserve stored choices and other modules' active sessions.

Exit: cold/warm/session-reopen/pressure tests, native producer joins, no stale rendered
PCM after interruption and no lost accepted capture under concurrent ASR/TTS load.

## VTD-06 through VTD-08 — qualify and deliver

Build the paced native harness and report schema from [benchmark spec](02-BENCHMARKS.md).
The included offline scorer validates trace arithmetic and gates now; it cannot replace
production capture/renderer instrumentation. Add proposed self-test flags only through
the existing entrypoint with agreed ownership. Unsupported flags today are not commands
to execute. Register real cases in the existing acceptance tiers once implemented.

Re-run relevant existing tests: voice-turns, voice-pipeline, voice-rapid, voice-barge,
voice-conversation, realtime, voice-latency, duplex, acoustic-replay, voice-suspend,
playback-ledger, voice-delivery, owner-store isolation and affected ASR/TTS regressions.
Use core/integration/owner requirements from the actual acceptance catalog; no copied
historical green result counts as a current run.

Rollout order: observe-only decisions -> isolated native candidate -> fixed current
ASR/TTS pair -> capability-qualified candidate engines -> physical routes/concurrent
workload -> normal default only after inherited gates. Record decision disagreement in
the existing diagnostic sinks without owner audio/text. Keep an internal diagnostic
fallback switch and a tested rollback to current endpoint policy; never silently switch
the user's chosen speech engines or enable cloud transport.

Completion requires artifact identity, source/binary provenance, same-case before/after
reports, all mandatory provider/route cells, held-out cutoff/latency gates, normal stop and
reopen, bounded resource soak, current acceptance and explicit remaining limitations.
Parent P2-04/P2-05/P2-07 stay open until their own contracts are satisfied.
