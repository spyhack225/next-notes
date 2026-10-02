# Executed status — P6-05k bounded diagnostic prerequisite

Corrected original90 fails149 feature assertions (pure79 + Manager35 + receipt35); identical corrected common fixtures pass installed fixed91 worker1352 and all20 related flags. Source/full bundle remain invariant. This worker independently reviewed retained source manifests, unchanged97-check pure fixture and actual current diagnostic traces; it performed no native runs. See [independent review](independent-executed-review.md), [exact review pins](independent-executed-review.json) and the [root verification report](../heartbeat-integration-review/verification.md). Initial88/89 remain invalid complete-flow evidence; historical preparation below is preserved. Parent P6-05, stale decisions, event/periodic activity, recovery/retry/IM-16 and aggregate gates remain open.

---

# P6-05 pure heartbeat age policy prerequisite

Prepared actual new Source TaskHeartbeat.swift and TaskHeartbeatSelfTest.swift, restricted to pure values. Source is frozen on the fixed body; root must mount the retained original full snapshot before original88, then restore fixed for89. The common97-check pure fixture is byte-identical across both. No compiler/native/model/build/staging was run by this worker.

The original is an explicit missing-feature scaffold: ageWindowSeconds returns nil and classify returns unknown(missingHeartbeat). It is not a stale bug or a substitute old production failure. Full original bytes were retained before writing the fixed body; diagnostic types/name/default evidence and identical test inputs are common. The producer patch changes only the two policy function bodies. Parent P6-05 remains open.

## Exact API and contract

- TaskHeartbeat.classify(status: AgentTaskStatus, runtimeClass: TaskRuntimeClass?, heartbeatAt: Date?, permissionWait: Bool? = nil, now: Date) -> TaskHeartbeatAge.
- TaskHeartbeatAge is Equatable/Sendable: excluded, waitingOnPerson, unknown(TaskHeartbeatUnknownReason), withinWindow(age:window:), ageCandidate(age:window:). Its diagnosticName is only a case label, never a timestamp or health verdict.
- TaskHeartbeatUnknownReason: missingRuntimeClass, missingHeartbeat, invalidClock, futureHeartbeat.
- TaskHeartbeat.ageWindowSeconds(for:) returns roadmap starting diagnostic windows30/300/300/900/1800 seconds; waitingOnPerson returns nil. Exact equality is an age candidate. These constants are not failure/retry deadlines or measured health guarantees.
- TaskHeartbeatEvidence independently carries processAlive/backendSessionAlive/toolInFlight/receiptCreated TaskHeartbeatFact unknown/yes/no values, defaulting all to unknown. The age policy never observes or reconstructs them. Callers must use actual current producers; LAST return/nil, outgoing pendingCount0, receipt-link absence and Process.isRunning cannot establish comprehensive health/no-effect/safe retry.

Precedence: terminal/queued/recovering => excluded first; waitingForPermission/CompatibilityCLI/Input => waitingOnPerson; running true current Gate wait or waitingOnPerson class => waitingOnPerson; missing runtime/beat => unknown; nonfinite clock/beat/elapsed subtraction => invalidClock; future beat => unknown; otherwise withinWindow or ageCandidate only. True Gate excludes ages conservatively by task ownership; false/nil do not prove absence of every human interaction. No state changes, timers, tasks, queues, registries, stores, I/O, retry or foreground awaits exist here.

## Focused proof and limits

The common fixture has97 checks: all five windows at zero/before/exact/after/40days/missing/future; excluded status precedence; 40day waiting permission/input/compatibility; waiting class and Gate exclusions; invalid/future/overflow clocks; missing runtime; payload-free diagnostic labels; unknown/default and explicitly supplied current facts. Static prediction is original79 missing-feature failures and18 passing controls, fixed97 green. These are not executed verdicts. Exact count breakdown and hashes are in preparation-manifest.json.

Register TaskHeartbeatSelfTest.cases(check: check) through the existing root-owned worker flag. Prior worker1161 plus pure97 predicts1258; root-owned actual Manager diagnostic integration checks are additional and intentionally not counted here. Root must verify the same pure original/fixed fixture, actual fresh-primary/Gate/runtime/receipt diagnostic consumer, nonmutation, and related flags before claiming bounded completion. A helper-only pure pass cannot prove Manager integration or stale policy.

No periodic/event beat generation or parent stale engine is implemented. Current process/session observations remain samples, complete in-flight/receipt/effect coverage stays unknown where unavailable, and recovery/retry/IM-16/quick/full/owner/privacy/permission/latency gates remain open.
