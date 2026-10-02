# Verified bounded P6-06p — original82/fixed83

Actual original82 RED4 → identical fixed83 worker1092/all20 focused flags PASS. [Verification and limits](verification.md) is current. The off-source handoff below remains preparation history, not native proof.

---

# P6-06p: nested ACP review metadata — off-source producer proposal

Prepared only: **no Source application, Swift compilation, peer execution or native verdict by this worker**. Root must capture the actual original failure before changing Session. The standalone fixture and common n/o amendments are frozen off-source for independent review. Existing n/o evidence packages remain unchanged.

## First broken contract

`ACPSession.handleIncoming` produces operation arguments containing both `taskID` and the exact serialized `toolCall`. The same `PermissionBroker.authorize` call independently supplies typed `taskID`. Broker's request constructor retains this in `PermissionRequest.taskID`; Gate's context match, task routing and journal attribution use that property, not the redundant operation argument.

`ToolCallReviewBuilder` exposes every noninternal argument as a field. Its existing text grounding scans phone-like tokens. Thus the redundant UUID becomes an editable value the person may have to confirm even though it is already known internal routing identity. The n calibration demonstrated the builder limitation for `ABCDEFAB-CDEF-ABCD-ABCD-123456789012` through actual producer logic; it did not prove the unavailable raw app77 UUID's cause. Calibration stays unchanged.

The proposed production change is exactly:

```swift
let arguments = ["toolCall": detail]
```

Keep the typed `taskID:` passed to Broker, captured Session context, current-attempt checks, risk, grants, permission journal, policy, offered options and exact sorted operation `detail` unchanged. No inspector rule, UUID exception, prefix sanitizer, fake schema, retry or new store/queue/await is needed. There is no production consumer of `acp_nested_tool` operation `arguments["taskID"]`; known reads are fixture assumptions. Session itself executes no local nested tool and its later result chooses the offered ID from the actual Gate Bool.

## Actual original/fixed regression

`ACPSessionReviewMetadataSelfTest` uses the existing standalone Session API with the known valid UUID and default nil task context. It creates no Manager/task row and never overrides a random Manager ID. The real Session, Broker, Gate and owned stdio peer handle one request. The peer's operation is harmless review-only JSON, and no tool backing/external effect can run. Unexpected executor calls fail closed.

S03 pins typed header/task/risk. S04 pins exact operation JSON/detail. Before any confirmation, S05/S06 require no redundant taskID argument/field and only the exact toolCall review value; S07 requires ready review and S08 presses the real `.once` approval. Expected original behavior is S05–S08 red with UUID phone/notConfirmed and actual refusal; only the actual installed run can establish that verdict. If original control differs, retain it and investigate rather than claiming reproduction from the calibration.

Raw original readiness/first-press state is traced before cleanup. If the first press refuses, the fixture requires the actual retained same request, exact taskID value and ONLY taskID.notConfirmed blockers. It then uses the genuine Store.confirm solely to finish the original harmless protocol. It never changes operation JSON, chooses another UUID, constructs a fake ready review or retries a model. Both versions receive the same offered allow wire and same reply after their real original/fixed decision path. Original failure is not hidden or replaced with a timeout.

Remaining checks pin actual task attribution, one ask/request/reply/prompt/process, conforming wire, no cancellation before verdict, no grant change, no backing, bounded prompt cleanup and owner bytes/defaults. There are18 normal additional worker checks; cleanup invalidity is not a passing old regression. Root registers in `TaskWorkerAttemptSelfTest` after `TaskACPPostGateSelfTest`, placing the class under `Agent/Tasks/Durable`. This reuses the actual worker flag and preserves foreign ownership of `NextNotesApp`; it adds no ACP registry/count claim. Conditional total is1074+18=1092 if prior/current checks actually execute. Root retains old/current raw logs and actual source/bundle/process proof.

## Common n/o fixture contract amendments

Copied proposed snapshots and `n-o-common-contract-amendments.patch.txt` are in THIS report only. Apply the same amendments before BOTH metadata original/fixed runs; do not overwrite historical n/o source/evidence snapshots.

The existing n/o fixtures assumed the redundant field was always present. Their purpose remains Gate admission/post-Gate current-attempt proof. They now pin identity through `request.taskID == submitted.id` and preserve all actual captured context/positive handle/primary owner/receipt join assertions. If the original redundant taskID argument/field exists, both remain EXACT and only its known notConfirmed prerequisite can be confirmed. If fixed producer omits it, neither argument nor field may exist and no blocker may be ignored. No other field may be confirmed.

E01 still compares sorted encoded request bytes, same actual request, review arguments and every field value before/after confirmation. It adds exact peer operation dictionary and `request.detail == toolCall` checks. C10/C09 now use the typed header. Missing/changed typed task identity, changed operation, unexpected blocker or different receipt/context still fails. The dedicated metadata fixture requires actual absence and readiness and supplies the new original red; common n/o controls do not pretend the old redundant field was fixed.

Counts remain n160 and o57. The separate deterministic n calibration K01/K02 remains byte-identical, so the remaining general builder behavior is never marked repaired. Offered wire options, approval/hold journal sequencing, current checks, receipt evidence, review retention, released context negatives and fresh Manager no-replay proofs are unchanged.

## Frozen preparation files

- `ACPSessionReviewMetadataSelfTest.swift.txt`: `42566a560f72159df8bcff3011121b6ddde87ad478187f0beaa78d232c97b033`
- `owned-review-metadata-peer.py.txt`: `9d4431e7269d177626a95940584d7c455e15f3f69a281ef9016e49ca6e35db13`
- `Session-producer-one-line.patch.txt`: proposal only; rebase against the root's verified post-Gate Session baseline before original/fixed metadata execution.
- `common-amended-TaskACPGateAdmissionSelfTest.swift.txt` and `common-amended-TaskACPPostGateSelfTest.swift.txt`: proposed common fixture copies, uncompiled/unexecuted.

Python AST parsing only was performed; embedded peer exactly matches separate bytes. Source pins are preparation observations, not an executed build manifest. Root owns any implementation and all native runs.

Open: general inspector UUID/phone behavior, unknown nested tool review ID fallback, edited operation execution, standing grants, current-client/close epochs, consequential effects, crash/reconciliation/liveness/recovery/retry, remote/voice/scheduled authority, IM-16 and parent/aggregate gates. This proposed source fix concerns redundant internal metadata presentation only.
