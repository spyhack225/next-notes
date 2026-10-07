# Continued dictation optimization — 7 October 2026

## Current verdict

The [shared optimized baseline](2026-10-07-shared-release.md) still misses the complete-delivery target on long holds. A full-input layout preparation experiment was implemented, exercised through production consumers, and **removed after native replay showed no useful speedup**. The retained changes are immediate cancellation of the existing layout task, bounded local-planner caller deadlines, fixed-regex reuse, an ASCII sentence-splitting fast path and a quote-to-word rendering repair. Features, model choices, quality assertions and deadlines remain. The eight-word quote bound now counts the same whitespace-delimited spoken words as marker stripping; apostrophes no longer count as extra removable words.

**Universal two-second polished delivery remains unachieved.** Recognition, live display and semantic tail cleanup are much faster than the independent full-passage layout pass. Short native cases can already finish near116–128ms in the shared baseline; those figures must not be extended to long dictation or physical external-field delivery.

## Native complete-path replay of the rejected preparation experiment

Signed optimized37817, binary SHA256 `9c57531fd7c59fd8942deeada6a11852babd780744f8bea5f6b5019ef7da4e12`, follows the same121.18-second public WAV and independent gold as the shared baseline. Actual Parakeet, controller factory/live-chunk consumer, incremental cleanup, finishing router and isolated insertion run twice in one process. Grammar/structure stay enabled; busy-route skipping is off; budgets are unchanged. Empty isolated screen context and plain path-reference profile mean the audio replay does not exercise file tagging. The actual router has a separate file-tagging regression. No owner history, microphone or destination is used.

| Round | Startup before feeding | First live text | Final recognition after release | Text ready after release | Tail generation | Layout |
|---|---:|---:|---:|---:|---:|---|
|1|21,886ms|506ms|37ms|6,101ms|404ms|6s timeout|
|2, same process|0ms|495ms|30ms|6,251ms|492ms|6s timeout|

Both rounds have live text at release,30 selected/answered heads,1,297cached prompt tokens and raw/final strictWER5.1%. Head completion may be a formatter fallback;30answers do not prove30accepted semantic repairs. Explicit cleanup preparation separately takes3.359s. ASR startup is outside feeding/readiness timing, not eliminated by preloading a different model. Functional `DICTATION_POLISH_OK` / `DICTATION_SEGMENTS_OK` means finishing completes, not that latency or formatting quality passes.

No exact final-input layout is ready for reuse. The latest full snapshot changes faster than the native planner answers, so coalescing alone does not catch up. Compared with baseline6.204/6.317s, these observations establish **no causal end-to-end improvement**. Extra preparation/model work is therefore not retained. Controller, incremental-session and trace source are restored byte-for-byte to the pre-experiment snapshot; source pins and the experiment patch remain for reproduction.

### Native resource limits

One staged diagnostic runs at a time under the agent-relay machine claim; no compiler competes with the replay. The installed owner app remains active. Prelaunch coarse gate reports swap7.35GB/free8.22GB; headroom falls near7.7GB during launch, then recovers. This is not an idle pristine host or a paired contention control.

A PID/start-time-bound, read-only libproc sampler takes426samples every0.5s, beginning after startup and roughly45s into speech. Observed app footprint is328,436,256→196,167,048bytes, maximum340,085,280; RSS maximum688,193,536. This omits startup/early speech and Apple-hosted services, so it is neither whole-machine memory nor full-lifecycle peak. Twelve retained native cleanup records have median0.555s/max0.96s generation; logs do not cover every head and this is not decode-only throughput-floor evidence.

## Retained layout cancellation producer repair

Originally, cancelling the actual router while semantic cleanup is held leaves its entered layout task uncancelled until the semantic call returns. Original signed35028 fails this assertion. The same layout task is now enclosed by the router's cancellation handler and cancelled on every exit. Actual held-planner/held-semantic consumers verify cancellation **before releasing semantic cleanup**, then release/join both owned tasks. Retained signed40182 and41800 pass.

This forwards cancellation to the existing owner; it does not prove immediate cessation of uncancellable Apple native inference. No model pass, queue, store, timer, budget or fallback is added.

### Scripted experiment history, kept separate from production

Original35028 also fails two preparation-feature assertions. Its scaffold produces no ready layout, so the250ms finishing wait is not independent proof of repeated completed native work. Fixed35518 passes these three cases.35923 reproduces late partial overwriting final ownership;36151 also reproduces nominal-budget reset.36425 passes these, latest-only coalescing and actual controller factory/live-chunk/runTail/isolated-delivery checks.36975 reproduces an introduced pending-final request waiting behind obsolete work;37454 repairs that same case. These are scripted producer/consumer checks, not native layout judgment or latency acceptance. All preparation code is now archived and removed from production.

## Retained CPU improvements

| Producer | Exact-output verification | Optimized implementation fixture |
|---|---|---|
|`RuleBasedFormatter`|768inputs;5,392final/partial/async/concurrent checks;0failures, including the existing golden corpus|100passes: original160.95–167.11ms, compiled fixed patterns65.30–66.14ms; about0.96ms saved per pass|
|`SentenceChunker.sentences`|2,896inputs;28,960sentence/grouping/concurrent comparisons;0failures, plus8maintained boundary cases|100splits of14KB ASCII: original69.83–71.59ms, candidate14.67–15.55ms; about0.55ms saved per split|

These are serial interleaved optimized source fixtures with owner apps still active, not full app percentiles. The first regex comparison ran during the optimized build; the retained serial comparison avoids that confound. Rules preserve pattern order/templates and partial-versus-final punctuation. Unicode, decomposed accents, emoji, decimals, email addresses, whitespace and paragraph boundaries retain exact outputs. The sentence fast path scans ASCII UTF8 ranges without allocating a character array; Unicode and CRLF use the exact existing grapheme scan. A generic String-index rewrite showed negligible benefit/an outlier regression and is rejected.

The first staged41530 has one **new fixture expectation error**, not an original/current output mismatch: the new vertical-tab/form-feed case expected those separators trimmed, whereas both old and candidate retain them. A same-input original/candidate probe records identical arrays.41800 corrects that expectation to the existing contract; it does not change the optimized producer or weaken a pre-existing quality assertion. The erroneous fixture/source pin and actual verdict remain in evidence.

## Native planner output investigation — no promotion

A separate signed runner uses the actual FoundationModels responder, full production schema/system/user prompts, temperature0.1/token cap500, strict validator, announcement corroboration, renderer and unchanged six-case quality corpus. Only logging/test-output sinks are replaced. It does not exercise the router, deadline, prewarm or complete dictation path. Each case uses a fresh session; the first call may include native cold work. A150s watchdog bounds the diagnostic, not production. Calls are sequential after the long replay and builds join.

The **original full schema fails14quality assertions**. Raw outputs locate the producer problems:

- Counted/mixed cases emit separate one-item lists, although the renderer requires two items per list block.
- Several ranges overlap or extend outside the numbered source sentences.
- The French enumeration returns ordinary prose; the announced French case generates one item instead of the list.
- One announcement contains nine words, exceeding the unchanged eight-word evidence limit.

A conditional typed schema encodes list-only metadata and the two-item floor, retaining every existing prose/list/quote/code representation, strip bound and final validation. It also **fails14assertions**: generated ranges/items still overlap, duplicate or escape input. All six typed plans fail shape validation; the full schema has four shape rejections and two shape-valid plans, one of which still misses expected French structure. Equal assertion totals do not establish equal quality. The typed experiment is not promoted. Faster rejection is not a feature-preserving formatting solution.

## Local planner deadline producer repair

The actual `LLMStructurePlanner` used a throwing task group to race its provider against a timeout. Leaving the group joined the cancelled responder, so a nominal six-second warmup took **12.033s** in signed debug42401. The provider availability await also occurred before the deadline began.

Signed original43327 fails two unchanged assertions through the real planner/provider seam: a held response delays caller return beyond its requested deadline; held availability sits outside the same budget. The responsible planner now bounds the caller with the existing wait seam, forwards cancellation to the same retained response task and includes availability in that budget. It checks cancellation again before generation so late availability cannot launch a cancelled request. Signed43576 passes both original assertions and the additional late-request negative. No timeout, token cap, grammar, model selection, queue or retry changes.

Native debug43576 warmup returns in6.010s, with native completion joined separately at the private runtime's shutdown. This is caller responsiveness, **not immediate native cessation**. Production's automatic layout route still selects Apple; fixing the existing local planner does not silently promote it or establish an owner-path speedup.

## Native local layout judgment and lost-word diagnosis

The existing six-case plan leg can now explicitly use `--plan-model minicpm` with a private runtime and the exact full production grammar, prompt, validator, corroboration and renderer. It changes no saved role and joins that private native owner before termination. `--plan-details` prints the actual decoded plan. Optional `--plan-prepare` separates completed native cold loading from the graded warm cases; a bounded warmup alone cannot establish native readiness.

Original debug42401 local cases take2.147–5.905s, upper-middle5.032s, and fail three mixed-layout assertions. Debug43576 and details43978 retain the same three failures; their first graded case also times out around6.09s because native cold loading has not finished after bounded warmup. These observations are neither an optimized full-dictation comparison nor a local default recommendation. They do show that replacing Apple with the existing local planner would not establish universal two-second delivery.

Details43978 reveals a source-level accuracy error on P4, even though the model's plan is correct. The model quotes `D'abord`, requests zero count-based stripping and groups the three French items correctly. The renderer treats that quote as **two lexical pieces**, then removes **two whitespace-delimited words** from `D'abord on règle la facturation.` The resulting `Règle la facturation.` loses `on`. Curly apostrophes and hyphenated words have the same unit mismatch. Separately, a verified quote located later in the sentence incorrectly authorized deletion of unquoted opening words.

The producer now retains the normalized match range and maps a verified opening quote to complete original spoken words. A later match, or one ending inside a word, removes nothing. Existing non-prefix corroboration remains supported; this fix does **not** prove those quoted words semantically announce a list. Unverified/absent quotes retain the existing bounded count fallback. The no-added-words invariant remains and is no longer described as a no-deletion guarantee. Shape validation keeps the eight-spoken-word bound, with an explicit nine-word rejection.

Corrected signed original45343 fails **seven assertions**: both renderer and actual router lose unquoted opening words; straight/curly apostrophes and a hyphen lose content; the actual router reproduces P4 word loss; an eight-spoken-word quote is incorrectly rejected as eleven lexical pieces. The exact native P4 component input/plan is preserved; the router fixture appends unchanged prose solely to enter its existing greater-than60-word planning admission. These are explicitly different scopes. The initial44648/45034 scaffold mistakenly omitted the router formatting switches; its two consumer failures were fixture errors. Both switches are enabled in45343, which again reproduces all seven failures, including the actual model-plan trace. Optimized signed45909 passes the identical seven assertions plus all existing router and structure checks. Its actual native six-case probe explicitly completes private weight preparation first (0.234s), then the ungraded warmup (5.117s). P1 now returns valid prose in4.287s, P2 list2.117s, P3 French list5.795s, P4 French list3.278s, P5 prose5.003s and P6 rejects the same one-item list in3.932s. P4 now retains exactly `On règle la facturation.` with the same quoted announcer and zero counts. The suite still reports **CLEANUP_FAILED3** for mixed layout and **CLEANUP_PLAN_NATIVE_JOINED**; upper-middle4.287s/max5.795s are model-only observations, not full-path latency or percentiles. Debug/release runs are not a paired speed comparison. Completed weight loading alone does not eliminate first-generation preparation. The exact quote regression body is moved into the responsible producer and invoked directly by the maintained router flag, with final signed debug47042 passing the same maintained router/structure checks. Its store-isolation assertion reports21files/33defaults unchanged, while the embedded browser production suite still reports18inherited failures despite launcher exit0. Relocation changes no producer algorithm; the optimized and final debug algorithm sources are checked against each other after removing only that test block.

## Logs, remaining work and integration scope

The latest read-only owner usage rows still end18:57:36UTC, before the final shared install. Recent historical complete holds take2.60–5.08s. No new owner run exists to judge the shared installed build. Metadata exports exclude dictated text, destinations and payloads.

Optimized45909 passes actual cleanup-router/structure, dictation/hygiene/segments, commandkey and duplex flags. The two inherited duplex reducer divergences remain in the log. These functional passes do not establish complete latency acceptance. Earlier41800 passes actual cleanup-router and cleanup-structure checks and `DICTATION_OK`; injected1.5s startup feeds38,137 of approximately40,000nominal pre-roll frames and records79ms key-down-to-capture. That is a scheduling-dependent injected fixture, not physical cold ASR/capture acceptance.40182 also passes duplex and commandkey; final41800 duplex verification is recorded separately. Earlier store isolation preserves21files/33defaults while its embedded A02 browser/tool-loop suite retains18inherited failures. No exit0 or functional OK converts those failures into a quality pass.

Next substantive work remains native layout judgment/efficient full final-tail coverage, cold recognizer/model preparation under shared load, paired accuracy and physical capture/Enter/external-field insertion. Do not reuse a stale layout for unseen text, append a tail as presumed prose, cut deadlines, silently replace the selected model, or remove formatting/file tagging to claim the target.

Cleanly owned rule/sentence CPU source, Apple/local caller deadlines, quote rendering and its maintained producer/router test, and the opt-in native planner diagnostic are integrated through a private Git index. The maintained sentence/quote calls are added against the existing HEAD router seam. The router cancellation repair, local held-provider fixture and earlier full-pipeline repairs remain explicitly retained in the canonical shared working tree, with source pins and producer-only patches; their files contain other shared work and are not staged wholesale. These tests run the pinned canonical shared tree, not an independently rebuilt clean HEAD checkout. The other seven staged files remain byte-identical. The roadmap update is retained locally under its existing ignore rule. The installed owner app is not replaced: `AGENTS.md`'s native-shutdown contract holds installation. This is bounded optimization, not roadmap-phase completion or default promotion.

Evidence and exact pins: [layout replay](2026-10-07-evidence/layout/long-warm.log), [native bundle](2026-10-07-evidence/layout/native-bundle.json), [retained bundle](2026-10-07-evidence/layout/retained-final-bundle.json), [rule comparison](2026-10-07-evidence/layout/rules/comparison-serial.json), [sentence comparison](2026-10-07-evidence/layout/sentences/ascii-comparison.json), [full-schema output](2026-10-07-evidence/layout/planner/full-schema.log), [typed output](2026-10-07-evidence/layout/planner/typed-schema.log).

## Artifact lifecycle

All owned compilers, launchers and native diagnostic owners have joined. Superseded original/debug/native bundles and completed standalone comparison executables are removed after exact path/hash/process checks; compact sources, patches, signatures and actual verdicts remain. This continuation reclaims **4,440,801,280 allocated bytes (4.14GiB)**, excluding prior-turn cleanup. Keep shared30744 (installed owner baseline), optimized45909 (native/functional candidate), debug47042 (current maintained regression candidate) and the reusable shared scratch. No worktree is created; models, recordings, user stores and other agents' artifacts are untouched. [Lifecycle receipt](2026-10-07-evidence/layout/artifact-lifecycle.json).
