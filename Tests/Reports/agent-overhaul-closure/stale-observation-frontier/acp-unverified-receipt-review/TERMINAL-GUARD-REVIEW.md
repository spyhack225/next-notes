# Independent terminal guard review — unexecuted proposed diff

Source reread: 2026-10-02 after root's current typed ACP binding and receipt routing.
The completed audit/fixture artifacts and all runtime Sources are unchanged by this
review. `terminal-record-guard.patch` is an off-source proposed diff only; it was not
applied. Root owns original/fixed proof and installation.

The smallest responsible change is guarding the existing final record Bool in
ActionOrchestrator's allowUnverifiedResult branch (`ActionRuntime.swift:743`). Use
the existing P6-06d action-ran/result-not-saved sentence. It changes one discarded
result into one Bool branch and an error throw; it adds no receipt write, field,
event, query, await, timer, store, queue, model pass, fallback or retry.

## Catch/state trace

1. Real backing already returned and verification was absent. Existing
   `add(.couldNotVerify, ...)` sets local `receipt.status = .couldNotVerify`
   unconditionally before attempting its write (`:615–617`). Its Bool is currently
   ignored, but its stage is included in the final record attempt.
2. Existing assignments populate result/artifacts/verification/completedAt. None
   changes receipt.status, so the proposed guard throws while local status remains
   couldNotVerify. An additional status assignment is redundant.
3. `ActionReceiptStore.record` snapshots existing memory and restores it when save
   returns false (`:411–429`). It does not authorize successful output on rejection.
   The unchanged source fingerprint/save branch preserves changed/nonregular source
   evidence (`:442–459`).
4. The proposed `AgentError.backendUnavailable` is caught by the first typed catch
   (`:768–778`). Its default arm tests receipt.status; couldNotVerify skips
   `add(.failed, ...)`. The same error is rethrown without another receipt write.
5. The generic error catch and `status(forThrown)`/resolveUnknownOutcome path are not
   entered for this typed error. A terminal receipt refusal therefore does not
   invent outcomeUnknown or call its resolver. The patch does not modify P1-21.
6. ACP's outer runSessionWithReceipt cannot construct its final .completed outcome
   after the throw. ACP.submit records its usual error usage and propagates. The
   actual Manager AgentError catch admits failed task state through existing bound
   worker conditions and announces the exact error; the successful result/artifact
   consumer path is skipped (`AgentTaskManager.swift:688–805`). No retry is added.

The last committed receipt can be **fired** if intermediate and final saves both
refuse (the frozen peer damages its path before reply), or **couldNotVerify without
terminal fields** if the intermediate save succeeded and the final save alone
refuses. Both are valid retained evidence. Do not describe every refusal as a fired
receipt. The fix preserves the actual last commit and prevents successful result
delivery; it does not reconcile or prove the external effect.

## Accepted behavior

When record returns true, the existing AgentToolResult expression is untouched:
same summary + existing inspection warning, reference and link. All assignments and
the same one final record call remain in the same order. No latency-producing await
or additional encoding/save is introduced. The verified terminal branch and
allowUnverifiedResult=false behavior are untouched.

This is a shared runtime correction. Existing browser, Workspace and compatibility
CLI callers with allowUnverifiedResult=true also stop returning success on rejected
terminal receipt persistence. Their accepted branches retain their existing output,
permissions and result verification behavior. Relevant shared receipt/production
tool-loop/permission/ACP/MCP/compatibility tests still need root's real verdicts;
the two-mode ACP fixture is not proof of every caller or external effect.

## Required original/fixed evidence

Freeze the registered actual two-mode fixture and current routing/attempt producer
before original61. Original damaged mode should retain exact fired bytes/memory yet
report completed/result delivery; its three predicted failures must be recorded as
actual observations. Apply only this guard to the producer for fixed62 and rerun
the identical fixture: accepted behavior remains green; rejected terminal save
produces failed SQL/task state, jobFailed and exact failure announcement, with no
reply/artifact delivery and no fresh-manager replay. Keep root's focused flags and
owner isolation verdicts real. No app, native peer, build or runtime verification
was executed by this review agent.

No new stale authority, liveness, effect outcome, reconciliation, complete retry
prevention, crash durability, broader recovery, IM-16 or Agent quality claim follows.
