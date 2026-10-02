# ACP startup receipt join review — unexecuted handoff

Scope: typed normal ACP Manager dispatch only. Root owns original63/fixed64 native verification and Source integration. No Source/native/build/model/subprocess run was performed by this review agent.

## Confirmed source gap

Current ACPAgentBackend.runSessionWithReceipt fire receives the real prepared action UUID after ActionRuntime has committed its .fired receipt, but directly captures workspace/starts the process without TaskEventJournal.toolStarted. Manager.journalContext routes ordinary positively owned ACP through a generic event-only branch, bypassing the existing local exact receipt validation, receiptIDs join and admitted activity transaction. Consequently original code emits no startup event or task receipt link. This is source evidence of the missing capability, not a claimed native regression verdict.

## Root proposal reviewed

root-producer-proposal.patch in sibling acp-receipt-start-review adds toolStarted(taskID:tool:receiptID:prepared.id) before workspace capture/process entry and removes ACP's early generic branch so hasWorkerAttemptRecord reuses the exact saved .fired receipt validation and existing task snapshot/event transaction. Exact UUID/attempt/current lease/prepared routing/tool checks are preserved. Rejected admission throws the existing not-run error before the process. No new schema, queue, store, query, await or timer. This necessarily adds ACP's previously missing startup primary transaction; it is not evidence of unchanged whole-history save latency. The LAST entryAdmitted observation follows committed admission and does not establish process health, externally confirmed effect, complete active-call coverage or cessation. ACP toolCompleted producer remains absent/open.

## Actual fixture

TaskACPReceiptStartSelfTest.swift.txt uses injected safe temporary real TaskStore/AgentTaskStore/ActionReceiptStore and actual Manager -> Registry -> ACP backend -> owned Python peer. It preserves the objective used by the existing primary fixture and uses identical objective/marker/peer in both modes. The only rejected-mode intervention is a BEFORE INSERT toolStarted trigger installed at the existing backend-entry seam after positive primary attempt admission. No invented receipts, synthetic contexts, fake backend, direct callback proof or owner store reads.

The peer reads its sibling config.json, verifies only owned temporary database/receipt paths, snapshots the actual saved fired receipt bytes and exact primary/task events at process startup, then answers legitimate initialize/new/prompt with one valid session/update. It deliberately does not require a join/event inside peer code: original missing facts remain observable data and the unchanged original protocol can complete. A peer exception, missing accepted snapshot/protocol, or deadline failure invalidates the harness rather than masquerading as product proof. Generic diagnostics retain only mode/state/counts/booleans.

Accepted assertions require the exact real saved receipt UUID in the primary row before process protocol, exactly one matching toolStarted event, retained UUID in terminal memory/SQL/fresh actual Manager, and unchanged actual unverified result/artifact delivery. Rejected assertions require zero peer launch/requests/snapshots, rolled-back join/event, real failed receipt with its retained fired event, exact not-run failure, no result/artifact/success delivery, and no fresh-manager replay. Fired evidence is never generalized into confirmed external effects; missing join is never a retry authorization.

Normal fixture count is 30: common eight per mode + accepted eight + rejected six. Two exceptional cleanup call sites only execute on timeout/error and are not counted as the normal feature extension. Syntax/native verdict is UNCOMPILED/UNEXECUTED. Preserve fixture bytes for original/fixed; native counts and verdicts remain authoritative.

registration.json appends one call after the current unverified receipt fixture without changing any previous assertion/input. Root already owns the reviewed expectation upgrade in TaskACPUnverifiedReceiptSelfTest: the single old emptiness predicate is now exact [fired.actionID.uuidString] and final IDs equal primary IDs; all terminal/result/byte predicates remain. Prior original61/62 evidence is preserved. TaskACPPrimaryAdmissionSelfTest contains no receipt-emptiness assertion requiring change.

## Dependencies and limits

Requires root62 ActionRuntime guarded unverified receipt persistence and 1675da8 ordinary ACP exact live context admission. Parent P6-05/P6-06 contracts, fixed quality/privacy/permission/latency gates, explicit continuation/recovery policy and IM-16 remain open. Compatibility one-shot, scheduled/remote/voice authority, nested permission provenance/current client after awaits, full session activity authority and ACP completion admission are not expanded. Original/fixed native producer and actual-consumer verification must run before any completion claim.
