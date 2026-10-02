# P6-05c: bind observations to the existing admitted worker handle

2026-10-02. Bounded observational feature prerequisite under AGENT-OVERHAUL §4.1, not a reproduced handle-clearing bug or completion of stale detection.

## Producer and actual consumer

The existing Manager running dictionary previously held the actual Swift Task but no captured admitted attempt identity. A task ID or app PID could not distinguish its executing handle from an unbound queued successor. Existing release protection already covered its known successor case; this change makes no claim that it fixed a reproduced clearing defect.

The same dictionary now wraps the same Task plus an optional TaskWorkerBinding. Queued slots are unbound. Immediately after the existing primary running commit succeeds, and before backend entry, the producer captures task ID, positive attempt, process owner and admitted start. No second registry, ledger, task, save, await, timer, schema or compute owner is added. The four existing enqueue sites and cancellation paths use the same map and Task. Release also checks the captured slot binding, preserving queued/replacement successors.

Manager.workerBinding supplies a read-only in-process snapshot only for a matching uncancelled, typed-local, running in-memory row. The existing backend-entry path consumes that same snapshot in a metadata-only debug diagnostic. It reads no SQL and grants no execution, health, process death, backend-session liveness, effect/no-effect, stale decision, recovery or retry authority. Authoritative effect checks remain independent. Another Manager can commit a restart hold while the original Manager still truthfully reports its captured handle; the original context then fails actual primary validity.

## Original and current verification

Original app37 retains the original unbound running-map producer and adds only a binding type, nil observation scaffold and actual regression registration. The installed original fails exactly seven missing-feature assertions at real backend/held-backing entry; prior362 cases and the original temporary read remain green. This is a feature absence result, not an invented production failure.

Fixed installed app38 passes **399 cases**: prior362 plus37 new checks, using byte-identical original fixture SHA256 ff89dd62ecd483ed43e44a79613f9ea7360214f12c8907372cdbe41d6117e5c2.

Three actual Manager → LocalBackend → Executor → Orchestrator paths hold after real fired receipt/tool-start admission. Backend and held-backing consumers compare exact in-memory binding and fresh SQL metadata using the existing ISO8601 date representation, without a replacement clock or tolerance. Repeated snapshot reads change no task row, event, generation, export, receipt, owner store/default or backing count. Normal completion executes one original restricted temporary read and retains its exact completed receipt.

Cancellation overlaps deliberately cancellation-ignoring already-entered backing. Removing its handle does not prove the backing stopped: after explicit fixture resume it performs one safe read, while the task remains cancelled with no result. Restart uses a fresh actual Manager/store to commit recovering, supplies no new live handle, rejects retained authoritative validity and stops before the temporary read. Every hold is released and the actual worker exit joined during bounded cleanup. Primary-start rejection produces no backend/receipt/binding; tool-start rejection retains its admitted entry observation but runs no backing. These holds are diagnostic-only continuations, not production waits.

All **14 related flags pass** in installed app38:

| Flag | Actual marker | Exit |
|---|---|---|
| `--selftest-task-durability` | TASK_DURABILITY_OK: 37 cases | 0 |
| `--selftest-task-recovery` | TASK_RECOVERY_OK: 56 cases | 0 |
| `--selftest-task-authority` | TASK_AUTHORITY_OK: 58 cases | 0 |
| `--selftest-task-restoration` | TASK_RESTORATION_OK: 82 cases | 0 |
| `--selftest-task-history-repair` | TASK_HISTORY_REPAIR_OK: 58 cases | 0 |
| `--selftest-receipt-persistence` | RECEIPT_RUNTIME_OK: 5 cases | 0 |
| `--selftest-tool-review` | TOOL_REVIEW_OK | 0 |
| `--selftest-toolloop-production` | TOOLLOOP_PRODUCTION_OK | 0 |
| `--selftest-routine-authority` | ROUTINE_AUTHORITY_OK | 0 |
| `--selftest-schedule` | SCHEDULE_OK | 0 |
| `--selftest-usage-log` | USAGE_LOG_OK: 26 cases | 0 |
| `--selftest-store-isolation` | STORE_ISOLATION_OK: 21 files and 32 defaults unchanged; TOOLLOOP_PRODUCTION_OK | 0 |
| `--selftest-toolloop-live-grader` | TOOLLOOP_LIVE_GRADER_OK | 0 |
| `--selftest-voice-scheduling` | VOICE_SCHEDULING_OK | 0 |

Original app37 SHA256: 914ed434d0d1cdd98c3238f7e7d2772a5f340234c96f889c5b5399dd54a9772b.
Final app38 SHA256: 670abcdda9a883dedffbd9d55b1b1d74a2dc75a12d6aa5a928ba1ae40bbf12f8.
Complete source manifests, original pre-scaffold/compiled snapshots, unchanged fixture, original/final build and native logs, runner stdout, binary-cache paths and final source/artifact checks are retained. Source stability was empty at original and final verification. Four related flags retain actual stdout without producing a companion log. UI source/native/build/model work stayed frozen through original37/final38.


## Scope

This establishes captured in-process ownership metadata, not runtime health or a complete stale collector. The snapshot is intentionally not a fresh authoritative SQL view. Missing/cancelled/unbound/held observations remain unavailable, never verified gone or safe to retry. Genuine concurrent replacement-worker coexistence, process crash/power loss, four joined stale observations, ACP/session/process liveness, consequential receipt reconciliation, automatic recovery/retry and IM-16 remain open. No model/default changed or model evaluation ran; historical quick app13 FAILED3/10 remains below unchanged9/10.
