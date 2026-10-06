# Native prefix retention on cancellation — 2026-10-05

`NotesModelRuntime` cleared valid native prompt KV when cancellation was checked between successfully decoded chunks or before generation. Its ledger recorded prompt tokens only after the complete prefill. The producer now records each successful chunk in the same ledger and preserves that exact ledger/context on `CancellationError`. Native decode failures still clear both halves; existing context reservation and prefix removal govern reuse. No new owner, gate, await, timer, model pass or output adoption is added.

Same actual private S1 interactive-stream fixture: original two failures (reused0 instead of128 after a partial prefill, reused0 instead of649 after complete prefill before sampling) → fixed native prefix-cache PASS. Both successor streams deliver answers; changed instruction controls still invalidate prior instructions. Existing prefix cases, chat-template, residency, concurrent-voice and owner-store isolation PASS. S1-mini is reused from its existing484,219,808byte local artifact, with no download. All task-owned TMP roots are removed after process joins; model claim released.

Fixed binary SHA `1f47f31271773eaba921c8d5783fb41cae36a436a6db4f735d1c7be0a9d053c5`; start load2.51, swap5.34GiB, free10.78GiB. Exact original/fixed logs, source patches and app metadata live outside iCloud at `~/Library/Caches/NextNotesBuild/integration/voice-prefix-cancellation/`.

This repairs lost cache work. It does not prove an end-to-end speed delta, incremental prefill while speaking, Apple voice latency, a default switch or PL12 completion. Last aggregate Qwen source847c1b7 quick10/10×3 and full28/30×2 remain historical measurements; current broader quality/voice/wake/floor/parent gates are open.
