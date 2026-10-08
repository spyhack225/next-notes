# Dictation continuation: finishing preview and constrained layout transport

## Verdict

The release-to-final latency goal remains open. The actual finishing controller now publishes completed semantic/deterministic cleanup while its independent layout pass is pending. The maintained original regression fails; the changed router/controller passes it. Three native compact layout transports are faster in their isolated warm diagnostics but fail existing formatting assertions. They were opt-in experiments and are now archived outside production, not promoted or counted as an accuracy-neutral speedup.

This report continues [the pipeline/layout analysis](2026-10-07-layout-preparation.md). All features, production model choices, token caps and caller deadlines remain. These measurements do not establish physical microphone, displayed frame or external-field insertion latency on the reference MacBook Air.

## Latest actual owner logs

Read-only owner metadata, 7 October at 23:52:51/23:53:20 UTC, supersedes the earlier report's historical “latest row” observation. Dictated text, app destinations and payloads are not exported.

| Actual hold | Final words | Processing after hold | Observed dominant work |
|---|---:|---:|---|
|38.689s|128|3.612s|Apple layout reaches its 3.5s deadline; semantic tail field is 1.191s and three incremental groups answered|
|1.909s|5|11.534s|ASR67.84ms + drain4.44ms; cleanup11.447s; injection132.09ms|

The short row reports a resident cleanup runtime, staged session, cleanup timeout fallback and Apple as the used engine. Its timing is consistent with the warm short local cleanup budget (8s), followed by Apple fallback. The usage log aggregates cleanup under Apple and supplies no failed-local-attempt phase/token counters. Therefore **the local stall's native cause is unproven**; residency is not evidence of readiness, and these logs cannot distinguish paging, prefill, scheduler parking or decode delay. No capture/stream drops are reported in these rows. The ASR stage is not the dominant observed delay in either run.

## Producer repair: publish cleanup before layout finishes

The router previously held its completed semantic/deterministic text until the independent full-input layout plan resolved. The finishing controller likewise kept displaying the previous raw transcript throughout that wait. The same actual `CleanupRouter.format` and `DictationController.runTail` now carry a synchronous optional progress sink through their existing formatter seam. It publishes only after semantic cleanup and deterministic rules are complete, and only while layout is still pending. No additional await, model pass, timer, queue or store is added.

The controller accepts progress only for its current finishing session. A per-invocation active flag closes when the formatter returns or its caller deadline expires, so queued progress cannot overwrite the final result. The complete formatted result and subsequent dictionary/file-tag output are also reflected in the finishing transcript. External typing, history, parsing, file tagging and final delivery retain their existing finalization path. Live recognition stays visible throughout the wait.

The maintained regression uses the actual observable controller/router and a held scripted layout producer. It verifies cleaned text arrives before layout release, external delivery stays empty, the same layout task subsequently supplies the final paragraph result, and the final consumer receives all content. Stale session and completed-state progress are refused. The fixture uses an isolated settings harness, temporary usage log, no microphone, owner history or external destination.

- Original signed debug54148: unchanged maintained assertion fails (`CLEANUP_FAILED`, missing finishing preview).
- Fixed signed debug54491: `CLEANUP_ROUTER_OK`, including the original assertion and related router checks.
- A prior equivalent scaffold53810 also fails the same preview contract; the maintained fixture replaces its unnecessary dependency on newer admission/context test seams.

After the debug pass, frozen source additionally records `DICTATION_POLISH_PREVIEW` cleanup/final readiness in the existing replay diagnostic. This is **observable transcript publication, not physical paint**. Its raw WER counter now captures the final ASR chunk itself, so displaying polished text cannot contaminate the “raw ASR” score. Those final small logging/reset/identical-value guard changes are compiled in shared optimized57481 and verified by the fixed debug61082 maintained router path. Native complete-path publication timing and physical paint remain open.

## Native layout transport experiments

Each signed debug trial runs the existing six-case plan corpus through a private MiniCPM runtime, real prompt/grammar, existing validator, announcement corroboration and renderer. Cold weight preparation finishes explicitly before graded cases. Native completion joins before exit. The production full-schema route remains the default; the diagnostic alone enables `--plan-compact`.

| Transport | Warm upper-middle (6cases) | Warm maximum | Existing failed assertions | Decision |
|---|---:|---:|---:|---|
|V1 tuple ranges/items, shorter semantic prompt|1.423s|1.615s|5|Do not promote|
|V2 same tuples, original semantic rules plus wire examples|1.108s|1.350s|10|Do not promote|
|V3 named item starts, implicit block starts, original semantic rules|1.527s|2.157s|6|Do not promote|

These are not optimized full-pipeline results or percentiles. Comparison with the previous optimized full-schema trial is not a paired speed benchmark. Explicit weight preparation varied (V1 11.897s, V3 6.946s); it must not be included in a claim of warm latency or assigned causally to one transport.

The source-dependent grammar constrains coverage/order, sentence ranges, increasing item starts, the first item start, the two-item floor and strip counts. It retains prose, numbered/bulleted lists, quote/code blocks, multi-sentence items, per-item counts and exact quoted evidence. Existing limits on total blocks/items and spoken quote length remain in the final validator: the grammar does not establish every validator bound by construction.

Geometry validity does not establish semantic grouping. V1 misses a first item and French announcers; V2 worsens boundaries and mixed layout. V3 repairs one English case but merges French/English items, misclassifies a French introduction and includes closing prose in a list item. The corroboration guard still refuses unsupported lists. Faster valid geometry does not repair those failures. The pinned first shared bundle contains the opt-in V3 diagnostic; its native quality gate is explicitly red. After source acceptance, the rejected prototype and its exact owned constructor/router hooks were archived and removed from the canonical production source. The existing full planner and all features remain.

## Producer repair: cancelled parked work

The original actual scheduler source reproduces twelve failures across six cancelled parked jobs (background/meetingLive/realtimeAgent, cancellation before/after waiter registration): none joins or leaves the parked queue while ASR is held. The unchanged candidate fixture passes these cases, twenty release/cancel ordering races and the existing priority regressions. The same assertions are maintained under `--selftest-scheduler`; actual signed fixed debug61082 passes them.

Signed original debug60376 then reproduces **three actual native consumer failures**, using a private S1-mini runtime and the exact `completeForDictationCleanup` entrance. A real successful native prefill observer starts a held scheduler ASR job; the fixture verifies its registered parked checkpoint before cancelling the same cleanup Task. After250ms the native owner is still retained, the scheduler still holds its cancelled parked job, and a successor reports `the model is busy with other work`. The fixture releases only the retained ASR UUID, joins the original cancelled producer and checks private termination. This ASR reservation is real scheduler state, not an actual concurrent Parakeet inference or microphone session.

The responsible `checkpoint` now observes cancellation through its existing waiter map and existing `cancelWaiter`; no second queue, store, native pass or production timer is added. Cancellation removes only the parked/queued job. The currently running ASR job remains held. Native generation already calls `checkTerminationAdmission` after this await, and that helper checks Task cancellation, so the runtime needs no redundant guard or code change.

Signed fixed debug61082 passes the **same native fixture**. The cancelled call joins while ASR remains held; the next cleanup passes its native-owner check and is refused at the correct ASR-lane boundary. The observation records2.373ms for cancellation/test polling plus successor refusal, not physical dictation or inference latency. Both original and fixed retain256cached tokens of650; the successful successor decodes394 and equals its cleared-context control. The unchanged native prefix-cache suite also passes (646/666reused; observed prefill1.38s→0.18s). All private native owners and launchers join.

This confirms a repeated-request ownership defect and its repair. **It does not establish that scheduler parking caused the owner's11.447s cleanup**, nor that all native operations can cease immediately. An in-progress uncancellable decode still ends at its normal boundary.

Evidence: [actual original native failures](2026-10-07-evidence/checkpoint/native-original.log), [same fixed native flow](2026-10-07-evidence/checkpoint/native-fixed.log), [producer patch](2026-10-07-evidence/checkpoint/ComputeScheduler.producer-fix.patch), [maintained scheduler](2026-10-07-evidence/checkpoint/scheduler-fixed.log), [unchanged native cache](2026-10-07-evidence/checkpoint/prefix-fixed.log), [source/log manifest](2026-10-07-evidence/checkpoint/manifest.json).

## Producer repair: Unicode capitalization

The deterministic rules built `Character(character.uppercased())`. Uppercasing one character can yield several grapheme clusters (`ß`→`SS`, `ﬃ`→`FFI`). An optimized standalone original probe happens to return correct text, so no release crash is claimed. Its unoptimized counterpart traps. The signed debug60376 actual `CleanupRouter.format` path also exits133; the PID-bound crash stack identifies `capitalizeSentences` atTextFormatter.swift139, then `apply`/`format`, then the actual router. The original fixture uses the same three explicit final/partial cases.

The producer now appends the uppercase **string**. Fixed debug61082 passes those unchanged router and partial-rule assertions plus existing rules/structure/router cases. Parsing, punctuation, casing intent and rule order remain. This is a verified debug crash repair, not a measured latency improvement.

Evidence: [actual original router](2026-10-07-evidence/checkpoint/router-unicode-original.log), [PID-bound crash frames](2026-10-07-evidence/checkpoint/unicode-native-crash.json), [one-line producer patch](2026-10-07-evidence/checkpoint/TextFormatter.producer-fix.patch), [fixed router](2026-10-07-evidence/checkpoint/router-fixed.log).

## Related acceptance and limits

Fixed debug61082 passes scheduler, cleanup-router, cleanup-structure, dictation, hygiene, segments, commandkey, contention and duplex, plus the new actual native cancellation and unchanged native prefix-cache flags. Two inherited duplex reducer divergence warnings remain. The dictation injection fixture reports38,137/~40,000pre-roll frames and75.7mskey-down-to-capture with a1.5s injected start; it is not physical cold-start evidence. No broad model-quality gate or owner install is implied by these functional passes.

The host is verified Mac15,12 /Apple M3 /16GB /8physicalcores. ASR-plus-voice≥20tok/s is not proved. Native/signed tests are serialized without a competing compiler under the machine claim; the owner app stays active. The original debug window explicitly lowers the coarse gate's free-disk bound to7GB (observed7.588GBfree,7.342GBswap,load4.74). This is a disclosed resource override, not a pass of the normal10GBbound. Two own fixture compile errors (private duration helper, await insideBoolean autoclosure) are retained and repaired without changing assertions. Shared writers briefly mutated sources during an unsuccessful compile; that build produces no accepted native verdict. The coherent original and fixed bundles each verify1167unchanged Sources/Resources hashes before/after compilation. Meeting corrections are preserved.

Remaining work includes optimized short/121s replay, physical live UI/Enter/insertion, per-attempt native stall evidence and feature-preserving full-passage layout. A related per-hold pre-clean lane cancellation wait is identified only as a future reproduction; it is not described as a global delay or extra model pass. The scheduler's stale whole-hold comment is corrected: current Parakeet already reserves ASR per inference/cold-load, so no such scheduling rewrite is implemented.

## Integration, resource coordination and artifact lifecycle

Focused preview, checkpoint and Unicode producer/test changes are integrated in **86bf867** (81owned source/evidence paths) through a private index against HEAD. [Integration receipt](2026-10-07-evidence/checkpoint/integration-receipt.json). The newer native fixture and prior mixed pipeline prerequisites remain explicitly retained in the canonical working tree. The failed prototype is retained only as exact source/log evidence. Mixed files are not staged wholesale. The foreign seven-file staged binary diff remains SHA256 `a95a56feed170210aba2a320010f073d3e2cb35b3c379a2db889f3d07aba6e2d`. No worktree, PR, default promotion or owner installation is performed.

The meeting peer owns one coordinated optimized build from the frozen canonical Sources/Resources; no competing native inference or project compiler is launched. The owner app remains unchanged. Source freeze hashes and exact test logs are retained below. A diagnostic build failed once on a temporarily missing peer self-test type and once on this change's mutable formatter capture; both compile causes were repaired before the retained original/fixed runs. These build errors are not product latency verdicts.

After exact path/hash/process checks and preserving source/log verdicts, obsolete owned trial bundles51876/52522/53046 and superseded debug bundles47042/53810/54148 were removed. **1,400,635,392 allocated bytes (1.30GiB)** were reclaimed this continuation. Keep installed baseline30744, optimized45909, fixed debug61082, first shared optimized57481, reusable shared scratch and the upcoming shared release. Superseded debug54491 and original60376 were removed after preserving source/verdict/hash pins, exact process checks and integration receipt. This reclaims another467,820,544allocatedbytes; **1,868,455,936allocatedbytes (1.74GiB) of owned bundles are reclaimed in total this continuation**. Five completed standalone probes are also removed, excluded from that measured total; their exact source/build/output remains. The OS-sanitized original crash report is deliberately retained after the strict path cleanup guard refused removal. [Final bundle lifecycle](2026-10-07-evidence/checkpoint/final-artifact-lifecycle.json), [probe/crash retention](2026-10-07-evidence/checkpoint/pure-probe-lifecycle.json). User models, recordings, stores and peer artifacts remain.

Evidence: [source/log manifest](2026-10-07-evidence/layout-wire/manifest.json), [maintained original](2026-10-07-evidence/layout-wire/preview-maintained-original-router.log), [fixed router](2026-10-07-evidence/layout-wire/preview-fixed-router.log), [V1](2026-10-07-evidence/layout-wire/compact-native-debug.log), [V2](2026-10-07-evidence/layout-wire/compact-native-debug-v2.log), [V3](2026-10-07-evidence/layout-wire/compact-native-debug-v3.log), [source freeze](2026-10-07-evidence/layout-wire/source-freeze.sha256), [transport lifecycle](2026-10-07-evidence/layout-wire/transport-bundle-lifecycle.json), [preview lifecycle](2026-10-07-evidence/layout-wire/preview-bundle-lifecycle.json).

## Optimized complete-path replay — 8 October, 01:28–01:36 UTC

The exact signed second shared candidate62791 (`9b17a28e668cdbaac94fab2a85c2c31daa97c812172c577cc5dda8b1564154c7`) ran both real-time file-fed controller replays. Grammar and list formatting remain enabled; recognition, incremental cleanup, finishing router and layout are production implementations. Context, owner history and external insertion are isolated. All native/pure children joined before returning the machine claim. [Exact output and scope](2026-10-07-evidence/optimized-replay/manifest.json).

| Fixture / round | ASR final after release | Completed cleanup publication | Final result ready | Outcome |
|---|---:|---:|---:|---|
| 8-second short /1 |63ms |2222ms |2251ms |0/2 heads answered inside grace |
| 8-second short /2 |56ms |1852ms |1863ms |2/2 heads answered |
|121.19-second long /1 |47ms |423ms |6433ms |30/30 heads answered; layout6s timeout |
|121.18-second long /2 |36ms |424ms |6320ms |30/30 heads answered; layout6s timeout |

Already-visible raw text remains at release in all four rounds. First live text is520/492ms for the short fixture and881/490ms for the long fixture, measured **after** recognizer start returns. The fresh-process short ASR startup is22.732s; the second start is effectively0ms. Long-process startup is1.760s, then0ms. These clocks cannot establish fast physical cold key-down. Completed cleanup publication is an observable controller assignment, not a physical paint or external delivery receipt.

The independent long fixture has raw and final WER0.051 in both rounds; this establishes word preservation on that fixture, not list/paragraph semantic quality. Both long rounds still fail the two-second final target. Early cleanup is now actually published at423–424ms despite the six-second layout delay. No layout feature, budget or model default is cut to obtain those numbers.

The short run's `head`, `answeredHead` and real wait expose another diagnostic gap: accepted pre-cleaned heads have no model trace, so zero run-level `modelSeconds`/cached tokens does **not** mean that no model ran. Original owner8s native stall attribution is still open. A filtered system-log query returned no local phase entries, supplying no missing evidence. Per-attempt admission, prefill, checkpoint and generation evidence must be collected at the existing native producer/usage seam.

The run used an explicit7GB disk minimum: free7.399GB, swap7.643GB, load2.62. The ordinary10GB disk bound remains unmet. No competing development compiler/model ran during either native replay. The16GB M3 owner app remained active; ASR+voice decode-floor acceptance remains separate.

## Three further small producer optimizations

The agreed source-only window after native joins changes five paths, with exact [before/after hashes](2026-10-07-evidence/preclean-cancellation/source-mutation-receipt.json). Canonical Sources were frozen again before peer native work. Maintained app compilation and consumer checks are pending the final shared candidate.

- **Per-hold cancelled waiter:** actual `IncrementalCleanupSession.close -> PrecleanLane.run -> CleanupHead.cleaned/completed` reproduction holds the first semantic call using an uncancellable continuation, verifies the second registered waiter, then calls the real session cancellation. Original reports two failures at150ms: the second Task and completion are still pending. Candidate releases the second Task in2.062ms while the first owner remains held, returns the exact raw group and starts no second semantic call. Ordinary serial cleanup and20 cancellation/release orderings pass. Both original/fixed same owned tasks are released and joined. The maintained cases are wired into actual cleanup-router; its signed app check is pending. This lane belongs to one hold: no global next-hold blocking or native latency win is claimed. [Original/candidate evidence](2026-10-07-evidence/preclean-cancellation/manifest.json).
- **Frame energy reuse:** `DictationSegmenter` formerly calculated each320-sample frame's RMS once through `ChunkedTranscriber.frameIsSilent` and again for hard-cut energy. The same calculation now feeds a shared `frameIsSilent(rms:)` comparison, keeping the same private0.01 floor. A deterministic121s speech/silence/threshold-noise corpus yields byte-identical cuts, end-of-speech counts and last-speech offsets for whole/streamed scans.40 optimized scans measure2.027ms→0.940ms, saving1.087ms per full121s scan. This is CPU component evidence, not release latency. Existing signed segment checks are pending. [Comparison](2026-10-07-evidence/segmentation-energy/comparison.json).
- **Bounded visible suffix:** `LiveDictationText.tail` no longer counts every grapheme of the complete transcript before selecting its visible140-character suffix. It checks the bounded suffix's start index instead. All4000 original/candidate outputs match, including Unicode graphemes, whitespace and `Int.max` limits. A43,200-character fixture measures0.188ms→0.00257ms per call over1000 calls; this is string preparation, not SwiftUI paint. The real island/HUD consumers keep the same function and text. Signed island acceptance is pending. [Comparison](2026-10-07-evidence/live-text-suffix/comparison.json).

## File-reference matching allocation

`PhoneticKey.matches` allocated two temporary arrays for every phonetic comparison. The same four comparisons now use scalar optionals, preserving empty-primary refusal and all alternate pairings. Actual original/current dictionary, screen context and file-reference producers pass **4487 unchanged-output checks**, including 2304 arbitrary primary/alternate combinations, existing score vectors, all137 file cases at four loose-match budgets with both tag styles, and200-candidate context ordering.

Alternating measurements put context narrowing at38.80–40.49ms originally and22.19–22.955ms after the change. File tagging saves0.655ms at loose budget5 and5.438ms with an unlimited budget; strict-only tagging is effectively unchanged. These are component CPU measurements, not whole-dictation delivery. No filename, score, range, confidence, context ordering or rendered tag is changed. [Exact fixtures/results/source hashes](2026-10-07-evidence/phonetic-allocation/manifest.json). The existing dictionary package suites and final signed app checks remain pending.

The exact maintained pre-clean cancellation producer also compiles independently and reports `PRECLEAN_MAINTAINED_OK` (2.044ms observation while the first semantic owner remains held). This checks the maintained source and original flow, while the final signed cleanup-router hook remains pending. [Source and result](2026-10-07-evidence/preclean-cancellation/maintained-manifest.json).


## Third signed release consumer checks — 8 October

The coherent staged68784 binary is `cff85f47c0ab9ddbabe3b413e872d091a2191e79d7b26bda3842da938c97aa53`; its build preserves1168 Sources/Resources hashes. The actual maintained router passes cancelled pre-clean admission, with the queued task joining at1.834ms while the first semantic owner stays held. Actual segment control and island consumers also pass. These are model-free contract checks, not native recognition, physical capture/paint or latency acceptance. [Signed verdicts and scope](2026-10-07-evidence/third-release/acceptance.json).

Owned IncrementalCleanup committed-prefix completion/cancellation producer, its maintained fixture, the exact router fixture hook and shared RMS seam are integrated in604e80f. The mixed router/controller/ASR/live UI prerequisites remain retained; this is not a clean-HEAD complete-app build claim. The dictionary4487 component assertions still await the existing package suites. No source bytes changed during integration and the foreign seven-file staged SHA remains identical.

The broader read-only Oct7 history contains21 non-command dictations:14 exceed2s, median processing3.207s, maximum13.073s. For those slow rows the median recorded cleanup fraction is98.05%; semantic/layout timings overlap and must not be added. Six rows ask for layout, four time out. Two sub-six-second holds exceed10s despite resident cleanup weights. This small historical sample confirms the reported pattern, not a percentile, paired Wispr comparison, accuracy measurement or performance of the new staged build. No transcript, destination or participant information is exported. [Aggregate metadata](2026-10-07-evidence/third-release/owner-metadata-aggregate.json).

Two larger cache-only proposals are prepared but unverified: discard only successfully committed PCM through absolute offsets in the existing Parakeet array, and replace repeated committed-text array joins with its single accumulated string/count. Both require unchanged audio slices, original failed/held segment fallback, exact final/stream parity and native replay before adoption. The existing recognition replay trims both reference and test input using the production RMS floor, so it cannot prove retention of quiet final words. Full-audio quiet-speech recognition remains an explicit open contract.

The peer removed its own obsolete57481 bundle after preserving its evidence. Current shared68784 and original optimized62791 comparison remain retained; that peer cleanup is excluded from the1.74GiB of owned bundles reclaimed here. Installs remain held under AGENTS.md's native shutdown contract; the owner application is unchanged.


## Successful-segment PCM retention prototype

The cache-only actual Parakeet producer and absolute-offset segmenter compile and pass nine identical-input original/candidate cases, including short padding, quiet audio, pauses, a non-frame-aligned hard rewind,121s, first-pass failure, held segment/final-tail overlap and failed-segment fallback. Every supplied ASR slice hash, streamed chunk, committed prefix, key-up plan and final string matches. Peak retained samples for the normally drained121s case fall from1,936,000 to69,600 (7.744MB→0.2784MB of logical Float elements). Hard rewind remains within15s. Failed/backlogged audio is retained: this is not a universal whole-process/backlog memory ceiling.

The separate committed-string replacement also preserves all nine cases with scripted empty/whitespace, accented/decomposed Unicode, emoji and CJK model-boundary answers. It removes repeated joins of a frozen prefix without another store. The combined prototype remains uncompiled. Real AV buffers/control are exercised; native model, converter and scheduler boundaries are substituted. No native WER or latency benefit is proved and no canonical PCM/prefix source change has been made. Exact source and original/candidate results are retained in [the prototype manifest](2026-10-07-evidence/bounded-pcm/manifest.json). All compilers/probe children joined and the machine claim was released.


## Combined producer and unchanged dictionary suites

The combined PCM-offset/committed-string producer compiles and passes18 identical-input cases (nine ordinary hash answers, nine scripted empty/Unicode answers), preserving all audio slices, streamed/final text and key-up plans. The121s retention case remains green. Native boundaries remain substituted; native complete replay and quiet-speech acceptance are still required.

The actual dictionary target and unchanged repository SwiftTesting files/resources pass31 tests in2 suites, including137 crowded-screen file cases. This uses an isolated cache-only package manifest with the identical target settings; app/external dependencies are omitted, with no dictionary/test stubs or assertion changes. It is not a full root-package build. [Exact target pins and verdict](2026-10-07-evidence/dictionary-package/acceptance.json). The clean `SpokenForms.matches` optimization is integrated separately, preserving every foreign staged byte. PCM/prefix source adoption remains coordinated with the next coherent source gap/build.


The three-path PCM/prefix/full-audio diagnostic patch is now applied in the explicitly coordinated source gap486, with each original hash matching signed68784 and exact after hashes recorded. It remains pending signed fourth-build/native replay acceptance; source adoption is not a quality/speed verdict. Dictionary matching is integratedc5d295b. Completed exact PCM probe binaries and isolated dictionary build scratch are removed after source/output retention and process checks, reclaiming79,343,616allocatedbytes separately from the1.74GiB of owned bundles. All source, package/Make settings and unchanged test resources remain reproducible. [Artifact receipt](2026-10-07-evidence/third-release/component-artifact-lifecycle.json).
