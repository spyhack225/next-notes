# P6-01 actual task restart baseline — 2026-10-01

This task characterizes existing behavior; it does not fix a claimed restart bug
or add recovery. The actual `AgentTaskManager` initializer changes persisted
`running` and `queued` records to in-memory `failed` records with exactly
`Next Notes quit while this task was running.` A persisted
`waitingForPermission` record survives without supplying a live one-shot approval.
Completed records survive unchanged. The initializer does not rewrite the JSON.

## Narrow source changes

- `AgentTaskStore` accepts an optional exact file URL. Nil preserves the existing
  shared AppIdentity path resolution. Injected paths do not fall back to that
  path after a read/write failure. Its read-only `storageURL`, also used by the
  real load/save methods, lets the test verify its binding **before any seed**.
- `AgentTaskManager` accepts a real store, defaulting to the existing shared store.
  Loading and non-harness persistence use that store. The restart mapping,
  approval sets, default shared paths and self-test persistence guard are unchanged.
- New `Agent/Tasks/Durable/TaskStoreSelfTest.swift` supplies the five-case baseline
  through the real store, fresh store instance and actual manager initializer.
  It snapshots the owner's files/defaults with existing `SelfTestStoreGuard`.

No task schema, SQLite database, additional ledger, grant, token-injection helper,
backend invocation, retry or recovery planner was introduced. Existing Codable
names are preserved; roadmap “needsPermission” means `waitingForPermission` here.

## Focused actual-source evidence

```sh
python3 Tests/Reports/durable-tasks/run-task-durability-driver.py
python3 Tests/Reports/durable-tasks/run-task-durability-driver.py --omit-restart-mapping
python3 Tests/Reports/durable-tasks/run-task-durability-driver.py --ignore-injected-path
```

Results:

```text
TASK_DURABILITY_OK: 5 cases                        # current behavior; exit 0
TASK_DURABILITY_FAILED: 4 assertions                # restart mapping mutation; exit 1
TASK_DURABILITY_FAILED: 1 assertions                # isolation binding mutation; exit 1
```

The mapping mutation changes only the actual initializer condition in a temporary
compiler copy. Both running/queued status and exact quit-message assertions fail.
The binding mutation ignores the injected path in a temporary store copy; the
fixture refuses that location before seeding, and the disposable owner sentinel
remains unchanged. An ordinary run is green again after the mutations.

The tiny compiler fixture builds the full current `AgentTask`, `AgentTaskStore`,
`AgentTaskManager`, `TaskStoreSelfTest` and `SelfTestStoreGuard` source files,
including the actual manager's Observation macro. Backend, UI and announcement
collaborators are minimal and trap if called. AppIdentity's owner directory is a
disposable sentinel directory in this standalone fixture; the actual app test
uses the real guard's normal owner snapshots. No real owner task file is seeded.

The test first creates a unique temporary directory and validates the injected
store location. It then saves four records through the production JSON encoder,
reopens a distinct store and compares the entire ledger. The completed record
contains representative context references, result/artifacts, tool/arguments,
meeting ID, backend, ACP CLI/compatibility fields and schedule ID, so exact
equality checks more than default nil metadata. Whole-second dates retain exact
equality across the production ISO-8601 encoding.

The actual manager initializer supplies the restart decisions. Its real
`consumePermissionApproval` returns false for the retained permission record;
this proves the persisted record supplies no live token. It does not claim a
prior granted retry was executed or that a standing permission was restored.
Another fresh store verifies initialization left the persisted ledger untouched.

`git diff --check` passes for the owned source and fixture/report paths.

## Installed root validation

The registered installed app prints `TASK_DURABILITY_OK: 5 cases` and the
existing task test prints `TASKS_OK`. The isolation test reports 18 files and
23 defaults unchanged. Raw outputs are in `2026-10-01-p6-01/` beside this report.

Core acceptance completed at **16/18**: the known wake failure (17/24 hits,
3/32 false accepts) and a dictation silent-hold outcome classified as `tap`
instead of `empty`. A single isolated dictation recheck failed on different
microphone/capture timing assertions (no audio at a timed-out finish and delayed
capture); it did not repeat the silent-hold assertion. These are real failures,
not counted as passes. The task-store constructor changes have no dictation
call site or capture behavior change. Microphone-dependent dictation verification
remains unresolved and belongs to its producer work; no core or readiness gate
is marked green by this baseline.

P6-01 is the completed five-case characterization. It does not prove durable
recovery or unblock IM-16. P6-02 must preserve today's task fields, reject storage
corruption without deleting history, and keep JSON as the current read authority.
