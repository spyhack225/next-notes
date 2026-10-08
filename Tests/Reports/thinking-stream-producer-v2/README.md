# Visible EOF-tail correction — fixture V2

Independent [review](REVIEW.md) rejected producer commit `8e4243d6837737f1c2c23b18399237dcf0dff214`: its `finish` discarded every possible marker prefix when special rendering was enabled, even with neither hidden depth active. EOF rules out completing the marker, so that tail is visible text. `Answer<thi` must remain `Answer<thi`; pieces `2 ` and `<` must remain `2 <`.

## Why the earlier GREEN missed it

V1's `truncated-opening` expected `Answer` from `Answer<thi`, wrongly requiring the deletion. The original RED log actually reports `“Answer<thi”, expected “Answer”` at line 633. The producer then implemented that wrong expectation. Fixture hash invariance proves that RED/GREEN used the same oracle; it does not prove that oracle was correct. Joined-output checks also did not pin how soon callbacks released a disproved prefix, and every scripted case enabled special rendering. Those gaps are addressed explicitly in V2.

The original [V1 source](ChatTemplateSelfTest-v1.swift.fixture) is frozen at SHA256 `2e8009db5d72670706f7e934a21eda9d9e74c22aeb86fb2fcac9aac19cd88dc4`; historical logs and patches in [the prior report](../thinking-stream-producer/README.md) are retained unchanged. [RESULT-v1.md](RESULT-v1.md) retains the previous result. V2 explicitly changes the wrong expectation and adds new assertions. [V2 source](ChatTemplateSelfTest-v2.swift.fixture) is frozen at SHA256 `bbd42ce79c68ca516014f5eba82bc6a4006d2594ee8ad78a8f97a7cb71544d49`; the runner checks its bytes against the maintained source before each phase.

## Repair and assertions

The existing producer's `finish` must yield pending text when not stopped and neither think nor channel depth is active. Unclosed hidden bodies/prefixes and completed turn-end tails stay discarded. No role, sampler, prompt, budget, default, await, scheduler, store, queue or model pass needs to change.

V2 retains every V1 case, with that one explicitly corrected expectation, and adds lone `<`, `2 <`, every proper incomplete family-control prefix at EOF, special-rendering-OFF tails/terminators/literal thinking, and unclosed think/channel prefixes. Synchronous producer checks pin joined progress after each piece: `["A<", "x", "B"]` gives `A`, then `A<x`, then `A<xB`; `["A<"]` gives `A` before EOF and exactly one `<` callback at EOF. Lone `<` releases at EOF too. Repeated finish emits nothing extra, hidden unclosed tails emit nothing, and no text after a completed terminator is released.

The async cases consume `NotesModelRuntime.streamPiecesForTesting`'s actual `AsyncThrowingStream`; synchronous progress cases call the same `ChatTemplateStreamOutput` used by `streamWhileScheduled`. Sampling is substituted for these scripted inputs. Native vocabulary/control cases are retained, and the requested prefix-cache flag exercises the scheduled native call site. This does not prove that a live model generated these exact hidden/EOF inputs or that physical voice playback/full duplex passed.

[The UTF-8 source finding](utf8-boundary.md) documents the actual native boundary. The producer accepts `String`, not raw byte fragments. `LlamaHelpers.piece` independently decodes each token at line 59; it cannot reconstruct a scalar split between token byte buffers. Complete Swift-string Unicode preservation is covered; native split-byte scalar preservation is an inherited upstream limitation, not a pass claimed by this repair.

## Verification

RED is confirmed: `CHAT_TEMPLATE_STREAM: 658 cases, 201 failures; decoded pieces -> producer callbacks -> completed stream`, final `CHAT_TEMPLATE_FAILED: 201 problem(s)` (exit 1). The producer was byte-identical to `8e4243d6`. Only visible EOF-prefix/release assertions fail; V1's prior retained cases, progress timing, hidden/stopped negatives and rendering-OFF cases pass. [red-summary.json](red-summary.json) pins source/fixture/binary and the exact verdict. The cold RED build completed in 381.35s.

GREEN: `CHAT_TEMPLATE_STREAM: 658 cases, 0 failures; decoded pieces -> producer callbacks -> completed stream`, final `CHAT_TEMPLATE_OK: 6 families detected and rendered; control tokens survive planner decode` (exit 0). [green-summary.json](green-summary.json) verifies the same fixture hash and pins the fixed producer and binary. Native S1-mini/MiniCPM vocabulary cases were not skipped. Debug GREEN build completed in 362.87s. These are compile durations and functional cache observations, not app latency or ASR/voice acceptance.

Both builds and all tests used `RELAY_ID=claude2-thinking-review ../heavy.sh`, the shared FIFO and unchanged resource gates. The GREEN slot was held at the normal 10 GB disk gate before recovering; held time is not a test verdict. GREEN's build and the following flags ran serially in **one** admitted slot; each flag was invoked once, including prefix-cache.

| Flag | Exact final marker | Exit |
| --- | --- | --- |
| `--selftest-chat-template` | `CHAT_TEMPLATE_OK: 6 families detected and rendered; control tokens survive planner decode` | 0 |
| `--selftest-notes-truncation` | `NOTES_TRUNCATION_OK: a cut answer says so on the page, the single pass and the reduce each retry once at double the budget, the cap scales with the meeting, the wire finish reasons are read` | 0 |
| `--selftest-llm-prefix-cache` | `LLM_PREFIX_CACHE_OK: reused 646/666 tokens, prefill 2.00s → 0.37s; stable prompt front 90% (was 73% before P1-28)` | 0 |
| `--selftest-store-isolation` | `STORE_ISOLATION_OK: 21 files and 0 defaults unchanged` | 0 |

Store-isolation also prints `TOOLLOOP_PRODUCTION_FAILED` with 18 `TOOLLOOP_PRODUCTION_WRONG` browser-fixture diagnostics. Those same 18 were retained in the earlier run. The existing StoreIsolationSelfTest invokes the production tool-loop fixture without the required browser fixture admission flag; that inherited test-wiring failure remains outside this correction. The final isolation marker establishes its own 21-file/0-observed-default comparison, not nested tool-loop success or installed owner-domain preference coverage. Both the embedded failure and final OK marker are retained in logs/summaries; no test was weakened.

## Artifact and integration record

RED binary SHA256: `8f065d5e20c72b04020bdb30f22ff2994386deada4f1e8b3ba70384ea21d4444`.
GREEN binary SHA256: `56643ae8b74bffb57862c3a3ee1bba83ad3313bdd7b548b13b5f15ea531ac7ba`; UUID `8ECCEE69-F2F4-3D89-8EA1-AF0FFBE8C129`, ad hoc signature, unbundled Mach-O. Source/binary/fixture pins, signatures, exact commands and machine metadata are retained in source-pins, summaries and analysis JSON. Full run/build logs are compressed losslessly. The original prerequisite `aae0a5c6` / shared `20d8f9b8` remains unchanged.

[cache-cleanup.json](cache-cleanup.json) records only owned unused caches/compile intermediates retired after RED, a no-holder check, unchanged RED executable/framework hashes and global available-space samples. [final-cleanup.json](final-cleanup.json) records exact final owned scratch removal after GREEN binary-hash/no-holder checks. No foreign artifact/process or owner data was cleaned. Runner-owned temporary roots were removed by `TemporaryDirectory` after each child exited.

This correction changes `ChatTemplate.swift`, `ChatTemplateSelfTest.swift`, evidence/docs and the shared standard only. No `NotesModelRuntime` or task-store change is made by this correction. Earlier branch hunks in `NotesModelRuntime.swift` and `AgentTaskStore.swift` **will conflict with uncommitted work**, confirmed by the supplied dirty-source list and a read-only canonical status check. Merge the runtime hunk manually and reuse the exact shared prerequisite. No such dirty file was reported for this correction's two source files at that check.

No install, GUI opening, push, merge, canonical checkout writes, owner-store migration/seeding, new role, sampler/default change or native-test repeat. Physical voice/full duplex, live hidden-generation frequency, hidden-block error/cancellation replay, measured allocations/latency, non-streaming reasoning and inherited aggregate quality remain unverified by this bounded repair. The native byte-fragment decoder limit remains explicitly open; no model/default or phase is promoted.
