# Benchmark results

One catalog for model comparisons and complete workflows. Original evidence stays at its linked path.

[How to save a result](FORMAT.md) · [All evidence](EVIDENCE.md) · [Branch/worktree audit](inventory/README.md) · [Website](https://next-notes.com/?page=benchmarks)

Status describes the stated scope only. A measured component is not production acceptance. Targets are not results; missing measurements stay missing.

| Date | Area | Benchmark | Status | Result and limits |
|---|---|---|---|---|
| 2026-10-22 | tts | [Qwen3-TTS0.6B4bit: quiet-room speaker-output attempt](runs/2026-10-22-tts-qwen-speaker-quiet.json) | failed | No completed native-format trial: Disk guard stopped the owned process group before cleanup. No acoustic median or fastest-default decision accepted; all attempts and refusals remain retained. |
| 2026-10-22 | tts | [Qwen3-TTS0.6B4bit: native speaker-output experiment](runs/2026-10-22-tts-qwen-speaker-output.json) | partial | 1/3 warm pickups qualified. No acoustic median or fastest-default decision accepted. Background audio was present; all attempts and refusals remain retained. |
| 2026-10-22 | tts | [Qwen3-TTS-0.6B-CustomVoice-4bit@08c72cad5e2fd0f41730c8bd1f28149585e46361: native first generated audio](runs/2026-10-22-tts-qwen-native.json) | measured | Warm median 2709.30 ms across 5 back-to-back runs; first synthesis after preparation 3093.75 ms. Result saved, child joined and owned model removed. |
| 2026-10-22 | tts | [Pocket: quiet-room speaker-output attempt](runs/2026-10-22-tts-pocket-speaker-quiet.json) | measured | 30/30 warm pickups qualified. Complete threshold-qualified microphone median accepted for this route/workload; default promotion remains a separate contract. |
| 2026-10-22 | tts | [Pocket: native speaker-output experiment](runs/2026-10-22-tts-pocket-speaker-output.json) | partial | 27/30 warm pickups qualified. No acoustic median or fastest-default decision accepted. Background audio was present; all attempts and refusals remain retained. |
| 2026-10-22 | tts | [FluidAudio/PocketTTS-int8/alba: native first generated audio](runs/2026-10-22-tts-pocket-native.json) | measured | Warm median 59.00 ms across 5 back-to-back runs; first synthesis after preparation 1096.68 ms. Result saved, child joined and owned model removed. |
| 2026-10-22 | tts | [Phonon31m: quiet-room speaker-output attempt](runs/2026-10-22-tts-phonon-speaker-quiet.json) | partial | 19/30 warm pickups qualified. No acoustic median or fastest-default decision accepted; all attempts and refusals remain retained. |
| 2026-10-22 | tts | [Phonon31m: native speaker-output experiment](runs/2026-10-22-tts-phonon-speaker-output.json) | blocked | No native-format trial started: disk admission refused. No acoustic median or fastest-default decision accepted. Background audio was present; all attempts and refusals remain retained. |
| 2026-10-22 | tts | [Phonon31m-CoreML/v0.4.0: native first generated audio](runs/2026-10-22-tts-phonon-native.json) | measured | Warm median 7.80 ms across 5 back-to-back runs; first synthesis after preparation 8.32 ms. Result saved, child joined and owned model removed. |
| 2026-10-22 | tts | [Five native TTS generation results; speaker timing pending](runs/2026-10-22-tts-native.json) | partial | All five generation results are saved individually. Speaker output and ASR-plus-voice qualification remain pending; no fastest-audible default has been selected. |
| 2026-10-22 | tts | [Kokoro: quiet-room speaker-output attempt](runs/2026-10-22-tts-kokoro-speaker-quiet.json) | partial | 18/30 warm pickups qualified. No acoustic median or fastest-default decision accepted; all attempts and refusals remain retained. |
| 2026-10-22 | tts | [Kokoro: native speaker-output experiment](runs/2026-10-22-tts-kokoro-speaker-output.json) | partial | 26/30 warm pickups qualified. No acoustic median or fastest-default decision accepted. Background audio was present; all attempts and refusals remain retained. |
| 2026-10-22 | tts | [FluidAudio/Kokoro82M/af_heart: native first generated audio](runs/2026-10-22-tts-kokoro-native.json) | measured | Warm median 224.11 ms across 5 back-to-back runs; first synthesis after preparation 904.19 ms. Result saved, child joined and owned model removed. |
| 2026-10-22 | tts | [macOS: quiet-room speaker-output attempt](runs/2026-10-22-tts-apple-speaker-quiet.json) | partial | 29/30 warm pickups qualified. No acoustic median or fastest-default decision accepted; all attempts and refusals remain retained. |
| 2026-10-22 | tts | [macOS: native speaker-output experiment](runs/2026-10-22-tts-apple-speaker-output.json) | partial | 28/30 warm pickups qualified. No acoustic median or fastest-default decision accepted. Background audio was present; all attempts and refusals remain retained. |
| 2026-10-22 | tts | [macOS voice: physical speaker-to-microphone calibration](runs/2026-10-22-tts-apple-speaker-calibration.json) | partial | Original collector returned1247ms then299ms microphone pickup. Later loaded tests exposed converted-buffer host-window regressions; these historical values are not current qualified speaker timing or default evidence. |
| 2026-10-22 | tts | [AVSpeechSynthesizer/system-default: native first generated audio](runs/2026-10-22-tts-apple-native.json) | measured | Warm median 8.98 ms across 5 back-to-back runs; first synthesis after preparation 1039.27 ms. Result saved, child joined and owned model removed. |
| 2026-10-22 | asr | [Whistle](runs/2026-10-22-asr-whistle.json) | measured | English 150.2× throughput, 5.15% word error. App provider acceptance remains open. |
| 2026-10-22 | asr | [Voz (CoreML CLI)](runs/2026-10-22-asr-voz.json) | measured | English 375.3× throughput, 3.68% word error. App provider acceptance remains open. |
| 2026-10-22 | asr | [Parakeet Ultra (CoreML)](runs/2026-10-22-asr-ultra.json) | measured | English 256.1× throughput, 4.41% word error. App provider acceptance remains open. |
| 2026-10-22 | asr | [Whistle signed-app live ASR](runs/2026-10-22-asr-signed-app-whistle.json) | measured | Three warmed holds per supported language; each model downloaded, tested, unloaded and removed before the next. English-only Phonon; English and French for the others. |
| 2026-10-22 | asr | [Voz signed-app live ASR](runs/2026-10-22-asr-signed-app-voz.json) | measured | Three warmed holds per supported language; each model downloaded, tested, unloaded and removed before the next. English-only Phonon; English and French for the others. |
| 2026-10-22 | asr | [Parakeet Ultra signed-app live ASR](runs/2026-10-22-asr-signed-app-ultra.json) | measured | Three warmed holds per supported language; each model downloaded, tested, unloaded and removed before the next. English-only Phonon; English and French for the others. |
| 2026-10-22 | asr | [Parakeet Redux signed-app live ASR](runs/2026-10-22-asr-signed-app-redux.json) | measured | Three warmed holds per supported language; each model downloaded, tested, unloaded and removed before the next. English-only Phonon; English and French for the others. |
| 2026-10-22 | asr | [Qwen3-ASR 1.7B signed-app live ASR](runs/2026-10-22-asr-signed-app-qwen-17b.json) | measured | Three warmed holds per supported language; each model downloaded, tested, unloaded and removed before the next. English-only Phonon; English and French for the others. |
| 2026-10-22 | asr | [Qwen3-ASR 0.6B signed-app live ASR](runs/2026-10-22-asr-signed-app-qwen-06b.json) | measured | Three warmed holds per supported language; each model downloaded, tested, unloaded and removed before the next. English-only Phonon; English and French for the others. |
| 2026-10-22 | asr | [Phonon-2 signed-app live ASR](runs/2026-10-22-asr-signed-app-phonon.json) | measured | Three warmed holds per supported language; each model downloaded, tested, unloaded and removed before the next. English-only Phonon; English and French for the others. |
| 2026-10-22 | asr | [Parakeet v3 signed-app live ASR](runs/2026-10-22-asr-signed-app-parakeet.json) | measured | Three warmed holds per supported language; each model downloaded, tested, unloaded and removed before the next. English-only Phonon; English and French for the others. |
| 2026-10-22 | asr | [Parakeet Redux (CoreML)](runs/2026-10-22-asr-redux.json) | measured | English 102.0× throughput, 5.15% word error. App provider acceptance remains open. |
| 2026-10-22 | asr | [Qwen3-ASR 1.7B (4-bit MLX)](runs/2026-10-22-asr-qwen-17b.json) | measured | English 14.3× throughput, 3.68% word error. App provider acceptance remains open. |
| 2026-10-22 | asr | [Qwen3-ASR 0.6B (4-bit MLX)](runs/2026-10-22-asr-qwen-06b.json) | measured | English 31.6× throughput, 0.74% word error. App provider acceptance remains open. |
| 2026-10-22 | asr | [Phonon-2 (CoreML)](runs/2026-10-22-asr-phonon.json) | measured | English 466.0× throughput, 0.74% word error. App provider acceptance remains open. |
| 2026-10-22 | asr | [Parakeet v3 (cached FluidAudio)](runs/2026-10-22-asr-parakeet-v3-runtime.json) | measured | English 247.1× throughput, 4.41% word error. App provider acceptance remains open. |
| 2026-10-22 | asr | [Whistle paced ASR latency](runs/2026-10-22-asr-paced-whistle.json) | partial | Six authored short holds completed under machine pressure; no default promotion. |
| 2026-10-22 | asr | [Voz (CoreML CLI) paced ASR latency](runs/2026-10-22-asr-paced-voz.json) | blocked | Not started: insufficient internal storage after pressure incident; model not downloaded. |
| 2026-10-22 | asr | [Parakeet Ultra (CoreML) paced ASR latency](runs/2026-10-22-asr-paced-ultra.json) | blocked | Not started: insufficient internal storage after pressure incident; model not downloaded. |
| 2026-10-22 | asr | [Whistle resumed paced ASR latency](runs/2026-10-22-asr-paced-resumed-whistle.json) | measured | Three warmed paced trials per language; quiet serial candidate window, no app/default promotion. |
| 2026-10-22 | asr | [Voz (CoreML CLI) resumed paced ASR latency](runs/2026-10-22-asr-paced-resumed-voz.json) | measured | Three warmed paced trials per language; quiet serial candidate window, no app/default promotion. |
| 2026-10-22 | asr | [Parakeet Ultra resumed paced ASR latency](runs/2026-10-22-asr-paced-resumed-ultra.json) | measured | Three warmed paced trials per language; quiet serial candidate window, no app/default promotion. |
| 2026-10-22 | asr | [Parakeet Redux resumed paced ASR latency](runs/2026-10-22-asr-paced-resumed-redux.json) | measured | Three warmed paced trials per language; quiet serial candidate window, no app/default promotion. |
| 2026-10-22 | asr | [Qwen3-ASR 1.7B (4-bit MLX) resumed paced ASR latency](runs/2026-10-22-asr-paced-resumed-qwen-17b.json) | measured | Three warmed paced trials per language; quiet serial candidate window, no app/default promotion. |
| 2026-10-22 | asr | [Qwen3-ASR 0.6B 4-bit resumed paced ASR latency](runs/2026-10-22-asr-paced-resumed-qwen-06b.json) | measured | Three warmed paced trials per language; quiet serial candidate window, no app/default promotion. |
| 2026-10-22 | asr | [Phonon-2 (CoreML) resumed paced ASR latency](runs/2026-10-22-asr-paced-resumed-phonon.json) | measured | Three warmed paced trials per language; quiet serial candidate window, no app/default promotion. |
| 2026-10-22 | asr | [Parakeet v3 resumed paced ASR latency](runs/2026-10-22-asr-paced-resumed-parakeet-v3.json) | measured | Three warmed paced trials per language; quiet serial candidate window, no app/default promotion. |
| 2026-10-22 | asr | [Parakeet Redux (CoreML) paced ASR latency](runs/2026-10-22-asr-paced-redux.json) | blocked | Not started: insufficient internal storage after pressure incident; model not downloaded. |
| 2026-10-22 | asr | [Qwen3-ASR 1.7B (4-bit MLX) paced ASR latency](runs/2026-10-22-asr-paced-qwen-17b.json) | blocked | Not started: insufficient internal storage after pressure incident; model not downloaded. |
| 2026-10-22 | asr | [Qwen3-ASR 0.6B (4-bit MLX) paced ASR latency](runs/2026-10-22-asr-paced-qwen-06b.json) | blocked | Not started: insufficient internal storage after pressure incident; model not downloaded. |
| 2026-10-22 | asr | [Phonon-2 (CoreML) paced ASR latency](runs/2026-10-22-asr-paced-phonon.json) | blocked | Not started: insufficient internal storage after pressure incident; model not downloaded. |
| 2026-10-22 | asr | [Parakeet v3 (cached FluidAudio) paced ASR latency](runs/2026-10-22-asr-paced-parakeet-v3.json) | blocked | Cached model short-prefix warmup aborted during disk/swap pressure; no timing accepted. |
| 2026-10-22 | asr | [Paced speech recognition in the signed app](runs/2026-10-22-asr-live-pending.json) | partial | All eight signed-app model cases passed across 45 warmed paced holds. Live text, committed text and release-final clocks are reported separately. |
| 2026-10-22 | models | [Archived runtime producer integration](runs/2026-10-22-archived-runtime-integration.json) | partial | Optimized build and11native rootflags pass: Google402assertions, stream658/0, notes, scriptedclock2/2 andonce-onlynativeprefixcache646/666tokensreused. Owner21files/89preferencekeys/modelhashunchanged. Inherited18nestedbrowserfailures remainopen. |
| 2026-10-13 | meetings | [Whole meeting pipeline baseline](runs/2026-10-13-meeting-full-pipeline.json) | partial | 21 scoped checks pass; saved audio coverage, hardware routes and semantic acceptance remain open. |
| 2026-10-08 | voice | [Voice response latency audit](runs/2026-10-08-voice-latency.json) | partial | First-audio median improved from 3.78 s to 2.65 s; 0.9 s target remains unmet. |
| 2026-10-08 | agent | [Agent quality, voice and model workload audit](runs/2026-10-08-agent-acceptance.json) | partial | Quick 9–10/10; full 25/30 and 23/30; owner 8/9. Full acceptance remains open. |
| 2026-10-07 | dictation | [Dictation release-to-delivery investigation](runs/2026-10-07-dictation-latency.json) | partial | Cleanup dominates retained slow turns; final polished delivery target remains open. |
| 2026-10-06 | models | [MiniCPM5-2B decode with ASR overlapping](runs/2026-10-06-minicpm-asr-overlap-decode.json) | measured | 42.20 tokens/s median over 96 rounds and 604.28 s with ASR overlap. Combined voice remains unqualified. |
| 2026-10-01 | workflows | [Durable tasks and workflow checks](runs/2026-10-01-workflow-durability.json) | partial | Bounded regression evidence exists; broad recovery, retry and remote authority remain separate contracts. |
| 2026-09-30 | dictation | [Qwen3.5-4B Q4_K_M](runs/2026-09-30-cleanup-qwen35.json) | measured | 11/42 failed assertions; 8.58 s median cleanup. Historical tested configuration. |
| 2026-09-30 | dictation | [Qwen3-4B Instruct 2507 Q4_K_M](runs/2026-09-30-cleanup-qwen3.json) | measured | 8/42 failed assertions; 1.61 s median cleanup. Historical tested configuration. |
| 2026-09-30 | dictation | [MiniCPM5-2B Q4_K_M](runs/2026-09-30-cleanup-minicpm5.json) | measured | 3/42 failed assertions; 0.59 s median cleanup. Historical tested configuration. |
| 2026-09-30 | dictation | [Gemma 4 E4B Q4_K_M variability](runs/2026-09-30-cleanup-gemma.json) | partial | 3–11 failed assertions; 2.62–8.51 s median across retained conditions. No single ranking. |
| 2026-09-30 | dictation | [Apple Foundation Models grammar](runs/2026-09-30-cleanup-apple.json) | measured | 0/42 failed assertions; 3.03 s median cleanup. Historical tested configuration. |
| 2026-09-23 | models | [Needle resident server](runs/2026-09-23-decision-needle-serve.json) | measured | 73.2% exact-tool accuracy; 277.0 ms median decision latency on 112 fixtures. |
| 2026-09-23 | models | [Needle per-proposal process](runs/2026-09-23-decision-needle.json) | measured | 73.2% exact-tool accuracy; 994.7 ms median decision latency on 112 fixtures. |
| 2026-09-23 | models | [Laya typed decisions](runs/2026-09-23-decision-laya-typed-decisions.json) | measured | 74.1% exact-tool accuracy; 462.3 ms median decision latency on 112 fixtures. |
| 2026-09-23 | models | [Laya multilingual](runs/2026-09-23-decision-laya-multilingual.json) | measured | 69.6% exact-tool accuracy; 89.3 ms median decision latency on 112 fixtures. |
| 2026-09-23 | models | [Decision model comparison](runs/2026-09-23-decision-gate.json) | measured | Historical measured candidate results and separately labelled published-only candidates retained. |
| 2026-09-13 | tts | [Piper 1.8.0 / lessac medium](runs/2026-09-13-tts-piper.json) | measured | Historical warm first generated PCM range 98–109 ms; actual playback unmeasured. |
| 2026-09-13 | tts | [Kokoro ONNX v1.0 / af_sarah](runs/2026-09-13-tts-kokoro.json) | measured | Historical warm first generated PCM range 3200–3400 ms; actual playback unmeasured. |
| 2026-09-13 | tts | [Apple short-response synthesis](runs/2026-09-13-tts-apple.json) | measured | 201.8 ms warm median first generated PCM; 450.3 ms first trial. |

## Evidence by area

- [Asr](inventory/asr.md): 157 evidence files.
- [Dictation](inventory/dictation.md): 560 evidence files.
- [Meetings](inventory/meetings.md): 1143 evidence files.
- [Agent](inventory/agent.md): 477 evidence files.
- [Voice](inventory/voice.md): 321 evidence files.
- [Tts](inventory/tts.md): 210 evidence files.
- [Workflows](inventory/workflows.md): 176 evidence files.
- [Models](inventory/models.md): 20 evidence files.
- [Other](inventory/other.md): 744 evidence files.

## Operating rules

- Keep cold, warm, load, generated PCM, audible output and complete delivery separate.
- Compare only matching fixtures, metric boundaries, hardware, workload and grading rules.
- Keep failures, partial coverage, blocked runs and unrun checks visible.
- New models run one at a time: save, exit/unload, delete owned temporary assets, then continue.
- Website summaries require explicit publication review. Owner audio, transcripts and raw outputs stay private.
- No benchmark runs on app startup, dictation, meeting capture or voice paths.
