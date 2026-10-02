# Stale dictation metric-tail regression — historical preparation, original red observed

Root app 14 subsequently ran the actual original controller/protocol and failed
with all seven errors retained: five metric-tail/lane-wait targets and two additional
timing/capture failures. See [the installed original report](2026-10-01-installed-original-red.md)
for exact logs, binary/source hashes and executed registry. Root applied the exact
protocol getter requirement and post-metrics session guard afterward; installed
app 17 now passes the unchanged Dictation, usage-log and store-isolation checks.
Five targeted assertions are green; the two additional timing/capture checks
passed this run without a causal repair claim. This reporting worker changed no
Sources file and ran no compiler/build/native test.

The sections below preserve the original preparation rationale and proposal;
their then-pending statements are historical, superseded by the installed report.
The getter requirement was subsequently justified by an independent copied
original-red/current-green dispatch regression and actual installed disk-usage red;
it was not added solely to make the suspension fixture convenient.

## First source contract that may break

`runTail(session:audio:)` validates its captured generation immediately after actual insertion and publishes the actual receipt. It then awaits the engine actor's `startLaneWait` before assembling locally captured usage rows. After that actor hop, `finishIdle`/`fail` read and clear the controller's current mutable audio/state/outcome identity without checking whether it still owns that generation.

Actual cancellation increments the generation and reports the old cancellation. The next accepted hold mints a new ID, owns the shared microphone subscription, and enters starting/listening. If the old actor read resumes afterward, the old outcome switch can call `finishIdle(.inserted)` against those new fields: the successor's capture unsubscribes, state goes idle, and an inserted outcome is incorrectly attributed to its fresh ID. This remains an unverified source hypothesis until the original actual-controller fixture produces the failure.

## Faithful suspension, without changing the producer seam

The current `startLaneWait` is an actor-isolated protocol EXTENSION property returning zero, not a protocol requirement. A conformer's overridden async getter is not a witness for the existential call, so such a fixture would test the wrong contract. Do not add a production protocol requirement merely to make this regression convenient.

The prepared fixture uses the existing actual controller/real shared microphone/scripted-engine/injected-insert seams. Its wrapper engine actor is parked by a test-only externally released semaphore during the first injected insertion. A cooperative async continuation would permit actor reentry; it would not suspend the real extension read. The fixture waits for the actual first receipt plus parked actor plus finishing state, then cancels and starts the successor. It requires actual successor listening/capture before releasing the old actor.

The barrier is bounded at 15 seconds and released on every exit/defer. No wait, timer, queue, store, model pass or gate is added to product execution. It runs alone in the coordinator's serial native slot and retains the original microphone requirement. If the suspension/actual capture cannot be reached, it reports an unverified regression as failure, never success.

## Before/after assertions

Original expected failure: `STALE_METRIC_TAIL: old inserted tail cleared successor capture/state`, a prematurely inserted successor outcome, missing successor final insertion or wrong hold attribution.

Required fixed contract: old locally captured ASR usage remains under the old run ID; the old cancellation and successor inserted outcome each occur once; the successor remains listening/capturing until its own release; next receipt is the exact successor ID; two actual insert callbacks occur. Usage uses its own new temporary UsageLog instance and no owner store.

`/tmp/NextNotes-ux08-stale-tail-regression.swift.txt` supplies the root-owned runDictationSelfTest block and file-scope helpers. Existing delayed-insertion cancellation and every original case must remain unchanged.

## Minimal proposal after original red

`/tmp/NextNotes-ux08-stale-tail-proposal.patch` adds one generation guard AFTER the existing usage block and immediately BEFORE the actual outcome switch. This preserves the old locally captured usage rows even after cancellation, while refusing to finish/fail another hold. It adds no await or policy gate. Do not apply/claim fixed before the actual old-flow regression is observed and then rerun against the change.

Actual target insertion/readback, displayed frames, physical latency/duplex and full UI first-success remain separate evidence. This fixture intentionally replaces insertion effects and records no owner history.
