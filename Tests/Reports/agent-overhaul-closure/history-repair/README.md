# Prepared task-history repair

The failure begins in `AgentTaskStore.load`: preparation retains a generation-one JSON witness bound to an exclusively created ledger, then a crash before reconciliation leaves that ledger at schema zero. Ordinary loading correctly rejects this uncertain state. The previous fixture-only repair called the normal authority probe, which also rejected zero, and there was no production repair action.

The production repair now accepts only an explicit action against the same existing device/inode and validated preparation. A read-only probe accepts a strictly empty schema-zero ledger, or a known unmarked ledger whose existing canonical rows agree with the preparation in relative order. Missing files, foreign identities, marked ledgers, unknown schemas/objects, corrupt stores and disagreeing history remain retained and rejected. No creating open is used. The write transaction repeats the binding, schema, row and unchanged-witness checks and preserves existing child rows. It does not dispatch work or mint an approval.

`AgentTaskManager.repairTaskHistory()` shares the startup interrupted-task hold logic. A successful repair still leaves interrupted work held, and both approval token sets are cleared. Failure keeps admission blocked. Exact pending-card restoration is a separate consumer call; this helper does not execute an approval or reconnect a worker.

The copied-source driver uses actual store, schema, manager and recovery planner sources against injected temporary files. Its external collaborators are declared test scaffolding; it does not prove the installed application's UI, actual permission gate, production backend or owner migration. Original producers are retained in `original-*.swift.txt` and selected by `--original`.

Commands run serially in the coordinated tiny compiler slot:

```sh
python3 Tests/Reports/agent-overhaul-closure/history-repair/run-history-repair-driver.py --original
python3 Tests/Reports/agent-overhaul-closure/history-repair/run-history-repair-driver.py
```

The original copied actual-store fixture compiled successfully and exited 1 with `TASK_HISTORY_REPAIR_FAILED: explicit prepared schema-zero repair is unavailable: Task storage has an unsupported schema version (0).` The final actual manager/store fixture compiled successfully and exited 0 with `TASK_HISTORY_REPAIR_OK: 41 cases`. Raw output is retained in `original-red.log` and `standalone-green.log`. The original fixture's refusal also asserts that its saved JSON and blank ledger bytes were unchanged.

The final fixture covers explicit manager repair, read-only affordance, held restart and zero backend starts; preservation of known terminal history and event children; 13 rejected cases (missing/replaced/future/unknown-schema-zero/foreign-application/corrupt/bad-generation/bad-format/malformed/conflicting/foreign-known-object/invalid-journal/marked); an unexpected schema object inserted inside the transaction; a changed preparation witness; and primary-commit failure with a later explicit retry. The installed flag also requires `SelfTest.isRunning` and checks the owner store/default snapshot before and after all fixture paths.

The copied harness initially encountered duplicate collaborator methods after the shared restoration driver gained them, then a sandbox rejection of Apple's Observation macro plugin. Duplicate scaffolding was removed; the same actual producer sources ran with the compiler plugin allowed. Those infrastructure failures supply no product regression evidence.

`prepared-source-manifest.json` records the current frozen file hashes and retained original producer hashes; it is a handoff manifest, not a captured compiler-input manifest. The driver copies live dependencies, so root's subsequent integration must receive installed verification.

Installed `--selftest-task-history-repair`, real card consumers, full-history latency, power-loss durability, leases, receipts and retry remain separate requirements.

## Diagnostic legacy pending-payload reader

A separate confirmed source gap existed in the generic `TaskStore.replaceSnapshot` API: it could add/write `pending_interaction` into an unmarked v1 store while retaining version one, but `readRows` projected `NULL` for all versions below three. Production `AgentTaskStore` migrates first, so this is a narrower diagnostic reader contract rather than evidence that its authoritative writer lost payloads.

The reader now decodes its recognized optional column when present in known v1/v2 schemas. A genuine old schema without the column still projects nil. This read does not add a column, change the version, install an authority table or grant authority. The original pre-fix reader is retained in `original-v1-TaskStore.swift.txt`.

Ten additional actual-store assertions cover: a real v1 schema without either the new column or authority table, its unchanged nil read, physically accepted permission/input writes, exact fresh-reader payload equality, and retained version-one/unmarked status. The archived pre-fix reader compiled successfully and exited 1 with two original failures: the accepted permission and input writes lost their pending payload on a fresh read (`v1-original-red.log`). The final reader preserves both payloads while retaining version one and no authority table. Exact copied compiler-input hashes are retained in the corresponding manifest files.

## Cached repair eligibility

The first production repair affordance also read and decoded the preparation and probed SQLite whenever SwiftUI evaluated `canRepairTaskHistory`. The producer now computes an observable cached eligibility value when initial history loading fails. The property itself reads only that in-memory value, the existing error and active-task state. An explicit repair still performs all original store validation; a failed action refreshes eligibility. Successful repair clears it.

Seven additional assertions exercise the actual manager: an initial eligibility probe; twenty repeated affordance reads without further probes; a replaced ledger that leaves the cached affordance unchanged; the explicit action rejecting that replacement without dispatch; refreshed false eligibility after failure; and preserved witness/replacement files. The archived old manager compiled and exited 1 with three cache failures (`cache-original-red.log`). Its exact source is retained in `original-cache-Manager.swift.txt`.

The final current driver compiled and exited 0 with `TASK_HISTORY_REPAIR_OK: 58 cases` (`final-current-green.log`): the original 41, ten legacy pending-reader assertions and seven caching assertions. Root ran these serially with an unrestricted compiler after the child sandbox rejected Apple's Observation plugin. A later approved child duplicate reproduced the same two v1 failures; it added no further source changes. `final-input-manifest.json` captures the exact copied final inputs.

Root's serial installed run also passed `--selftest-task-history-repair` with 58 cases, alongside authority 56, recovery 56, restoration 28 and durability 37 (see the adjacent [restoration report](../restoration/README.md)). This exercises the installed manager/store producers under the isolated harness. A rendered native restore button, original owner-store migration, real backend execution, full-history latency and the broader recovery contracts remain separate proof requirements.

Latest bounded integration evidence, 2026-10-01: installed historyrepair58 remains green alongside restoration70 (original28 permission plus narrow filesystem.read/path input42), authority58, recovery56 and durability37. The [input report](../input-clarification/README.md) retains original2/scope4/current42 and exact installed authority9 raw log hashes. This supersedes the historical integration counts above, not its preserved run records. No actual restore-button or input-picker claim follows: the CUA chooser attempt was refused, the isolated native proposal remains unapplied, and broader history repair/rendered-card/worker/receipt contracts keep P6-04a-3 and parent P6-04a in progress.
