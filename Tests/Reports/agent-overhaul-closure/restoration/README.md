# P6-04a-3 retained interaction producer foundation

2026-10-01. This report covers the owned manager/task implementation and copied-source checks. Installed application, actual approval gate, edited review producer and real LocalAgentBackend evidence must be added by the integrating executor before claiming the original product flow is fixed.

## Confirmed causes

The original manager preserved `waitingForPermission` and `waitingForInput` rows but never invoked the approval consumer on restart. An ordinary permission failure arrived as `AgentError.needsPermission(request.title)` from ActionOrchestrator; its exact request, arguments, scope, trigger and origin were not part of AgentTask. The original SQLite canonical projection could not retain a pending interaction payload. LocalAgentBackend consumed a token from `AgentTaskManager.shared`, irrespective of the contextual manager executing the task. The review store kept user edits only in memory. These are separate producers; preserving a row alone fixes none of their missing consumers.

## Owned implementation

`AgentTask.pendingInteraction` is one optional typed payload in the existing record. Its permission case contains the existing `PermissionRequest`, optional exact `ActionOriginContext` and optional `ToolCallReview`; its input case contains the original identified question. Optional decoding retains older history without inventing an action or question.

`AgentTaskManager.parkPermission` commits a genuine task-bound direct-local request before a card may exist. `persistPendingReview` commits the edited review through the same row. `restorePendingInteractions` uses the existing gate; the root executor supplies that gate's durable callback bridge and application call sites. Its callback matches task/request/tool identity, current state, typed owner and reviewed arguments. The primary transition must commit before the manager supplies a one-shot token or dispatches. Original underscore authorization pins survive, and a cleared field stays cleared. A rejected callback leaves the exact question/card state retained.

Manager updates roll back their in-memory mutation after a primary failure. A failed launch decision restores the loaded snapshots and blocks dispatch; planned recovery is no longer represented as committed memory. Contextual capture and token consumption bind to the actual manager rather than the global manager. One-shot tokens remain in memory only.

Legacy title-only approvals/questions, ACP nested requests without a verified continuation, remote, voice and scheduled requests receive no local replay authority. Compatibility mode retains its existing frozen command/directory validation and explicit one-shot approval. No worker reattachment, automatic retry, lease, receipt reconciliation or iMessage production host is claimed.

## Before and after evidence

`run-restoration-driver.py --original` uses the committed `5de382a` manager and the original schema2/store/journal snapshots in `/tmp/nextnotes-restoration-original`. The fixture supplies one original request with literal path, content, authorization pin, source and request identity. The actual primary projection discarded the typed pending payload, and the original fresh manager invoked no card consumer. The process exited 1 with two assertions (`original-red.log`). The optional typed payload is a fixture extension so the older projection can be asked to retain it; this is not a claim that the old ActionOrchestrator captured that value.

The current copied sources pass 14 cases with exit 0 (`standalone-green.log`): exact primary payload and origin, actual fresh-manager card call, no restored grant or dispatch, deduplicated restoration, rejected approval and stale identity, original input question and rejected callback, producer rollback, launch-decision rollback, negative legacy/ACP/remote/voice/scheduled ownership and frozen compatibility history.

The standalone driver replaces the gate/review/UI/backend collaborators. It demonstrates the actual manager, task decoder, SQLite projection and primary commit boundaries; it cannot prove the real gate, review editing, final tool boundary or rendered cards. It deliberately never executes a tool, obtains an account or loads a model. `SelfTestStoreGuard` checks owner-store isolation. Installed proof must exercise those genuine consumers and the genuine request producer, replacing only the external effect.

## Remaining product contracts

The input API and retained question projection need a verified production worker producer and an actual answer card. A helper/API alone is not a shipped input flow. The external UI owner must integrate visible damaged-history/repair and paused-work actions. Product repair, large-history latency, older-binary rollback, ACP reattachment, final attempt fencing and receipt-aware recovery remain open. Do not promote parent P6-04a or IM-16 from this report alone.
