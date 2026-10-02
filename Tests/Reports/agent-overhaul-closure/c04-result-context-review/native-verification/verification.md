# P1-10a-1: retain results before measured planner admission

Status: bounded producer fix verified. Original105 fails four target assertions; fixed106 passes the identical84 checks. Broader model quality, direct voice identity, default answer-only/scheduled folding and Agent phase gates remain open.

## Confirmed cause and producer change

Successful reads enter the ordinary planner as `<tool> returned:\n<body>`. `AgentToolLoop.userMessage` unconditionally folded everything older than the last two entries before the existing prompt token count. A real refusal/unsupported-claim repair note is also an entry. Consequently mail → repair note → calendar retained only `search_email returned:` for the mailbox, even when the complete prompt fit. The session still held the exact original output. The first incorrect decision was prompt admission, not missing tool backing or the final renderer.

The responsible producer now honors the ordinary fitter's `foldOlderResults:false` argument. It admits the already capped bodies into the existing measurement. The existing pressure sequence still drops earlier conversation, explicitly folds older results, caps bodies and refuses irreducible overflow. Generic/scheduled callers and `finalAnswerRound` retain their existing default folding pending separate original-flow proof. No prompt instruction, grader, output sanitizer, model default, tool permission or receipt contract changed.

## Actual original/fixed comparison

Both binaries contain the same conductor, registry, exact-flag temporary-memory seam and fixed ISO timestamp. The native conductor calls actual typed `RealtimeAgent.handle`, planner/backend, permission/validation and tool runner. Only the model/tokenizer and external tool backing are scripted; backing reuses unchanged live-evaluation mail/calendar fixtures and rejects unexpected tools. This is production-path transport proof, not native tokenization or model grounding proof.

| Mode | Original105 | Fixed106 |
| --- | --- | --- |
| No repair note,8192 window | Both bodies retained;14/14 | Identical prompt;14/14 |
| Actual refusal note,8192 | Mail body lost;13/14 | Exact545-character body retained;14/14 |
| Actual unsupported-claim note,8192 | Mail body lost;13/14 | Exact body retained;14/14 |
| Same refusal,32768 | Mail body lost;13/14 | Exact body retained;14/14 |
| Same claim,32768 | Mail body lost;13/14 | Exact body retained;14/14 |
| Same claim with counted pressure,8192 | Early folding bypasses pressure;14/14 | Counter8192→2000 invokes existing explicit folding;14/14 |

Original reaches all84 checks, with exactly four C07 failures and all80 controls green. Fixed passes84. Both execute exactly two reads per mode, preserve device-relative calendar arguments, raw session results, actual guard notes, visible budgets and final delivery. Neither carries invented intermediate assistant claims. Scripted final replies test delivery only.

The corrected common local-memory seam checks the actual SelfTest per-process temporary URL and clears only temporary in-memory labels immediately before the unchanged grounding producer. All12 domain controls pass before full user prompts are emitted. This does not suppress startup/activity refresh or prove no owner reads. Initial104 independently reproduced four failures, but its startup-derived grounding made it unsuitable for the final paired comparison. Its full stdout remains only in private system temp; the repository retains metadata/withheld-prompt records and the original preparation. The marker-only log/parser and stdout buffering issues were corrected before both105/106.

The1048-entry compiler manifests differ at exactly one Source: the reviewed conditional selection inside `AgentToolLoop.swift`. All common sources, fixture bytes and timestamp match. Each installed signed bundle and cached executable is pinned; native/model/core checks retain Source and full bundle invariance. See [source delta](original-fixed-source-delta.json), [common admission](isolation-common-mount.json), [original checks](app105-checks.json), [current checks](app106-checks.json) and the [independent paired review](../independent-review/closure-frontier-paired105-106-review.md).

## Related checks and unchanged gates

Fourteen of15 focused flags pass: dedicated84, production tool loop, live grader, ordinary tool loop, tool review, tools, persona, owner isolation, worker1352, voice conversation, concurrent voice, duplex work, scheduling and tool awareness. Owner isolation retains21 files/32 defaults. Existing full-envelope/capping, streaming, cancellation and permission regressions remain green.

The additional native `voice-grounding` flag fails. Its direct Llama `streamConversation` identity answer did not name the user. The direct test/system/provider/runtime/grader sources match103/105/106; its call path bypasses the changed result fitter and C04-only hook. Earlier reports contain the same failure, but there was no adjacent103/105 run and today's runtime cause is unresolved. Other model predicates lack individual failure labels. Preserve the actual failure, not an inferred all-green verdict. Raw live identity/model responses remain in private temp; the repository retains safe metadata and [independent attribution](voice-grounding-attribution/actual106-attribution.md).

Required native quick106 is **4/10**, below the unchanged9/10 bar,84.7s. C04 now passes with the correct fixture mailbox/calendar facts; A02 also passes. Historical103 was2/10, and its round2 raw response/final prompt was not retained. The paired structural reproduction proves the repo defect; the latest native pass does not retrospectively establish which branch caused103's hallucination or a causal latency gain. No model/default or phase promotion follows.

CORE remains **21/22**, exit2. The unchanged wake failure is17/24 hits and3/32 false accepts against0.8/≤2. Full/owner evaluations, live interactions and latency readiness remain open. Longer admitted prompts can increase prefill cost; no performance neutrality claim is made. The fit path adds no counter await, model pass, store, queue or timer. Pressure reuses existing counter iterations.

Manual diagnostic: `Scripts/run-selftest.sh --selftest-c04-result-context --c04-fixture-now <ISO8601>`. Original/fixed comparison must reuse one timestamp and the identical conductor. The date remains subject to the real device-day grounding control; no grader or clock exemption is added.
