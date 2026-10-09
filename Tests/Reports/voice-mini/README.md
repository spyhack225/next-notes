# Resident Mini voice experiment — final evidence

Recommendation: **park Mini as a live answerer**. The decisive number is **0/5 qualified Mini turns in the explicit-census repeat**, versus 1/5 Apple. The first batch was Mini1/5, Apple2/5, cold-Mini fallback5/5. Four available Mini L2 values have a lower median than Apple, but one actual turn never reaches an answer token. This is not a qualified five-turn latency win. First-batch Mini L3 is worse; the repeat has lower raw Mini L2/L3, but no qualified Mini turn. Both endpoint-to-first-answer and endpoint-to-first-audio 200ms gates fail. No role/default, stored choice, prompt, sampler, response deadline or production audio fallback was changed.

## Confirmed producer repair and original/fixed evidence

Listen2 made partial native preparation resident-only, but committed `streamInteractiveConversation` still invoked `loadIfNeeded`. Committed admission now checks weights, vocabulary and existing context before the existing reservation and again after its existing lane wait, and refuses insufficient existing context. It starts no cold load/context growth. Valid resident requests retain the same template, context, sampler and prefix path. Overflow-safe budget validation corrects the streaming budget crash found by the original fixture.

The frontend preserves the complete canonical Apple split route, then attempts resident Mini. Only `notLoaded` before any native answer text selects a fresh independent Apple Foundation Models answer session. Decode/protocol/cancellation errors and failures after text do not retry through Apple. The synchronous actual-provider observation reaches the real coordinator tracker through its existing MainActor route-resolution hop. No new turn await/store/queue/timer is introduced.

* Initial actual cold RED: debug build347.16s; PID16288 SIGTRAP/exit-5 (shell251), no final marker. Missing-model entry tried loading; a subsequent call loaded the fallback built-in model in23.492s, then `Int.max` overflowed streaming budget addition. This is not a passing RED marker or a complete scripted result. Own crash metadata and relevant stack frames: [red-crash-metadata.json](red-crash-metadata.json). The deliberately absent custom spec reset to the built-in isolated self-test model after failure; owner choices were never used.
* Subsequent scripted-only RED, same nine cases: debug build364.36s, exit1 `VOICE_RESIDENT_ANSWER_FAILED`, **18 targeted failures**. Native selection/identity missing, fault/cancel/late-notLoaded cases answered through Apple, unavailable/failed Pocket fallback spies1/1. Control/invalid refusals and revised-route discard exercised. The two real cold calls were explicitly UNRUN to isolate the earlier arithmetic crash.
* The scripted RED is missing-feature proof: before implementation, the generic external generator supplies the Apple fake even for the pinned provider, because the new native fixture hook is not consumed. It does **not** establish that the old real native SDK retried decode/cancellation failures through Apple. Those negative cases verify the new fallback catch policy through the real frontend/coordinator consumers; native hardware fault/cancellation phases are not independently reproduced by them. The actual original cold stream and actual fixed cold file-fed arm supply the production entrance/consumer evidence.
* GREEN: debug build121.04s, exit0 `VOICE_RESIDENT_ANSWER_OK`. Full original caps8/Int.max both refuse before load; no model.load, no loaded weights. Cold/evicted calls native1/Apple1; resident/revised1/0; control/invalid0/0; fault/cancel/late-notLoaded1/0. Precommit silence and actual committed reply/speech retained. The resident fixture file hash is byte-identical RED/GREEN `e876332245c418aedd03a878baeb1469af9338545ee8b12af459c58fb8384151`. Speech contract body is also unchanged: [fixture-invariance.json](fixture-invariance.json).
* Actual five-turn cold consumer: `VOICE_LATENCY_OK`, 5/5 qualified; all five have one completed positive-count Apple answer and actual Apple summary, retained native refusal rows, no model.load, runtime loaded=false after all turns. This verifies producer and real file-fed consumer. It does not prove cancellation, microphone/ears, release or normal-use residency.

## Why routing is slow

Routing uses Apple Foundation Models typed `LocalVoiceRoute.collect()`, not Mini. The canonical validator is synchronous; successful route validation completes before native answer entry. Split routing takes no llama compute ticket. Native preparation/sampling use the existing context reservation/realtime lane.

Retained listen2 exact per-turn endpoint→routeDone medians: Apple route-only1.125s, Mini without prefill4.175s, final Mini4.343s (not the approximate difference of headline medians). The first final slow route occurred with Mini absent and partial prefill skipped. Concurrent Mini prefill therefore cannot be the sole explanation.

This batch's Apple arm, with no Mini pin, takes4–5s in typed collection itself. Validation is0–2ms. Thus the historical routing gap is not reproduced as a unique Mini-only delay. High shared-machine swap is recorded, but CPU/GPU/ANE, service/cache and pressure attribution remain **unproven**. The original batch uses one v2 heavy-wrapper slot and Apple then Mini back-to-back; it retained load/swap/thermal/power but not an explicit foreign-process count. Do not call the old listen2 run and today's run a controlled comparison. The explicit-census repeat below is complete.

A separate actual Mini failure is confirmed: run2, gen16 prefill admitted at0.002s, canceled at0.256s; Apple route native task ended at0.257s, but the structured prefill child did not settle until9.498s (**9.242s cancellation latency**). The next exact committed gen27 fails its existing2s speculation barrier after2.008s, before typed collection or an answer. This is the **one missing L2/final-answer-count turn**, not a cold-load timeout. `speculate`, `cancelSpeculation`, `serialBarrier`, and the2s wait body are byte-identical to listen2: [prefill-barrier-invariance.json](prefill-barrier-invariance.json).

The current producer already bounds its route-predecessor wait at2s but includes the native child in its structured lifetime/drain chain. Adding another bounded join, extending that deadline or waiting longer would not fix the delayed child and would slow a live turn. The native prefill producer checks cancellation between128-token decodes; this trace does not separate synchronous native/KV preparation, decode, scheduler wait and actor scheduling inside the9.242s interval. A verified prompt/lease-safe cancellation or independent route-publication repair remains open; this experiment does not claim it fixed or detach a native context without ownership proof.

## Residency and cheap routing

Permitted retained diagnostic counted rows: Mini-before warm5/cold0; final listen2 warm4/cold1 (one unavailable final count). These two n5 sequences are not normal-use residency probabilities. No retained unload rows in the old stdout means missing coverage, not zero owner evictions. Owner stores were excluded.

This batch preloads resident Mini15.303s **before all spoken turns** (12.356s weights). Four completed counted Mini answers are warm with native final counts; the fifth has no answer admission due the barrier above. Runtime remains loaded after all turns. The explicit cold arm remains unloaded through all turns. Own isolated metadata has one `model.unload` note `model=Gemma 4 E4B reason=switched resident` in each pinned arm; this is a selector/reset fact, not a measured Mini pressure eviction. No normal-use pressure-eviction frequency is established.

The rejected single-decision report was read: native single12/15 versus split13/15 and failed history replay despite its schema repair. No repeats or rule bypass were introduced. A rule gate/Mini router needs semantic/history acceptance, not only canonical shape validation. Retain the full validated Apple split and existing exact partial reuse; no new model pass or weakened route is justified here.

## Matched first batch

Same authored haiku16k fixture, SHA256 `ec9f48e5b38281e2ef3022904db9eb2e3eb5b69bdcbaab94faf000a9c91fbeab`; MiniCPM5-2B-Q4_K_M artifact SHA256 `ec2d5801640099e97d8d7e8003ad4d81f336e757811f03a26173dddf386602fd`. Thinking off/current sampler; n0 warmup excluded. All measured rows below retain failed turns. p95 is nearest-rank (for n5/n4, the maximum); **Mini L2 n4 excludes its missing value explicitly**. L1 is onset→first partial preparation; L2 endpoint→first answer token; L3 endpoint→first playback. Qualification requires final joined positive answer counts/actual model, localEOU, all required stages, one committed turn/audio acknowledgement, existing acceptance and <=100ms main stall.

| Arm | Stage | n | Median s | p95 s | Min s | Max s |
|---|---|---:|---:|---:|---:|---:|
| Apple | L1 | 5 | 0.701 | 0.774 | 0.690 | 0.774 |
| Apple | L2 | 5 | 5.956 | 6.964 | 5.583 | 6.964 |
| Apple | L3 | 5 | 6.249 | 7.279 | 5.944 | 7.279 |
| Resident Mini | L1 | 5 | 0.685 | 1.084 | 0.680 | 1.084 |
| Resident Mini | L2 | 4 | 5.021 | 9.684 | 3.356 | 9.684 |
| Resident Mini | L3 | 5 | 8.329 | 10.656 | 4.285 | 10.656 |
| Cold Mini → Apple | L1 | 5 | 0.678 | 0.679 | 0.670 | 0.679 |
| Cold Mini → Apple | L2 | 5 | 4.783 | 5.230 | 4.153 | 5.230 |
| Cold Mini → Apple | L3 | 5 | 5.000 | 5.473 | 4.328 | 5.473 |

Qualified: Apple2/5 (runs3,4); Mini1/5 (run4); cold fallback5/5. Apple runs1/2 VAD and >100ms stall; run5 >100ms stall. Mini runs1/3/5 VAD; runs1/2/3/5 >100ms stall; run2 barrier failure/no answer. Qualified-only n2 Apple / n1 Mini statistics are retained in [native-analysis.json](native-analysis.json), not treated as a five-turn matched pair. Mini's available L2 median is0.935s lower, but p95 is9.684s versus6.964 and incomplete; no qualified L2 win is demonstrated. Both200ms gates fail.

Cold admission entry→fallback takes0.263–0.987ms in the five counted turns, preserving the same already-validated route; it adds no second route collection. Native entry→admitted is4.689–8.261ms in three adopted answer generations. These measure the complete actor/reservation/scheduler/tokenizer entrance, not pure scheduler wait. Exact raw-uptime event records and unavailable first-batch census values are in [stage-analysis.json](stage-analysis.json).

Qualified-only observations follow. **n2 versus n1 is insufficient for the required n5 comparison**; the reliability count, not an unqualified lower median, supports park.

| Qualified arm | Stage | n | Median s | p95 s | Min s | Max s |
|---|---|---:|---:|---:|---:|---:|
| Apple | L1 | 2 | 0.700 | 0.701 | 0.698 | 0.701 |
| Apple | L2 | 2 | 6.460 | 6.964 | 5.956 | 6.964 |
| Apple | L3 | 2 | 6.756 | 7.264 | 6.249 | 7.264 |
| Resident Mini | L1 | 1 | 0.680 | 0.680 | 0.680 | 0.680 |
| Resident Mini | L2 | 1 | 4.535 | 4.535 | 4.535 | 4.535 |
| Resident Mini | L3 | 1 | 8.450 | 8.450 | 8.450 | 8.450 |
| Cold Mini → Apple | L1 | 5 | 0.678 | 0.679 | 0.670 | 0.679 |
| Cold Mini → Apple | L2 | 5 | 4.783 | 5.230 | 4.153 | 5.230 |
| Cold Mini → Apple | L3 | 5 | 5.000 | 5.473 | 4.328 | 5.473 |

## Exact flag verdicts

| Run | Exit | Actual final marker |
|---|---:|---|
| Full cold original RED | -5 | none; SIGTRAP |
| Scripted RED | 1 | VOICE_RESIDENT_ANSWER_FAILED |
| Full cold+scripted GREEN | 0 | VOICE_RESIDENT_ANSWER_OK |
| partial/preparation/prefill | 0 | VOICE_PREPARATION_OK |
| matched Apple | 1 | VOICE_LATENCY_FAILED |
| matched resident Mini | 1 | VOICE_LATENCY_FAILED |
| cold Mini→Apple | 0 | VOICE_LATENCY_OK |
| voice pipeline | 0 | VOICE_PIPELINE_OK |
| voice turn routing | 0 | VOICE_TURN_ROUTING_OK |
| concurrent voice | 0 | CONCURRENT_VOICE_OK |
| voice conversation | 0 | VOICE_CONVERSATION_OK |
| duplex | 0 | DUPLEX_OK |
| prefix cache | 0 | LLM_PREFIX_CACHE_OK: reused 646/666 tokens, prefill 1.74s → 0.20s; stable prompt front 90% (was 73% before P1-28) |
| store isolation | 0 | STORE_ISOLATION_OK: 21 files and 0 defaults unchanged; later nested TOOLLOOP_PRODUCTION_FAILED |

The nested store-isolation A02 fixture retains18 `TOOLLOOP_PRODUCTION_WRONG` admission failures from the unchanged requested-flag mismatch. Exit0 is only the narrow owner-store isolation verdict, not a green tool loop. Exact verbatim marker order (including the last nested printed failure) is in [verdicts.json](verdicts.json). See [status.txt](status.txt) and each label.stdout.log / label-pins.json. First combined wrapper exits1 because Apple/Mini latency fail.

## Pocket-only proof, coordination and scope

Pocket is prepared before measured turns; the SelfTest harness installs real Pocket on the existing synth and a silent failure backing. Unready/failed speech stays silent and fails evidence. Actual AVSpeech speak-entry counter is0 in all3 latency arms and pipeline; routing corpus counter0. PCM scheduling through an existing player is not Apple synthesis. Pipeline/routing harness scope exception: positioning relay `40d1dd82-c3a7-461e-8fc7-c62cf13c5fdc`. Exact additive3line counter prerequisite SHA256 `bf8d8984dbdec07f3b1e89035a95af793dfd5f4fb6b01d2650a0899de4972b9d`, shared with voice-ack `3d1a5070`; skip duplicate integration hunks. The future no-Apple producer retains the helper signature but ignores its fallback argument; our fallback-specific dropped-clause observation does not automatically transfer to that policy. Its delivery/cancellation acceptance and removal of the synthesis sink require separate integration proof. Voice-ack also adopted the same helper. This changes no production voice fallback outside our scope.

Own worktree only; no install/push/merge/GUI/owner-store reads. Read-only canonical conflict snapshot: runtime and VoiceCapabilityConversationSelfTest **will conflict with uncommitted work**. Coordinator route/admission hunks stay away from voice-ack's commit hook, but that file and latency/pipeline helper need manual peer integration. The off-limit LLMProvider/LlamaLLMProvider/RealtimeAgent files are untouched. Mini has released its need for shared voice scratch. Voice-ack acknowledged and retains it for its queued retry; do not delete it while that peer needs it.

Resource samples:1s own app PID only, no Apple service/children/continuous peak claim. First Apple/Mini/fallback sampled peak RSS956/2292/1051MB; footprints558/680/557MB. Shared used swap6279→6271MB Apple,6271→6962MB Mini,6962→6946MB fallback. These are observations under the allowed wrapper gate, not memory ceilings or causal proof. Full before/after OS/power/thermal/load/swap/source/binary pins are in label-pins.json. Exact finished child temp roots are removed by native-driver; foreign roots/files/processes untouched.

`green-slot.sh`/`apply-fix.py` reproduce RED→GREEN only from the scaffold commit; they are historical one-shot drivers, not commands to apply again on the finished branch. The old planned patch is superseded by the actual committed source. The native batch script does not skip a failing arm and never treats a missing marker as pass. The repeated pair below completes the requested additional check. Source is frozen at the verified producer implementation; the remaining contracts stay open.


## Explicit-census repeated pair, same source

Positioning relay `b421156d-99a0-43d0-99fe-0806bbe1ff43` requested explicit heavy-process and memory records. Ticket43 waited behind peer work and was temporarily held at free9GB<10GB; the gate later admitted it normally. No threshold override or foreign deletion. Own debug build298.79s. Both arms ran **back-to-back in ONE slot**, exact nine source hashes equal the first batch, and both fixture/model hashes unchanged. Repeat source, binary UUID/SHA, arguments, sampled own-PID resources and machine snapshots are retained in `repeat-*-pins.json`; summary [repeat-environment.json](repeat-environment.json).

Actual foreign-heavy executable counts **0 before / 0 after both arms**, not queued shell argument matches. This is a start/end census, not a continuous whole-machine quietness proof; Apple services and normal owner applications are outside that count. Apple starts/end load3.66/6.57, swap7520/7520MB, memory free56/57%. Mini starts/end load6.57/3.97, swap7520/7512MB, memory free56/55%. Disk was above the wrapper's admission threshold, then about9.2GiB after Mini; no claim that admission conditions stayed constant throughout. Parent listen2's earlier numbers remain incomparable across time, and high shared swap remains a confounder.

| Arm | Stage | n | Median s | p95 s | Min s | Max s |
|---|---|---:|---:|---:|---:|---:|
| Apple repeat | L1 | 5 | 0.677 | 0.679 | 0.676 | 0.679 |
| Apple repeat | L2 | 5 | 4.217 | 4.795 | 3.964 | 4.795 |
| Apple repeat | L3 | 5 | 4.437 | 4.990 | 4.157 | 4.990 |
| Resident Mini repeat | L1 | 5 | 0.680 | 4.523 | 0.675 | 4.523 |
| Resident Mini repeat | L2 | 5 | 3.360 | 7.723 | 2.216 | 7.723 |
| Resident Mini repeat | L3 | 5 | 3.910 | 8.277 | 2.626 | 8.277 |

Both repeat arms exit1 `VOICE_LATENCY_FAILED: run 1: voice.speech_end_to_eou is absent — the stage did not happen, or its mark was never stamped`. Qualified **Apple1/5 (run5), Mini0/5**. Apple's only qualified L1/L2/L3 values are0.676/4.795/4.990s; Mini has no qualified statistics. Apple's first4 turns useVAD and exceed100ms stalls; Mini all5 useVAD and first4 exceed100ms stalls. All five counted Mini answers have exact native final counts42/43/43/43/43, warm=true and positive prompt counts. All five Apple answers have final estimated counts. Mini remains loaded; its only11.616s weight load is before all spoken turns (total preparation14.124s). No live-turn model.load; no fallback mistaken for Mini. Actual Apple-synthesis calls0 and silent failure clauses0 in both arms. Sampled own-app peak RSS1020/2502MB and footprint546/702MB (Apple/Mini).

The first batch's committed2.008s predecessor timeout/9.242s canceled native child **does not recur as a missing answer in this repeat**. Shorter `speculation_barrier_failed` entries are canceled provisional generations, not evidence of the2s deadline failing. The repeat's misses are VAD/stall qualification, not repaired cancellation. No new native cancellation implementation or longer join was introduced. Repeat prefills mostly0.002–0.004s with reuse, plus one2.975s miss; warm caches do not establish reliable full-duplex behavior.

Raw five-value Mini L2 median3.360s is0.857s lower than Apple's4.217s, but Mini p957.723s is higher than4.795s. Raw Mini L3 median3.910s is lower than4.437s, but p958.277s is higher than4.990s. **Mini has not demonstrated a qualified L2 win.** With0/5 qualified turns, there is no native acceptance pair from which to recommend adoption. Both200ms gates fail. Park the live answerer experiment; retain the verified resident-only admission/actual Apple fallback diagnostic. Do not promote a role/default or call broader Agent/voice readiness complete.
