# Requested mail read qualification

Original b915ced with the COMMON exact MiniCPM F03 replies fails fifteen assertions. AgentAccountRead now qualifies its automatic mail read from the actual requested read clause. The identical production flag plus tool-review, toolloop-live-grader, acp-confirm and store-isolation pass; 21 owner files/32 defaults remain unchanged.

Actual typed agent.handle/pendingRead consumers no longer inject an inbox read or stop in a mailbox-summary round for the file-and-send request. Natural inbox questions, requested summaries/reads, explicit read-plus-draft admission, completed-read suppression and existing meeting/calendar controls pass. Mail writes, advice and self-directed questions supply no automatic inbox-read request. No extra round, store, queue or approval was added.

This repairs wrong read selection, not the model's initial file denial, recipient resolution, compound write completion or aggregate quick readiness.

Raw comparison/build logs and COMMON fixture are retained outside iCloud in ~/Library/Caches/NextNotesBuild/integration/f03-quick-triage/requested-read/.
