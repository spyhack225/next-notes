# P6-05b: preserve task attempt fencing across runtime classes

2026-10-02. Bounded producer repair under AGENT-OVERHAUL §4.1; parent stale observation and recovery/retry remain open.

## Confirmed cause and producer

Manager and LocalBackend previously recognized a positive typed-local attempt only when its runtime class was localDeterministic. Changing that descriptive field could downgrade retained held/stale ownership into unbound work: the actual backend reached a real temporary file read and the manager admitted tool facts. Native browser tools were also stamped localDeterministic at running admission, despite their actual catalogue descriptor being browser.

A separate admission defect was visible even with the original local class. Backend required a validity callback to exist but did not evaluate it until the final effect boundary. A held task was refused there, after new receipt records had already been created. This original failure is preserved rather than replaced by the easier nonlocal-class scenario.

Installed original app33 reproduces **122 failed assertions**: 120 across five nonlocal runtime classes, one native browser classification assertion and one local-class held receipt-mutation assertion. All previous 169 cases remain green. Six classes and six owner/start/attempt variants use a real Manager-produced running row, isolated actual task/receipt stores, fresh held Manager, actual LocalBackend and restricted temporary FilesystemExecutor backing. Browser metadata uses the actual registry and committed running row, then stops at backend entry before any authorization or browser backing.

Manager now recognizes positive worker history independently of runtime class, retaining exact start/current-process/attempt/state primary admission. Bare historical manual waiting metadata remains unbound for journal fixtures. Backend independently requires valid ownership for **every** positive typed-local attempt. It evaluates the synchronous primary-validity callback inside its existing MainActor permission-consumption hop, before receipt preparation, and keeps the existing final effect check. This adds no actor hop, sequential await, store, save, timer, automatic retry or model pass. There is one additional fail-fast primary validity probe at the existing hop; no general latency result is inferred.

Running admission now tags actual native browser descriptors as browserOrMCP. Other classes keep their baseline contracts. This is metadata proof for native browser tools, not a live browser execution or MCP/Composio classification claim.

## Verification

Fixed installed app34 passes **354 cases**, including the byte-identical original 185-case extension and prior 169 cases. Original compiler-only build32 failed on a fixture optional exclusivity expression and was never installed; the correction was made before original33, and original33/fixed34 use the same corrected fixture bytes.

Final installed app35 passes **362 cases**: all original 354 plus eight additive bare/doubly damaged waiting backend checks. The original 185 assertions and inputs remain unchanged in the final fixture; the only fixture diff appends the eight boundary checks. Both nil and attached contexts refuse before receipt preparation, with zero real reads and unchanged SQL snapshot, journal, authority generation, injected receipt disk bytes and harness receipt arrays.

All **14 related flags pass** in final installed app35:

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

Original app33 SHA256: adc7f6d9848d5ef0355dc989167133a723a77824d52738e1d4e405d2f4b1e8b7.
Fixed app34 SHA256: f35dac9ae63578266a96954e94bd442d7f2bb37ee1f129967b5741bbf06fcd60.
Final app35 SHA256: 4215fcde67392b6d52a751f2250be868c316fd487a65562e55b9752eba3fc31c.
Original compiled fixture SHA256: 158c25e93f8335906418d18c5d7467b0ad167adf26e90058e615fdc8d04df4a8.
Final additive fixture SHA256: 55dfe4f7ff6ee1fd18c4b5adf05fd28ded17136df24099151e488ff353b88af5.

Binary cache paths, original/final producer snapshots, complete source manifests,
compiler-only build32, original33/fixed34/final35 build logs, direct flag logs,
final runner stdout and per-flag verdicts are retained here. Final source stability
and installed binary checks show no changed source/artifact during verification.
Original source hashes exactly match the original33 manifest; pre-registration
snapshots are retained separately. UI captured original33 only in a separately
released native slot, then held source/build/install/native/model work through
fixed34/final35. No Computer Use access or owner-store migration was performed.
Four related flags produce stdout evidence rather than a companion log; missing
log files are not treated as passes.


## Scope

Fresh-object held reads establish exact primary/history/receipt refusal; they are not a process crash or power-loss test. The browser fixture stops before permission and backing. MCPClientStore currently lacks a safe isolated registration seam; no owner configuration was read or rewritten to create a fixture. Stale windows, process/backend-session liveness, concurrent replacement-worker lifecycle, consequential receipt reconciliation, automatic recovery/retry, remote/voice/scheduled/ACP authority and IM-16 hosting remain open. No model/default changes or new model evaluation occurred; historical app13 quickFAILED3/10 remains below the unchanged 9/10 gate.
