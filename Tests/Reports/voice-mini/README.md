# Resident Mini voice experiment — first batch evidence

Recommendation is provisional **park** pending the positioning-requested explicit-census repeat. The first decisive number is **1/5 qualified Mini turns**, against 2/5 Apple and 5/5 cold-Mini fallback turns. Four available Mini L2 values have a lower median than Apple, but one actual turn never reaches an answer token. This is not a qualified five-turn latency win. Mini L3 is worse. Both endpoint-to-first-answer and endpoint-to-first-audio 200ms gates fail. No role/default, stored choice, prompt, sampler, response deadline or production audio fallback was changed.

## Confirmed producer repair and original/fixed evidence

Listen2 made partial native preparation resident-only, but committed `streamInteractiveConversation` still invoked `loadIfNeeded`. Committed admission now checks weights, vocabulary and existing context before the existing reservation and again after its existing lane wait, and refuses insufficient existing context. It starts no cold load/context growth. Valid resident requests retain the same template, context, sampler and prefix path. Overflow-safe budget validation corrects the streaming budget crash found by the original fixture.

The frontend preserves the complete canonical Apple split route, then attempts resident Mini. Only `notLoaded` before any native answer text selects a fresh independent Apple Foundation Models answer session. Decode/protocol/cancellation errors and failures after text do not retry through Apple. The synchronous actual-provider observation reaches the real coordinator tracker through its existing MainActor route-resolution hop. No new turn await/store/queue/timer is introduced.

* Initial actual cold RED: debug build347.16s; PID16288 SIGTRAP/exit-5 (shell251), no final marker. Missing-model entry tried loading; a subsequent call loaded the fallback built-in model in23.492s, then `Int.max` overflowed streaming budget addition. This is not a passing RED marker or a complete scripted result. Own crash metadata and relevant stack frames: [red-crash-metadata.json](red-crash-metadata.json). The deliberately absent custom spec reset to the built-in isolated self-test model after failure; owner choices were never used.
* Subsequent scripted-only RED, same nine cases: debug build364.36s, exit1 `VOICE_RESIDENT_ANSWER_FAILED`, **18 targeted failures**. Native selection/identity missing, fault/cancel/late-notLoaded cases answered through Apple, unavailable/failed Pocket fallback spies1/1. Control/invalid refusals and revised-route discard exercised. The two real cold calls were explicitly UNRUN to isolate the earlier arithmetic crash.
* GREEN: debug build121.04s, exit0 `VOICE_RESIDENT_ANSWER_OK`. Full original caps8/Int.max both refuse before load; no model.load, no loaded weights. Cold/evicted calls native1/Apple1; resident/revised1/0; control/invalid0/0; fault/cancel/late-notLoaded1/0. Precommit silence and actual committed reply/speech retained. The resident fixture file hash is byte-identical RED/GREEN `e876332245c418aedd03a878baeb1469af9338545ee8b12af459c58fb8384151`. Speech contract body is also unchanged: [fixture-invariance.json](fixture-invariance.json).
* Actual five-turn cold consumer: `VOICE_LATENCY_OK`, 5/5 qualified; all five have one completed positive-count Apple answer and actual Apple summary, retained native refusal rows, no model.load, runtime loaded=false after all turns. This verifies producer and real file-fed consumer. It does not prove cancellation, microphone/ears, release or normal-use residency.

## Why routing is slow

Routing uses Apple Foundation Models typed `LocalVoiceRoute.collect()`, not Mini. The canonical validator is synchronous; successful route validation completes before native answer entry. Split routing takes no llama compute ticket. Native preparation/sampling use the existing context reservation/realtime lane.

Retained listen2 exact per-turn endpoint→routeDone medians: Apple route-only1.125s, Mini without prefill4.175s, final Mini4.343s (not the approximate difference of headline medians). The first final slow route occurred with Mini absent and partial prefill skipped. Concurrent Mini prefill therefore cannot be the sole explanation.

This batch's Apple arm, with no Mini pin, takes4–5s in typed collection itself. Validation is0–2ms. Thus the historical routing gap is not reproduced as a unique Mini-only delay. High shared-machine swap is recorded, but CPU/GPU/ANE, service/cache and pressure attribution remain **unproven**. The original batch uses one v2 heavy-wrapper slot and Apple then Mini back-to-back; it retained load/swap/thermal/power but not an explicit foreign-process count. Do not call the old listen2 run and today's run a controlled comparison. A repeat with explicit start/end census and memory% is queued at positioning's request.

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
| prefix cache | 0 | LLM_PREFIX_CACHE_OK: reused646/666 tokens, prefill1.74s→0.20s; stable prompt front90% |
| store isolation | 0 | STORE_ISOLATION_OK:21files/0defaults unchanged; nested TOOLLOOP_PRODUCTION_FAILED |

The nested store-isolation A02 fixture retains18 `TOOLLOOP_PRODUCTION_WRONG` admission failures from the unchanged requested-flag mismatch. Exit0 is only the narrow owner-store isolation verdict, not a green tool loop. See [status.txt](status.txt) and each label.stdout.log / label-pins.json. First combined wrapper exits1 because Apple/Mini latency fail.

## Pocket-only proof, coordination and scope

Pocket is prepared before measured turns; the SelfTest harness installs real Pocket on the existing synth and a silent failure backing. Unready/failed speech stays silent and fails evidence. Actual AVSpeech speak-entry counter is0 in all3 latency arms and pipeline; routing corpus counter0. PCM scheduling through an existing player is not Apple synthesis. Pipeline/routing harness scope exception: positioning relay `40d1dd82-c3a7-461e-8fc7-c62cf13c5fdc`. Exact additive3line counter prerequisite SHA256 `bf8d8984dbdec07f3b1e89035a95af793dfd5f4fb6b01d2650a0899de4972b9d`, shared with voice-ack `3d1a5070`; skip duplicate integration hunks. Voice-ack also adopted the same helper. This changes no production voice fallback outside our scope.

Own worktree only; no install/push/merge/GUI/owner-store reads. Read-only canonical conflict snapshot: runtime and VoiceCapabilityConversationSelfTest **will conflict with uncommitted work**. Coordinator route/admission hunks stay away from voice-ack's commit hook, but that file and latency/pipeline helper need manual peer integration. The off-limit LLMProvider/LlamaLLMProvider/RealtimeAgent files are untouched. Shared voice scratch is retained for queued voice-ack and repeat, never deleted while a peer needs it.

Resource samples:1s own app PID only, no Apple service/children/continuous peak claim. First Apple/Mini/fallback sampled peak RSS956/2292/1051MB; footprints558/680/557MB. Shared used swap6279→6271MB Apple,6271→6962MB Mini,6962→6946MB fallback. These are observations under the allowed wrapper gate, not memory ceilings or causal proof. Full before/after OS/power/thermal/load/swap/source/binary pins are in label-pins.json. Exact finished child temp roots are removed by native-driver; foreign roots/files/processes untouched.

`green-slot.sh`/`apply-fix.py` reproduce RED→GREEN only from the scaffold commit; they are historical one-shot drivers, not commands to apply again on the finished branch. The old planned patch is superseded by the actual committed source. The native batch script does not skip a failing arm and never treats a missing marker as pass. Repeat evidence will be added after its slot runs or a genuine scheduling/availability constraint prevents it.
