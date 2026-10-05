# Requested meeting grounding — 2026-10-05

The exact MiniCPM K01 answer claimed past decisions without a read, then asked a generic follow-up question. `AgentAccountRead` rejected that question before checking the unsupported content. The existing requested-read path now recognizes affirmative past-decision statements bound to a meeting read question. It obtains the selected read and answers from its result.

Corrected identical COMMON: six original failures → zero fixed failures through pure checks and actual typed `agent.handle`/executor/result/final-answer consumption. Genuine clarification, advice, uncertainty, write requests and already-completed reads stay excluded. The first fixture omitted the request in its tool lookup; its two false completed-read failures are retained, and both variants were rerun after correcting that lookup without changing inputs or assertions.

Production tool loop, live grader, tool review, ACP approval and owner-store isolation pass. Original installed Mini quick baseline6/6/6 remains recorded; a fresh installed measurement is required. Broader meeting content accuracy, voice delivery and overall gates remain open.

Raw patches/fixtures/results: `~/Library/Caches/NextNotesBuild/integration/meetings-unbacked-content/`.
