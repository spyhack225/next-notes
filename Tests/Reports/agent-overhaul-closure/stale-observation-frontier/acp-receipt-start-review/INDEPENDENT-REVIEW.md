# Independent ACP receipt-start review

2026-10-02; source review only against root62. Root reports committed 3b2acbb,
worker701/all20 PASS; this agent ran no app/build/peer/native test and changed no
Sources/index/model/account/owner payload or other child's fixture. Root owns proof.

The two-file proposal uses the smallest existing seam: ActionOrchestrator commits
the fired receipt first, then ACP calls TaskEventJournal.toolStarted with that same
prepared UUID before checkout capture/process entry. Manager normal typed ACP uses
hasWorkerAttemptRecord and the existing receipt/progress/journal primary transaction.
It validates exact fired task/attempt/process owner, prepared action/intent/routing/
tool identity and no duplicate receipt ID before committing the task link and event.
Failed primary commit rolls back fields; export failure after SQL commit stays admitted.

This adds one synchronous existing primary save transaction to ACP startup, including
the existing snapshot/export cost. It adds no store/schema/ID namespace, separate
progress save, await, timer, permission token or retry. Do not claim zero added save
or query, complete launch fencing or broad latency improvement.

Permission events retain running/waitingForPermission acceptance. Other events become
running-only. Outer authority/approval and scheduled refusal stay before fire.
Compatibility remains excluded by frozen compatibilityCLI/compatibilityCommand;
its existing explicit one-shot approval is neither widened nor converted into a
typed ACP attempt. Nested transport permission provenance/global receipt event routing
remain separate contracts.

The new admission checks the same primary epoch synchronously. Lower runSession still
awaits Session subscription/start before native launch: primary replacement after
the join across those awaits is not newly fenced. Existing cancellation checks are
retained; they prove neither already-entered process cessation nor effect outcome.
The existing LAST cache may now hold ACP entryAdmitted, but this proposal emits no
ACP toolCompleted and proves no backing return, active-call coverage or health.

On rejected bound toolStarted, its existing error is `The action could not be saved.
It was not run.` Runtime local status is fired, so the existing typed catch attempts
add(failed). With a healthy receipt writer the receipt becomes failed while retaining
its fired event/identity; with damaged source it may remain fired. Startup fixtures
must require retained evidence and zero owned peer launch, not universal fired status.
This differs from terminal refusal's couldNotVerify catch behavior.

Old TaskACPPrimaryAdmissionSelfTest controls need no expectation change: positive
start/result, running-SQL rejection, pre-runtime stale state/attempt, held cancellation,
direct positive-without-context refusal, and bare Session decline/late-update remain
their original cases. Compatibility authority/restoration controls stop before CLI
launch; scheduled ACP controls refuse before fire. Their passes do not substitute
for an actual receipt-start regression.

The existing TaskACPUnverifiedReceiptSelfTest has one explicit expectation upgrade:
replace its empty receiptIDs check at approximately line153 with
`primary?.durability?.receiptIDs == [fired.actionID.uuidString]` and
`final?.durability?.receiptIDs == primary?.durability?.receiptIDs`.
Keep its inputs, peer and 23 normal assertions unchanged; rename that assertion to
exact admitted attempt/receipt retention. Original61/fixed62 archived fixture bytes
remain historical evidence; report the new expectation contract openly rather than
calling upgraded runs byte-identical to those earlier runs.

New startup proof needs fresh task/receipt/journal/progress observation at actual
peer boundary, zero peer launch and no admitted join/event/progress on primary
tool-start rejection, healthy/damaged receipt distinction, export-failure admission,
and unchanged original/fixed startup inputs. Original regression and related root
flags remain necessary; this review is not an executed verdict. Receipt reconciliation,
crash/power-loss proof, broader fencing, liveness, recovery/retry, IM-16 and aggregate
quality contracts stay open.
