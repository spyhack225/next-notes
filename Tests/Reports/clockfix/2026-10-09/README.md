# Calendar fixture clock investigation — 9 October 2026

Clockfix is isolated on `claude2/clockfix`; no canonical source edits, installation, push or merge are authorized.

The worktree baseline is `e0b649c5` (c6d850c plus the recoveredReadHistory prerequisite). Its ToolStepRunner already explicitly passes `SelfTest.fixtureClock ?? Date()` to AgentToolLoop.groundedArguments. The canonical checkout has an uncommitted recovered-read change which also removes that argument. The retained read-only diff records that source difference; the initial MAIN-DIRTY-SOURCES list did not include the newer ToolStepRunner edit. Nothing from that diff is applied to the canonical tree.

The omitted argument selects the grounding producer's `now: Date = Date()` default. A relative `today`/`tomorrow` request intentionally replaces the model's proposed date at that producer. AgentNow's prompt, the live fixture and the grader already use the pinned fixture date. The native batch distinguishes the already-correct explicit caller from the defective defaults and replays the exact omitted-clock call before repairing the defaults. A correct raw completion is evidence of a proposal; the real parser and fixture call log are the execution evidence.

`--selftest-toolloop-live --only C01,C04 --model scripted-clock --fixture-now 2026-10-05T09:00:00-04:00` runs the unchanged cases and grader through RealtimeAgent.handle(source:text), normal planner/parser/ToolStepRunner and AgentToolExecutor.fakeForTesting backed by LiveEvalFixtures. Only the completions are scripted. C01 retains the archived Qwen proposal; C04 retains the archived Mini first completion, including its function/param wire form, proposing a mail read and the fixture tomorrow. The provider checks the actual planner prompt's date. Extra default-clock checks exercise grounding and the account floor without explicit `now`, plus explicit-clock precedence, historical dates and ambiguous relative days. This diagnostic cannot run a quick/full suite or qualify a model.

The repair uses the existing SelfTest.fixtureClock injection in the defaults of groundedArguments, defaultRead and pendingRead. Outside the explicitly pinned live selftest that injection is nil. Explicit callers still take precedence; the final source retains HEAD's explicit ToolStepRunner binding. No clock/store/queue abstraction, await, sleep, model pass, deadline, grader or bar is added to the product path.

Native results are retained in [checks.json](checks.json), [wrapper.log](wrapper.log) and the per-run reports. One normal FIFO heavy.sh slot ran four debug builds, all exit0; baseline/source-pin comparison confirms only the omitted now argument changes between the first two variants, only the two default-clock producer files change for the repair, and only the explicit runner binding is restored for the final build. All830 final source files match the native build pins. Cases, grader, fixtures and scripted provider hashes are identical across all four variants.

| Run | Actual result | Final marker / exit |
|---|---|---|
| Baseline, explicit runner binding | C01/C04 PASS5/6; default and floor probes wrongly9/10 | `TOOLLOOP_LIVE_FAILED: scripted clock defaults failed (4)` /1 |
| Exact omitted-binding original | C01/C04 WRONG_TOOL9/10; score0/2 | `TOOLLOOP_LIVE_FAILED: scripted clock defaults failed (4)` /1 |
| Same omitted caller with repaired defaults | C01/C04 PASS5/6; default/floor correct; score2/2 | `TOOLLOOP_LIVE_OK: 2/2 on scripted clock diagnostic (no model qualification)` /0 |
| Final source with explicit binding retained | Same fixture PASS2/2 | same OK marker /0 |
| Midnight, DST, UTC replays | Each PASS2/2; UTC crosses to6/7 correctly | same OK marker /0 each |
| now-block | passed | `NOW_BLOCK_OK` /0 |
| toolloop-live-grader | passed without grader changes | `TOOLLOOP_LIVE_GRADER_OK` /0 |
| toolloop-production | standalone passed | `TOOLLOOP_PRODUCTION_OK` /0 |
| capability-manifest | passed | `CAPABILITY_MANIFEST_OK` /0 |
| store-isolation | retained file/default snapshots unchanged, narrower limits below | `STORE_ISOLATION_OK: 21 files and 0 defaults unchanged` /0 |
| One real Mini quick control | 9/10; C01/C04 PASS5/6; A02 UNGROUNDED | `TOOLLOOP_LIVE_OK: 9/10 (quick) on MiniCPM5-2B` /0 |

The final batch marker is `CLOCKFIX_BATCH_OK`, wrapper exit0. Source diff-check passes; raw compiler logs and patch contexts intentionally retain their original trailing spaces, which a full artifact diff-check reports. Compilation/audio dependency commands exit0; their actual build-complete output is in the build logs (they have no selftest OK marker). The unchanged-tree claim is deliberately limited: this worktree's runner binding already worked. It was the default producer probes that failed on its unchanged product source. The canonical one-line omitted-binding replay reproduces the observed C01/C04 failures; it is never presented as an unmodified c6d850c case failure.

[Mini report](mini-control.md) and its [ten complete unique JSONL rows](mini-control.md.jsonl) retain actual replies and all raw rounds. Admission swap6.088623GiB <=8, free disk12.017139GiB >=10, load2.98 <=40. Model id is `openbmb/MiniCPM5-2B-GGUF/MiniCPM5-2B-Q4_K_M.gguf`, size1,561,318,368bytes, resolved without fallback at32768context. Device/power/OS metadata captured after the run and model file stat are in [environment.json](environment.json); no fresh weight digest was computed. The compiled debug executable SHA is in [final-build-pin.json](final-build-pin.json). No installed app was selected or changed. Reported timing/RSS/footprint is diagnostic metadata, not an optimized release benchmark or full-duplex performance acceptance.

The observed current score is9/10, two points above the retained installed Mini7/10x3. Only C01 and C04 verdict classes differ from that cohort; all eight other classes match. This is one current debug-source run versus a different installed build, not a same-binary model-only ranking or proof of a stable repeated score. Do not revise/regrade the old runs. Qwen/Apple were not rerun, full/owner suites and combined ASR/voice performance were not run, and nothing is promoted. The exact historical installed source/dirty-edit parity was not recovered; the causal proof is the native owned-source replay of the observed canonical call.

The extra isolation flag intentionally ignores the nested production-loop return. Its A02 fixtures are refused because AgentToolExecutor.browserPageFixtureIsAdmitted requires requested==toolloop-production. Its nested output therefore includes `TOOLLOOP_PRODUCTION_FAILED`; that is **not** a functional pass. The standalone prescribed production-loop flag passes. The isolation verdict proves21 snapshots unchanged and observes0 owner defaults; it does not establish a32-default witness or successful nested A02 actions. No isolation/admission guard was weakened or repaired for this task. Memory-tool refusal and nested Needle timeout diagnostics are retained too.

The correction is classified as an evaluation clock-binding defect. Real-user calendar execution was not exercised, so it supplies no claim that a production calendar failure was fixed. Explicit date/clock precedence and ambiguity controls pass through the producer; normal calls keep the real clock because the existing fixture injection is nil outside the pinned selftest. No new save/store/model pass or sequential await is added.

Owned compiler scratch and TMPDIR are deleted after joining every native child; [cleanup.json](cleanup.json) confirms both absent. The canonical edit, owner files, model choices and weights are preserved. Broadcasts through agent-relay persist these findings; sending does not prove reading or agreement.

Reproduce from this branch, in an owned worktree only:

```sh
RELAY_ID=claude2-clockfix ../heavy.sh 'python3 Tests/Reports/clockfix/2026-10-09/run-batch.py'
```

The driver rejects unexpected producer edits before whole-file replay and restores its initial source on an incomplete run. It uses the retained baseline git source, not a canonical checkout write. Direct scripted diagnostic after a build uses the CLI command given above; it cannot qualify a model.
