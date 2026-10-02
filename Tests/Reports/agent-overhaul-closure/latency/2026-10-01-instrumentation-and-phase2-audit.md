# Agent Phase 2 instrumentation and completion audit — 2026-10-01

This is an implementation/evidence report for P2-01, not a Phase 2 completion claim.
The target stays warm speech-end→first audio ≤0.9 s over five runs, worst main-actor stall
≤100 ms, barge duck ≤200 ms and inter-clause gap ≤50 ms. No threshold, default, model,
voice owner, permissions, real store, microphone or audio-device setting was changed.

## Confirmed producer failures and repairs

1. **Healthy measured zero disappears from the metrics store.** A complete actual
   `VoiceLatencyTimeline` turn, with every ordinary required mark and no late ping, had
   `mainStallSeconds=0` in memory and in its actual usage summary, but zero persisted
   `voice.main_actor_stall` rows. The unchanged production `validateStore` rejected it with
   “voice.main_actor_stall was measured but not stored.” `span(for:)` discarded the zero.
   The producer now writes the real zero through the existing writer.
2. **A mark unlocks twice.** `mark` installed a deferred unlock and also unlocked explicitly
   before emission. A checked-lock diagnostic copy of the same body observed 13 unmatched
   unlocks for 13 marks. The native run did not crash; this report makes no native-crash
   claim. The single explicit unlock remains; file emission stays outside the critical
   section. No lock, gate, wait or queue was added.
3. **Snapshot construction ran on the stamping thread.** An observation inserted at entry
   to the actual `ProcessSnapshot.current()` found 15 calls on the main stamping thread,
   zero on the metrics writer, for one complete turn. The old producer built the span
   before `recordAsync { built }`. Construction now happens inside that existing writer
   closure; the same observation is main=0, writer=15. The closure accepts an optional
   span so a genuinely absent stage remains absent. This establishes thread placement,
   not a measured 0.3–0.6 s user-visible stall fix. Generic `LatencyTrace.record/end`
   construction still runs before `persist`; that broader contract is open.

4. **The latency harness accepted unmeasured/misattributed turns.** Its ordinary validator
   treated split-mode lane/route boundaries as always optional, accepted a zero/multiple
   committed count, and its store validator let an unstored revision borrow the earlier
   turn's rows. At the actual validator boundary, the original source accepted all four
   invalid fixtures. The producer-side harness now receives the real observed commit count
   and command-line deterministic frontend mode from oneRun, enforces conditional stages,
   and matches the exact session+turn revision. The same missing-stage, count and revision
   inputs are rejected. Speculation-hit and single-decision exceptions remain valid. This
   is a repaired measurement/verdict contract; it is not evidence that a real capture
   session ever committed two turns or that a real split route failed to run.

## Isolated evidence

`run-instrumentation-driver.py` copies the actual Timeline, MetricsStore, UsageLog,
UsageRecord schema and LatencyTrace into a temporary compiler directory. The original
production `validateStore` is extracted verbatim. App bootstrap identity is a temp-only
harness stub. The unrelated error-classification method in UsageRecord is replaced with
an unused `.other` shim to avoid loading tool/backend implementations; the producer,
store readers/writers, span construction and validated schema are unchanged. No owner
Application Support directory is referenced. Compiler cache and binary are temporary.
The committed-count negative controls drive the actual validator boundary: the old
signature did not accept count/mode from oneRun, so the driver explicitly calls that old
signature and checks its missing rejection. They do not synthesize capture callbacks or
claim actual production sessions committed zero/two turns. The unstored revision is an
explicit negative-control VoiceClosedTurn carrying no emitted store rows.
The optional checked-lock and snapshot observations are separate diagnostic copies,
not changes to production lock/ProcessSnapshot types.

| Evidence directory | Actual result |
|---|---|
| `red-native` | Compile 0, run 1: required measured zero missing from store; 2 assertions |
| `red-checked` | Compile 0, run 1: same missing row plus 13 unmatched unlocks; 3 assertions |
| `red-snapshot-thread` | Compile 0, run 1: 15 main-thread snapshots, 0 writer snapshots |
| `green-all` | Compile 0, run 0: one zero stall row, 0 unmatched unlocks, 0 main/15 writer snapshots |
| `mutation-zero-stall` | Compile 0, run 1: restoring the original zero omission fails the original consumer and persisted-row assertion |
| `green-pure-suite` | Compile 0, run 0: actual emission/zero/missing PCM/discard/incomplete usage cases and the actual 200 ms labelled stall-probe check |
| `red-consumer-contracts` | Compile 0, run 1: unchanged validators accept missing split stages, counts 0/2 and an unstored next revision; four invalid-fixture assertions |
| `green-consumer-contracts` | Compile 0, run 0: three missing split-stage errors, counts 0/2 rejected, unstored next revision rejected; hit/single-mode exceptions preserved |
| `green-final-pure-suite` | Compile 0, run 0: final actual validators + all current pure fixture methods and actual labelled 200 ms probe |
| `mutation-final-zero-stall` | Compile 0, run 1: actual final pure suite and original consumer reject restored zero omission; four assertions |

Each directory contains raw compile/run output and SHA256 source manifests. The mutation
only changes a temporary copied source. The production `VoiceLatencySelfTest` includes the
zero case and exposes it with the existing flag plus `--voice-latency-instrumentation`.
That modifier prints `VOICE_LATENCY_INSTRUMENTATION_ONLY`; it measures no audio/model
latency, and a green modifier result cannot satisfy the full latency or phase gate.

Root subsequently verified the installed instrumentation modifier, metrics and
store isolation, and retained original/current native five-turn runs below. The
copied-source driver itself remains narrower than installed or physical audio proof.

## Full P2-01 contract audit

| Task contract | Current source / evidence | Completion verdict |
|---|---|---|
| Six generated Float32 mono/16 kHz fixtures and pause-duration check | Root generated all six with `Scripts/make-voice-fixtures.sh` at `/tmp/nextnotes-agent-closure-voice-fixtures`, including the checked pause fixture | Generated; the fixture-absence finding belonged to the earlier read-only audit |
| One stage vocabulary and no duplicate clock/file | Existing VoiceMark/VoiceStageSpan/LatencySpanID, shared metrics/usage stores | Isolated producer/store proof plus installed instrumentation, metrics and store isolation green |
| `source=voice/text/worker` on first-token spans | Tracker carries source; coordinator passes voice; typed tracker chooses text/worker | Source path exists; early typed no-token/cancelled trace endings still omit source |
| Off-main encoding, write and snapshot | Existing serial MetricsStore writer; Timeline lazy span construction repaired | Timeline thread proof green; generic LatencyTrace snapshot placement still open |
| Per-session/turn lifecycle, required stages, nonzero events | Live/file stamps exist in AgentCaptureController, coordinator, frontend, speech buffer, Pocket and synthesizer | Isolated proof and current native five-turn baseline green; original cold duplicate remains open |
| Conditional lane/route stages | Existing VoiceStageSpan predicate requires lane on a miss and split-route boundaries; hit/single-mode exceptions preserved | Original-validator red→current-validator green; installed modifier and current native five-turn baseline green |
| Exact per-turn persisted stage proof | validateStore matches source+session+revision | Original-validator red→current-validator green; installed modifier and current native baseline green |
| Exactly one committed turn per counted run | oneRun passes its actual observed committed count; validator requires exactly one | Original native run 5 committed two; current warm five measured turns each commit once. Warm green does not close cold duplicate |
| One usage turn row and frontend pass rows joined by turn ID | Prospective turn reservation before speculative inference; strict actual pass/turn join | Original producer/installed native missing-join red; current copied producer and installed scripted/native checks green, with 18 native passes joined |
| Unavailable sub-reasons | Coordinator emits barrier_timeout/missing_latest_user/apple_unavailable and zero marker | Source wired; no new live unavailable/pipeline execution in this audit |
| Probe accuracy and named site attribution | Actual 200 ms probe case green in copied-source suite; ASR/island/echo/played/session wrappers exist | Probe accuracy green; no current real stall attribution or Instruments evidence |
| Full installed warm-up + five measured turns, tables and medians | Original and current actual file-fed runs retained below | Original median 4.776 s / 156 ms worst stall; current warm median 2.894 s / 35 ms worst stall. Current run is a diagnostic baseline; ≤0.9 s exit target is still unmet |
| EXPERIMENTAL catalogue entry, 600 s budget and AGENTS instructions | Root registered `selftest-voice-latency\|600` under EXPERIMENTAL and added the latency/controlled-input flags to AGENTS | Registered; no CORE/default promotion or latency exit claim |
| Actual attributed >100 ms stall fixed, island-on/off and regression list | No newly measured real user stall in this worker | Open; lazy snapshot thread fix does not substitute for this requirement |

## Phase 2 remaining work

P2-01 remains in progress until the full baseline and every task contract are verified.
Do not start P2-02…P2-08 based solely on instrumentation green. Current-source audit
confirms per-session `LocalVoiceTurnDetector()` construction and close at session end,
so P2-07 residency is still genuine work. The shared capture hub now has consumer-specific
callback bounds (meeting 256, others 8); P2-08 must re-read that producer and coordinate
external dictation/meeting ownership before changing it. Ducking, Smart Turn, speculative
append reuse and TTS pipeline gates require their own actual producer and physical/file-fed
proof; shadow VoiceSession greens are not these gates.

## Read-only duplicate-turn producer audit

The actual installed baseline `/tmp/nextnotes-agent-closure-voice-baseline.out`
contains a separate product failure, not just a validator failure. Run 5 commits
**two** turns from one 3.235 s haiku WAV plus its silence tail. Preparation takes
7.534862 s, and 60 chunks / 76,095 canonical frames await the local decoder.
Apple/VAD commits first. The local decoder subsequently produces the same captured
utterance at `sinceVoiceEnd 5.175s`; its endpoint interrupts the answer and commits
again. The original trace is the reproduction; no changed WAV, timeout or scoring
rule is proposed. This audit makes no after-fix claim.

The first broken contract is audio ownership across reset. `startEngine` retains
old captured chunks in the existing backlog while `LocalVoiceTurnDetector.prepare`
holds its operation gate. `emitTurn` calls `resetTurn`, which increments `turnEpoch`
and queues `resetForNextTurn`. That reset clears the decoder and installs callbacks
carrying the new epoch. Old backlog input then produces events carrying that new
epoch. The callback guard proves callback age, not input age. `noteModelEOU` turns
nonempty old words into fresh `heardSpeech`, final text and a new endpoint.

The capture seam already numbers chunks and records their delivery date, but
`noteAcousticLevel` receives neither. Its speech dates are MainActor receipt dates.
`TurnAudioSequence.current()` is not a committed utterance boundary: another
utterance can already be captured while the prior result or commit is delayed.
Filtering every old callback generation or every sample at/below that current
counter would erase valid next input. Apple `TranscriptionChunk` likewise retains
text/finality only; this audit did not change the shared transcription producer.

The actual checked-out FluidAudio `StreamingEouAsrManager.swift` establishes these
constraints, which matter before choosing a fence:

- Canonical Agent input is Float32 mono/16 kHz. Its converter fast path extracts
  those samples without rate conversion, so an input frame interval can use the
  original canonical frame count.
- `process` appends input, decodes 2,560-sample windows and shifts 1,280 samples.
  One input call can trigger several internal windows and callbacks. The current
  per-call capture timestamp or upper bound is not each decoded utterance's end.
- Partial and EOU callbacks run synchronously inside `processChunkAndDecode` on
  the manager actor. Token timestamps are 40 ms bins at this configuration.
  EOU timestamps are decoded shift counts at **confirmation after the existing
  320 ms debounce**, not last voice, source host time or a new utterance onset.
- Public getters expose token and EOU timestamps. EOU is latched once until reset;
  a getter after processing can recover that endpoint, but token state may already
  include later windows. It cannot timestamp each earlier partial by assuming all
  callbacks occurred at the end of the input call.
- `reset` removes buffered audio, token/EOU timestamps and the decoder origin.
  The remaining 1,280-sample overlap can contain a next utterance's first phoneme.
  Merely moving reset later does not establish preservation of that suffix.

The smallest implementable starting diff belongs in the two existing producers:
add canonical frame bounds to the existing backlog entry (keep its chunk sequence
for discontinuity detection), carry the identical stamp to acoustic observation
and detector processing, and retain an immutable decoder origin/input generation
under the detector's existing operation gate. Callback payloads must retain that
input identity, rather than receiving the epoch of whichever frontend reset happened
last. Reject covered input **before** raw latency marks, frontend staging or barge
effects. A reset request must name the closed input generation and boundary, so a
late request for A cannot clear a decoder already processing B. Reuse the existing
backlog and gate; no second queue/store, transcript heuristic, sleep or new audio
owner is needed for these metadata changes.

That starting diff is not sufficient by itself. It needs a verified, frozen end
of the utterance actually represented by the committed result. The newest input,
MainActor speech date, callback epoch, EOU confirmation timestamp and last token's
40 ms bin are not interchangeable boundaries. An operation-call upper bound is
only conservative provenance. The current source lacks the exact committed-range
contract; this audit does not claim a safe global-counter replacement. A synchronous
manager callback can obtain public timestamp state on its actual actor without
another await, but any implementation using actor isolation assumptions must pin
that vendor callback contract. No such implementation or compiler experiment ran
in this read-only audit.

A bounded alternative is to finish/reset the decoder at its own actual endpoint
and change decoder-owned input identity there, independently of frontend commit
time. This preserves B that was queued before A committed. It still requires the
same range proof and preservation of any buffered suffix above A's boundary; a
reset that discards that suffix is an introduced speech-loss bug. The two alternatives
must be selected using the following actual-producer fixture, not by text equality.

The minimum controlled regression uses a SelfTest-only suspension at the existing
prepare/process seam and numbered samples through the actual capture delivery,
backlog, detector and endpoint consumer:

1. Hold preparation, feed A and closing silence, let actual Apple/VAD commit A,
   then release the decoder. The original source must reproduce duplicate A;
   corrected behavior must produce one commit and no stale staging/interruption.
2. Hold A's slow result, retain its actual closed input range, and feed B's onset
   before A commits. Assert `A.end < B.start <= captured.currentAtACommit`, then
   release/reset/drain. Require exactly A then B, preservation of every B frame
   including its first phoneme, and B's real coordinator interruption of active A
   output. Also place B's first samples inside the decoder's retained overlap.
3. Repeat with a process already in flight, rather than only cold preparation.
   The queued reset must neither relabel A nor erase B; equality at the closed
   boundary and the first frame above it must have different admission outcomes.

The existing model-backed `--selftest-voice-rapid` remains required, but is narrower:
it waits for exactly one committed A before feeding B and asserts a nonnegative,
under-0.1 s commit-to-second-sample gap. It does not cover case 2. Keep the original
one-WAV baseline, rapid, session-cancellation/discontinuity and actual pipeline/duplex
regressions. The initial read-only audit edited/compiled no voice source; the
subsequent diagnostic application is described below. The duplicate product bug
remains open.

The controlled native support was prepared for root review in
`controlled-input-probe/proposed-support.patch`, with original/proposed producer
copies, SHA256 manifest and an exact three-case recipe in that directory's README.
Root has now applied the combined support/conductor and registered
`--selftest-voice-input-producer <haiku-wav> <stop-wav>` (cold-only by default;
`--voice-input-all` requests all three cases). Root app 12 compiled/installed and
ran the cold diagnostic green; this result is scoped below and supplies no
production fence or original-flow repair proof. The support keeps the actual native manager,
actual operation gate, actual backlog and actual callback/reset path; it manufactures
no transcript or EOU and emits no pass marker. The recipe explicitly covers held
preparation, B captured before A commits and B crossing the retained 80 ms decoder
suffix. The support does not supply a production frame fence or prove that suffix
preservation exists. The original review patches passed applicability checks;
they are retained snapshots and must not be reapplied to current sources. No
compiler/model run was performed by this worker; root's actual run is retained below.

The conductor's original review copy is retained as
`controlled-input-probe/NativeInputProducerConductor.swift.txt`. Its default selection
requires the original single-WAV held-prepare case first, real native EOU, actual
queued/granted reset observations, bounded labelled waits, full successful input
processing and exactly one delivered commit. The optional precommit/overlap cases
fail on absent preservation evidence. It checks the actual capture format and every
delivered buffer before comparing canonical frames to the inspected 1,280-frame
overlap. Failed native processing does not count as successful frame coverage.
Both continuations are released before awaited cleanup on every exit, and the prior
test handler is restored. Static review additionally repaired only the diagnostic:
held emit aborts if its captured session ended/changed or its task was cancelled;
cleanup snapshots tasks before releasing holders, joins them with the existing
capture-finish bound after session teardown, and stops further cases on a failed
join. B requires a `.localEOU` commit and a B-associated native endpoint before that
commit, so Apple's wording cannot masquerade as native preservation. Ordinary
default-nil production behavior is unchanged. Scoped whitespace checks pass.
Root's app 12 cold diagnostic is green without a producer fix; the original-red
repeatable flow and precommit/overlap cases remain unverified.

### Installed cold diagnostic: admitted old input, narrower consumer flow

Root's installed app 12 ran the same haiku PCM/tail with the held-prepare support.
The raw logs are `controlled-input-probe/installed-native-cold-12.out` and `.log`.
Its manifest binds those exact logs and frozen build-12 source hashes to installed
binary `a35a883bee7666030975ee28960ca62cf958c9a158be71978b8254f2490b488c`.
It reports `NATIVE_INPUT_OK`, one delivered commit, one native EOU and all 60
capture/process intervals. The initial VAD commit occurs at captured frame 69,695;
after its reset, native input `[63295,64575)` produces an EOU callback carrying
fresh frontend epoch 2. `callback.eou.handled` and a second `capture.reset` follow,
with **no** second `commit.selected` or `commit.emitted`. Thus old input was still
admitted by the original producer and subsequently discarded. The shadow trace's
`inputWithdrawn` agrees with a discard; it is not producer rejection. No production
provenance fence was introduced, and this green cannot resolve the original bug.

The diagnostic changes two material parts of the original consumer flow:

- `beginInputProducerFixtureForTesting` installs `turnHandlerForTesting` and calls
  `beginFileSession(... prepareResources: false)`. The actual emitter delivers to
  that sink instead of `RealtimeAgent.handle`; frontend staging and speculative
  preparation explicitly skip while a sink exists. It produces no actual reply,
  playback reference, speaking phase or real reply interruption. Pocket playback
  preparation still occurs, but preparing it is not audio delivery.
- The support waits for real native load/prime to reach its held checkpoint **before**
  starting the WAV, then releases after the unchanged WAV/tail completes. Its
  reported 7.664531 s preparation includes that held interval. Actual first-input
  processing lag is 4.757658 s, versus the original run 5's 7.523829 s; native EOU
  is 2.645 s after source voice end, versus 5.175 s originally. Similar total
  prepare numbers do not establish the same ordering relative to a real reply.

In the installed diagnostic, every stale native partial logs `apple=false`, and
the EOU reports Apple revision age `none`. Original run 5 logs `apple=true` for
those partials and revision age 3.959 s at the EOU. Original retained run 5 also
contains actual first-token/TTS spans before the late endpoint, a second emitted
local endpoint and an 8 ms barge-to-stopped span; it ends with two commits. The
diagnostic therefore differs in both live response state and the late Apple state
presented to the existing text policies.

There is no special recording-sink discard in `noteModelEOU` or `tick`: a nonempty
EOU marks speech, fills `modelFinalText`, marks EOU and schedules the actual tick.
At tick, before emission, the ordinary no-words, backchannel, in-flight repeat,
playback-echo and committed-revision branches can discard and reset. Fresh session
startup clears playback references; the sink starts no thinking request or output;
the native haiku request is not a short backchannel. These facts make the existing
committed-revision guard the strongest source-consistent explanation for this
particular reset. **The exact branch is not confirmed:** the captured event trace
does not record its reason or the selected first text/committed prefix/filter
result. No branch or transcript value is invented from the green marker.

A repeatable original-red regression must retain the original actual consumer:
same haiku/tail, normal frontend/speculation path, actual streamed response and
acknowledged playback, with old A arriving after A's commit while that reply is
still active. A harness-only prepare release tied to observed playback acknowledgement
can control that ordering without a production sleep or timeout change; it still
must demonstrate the original duplicate before any repair. Record the actual
selected/emitted A snapshot, cumulative Apple revision/prefix state, native input
interval/epoch, discard reason and thinking/speaking state at the stale callback's
tick. The existing timeline can retain discard reasons or a `discard_after_endpoint`
note, but this conductor does not currently print them. Restoring the real consumer
alone does not guarantee red: the Apple/text-policy state and relative playback
ordering must be measured rather than forced to pass by changing text guards.
The original-red fixture also needs a common input-clock proof: canonical capture
frame intervals must map to the actual converted Apple input time and selected
`SpeechTranscriber.Result.range`, while native process intervals retain the same
capture origin. Neither the callback's Date nor its epoch establishes that the two
recognizers represent the same A input. This metadata is currently discarded and
requires a separately reviewed diagnostic seam; it is not available in either log.
Only then can the same regression verify producer rejection and zero stale staging,
interruption or second delivery after a fix. Native B's initial “Wait” and complete
precommit/overlap input preservation remain separate required acceptance cases.

### Native boundary follow-up: confirmation is not an owned-audio cut

**The proposed use of the native consumed/confirmation cursor as A's end is
withdrawn.** It is decoder bookkeeping, not a verified utterance range. The
existing public FluidAudio API does not provide the boundary needed to discard
old A while guaranteeing preservation of B captured before A commits. No
production fence is authorized or applied. This finding does not narrow the
duplicate-turn or full-duplex acceptance contract.

The inspected dependency is FluidAudio 0.15.6, pinned in `Package.resolved` to
`4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b`. The following contracts come from that
exact checkout, not a newer API description:

| Producer / source lines | Actual contract | Boundary limit |
|---|---|---|
| `StreamingEouAsrManager.swift:155,250–273` | Partial/EOU callbacks carry a cumulative `String`; separate getters return lexical-token and EOU timestamps | No callback carries an input range, exact endpoint frame, buffered-tail identity or consumed-prefix acknowledgement |
| Same file, `300–325,655–677` | New **lexical tokens** clear the EOU debounce anchor. Confirmation occurs after 320 ms of shifted decoder input and records `totalSamplesProcessed / 16` milliseconds | Absence of a new token proves neither silence nor absence of B's initial phoneme; the recorded time is confirmation, not A's acoustic end |
| Same file, `445–472` | A process call appends its entire input, evaluates 2,560-frame windows and removes 1,280 frames after each decode/callback | The call's upper frame bound includes all appended input; callbacks precede that window's removal; processing continues after an EOU callback |
| Same file, `630–645,649–655,681` | Lexical timestamps use `processedChunks * 2` plus the emitted encoder frame, in 40 ms bins; partial callback precedes the shifted-count increment | Lexical emission bins are not word/phoneme spans. The partial's timestamp state and EOU confirmation state refer to different points in the loop |
| `RnntDecoder.swift:5–11,90–126` | Decoder visits encoder frames in order. EOU sets a Boolean and breaks the frame loop; only lexical emissions retain their frame index | The actual EOU symbol's encoder index is discarded. Even exposing it would locate a model symbol, not prove the source-audio onset/end of a different utterance |
| `StreamingEouAsrManager.swift:509–524` and `StreamingAsrUtils.swift:49–56` | Reset removes the entire audio buffer, accumulated tokens/timestamps, shifted origin and decoder state | Reset loses any already-decoded or buffered B unless its complete uncommitted input is retained elsewhere in the existing seam |

For `.ms160`, let `k` be the zero-based window index and assume contiguous
canonical 16 kHz input since reset. The current window spans
`[origin + k*1280, origin + (k+2)*1280)`. After decoding, the confirmation cursor is
`origin + (k+1)*1280`; the lexical bins are `k*80 + t*40` ms for encoder indices
`t = 0,1`. Thus the encoder has already received 80 ms beyond that cursor. More
importantly, B may have begun **before** the cursor without yet emitting its first
lexical token. The 320 ms debounce does not rule that out. Retaining only frames
strictly above the cursor or replaying only the final 1,280 frames therefore has no
proof of preserving B's first “Wait.” A later process call can also have decoded
more B before the queued frontend reset acquires the existing operation gate.

Apple has a different, actual represented-input capability. SDK 26.2's Speech
interface exposes `AnalyzerInput(buffer:bufferStartTime:)` at lines 293–299,
`SpeechTranscriber.Result.range` / `resultsFinalizationTime` at 495–497, and the
`.audioTimeRange` attribute option at 459. A result's range identifies the input
audio to which that result applies; text attributes can retain the source-audio
range of a text run. Those are represented-result ranges, not a claim that an
entire phrase range is the exact last voiced sample. See Apple's
[result-range contract](https://developer.apple.com/documentation/speech/speechmoduleresult/range)
and [time-range text attribute](https://developer.apple.com/documentation/foundation/attributescopes/speechattributes/timerangeattribute).
The app currently drops these values: `AppleSpeechEngine.swift:77–81` emits a
flattened cumulative text snapshot, `121–127` merges finalized/volatile text,
`180` requests no attributes, and `96` supplies no explicit input timestamp.
`AgentCaptureController.swift:1903–1904` advances its Apple cursor to the latest
cumulative text, which is not necessarily the snapshot selected for A if B arrived
before that commit. A correct timed-result change must freeze text and represented
range together at selection, and retain B's later timed runs.

An explicit Apple timestamp must be based on the actual converted stream, with
its canonical mapping checked. Apple requires nonoverlapping, increasing input
ranges and warns that conversion priming can invalidate the original buffer's
start time. The observed 16 kHz Float32-to-Int16 baseline avoids rate conversion;
that observation is not a general proof for other capture formats. See Apple's
[buffer timestamp contract](https://developer.apple.com/documentation/speech/analyzerinput/init(buffer:bufferstarttime:)).

The smallest **conditional** producer change is still input provenance through
the existing backlog/detector seam, but a complete safe fix additionally needs:

1. A frozen selected A result with a verified represented-input cut below **all**
   B frames. For an Apple/VAD-selected A, retain the actual selected result range
   and capture-side acoustic interval rather than using the newest speech date or
   capture counter. For a native-selected A, the inspected public API is missing
   a usable source-audio ownership boundary; confirmation/token bins cannot supply
   it. Any new vendor endpoint/suffix API must be identified as a new change and
   validated, never assumed to exist.
2. Complete retention of uncommitted canonical PCM inside the **same bounded
   backlog**, with a processing cursor instead of today's destructive `take()`
   (`AgentCaptureController.swift:54–60`). Selection of retained input, reset and
   callback-origin assignment must share the detector's existing operation gate.
   A reset for A must not clear B's origin/state; replay must include B already
   processed before the reset, not only B still queued or the last 80 ms. A bound
   overflow remains an explicit discontinuity, not silently successful coverage.
3. Admission using that immutable input identity before latency stamping, frontend
   staging or barge effects. The frontend epoch and the latest capture counter
   remain insufficient. This introduces no new audio owner, model pass, delay or
   gate; replay/reset cost and duplex behavior still need measurement.

These are requirements for a candidate diff, **not an implemented algorithm or a
claim that the missing native boundary is solved**. The prepared native conductor
must first reproduce the original cold duplicate, then exercise B's initial
“Wait” before A commits and inside the native retained window. Passing requires
both exact input-interval preservation and that initial word in the actual native
B result; interval accounting alone or a scripted transcript cannot establish it.
Cases 2/3 remain unrun and may expose the present loss mechanism. That boundary
audit changed no Swift source. The subsequently applied diagnostic and narrow
self-test cleanup/verdict changes above do not implement a production fix; no
compiler, model, production timeout, threshold or fixture audio was changed.

## Root installed verification and first native baseline

The installed instrumentation modifier passes (`installed-instrumentation-green.log`); installed metrics and store isolation also pass. All six synthetic WAVs were generated outside the repo at `/tmp/nextnotes-agent-closure-voice-fixtures`, including the checked pause fixture. The original full warm-up plus five measured native turns is retained at `installed-five-turn-baseline-red.log`. It fails rather than relaxing its assertions: median speech end to first audio **4.776 s**, worst observed main-actor stall **156 ms**, no speculative model-pass join for each of the five measured turns, and two commits/missing EOU stages/VAD fallback in measured run 5. These are actual pipeline results, superseding the earlier pending-only audit.

The run also exposed a harness observer error: session startup replaces the playback callback, while oneRun had installed its observer before startup. The corrected harness attaches after startup and preserves the production consumer. It now checks the actual playback acknowledgement and reads feed/progress/endpoint state at completion rather than from an initial snapshot or after teardown. This fixes measurement; it claims no product latency gain.

The missing IDs were traced to `prepareResponseIfUseful` starting speculative inference without its prospective turn correlation. Native recorders capture IDs before final commit; adoption cannot retrofit them. Commit `bdd9766` reserves the existing prospective turn ID before inference and preserves it through revisions/commit, plus a correlation check on speculation adoption. The copied original producer compiles and fails the strict join; the current producer compiles and passes. Installed scripted recorder checks pass five cases, including exact reuse and changed-correlation rejection. See `usage-correlation-before/README.md`.

The unchanged warm-up plus five native turns rerun passes the baseline validator: all five measured turns have one commit, local EOU, a playback acknowledgement and model-pass joins with matching conversation identity. Across 18 native passes, no turn identity is missing. Median speech end to first audio is **2.894 s**, p90 **3.729 s**, and worst measured main-actor stall **35 ms**. No 0.9 s target was supplied to this diagnostic run: it is baseline evidence, not the latency exit gate. Raw evidence is retained in `usage-correlation-before/installed-five-turn-current-green.log` and its report. Warm preparation did not exercise the original cold duplicate or establish the cause of the original 156 ms stall.

The duplicate commit remains open. Reset can rebind queued old audio to new decoder callback identity while preparation holds the existing operation gate. A safe repair requires the committed utterance's input end, preserving later captured input; the newest capture counter is not that endpoint. Main-actor stall attribution/fix and every prescribed Phase 2 latency target also remain open.
