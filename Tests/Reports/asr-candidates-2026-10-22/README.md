# ASR candidates — 22 October 2026

The Settings label repair is implemented in source. All requested model families ran locally in isolated runtime probes. New selectable application providers are **not implemented or installed** by this change. These measurements do not pass production dictation, meetings or voice acceptance.

## Measured comparison

Apple M3, 16 GB, macOS 27.2. Existing authored fixtures: English 60.585375 seconds / 136 normalized reference words; French 58.406875 seconds / 151 words. Three passes per supported language; the table uses the median of passes 2 and 3. RTFx means seconds of audio processed per second of execution. Sizes are decimal MB of the actual runtime artifact, not parameter counts.

| Runtime | Model MB | English RTFx | English WER | French RTFx | French WER |
|---|---:|---:|---:|---:|---:|
| Parakeet v3 (cached FluidAudio) | 483.3 | 247.1× | 4.41% | 210.7× | 9.93% |
| Whistle | 16.9 | 150.2× | 5.15% | 109.6× | 19.87% |
| Parakeet Redux (CoreML) | 220.3 | 102.0× | 5.15% | 86.2× | 12.58% |
| Parakeet Ultra (CoreML) | 632.2 | 256.1× | 4.41% | 204.2× | 9.93% |
| Phonon-2 (CoreML) | 345.0 | 466.0× | 0.74% | Unsupported | — |
| Qwen3-ASR 0.6B (4-bit MLX) | 712.8 | 31.6× | 0.74% | 24.6× | 9.27% |
| Qwen3-ASR 1.7B (4-bit MLX) | 1607.6 | 14.3× | 3.68% | 11.9× | 3.97% |
| Voz (CoreML CLI) | 336.7 | 375.3× | 3.68% | 334.2× | 11.92% |

**This is a smoke corpus, not a public leaderboard.** The English and French fixtures are short authored dialogues, and repeated passes repeat the same audio rather than adding independent quality samples. WER uses case-folded Unicode alphanumeric tokens; it does not normalize number spellings. A score may include formatting differences. Do not pick or promote a default from these eight rows.

The strongest English candidate on this fixture is Phonon-2 (1 edit / 136 words); Qwen 0.6B also has 1 edit but takes about 1.9 seconds warm versus Phonon’s 0.13 seconds. Qwen 1.7B gives the lowest French error here (6 / 151) but is the largest and slowest. Whistle is exceptionally small. Redux trades disk for slower execution and worse fixture scores than v3; Ultra costs more disk without a fixture quality gain. Voz is fast but its French result is worse than v3 here.

## Timing, memory and provenance limits

- The v3 baseline is an explicit CoreML probe linked against the existing cached FluidAudio objects, with the owner’s installed v3 asset files read in place. It is **not** a measurement of the installed app’s key-up delivery path. The cached checkout reports a Git HEAD, but Git status fails because its alternates object directory is missing. Object, module, source and model hashes are retained in `run-context.json`; a clean source/build equivalence claim remains open.
- CoreML v3/Redux/Ultra use the same cached decoder and .v3 architecture with explicitly loaded matching weights. The newer SDK’s typed .redux/.ultra integration is not present in the app. This proves the bounded runtime input/output, not the newer SDK’s complete pipeline.
- Phonon uses the pinned vendor native source package, default long-audio pipeline, CPU preprocessing, CoreML encoder and native decoder. Its compiled model is placed beside the downloaded model so it is deleted with the candidate. English only. No vendor source inference logic was changed.
- Qwen uses mlx-audio 0.6.1 with pinned 4-bit MLX snapshots and recorded Python dependency versions. Model loading/generation is offline. This is Python MLX runtime evidence, not Swift MLXAudioSTT integration or app shader-packaging acceptance.
- Voz uses release CLI 0.5.0 / desert-ant-core 4.1.0, model revision v0.4.0, a verified disposable cache, and a six-file single-process batch. Audio inference has network access denied with sandbox-exec. Its download/preparation step can contact the SDK license service; no audio was supplied to that step.
- Processing boundaries differ slightly: the Swift Phonon path includes file reading; other array probes read WAVs before timing. Voz reports its recognizer processingTime. None of these measurements includes polished-text cleanup/insertion, key-up tails, paced microphone capture, first audible response or a full-duplex workload.
- Cold observations: Whistle load 5 ms; cached v3 CoreML load 20.2 s; Redux 6.1 s; Ultra 11.6 s; Phonon explicit package compilation 0.78 s plus first ANE load 63.8 s; Qwen 0.6B load 1.87 s / 1.7B 2.15 s. Voz download/preparation 18.5 s includes network and is not a comparable model-load measurement. Paths and OS specialization caches differ; no cold-start ranking is justified.
- Lifetime process RSS: Whistle 167 MB, v3 489 MB, Redux 1,631 MB, Ultra 668 MB, Phonon 574 MB, Qwen 0.6B 934 MB, Qwen 1.7B 1,035 MB. These include load/compilation transients and are not steady-state resident weights or Mach physical footprint. Voz peak RSS was not instrumented.
- TTS work was coordinated to defer all native inference/builds during this window. Power state, per-run thermal traces, physical footprint and combined ASR/voice contention were not captured. A later thermal query reported no warning, which does not establish each run’s thermal state.

## Storage lifecycle

Only one new model candidate was downloaded at a time. Every runner takes the same nonblocking diagnostic lock, stages only the selected platform/artifact files, checks size and SHA-256 where supplied by the Hub, runs an owned child, saves the result, joins the child and deletes its exact temporary directory before another candidate starts. Qwen’s disposable interpreter environment and download cache were deleted too. The Phonon build, native library and compiled model were deleted together. Existing owner model assets, recordings and preferences were not deleted or migrated.

Initial disk headroom was roughly 143 MiB, so no model/build work began. After the owner freed space, small probes proceeded with per-candidate budgeting and reserve space, independently of the larger full-app compiler gate. Final available disk and owned cleanup receipts are in `cleanup.json`. OS-managed CoreML/ANE specialization caches may persist; they were not swept. The largest new model snapshot was Qwen 1.7B at about 1.608 GB. This is not a measured peak disk-use claim.

Important size differences: Whistle’s 16.9 MB runtime file is not its 220 MB training checkpoint. Redux’s Photon weights are 178 MB, while the tested CoreML runtime needs 220 MB. Phonon’s 164 MB CPU/MLX archive is different from the tested 345 MB CoreML artifact. Voz’s actual pinned Apple files total about 337 MB, versus its page’s 467 MB headline. Never download whole mixed-platform model repositories to benchmark these variants.

## Implementation path and remaining contracts

Reuse TranscriptionEngine, DictationController, the existing pause segmentation/key-up planner, compute scheduling, model library/downloader and usage records. Do not add a second capture pipeline, transcript store or product scheduler.

| Family | Application support path | Current application status |
|---|---|---|
| NVIDIA Parakeet v3 | Existing FluidAudio/CoreML path | Already supported; no duplicate NVIDIA checkpoint needed |
| Redux / Ultra | Extend the existing Parakeet backing to a pinned compatible FluidAudio release and explicit model identity | Runtime probes pass; provider selection/download/cache ownership pending |
| Phonon-2 | Vendor PhononCoreML package, actor-owned transcriber; reuse dictation segment handling | Runtime probe passes; English-only routing, partials/key-up and app integration pending |
| Whistle | Native Needle 3 speech API; keep its non-thread-safe/global state from affecting the existing tool-calling runtime | Native batch probe passes; streaming snapshots, cancellation and app integration pending |
| Qwen3-ASR | Reuse MLXAudioSTT from the MLX dependency already being added by the TTS work | Python MLX probes pass; native Swift loading, Metal library packaging and integration pending |
| Voz | Native Swift SDK with explicit local directory and current model identity | CLI probe passes; app adapter and SDK metadata/license policy integration pending |

Before exposing each provider: implement and verify the actual production call site; preserve stored .apple/.parakeet choices and existing defaults; show install size before downloading one selected variant; keep automatic warmup/comparison from fetching every engine. Existing diagnostic Compare mode is not a license to mass-download this matrix.

For dictation, require cumulative/revisable snapshots, stable-prefix semantics, accepted-PCM coverage at key-up, quiet final words, no hallucination on silence/noise, rapid consecutive holds and cancellation/quit joining. For meetings, preserve chunk timestamps and per-track capture coverage, final-pass cancellation, speaker/timing contracts and saved transcript identity. Do not imply dictation-provider selection changes meetings automatically.

For conversational voice, keep transcript ownership separate from EOU. Each adapter needs processed-through audio evidence and transcript finality, joined to session/turn/generation, before an independent turn detector can commit the last words. Preserve current Apple/Parakeet routing until its production tests pass. See the coordinated [voice turn detection roadmap](../../../roadmap/in-progress/VOICE-TURN-DETECTION/03-ASR-TTS-ALIGNMENT.md). No new provider was inserted into capture, playback or echo handling in this change.

Next validation must use a larger independently transcribed corpus (English/French, names/numbers, household/office/legal-operations/editing terminology, accents, low-volume tails, noise, interrupted speech and long calls), then actual M3 ASR+voice workloads. Run the existing relevant dictation, stream, meeting-final, voice-input producer, acoustic/duplex, cancellation, store-isolation and UI checks. The full app was neither rebuilt nor installed in this window.

## Evidence and reproduction

- `comparison.json` contains the compact numeric comparison; each named runtime JSON retains raw transcripts and all three trials.
- `artifact-metadata.json` contains official snapshot revisions and selected large-file metadata, collected without downloading checkpoints.
- `run-context.json` fingerprints the cached native objects/module and existing v3 assets and records provenance limits.
- `settings-validation.json`: original four source checks fail; corrected four pass. This is not a native UI assertion.
- `diagnostic-tests.txt`: seven external download/lock/scoring boundary cases; no model or application substitution claims.
- All benchmark helpers live in `Tools/`: `asr_benchmark.py` (Whistle/shared download/scoring), `asr_coreml_compare.py`, `asr_phonon_compare.py`, `asr_qwen_compare.py`, `asr_voz_compare.py`; native probe sources are retained.

Developer reproduction: build the bounded cached-object probe with `python3 Tools/build_asr_probe.py --record <new-build-record.json>`, then run exactly one comparison command, e.g. `python3 Tools/asr_coreml_compare.py --engine redux --output <new-report.json>`. Whistle/Phonon/Qwen/Voz tools take a new --output path; Qwen also takes --size 0.6b or 1.7b. All output paths must be new. Coordinate native workloads via agent-relay first. These are developer diagnostics, not user-facing setup steps.

## Official compatibility sources

- [NVIDIA Parakeet v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3): the model family already used by the app’s CoreML conversion.
- [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR), [MLX Audio Swift](https://github.com/Blaizzy/mlx-audio-swift): official model family and a native Swift runtime path.
- [Whistle](https://cactuscompute.com/blog/whistle), [native engine](https://github.com/cactus-compute/needle): small local speech model and speech C API.
- [Phonon-2](https://www.fermionresearch.com/models/phonon-2/), [Swift package](https://github.com/fermionresearch/phonon-coreml): distinct CPU/MLX and CoreML exports; English only.
- [Moondream Redux/Ultra](https://moondream.ai/blog/introducing-parakeet-redux-and-ultra), [FluidAudio Redux](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetRedux.md), [Ultra](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetUltra.md): matching model versions and CoreML variants.
- [Voz](https://desertant.com/models/voz/), [SDK](https://github.com/Desert-Ant-Labs/desert-ant-core), [CLI](https://github.com/Desert-Ant-Labs/desert-ant-cli): native Apple runtime, catalog pins and explicit cache support.
