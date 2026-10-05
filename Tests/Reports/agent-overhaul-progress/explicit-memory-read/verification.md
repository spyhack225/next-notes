# Explicit memory read — 2026-10-05

The original request, ‘What do you know about me?’, received persona-only text with no recall. The selected ready memory capability had no read-floor resolver. AgentAccountRead now routes that explicit request through the existing bounded memory.recall and final evidence round. Existing current-turn/session suppression and write/advice/disabled controls remain. No new store, prompt, model/default change or write is added.

Original unchanged production regression: six failures; fixed: one recall, two provider rounds, no writes, returned facts reach the delivered answer. Capability-manifest, tool-review, voice-turn-routing and store-isolation pass. The earlier-session control was corrected before qualifying RED to exercise the actual floor cache; initial invalid harness runs remain in the external evidence. Ordinary model-call session-cache omission remains open.

Pinned MiniCPM5-2B-Q4_K_M, baseline sampler, Oct 5 09:00 New York clock: Y02 changes from MISSED_TOOL/no read to PASS/memory.recall and a grounded answer including Cyril/ProductFlo/CEO. Raw rounds retained. This single replay does not close full, owner, latency or floor acceptance.

Evidence: `~/Library/Caches/NextNotesBuild/integration/y02-explicit-memory-read/`. Bulk artifacts stay outside iCloud.
