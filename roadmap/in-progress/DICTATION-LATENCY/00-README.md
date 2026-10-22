# Dictation latency — why Wispr Flow beats us, and the plan (2026-10-04)

Goal: text in the field **within a few hundred ms of key-up, for any length**, with live text
while the key is held, and **no feature lost** (dictionary, spoken structure/lists, grammar and
tone cleanup, per-app formatting, file-name tagging, command mode).

## 2026-10-07 implementation and evidence

The [pipeline audit](../../../Tests/Reports/dictation-latency/2026-10-07-pipeline-analysis.md)
traces the current production path and distinguishes earlier uncommitted implementation
from the fixes verified in this investigation. It includes updated read-only timing samples,
accuracy limits, original failing regressions, and staged-build results.

Confirmed repairs: preserve accepted audio packets at Stop; emit committed text immediately;
request the first partial at 400 ms; process an unchanged committed prefix once; match
whitespace and word boundaries correctly; overlap head/tail cleanup and retain a head that
finishes during tail work; enforce Apple's existing caller deadline; capture file-tagging
context when cleanup is off; retain the release timestamp for delivery measurement; show
the full live transcript in Dictation with Enter stopping an active recording; release hidden
island mouse interception. Ordinary builds now default to optimized release configuration.
All existing semantic cleanup, spoken structure, dictionary, profile, file-tagging and
insertion features remain in the path.

**The latency targets below remain targets.** ASR replay is not a complete polished-delivery
benchmark; a recognizer's own whole-buffer answer is not ground-truth accuracy. Native UI
interaction and paired owner/Wispr accuracy remain unverified. Some standalone cleanup
quality assertions remain red. Installation stays held by the native-shutdown contract in
`AGENTS.md`; verification uses a separate signed staged bundle. No model/default or roadmap
phase is promoted by these bounded changes. The original option table is retained as the
plan; use the audit's status table for what is actually wired or still open.

## Follow-up after continued slow owner runs

The [follow-up investigation](../../../Tests/Reports/dictation-latency/2026-10-07-followup.md)
uses the newer owner timings and complete production finishing-path replay. It reproduces
premature punctuation closing an unfinished committed sentence, cancellation leaving entered
pre-clean work active, the native layout deadline joining an uncancellable response, and
unused/rejected heads continuing to compete with replacement cleanup. These producer repairs
retain final punctuation, model choices, all formatting and existing quality budgets.

A 60-second replay now reuses all 15 pre-cleaned groups, but complete text readiness still
reaches about five seconds because layout remains on the release path. Two smaller layout
response experiments failed latency/quality acceptance and were reverted. The existing
layout quality corpus remains red. Recognition-only figures do not establish polished
delivery; the universal two-second target and installation hold remain open.

The optimized full-path follow-up still misses the target: an eight-second first hold took
2.20 seconds after release, its second 1.12 seconds; warmed short/long runs under competing
meeting/native load were substantially slower. Cold recognizer startup is logged separately.
Head counts include rule fallbacks and do not establish completed semantic cleanup. A further
usable-head lifecycle defect was reproduced with three actual-router failures, then repaired.
A native dictation cancellation fixture also showed valid KV discarded (0/649tokens reused);
the repair preserves successful native tokens, with one successor token decoded and exact
cleared-context output equality. Another actual-router failure waited for layout after
post-cleanup rules already produced the authoritative list; its repair preserves that list
and cancels the unused plan. All three original/fixed checks pass in staged debug/native
fixtures. The current optimized validation and clean replay require an agreed agent-relay
test window around the owner's next Meet check. Ordinary-prose layout quality and complete
delivery targets remain open; see the follow-up for exact evidence and build scope.

## Continued optimization while native tests are coordinated

The [meantime CPU report](../../../Tests/Reports/dictation-latency/2026-10-07-meantime.md)
records integrated commit35559e4: faster spoken-name scoring, lazy file-tag preparation,
and compiled structure patterns, plus two actual-router result reuse expressions retained
in the canonical working tree. Original/current producer and actual narrowing consumer
comparisons pass2,183checks; existing structure corpus,32profile/toggle comparisons and
four concurrent suites pass. Optimized implementation fixtures cut200-candidate narrowing
from81–87ms to38–40ms and67-name loose tagging from25.93ms to13.04ms.

These fixtures preserve exact outputs and do not prove complete polished latency. The owner
completed a responsive40m05Zoom call. One coordinated optimized build now includes both
investigations, followed by actual consumer checks and sequential native replay. No dictation
model/compiler competes with that shared build. Full-path quality and delivery targets stay
open. The historical options and memory estimates below are superseded where they disagree
with PERFORMANCE-STANDARDS.md: Apple model memory is not zero system cost, mapped weights
are not free RAM, the actual ASR lane is per inference pass, and models/defaults need measured
quality/throughput acceptance before promotion.

## 1. Historical baseline — 4 October, owner's M3 Air 16 GB

| | Wispr Flow (`flow.sqlite`, 40 holds) | Next Notes (`usage.jsonl`/`runs.jsonl`, 27 holds) |
|---|---|---|
| 2 s clip, key-up → text | 0.19–0.30 s | 15.8 s (MiniCPM cold timeout + cold Apple fallback) |
| 10–30 s | 0.39–1.03 s | p50 4.6 s overall |
| 60 s | 0.75–1.13 s | up to 16–17 s |
| 254 s (817 words) | 1.32 s | — |
| p90 | ~1.3 s | 16 s, worst 21–25 s |

The `opusChunks` column supports audio streaming during the hold. The exact cloud
formatting architecture is not established by that metadata; its measured delivery is
the comparison above.

Our split (key-up → text):

| Stage | Cost | Notes |
|---|---|---|
| Parakeet final (warm) | 0.1–0.7 s | Not the bottleneck today. |
| **Cleanup** | **2–17 s** | The bottleneck. |
| Injection | 0.07–0.39 s | AX, else pasteboard with 40 + 80 ms sleeps. |
| Cold start (first hold after launch / pressure) | up to 21 s | Key-up landed while `engine.start()` was still loading Parakeet behind a 35.7 s LLM load. |

## 2. Historical diagnosis — superseded by current producer evidence

1. **MiniCPM cleanup is usually not resident.** Pressure eviction with no reload; cold load
   14–49 s; the 8 s timeout races the load; 6 of 9 MiniCPM runs timed out (13.8–17.6 s).
2. **The fallback is cold and sequential.** Apple is staged at key-down only when Apple is the
   chosen engine, so after the 8 s timeout Apple starts from nothing (6–9 s).
3. **Cleanup runs on the background lane** with notes, memory review and `agent.worker`
   (10–29 s jobs, 7–12.7 s queue waits), and the timeout clock includes that wait.
4. **Pre-cleaning while the key is held never runs.** Parakeet holds the single `.realtimeASR`
   lane for the whole hold, so the pre-clean jobs are parked until after release; the parked
   job is then counted as "pressure" and the router defers to rules. Only 3 of 78 cleanups ever
   used a pre-cleaned head.
5. **Partials re-transcribe the whole buffer every second (O(n²)).** 60 s hold = 26 s of ANE
   busy (44%), 120 s = 82 s (69%). Earlier sentences get re-worded, which is why pre-cleaned
   heads are rejected. Under contention, key-up → ASR final reaches 2.5–12 s.
6. **The live text is invisible.** Partials arrive, but with `hudPlacement = notch` the
   dictating island card is collapsed and shows text only on hover; after key-up it says
   "Finishing…" although the raw text is ready seconds earlier.
7. **Fixed floors.** Every Parakeet call pads to one 15 s encoder pass (85 ms release / 137 ms
   debug); the installed app is a **debug** build (+50 ms per pass, +45% on long audio).
8. Rules route awaits the layout plan unbounded (3.5–9.2 s measured).

## 3. Original options and hypotheses — current status is recorded above

| # | Option | Wins | Risk / cost | Status |
|---|---|---|---|---|
| 1 | Never wait on a cold MiniCPM: go to a **staged** Apple pass, load in background | p90 16 s → ~3 s | none | in progress |
| 2 | Stage Apple at key-down whenever it is the fallback | 6–9 s → 2–4 s on fallback | none | in progress |
| 3 | Cleanup at interactive priority; timeout starts after lane | 1–13 s queueing | lane ordering | in progress |
| 4 | Bound the layout wait (`layoutGrace`) | up to 9 s | none | in progress |
| 5 | Keep MiniCPM resident; reload after pressure; preload warms the real cleanup prefix | prefill 3–5 s → ~0.05 s | memory on 16 GB | in progress |
| 6 | **Pause-committed ASR segments**: freeze text at pauses, partials and final re-run only the open tail | key-up ASR < 150 ms for any length; O(n) | WER 1.2% → ~1.8% on test script | in progress |
| 7 | Per-pass ASR lane so pre-cleaning runs during the hold | unblocks #8 | none | in progress |
| 8 | **Pre-clean committed segments while speaking**; at release clean only the last sentence | cleanup at release ≈ 0.3–0.5 s for any length | head-prefix check already exists | in progress |
| 9 | Live text visible in the notch / HUD; raw text shown while tidying | perceived latency | none | in progress |
| 10 | Release build of the app (or at least FluidAudio) | −50 ms/pass, −45% long passes | build time; owner choice | proposed |
| 11 | Prompt-lookup speculative decoding for cleanup (draft copied from input) | 2–3× decode | llama.cpp work | proposed |
| 12 | Edit-list output (GBNF) instead of full rewrite | −80–90% output tokens | quality; needs `--selftest-cleanup` | proposed |
| 13 | Rules-only route for short, clean utterances | 2–4 s on short clips | quality policy — owner decision | proposed |
| 14 | Parakeet Unified / Nemotron streaming model (cache-aware, one-chunk finish) | ~30 ms finish | download, English-only | proposed, opt-in trial |
| 15 | Batch long-dictation chunks into one decode (multi-sequence) | ~2× long tails | needs P3-07 capacity evidence | proposed |
| 16 | Move `RunLog.append` off the main actor; trim injection settle sleeps | tens of ms | none | proposed |
| 17 | Cloud cleanup (Wispr's approach) | ~300 ms formatting | privacy; must be opt-in | not proposed as default |

Rejected for the final text: FluidAudio `SlidingWindowAsrManager` (WER 3.6%, updates every 11 s)
and EOU-120M (WER 10%, no punctuation) — EOU stays useful for live display / end-of-speech.

## 4. Acceptance target — not achieved

The original0.5–0.8s estimate for every length was an unverified hypothesis. The latest
optimized121s replay has ASR final36–47ms and completed cleanup publication423–424ms,
but final layout/result still takes6.320–6.433s. Short replay finishes in1.863–2.251s.
Physical microphone, paint and external insertion are separate open checks. Keep live
text visible and preserve all features; the universal two-second polished target remains
open. See the current report linked above for exact scope and quality verdicts.

## 5. The 2 GB challenge (owner, 2026-10-04)

**Historical design hypotheses below, not current performance contracts or model choices.** The 7 October [performance standard](../../../PERFORMANCE-STANDARDS.md) supersedes these resource assumptions. Apple-hosted inference still consumes machine memory/compute; mapped weights can incur paging; modes must preserve simultaneous ASR, voice and background work. Exact role files follow saved choices and observed usage. No default/model/TTS/ASR feature removal is authorized by this proposed budget. The file/role figures below are an Oct4 snapshot, not a current inventory.

A design target, not a hard cap: fit the whole app in ~2 GB without dropping a feature, to force
the architecture to be lean. If benchmarks show a bigger model (e.g. Gemma 4 E4B) is clearly
better for a role, we switch the one shared brain to it and raise the target (e.g. ~5 GB).


What we keep on disk today (measured): Gemma 4 E4B 4.98 GB, Qwen3.5-4B 2.74 GB, Qwen3-4B
2.50 GB, MiniCPM5-2B 1.56 GB, S1-mini 0.48 GB, embeddinggemma 0.28 GB, potion 0.13 GB;
Parakeet TDT v3 0.46 GB, TDT v2 0.44 GB, EOU streaming 0.43 GB, CTC-110M 0.10 GB, Silero VAD 1 MB;
Pocket TTS 0.43 GB, Kokoro 0.08 GB. Roles on this Mac: cleanup = MiniCPM, meeting notes =
**Gemma 4 E4B (5 GB)**, agent = cloud. Cleanup and notes share one runtime, so every notes pass
evicts MiniCPM ("switched") and every dictation after it pays a reload.

Rules that make 2 GB possible without slowness:

1. **One resident brain, ≤ ~1 GB.** One weights file serves cleanup, notes, meeting agent and local
   agent as separate sequences/contexts. A 5 GB notes model can never fit; it becomes an opt-in
   "deep pass" run only when the Mac is idle and plugged in — never resident.
2. **Measure Apple-hosted inference too.** Foundation Models uses a system process, so the app’s own footprint omits part of its cost. Include its machine memory, compute and contention when evaluating fallback. The separate process does not make inference free.
3. **Measure mapped-weight readiness.** File-backed weights still occupy memory and incur paging and native-context costs. A fast theoretical SSD read does not establish cold inference latency. Key-down prefetch remains an unverified option and must not compete with capture/ASR; no extra cold load is launched there.
4. **Time-multiplex by mode; predict the switch.** A person dictates, or is in a meeting, or talks
   to the agent — rarely two at once. Each mode has a small working set, and every switch has an
   early signal (key-down, calendar 5 min before a meeting, wake word) to page it in.
5. **Right-size each job.** Most cleanup is deterministic (fillers, stutters, dictionary,
   spoken structure); a model only touches the sentences that need it, sentence by sentence
   while speaking.
6. **One of each kind.** One ASR model (TDT v3; drop v2/EOU/CTC residency — Silero VAD 1 MB covers
   end-of-speech), one TTS (Kokoro 80 MB over Pocket 430 MB), one embedder (potion, static,
   130 MB, only while indexing).
7. **Small KV.** Cleanup needs ~2k tokens of context; q8_0 KV; contexts freed between modes,
   weights kept mapped.

Target budget (in-process, steady state):

| Item | MB |
|---|---|
| Parakeet TDT v3 int8 (ANE) | ~460 |
| Silero VAD + wake word | ~10 |
| One LLM brain (≈1.5B–2B at ~3.5 bits, or MiniCPM5-2B Q4 if measured to fit) | ~1,000 |
| KV + compute buffers (2k ctx, q8_0) | ~150 |
| Kokoro TTS (only while speaking) | ~80 |
| App, UI, Swift runtime | ~200 |
| **Total** | **~1,900** |
| Apple Foundation Models (separate system process) | Not included above; measure machine cost |

Open measurements before choosing the brain: notes quality of the shared brain vs Gemma
(`--selftest-meeting-quality`, owner meetings), cleanup quality at ~3.5 bits
(`--selftest-cleanup`), and the true page-in cost of a mapped model on this Mac.

## 6. Evidence

Benchmark harness and logs: session scratchpad (FluidAudio direct, release vs debug, real-time
replay at 10/30/60/120 s). Owner data read only as numbers and enums, never dictated text.


## Latest shared optimized verdict

[Shared native verification](../../../Tests/Reports/dictation-latency/2026-10-07-shared-release.md) measures installed-equivalent30744. Warm8s text readiness128/116ms;121s readiness6.20/6.32s due to6s rejected layout wait, despite22/46ms recognition and365/370ms tail cleanup. All six replay rounds retain live text. Cold startup21.5s, universal2s, native layout quality and external delivery remain open. Current actual router/structure plus dictation/hygiene/capture flags pass. Every formatting feature/schema/validator/budget remains.


## Continued producer repairs and rejected layout experiments

[Continued evidence](../../../Tests/Reports/dictation-latency/2026-10-07-layout-preparation.md) records removal of the full-input preparation experiment after121s replays still wait6.10/6.25s. Retained work fixes router layout cancellation, local caller deadline overruns, quote-based word loss and repeated CPU work. Correct native French plans now preserve content through the renderer/router; mixed local layout remains3 failures and both tested native Apple schemas remain14 failures. All features, model choices, token/deadline bounds and quality checks remain; the eight-word quote bound now uses the same spoken-word unit as stripping. Universal2s, physical live capture/display/insertion and paired accuracy acceptance remain open.

### 7 October continuation: finishing preview and layout transport

Actual owner rows still miss the target (5words: ~72msASR,11.447scleanup; long hold3.612sprocessing). Router/controller finishing progress now passes its maintained original-fail/fixed-pass test; physical paint and optimized replay remain unverified. Three native compact layout transports fail5/10/6existing quality assertions despite faster isolated warm cases. None is promoted. Source is frozen for the coordinated meeting/dictation optimized build. Parked-checkpoint cancellation is the next reproduction, not a confirmed owner-stall cause. See [the continuation report](../../../Tests/Reports/dictation-latency/2026-10-07-live-preview-and-layout-wire.md).

7October final focused proof: native original60376 reproduces3parked cleanup ownership failures; fixed61082 wakes cancellation while ASR held and preserves256/650nativeprefix plus cleared-control output. Maintained scheduler12negatives/20races, native cache and9related flags pass (inherited2duplex warnings retained). Actual debug router Unicode trap reproduced/fixed by appending uppercase String. Optimized short/121s/physical paint/owner-stall attribution remain open. No deadline/features/model choices changed.


### Continued complete-path proof — 2026-10-08 01:36 UTC

Signed62791 full real-time121s runs: ASR47/36ms, completed cleanup publication423/424ms, final6433/6320ms,30/30 heads each, independent raw/final WER5.1%. Layout still times out at6s;2s polished target remains open. Short final2251/1863ms; cold fresh-process ASR startup22.732s is separately reported. Raw stays visible throughout. Publication is not physical paint/insertion. Source-only follow-up adds exact cancelled waiter release, one shared frame RMS calculation and bounded visible suffix; maintained signed app checks remain pending. Pre-clean native phase/engine trace omission is confirmed; owner8s stall cause stays open. See the continuation report and exact evidence. No budget/default/feature cut or owner install.


### Continued producer implementation — 2026-10-08

Signed68784 passes actual router cancellation, segment control and island consumers. Pre-clean queued cancellation joins in1.834ms with the first semantic call still held. Integrated604e80f includes the responsible cancellation/completion seam and shared frame energy comparison; c5d295b integrates scalar phonetic comparisons.4487 unchanged-output component assertions plus31 unchanged dictionary tests/2suites/137filecases pass; the package proof isolates the exact dictionary target and is not a full root-package build. Foreign staged bytes are preserved.

Next larger chunk: the actual Parakeet PCM-offset/committed-string composite passes18 original/current identical-input cases through real AV buffers (model/scheduler/converter boundaries substituted). Normally drained121s retained PCM drops1,936,000→69,600samples. Failed/backlogged segments and independent retry audio remain retained; no whole-process memory ceiling is proved. Exact3path source proposal also adds an explicit untrimmed audio replay so the production RMS gate cannot hide quiet final speech. The exact3path proposal is now applied in the coordinated source gap and included in the fourth coherent signed build; real original/fixed ASR replay remains pending the native window. Source/output evidence and native acceptance limits remain in [the continuation report](../../../Tests/Reports/dictation-latency/2026-10-07-live-preview-and-layout-wire.md).

The Oct7 installed log sample contains21 non-command dictations;14 exceed2s, median3.207s, max13.073s. Slow-row median cleanup share98.05%; six layout attempts include four timeouts. These historical metadata support the complaint, not performance of the staged build or independent accuracy. Native failed-cleanup phase attribution, full-passage layout quality/speed, physical live paint/Enter/insertion, ASR+voice decode floor and universal2s polished acceptance remain open. No feature/deadline/model choice is removed, and the owner app has not been replaced.


### 8 October fifth source snapshot: quiet tail and phase baseline

Native fourth whole quiet input fails accuracy: reference WER4.4% vsstream9.6% twice, key-up `committed-only`. Original full controller also loses “I will send the summary tonight.” in both rounds; layout4.8s timeout keeps final at4875/4926ms despite337/406ms cleanup publication. Universal2s and quiet accuracy remain unmet. Fifth source requires captured-PCM coverage for final reuse and enables explicit replay raw/reference output. Actual-engine substituted-boundary originalRED2/candidatePASS4 is not native word proof. Fifth signed/native acceptance, silence/noise/normal short-long latency, quiet live scheduling and pause-cut accuracy remain open. Runtime/Scheduler telemetry proposal stays unapplied until real missing-phase baseline. Native shutdown install hold is unchanged.


### 8 October: fifth native quiet acceptance still fails

Signed fifth direct Parakeet recovers all seven independently aligned public quiet words; actual streamed endings return one/two words (85.7% WER), first partial about 3.08 seconds. Captured-sample final coverage alone is insufficient: the RMS pause producer cuts the entirely quiet spoken clause at 1.5 seconds. Cache-only guard passes original RED2 with ordinary pause/cap controls unchanged; accepted-PCM cadence remains experimental pending native noise/word/workload evidence. Native cleanup phase original fails four missing-span assertions; existing cancellation/prefix controls stay green. Cache-only empty-name context shortcut preserves 582 exact-field cases and saves roughly 1.9 ms of component CPU on long public text. No owner install/default change or universal latency/accuracy acceptance. See the latest [analysis](../../../Tests/Reports/dictation-latency/2026-10-07-pipeline-analysis.md).


8 October sixth compiled source update: reviewed quiet/quality four-path changes were applied before the shared freeze. Signed uninstalled candidate8d079a72 compiles in810.30s (819.16s with bundle), strict signature/pins1,173 pass. Native phase originalRED4, exact quiet7words, no-speech live/final negatives and full8/60/121s finishing remain unrun on the sixth candidate. Short native cleanup explicitly allows8s after admission, then sequential Apple fallback; this explains an available slow path but does not yet attribute owner11.447s. Global layout still launches at key-up after live semantic heads;121s measured6.3s remains open. Ready-result deadline bypass and same-model copied-token verification are cache-only experiments, not promoted fixes. A public same7word loud-opening/quiet-continuation control is prepared with no clipping to test the remaining RMS pause risk. [Current analysis](../../../Tests/Reports/dictation-latency/2026-10-07-pipeline-analysis.md).

### 8 October acceptance follow-up: producer silence and native resource boundaries

Sixth native phase regression now passes the original four missing-span assertions; parked cancellation joins in2.34ms with reservation held (private CPU fixture, not owner stall attribution). Both exact quiet native attempts stop during model load on disk guards and supply no word result. ANE encoder compilation14.385/15.379s is observed; temporary disk writer remains unobserved. Actual copied Engine with the exact public seven-word recording plus16s leading/trailing digital zero reproduces one/five wholly silent inference calls; the cache-only three-line per-pass guard removes those calls in4cases under ordinary resource admission. Model boundaries are substituted: native words, noise, full finishing and physical delivery remain open. A completed-head shortcut passes742 component cases and saves~0.172ms for30groups; native prompt-copy lookup passes19,138pure cases but its decoding algorithm is uncompiled/unrun. Source7 changes await the coordinated gap; current signed candidate remains uninstalled. See [current analysis](../../../Tests/Reports/dictation-latency/2026-10-07-pipeline-analysis.md).


8 October Source7 follow-up: the exact per-inference digital-zero guard and completed-head shortcut are applied in the coordinated source gap, with all existing Git index entries unchanged. Component original RED2/fixed four cases and ready-head 742 cases pass; seventh coherent compilation/native word/full-finishing/physical acceptance remain pending. Actual linked native defaults now confirm physical batch512, while Runtime submits at most128 tokens per prefill. A cache-only128/128 capacity candidate and allocation diagnostic remain unapplied/uncompiled/unrun; no memory/speed/quality/default claim. [Latest analysis](../../../Tests/Reports/dictation-latency/2026-10-07-pipeline-analysis.md).

## 7. Status 2026-10-09 (Claude lead + subagents)

Installed `/Applications/Next Notes.app` executable sha256 `503e0e40…` at 02:45 UTC (release, signed).
Changes, all verified on the staged bundle (one flag per process; logs in
`~/Library/Caches/NextNotesBuild/claude-worktrees/checks3/`): MiniCPM "resident" now means its
weight pages are actually in memory (mincore sample) — if not, the staged Apple session answers at
once and the weights are read back; the read also starts at key-down; the cleanup prompt prefix is
re-prefilled in the background after another role used the shared KV; per-phase timing lands in
`runs.jsonl` and the `dictation.cleanup` usage row; llama backend init runs once at launch after
Parakeet; `make bench-models` + `shared/model-guardrails.json`. Parked: Parakeet CPU fast-start
(10.5 s, missed its target, double memory), precompiled Metal library (needs own llama.cpp build +
Metal Toolchain), 2–4 s encoder re-export (~50 ms, 2.5 GB download). Root cause for most slow holds:
memory pressure evicting the mmapped weights and cross-role KV overwrite. Next: read owner holds
after 02:45 UTC with `python3 Scripts/dictation-stats.py --since 2026-10-09T02:45`.
