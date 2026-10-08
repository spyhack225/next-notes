# listen2 — retained routing/prefill experiment

The 200 ms L1/L2 gates are **not met**. Diagnostic route reuse works through the actual coordinator/stream/speech consumers. The native prefill API and resident admission tests pass, but the final native candidate is **not accepted**: its first required cold answer lacks final counts at the unchanged 25 s deadline, and VAD/stall/prefix-speed checks remain failed. This is an experiment report, not a default/model/phase promotion.

Own branch `claude2/listen2`, relay `claude2-listen2`; canonical checkout was read only. No install, push or merge. All Swift builds/native/self-tests/model loads used `RELAY_ID=claude2-listen2 ../heavy.sh` v2/FIFO, one claimed slot at a time and owned scratch. Queue/resource waits were not runs or passes. The final slot returned1 because its real checks failed. No gate, deadline, sampler, prompt, quality assertion or stored choice was weakened.

## Matched native measurements

Seconds: median / p95 / min / max. One excluded warmup and five counted turns per run; nearest-rank p95 is the maximum at n5. L1 is onset to preparation handoff, L2 endpoint to consumed first answer, L3 endpoint to first audible. The same file-fed WAV has SHA256 ec9f48e5b38281e2ef3022904db9eb2e3eb5b69bdcbaab94faf000a9c91fbeab. Unbundled debug arm64, macOS27.2 26B5091g, M3/16GB. Pocket is actually prepared and its PCM/playback measured. No physical microphone or ear acceptance was run.

| Seconds | Corrected base Apple/Pocket | Route-only Apple/Pocket |
|---|---|---|
| L1 | .678/.683/.673/.683 | .676/.677/.672/.677 |
| L2 | 2.849/3.831/2.473/3.831 | 2.674/3.082/2.428/3.082 |
| L3 | 3.001/4.426/2.615/4.426 | 2.884/3.534/2.599/3.534 |

Both native markers VOICE_LATENCY_OK, exit0; both200ms gates FAIL. Original base already starts Apple routing and buffered answers on stable partials. Retaining the route alone does not remove the Apple model delay: it finishes .973–1.490s after endpoint (median1.125s), then first answer takes median1.491s. L1 remains dominated by first ASR partial availability.

| Seconds | Matched Mini, prefill disabled | Matched Mini, resident prefill enabled |
|---|---|---|
| L1 | .716/1.387/.673/1.387 | .713/.933/.687/.933 |
| L2 | 17.206/21.668/15.253/21.668 | 5.197/22.596/4.489/22.596 |
| L3 | 19.774/24.334/16.347/24.334 | 7.323/23.143/5.530/23.143 |
| routeDone to first answer | 13.679/15.902/11.078/15.902 | .387/19.097/.128/19.097 |

These are all five observed timestamps, not five fully qualified completed native passes. Both runs end VOICE_LATENCY_FAILED, exit1; both200ms gates FAIL. Mini artifact SHA256 ec2d5801640099e97d8d7e8003ad4d81f336e757811f03a26173dddf386602fd remains identical, thinking off and sampler unchanged. Same driver/run count, differing generated histories; the smaller median is exploratory, not a statistically proved improvement or qualified latency gate.

Final after has three VAD endpoints (runs2–4), max main-thread stall.296s over.100s. Before has two VAD endpoints and stall1.184s. Final run1 pays required cold load13.103s plus prefill5.306s and generation; the existing25s response deadline cancels it. The correctly pinned/joined row is present in stdout and the owned private usage log, but says stop with unavailable final counts. It fails the unchanged native qualification predicate. The marker's broad wording does not mean no native model ran. The excluded warmup also has no real answer-token mark. Cold start, cancelled-stream/count completion, EOU and responsiveness contracts remain open.

The initial prefill candidate is separately rejected: an optional while-speaking partial starts12.299s of cold loading and strands a cancelled native owner; the next committed turn has no answer-token mark. L2 n4 median4.0795/p955.883 is not a five-turn result; L3 includes1.228s of error speech. Nothing missing was filled with zero or dropped to manufacture a passing distribution. Exact initial source snapshots/raw logs/pins remain retained.

## Producer changes and original/fixed proof

Route RED:16 failures across12 unchanged authored scenarios; final VOICE_PREPARATION_OK. Native prefill entry RED: INTERACTIVE_PREFILL_FAILED:1 problem(s); original fixture body remains byte-identical and ends INTERACTIVE_PREFILL_OK. New resident producer contract RED: RESIDENT_PREFILL_FAILED:5 problem(s); same additive fixture ends RESIDENT_PREFILL_OK.

LocalVoiceFrontend retains the complete validated route and admitted answer plan in its existing speculative slot. Exact normalized text/context/token budget/mode/correlation reuse it; terminal courtesy and actual revisions fall back. Pending route completes once asynchronously; commit never joins speculative preparation. No speech/history/tool effect is emitted before commit. The switch requires SelfTest voice-latency plus --voice-latency-partial-route. Prefill additionally requires --voice-latency-prefill and the explicit local answering pin.

NotesModelRuntime.prepareInteractiveConversation uses the same family/BOS tokenizer, realtime reservation, native context and KV token ledger; no sampler. Commit checks the exact rendered prefix and decodes at least the last token. Optional partials require resident weights/vocabulary/context before reservation, recheck after it, and refuse context growth. This repairs the newly introduced optional cold-load admission contract; it does not establish full cold-start voice correctness. Required answers retain their original cold path. No store, queue, runtime, ledger, model pass, timer, timeout increase or production confirmation was added.

## Exact final checks

| Check | Exit | Final marker |
|---|---:|---|
| resident-red | 1 | RESIDENT_PREFILL_FAILED: 5 problem(s) |
| resident-green | 0 | RESIDENT_PREFILL_OK |
| prefill-final | 0 | INTERACTIVE_PREFILL_OK |
| route-resident-final | 0 | VOICE_PREPARATION_OK |
| mini-after-final | 1 | VOICE_LATENCY_FAILED: run 1: explicit answering file pin did not reach the committed consumer and joined native answer pass |
| resident-partials | 0 | VOICE_PREPARATION_OK |
| resident-pipeline | 1 | VOICE_PIPELINE_FAILED |
| resident-routing | 0 | VOICE_TURN_ROUTING_OK |
| resident-concurrent | 0 | CONCURRENT_VOICE_OK |
| resident-conversation | 0 | VOICE_CONVERSATION_OK |
| resident-duplex | 0 | DUPLEX_OK |
| resident-prefix | 1 | LLM_PREFIX_CACHE_FAILED: 1 problem(s) |
| resident-isolation | 0 | STORE_ISOLATION_OK: 21 files and 0 defaults unchanged |

Pipeline failed with actual cold local EOU prepare6.855s and VAD endpoint. Default prefix failed its speed requirement: second5.53s is not half of first2.33s; no cache correctness assertion failed. Neither enables the new diagnostic entry. Their actual capture/EOU and default native streaming/test bodies are unchanged (hash assertions retained), but the cause of timing variability has not been independently established. Prior green checks are retained, not substituted for these failed verdicts.

Isolation's narrow privacy result covers21files and **0 watched defaults**, not the installed preference coverage. Its stdout again contains TOOLLOOP_PRODUCTION_FAILED with18 A02 failures: the in-process nested fixture uses isolation as requested, while its unchanged strict page-fixture guard requires toolloop-production. This known wiring failure stays open; no guard was weakened. Duplex also prints two reducer divergence diagnostics despite DUPLEX_OK. No factual/action/model quality, physical microphone, optimized release, full startup or broader Agent readiness claim is made; inherited quick3/10 remains open.

Original baseline compile was blocked by an absent recoveredReadHistory reader; exact canonical10line prerequisite is isolated in20d8f9b8 and must not be duplicated. First original Pocket baseline then ended VOICE_LATENCY_FAILED because the harness selected Pocket without preparing it, falling back to system speech without PCM marks. a8a2d629 fixes the harness's setup producer before measurement; all three base voice producer hashes remained invariant. Both qualified Apple measurements use that corrected harness. Earlier route/fix/related markers, exact source/fixture/binary pins and real failures are in the linked retained report.

Final Mini resource sample:163 one-second samples, RSSmax2178433024B/footprintmax685903256B; swap6464.12→6526.75MiB at native launch/end. Apple service/child costs are excluded; sampled maxima and thermal snapshots are not continuous traces/peaks. Numerical rows agree with all available stdout counterparts. Only five authored turn metadata rows were retained from the exact exited owned native PID, then its temp root was removed. No owner-store payload was read.

## Commits and integration

- 20d8f9b8: separately authorized exact missing-reader prerequisite; skip duplicate canonical hunk.
- a8a2d629: real Pocket setup and baseline evidence.
- 06e0f7be: scripted route RED.
- 0c0354d5: diagnostic route retention and original/fixed consumers.
- 9e5e510b: native API RED scaffold/fixture.
- 8eb3fbbf: route/native RED evidence and shared standard.
- 1570c4c1: rejected cold-prefill iteration/source snapshots.
- 32c41d5a: resident-only diagnostic prototype and all final failed acceptance evidence.

Changed product/test sources: Formatting/LLM/LocalVoiceFrontend.swift, NotesModelRuntime.swift, PrefixCacheSelfTest.swift; Agent/Voice/VoiceLatencySelfTest.swift and VoicePreparationSelfTest.swift; the prerequisite Agent/Tasks/AgentTaskStore.swift. PERFORMANCE-STANDARDS.md and Tests/Reports/pl12-listen2 contain the shared findings/evidence. Owned VoiceConversationCoordinator.swift is unchanged. RealtimeAgent, LLMProvider and LlamaLLMProvider were not edited.

Final read-only canonical check is timestamped in canonical-conflicts.json; all three owned-file logs were read again after the source commit. Canonical HEAD55d402ee3778e7b2204e969adec9c5108c2b192a. Coordinator and frontend are clean and byte-identical to the original base. Runtime has uncommitted work; latest canonical owned-file entries remain d209b294 (coordinator),61fadf0a (frontend),1af0ca2c (runtime).

- NotesModelRuntime.swift **will conflict with uncommitted work**; merge this bounded API into the owner's runtime work manually, preserve its changes.
- PrefixCacheSelfTest.swift **will conflict with uncommitted work**; retain both sets of native fixtures/dispatch branches.
- AgentTaskStore.swift has the identical uncommitted reader prerequisite; skip the duplicate, preserve other canonical changes.
- Frontend/coordinator, the two voice test files and the shared standard were clean in canonical at this check. Shared-standard report additions still need normal integration review against concurrent committed evidence.

The integrator should keep prefill classified as experimental/rejected until the cold completion and failed native checks are resolved with original/fixed producer evidence; no promotion is supported here. Further latency work must address ASR first-partial availability and the Apple routing stage, not only answer prefill. Full-duplex capture/model/speaker behavior must remain independent of development coordination.

Owned scratch was removed after wrapper/sampler exit; six exact exited owned PID-scoped temp roots were removed, ordinary auxiliary fixtures retain their normal deferred cleanup. Unidentified/foreign temp roots, models, caches, owner app and claims were preserved. [Detailed report](Tests/Reports/pl12-listen2/README.md), final-comparison.json, resident-checks.json, canonical-conflicts.json and cleanup.json retain the evidence. No install/push/merge occurred.
