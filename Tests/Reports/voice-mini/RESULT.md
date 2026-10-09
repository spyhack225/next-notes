# voice-mini result

**Recommendation: park Mini as a live voice answerer.** The deciding number is **0/5 qualified Mini turns** in the repeated Apple→resident Mini pair, versus 1/5 Apple. All five Mini answers completed with warm native final counts, but every endpoint used VAD and four turns exceeded the unchanged 100 ms main-thread stall limit. Both 200 ms gates fail. Mini has no qualified L2 comparison from this repeat.

The cold-admission repair passed: committed native requests now refuse absent weights or insufficient existing context through the existing reservation/lane, without loading or growing context on the turn. Only `notLoaded` before any answer text selects an independent Apple Foundation Models answer through the already-validated split route. Actual provider identity reaches the coordinator and usage summary. Defaults, roles, stored choices, prompts, samplers and deadlines remain unchanged. Diagnostic speech uses prepared Pocket or silence; measured Apple synthesis-entry counters are zero. Apple language modeling is separate from Apple TTS.

## Commits and scope

Own branch `claude2/voice-mini` contains `82591312` (original fixtures/evidence) and `e8c2f0e2` (producer repair and first native batch). The final evidence commit contains the repeated pair and this handoff; it changes no source. Integration requires the inherited listen2 substrate at `73f4dde8`.

Changed producers: `Formatting/LLM/LocalVoiceFrontend.swift`, interactive admission in `NotesModelRuntime.swift`, and the route/admission tracker in `VoiceConversationCoordinator.swift`. Tests: voice latency, preparation, new resident-answer/Pocket helper, and the approved pipeline/routing harness changes. Speech synthesis has only the additive three-line test counter. Reports and PERFORMANCE-STANDARDS retain evidence. `LLMProvider.swift`, `LlamaLLMProvider.swift` and `RealtimeAgent.swift` are untouched. Worktree only; **no install, push or merge**.

## Original/fixed verification

* Actual original cold calls with caps 8/Int.max tried loading. After the missing custom model failed, the next call loaded the built-in isolated self-test fallback in 23.492 s and arithmetic-overflowed: SIGTRAP, exit -5, **no final marker**. Fixed identical cold calls refuse before load and leave weights absent. Budget validation is overflow-safe; the extreme loaded-budget branch was not independently hardware-probed afterward.
* Scripted-only RED: 18 missing-feature failures, exit 1, `VOICE_RESIDENT_ANSWER_FAILED`. Full original cold calls plus the same nine scripted cases GREEN: exit 0, `VOICE_RESIDENT_ANSWER_OK`. Fixture hashes match. Before the native fixture hook existed, the generic scripted generator supplied the Apple fake for every provider. Those RED negatives establish missing functionality, not that the old real native SDK retried decode errors through Apple. The corrected negative cases exercise the actual frontend/coordinator catch policy.
* Actual cold Mini→Apple file-fed run: exit 0, `VOICE_LATENCY_OK`, **5/5 qualified**. No `model.load`; Mini remains unloaded. Every turn has one completed positive-count Apple answer and actual provider summary, with the native refusal retained. Entry→fallback takes 0.263–0.987 ms; there is no second route collection.
* First matched pair: Apple 2/5 qualified, Mini 1/5. Mini has four L2 values because one turn lacks an answer. An older native prefill took 9.242 s to cancel; the next committed producer failed its existing 2 s predecessor barrier after 2.008 s, before routing. Those producer/barrier bodies are unchanged from listen2. A longer or second join does not repair delayed native cancellation; the internal native phase is not isolated.
* Repeat: identical nine source hashes, fixture and model artifact; Apple then Mini back-to-back in one heavy slot. All five Mini answers complete; the earlier missing-answer timeout does not recur. VAD/stalls still leave **0/5 qualified**. Each arm exits 1 with the exact marker `VOICE_LATENCY_FAILED: run 1: voice.speech_end_to_eou is absent — the stage did not happen, or its mark was never stamped`.

Repeated raw timings, including failed turns (seconds; p95 is nearest-rank):

| Arm | Stage | n | Median | p95 | Min | Max |
|---|---|---:|---:|---:|---:|---:|
| Apple | L1 | 5 | 0.677 | 0.679 | 0.676 | 0.679 |
| Apple | L2 | 5 | 4.217 | 4.795 | 3.964 | 4.795 |
| Apple | L3 | 5 | 4.437 | 4.990 | 4.157 | 4.990 |
| Resident Mini | L1 | 5 | 0.680 | 4.523 | 0.675 | 4.523 |
| Resident Mini | L2 | 5 | 3.360 | 7.723 | 2.216 | 7.723 |
| Resident Mini | L3 | 5 | 3.910 | 8.277 | 2.626 | 8.277 |

Mini's raw L2 median is lower, but its p95 is higher and no Mini turn qualifies. This is not an adoption result.

All required related checks ran in the first combined slot on the same verified implementation:

| Check | Exit | Exact marker |
|---|---:|---|
| Partial/prefill preparation | 0 | VOICE_PREPARATION_OK |
| Voice pipeline | 0 | VOICE_PIPELINE_OK |
| Voice turn routing | 0 | VOICE_TURN_ROUTING_OK |
| Concurrent voice | 0 | CONCURRENT_VOICE_OK |
| Voice conversation | 0 | VOICE_CONVERSATION_OK |
| Duplex | 0 | DUPLEX_OK |
| Prefix cache | 0 | LLM_PREFIX_CACHE_OK: reused 646/666 tokens, prefill 1.74s → 0.20s; stable prompt front 90% (was 73% before P1-28) |
| Store isolation | 0 | STORE_ISOLATION_OK: 21 files and 0 defaults unchanged |

Store isolation later prints `TOOLLOOP_PRODUCTION_FAILED`, retaining 18 inherited A02 requested-flag admission failures. The isolation marker is narrow; this is not a green tool loop. Both matched wrappers exit 1. No missing or failed check is reported as passed. Full first/repeated timing tables, qualified-only observations, literal marker order and source/binary/resource pins are in [the report](README.md), [verdicts](verdicts.json) and [native data](native-analysis.json).

## Questions and remaining contracts

Apple FM performs typed route collection. Canonical validation is synchronous and finishes before native answer entry; it does not wait for Mini. Retained historical endpoint→routeDone medians were Apple 1.125 s / Mini 4.343 s. The first old slow Mini route occurred with Mini absent. Today's Apple-only collection is also slow, so concurrent Mini prefill is not the sole cause. CPU/GPU/ANE, service/cache and shared-pressure attribution remains unproved. The separate delayed native child can block the next speculative producer's existing drain, as measured above.

Normal-use residency and pressure-eviction rates are **unavailable**: owner stores were excluded. Authored retained diagnostic rows show warm 5/cold 0 and warm 4/cold 1, not a population estimate. Resident runs stay loaded; the cold arm stays unloaded. `Gemma 4 E4B reason=switched resident` unload notes are selector/reset facts, not measured Mini pressure evictions.

The rejected single-decision experiment failed semantic/history acceptance (single 12/15 versus split 13/15). It was not repeated. No rule bypass or unverified Mini router was added. Preserve the full validated Apple split and exact partial reuse. Native cancellation, localEOU/stall qualification, release/physical microphone/ears, normal-use residency and aggregate model/Agent quality remain open.

The repeat measured zero foreign heavy executables at both start/end of both arms, with recorded load/swap/memory percentage. That is not continuous quietness proof. Shared used swap was about 7.5 GB. Own-app sampled peak RSS was 1,020/2,502 MB (Apple/Mini), excluding services and continuous peaks. Historical listen2 comparisons are not a controlled same-time pair.

## Integration and cleanup

Runtime and `VoiceCapabilityConversationSelfTest.swift` **will conflict with uncommitted work** in the canonical checkout. Merge coordinator by hand: these route-summary hunks are away from voice-ack's commit hook. The Pocket helper, latency/pipeline harness and exact three-line counter are shared with voice-ack (`3d1a5070`; counter patch SHA256 `bf8d8984dbdec07f3b1e89035a95af793dfd5f4fb6b01d2650a0899de4972b9d`); skip duplicate hunks. Approved harness exception: relay `40d1dd82-c3a7-461e-8fc7-c62cf13c5fdc`.

The no-Apple producer retains the helper signature but ignores its fallback argument. Its interruption/delivery proof supersedes the helper's old dropped-clause observation; that integration is unverified here. Do not treat a PCM scheduling event as Apple synthesis evidence.

All finished child private roots were removed. Mini has explicitly released its need for shared `wt-scratch/voice`; voice-ack acknowledged and is retaining it for its queued retry. Do not delete it before that peer finishes. No foreign file, process, claim or owner store was changed or deleted. The resource gate briefly held the repeat at 9 GB free; no bypass. Source remains frozen at the verified implementation.
