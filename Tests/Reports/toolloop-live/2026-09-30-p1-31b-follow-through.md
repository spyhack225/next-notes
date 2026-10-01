# P1-31b — honest stops, broad mail grounding and follow-through investigation

2026-09-30 (America/New_York; run timestamps cross UTC midnight). Bounded Agent-overhaul work; parent P1-31, Phase 1 and SB-07 remain open.

## Implemented behavior

The shared claim guard excludes the exact “ran out of time” idiom occurrence from executed-read claims. A later “I ran the script” or “I sent the email” in the same reply still counts; “I ran out of timers” is not the idiom. The live grader recognizes the actual typed and spoken timeout renderer sentences, with and without an earlier verified result. An unfinished turn stays TIMEOUT, never PASS.

Broad mail requests no longer keep an account noun as a content filter: “summarize my recent email” must not become `query=email`. Existing grounding drops that invented filter while preserving a requested count. Explicit topics, quoted words and subject fields remain supported. This runs through the same grounding seam used by the ordinary planner and the Needle validator, with no extra model round or account lookup.

## Red-first evidence

- [Grader red](2026-09-30-p1-31b/grader-red.log): actual renderer timeouts were FABRICATED/MISSED_TOOL without work and PASS after a verified agenda read.
- [Shared guard red](2026-09-30-p1-31b/production-red.log): four idiom assertions failed.
- [Mail grounding red](2026-09-30-p1-31b/mail-red.log): all six account nouns plus the count/filter assertion failed on the original grounding code.
- [Candidate grader green](2026-09-30-p1-31b/after-toolloop-live-grader.log) and [candidate production green](2026-09-30-p1-31b/after-toolloop-production.log): `TOOLLOOP_LIVE_GRADER_OK`, `TOOLLOOP_PRODUCTION_OK`; Needle policy has zero problems.

Earlier reports remain historical. Their truncated reply sidecars cannot be faithfully regraded, and this change does not retroactively pass a gate. The fixed corpus, owner cases, pass bars and verdict priority are unchanged.

## Comparison method

Before and After are separately frozen, codesigned app bundles, using the same installed Qwen3-4B-Instruct-2507 Q4_K_M artifact. Before already contains the timeout/claim correction, so both comparison builds use the same grader. The implementation delta under investigation is mail grounding plus short save/draft/combined-read prompt hints and allowance for independent reads in one planning round. Neither execution authority nor concurrency/budget/approval code changes.

Both arms use `PromptConventionPlanner` (isolated `agentNativeToolCalling=false`, no `--planner` override); Needle-first remains a harness experiment. Fixed `--quick` and fixed existing `--only Y01,M04,O09` selections are used; the latter includes two canonical cases and one separately reported owner case. Partial attempts are not complete quality scores. No mailbox/calendar rows, verdict classes or case expectations were added.

[Artifact verification](2026-09-30-p1-31b/artifacts.json) records exact model and Needle bytes/hashes, verified off the turn path. Weights are reused in place, without copies or downloads. [Before provenance](2026-09-30-p1-31b/before-provenance.json) and [environment](2026-09-30-p1-31b/environment.json) record the frozen binary/source identities and concurrent dirty build context. No owner role, cleanup/default preference, model-library choice or cloud permission was changed; no cloud turn ran.

Timings measure the first returned fixture result and completed reply, not first token, audible response or live service latency. Base-model warm-up is excluded; Needle schema startup is included. Nearest-rank percentiles and varying result sample counts need the same care as P1-31a. App RSS excludes the Needle child. The shared Mac has 16 GiB RAM and is under substantial concurrent load; these are diagnostic runs, not reproducible promotion evidence.

## Interrupted runs and environment reds

The first Before Needle quick run exited 241 without a verdict/report; its cause is not established. One retry completed 4/10. A native ONNX/backtrace appears after that retry's FAILED marker; the completed score is retained without attributing the exception to a particular model or planner.

The first After ordinary quick aborted with `LLVM ERROR: IO failure on output stream: No space left on device`, before any case verdict. The next targeted attempt produced no report, and the controller also failed writing metadata for lack of space. These are absent results, not zero model scores. The completed 30-test dictionary build's disposable test compiler outputs were cleared; installed models and owner stores were preserved. Subsequent attempts are named `-retry`, leaving the original interruption logs intact.

`--selftest-voice-grounding` fails its user-identity assertion on both [After](2026-09-30-p1-31b/after-voice-grounding.log) and [frozen Before](2026-09-30-p1-31b/before-voice-grounding.log), with identical identity replies omitting Serge. The current red therefore predates these grounding/prompt changes. Native tools' earlier 4/5 grammar-valid red remains recorded in P1-31a; this work does not diagnose or promote that separate path.

## Results and decision

| Run | Result | Evidence |
|---|---|---|
| Before ordinary fixed quick | 5/10, complete; no WRONG_TOOL | [Report](2026-09-30-p1-31b/before-base-quick.md) |
| Before Needle fixed quick, one retry | 4/10, complete; no WRONG_TOOL | [Report](2026-09-30-p1-31b/before-needle-quick-retry.md) |
| Before ordinary Y01/M04/O09 | Incomplete; all 3 attempted, partial 0/2 canonical; O09 TIMEOUT | [Report](2026-09-30-p1-31b/before-base-targets.md) |
| Before Needle Y01/M04/O09 | Incomplete; all 3 attempted, partial 1/2 canonical; O09 TIMEOUT | [Report](2026-09-30-p1-31b/before-needle-targets.md) |
| Rejected After ordinary fixed quick, retry after disk recovery | 4/10, complete; two TIMEOUT, one WRONG_TOOL | [Report](2026-09-30-p1-31b/after-base-quick-retry.md) |
| Rejected After Y01/M04/O09 | Interrupted during warm-up; no case verdict, no score | [Interruption](2026-09-30-p1-31b/interrupted-warmup.json) |
| Rejected After Needle arms | Not run after the ordinary quality regression and warm-up stall | No paired Needle delta claimed |
| Final retained ordinary fixed quick | 5/10, complete; two TIMEOUT, zero WRONG_TOOL/ERROR/LEAK/FABRICATED | [Report](2026-09-30-p1-31b/retained-base-quick.md) |
| Final retained Y01/M04/O09 | Incomplete; all 3 attempted and TIMEOUT, partial 0/2 canonical | [Report](2026-09-30-p1-31b/retained-base-targets.md) |
| Final retained Needle M03 diagnostic | Unfiltered mail read executed; answer TIMEOUT, partial 0/1, not a complete score | [Report](2026-09-30-p1-31b/retained-needle-mail.md) |

The prompt experiment is rejected. Ordinary quick fell from 5/10 to 4/10, with two timeouts and one new WRONG_TOOL result (R02 read the calendar and added unsupported reminder controls). M04 did execute the fixture draft, but that isolated success does not establish a reliable improvement. Before Y01 failed to save in both paths; its Needle recall did not save. M04 passed in Before Needle-mode runs on the ordinary fallback (`class-does-not-fit`), so that pass is not attributable to an accepted Needle first call. O09 stopped unfinished in both Before paths. The later candidate targets never reached a case verdict. Heavy concurrent load prevents a causal latency claim; it does not supply evidence to retain the prompts.

The final source restores the original manifest rules and one-call planning instruction, retaining only the tested timeout/claim and mail-grounding fixes. The frozen After reports therefore describe a rejected candidate, not the final shipped implementation. The [rejected prompt patch](2026-09-30-p1-31b/rejected-prompt-experiment.patch) reconstructs both candidate prompt files exactly against their captured SHA-256 hashes. Final-build checks and fixed quick diagnostics must be reported separately.

## Verification

The rejected-candidate [build](2026-09-30-p1-31b/build-final.log) and [install](2026-09-30-p1-31b/install-final.log) passed using `make build` and `make install OPEN=0`. [Dictionary/spoken-form tests](2026-09-30-p1-31b/dictionary-tests.log): 30 tests in two suites passed. The [check ledger](2026-09-30-p1-31b/checks.json) retains marker lines and durations, including the separately explained voice-identity red.

The default retained-source rebuild stalled before compiler output under extreme host load (>180), and was interrupted. A temporary Makefile recipe override kept the existing `build` target, prerequisites, configuration and scratch path, changing only compiler concurrency to `--jobs 1`. No repository build settings changed. `make -f Makefile -f /tmp/nextnotes-p1-31b-serial.mk build` passed in 341.95 s; installation through the same Makefile with `OPEN=0` passed. [Final build](2026-09-30-p1-31b/retained-build.log), [install](2026-09-30-p1-31b/retained-install.log), [source identity](2026-09-30-p1-31b/retained-source.json) and [final binary/check provenance](2026-09-30-p1-31b/retained-provenance.json) distinguish this retained source from the rejected After candidate.

The owner reported no expected heavy work. A [host snapshot](2026-09-30-p1-31b/host-top.txt) showed about 15 GiB used, 5.5 GiB compressed, only 90 MiB unused, and 85 runnable processes despite CPU idle time. [Later memory snapshot](2026-09-30-p1-31b/host-memory.txt) showed recovery to about 1 GiB unused; no single cause was established. No other agent, browser or system service was terminated. Only owned stalled comparison/build/sample processes and disposable compiler outputs were stopped/cleared. These diagnostics do not prove that another agent or a specific model caused the host pressure.

Completed check markers: `TOOLLOOP_LIVE_GRADER_OK`, `TOOLLOOP_PRODUCTION_OK`, `TOOLLOOP_OK`, `CAPABILITY_MANIFEST_OK`, `TOOL_AWARENESS_OK`, `VOICE_TURNS_OK`, `VOICE_SCHEDULING_OK`, `USAGE_LOG_OK: 25 cases`, `STORE_ISOLATION_OK: 18 files and 23 defaults unchanged`. Voice grounding is the separate matched Before/After red above.

Final retained-build deterministic checks passed: [grader](2026-09-30-p1-31b/retained-toolloop-live-grader.log) `TOOLLOOP_LIVE_GRADER_OK`, [production](2026-09-30-p1-31b/retained-toolloop-production.log) `TOOLLOOP_PRODUCTION_OK`, [capability manifest](2026-09-30-p1-31b/retained-capability-manifest.log) `CAPABILITY_MANIFEST_OK`. The restored manifest prompt is 1,674 tokens for 16 tools (candidate was 1,747), and the small-reader case is 1,125 tokens for 8 tools. Final fixed quick is 5/10, matching the fresh Before count but below the 9/10 gate; case classes differ, so this is no claim of equivalent case-level quality. Before C01 passed and C04 refused after one read; Final both timed out without a read. Final M04 executed a draft while Before ordinary M04 only printed draft prose. M03/M05/R02/N04 pass in both. Final quick has zero WRONG_TOOL/ERROR/LEAK/FABRICATED; timings remain worse under host pressure.

The final targeted Y01/M04/O09 selection attempted all three and timed out on all three: partial 0/2 canonical, never a completed zero score. Y01's 113.251 s elapsed stop also shows that a nominal planner ceiling does not by itself guarantee prompt cancellation under this host pressure; latency/cancellation remains parent work.

The separate final Needle M03 diagnostic accepted the same low-confidence `search_email` first tool as Before (0.2806). It now executed `search_email` without the invented `query=email`, returning the broad fixture mail result at 12.818 s. The later model answer timed out (72.411 s overall): this is execution/grounding evidence, not a passing end-to-end M03 result or a paired Needle quick score.

The final quick first-result p50/p95 is 18.931/25.710 s (n=6), completed-reply 33.532/59.912 s (n=11), whole-case 37.771/59.912 s (n=10), with app peak RSS 3,327,836,160 bytes. Before ordinary quick whole-case p50/p95 was 22.859/52.104 s; no speed improvement is claimed. [Fixture identity](2026-09-30-p1-31b/fixture-identity.json) confirms the fixture implementation remains identical to `ac3b852`; case/grader hashes in Before, rejected-candidate and final provenance match across these comparisons.

Decision: retain the bounded semantic fixes, keep the ordinary planner and all owner choices, and leave parent quality/latency gates open. P1-31b does not solve the live save/draft/compound completion problem, the pre-existing voice identity/native-tool reds, or shared-runtime admission. Next bounded work should reproduce a missing explicit save/draft through the existing runner and fix its cause; do not add another prompt/model round, lower the gate or promote Needle from these results.
