# thinking — review follow-up, 2026-10-05

Work is in progress on `claude/thinking`. The original native precedence regression has failed as expected. The corrected build is queued through `../heavy.sh` behind serial-root's F03 priority hold; green checks and new commits are pending. No queued or held job is counted as a pass.

## Confirmed cause and correction

The interactive planner set `LocalThinkingRole.current = .agent`. Although `streamInteractiveConversation` explicitly requested `.off`, `streamPrompt` selected `current ?? thinking`, producing the open-thinking MiniCPM prompt. This affected both the ordinary and grammar planner overloads.

The producer now takes an optional explicit role and selects `thinking ?? current ?? .agent`. Both interactive planner calls carry `.off`; noninteractive work still carries `.agent`. The direct foreground voice call also carries `.off`. Generic completion keeps its existing ambient-role-or-off behavior. No provider, grammar, stored choice, scheduler, token budget, timer or native termination seam is changed.

The native regression uses an isolated runtime with the explicitly pinned existing file `/Users/sergekadjo/Library/Application Support/Next Notes/Models/MiniCPM5-2B-Q4_K_M.gguf` (1,561,318,368 bytes). It drains the public interactive runtime calls under nil/Agent/notes and both actual PlannerBackend stream overloads through `LlamaLLMProvider(runtime:)`. Noninteractive Agent and notes are positive controls. Assertions read actual `prefillStatsForTesting().promptTokens`; they do not re-evaluate the role expression.

Original results: direct/nil OFF = 24 prompt tokens; direct/Agent, direct/notes, planner/plain and planner/grammar = 22. Both work controls = 22. Exact final marker: `LLM_PREFIX_CACHE_FAILED: 4 problem(s)`, exit 1. The native fixture SHA-256 is `20d6d5e47ba35c5e9df32a0dcec9e7d64a800d2e6a522d788172a9e9b5d1f7d8`. Red binary SHA-256: `cc9f1c2a529018a1fdc048033d8dcddddb8fe0682d6b5060b9776db3a4248b2c`. Red build passed in 218.82 seconds. Four additive scripted planner checks observe OFF/work roles at the actual provider protocol hop, including grammar/default forwarding.

## Sampler work and floor handoff

The process-only sampler implementation and tests are prepared, not yet applied or verified. It will validate a single `--sampler-arm baseline|minicpm-vendor` before resolving/loading a model, bind the arm to the resolved GGUF, use that profile in the existing grammar-first sampler chain, and emit `TOOLLOOP_LIVE_SAMPLER` before warm-up. Explicit report rows will retain `samplerArm`; the markdown header will show the same parameters, seed and penalty window. No argument will preserve the current role profile. Apple/cloud/server, missing/unknown/duplicate values and unpinned requests will be refused.

This branch and cb6d700 have no `--floor`/`--floor-model` implementation in `runMetalSelfTest`. Runtime parser/binding support can be supplied here; the floor host must resolve its explicit pin and configure that private runtime before warm-up. No floor application or qualification is claimed. The optional notes arm is unnecessary for the requested bake-off and is not enabled.

## Reserved provider handoff, updated from the review

`MeetingAgent.swift:310` invokes `complete(... tools:)` through `any LLMProvider`. The tools-completion overloads in `LLMProviderTools.swift` are extension-only in this branch. Root must make its selected overload a protocol requirement with the existing default, then wrap only the actual native tools-completion body/runtime request in `LocalThinkingRole.$current.withValue(.agent)`. A concrete provider method alone will not dispatch through the existential. Keep generic complete and interactive conversation outside that wrapper. Neither reserved provider file is edited here.

## Prior evidence retained from RESULT-previous.md

- `a0b197f46c147fb9b21f0061a1a767a9a8bc5dd2` introduced the shared strip/cap producer, role plumbing and role sampler; `d152964` recorded its verification/handoff.
- The original extracted strip-and-cap producer failed 77 assertions before correction. Its unchanged regression passed afterward, including actual 512/1,024 caps and split tags. Fixture SHA-256: `81d016bc5dbf1c67ebefcdb0524fbec1b501c90c21bdd5f8e0e58937ebaad59c`.
- The actual non-Agent completion renderer then failed two native tool-delimiter assertions; those same assertions passed after fixing that renderer. Agent completion still preserves native tool markup.
- The previous six checks were green: chat-template; notes truncation; model roles; usage log (26); owner isolation (21 files, 0 defaults); S1 prefix-cache (646/666 reused, 1.33s → 0.18s, stable prompt front 90%). These are prior results, not this follow-up's pending rerun.
- Forced thinking closure extends the same native KV ledger. Hidden reasoning is discarded before output callbacks/results and only its numeric count reaches usage. Answer grammar resumes after closure. No second model or durable store was added.

## Limits

The new native regression observes prompt production/consumption, not a physical microphone/TTS conversation or measured first-token latency. Native MiniCPM forced-cap output, broader grammar-on-answer behavior, live notes quality/cut-short rates, dictation tail, near-full Agent-window fitting and voice latency remain unqualified. Serial-root owns actual model/quality bake-offs; none is run here. No model/default promotion, broader readiness, rebase, install or push is claimed. Root should integrate relative hunks, preserving its newer App/runtime/quit work.

`RESULT-previous.md` is retained untouched and untracked. Only this worktree is changed; the iCloud main checkout's working files, other worktrees, installed app and owner stores are untouched.
