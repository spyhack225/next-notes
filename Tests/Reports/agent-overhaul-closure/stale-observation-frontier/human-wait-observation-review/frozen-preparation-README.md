# P6-05j current task-owned approval wait fixture

Frozen off-source, unrun. Root owns source/native/index. Parent P6-05 stale diagnosis does not exist yet; this is missing diagnostic input, not a reproduced stale classification bug.

## Actual contract and identical native path

Gate.hasWaitingRequest(taskID:) reads existing current WaitingApproval and queued request.taskID; Manager.workerPermissionWait(taskID:)->Bool? uses existing current workerBinding then synchronous Gate projection. False describes no matching Gate approval wait; nil describes unavailable live worker binding. This intentionally narrow API does not imply input-question/global/all-person-wait coverage, exact attempt authority, approval, health or retry permission. hasRestoredRequest is unchanged and stays false for these actual live ACP requests.

Root common wrapper and false Gate getter compile the same fixture on original86/fixed87. Fixed-only Gate getter body will inspect actual waiting/queue; no source execution/admission/control path changes. Original false is a missing feature, not a claim the current app actually classifies a wait as stale.

## Frozen original-compatible actual regression

**29 normal checks**, one error-only drain assertion excluded. Six expected original missing-projection failures: V02 visible A, Q02 still-active A, Q03 queued B, Q05 repeated positive queries, D02 rejected-decision wait retained, P02 promoted B. Prior worker1132 predicts1161 only when all actual flows execute. Native counts/verdict remain unrun.

Two explicit safe isolated real TaskStore/AgentTaskStore/ActionReceiptStore/Manager roots submit actual typed ACP tasks with fresh random task IDs. Same owned Python peer starts actual initialize/session-new/prompt, captures exact submitted identity and waits on safe release files. Unexpected Executor tool backing fails closed. Actual startup receipts/primary joins, positive captured attempts, owning app PID and current bindings are pinned.

- Before requests, both actual running workers return false and missing/unrelated Manager bindings return nil. No account/provider/model/native input is used.
- A reaches actual Session/Broker/Gate visible approval. B reaches another real admitted request queued behind A. Visible/queued identity is proved through real pending A, queuedCount1, exactly two Gate asks and exactly one admitted permissionRequested event per actual worker. No synthetic waiter or fake context.
- The existing safe progressDateForTesting constant is captured once as an integral timestamp forty days before current wall time. Both worker/tool-start producers really admit that timestamp into heartbeatAt/lastProgressAt while rows stay running/acpWorker. Projection must identify these waits without reading/changing age; no timer/history seed/stale decision is introduced.
- Both wrappers are sampled eagerly on every repeated iteration on original and fixed, avoiding result-dependent short-circuit input differences. Exact primary rows/journals, export/receipt bytes, current card/review, grants and bindings remain unchanged. Queued B review is never constructed by a diagnostic snapshot; it is built by existing Gate.present only after promotion.
- An actual SQL permissionApproved INSERT trigger rejects A's genuine explicit approval. The actual Bool false, same card/review/queue/bindings, sqlFailed result and unchanged primary/journals prove retention. No Task cancellation substitutes for this intervention. Current approval projections must remain true for both.
- Drop trigger and perform one actual .once response. A clears and exact B promotes synchronously before any await; actual A approval event persists once. A returns false with still-live binding; B projects true. Both actual ready reviews carry only exact four-field requested toolCall operation plus identical detail, no redundant editable task ID.
- Gate.cancelPending(taskID:B) withdraws only the real promoted request, retaining still-live workers while current wait projections become false. This is Gate withdrawal, **not Task cancellation**. Real wire receives A allow and B offered reject exactly once, no external effect. Actual notApproved journal fact on B includes withdrawal rather than claiming a human denial.
- Same harmless peer replies finish both original task/result consumers once with truthful couldNotVerify receipts. Actual bindings release; wrappers return nil. Retained actual contexts/inert Session attachment cannot manufacture a wait/binding. Peer launch/call list proves no restart or Task-cancel replacement.

Raw trace captures actual visible/queued/rejected/promoted wrapper samples before teardown, alongside released nil, actual two asks/entries/exits and old admitted timestamp. Original feature assertions cannot block release/control/cleanup. Error cleanup drops only its owned trigger, releases safe peer barriers, withdraws task-owned Gate requests and drains exact owned workers.

Extracted peer equals the embedded Swift raw multiline after eight-space dedent plus terminal newline. Script/config/marker paths are own canonical safe temp children. No owner constructor/history seed/payload decode occurs; existing outer worker harness supplies owner/default invariance. Final direct checks preserve Gate/grants and zero unexpected tool backing.

## Cost, authority and coverage limits

Gate queued.contains traverses the existing queue and workerBinding uses the existing task lookup. These are off-path synchronous diagnostics; no constant-time or full-history latency proof is claimed. No store/queue/cache/timer/periodic loop/foreground await/model pass/SQL probe/save is added by projection. Exact primary/current Process checks are separate APIs and confer no authority here.

A task-owned wait may coexist with invalid fresh primary authority or old same-task restored ownership. This conservative projection does not supply immutable attempt/start fields and cannot independently prove successor identity. This fixture covers actual active/promoted ACP request cancellation; independently isolated cancellation of an entry while it remains queued is not asserted here. Input-question/global/restored/remote/voice/scheduled coverage, four-question nonmutating stale policy, healthy session/all effects/current receipt completeness, retry/recovery/IM-16 and aggregate quick/full/owner/permission/privacy/latency requirements remain open.
