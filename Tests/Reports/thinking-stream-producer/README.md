# Streaming output producer repair — 8 October 2026

The original streaming producer removed complete controls inside each decoded piece, then yielded the remaining body. It had no reasoning state, so `<think>PRIVATE</think>Answer` emitted `PRIVATEAnswer`; markers split across pieces also reached callbacks. The retained native MiniCPM vocabulary case reproduced `PRIVATEAnswer<function…` at this same producer.

`ChatTemplateStreamOutput` now owns that boundary in the actual `NotesModelRuntime.streamWhileScheduled` loop. It keeps only possible marker prefixes between pieces, discards text inside `<think>` blocks or Gemma thought channels, and stops at the family's turn end even when more text follows in the same piece. Nested/interleaved blocks stay hidden. Hidden bodies are discarded immediately. Ordinary pieces yield immediately; there is no extra await, queue, store, model pass, retry, sleep or downstream reply scrub. The old unused whole-output accumulator was removed.

The family marker list, prompts, generation budgets, sampler and defaults are unchanged. MiniCPM and Qwen tool envelopes are preserved. Plain Unicode, decomposed accents, emoji, punctuation, spaces and newlines are byte-identical in all seven family fixtures. An unfinished possible control prefix at end of stream is intentionally discarded rather than released as markup; an unfinished hidden body is never flushed. Non-special rendering retains its legacy incomplete terminator tail.

Gemma thought-channel handling follows [Google's control-token specification](https://ai.google.dev/gemma/docs/core/prompt-formatting-gemma4): `<|channel>thought…<channel|>` carries reasoning; `<|think|>` is a system switch, not an output-block opener.

## Original and fixed evidence

Before the repair, the old inline producer was mechanically moved into the shared output boundary without changing its decisions. The runtime's scheduled native loop and the scripted `AsyncThrowingStream` fixture both call that exact producer with their real yield callback. The fixture checks each callback and the joined stream without scrubbing either. Native MiniCPM tokenizer/piece rendering also supplies real vocabulary pieces to the producer. Sampling is substituted only in the scripted boundary fixture; native model generation of hidden thoughts was not run.

- RED: `CHAT_TEMPLATE_STREAM: 440 cases, 542 failures; decoded pieces -> producer callbacks -> completed stream`, then `CHAT_TEMPLATE_FAILED: 543 problem(s)` (exit 1). The additional failure is the native MiniCPM producer. Every failure was in the new stream/native-output cases; no old detection/rendering/delimiter case failed.
- GREEN: `CHAT_TEMPLATE_STREAM: 440 cases, 0 failures; decoded pieces -> producer callbacks -> completed stream`; native MiniCPM output case and existing checks passed.
- Byte-identical fixture SHA256 in both binaries: `2e8009db5d72670706f7e934a21eda9d9e74c22aeb86fb2fcac9aac19cd88dc4`.
- RED binary SHA256: `95d1bb9614a4990f0d6ab67a27b813f3246442101b8b168136afa9a2ab4b2b3a`.
- GREEN binary SHA256: `7a0f8f71b36f1abdd990543de5ab8f1c73617821b39f009d7829a7ae1d55873e`; UUID `402D9374-1981-3807-8A41-3C264900C53A`, ad hoc signature, unbundled Mach-O, Info.plist not bound.

The maintained fixture covers every marker split, every split in the thinking body/envelope, character-sized pieces, multiple/nested/interleaved blocks, stray closers, unfinished blocks/prefixes, stop tails, plain bytes and native tool envelopes. [red-source.patch](red-source.patch) replays the exact RED source on prerequisite `aae0a5c6` (the shared prerequisite original is `20d8f9b8b592b92acd01ab31d3f50978abb99103`). The fixture file did not change after RED. [red-summary.json](red-summary.json) and [green-summary.json](green-summary.json) retain binary/fixture pins, commands, exit codes and exact markers; adjacent diagnostic logs retain actual output.

## Required checks

| Flag | Exact final marker | Exit |
| --- | --- | --- |
| `--selftest-chat-template` | `CHAT_TEMPLATE_OK: 6 families detected and rendered; control tokens survive planner decode` | 0 |
| `--selftest-notes-truncation` | `NOTES_TRUNCATION_OK: a cut answer says so on the page, the single pass and the reduce each retry once at double the budget, the cap scales with the meeting, the wire finish reasons are read` | 0 |
| `--selftest-llm-prefix-cache` | `LLM_PREFIX_CACHE_OK: reused 646/666 tokens, prefill 1.38s → 0.18s; stable prompt front 90% (was 73% before P1-28)` | 0 |
| `--selftest-store-isolation` | `STORE_ISOLATION_OK: 21 files and 0 defaults unchanged` | 0 |

The prefix-cache flag ran **once**. Its native private S1-mini runtime exercises `streamConversation` and the scheduled stream call site, prefix reuse and existing interruption controls. These timings are functional test observations, not an ASR/voice latency acceptance or a model comparison.

Store isolation enumerates `UserDefaults.standard` in this direct scratch-executable invocation and observed **zero watched defaults**. Its real marker is not the historical 32-default result. It compared 21 file signatures, including absence/unreadability values; this does not establish installed owner-domain preference coverage. No owner preferences were inspected or seeded to increase the count, and no owner-store migration was performed.

## Build and coordination

Machine: Apple M3, 16 GiB, macOS 27.2 `26B5091g`, arm64; Apple Swift 6.4 (`swiftlang-6.4.0.34.1`, clang `2100.3.34.1`). Debug builds and all native tests went through `RELAY_ID=claude2-thinking-review ../heavy.sh`, using only `wt-scratch/thinking-review`. The wrapper waited for foreign work/claims and, after its shared update, the FIFO queue. No admission threshold was relaxed. Waiting was not a test result.

The first build failed at the inherited `TaskAuthoritySelfTest.swift:372` missing `AgentTaskStore.recoveredReadHistory`. At the orchestrator's direction, the exact shared listen2 prerequisite was cherry-picked as `aae0a5c6`; its canonical method was verified byte-identical. It is a separate prerequisite, not a second task-store repair. Corrected RED build passed in 331.73s; GREEN build passed in 257.57s. These are build durations, not product measurements.

Build commands were `make webrtc-audio && swift build -c debug -j 2 --scratch-path <owned scratch>`, then the corrected RED `swift build`, and GREEN `swift build … && python3 Tests/Reports/thinking-stream-producer/run-checks.py green`. RED used the same runner with `red`. Each test used a private temporary root, removed after its process exited. Full build logs are retained compressed without changing bytes. No app was installed, opened through the GUI, pushed or merged.

Disk fell below the 10 GiB gate while peers built. [cache-cleanup.json](cache-cleanup.json) records exact owned, unheld scratch targets removed, allocated bytes, measured available space and unchanged RED executable/framework hashes. Only own optional indexes/SDK cache/copied debug symbols and own compile intermediates were retired. Independent peer cleanup changed global available space too; no global gain is attributed to this task. The fixed build regenerated its needed intermediates. The remaining owned scratch was removed after final binary-hash verification and a no-holder check, as RULES-2 requires; [final-cleanup.json](final-cleanup.json) retains the exact result.

## Scope and integration

Feature code changes: `Formatting/LLM/ChatTemplate.swift`, `Formatting/LLM/NotesModelRuntime.swift`, and the maintained `ChatTemplateSelfTest.swift`. Shared prerequisite: `Agent/Tasks/AgentTaskStore.swift` only. `NotesModelRuntime.swift` **will conflict with uncommitted work** per `MAIN-DIRTY-SOURCES.txt`; merge the bounded producer/callback hunk manually. The shared task-store prerequisite also overlaps canonical uncommitted work and is the same canonical function; do not duplicate it.

No thinking-per-role policy, model promotion, sampler repair or extra model pass is delivered. Physical voice playback/full duplex, live model reasoning occurrence, non-streaming literal-thinking output, broad notes factual quality and inherited aggregate quality gates were not accepted by these checks. There is no model/default or roadmap-phase promotion.
