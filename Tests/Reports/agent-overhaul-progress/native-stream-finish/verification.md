# Native stream finish reason — 2026-10-06

The native stream producer supplied no finish reason, so usage recording treated token-budget exhaustion as a normal stop. NotesModelRuntime now reports its actual EOG/template stop versus exhausted budget; token output, budgets, cache reuse and cancellation are unchanged.

The same native MiniCPM fixture through LlamaLLMProvider → ModelPassRecorder → a fresh temporary UsageLog reader failed two assertions before the fix and passes afterward. At cap 2, identical `alpha bra` output and two completion tokens now persist `length`/truncated=true rather than `stop`/false. At cap 64, the complete phrase still records `stop`/false with 15 completion tokens and 39 reused prompt tokens. Each pass produces exactly one usage row.

Five focused/related flags pass: native-stream-finish, usage-log (26 cases), voice-latency instrumentation, toolloop-production and store-isolation (21 files/32 defaults unchanged). Joined test processes removed their temporary roots. Verified packaged binary SHA256: 5437ed4df6d0eb44720616d19c4fe9e326066ff2bdc829da45430d0ffe093aa7.

Raw original/fixed logs and metadata remain outside the repo at ~/Library/Caches/NextNotesBuild/integration/native-stream-finish-reason/. This fixes usage truthfulness; requested long voice answers, latency, thermal floor and overall roadmap acceptance remain open.
