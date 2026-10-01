# P1-31c — explicit personal memory saves (2026-09-30)

## Failure and producer

Y01 asks “Remember that my brother's name is Cyril”. The recorded Needle-first failure ran `memory.recall` and answered “I'll keep that in mind” without a write ([prior trace](2026-09-30-p1-31b/before-needle-targets.md)). The planner's action producer delegated an already specified save to model selection; a completed lookup and a prose response were valid ways to end the loop. Continuation policy alone did not ensure the remaining action happened. Earlier scripted continuation tests supplied `memory.remember` themselves and proved execution policy, not live completion.

The red-first regression now replays the failing recall/acknowledgment outputs through `RealtimeAgent.handle`, ordinary and Needle-first branches. The executor seam delegates to the actual `MemoryToolExecutor` and a durable temporary `NextMemory`. Before the fix the calls were only `memory.recall`, the reopened file contained no Cyril fact, and `TOOLLOOP_PRODUCTION_FAILED` reported ten explicit-memory assertions. [Raw red run](2026-09-30-p1-31c/red-production.txt).

## Retained change

The existing `AgentDirectIntent` seam recognizes a whole, explicit single personal fact introduced by “remember”, with supported polite prefixes. It preserves the fact's words and case, changing only a supported first-person subject into the existing declarative form. It supplies `memory.remember(kind: profile, text: ...)` before a model planning pass. The existing `ToolStepRunner` still checks the manifest, owner/effect validity, user provenance, permission policy and guarded atomic store write. The loop returns the executor's actual confirmation only after a successful result. A rejection is neither optimistically rewritten nor retried. The existing isolated `usage.jsonl` records a `rules` / `direct-intent` pass and the actual tool outcome, with no text/arguments.

Questions, negated commands, conditional/external/quoted content, multiple objectives and ambiguous additional pronouns remain with the existing planner. This is a deliberately bounded action parse; complex memory updates/forgetting and unsupported wording are not fixed by it. There is no prompt experiment, new model pass/store/queue, model selection/default change, cloud request or downloaded/copied weights. Parent P1-31 and Phase 1 remain open.

## Verification

Initial green: `TOOLLOOP_PRODUCTION_OK`, including actual executor/authority/policy, durable reopen, one-copy repeat, first-person preference, permission denial/cancellation, sensitive facts, disabled store/capability and failed atomic storage. Original live Y01: `TOOLLOOP_LIVE_OK: 1/1` on installed Qwen3-4B-Instruct-2507, one `memory.remember`, 8.2 s whole turn (includes upstream setup; not a zero-latency claim). [Target report](2026-09-30-p1-31c/after-y01.md).

Fresh unchanged-source ordinary quick baseline: 4/10, 350.6 s, no ERROR/LEAK/WRONG_TOOL/FABRICATED. [Baseline](2026-09-30-p1-31c/before-quick.md). The final installed ordinary quick is **5/10**, 373.5 s, still below the unchanged 9/10 bar. It has two TIMEOUT, two MISSED_TOOL and one UNGROUNDED verdict, with zero ERROR/LEAK/WRONG_TOOL/FABRICATED. The before run had three MISSED_TOOL verdicts; K01 changed to PASS. Whole-case p95 increased 51.417→59.094 s. The fixed quick set excludes Y01 and this bounded path does not run for any quick request, so neither the score change nor timing is claimed as a causal gain from the memory fix. [Final quick](2026-09-30-p1-31c/after-quick.md).

Final Needle-first-enabled original Y01: **PASS 1/1**, one `memory.remember`, actual confirmation, zero model-planning rounds. Whole case 5.289 s and first fixture result 1.803 s include upstream setup; the rules pass itself records 10 ms. [Target report](2026-09-30-p1-31c/after-y01-needle.md). Needle is bypassed only for this fully specified bounded action; its general path/default is unchanged.

Final integrated `TOOLLOOP_PRODUCTION_OK` includes `TOOLLOOP_PRODUCTION_EXPLICIT_MEMORY: 0 problem(s)`, with the original bad output replay and real guarded durable store. Memory, capability manifest, usage (25 cases), store isolation (18 files/23 defaults), model library/roles, cleanup routing, Settings/UI strings, grader, voice turns and scheduling all pass. `make test` passes 30 tests in two suites. [Production output](2026-09-30-p1-31c/integrated-toolloop-production.txt), [check manifest](2026-09-30-p1-31c/integrated-checks.json), [dictionary output](2026-09-30-p1-31c/dictionary-tests.txt).

The existing model-unopenable live S1-mini latency check remains red: 7.2 s, then 6.5 s on repeat, against its unchanged 5 s bar. No integrity/registration assertion failed there; this is not a full model quality gate pass. Parent P1-31 and Phase 1 stay open.

One preceding final production-check attempt ran while the host disk was actually full and reported failed durable writes plus a usage assertion. After clearing only completed disposable compiler output, the same binary restored those results; one assertion still incorrectly expected an unpunctuated first-person fact. It was corrected to the existing canonical period contract, already pinned by MemorySelfTest. The final rebuilt production run passes. Raw failed runs are retained as evidence, not model-quality scores: [full-disk attempt](2026-09-30-p1-31c/final-production.txt), [post-cleanup assertion](2026-09-30-p1-31c/final-production-after-cache-cleanup.txt). Subsequent space cleanup removed only two completed P1-31b app snapshots, preserving the final baseline, installed weights and owner stores.

Builds use the standard Makefile prerequisites/configuration/scratch with a temporary serial recipe override (`--jobs 1`), as in P1-31b. Other agents' source changes remain in the shared working tree; they are validated/committed separately. Roadmap edits are local and ignored.

Generated Markdown evidence has trailing whitespace normalized for diff checks; raw transcript and JSONL sidecars preserve model output.
