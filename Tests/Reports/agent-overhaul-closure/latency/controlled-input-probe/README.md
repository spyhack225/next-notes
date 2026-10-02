# Controlled native input/reset regression — cold diagnostic green, product bug open

Root applied `proposed-combined.patch` to the capture/detector sources and registered
`--selftest-voice-input-producer <haiku-wav> <stop-wav>` in `NextNotesApp` on
2026-10-01. This is a **diagnostic only**, with no production provenance fence or
duplicate-turn repair. Root compiled/installed app 12 and ran the native cold case:
`NATIVE_INPUT_OK`, one commit, one real native EOU, 60 captured/processed intervals.
The stale A callback was admitted under the new epoch, then discarded downstream;
the original actual-response duplicate remains open. Cases 2/3 are unrun. This
worker ran no compiler, model, build or installed flag. Raw root evidence is
`installed-native-cold-12.out` and `.log`; see the flow-mismatch analysis in the
parent latency report. `source-manifest.json` binds those exact logs and archived
root `build12-source-inputs.json` to installed binary
`a35a883bee7666030975ee28960ca62cf958c9a158be71978b8254f2490b488c`.

`prepare-controlled-input-probe.py` originally generated the review patches from
the clean capture/detector sources; original/proposed copies and hashes are retained
beside them. The patch files now record that review snapshot. Do not apply them
again or regenerate them over the applied sources.

The original conductor review copy is `NativeInputProducerConductor.swift.txt`.
`proposed-conductor.patch` recorded an append **after** the support patch; root
applied the single `proposed-combined.patch` alternative. Its entry point is
`AgentCaptureController.runNativeInputProducerFixtureSelfTest(first:second:coldOnly:)`.
The default `coldOnly: true` runs the original one-WAV native regression first;
`false` attempts all three and exposes missing overlap/preservation evidence as
failures. The registered flag defaults to cold-only; `--voice-input-all` requests
all three. Root owns compilation, isolation guards and the final flag marker. No
native case has been executed by this worker; root's cold-only result is above.

This first conductor was intended to characterize the native reset failure. Its
cold case instead passed without a fix: the recording sink supplies no actual
frontend or reply, and an existing downstream text discard absorbed the old native
event. It verifies the stale-input/reset seam, **not an original-red regression**.
If the eventual fix rejects covered A frames before decoding, requiring
the old native A endpoint afterward would be wrong. Its green contract must instead
account for those exact frames through real producer rejection observations, verify
actual native load/prime and a native B control, and retain the same WAV/hold/commit
scenario. An absent model or unobserved input must still fail. No rejection mechanism
or green characterization is invented in the current artifact.

The support adds two harness-only pause points and metadata observation. The
detector still loads and primes real FluidAudio/Core ML models and receives real
PCM; nothing manufactures a word, partial, EOU or detector decision. Preparation
pauses **after** load/prime/reset while its actual operation gate remains held.
This deterministically reproduces the backlog/reset ordering; it does not measure
cold model load time. A commit can pause after the real tick selects eligible text
and before the real emit/reset path runs. Both hooks require an explicitly supplied
probe under `SelfTest.isRunning`; default production operation does not await them.

Captured samples receive half-open canonical frame intervals through the actual
delivery closure. The same actual backlog sequence selects the recorded interval
when the real detector processes that entry. Events observe native callbacks,
captured callback epoch, selected/emitted commit, and actual reset request/grant/
completion. The interval accompanying a callback is its **process input call**;
it is deliberately not labelled a decoded utterance or exact EOU range. The probe
stores metadata and continuations only, never a second PCM buffer or audio queue.

The support emits no OK/FAILED marker and supplies no production provenance fence.
The conductor returns labelled failures, restores the previous handler and releases
the two continuations synchronously before awaiting cleanup on every exit. Cleanup
retains the existing task handles before release, joins them after session teardown
with the existing capture-finish bound, and stops later cases if any join fails. It checks
the actual capture format and each delivered buffer. It requires real native EOU,
contiguous captured intervals, exact completed process intervals and bounded event/
frame waits. The callback interval remains its process-call bound. It neither uses
the EOU confirmation timestamp as a speech end nor manufactures native events.
The root's flag must emit one final failed marker whenever a required stage is absent.
Use the existing isolated app self-test launcher/store guard. Do not use the owner's
task/conversation stores or launch a cloud model.

## Case 1: original held preparation / one utterance

1. Save the existing `turnHandlerForTesting`; call
   `beginInputProducerFixtureForTesting(wav: haiku16k, holdPrepare: true,
   holdFirstCommit: false, committed: recordingSink)` on the actual shared capture.
   Use a bounded wait for `prepare.held`; failure to reach it is a failure, including
   missing/corrupt native model assets. This does not silently use a fake decoder.
2. Call `startInputProducerFixtureFeedForTesting`. Wait for actual VAD emission and
   its recording sink, then await `fileSessionProgress.feed` completion. Require
   exactly one initial commit, its real endpoint source `.vad`, zero dropped chunks,
   contiguous capture intervals and a queued `reset.requested` before preparation
   is released. The original haiku file/tail enters unchanged.
3. Call `probe.releasePrepare`. Wait for `prepare.ready`, `reset.granted` and a
   **native.eou** associated with an actual process interval captured before that
   initial commit. Wait for all captured intervals to reach process.end and drain
   the scheduled MainActor EOU/turn handler. Assert the recording sink still contains
   one turn and no second commit.emitted. The old producer should fail here by
   accepting old input through a freshly installed callback epoch. Preserve the
   original installed cold trace separately; this controlled hold does not replace
   its real timing measurement.

## Case 2: B captured before A commits

1. Start a fresh session with held preparation **and** held first commit. Start A;
   wait for commit.selected. That event freezes the test's A input prefix at
   selection; it is a fixture boundary, not a proposed production utterance fence.
2. Start `feedInputProducerFixtureSecondForTesting(wav: stop16k)` in a task. That
   actual method cancels/awaits A's remaining tail, labels the next input B and uses
   the same capture delivery closure. Wait for at least one real B buffer to be
   captured, then release the first commit followed by preparation. Keep feeding B.
   Await its task and native decoder drain.
3. Require `A.selectedCapturedEnd <= B.firstFrame < B.firstEnd <=
   A.emittedCapturedEnd`. Thus B physically arrived before A's actual commit.
   Require exactly A then B, nonempty native endpoints, expected haiku/stop-speaking
   words, zero drops and complete ordered B frame coverage in process.end events.
   A fix using the newest capture counter or commit-assigned chunk generation will
   fail this case even if the ordinary postcommit rapid probe passes.

## Case 3: B begins inside the decoder's retained 80 ms overlap

1. Start fresh with `holdPrepare: false, holdFirstCommit: true`. Wait for native
   prepare.ready before starting A. Require the real local EOU to select/hold A's
   first commit. Cancel A's tail and start B with the same second-input method.
2. Keep A held until one B process.end exists and the actual decoder buffer suffix
   intersects B. Compute that suffix from the real completed input intervals since
   the most recent reset: for `N` contiguous canonical frames, shifted frames are
   zero below 2,560; otherwise
   `1,280 * (1 + floor((N - 2,560) / 1,280))`. The retained half-open interval ends
   at the last submitted frame and starts at origin plus shifted frames. This is
   the inspected `.ms160` manager's actual buffering rule, not the EOU timestamp.
   Fail if inputs are missing, discontinuous, or no B overlap was exercised.
3. Release A's commit. Observe actual reset.granted/completed under the existing
   operation gate. For every B frame retained immediately before a reset, require
   it to remain in the decoder or be truthfully resubmitted afterward through the
   real input seam before B's endpoint. A submitted frame that is then removed by
   reset is not preserved merely because it appeared in an earlier process.begin.
   Require the native B transcript to retain its initial “Wait” as well as
   “stop speaking”, two commits, zero dropped chunks and all B intervals accounted
   for. The support trace alone cannot prove an internal suffix was retained: the
   conductor must verify the actual proposed preservation mechanism too. No such
   production mechanism is implemented in this patch.

All waits need labelled bounded failures, not a timeout extension to obtain a pass.
Release both probe continuations in every error/cancellation cleanup **before**
awaiting `endInputProducerFixtureForTesting`, then restore the previous test sink.
Run existing voice-rapid, pipeline, cancellation/discontinuity and duplex regressions
after any eventual producer fix. The recording sink proves input/endpoint delivery;
it supplies no real frontend, audible output, physical barge or model quality proof.
The actual full pipeline must separately verify the original stale endpoint no longer
interrupts its reply. This native support is not a Phase 2 completion claim.

## Static applied-source review — not compiler or native evidence

The applied conductor shares the file's MainActor isolation and private capture
seams. Probe metadata is lock-protected; continuation release removes each waiter
under the lock and resumes it after unlocking. Locks inside the continuation setup
are in a synchronous closure. Optional/default-nil probe paths retain ordinary
production behavior. No definite type error was found by inspection; root's
subsequent app 12 compilation verifies the actual source's Swift 6 acceptance.

Static review found three diagnostic limitations. Root authorized narrow self-test
repairs; these are applied and frozen. Root app 12 compiled and ran the cold case;
precommit/overlap behavior and original-flow repair remain unverified:

- `endInputProducerFixtureForTesting` awaits the existing `endSession`, but
  `stopEngine` cancels and drops `turnDetectorTask` without joining it. Releasing
  both probe waiters prevents the held-prepare deadlock; it does not prove the
  native task has completed before the next all-case fixture starts. The diagnostic
  now snapshots decoder/VAD/handler/file/Apple tasks before releasing holders,
  joins them after teardown, reports any bounded-join failure, and stops later cases
  on that failure. The underlying ordinary production teardown is unchanged.
- The first applied held `emitTurn` continued after its test-only await without checking whether
  its session ended or its VAD task was cancelled. Failure/cancellation cleanup can
  resume that old emit/reset path while ending the session or restoring the prior
  handler. The supplied-probe branch now checks the selected session's identity,
  active state and task cancellation immediately after release; invalidated holds
  record `commit.aborted` and return before emit/reset. The default-nil path is unchanged.
- The first applied second-turn wording assertion required “Wait” and “stop speaking”
  plus **any** native EOU. It did not require the second turn's `.localEOU` source
  and a B-associated native endpoint. A native A event followed by Apple/VAD B can
  satisfy that wording assertion. Therefore it cannot establish native B preservation.
  Case 3's suffix-loss assertion still exposes the original reset, but case 2's
  future green needed to close this verdict gap. The conductor now requires B's
  `.localEOU` source plus an actual B-associated native event before the second
  emitted commit. No native preservation pass is claimed.
