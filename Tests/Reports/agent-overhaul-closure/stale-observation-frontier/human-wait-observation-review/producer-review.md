# P6-05j producer review — current Gate wait metadata

Read-only review, 2026-10-02. Scope is the proposed root-owned Gate and Manager APIs, not implementation or native proof. No fatal contract issue found. The fixture remains independently owned by agent_closure_audit; this file neither modifies it nor claims its verdict.

## Reviewed bounded APIs

`PermissionGate.hasWaitingRequest(taskID: String) -> Bool`: synchronously match the exact supplied taskID against the current active `waiting.request.taskID` and every existing `queued` entry's request.taskID, irrespective of whether the entry has a suspended continuation or restoredDecision. The original missing-feature scaffold returns false; the fixed producer reads the actual owned entries. Preserve `hasRestoredRequest` byte-for-byte and all ask/respond/cancel/advance behavior.

`AgentTaskManager.workerPermissionWait(taskID: String) -> Bool?`: synchronously require the existing `workerBinding(taskID:)`, otherwise return nil; then return Gate's task-owned projection. Do not add a primary probe, validity callback, Task, actor hop, persistence, receipt read, age policy or state mutation. Original and fixed Manager wrapper should be identical so the compared producer is Gate's projection. The narrow PermissionWait name explicitly avoids claiming input/restored/remote human-wait coverage.

Both owners are MainActor-isolated. Neither proposed call suspends, so queue promotion, continuation resumption, cancellation or worker release cannot interleave within the sample. No post-await identity recheck is needed here; any future combined asynchronous diagnostic must sample again after its own await rather than retaining this Bool as current.

## Actual source contract and limits

- Gate's `WaitingApproval` already owns typed PermissionRequest plus real continuation/restored callback (`PermissionGate.swift:14–23`). Accepted asks enter `waiting` via present or queued via append (`35–73`, `103–108`); restored entries use the same ownership structures (`87–100`). This is the first producer with complete current Gate queue ownership.
- Rejected review/decision admission retains that same active entry (`respond`, `167–214`). Accepted respond removes pending/waiting before continuation-driven work can resume, then advances the queue (`215–249`). Cancel removes matched active/queued entries and advances (`311–345`). A current query naturally follows these existing transitions without listeners or duplicate bookkeeping.
- `hasRestoredRequest` (`263–266`) intentionally excludes live entries; Manager uses it for durable restored cancellation/response routing (`AgentTaskManager.swift:307`, `374`). Replacing that filter would be an unrelated authority regression; adding the independent query is appropriate.
- `workerBinding` (`AgentTaskManager.swift:59–67`) checks the actual uncancelled map handle, positive owned attempt, running in-memory task, exact attempt/process owner/start. A released, cancelled, queued, waitingForPermission, input-wait or absent handle returns nil. This API therefore covers the live running nested ACP case, not every human wait in the product.
- Normal ACP nested Gate requests retain typed taskID, captured journal context and the existing post-Gate validity guard (`ACPSession.swift:149–209`). Their Manager task remains running/acpWorker. Gate alone projects human wait; it does not overwrite that descriptive runtime class or the captured execution authority.
- `workerBinding` performs no fresh SQL probe. Another Manager can hold the same primary while the old uncancelled in-memory worker/card remains; the old wrapper may still report true. That is a truthful wait observation, not current primary authority. A fresh Manager without a live binding returns nil.
- Request taskID does not carry immutable attempt/start provenance. A same-task older/restored request may conservatively exclude an age verdict for a newer handle. True means Gate currently owns a request for this task; false means Gate has no matching current request at the sample, not that all input/person waits are absent. Nil means no eligible local worker sample. None authorizes approval, liveness, stale classification or retry.

## Native fixture review predicates

Require actual isolated Manager/backend/owned peer calls for A visible and B queued, both fresh readers running/acpWorker with captured attempt/receipt joins and actual admitted timestamps 40 days old through the existing safe test clock. A and B must project true while `hasRestoredRequest` stays false; an unrelated taskID must not borrow their wait. No helper-only ask or historical permission fact can replace the owned production flow.

Recheck after exact refused SQL decision, promotion, accepted decision and both active/queued cancellation paths. Preserve exact request/header/toolCall identity and request/decision journal admission. While a real Manager handle remains running after Gate removal but before peer-result release, false is a useful positive control; after real release/cancellation, Manager must return nil. Gate's own task query can still truthfully report a retained restored card even when Manager's live wrapper is nil.

Repeated samples must leave SQL/journal/export/receipt/card/review/grants unchanged. Real peer protocol barriers may order the fixture; no production await/delay/timer may be added. Any unexpected backing is refused and owned continuations/processes join with bounded cleanup. The original false scaffold should fail only missing-wait feature predicates; functional controls must remain valid on both producer versions.

The 40-day case establishes that this projection is age-independent. It does not execute a nonexistent parent stale detector or prove its future no-window policy. Parent P6-05, complete wait/activity/effect coverage, recovery/retry/IM-16 and quick/full/owner/privacy/permission/latency gates remain open.

## Actual common Source scaffold recheck

Root's applied common scaffold was inspected before original86: Gate `hasWaitingRequest` returns literal false at line270, existing restored-only query remains separate; Manager `workerPermissionWait` at line104 performs exactly the existing synchronous workerBinding guard and Gate query. Narrow naming and comments correctly distinguish Gate approval waits from all person interactions. No new actor hop, validity/SQL read, state/queue mutation or background task appears in either API. Missing current wait projection remains the intentionally unimplemented original producer. Static review passes; native original/fixed proof is pending.

Queued asks have no ToolCallReviewStore.begin until promotion through present. Fixture nonmutation readers should use review(id:) rather than the potentially constructing review(for:) for queued B. Direct Gate cancellation may project false while its Manager remains live until ordinary peer completion; Manager cancellation or genuine release is required before asserting the wrapper becomes nil. These fixture predicates were sent to the independent fixture owner.

## Fixed producer full-snapshot check

The exact off-source `proposed-PermissionGate.swift.txt` equals the current original common Gate file with only the literal-false method body replaced by the existing active/queued typed taskID match. A byte comparison confirmed no other changes anywhere in the full proposed Gate snapshot. `producer-Gate.patch` and `common-projection.patch.txt` match this bounded contract. `producer-review.json` pins those exact artifacts and the current common Manager. Static producer review PASS; no native or compiler result is claimed.
