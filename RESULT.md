Visible EOF-tail repair committed: 0be933e6f08e83248ef16d9360d2585ef599b0c3. This result/evidence-packaging commit follows it.
Rejected original producer: 8e4243d6837737f1c2c23b18399237dcf0dff214. Earlier report: 98700836. Unchanged shared prerequisite: aae0a5c6, the exact canonical/shared 20d8f9b8 recoveredReadHistory method.

Confirmed cause: ChatTemplateStreamOutput.finish used renderSpecial to discard every pending marker prefix. It deleted ordinary unfinished prefixes outside hidden blocks. The producer now flushes pending text when not stopped and neither think nor channel depth is active. It still discards unclosed hidden tails and text after completed turn terminators. No consumer sanitizer, retry, new role, sampler/default, await, timer, store, queue or model pass was added.

The earlier GREEN missed this because V1 explicitly expected Answer from Answer<thi. The earlier RED log actually reported the correct tail as a failure (line 633). Frozen-fixture invariance proved the same oracle was used, not that the oracle was correct. This correction explicitly reverses that wrong expectation in the test and producer commit message. V1 remains byte-identical at SHA256 2e8009db5d72670706f7e934a21eda9d9e74c22aeb86fb2fcac9aac19cd88dc4. New frozen V2 SHA256 is bbd42ce79c68ca516014f5eba82bc6a4006d2594ee8ad78a8f97a7cb71544d49, identical for RED and GREEN. The previous result, logs and patches remain evidence, and the old report is explicitly marked superseded.

V2 adds lone < at EOF, 2 <, all 196 proper family-control prefixes at EOF, callback-position checks for [A<, x, B] → A / A<x / A<xB and [A<] → A then exactly one < at EOF, unclosed think/channel tails, stopped tails, repeated finish and special-rendering-OFF cases. Existing cases remain with that one explicitly corrected expectation. The async stream consumer receives the same producer output; synchronous checks pin callback positions on the producer used by the scheduled native loop.

RED against the byte-identical 8e4243d6 producer:
CHAT_TEMPLATE_STREAM: 658 cases, 201 failures; decoded pieces -> producer callbacks -> completed stream.
Exact final RED marker: CHAT_TEMPLATE_FAILED: 201 problem(s) (exit 1).
All 201 failures are visible EOF loss: 196 proper-prefix cases, three named examples and two EOF callback checks. No other original/new case failed. Cold debug build completed in 381.35s.

GREEN with the unchanged V2 fixture:
CHAT_TEMPLATE_STREAM: 658 cases, 0 failures; decoded pieces -> producer callbacks -> completed stream.
Debug fixed build completed in 362.87s. Exact final markers:

--selftest-chat-template → CHAT_TEMPLATE_OK: 6 families detected and rendered; control tokens survive planner decode (exit 0).
--selftest-notes-truncation → NOTES_TRUNCATION_OK: a cut answer says so on the page, the single pass and the reduce each retry once at double the budget, the cap scales with the meeting, the wire finish reasons are read (exit 0).
--selftest-llm-prefix-cache → LLM_PREFIX_CACHE_OK: reused 646/666 tokens, prefill 2.00s → 0.37s; stable prompt front 90% (was 73% before P1-28) (exit 0).
--selftest-store-isolation → STORE_ISOLATION_OK: 21 files and 0 defaults unchanged (exit 0).

The four GREEN flags ran once each, serially with the fixed build in one admitted ../heavy.sh FIFO slot. Prefix-cache was invoked once, not rerun. All gates stayed unchanged. The GREEN gate initially held at 8 GB disk; held/waiting time is not a verdict. Build durations and cache timings are functional observations, not physical voice/ASR latency acceptance.

Store-isolation also prints TOOLLOOP_PRODUCTION_FAILED with 18 browser TOOLLOOP_PRODUCTION_WRONG diagnostics, matching the 18 in the earlier retained run. Its existing nested test omits the required browser-fixture admission flag; that inherited test-wiring failure remains open. The final STORE_ISOLATION_OK covers 21 file signatures and zero observed default keys in the unbundled scratch process. It does not prove nested tool-loop success or installed owner-domain preference coverage. Both verdicts are retained; no test was weakened.

LlamaHelpers.piece line 59 independently decodes each native token's bytes into a String. The producer receives no raw byte fragments. A scalar split between native token buffers is repaired separately with replacement characters upstream; complete-string Unicode tests cannot prove scalar-byte reconstruction. Tests/Reports/thinking-stream-producer-v2/utf8-boundary.md retains the actual code/caller finding and its limits. This is an inherited upstream limitation, not a native fragmented-token occurrence or fix claimed here. Native S1-mini and MiniCPM vocabulary cases were not skipped.

Correction files: Sources/NextNotes/Formatting/LLM/ChatTemplate.swift and ChatTemplateSelfTest.swift; PERFORMANCE-STANDARDS.md; RESULT.md; Tests/Reports/thinking-stream-producer-v2/; a supersession notice in the prior report. This correction makes no NotesModelRuntime or task-store change; both source hashes remain identical to 8e4243d6.

Earlier branch hunks will conflict with uncommitted work: Sources/NextNotes/Formatting/LLM/NotesModelRuntime.swift and Sources/NextNotes/Agent/Tasks/AgentTaskStore.swift (supplied MAIN-DIRTY-SOURCES.txt and a read-only canonical status check). Merge the earlier runtime hunk manually; reuse the exact shared prerequisite rather than duplicate it. No such dirty file was reported for this correction's two source files at that check.

Only owned unheld caches/intermediates were retired after RED, preserving its executable/framework hashes. Final owned scratch was removed after GREEN binary-hash/no-holder verification; every runner-owned temporary root was removed after its child exited. Full build/run logs and source patches are retained as lossless gzip archives. The staged whitespace check initially flagged blank unified-diff context lines in raw evidence patches; those exact bytes are now compressed instead of edited. Source/fixture bytes are unchanged; final whitespace validation passes.

No install, GUI opening, push, merge, canonical checkout writes, owner-store migration/seeding or foreign-process/file cleanup. The pre-existing untracked LAST-MESSAGE-previous.txt remains untouched. Physical voice/full duplex, live hidden-generation frequency, hidden-block error/cancellation replay, measured allocations/latency, non-streaming reasoning, installed preference coverage and inherited aggregate quality remain outside this bounded repair. No model/default or phase is promoted; no owner decision is required for this source correction.

Evidence: Tests/Reports/thinking-stream-producer-v2/README.md; source-pins.json; red/green-summary.json; red/green-analysis.json; frozen V1/V2 fixtures; exact logs; compressed source patches and build/run logs; cleanup manifests. Relay start, RED findings and final findings are sent as claude2-thinking-review; delivery does not establish that peers read them.
