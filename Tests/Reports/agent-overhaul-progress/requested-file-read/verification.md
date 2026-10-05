# Requested file read — 2026-10-05

The final no-call handler omitted explicitly requested local-file searches. In all three retained MiniCPM F03 rounds, the model claimed no pricing document existed on this Mac without searching. The existing read handler now derives the name from the explicit locate clause and runs the selected read through the existing executor before answering.

Original/fixed `--selftest-toolloop-production`: **RED8 → GREEN**, identical two raw replies and request, actual typed consumer → `filesystem.search(query:pricing)` → exact fixture result → Marcus-address question. No inbox read, draft or send is invented. Existing-completed/unavailable searches, advice, capability questions and write-only requests remain excluded. Voice routing, capability manifest, tool review and store isolation pass. `--selftest-agent-answers` times out at 120 seconds on both original and fixed before an answer; this inherited check remains open, not passed.

Evidence: `~/Library/Caches/NextNotesBuild/integration/f03-requested-file-read/`. This repairs the authorized file-read prerequisite; native compound delivery, fresh quick quality, full/owner and latency acceptance remain open. No new store, wait or model pass is added; the existing result-answer round is reused.
