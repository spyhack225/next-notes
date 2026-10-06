# Capture and healthy Stop diagnostic corrections — 2026-10-06

Capture's private test recorder counted overflow callbacks/largest batch while the real hub emits delta batches. Summing those deltas removes the dead largest-batch field. Original unchanged Stop scenario reported 15 rejected buffers but only 11 observed; fixed CAPTURE_OK.

Healthy Stop's test applied duration to an independently decoded, whole-second start date. It now checks the exact live producer boundary first and then encodes/decodes that boundary using the existing ISO8601 store codec. Original healthy Stop boundary assertion failed; fixed MEETING_HEALTH_OK (71 checks): 48,078 frames; live boundary 1791265629.284971; stored and codec boundary 1791265629.000000. Product capture, storage codec and original Stop flow are unchanged.

Store-isolation passes on the same bundle. Exact binary SHA256: 4c5f81a307c1edc32b61e34a50063cce42c2c6ff8521e46f16d65ca442fcc74d. Original logs: `~/Library/Caches/NextNotesBuild/integration/phase1-current-69115eb/core-remaining/`; fixed logs/results: `~/Library/Caches/NextNotesBuild/integration/voice-grounding-candidate-pin/`. Owned test temporary roots removed. Wake accuracy and broader CORE/roadmap gates remain open.
