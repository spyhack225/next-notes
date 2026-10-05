# Explicit voice answer-model measurement — 2026-10-05

The voice latency instrument always answered through Apple Foundation Models, even when an explicit local file was supplied. Its joined turn therefore could not qualify that file for PL-01/02. The exact self-test now accepts one validated local answering model through the existing split-answer producer. Apple routing, input, endpoint, speech delivery and the same owned generation task remain in place. Normal app selection is unchanged; no role/default/library choice is saved.

Original actual-owner guards fail six assertions -> same guards PASS. Same authored WAV and actual capture/endpoint/Pocket/usage consumer: original ignores MiniCPM pin and records Apple; fixed committed turn and completed native answer both name MiniCPM5-2B-Q4_K_M, with measured positive token counts. Existing native runtime reservation remains responsible for inference ownership; the Apple route releases its scheduler job before llama acquires its lane. No second runtime/store/audio path or conversational wait is added. A delivery-task drain is not claimed as native kernel cessation.

One warm-up plus one measured turn verifies identity, stages and playback acknowledgement only. Original Apple L1/L2/L3: 0.734/2.592/2.847 s. Pinned Mini: 0.759/2.882/3.213 s; native answer TTFT 1857 ms, decode 46.250 tok/s over 74 tokens. Default Apple control remains functional (0.669/3.173/3.417 s). These are separate one-turn observations, not a speed improvement, fixed-256-token C2 benchmark or latency acceptance. L1/L2 <200 ms, first-audio budget and full C1/C2 floor remain open.

Voice delivery, voice routing, usage log and owner isolation pass once. Five native invalid selections (cloud, missing file, duplicate, flag-valued argument, unsupported sampler modifier) refuse before capture, with no fallback. Original/common native consumer assertions are identical across comparison; legitimate provisional history is retained and the actual committed consumer must match the pin.

Evidence: `~/Library/Caches/NextNotesBuild/integration/pl01-voice-candidate-pinning/`. Bulk original/fixed/default logs stay outside iCloud.
