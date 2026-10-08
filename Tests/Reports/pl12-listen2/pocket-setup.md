# Native latency harness Pocket setup

Original actual five-turn matched run returns `VOICE_LATENCY_FAILED`: every counted
turn lacks clause-to-PCM and PCM-to-audible. The harness selected Pocket but never
called its prepare entrance. The actual SpeechSynthesizer selects system speech
when Pocket is not ready, even under the engine override. This is a harness defect,
not evidence Pocket produced the original first-audio receipt.

The same flag/WAV/n=5, with only explicit Pocket prepare/ready admission before
measuring, returns `VOICE_LATENCY_OK`, with real native Pocket PCM and playback
marks on all five counted turns. Assets are reported found in cache. No Settings,
role, audio producer, model runtime or three voice producers changed. The startup
await is only isolated test setup, outside measured turns and production capture.

Corrected base seconds: L1 median/p95 .678/.683; L2 2.849/3.831; L3 3.001/4.426.
Both 200 ms median gates fail. Original unqualified figures remain in baselines.json;
its separate VAD endpoint/stall failures are retained, not repaired or suppressed.
The TTS setup is the only defect this change claims to fix.

Both builds are debug, no owner installation. This is native file-fed diagnostic
performance, not optimized release or physical microphone/ear acceptance. Original
and corrected binaries/three source hashes, raw logs and 1s resource samples are
retained in this directory. Apple service/children are excluded from app samples.
