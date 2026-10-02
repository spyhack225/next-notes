# Current typed ACP terminal-save fixture handoff

Root reports integrated app60 worker678 and all20 focused flags PASS. These are root's
reported results, not runs by this audit agent. Current source has typed ACP attempt
admission and receipt/isStillValid routing; the terminal record Bool remains unchecked.

`TaskACPUnverifiedReceiptSelfTest.swift` is a complete **off-source, unbuilt, unrun**
fixture for root to copy/register in the existing worker flag before its original
broker61 run. Call:

```swift
try await TaskACPUnverifiedReceiptSelfTest.originalCases(root: root, check: check)
```

The Swift file embeds the byte-equivalent owned peer body using a Swift raw string.
All varying values, including the actual Manager-produced task ID, are written as
sorted JSON to sibling config.json by the existing backendEntryForTesting seam. No
JSON value is interpolated as a Python literal. The peer source was parsed with
Python ast; that is the only verification performed here. Root must compile/run and
freeze unchanged actual fixture bytes before repairing the producer.

Both modes use the same objective/reply and Manager -> Registry -> ACPBackend ->
ActionOrchestrator -> ACPSession -> owned Python peer production path. Only the mode
selects whether the peer damages its temporary receipt source before its real reply.
At actual session/prompt the peer queries the real temporary SQLite in read-only mode,
asserts running taskID/attempt1/currentPID/acpWorker/start metadata, and reads the
already committed fired receipt with the exact same task ownership. No model/account,
owner-store, repo checkout scan or activity/permission update is used.

Assertions cover actual Manager entry/exit, exact captured context/receipt injection,
fresh primary ownership at backing, fired identity/prepared routing/tool, accepted
receipt result/artifact/verification persistence, rejected exact retained bytes/state,
actual terminal memory/fresh SQL/journal/announcement and fresh-manager no replay.
The Swift comparison canonicalizes receipt Date representation only because the
existing writer persists ISO8601 seconds; it does not manufacture a receipt result.

Current ACP does not have the typed-local TaskDurability.receiptIDs join. The fixture
pins its empty join and exact optional receipt attempt/owner separately. It establishes
neither local effect admission joins nor ACP recovery/receipt reconciliation/retry.
Changing this assumption requires rereading the producer before freezing the case.

The damaged mode moves exact fired bytes to retained-fired.json and mkdirs the old
source before responding. Both the interim couldNotVerify and final record refuse.
The source's ignored final Bool is the candidate producing false task completion;
this is not a claim that the fixture isolates only the last filesystem syscall.

The peer writes exceptions to peer-stderr.txt; Swift prints bounded stderr diagnostics
on timeout/error and after each case, including empty stderr for a clean peer. Bounded
Task.yield waits and same-manager cancellation attempt to drain the same owned worker
on exceptional exit. No fixture-owned native process was run by the audit agent. Root
retains its wrapper watchdog/owned-peer cleanup responsibility if draining fails.

Predicted original RED is three damaged-case verdicts: task completion after rejected
terminal save, successful task/result delivery, and missing action-ran/result-not-saved
failure. Record real names/counts rather than treating this prediction as evidence.
Accepted behavior and all shared invariants should stay green. Root's original/fixed
same-input run and related flags remain necessary; no product bug is yet marked fixed.
