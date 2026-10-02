# P6-06c: exact task attempt and action receipt link

2026-10-02. Bounded prerequisite under AGENT-OVERHAUL §4.1; parent P6-06 remains open.

The actual Orchestrator already persisted `.fired` before backing entry. Its receipt
had only taskID, and the Executor discarded prepared.id when publishing toolStarted.
Manager admitted that fact without filling the existing TaskDurability.receiptIDs.
A fresh primary reader therefore could not identify the exact action its worker ran.

## Original failure and producer repair

Installed app26 reproduced **nine failed assertions** across accepted, SQL-success/
export-failure and completion-history-rejection reads. Each failure was observed at
actual Manager → LocalBackend → Executor → temporary FilesystemExecutor backing or
fresh terminal SQL. The existing93 worker checks remained green. The fourth original
scenario, rejected primary toolStarted, continued to refuse the effect and retain its
runtime receipt. See the original log and app26-sources. Only optional receipt-store
injection/pass-through was added before this run; no binding or join logic existed.

The responsible producers now preserve the handoff:

- ActionReceipt carries optional taskAttempt and taskLeaseOwner from the captured
  admitted typed-local TaskJournalContext. Old rows decode with no live binding.
- Executor passes the real prepared action UUID after final argument validation.
- Manager checks the saved `.fired` receipt's task, attempt, owner, tool, prepared ID,
  prepared routing and intent. Missing, malformed and previously linked IDs are refused.
- Receipt ID, existing activity fields and toolStarted commit through the same existing
  primary transaction before backing. Rejection rolls back the snapshot; accepted SQL
  remains authoritative even if its JSON export fails.

Receipt injection defaults nil and resolves the existing shared store at execution;
manager startup adds no receipt-history read. No new store, schema column, save,
await, timer, model pass or consumer retry was added. Receipt facts remain metadata
in the task journal; action content stays in its existing receipt store.

## Installed verification

App27 passes **136 cases**. App28 failed compilation only in the new continuation
fixture's throwing boolean expression; it was never installed. That log is retained.
After correcting the fixture, app29 passes **156 cases**. The original four flow inputs
and join predicates remain; malformed-boundary injections run in a separate fifth
scenario. The final fixture adds:

- Missing receipt/ID, legacy unbound receipt, wrong attempt/process/task/tool,
  prepared-ID/routing/intent/tool mismatch, unfired receipt, missing fired event and
  duplicate-link refusal, with zero backing and unchanged fresh primary rows/journal.
- Actual receipt write refusal and primary tool-start refusal, preserving no task link
  or effect; completion rejection keeps completed runtime evidence without task success.
- Fresh receipt/primary reads before actual temporary backing, including SQL accepted
  while export fails.
- Actual restored permission and missing-path input continuation: attempt N+1 once,
  exact edited approved payload, a distinct successor receipt, old-context refusal,
  exactly one original temporary write/read and durable terminal link.

All14 related flags pass:

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

## Provenance and limits

Original binary: e3b4336384a23f14c72fbf60483a8fd18c812abe8be70d54a78f2d9770b3127a.
Final app29 binary: c7e6468913226d281684ed2fa1fdbfe03a1b218882b4e1d0aa868266602b0eee.
Binary cache paths/hashes are retained in app26/27/29-binary.json. Build/source
manifests, original/final source snapshots, direct flag output and runner stdout are
archived here. Manifest stability checks returned no changed sources for the original
app26 and final app29 before verification completed. Later memory groundwork is
separate and receives no acceptance from this build. Existing UI changes were frozen
by their owner; this report supplies no new UI visual or model quality claim.

The task and receipt files remain separate persistence boundaries. A missing link
never proves an effect did not happen. Receipt retention remains capped by the
existing store; there is no new unbounded archive. The new fields bind current typed
local work only; they supply no process/session liveness, crash or power-loss proof,
receipt outcome reconciliation, replacement-worker lifecycle, standing-grant repair,
automatic recovery/retry, ACP/voice/scheduled/remote authority or production IM-16 host.
Parent P6-04a/P6-04a-3/P6-05/P6-06 and downstream contracts stay open. Latest aggregate
quick13 is historical FAILED3/10 against the unchanged9/10 bar; no app29 model eval
ran or is inferred from deterministic acceptance.

Independent read-only review found no material introduced defect. It checked the actual producer guards, lazy store access, SQL rollback/export behavior and equivalence of the original four flow scenarios. P6-06c is done as this bounded prerequisite only. The review separately identified ignored terminal receipt-save failure as inherited follow-up P6-06d; it is not repaired by this join.
