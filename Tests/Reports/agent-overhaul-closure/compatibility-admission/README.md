# Compatibility approval admission

The actual producer `AgentTaskManager.approveCompatibilityCLI` inserted a one-shot token before saving its queued transition. When the primary save failed, `update` correctly restored the waiting row, but `rejectStart` then changed the in-memory row to failed. SQLite retained the original waiting row. Since `AgentView.taskRow` displays the compatibility card only for `waitingForCompatibilityCLI`, the original card disappeared until restart.

The producer now returns on rejected primary admission, preserving the exact waiting row and its frozen command/directory. It inserts the one-shot token only after the queued transition commits. Successful dispatch remains on the existing task runner; no new store, retry or approval is added.

The focused fixture uses the actual frozen-request validator from `ACPCompatibilityCLIBackend` and actual task/store/manager producers. A SQLite trigger rejects the approval transition. It checks retained in-memory and committed rows, unchanged export, no token or worker, a fresh manager with no carried approval, successful committed admission, and one dispatch despite duplicate approval. The existing backend-entry test seam throws before any CLI backing executes; this does not prove a process effect or a rendered native card.

The retained original Manager is `original-Manager.swift.txt`. The copied driver substitutes only that producer when passed `--original`; exact inputs are captured in `original-input-manifest.json`. External collaborators are declared harness scaffolding, with the actual request type, request validator, command renderer and quoting function copied from the production CLI source.

```sh
python3 Tests/Reports/agent-overhaul-closure/compatibility-admission/run-compatibility-driver.py --original
python3 Tests/Reports/agent-overhaul-closure/compatibility-admission/run-compatibility-driver.py
```

Root's serial original run compiled successfully and exited 1 with exactly `rejected commit removed the original compatibility card` (`original-red.log`). All eight assertions ran, and no CLI executed. The current copied producer compiled successfully and exited 0 with `TASK_COMPATIBILITY_ADMISSION_OK: 8 cases` (`current-green.log`). `final-input-manifest.json` captures those exact inputs.

Root's installed build 3 passed `--selftest-task-authority` with `TASK_AUTHORITY_OK: 57 cases`, including this additional producer fixture and the previous rejected-save assertion against the exact waiting row. Raw output and launch logs are copied as `installed-selftest-task-authority.out` and `installed-selftest-task-authority.log`; `installed-evidence-manifest.json` hashes those exact logs. The same serial run passed restoration28/history-repair58/durability37/recovery56. Root subsequently installed build 4 for independent usage changes; this manifest describes the build-3 evidence, not the later installed binary. Actual rendered compatibility-card use, real CLI effects/receipts, attempts/leases/retry and IM-16 remain open.
