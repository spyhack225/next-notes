# PL12 listen2 partial routing and native prefill, 8 October 2026

The route-only diagnostic works through the real coordinator, split route collector/validator, committed stream and speech consumers. All 12 unchanged scripted scenarios pass after the RED 16 missing-feature failures. This does not establish 200 ms listening: matched native Apple/Pocket n=5 medians remain L1 0.676 s, L2 2.674s, L3 2.884s.

The committed base already starts validated routing and buffered answer drafting on stable partials. The prototype retains one complete validated route in the existing speculative buffer, starts answering only on the matching commit, and falls back through the original path for text/context/correlation revisions. It requires SelfTest voice-latency plus `--voice-latency-partial-route`; production/default behavior stays on the existing path. Terminal courtesy does not qualify as an exact route match. Canonical punctuation does: the admitted partial's answer plan remains in the same slot. A pending route continues once, asynchronously; commit does not join a speculative preparation task. No new cache/store/runtime/queue/model pass or precommit effect was added.

## Native fixture and before/after

Debug arm64, macOS 27.2 (26B5091g), M3/16 GB. All heavy work used `RELAY_ID=claude2-listen2 ../heavy.sh` and the owned scratch. One warmup excluded, five counted file-fed turns, Apple typed route/answer, real prepared Pocket PCM/playback. Same WAV SHA256 `ec9f48e5b38281e2ef3022904db9eb2e3eb5b69bdcbaab94faf000a9c91fbeab`. P95 is nearest rank; with n=5 it is the maximum. Native pins, raw rows and sampled resource reports are adjacent. These are exploratory unbundled debug observations, not an optimized release/physical microphone/ears check, model/default promotion or a statistically established latency improvement.

| Measure (seconds) | Corrected base median/p95/min/max | Route-only median/p95/min/max |
|---|---|---|
| L1 onset to preparation handoff | .678/.683/.673/.683 | .676/.677/.672/.677 |
| L2 endpoint to first answer consumed | 2.849/3.831/2.473/3.831 | 2.674/3.082/2.428/3.082 |
| L3 endpoint to first audible | 3.001/4.426/2.615/4.426 | 2.884/3.534/2.599/3.534 |

Both original and route-only 200 ms median gates FAIL. L1 remains overwhelmingly first ASR partial availability. Routing is reused but becomes ready .973–1.490s AFTER endpoint in every counted diagnostic turn (median 1.125 s); routeDone-to-first-answer median1.491s. Prefill of a llama answer cannot remove those remaining Apple routing seconds.

The first original baseline actually failed: the existing latency harness selected Pocket but never prepared it, so synthesis fell back to system speech and its PCM marks were absent. The existing harness now prepares Pocket before any measured turn and refuses absence rather than measuring a fallback. No production await was introduced. See `pocket-setup.md`, `baselines.json`, original raw logs. Both qualified measurements use the corrected harness, with all three base voice producer hashes invariant in the corrected baseline. A missing base task-store reader prevented the first compile: exact canonical uncommitted prerequisite is isolated in20d8f9b8, documented in `base-prerequisite.md`.

The first route-only GREEN attempt failed one unchanged canonical punctuation assertion: constructing a fresh final answer plan produced a different scripted answer. Retaining the admitted partial plan fixes the responsible producer without changing the fixture (SHA256982488e3b99589617826cd54a62c6042a117b3b3ae4e47084fbe97c30a2da315). Original and failed-attempt logs are retained. Scripted timing is not native performance evidence.

## Related checks and limits

Route RED `VOICE_PREPARATION_FAILED` exit1, fixed `VOICE_PREPARATION_OK` exit0. Both qualified native runs `VOICE_LATENCY_OK` exit0. Related ordinary partials `VOICE_PREPARATION_OK`; pipeline `VOICE_PIPELINE_OK`; routing `VOICE_TURN_ROUTING_OK`; concurrency `CONCURRENT_VOICE_OK`; conversation `VOICE_CONVERSATION_OK`; duplex `DUPLEX_OK`; native prefix cache `LLM_PREFIX_CACHE_OK`646/666; privacy `STORE_ISOLATION_OK: 21 files and 0 defaults unchanged`. Each exited 0. Zero watched defaults is the actual unbundled coverage, not proof of installed preferences.

Isolation also prints a nested `TOOLLOOP_PRODUCTION_FAILED` with 18 A02 fixture failures. The unchanged StoreIsolationSelfTest.swift:49 invokes that fixture while requested remains `--selftest-store-isolation`; unchanged AgentToolExecutor.swift:22 admits its page fixture only under `--selftest-toolloop-production`. Privacy's verdict remains narrow; broader tool-loop correctness is open. Neither scoped prototype producer runs under that flag. No test/admission guard was weakened or off-limits tool source edited.

Baseline 1 s resource sampling: 108 samples, RSSmax954318848B, footprintmax541247432B. Route-only 107 samples, RSSmax978599936B, footprintmax555583504B. These include warmup and exclude Apple service/children; sampled maxima are not continuous peaks. Native-launch swap/load/thermal and end snapshots are retained in JSON. No thermal warning reported at these snapshots; this is not continuous thermal proof. Failed queued watcher with 0 samples is absence, not a resource result.

## Conditional prefill evidence

Pending next guarded native slot. No prefill/default claim is made by the route checks above.
