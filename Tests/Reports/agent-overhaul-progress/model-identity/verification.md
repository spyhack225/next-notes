# Model-name prompt assembly — 2026-10-05

The actual planner received the resolved model name but lost its existing disclosure exception: plannerSystem did not forward the request into that rule. The rule now lives in the existing volatile plannerRuleLines tail and receives the request. Ordinary stable rules and saved models/roles remain unchanged; no output scrub, extra pass or new identity source is added.

Unchanged actual-call regression: original two missing-rule/tail failures -> fixed PASS. The original incomplete raw reply remains byte-identical in the controlled fixture. Persona, now-block, tool-awareness, live prefix-cache and owner isolation pass. Prefix test reuses646/666 tokens and retains90% stable front; this is not a new voice latency claim.

Pinned MiniCPM5-2B-Q4_K_M, baseline sampler and Oct5 09:00 New York clock: N02 changes from UNGROUNDED/‘MiniCPM’ to PASS/‘MiniCPM5-2B’ in one native round. N01 identity-role reversal, full/owner gates, floor and latency remain open.

Evidence: `~/Library/Caches/NextNotesBuild/integration/n02-model-identity/`. Bulk artifacts stay outside iCloud.
