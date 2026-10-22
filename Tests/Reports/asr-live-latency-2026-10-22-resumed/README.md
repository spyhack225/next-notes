# Resumed ASR paced latency — 22 October 2026

Status: five of eight candidates measured; remaining native cases pending the coordinated quiet machine window. Do not promote a default from this interim report.

## Method and boundaries

Apple M3 / 16 GB Mac, three warmed real-time-paced trials per supported language. The same 16 kHz mono authored dialogue excerpts supply English 7.25 s (20 words) and French 6.65 s (22 words). Audio becomes available against a monotonic clock. First inference receives 400 ms, then prefixes update every second, coalescing calls that run slowly. Release occurs independently of inference; release-to-final includes outstanding work and the final complete-audio call. Shapes warm before timing; downloads, native compilation, model load and warmup are separate from delivery latency.

First word means the first readable provisional word. Qwen timestamps its completed first-word boundary during token generation. Whistle returns committed deltas plus a pending tail through its native streaming API; other engines use paced prefix inference. A retrospective first-word match is not native commitment. Whistle's native commitment is separately recorded.

These are runtime callback measurements, excluding physical microphone capture, UI display, polish, external insertion and simultaneous ASR/voice workload. Three samples support medians and observed ranges, not tail-latency or broad quality claims. Full-duplex app acceptance remains open. No application default or installed app changed.

## Interim observations

| Model | EN first word / final after release | FR first word / final after release |
|---|---:|---:|
| Parakeet v3 | 513 / 133 ms | 511 / 160 ms |
| Whistle | 428 / 85 ms | 429 / 156 ms |
| Redux | 808 / 342 ms | 710 / 419 ms |
| Ultra | 515 / 142 ms | 506 / 141 ms |
| Qwen 0.6B 4-bit | 546 / 507 ms | 552 / 1,030 ms |

Whistle's first provisional word is quick, but native first commitment is 2,457 ms EN / 1,454 ms FR. Its French final substitutes different words for “le devis demain matin.” Raw short-excerpt edits are EN 1/20 and FR 6/22. The other four completed engines have EN 0/20 and FR 2/22; the French differences are solely “quarante mille” rendered as “40 000.” Literal WER must not equate this formatting with changed meaning.

The separate [whole-file comparison](../asr-candidates-2026-10-22/README.md) uses 136 English / 151 French reference words and remains a limited single-fixture quality observation. Its throughput is not first-word or release latency. The earlier [pressure experiment](../asr-live-latency-2026-10-22/README.md) is retained separately and is not pooled with this suite.

## Harness corrections and failures

`rpc-stderr-original-fixed.json`: original RPC reader fails the same bounded 256 KiB native-stderr case; repaired reader passes by draining both pipes with bounded diagnostics. Fresh v3 has an empty stderr tail, so this generic bug is not established as the cause of its old pressure stall. The initial overly tight test attempt is retained in `rpc-stderr-regression.json`.

`sdk-timeout-original-fixed.json`: the original SDK runner kills only its parent and fails the owned descendant lifecycle test. The fixed runner kills its own process group, joins it and closes pipes; the same test passes. This protects disposable benchmark builds and adds no product-path waiting.

`phonon-default-readiness-failure.json`: vendor default eagerly initializes 15 s, while this excerpt needs 5/10 s functions. Native readiness exceeded the diagnostic 120 s deadline. This is a censored startup observation, not a live latency result. The child was joined and its temporary assets deleted. The next attempt requests only the vendor-supported 5/10 s functions and eagerly prepares 5 s; same weights/audio, unused 15/35 s shapes omitted. Stable installation paths can reuse ANE specialization; disposable paths pay cold specialization, so these startup observations are not steady installed load times.

## Storage, ownership and provenance

Candidates are downloaded, run, saved, joined and deleted one at a time. Original installed model files and other agents' caches/processes are preserved. `*-context.json` retains disk, swap, thermal, power and process snapshots. `slot-one-cleanup.json` records the first native window handback: five reports saved, no ASR child/runtime/model remains, owned 19,373,776-byte probe removed. Before resuming native work, require an explicit machine handback through agent-relay.

`probe-build.json` pins the v3/Redux/Ultra probe and linked cached FluidAudio inputs. The shared source checkout has missing Git alternate objects; these hashes identify actual probe inputs, not a clean rebuild or installed-app source equivalence. Each candidate report pins its model/source/runtime metadata. Raw diagnostics remain private.
