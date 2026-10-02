# Receipt persistence producer — bounded P6-06a prerequisite

Implemented and verified on 2026-10-01 through the existing P1-21 receipt contract. The copied actual-store original harness fails10 assertions, the same original store on its production disk path fails7, and the fixed copied store passes26 cases. All three compiled successfully. Installed app13 passes the actual runtime disk fixture5, tool review, restoration70, authority58, durability37 and owner-store isolation21files/31defaults. The completed direct quick13 run fails3/10 against the unchanged9/10 bar (launcher exit1,189.3s), with the same ten case verdicts and class counts as prior app12: pass3/refusal2/missed_tool3/ungrounded2. The bounded prerequisite P6-06a is **done** under roadmap §4.1; the inherited aggregate quality gate stays failed. Parent P6-06 remains todo with its existing dependencies.

Exact raw logs, install log and build13 source manifest are archived under [installed-app13](installed-app13/); file hashes and the captured installed binary hash are in [installed-app13-evidence-manifest.json](installed-app13-evidence-manifest.json). Binary SHA-256: `47921c5faff10a75d55c6dd760e6f8d78439ce5937abdd1892b0d2411376af57`. This identifies app13 only. Original/proposed source snapshots, patches, prepared sources and historical preparation manifests remain retained; their prepare-only labels describe that earlier preparation, not the subsequent applied/tested verdicts.

## Confirmed cause and responsible producer

Original `ActionReceiptStore.record` mutated its in-memory array, then returned `SelfTest.isRunning ? true : save()`. This skipped every disk write during a self-test, including explicit safe temporary file injection. Its constructor did load that file. An accepted injected record therefore supplied no written or fresh-reader receipt proof.

Existing `ToolCallReviewSelfTest` G2 seeded readable/unreadable/readable rows, loaded only the readable records, called `partial.record(good)` and expected the original unreadable row to remain on disk. The harness bypass left seeded bytes untouched. On the real production path, `load` returned only readable rows and `save` encoded only that array: the next real record erased the unreadable row. A malformed/truncated/non-array source similarly became an empty list that could replace retained bytes. The archived production-original run confirms those actual overwrite failures. Unknown status values are different: their rows decode conservatively as `couldNotVerify` and remain writable and retained.

## Applied existing-seam fix

`ActionReceiptStore` retains two scalar facts: whether its URL was explicitly injected and whether its original load decoded completely. Default shared harness instances keep the existing isolated memory-only lifecycle behavior. Explicit harness stores use the actual disk writer only for file URLs under the resolved temporary root, outside Application Support; unsafe injections are refused before reading or changing state, and the allowed resolved path is checked again before a write.

Only a genuinely missing file is fresh. A read failure, malformed/top-level-invalid JSON or any undecodable row makes the instance unwritable while preserving readable rows for inspection. `record` returns false without changing state or retained bytes. Actual disk-write failure rolls back the in-memory receipts. Unknown stored statuses preserve typed identity/action fields through a real disk round-trip. The existing G/G2 fixtures now require accepted writes to reopen from disk, rejected damaged loads to leave exact bytes unchanged, failure rollback, and support/symlink refusal using owned temporary surrogates.

`ActionOrchestrator.execute` accepts one defaulted `receiptStore: ActionReceiptStore = .shared` parameter and uses that same instance for its existing lifecycle merge/writes. Ordinary product callers keep the single shared store. No new ledger, retry, await, timer or model pass was introduced. The app13 build manifest pins the applied sources; the copied current driver uses the prepared store snapshot, and root checked its store prefix byte-equal to the applied producer. `appendExternalEvent` and unattended draft still use shared receipts; this fixture supplies no injected nested ACP/draft route proof.

## Before/after and installed consumer verification

| Actual path | Result | Evidence |
|---|---|---|
| Original actual store with harness collaborator | compile0/run1;10 failed assertions | [raw original](installed-app13/nextnotes-receipt-original-red.log) |
| Original actual store with production writer enabled, explicit temp stores only | compile0/run1;7 failed assertions | [raw production original](installed-app13/nextnotes-receipt-production-original-red.log) |
| Fixed actual store copy | compile0/run0;26 cases | [raw current](installed-app13/nextnotes-receipt-current-green.log) |
| Installed actual Orchestrator and filesystem read | `RECEIPT_RUNTIME_OK: 5 cases` | [runtime output](installed-app13/nextnotes-agent-closure-receipt-runtime-13.out), [launcher log](installed-app13/nextnotes-agent-closure-receipt-runtime-13.log) |
| Installed related checks | tool review; restoration70; authority58; durability37; isolation21files/31defaults all pass | [exact summary](installed-app13/related/summary.json) |

`run-receipt-driver.py` copies the actual receipt/action types, store and AgentRisk. SelfTest, AppIdentity and OSLog are declared collaborators. AppIdentity names an owned temporary support surrogate. `--production-original` changes only the declared harness mode and uses explicit temporary instances; it never accesses shared owner receipts. Original/current input manifests retain exact copied source hashes. These copied runs exercise the store, not the Orchestrator.

The installed `--selftest-receipt-persistence` closes that consumer gap through the actual Orchestrator and existing FilesystemExecutor. A fresh disk reader inside the final fire closure must observe exact `.fired`, task ID and prepared arguments **before** one real temporary file read. A fresh reader after execution must observe `.completed` and its result.

The negative runtime case injects a real writer failure at the existing pre-fire validity hook, after a fresh reader verifies genuine `.approved` persistence. It retains those exact bytes and replaces the original writer target with an empty directory. The subsequent genuine `.fired` save must reject with the existing refusal and produce zero additional effects. In-memory state stays `.approved`; retained bytes and their fresh-reader lifecycle stay unchanged. Owner history/defaults remain unchanged. No fake runtime or receipt writer satisfies these installed assertions.

## Aggregate evaluation retained

The [completed direct quick output](installed-app13/quick-complete/nextnotes-agent-closure-quick-13-rerun.out), launcher log, markdown report and JSONL sidecar are archived exactly. Quick13 is **FAILED: 3/10**, bar9/10,189.3s; error/timeout/leak/wrong-tool/fabricated/filler are0, refusal2, missed-tool3, ungrounded2 and pass3. The manifest compares all ten case verdicts to the hashed prior app12 output; every class matches. This is unchanged inherited quality failure, not a model/default promotion or broader Agent-readiness claim. The initial via-open launch produced header-only evidence and was stopped before a verdict; its raw files are retained separately under `quick-incomplete-initial` without a speculative exit cause or evaluation result.

## Limits and next prerequisite

This is fresh-reader disk persistence and actual pre-effect admission proof. It is **not** a separate process-crash/restart, power-loss/fsync, lease/attempt fencing, task `receiptIDs` join, recovery/retry, idempotency or IM-16 hosting proof. A persisted `.fired` fact conservatively records intent to execute; it alone does not prove that an external effect completed. Damaged receipt history fails closed, while broader receipt repair UI remains open.

Next, recheck the actual worker producers before preparing bounded SQL-first positive-attempt/lease-owner admission and stale callback/effect fencing. Manager, LocalBackend, journal writers and primary store must share the same captured attempt/status contract. Never auto-fire after restart; preserve existing held recovery. P6-04a/P6-04a-3 remain in progress, and parent P6-05/P6-06 dependencies and exit contracts are unchanged.
