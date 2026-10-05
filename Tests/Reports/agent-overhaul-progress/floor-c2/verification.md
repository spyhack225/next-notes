# PL-01 real-audio C2 instrument — 2026-10-05

The existing voice-latency floor modifier requires an explicit native answering candidate and authored WAV and joins exactly one completed native256-token answer to the same committed audio turn and consumer. It reports actual prompt/cache/new-token counters and separate raw-warm/cached-voice timing; cached eligibility requires positive prefix reuse and <=300 new tokens. No production token cap, sampler, prompt, role, endpoint or playback deadline changed.

COMMON has three focused selector failures; fixed controls pass unchanged. Usage26, owner isolation21files32defaults and voice delivery pass once. Missing inputs refuse before capture. Retained original accepted haiku completes42 native tokens and ignores the new modifier; fixed same-input voice flow rejects short output as no256-token sample. This is truthful instrument behavior, not a latency/quality improvement. Authored long-input qualification and exact final outcomes below.

Authored long WAV native qualification split into two committed turns and took frontend-control without a native answering pass; the existing required L2 stages and pin consumer assertion fail. Exit 1, fixed samples 0. Ten-turn run not admitted. Scope is native decode/TTFT and Pocket playback onset, not complete spoken playback or displayed feedback. Full C2/floor/default/quality gates stay open.

Bulk actual original/fixed logs and WAV provenance: ~/Library/Caches/NextNotesBuild/integration/pl01-c2-fixed256/.
