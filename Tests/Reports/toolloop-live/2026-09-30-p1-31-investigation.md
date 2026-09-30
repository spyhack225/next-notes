# P1-31a — Needle first-step policy and paired local-model investigation

2026-09-30. This is a bounded implementation slice of AGENT-OVERHAUL P1-31, not a Phase 1 exit or a recommendation flip.

## Changes under test

- Give the active Agent an abstention description that permits questions, reads and searches. The passive meeting watcher keeps its own description.
- Validate the first call against its manifest entry, required parameters, existing value-shape/grounding rules and identifier guard. Drop backend-flagged arguments; reject a failed response, backend-reported negation, unknown tools, invented required values and unsolicited writes on informational questions. Confidence is recorded, without a universal threshold.
- Keep a preliminary memory recall in the same `ToolStepRunner` state and continue a save objective rather than answering as though the save happened.
- Apply the existing `ToolClaimGuard` to the answer-only round too. Preserve the verified result and the completion-limit signal; no extra model pass is introduced.
- Make `AgentCapabilityInputs.live(reader:)` honor the harness's fixture inputs while retaining the actual model reader. Previously only `AgentCapabilityManifestRuntime.current` honored the override; the production planner rebuilt from this Mac's grants/account state. The denial fixture exposed this by skipping an oversized real catalogue instead of executing its one-tool fixture.
- Record first fixture-result and completed-reply timings, Needle outcomes/confidence, artifact identity and process snapshots in the existing live-eval reports. Needle attempts use the existing isolated `usage.jsonl`, once per attempted engine pass.

The first-call branch remains behind `SelfTest.isRunning && needleFirstForTesting`. Normal turns retain the existing planner. No role default, cleanup setting, tool authority, task ledger, audio scheduler or model file was changed. No cloud comparison was run.

## Red-first evidence

[Initial policy red](2026-09-30-p1-31/policy-red.txt) caught seven failures: the wrong abstention description, an unsolicited calendar write, invented/missing/flagged recipients, an invented document identifier and recall completing a save objective.

[Claim/denial red](2026-09-30-p1-31/claim-and-denial-red.txt) caught the unexecuted-send claim and the denial fixture's bypassed roster. The latter was a harness failure, not evidence that a real denied write was retried. [Intermediate harness output](2026-09-30-p1-31/harness-red.txt) preserves that distinction.

[Production green](2026-09-30-p1-31/production-green.txt): `TOOLLOOP_PRODUCTION_NEEDLE: 0 problem(s)` and `TOOLLOOP_PRODUCTION_OK`. Cases also pin valid reads/sends, engine failure/timeout fallback, answer-only and oversized-class engine skips, one duplicate-call ledger, one Needle usage row and terminal denial. The old reply-scrub test now explicitly pins its unavailable-file-index precondition, so the repaired all-enabled fixture does not route that test into a real file search. Its original scrub assertions remain.

`make build`, `make install OPEN=0` passed; `make test`: 30 tests in 2 suites passed.

## Measurement method

Both arms use the same frozen, codesigned app bundle and exact existing model files. [Provenance](2026-09-30-p1-31/provenance.json) records binary/source/model/Needle SHA-256 hashes, file sizes, commands, host load, exit markers, sampled app and Needle-child RSS, and free disk. The four installed candidates are Qwen3-4B-Instruct-2507, MiniCPM5-2B, Gemma 4 E4B and Qwen3.5-4B, all Q4_K_M. The fixed case definitions and grader are unchanged. Fixture instrumentation adds timing only.

Timing starts at each `handle` call. First result means the first returned fixture result, not a live service response or a correct-answer verdict. Completed reply means the return of the reply, not first token or audible response. Base-model warm-up is outside the measurement; Needle schema startup is inside it. Percentiles use nearest rank. First-result sample counts can differ when an arm never calls a tool. App RSS excludes the Needle child; the separately sampled peaks need not occur together. Memory samples are every two seconds and can miss short-lived peaks.

This is a shared Mac under other work. Thermal state and load are retained. Single-run timing/quality observations do not establish reproducible superiority or satisfy the two-run promotion gate. The preliminary [ordinary 9/10](2026-09-30-p1-31-qwen3-base-quick.md) and [Needle 7/10](2026-09-30-p1-31-qwen3-needle-before-quick.md) used the faulty harness roster and are not a matched improvement baseline for the corrected runs.

## Paired results

| Agent candidate | Ordinary fixed quick | Needle-first fixed quick |
|---|---:|---:|
| Qwen3-4B-Instruct-2507 | 5/10 | 6/10 |
| MiniCPM5-2B | 2/10 | 3/10 |
| Gemma 4 E4B | 5/10 | Incomplete: 5/10 attempted, Needle timeout |
| Qwen3.5-4B | 2/10 | Incomplete: 7/10 attempted, Needle timeout |

The quick gate remains **9/10**. Neither complete Needle arm met it. Partial attempts are not model scores; the raw reports preserve `TOOLLOOP_LIVE_PARTIAL`/`INCOMPLETE`. No automatic retries were used.

| Full Qwen3-4B run | Canonical score | Owner cases, separate | Whole-case p95 |
|---|---:|---:|---:|
| [Ordinary planner](2026-09-30-p1-31/qwen3-base-full.md) | 17/30 | 7/10 | 49.038 s |
| [Needle-first](2026-09-30-p1-31/qwen3-needle-full.md) | 16/30 | 8/10 | 51.012 s |

The full gate remains **25/30 on two consecutive runs**, with O01–O09 passing. These are one full run per arm, not two gate runs of one candidate. Both failed quality; Needle's whole-case p95 was also worse. Both have 0 LEAK/ERROR/WRONG_TOOL in the full result tally. The Needle report has one FABRICATED label, discussed below.

## Latency and resource evidence

Both full arms used `PromptConventionPlanner` for System Two (isolated harness default `agentNativeToolCalling = false`, no `--planner` override). Needle-first replaces only an accepted first planning step. Neither native-mode promotion nor voice latency was assessed.

| Full Qwen metric | Ordinary p50 / p95 | Needle-first p50 / p95 |
|---|---:|---:|
| First verified fixture result | 9.047 / 29.090 s, n=26 | 2.994 / 28.805 s, n=29 |
| Completed reply | 13.545 / 49.038 s, n=43 | 14.474 / 46.432 s, n=43 |
| Whole case, including follow-ups | 13.831 / 49.038 s, n=40 | 14.143 / 51.012 s, n=40 |

The Needle full arm recorded 13 accepted calls, 7 abstentions, 6 rejected proposals and 5 oversized-class skips, with no engine error. The quick arms accepted only two first calls each; several apparent pass changes occurred on turns that fell back, so those changes cannot be attributed to Needle selecting the first tool. Confidence was not a reliable universal switch: a calendar question produced an unsolicited `create_event` at high confidence and was rejected by validation, while a low-confidence `search_email(query=email)` was accepted but answered the wrong search objective.

Memory and disk figures are in provenance and each report. All four GGUF files were reused in place; no weights were downloaded or copied. A temporary 133 MiB app copy held the executable constant during concurrent work. The Mac has 16 GiB RAM; reported thermal state was fair. These are contended-machine diagnostics, not isolated or overlap admission measurements.


| Full run | App peak RSS (self-reported) | Sampled Needle child peak | Free disk before / after |
|---|---:|---:|---:|
| qwen3-base-full | 2.927 GiB | 0.0 MiB | 13.46 / 11.75 GiB |
| qwen3-needle-full | 2.938 GiB | 99.2 MiB | 11.75 / 14.22 GiB |

## What remains red

- **Y01 save objective:** Needle's recall now reaches System Two's continuation rather than the premature answer-only exit. The live Qwen model still answered “I'll keep that in mind” without `memory.remember`/`memory.update`. Policy continuation is fixed; live save quality is not.
- **M03 broad mail read:** Needle selected the literal filter `email`; the valid empty-result reply and repair note did not make System Two read the requested recent mail.
- **M04 draft:** the model wrote “Drafted” or offered a draft without calling `draft_email`. The existing claim grammar catches explicit “I sent” but not every unsupported progress/status phrase.
- **F03/A02 and O08/O09:** file search must continue through addressing/drafting; a video must be clicked/played; the trip document must be resolved then updated; combined mail/calendar work must complete both reads. O08 and O09 failed in both full arms. Ordinary O01 also failed its grounding check; Needle O01 passed.
- **Grader limitation:** the fixed `ToolClaimGuard` phrase `i ran` matches the app's honest “I ran out of time before finishing the rest.” `LiveEvalGrader.timeoutPatterns` does not recognize that stop sentence, so an unfinished turn with no call becomes FABRICATED. This explains C01 in the Needle full report and the corresponding labels in the partial/ Qwen3.5 quick reports. These are unfinished turns, not evidence of an invented completed action in those replies. The grader was unchanged between arms; no case was removed or relabelled to pass a gate.

## Decision and remaining P1-31 work

**Keep the ordinary planner as the normal Agent path.** Do not flip the Agent model or recommend Needle-first. MiniCPM cleanup remains owned by the OpenCode executor; these Agent scores do not judge cleanup or notes quality. Independent workload choices and exact shared-file reuse remain the architectural direction.

P1-31a completes the first-call policy/harness/reporting slice. Parent P1-31 remains in progress: full paired reports for the other local candidates and Ling when authorized/available; live negative-case measurements; first-token/audible and overlap latency; repeated promotion runs; and the unresolved quality cases above. SB-07 is not complete.

Next bounded task: pin the honest-stop/claim-classification defect red first, then fix explicit write/combined-read follow-through through the existing manifest, runner and budget. Preserve the fixed cases, owner-case rules and thresholds. Re-run matched arms on any changed implementation before a recommendation.

## Regression verification

| Check | Result | Evidence |
|---|---|---|
| Build / install | Passed; final rebuilt app installed with `OPEN=0` | [Build/install output](2026-09-30-p1-31/build-install-final.txt) |
| Dictionary/spoken-form suite | 30 tests in 2 suites passed | [Test output](2026-09-30-p1-31/dictionary-tests.log) |
| Production tool loop, final rebuilt app | `TOOLLOOP_PRODUCTION_OK`; Needle policy 0 problems | [Final log](2026-09-30-p1-31/toolloop-production-final.log) |
| Usage log, final rebuilt app | `USAGE_LOG_OK: 25 cases` | [Final log](2026-09-30-p1-31/usage-log-final.log) |
| Fixed live grader | `TOOLLOOP_LIVE_GRADER_OK` | [Log](2026-09-30-p1-31/toolloop-live-grader-regression.log) |
| Capability manifest | `CAPABILITY_MANIFEST_OK` | [Log](2026-09-30-p1-31/capability-manifest-regression.log) |
| Tool loop | `TOOLLOOP_OK` | [Log](2026-09-30-p1-31/toolloop-regression.log) |
| Voice turns / scheduling | `VOICE_TURNS_OK`, `VOICE_SCHEDULING_OK` | [Turns](2026-09-30-p1-31/voice-turns-regression.log), [scheduling](2026-09-30-p1-31/voice-scheduling-regression.log) |
| Owner store isolation | `STORE_ISOLATION_OK: 18 files and 23 defaults unchanged` | [Log](2026-09-30-p1-31/store-isolation-regression.log) |
| Native tools | **FAILED** on two runs: llama 4/5 grammar-valid, 1/4 tool prompts called a tool; Apple 5/5, cloud absent | [First](2026-09-30-p1-31/native-tools-regression.log), [repeat](2026-09-30-p1-31/native-tools-repeat.log) |

The [first regression run](2026-09-30-p1-31/regressions.json) retains both reds. Usage E1 required an `answer` header row that P1-02 had already removed from typed turns. Its corrected assertions require exactly the two real planner rows (read and reply), the verified-read answer, and no restored header round; provider/model/correlation/tool/privacy assertions remain. This is a test-protocol correction, not an extra inference pass.

NativeToolsSelfTest builds its own all-enabled fixture directly and invokes `LlamaGrammarPlanner.round`; it does not exercise the new `.live(reader:)` override, Needle first step or final-answer guard. Its current red is therefore recorded separately, with no demonstrated cause or matched pre-change live baseline claimed. Both runs failed the same grammar-valid count. Raw completions are not exposed by that diagnostic, so a token-cutoff explanation remains a hypothesis. Native mode stays disabled; no threshold was weakened. This is not an all-green regression suite or a Phase 1 exit.


Build provenance includes concurrent uncommitted work; [source snapshot](2026-09-30-p1-31/source-snapshot.json) records that context. After the frozen comparison, the claim-guard comment and denial self-test assertion were strengthened, and UsageLogSelfTest was corrected to the existing P1-02 typed protocol. These subsequent changes are comments/tests; the compared runtime behavior is unchanged. The final rebuilt app passed the production and usage gates above.
