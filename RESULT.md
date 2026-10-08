Standalone streaming producer repair delivered on claude2/thinking-review.

Producer/test/evidence commit: 8e4243d6837737f1c2c23b18399237dcf0dff214.
Shared prerequisite commit: aae0a5c6 (cherry-pick of listen2 20d8f9b8b592b92acd01ab31d3f50978abb99103, exact canonical recoveredReadHistory method).
Previous read-only review remains in RESULT-previous.md and THINKING-REVIEW.md.

Confirmed cause: main stripped complete think controls per piece, then yielded the reasoning body; split controls and same-piece stop tails also reached callbacks. The actual streaming output producer now retains bounded marker prefixes, hides marked/nested/interleaved reasoning, and stops before turn-tail text. Ordinary plain/tool bytes are unchanged in the seven-family UTF-8 fixture. No roles, sampler, defaults, generation budget, model passes or scheduling awaits changed.

RED before repair: CHAT_TEMPLATE_STREAM: 440 cases, 542 failures; decoded pieces -> producer callbacks -> completed stream.
RED final marker: CHAT_TEMPLATE_FAILED: 543 problem(s), exit 1; extra failure is native MiniCPM vocabulary output PRIVATEAnswer… . All failures are in the new producer cases.
GREEN: same 440 cases fail 0; native MiniCPM producer and existing checks pass.
Exact fixture SHA256 before/after: 2e8009db5d72670706f7e934a21eda9d9e74c22aeb86fb2fcac9aac19cd88dc4.

Checks run through ../heavy.sh, serially in owned scratch:
--selftest-chat-template → CHAT_TEMPLATE_OK: 6 families detected and rendered; control tokens survive planner decode (exit 0).
--selftest-notes-truncation → NOTES_TRUNCATION_OK: a cut answer says so on the page, the single pass and the reduce each retry once at double the budget, the cap scales with the meeting, the wire finish reasons are read (exit 0).
--selftest-llm-prefix-cache → LLM_PREFIX_CACHE_OK: reused 646/666 tokens, prefill 1.38s → 0.18s; stable prompt front 90% (was 73% before P1-28) (exit 0).
--selftest-store-isolation → STORE_ISOLATION_OK: 21 files and 0 defaults unchanged (exit 0).
--selftest-llm-prefix-cache ran once. Both corrected RED and fixed debug builds passed; initial build failed on the inherited missing task-store method and was not a RED test verdict. No threshold/test/timeout was weakened.

The actual store-isolation result observes zero watched defaults in the unbundled scratch executable. It does not prove installed owner-domain preference coverage; do not substitute the historical 32-default count. The guard compared 21 file signatures including absence/unreadability states. Physical voice/full-duplex playback, live hidden-generation frequency, non-streaming literal-thinking output, broader notes factuality, task-store recovery qualification and inherited model-quality gates were not verified here. No model/default or phase promotion.

Files changed: Sources/NextNotes/Formatting/LLM/ChatTemplate.swift, ChatTemplateSelfTest.swift and NotesModelRuntime.swift; shared prerequisite Sources/NextNotes/Agent/Tasks/AgentTaskStore.swift; PERFORMANCE-STANDARDS.md; RESULT.md; Tests/Reports/thinking-stream-producer/ (report, unchanged RED source patch, exact native logs/summaries, compressed raw build logs, runner and cleanup manifests).

Will conflict with uncommitted work: NotesModelRuntime.swift and the shared AgentTaskStore.swift prerequisite (per MAIN-DIRTY-SOURCES.txt). Integrator must merge the bounded streaming callback hunk manually and reuse the existing canonical/shared prerequisite rather than duplicate its method. No owner decision or permission is needed for this bounded source repair; later installed-domain/live-voice acceptance is a separate contract.

No canonical checkout edits/builds, owner-store seeding, GUI opening, install, push or merge. Own scratch was removed after exact GREEN binary-hash/no-holder checks; every runner-owned test temporary root was removed. Foreign files/processes/staged changes were preserved. Cache cleanup retained the RED executable/framework hashes; its manifest distinguishes allocated bytes and available-space samples from independent peer cleanup.

Details and real original/fixed pins: Tests/Reports/thinking-stream-producer/README.md, red-summary.json, green-summary.json and final-cleanup.json. git diff --check and staged whitespace validation passed. Relay start/producer-RED/finish messages are sent as claude2-thinking-review; delivery is not assumed acknowledgement.
