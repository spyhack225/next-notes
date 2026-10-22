# Resumed ASR paced latency — 22 October 2026

Status: all eight candidates completed. Phonon supports English only; the other seven have three English and three French trials. Native candidate windows were serialized through agent-relay. Recommendation: Phonon for an English speed-first integration candidate, Voz for French. No installed default changed.

## Method and boundaries

Apple M3 / 16 GB Mac, three warmed real-time-paced trials per supported language. The same 16 kHz mono authored dialogue excerpts supply English 7.25 s (20 words) and French 6.65 s (22 words). Audio becomes available against a monotonic clock. First inference receives 400 ms, then prefixes update every second, coalescing calls that run slowly. Release occurs independently of inference; release-to-final includes outstanding work and the final complete-audio call. Shapes warm before timing; downloads, native compilation, model load and warmup are separate from delivery latency.

First word means the first readable provisional word. Qwen timestamps its completed first-word boundary during token generation. Whistle returns committed deltas plus a pending tail through its native streaming API; other engines use paced prefix inference. A retrospective first-word match is not native commitment. Whistle's native commitment is separately recorded.

These are runtime callback measurements, excluding physical microphone capture, UI display, polish, external insertion and simultaneous ASR/voice workload. Three samples support medians and observed ranges, not tail-latency or broad quality claims. Full-duplex app acceptance remains open. No application default or installed app changed.

## Results and default candidates

Median milliseconds; lower is faster. Model sizes are decimal MB of the measured artifacts, excluding runtime/compiler caches. Full-fixture word error rates are separate accuracy observations (136 EN / 151 FR words), not live timing grades.

| Model | Size MB | EN first / final after release | FR first / final after release | Full-fixture WER EN / FR |
|---|---:|---:|---:|---:|
| **Phonon 2** | 345.0 | **421 / 52 ms** | Unsupported | 0.74% / — |
| **Voz** | 336.7 | 451 / 66 ms | **446 / 83 ms** | 3.68% / 11.92% |
| Whistle | 16.9 | 428 / 85 ms | 429 / 156 ms | 5.15% / 19.87% |
| Parakeet v3 | 483.3 | 513 / 133 ms | 511 / 160 ms | 4.41% / 9.93% |
| Ultra | 632.2 | 515 / 142 ms | 506 / 141 ms | 4.41% / 9.93% |
| Redux | 220.3 | 808 / 342 ms | 710 / 419 ms | 5.15% / 12.58% |
| Qwen 0.6B 4-bit | 712.8 | 546 / 507 ms | 552 / 1,030 ms | 0.74% / 9.27% |
| Qwen 1.7B 4-bit | 1,607.6 | 572 / 659 ms | 601 / 1,297 ms | 3.68% / 3.97% |

English: Phonon has the lowest median first-word and release-to-final times, with zero errors on the short excerpt and the best tied whole-file English error count. Its first-word advantage over Whistle is only 6 ms in this small sample; its finalization advantage is larger. French: Whistle has the lowest provisional first-word median by 17 ms, while Voz has the lowest release-to-final median and avoids Whistle's substantive short-excerpt mistakes. Therefore Voz is the speed-first French default candidate. For French accuracy first, Qwen 1.7B has the best observed full-fixture WER, at appreciably greater latency/storage cost. These are candidates for production integration and broader accuracy testing, not proof of a universal fastest or most accurate model.

All first-word times include the shared 400 ms initial feed. They do not establish each model's minimum achievable first-word latency under a different streaming cadence. Raw three-sample values and observed ranges are in `comparison.json`; no percentile estimate is inferred.

Whistle's first provisional word is quick, but native first commitment is 2,457 ms EN / 1,454 ms FR. Its French final substitutes different words for “le devis demain matin.” Raw short-excerpt edits are EN 1/20 and FR 6/22. V3, Redux, Ultra, Qwen 0.6B and Voz have EN 0/20 and FR 2/22; the French differences are solely “quarante mille” rendered as “40 000.” Qwen 1.7B has 0/20 EN and 0/22 FR; Phonon has 0/20 EN. Literal WER must not equate this formatting with changed meaning.

The separate [whole-file comparison](../asr-candidates-2026-10-22/README.md) uses 136 English / 151 French reference words and remains a limited single-fixture quality observation. Its throughput is not first-word or release latency. The earlier [pressure experiment](../asr-live-latency-2026-10-22/README.md) is retained separately and is not pooled with this suite.

## Harness corrections and failures

`rpc-stderr-original-fixed.json`: original RPC reader fails the same bounded 256 KiB native-stderr case; repaired reader passes by draining both pipes with bounded diagnostics. Fresh v3 has an empty stderr tail, so this generic bug is not established as the cause of its old pressure stall. The initial overly tight test attempt is retained in `rpc-stderr-regression.json`.

`sdk-timeout-original-fixed.json`: the original SDK runner kills only its parent and fails the owned descendant lifecycle test. The fixed runner kills its own process group, joins it and closes pipes; the same test passes. This protects disposable benchmark builds and adds no product-path waiting.

`phonon-default-readiness-failure.json`: vendor default eagerly initializes 15 s, while this excerpt needs 5/10 s functions. Native readiness exceeded the diagnostic 120 s deadline. This is a censored startup observation, not a live latency result. The child was joined and its temporary assets deleted. The successful subsequent attempt requests only the vendor-supported 5/10 s functions and eagerly prepares 5 s; same weights/audio, unused 15/35 s shapes omitted. `phonon.json` records the successful native run and all three timed trials. Stable installation paths can reuse ANE specialization; disposable paths pay cold specialization, so these startup observations are not steady installed load times.

## Storage, ownership and provenance

Candidates are downloaded, run, saved, joined and deleted one at a time. Original installed model files and other agents' caches/processes are preserved. `*-context.json` retains disk, swap, thermal, power and process snapshots. `slot-one-cleanup.json` records the first native window handback: five reports saved, no ASR child/runtime/model remains, owned 19,373,776-byte probe removed. The second window began after explicit TTS and prefix-check handbacks; `final-cleanup.json` records all remaining children joined, all temporary assets deleted, idle OS ANE compiler samples and 4,002,684,928 bytes (3.73 GiB) free. The benchmark cache contains only a zero-byte lock. Installed v3 assets were reused and retained; all 23 owner model hashes were unchanged in the v3 receipt. No other owner cache was swept.

`probe-build.json` pins the v3/Redux/Ultra probe and linked cached FluidAudio inputs. The shared source checkout has missing Git alternate objects; these hashes identify actual probe inputs, not a clean rebuild or installed-app source equivalence. Each candidate report pins its model/source/runtime metadata. Raw diagnostics remain private.

Whistle CoreML remains a separate integration investigation: the measured 16.9 MB custom CPU artifact is not a published CoreML model. The [earlier audit](../asr-live-latency-2026-10-22/README.md) distinguishes its returned internal batch TTFT (~14 ms) from paced first-word delivery (~428 ms), and documents why a CoreML port needs validated export/operator/decoder parity before any speedup claim. No conversion toolchain or replacement weights were retained.

Validation: all 13 model-free ASR tests pass. Native reports all have child exit 0 and joined children. The initial failed Phonon readiness attempt and both original/fixed harness regressions are retained, rather than overwritten by successful results.
