# H1: caps on models, prompts and the tool loop

> **Historical model assumptions — revised 2026-09-30:** this completed plan/audit
> preserves its dated measurements and implementation history. For new work, follow
> the [independent-role/shared-file contract](../../in-progress/SHARED-BRAIN/00-README.md): Meetings, Agent and cleanup
> may use different appropriate models; exact verified artifacts are reused, with
> workload-specific consent and request ownership. Agent-only file selection,
> universal model defaults and deletion based only on the Agent are superseded.
> MiniCPM cleanup + Apple guard/fallback is concurrent work, not evidence that this
> historical build used it. Re-measure quality/latency on the actual current engine.

2026-09-23. This was a read-only audit. It changed no source files, ran no builds and did
not launch the app. Scope: token caps, context budgeting and truncation, tool selection,
plan budgets, round and call limits, retries and denial caps, provider fallbacks and their
guards, consent gates, the defaults of feature switches, and rate limits. It covers
`Agent/**` (except Speech and the acoustic files), `Formatting/LLM/**`, `Knowledge/**`,
`Persona/**`, `Support/ModelLibrary/**`, `Support/ModelRoles/**` and `Memory/**`.

Line numbers are for the working tree today. `ToolLoop` means
`Sources/NextNotes/Agent/RealtimeAgent+ToolLoop.swift`. Evidence tags: **(M)** means
measured on this Mac today from `~/Library/Application Support/Next Notes/`
(`agent-audit.jsonl`, `metrics.jsonl`, `agent-memory-review.json`, `Meetings/*`,
`knowledge.sqlite`) or from `defaults read ai.pivotstudio.nextnotes`. **(R)** means taken
from reports A–G.

What this Mac is running today (M): `modelRoles.agent = cloud` on
`inclusionai/ling-3.0-flash-sante:free`, with `openRouterAgentContextTokens = 262144` and
`agentResponsiveness = deep`. The knowledge index, knowledge tools, graph and embedder are
all on. `knowledgeGraphCloudConsent` and `visionCloudConsent` are unset, so they are false.
`modelLibrary.postDownloadPolicy = switchDeleteOld`.

---

## 1. Summary table, most harmful first

Coverage: **covered** = an existing roadmap task does it as written. **partial** = a task
touches it, but the shape proposed here differs or a piece is missing. **NEW** = no task
covers it.

| # | Limit | Value | Where | Verdict | Proposed change | Coverage |
|---|---|---|---|---|---|---|
| 1 | Typed tool-plan budget (all rounds) | 18 s local, 75 s OpenRouter, 120 s voice worker | `ToolLoop:796-798` | **HURTS** | per round plus a ceiling (30 s / 120 s local) | covered P1-06 |
| 2 | Typed first-pass output cap | 112 tokens | `ToolLoop:414,418` | **HURTS** | persona budget, reasoning allowance | covered P0-05 + P0-17 |
| 3 | Planner round output cap | 256 tokens | `ToolLoop:888,891` | **HURTS** | ≥ 1,024 typed, 768 worker | covered P1-02 step 6 |
| 4 | First-pass budget | 18 s warm, 45 s cold, 30 s OpenRouter | `RealtimeAgent.swift:31-32`, `ToolLoop:386-388` | **HURTS** | removed with the typed first pass | covered P1-02 / P1-06 |
| 5 | Unknown tool name or any tool error ends the turn | 0 repairs | `ToolLoop:962-967,1072-1081` | **HURTS** | 3-way error split, ≤ 2 repairs | covered P1-04 |
| 6 | Tool roster sent to the planner | 9 core + keyword top-15 = 24 | `ToolLoop:594-633` | **HURTS** | manifest, selected by namespace | covered P1-03 |
| 7 | Hard-coded allowlist (MCP/Composio never plannable) | 49 ids | `ToolLoop:29-58` | **HURTS** | manifest by risk class | covered P1-03 |
| 8 | Apple FM window constant | 4,096 (8,192 measured) | `FoundationModelLLMProvider.swift:13` | **HURTS** | read at runtime | covered P1-10a step 0 |
| 9 | History given to the model | first pass 2,500; planner 2,500 or 6,000; `.localModel` 3,000; voice 1,400; per message 1,800; **hard ceiling 10,000** | `ToolLoop:382,815`; `RealtimeAgent.swift:715,857,1026,1066`; `AgentSessionBoundary.swift:27` | **HURTS** (cloud reader has 262K) | scale with the reader and lift the 10,000 ceiling | **partial** P4-08 (misses the 10,000 ceiling and `:715`; it is also Phase 4) |
| 10 | Tool results fed back uncapped; P1-10a's planned cap is 1,200 characters **even for a 262K reader** | none today → 700/1,200 | `ToolLoop:1048`; plan in P1-10a | **HURTS** now; **MIXED** as planned | cap scales with the reader; document reads get a larger cap | **partial** P1-10a (NEW refinement) |
| 11 | Knowledge index default split: `Settings` says **off**, `KnowledgeIndexSettings` says **on** | false vs true | `Settings.swift:1078` vs `KnowledgeIndexer.swift:34` | **HURTS** (fresh installs) | one default (true), read from one place | **NEW** |
| 12 | Agent knowledge tools off by default | `knowledgeAgentToolsEnabled = false` | `Settings.swift:1083` | **HURTS** (fresh installs: "I can't access past meetings") | default on while the index is on | **NEW** |
| 13 | Multi-step notices state the wrong model and the wrong time | "on this Mac it takes a few minutes" while the plan runs on OpenRouter, or with an 18 s budget | `ToolLoop:755-770`; `ModelRoleStore.swift:810-828` | **HURTS** (a false statement) | derive from the resolved provider; drop "few minutes" and "slower" | **NEW** (P4-09 fixes only the consent) |
| 14 | Multi-step cloud escalation gated on the wrong consent and on a "then/after + 2 verbs" regex | `knowledgeGraphCloudConsent` | `ModelRoleStore.swift:726-745,779-796` | **HURTS** | own consent; route by role and lane | covered P4-09 (consider moving it earlier) |
| 15 | Voice and background work pinned to the built-in model | `voice → .appLLM` | `ModelRoleStore.swift:727` | **HURTS** | lanes | covered P4-09 |
| 16 | P4-09's new `agentCloudConsent` defaults to false | — | P4-09 target 3 | **would HURT** this user: it demotes an explicit `.cloud` role to on-device | seed it true when the stored role is already `.cloud` | **NEW** (amend P4-09) |
| 17 | The budget is carried across revisions of a voice objective | shared `remainingBudget` | `ToolLoop:389-443`, `:801-917` | **HURTS** (M: follow-ups timed out 2–3 s after arriving) | a new revision gets a fresh per-round deadline | **NEW** (amend P1-06) |
| 18 | Round cap | 4 (fast/balanced), 8 (deep); clamp 4…8; the rebuttal and repairs spend rounds | `AgentToolLoop.swift:17-25`; `Settings.swift:79-91` | **MIXED** | rounds = calls + 2; on exhaustion, one final answer-only round | **NEW** (amend P1-06) |
| 19 | Call-cap exit drops the verified results | "safe limit" with no result | `ToolLoop:957-958` | **MIXED** | route through `incomplete` or the final round | **NEW** |
| 20 | A repeated call signature ends the plan | stop | `ToolLoop:971-976` | **MIXED** | hand back "already done: <result>; answer now" once | **partial** P1-04 (dedupe re-keyed, stop kept) |
| 21 | Denial backstop needs a 2nd *identical* denial; the planner gets one rebuttal | 2 / 1 | `VoiceConversationCoordinator.swift:482-495`; `ToolLoop:830,942` | **MIXED** | escalate on the first contradicted denial | covered P1-07 |
| 22 | `agentAutoRunReadTools` is not honoured by the planner, but it hides the knowledge tools | planner hard-codes `autoApproveReads: true` | `ToolLoop:310,998,1190`; `KnowledgeTools.swift:24-33` | **MIXED** (a setting that says one thing and does another) | the planner honours it; knowledge visibility stops depending on it | **NEW** |
| 23 | Memory review: an update with no target is refused and the fact is lost | 25 of 40 refusals | `MemoryGuard.swift:390-402` | **MIXED** | on the review path, a refused update that passes provenance becomes `remember` | **partial** P4-07 |
| 24 | "Delete the old one" is recommended below 2× the 4 GB reserve | `recommendsDeletingOld` | `ModelLibraryStore.swift:458-464` | **MIXED** (it steered toward the policy that deleted the working model) | recommend it only after P0-02's decode check | **partial** P0-02 |
| 25 | MeetingAgent rounds and output | 2 rounds, 900 tokens, ≤ 3 proposals, "often zero" | `MeetingAgent.swift:16,49`; `AgentPrompts.swift:9,24-25` | **MIXED** (M: 0 proposals across 6 meetings with 4 "You" action items) | log each pass's outcome first; rounds 3 for readers ≥ 32K | **partial** P4-05 |
| 26 | KnowledgeAsker passages and output | 20 × 700 characters, 512 tokens | `KnowledgeAsk.swift:152-159` | **HURTS** on Apple FM | fit to the window | covered P4-08 |
| 27 | Gmail search | query required, 5 results, per-id fetch | `WorkspaceToolRunner.swift:19,55-83` | **HURTS** | defaults and a metadata batch | covered P1-09 |
| 28 | llama context sized to each prompt (rebuilt when the size changes) | 512 granularity | `NotesModelRuntime.swift:1234-1244` | **HURTS** latency | grow only | covered P0-18 |
| 29 | Assembler page pass | 600 tokens | `Knowledge/Assembler.swift:456` | **MIXED** | scale with the reader (≥ 1,500 on cloud) | **NEW** (low) |
| 30 | `Limits.tool` cloud branch can never be taken | 20 s always | `RealtimeAgent.swift:364-369` | housekeeping | delete the dead branch | **NEW** (trivial) |
| — | Kept (HELPS) | the notes model's 10-minute unload, 32K max context, 4 GB disk reserve, fit estimator, residency unload order, memory store budgets (2,400/4,000), 300-character entry cap, Workspace 2,000-character result, gws 60 s timeout, voice answer 256 tokens and 25 s, route 64 tokens, `maxLookupCharacters` 1,200, `AgentPolicy.live` (1 round, no reads), Needle confidence floors 0.3/0.35/0.5, local proposer 0.65, `FunctionCallStore.maxTools` 8, card caps 1 outstanding and 3 per 10 min, NeedleServer timeouts, ACP/Codex 32 KiB, VisionHandoff 320, `agentAutoRunReadTools = true`, graph and vision cloud consents off, 30-minute session idle, routines 180 s and 8 calls, persona 2,000 / skills index 1,200 | see §2.4 | **HELPS** | keep | — |

---

## 2. Detailed entries

### 2.1 HURTS

**1. Typed tool-plan budget: 18 s for every round together.**
- Where: `ToolLoop:796-798` (`isVoiceWorker ? 120 : openRouter ? 75 : 18`).
- What it guards against: a stuck local model holding the pane.
- Evidence:
  - (M) `metrics.jsonl` shows planner prefill of 2.2–5.2 s at 1.1–2.3K prompt tokens.
  - (M) `model.first_token` has a median of 4.9 s and a maximum of 8.3 s.
  - (M) One 256-token round decodes at about 45 tok/s (G), which is about 5.7 s.
  - So two rounds cannot fit in 18 s. The audit log has 10 "I stopped the tool plan
    because it took too long." replies. The typed one is 09-15 01:13Z, "Check my email,
    check the last email and then do a summary of that": it timed out after a
    `search_email` that had already returned.
- Verdict: HURTS. Covered by P1-06 (30 s per round, 120 s ceiling, 45 s cold allowance).

**2. Typed first pass capped at 112 tokens.**
- Where: `ToolLoop:414,418`.
- Evidence: G O2 and O5 were clipped mid-sentence. O5 used 105 of its 112 tokens on
  reasoning and ended with `finish_reason: length`.
- Covered by P0-05 + P0-17. Land them together, as the roadmap already says.

**3. 256 tokens per planner round.**
- Where: `ToolLoop:888,891`.
- Evidence (R, B/T4): a `draft_email` body is cut off, and the call then parses as an
  invalid tool request.
- Covered by P1-02 step 6: `plannerRoundTokens` gives ≥ 1,024 typed and 768 for the worker,
  capped at `contextTokens/4`.
- No change needed. For a 262K cloud reader the 1,024 cap is still reasonable, because the
  final typed answer is also written in a planner round, and P0-17 adds the reasoning
  allowance on top.

**4. First-pass budget: `Limits.modelWarm` 18 s, `modelCold` 45 s.**
- Where: `RealtimeAgent.swift:31-32`.
- Evidence: (M) five "The model took too long to answer." replies on 09-14. After P1-02
  there is no typed first pass.
- Covered by P1-02 / P1-06.

**5–7. Error handling, tool selection and the allowlist.** Covered by P1-04 and P1-03.
Nothing to add beyond items 19 and 20.

**8. Apple FM `contextTokens = 4_096`.**
- It drives the `< 8_000` history split at `ToolLoop:815`, MeetingAgent's cut, and the
  voice `compact` grounding.
- Covered by P1-10a step 0.

**9. History is fixed in characters, whatever the reader's window.**
- The values: first pass 2,500 (`ToolLoop:382`), planner 2,500 or 6,000 (`:815`),
  `.localModel` 3,000 (`RealtimeAgent.swift:715`), voice 1,400
  (`VoiceConversationCoordinator.swift:678`), and 1,800 per message
  (`RealtimeAgent.swift:1043,1066`).
- There is also a hard ceiling: `AgentSession.contextCharacters = 10_000`
  (`RealtimeAgent.swift:857`), applied as `min(Self.contextCharacters, maxCharacters)` at
  `:1026`. Compaction also folds at `AgentSessionBoundary.workingBudget = 10_000` (`:27`).
- This Mac's typed reader has a 262,144-token window (M), yet it is given 2,500 characters
  on the first pass: less than one email listing plus its question (Q9, "summarise those").
- P4-08 targets 12,000 at ≥ 32K. That value would be clipped to 10,000 by `:1026`
  **silently**, and P4-08 does not list `:715`.
- Proposal:
  - `AgentHistoryBudget.characters(contextTokens:)`: < 8K → 2,500; < 32K → 6,000;
    < 128K → 12,000; ≥ 128K → 24,000.
  - Raise `contextCharacters` and `workingBudget` to 24,000, or pass the budget through.
  - Per-message cap: `min(6_000, budget * 2/5)`.
  - Add `:715` to the call sites.
  - Move steps 1–2 of P4-08 into Phase 1. They take hours, and today's typed reader is the
    cloud one. The KnowledgeAsker half can stay in Phase 4.

**10. Tool results.** Uncapped today (T13). As planned, P1-10a would cap every result at
**1,200 characters (700 at ≤ 4K) whatever the reader's window** (P1-10a lines 47 and 70).
For a 262K OpenRouter reader that is a new cap that hurts:
- `read_doc` of a 10-page doc becomes 1,200 characters, so "summarise this doc" becomes
  impossible.
- Five emails with snippets won't fit.
- `skills.read` (today `readLimit = 6_000`, `SkillTools.swift:85`) would lose four-fifths
  of every skill's instructions.

Proposal (amend P1-10a):
- `characterCap(readerContextTokens:)`: ≤ 4,096 → 700; ≤ 8,192 → 1,200; ≤ 32K → 4,000;
  otherwise 12,000.
- Document-reading tools (`read_doc`, `filesystem.read`, `skills.read`, `meeting.transcript`)
  get 2× that cap.
- The existing context-budget fitter already shrinks results when a prompt is over.
- Workspace's own 2,000-character cap (`WorkspaceToolRunner.swift:17`) should read the
  same function rather than a literal.

**11. The knowledge index has two defaults.**
- `Settings.knowledgeIndexEnabled` defaults to **false** (`Settings.swift:1078`).
  `KnowledgeIndexSettings.fromDefaults` defaults to **true** (`KnowledgeIndexer.swift:34`),
  and the indexer reads that one (`:958`).
- On a fresh install the indexer indexes, but every other reader treats the index as off:
  - the sidebar hides Search (`UI/Sidebar.swift:108`);
  - the search screen refuses to run (`KnowledgeSearchView.swift:339`);
  - `KnowledgeToolGate.isAvailable` is false, so the planner is never shown
    `search_knowledge`, `expand_node` or `timeline`.
- AGENTS.md says "on by default … `--selftest-index` pins the on-by-default answer". That
  pins only the half nobody gates on.
- No evidence on this Mac, where the key is explicitly `1` (M).
- Proposal: `Settings` reads `KnowledgeIndexSettings.fromDefaults.enabled` for its initial
  value, so there is one default. Extend `--selftest-index` to assert
  `Settings.shared.knowledgeIndexEnabled == KnowledgeIndexSettings.fromDefaults.enabled`
  with the key absent.
- Phase 1, hours.

**12. Knowledge tools are off by default.**
- `knowledgeAgentToolsEnabled` defaults to false (`Settings.swift:1083`). A fresh install
  that has meetings indexed still answers "I cannot access past meetings" (B/T7), and the
  P1-01 eval cases K01–K03 and Y02 depend on these tools.
- The switch guards nothing that another gate does not already guard:
  - the tools are reads;
  - cloud readers are already limited to `search_knowledge` by `knowledgeGraphCloudConsent`
    (graph reads);
  - memory stays separate.
- Proposal: default true, still gated on the index being on. Phase 1.

**13. The multi-step notices say false things.**
- Where: `ToolLoop:755-770` computes `route` from `MultiStepPlanRouting` (a regex plus
  `knowledgeGraphCloudConsent`). It does not use the provider that will actually answer
  (`AgentModelRouting.provider`, `:774`).
- On this Mac (M): role `.cloud`, graph consent false. A typed "check my mail then
  summarise it" gets `.localWithWarning`. The reply is prefixed with "This needs a few
  steps, so **on this Mac it takes a few minutes**… or connect an online model to go
  faster". The plan then runs on OpenRouter.
- For a genuinely local model, "a few minutes" contradicts the 18 s budget that kills the
  plan.
- The `.cloud` notice says "Using X online — **slower**". The measured cloud model is the
  fastest path on this Mac: 0.8 s to first byte, 250 tok/s (G).
- Proposal:
  - Build the notice from the resolved `provider.id`, after line 778.
  - `.appLLM` with a likely multi-step request: "This takes a few steps on this Mac."
  - `.openRouter`: "Using <model> online; this leaves your Mac." Say it once per session,
    and say nothing about speed.
  - Never mention minutes the budget does not allow.
- Phase 0: a user-visible false statement, a few hours of work.

**14–15. Cloud escalation consent and lane pinning.** Covered by P4-09.
- The evidence is the current state of this Mac: the user chose `.cloud`, and every voice
  job and background worker still runs on the on-device model.
- Pulling P4-09's lane mapping into Phase 1 would let the P1-01 eval grade the model the
  user actually picked.

**16. P4-09's `agentCloudConsent` defaults to false.**
- As written (P4-09 target 1), a stored `modelRoles.agent = cloud` with the new consent off
  gets demoted to the on-device model, with the notice "Online answers are off".
- That silently undoes a deliberate choice this user made. The role picker already names
  the online model.
- Proposal: on first launch after the change, when the key is absent, set
  `agentCloudConsent = (choice(for: .agent) == .cloud)`. Choosing `.cloud` in the picker
  afterwards shows the consent sentence inline and sets it.
- Add a `--selftest-model-roles` case for the migration.

**17. The budget is carried across revisions.**
- In both loops, a round that finishes after the work item was revised charges
  `remainingBudget`, and then `continue`s with what is left:
  - first pass: `ToolLoop:440-443`;
  - planner: `ToolLoop:914-917`.
- A corrected voice objective therefore starts with a partly spent budget.
- Evidence (M, 09-14): three follow-up revisions ended "The model took too long to
  answer." **2–3 s after the follow-up arrived**:
  - 17:47:00Z (revision 1, "my last 10 emails, and then give me a summary");
  - 17:49:08Z (revision 2);
  - 17:49:31Z (revision 2).
- The voice worker has 120 s today, but P1-06's per-round design has the same carry-over
  unless the ceiling is reset.
- Proposal (amend P1-06):
  - On a revision change, restart the round clock.
  - Refill the ceiling to `max(ceilingRemaining, budget.ceiling / 2)`.
  - Cap it at one refill per 10 s so a stream of corrections cannot run forever.
- Red-first: add a scripted case to `--selftest-voice-work-lifecycle`.

### 2.2 MIXED

**18. Round cap.**
- `clampedMaxRounds(toolRoundLimit)`: fast and balanced get 4, deep gets 8
  (`Settings.swift:79-84`, `AgentToolLoop.swift:17-25`).
- Every rebuttal re-plan (`ToolLoop:942-948`) and, after P1-04, every repair spends a round.
- "Search, read, summarise" needs 3 rounds plus 1 answer round. One false refusal or one
  repair at `balanced` (the default) then ends the plan with "I couldn't finish the tool
  plan within the safe limit." (`:1085`), which carries no answer at all.
- A round count is redundant once P1-06 bounds time.
- Proposal:
  - `maxRounds = maxCalls + 2` (one answer round, one repair): 6 for fast, 10 otherwise.
  - When rounds or calls run out, make **one final round with no tools** ("Answer now from
    what you have; no tool calls"). It uses the answer token budget and is bounded by the
    per-round deadline.
  - Amend P1-06.

**19. The call-cap exit discards what was found.**
- `ToolLoop:957-958` returns a bare "I couldn't finish the tool plan within the safe
  limit."
- It bypasses `incomplete(…)`, so `lastVerifiedResult` and the memory confirmations are
  lost.
- Proposal: use the same exit as item 18's final round. Small, NEW.

**20. A repeated call ends the plan.**
- Where: `ToolLoop:971-976`.
- Small models re-issue the same call when the result was long or empty.
- P1-04 re-keys the dedupe to the canonical id, but it keeps the stop.
- Proposal: the first repeat appends "You already ran <tool> with these arguments; its
  result is above. Answer now or choose a different step." It counts as a repair. The
  second repeat ends the plan through item 18's final round.

**21. The denial backstop and the single rebuttal.** Covered by P1-07 (first-denial
escalation) and P1-03 (a manifest-driven roster makes most rebuttals unnecessary). Keep one
planner rebuttal; its cost is one prefill.

**22. `agentAutoRunReadTools` is only half enforced.**
- The Settings copy says reads run without asking only while the switch is on
  (`Settings.swift:620-627`).
- The realtime planner and the direct intents always pass `autoApproveReads: true`
  (`ToolLoop:310,998,1190`), so switching it off changes nothing for typed and voice turns.
- The switch *does* hide the knowledge tools (`KnowledgeTools.swift:24-33`, "leaving them
  in would bypass the switch"). The bypass already exists for every other read.
- Proposal:
  - The planner passes `autoApproveReads: Settings.shared.agentAutoRunReadTools`. A read
    then shows a card, the same as MeetingAgent does.
  - `KnowledgeToolGate.isAvailable` drops the `lookThingsUp` term.
- Default stays true (HELPS). NEW, Phase 1.

**23. Memory review yield.**
- Across 200 runs (M): 103 proposals, 4 saved.
  - 57 were skipped as "already remembered" (correct).
  - 40 were refused. 25 of those were "you didn't say which memory to change"
    (`MemoryGuard.targetProblem`, `:390-402`): the review model used `memory.update` for
    what was a new fact.
  - 33 runs failed on OpenRouter 429. The cloud gate now handles that.
  - 31 local runs proposed nothing.
- The guard is right to refuse re-targeting an unrelated entry.
- Proposal: on `origin == .memoryReview` only, an update refused *only* for its target
  whose replacement passes `provenanceProblem` is retried once as `remember`. The
  near-duplicate check still applies.
- Complements P4-07, which saves explicit statements at the time they are said. Phase 4.

**24. The disk-reserve nudge.**
- `recommendsDeletingOld` (`ModelLibraryStore.swift:458-464`) leans the confirmation sheet
  toward "switch and delete old" whenever free space after the download would fall under
  8 GB.
- On this Mac it always does (4.3 GB free, R). That is the policy that deleted the working
  model (T1).
- The 4 GB reserve itself HELPS.
- Proposal: until P0-02's one-token decode check ships, never recommend deleting, and never
  when the old model is the only usable one. Amend P0-02.

**25. MeetingAgent.**
- The limits:
  - `maxRounds` 2, and 1 while live (`MeetingAgent.swift:16,30`);
  - `maxOutputTokens` 900 (`:49`);
  - ≤ 3 proposals, with the prompt line "A follow-up nobody asked for is worse than none …
    often zero" (`AgentPrompts.swift:24-25`);
  - an exact transcript quote is required per write (`:40-42`).
- (M) Six finished meetings, `agentActions: []` in every one. Four of them list "**You** —
  send the proforma invoice / share the roadmap / send the meeting summary" action items.
- Whether the pass ran and returned zero, or never ran, is not recorded anywhere
  persistent. The `agent round N: K call(s)` line is info-level and ages out.
- Proposal:
  - First, record each pass (provider, rounds, calls, proposals, refusals) through P0-20's
    provenance row.
  - Only then change the gates.
  - Allow 3 rounds when the reader's window is ≥ 32K. The comment's "more than that on a
    4B model is a loop" is a per-model fact.
- Partial P4-05.

**29. Assembler page pass: 600 tokens** (`Assembler.swift:456`).
- A "pull everything together" markdown page with sources and 3–5 outstanding items is
  tight at 600 tokens (about 450 words).
- Proposal: `min(1_500, contextTokens/4)`. Low priority, NEW.

### 2.3 Covered, and nothing to add

- 26: KnowledgeAsker fitting → P4-08.
- 27: Gmail defaults → P1-09.
- 28: context grow-only and prefix reuse → P0-18.
- `inputTooLong` thrown instead of trimming (`NotesModelRuntime.swift:515,586`) → P1-10a's
  fitter.
- Codex usage-limit memory → P1-12.
- Persona short card first paragraph (Q8) and "wait for yes before `schedule.create`" (Q6)
  → P4-03.
- Routine "three sentences" → Q12, Phase 4.
- Housekeeping, 30: `Limits.cloudTool` (`RealtimeAgent.swift:26,364-369`) sits under
  `case .calendar, .mail, .files, .drive, .computer`, where `if case .toolLoop = intent` is
  never true. Delete it with P1-06.

### 2.4 HELPS (keep, with the reason)

- **Notes/agent llama runtime.**
  - `idleUnload` 10 min: AGENTS.md; 2.7 GB on a 16 GB Mac.
  - `maxContextTokens` 32K: memory.
  - `contextHeadroom` 256.
  - `minContextTokens` 2,048.
- **Model library.**
  - Disk reserve of 4 GB (`ModelDownloader.swift:40`): it protects macOS. The bypass needs
    confirmation.
  - `ModelFitEstimator` system reserve (max 3 GB, 30%) and app resident 1.5 GB.
  - `auxiliaryHeadSizeCeiling` 1 GB, which is what catches `mtp-` draft heads.
- **Residency.** Pressure unload order notes → diarization, never wake/ASR.
- **Memory store.** Budgets of 2,400 / 4,000 characters and 300 characters per entry.
  (M) 206 characters are used, so they never fire. Per-path prompt limits: voice 300,
  planner 3,400.
- **Voice lane.**
  - Answer 256 tokens and a 25 s deadline. Spoken prose; P0-09 fixes the 280-character
    speech cap separately.
  - Route pass 64 tokens.
  - Planner voice rule "under 220 characters".
- **MeetingAgent.** `maxLookupCharacters` 1,200 (a prompt sized before the result
  existed). `AgentPolicy.live` has 1 round and no reads (a read about the wrong minute).
- **Function calling.**
  - Needle floors of 0.3 / 0.35 / 0.5. Measured: confidence is not comparable across tool
    sets.
  - The local proposer's 0.65: self-reported, so only the hedge is meaningful.
  - `maxTools` 8: measured prefill and the 8K context.
  - `maxCalls` 3, value length 240.
  - Card caps: 1 outstanding, 3 per 600 s, 20 s after an agent turn, ≥ 12 characters.
  - NeedleServer: request 8 s, start 20 s, idle 600 s, 3 start attempts.
  - These all fit the approval model and the "may only add" rule.
- **Outputs.**
  - ACP and Codex output 32 KiB.
  - VisionHandoff 320 tokens.
  - Workspace result 2,000 characters (but see item 10).
  - gws 60 s default and 10 s probe.
- **Routines.** 180 s and 8 calls (`AgentSchedule.swift:40`), `maxRoundsBound` 8, 384
  tokens under the memory-review grammar. Unattended work needs a bound.
- **Consent and defaults.**
  - `agentAutoRunReadTools = true`: the permission model in AGENTS.md.
  - `knowledgeGraphCloudConsent` and `visionCloudConsent` default false: separate,
    per-feature consent, required by AGENTS.md ("a brief allowed for a local reader is not
    allowed for a cloud one").
  - `agentAutoSearchFiles` / `agentAllowComputerControl` false: approvals for clicks.
- **Session.** 30-minute idle boundary, with compaction to a 1,500-character summary, 120
  stored messages and 12,000 characters per stored message.
- **Prompt sections.** Persona `fullLimit` 2,000; skills index 1,200 / 120 per line. They
  keep the stable prefix small for the llama cache.
- **OpenRouter provider.**
  - `contextTokens = min(published − 2,048, 200,000)`.
  - Stream timeout 120 s.
  - 429 is surfaced, not silently re-routed (P0-14: one provider per turn).

---

## 3. Top NEW items for the roadmap

| Proposed task title | Phase | Why (evidence) | Size |
|---|---|---|---|
| **One default for the knowledge index; Agent knowledge tools on by default** (items 11, 12) | 1 | Split default at `Settings.swift:1078` vs `KnowledgeIndexer.swift:34`. Fresh installs hide Search and the three knowledge tools, while P1-01's K01–K03 and Y02 depend on them. | h |
| **Tool-result cap and history budget scale with the reader's window; lift the 10,000-character session ceiling** (amend P1-10a; pull P4-08 steps 1–2 into Phase 1) (items 9, 10) | 1 | The typed reader has 262K tokens but gets 2,500 characters of history. P1-10a's planned 1,200-character cap would make `read_doc` and `skills.read` summaries impossible, and P4-08's 12,000 is clipped to 10,000 at `RealtimeAgent.swift:1026`. | h–d |
| **Multi-step notices name the model that actually answers and promise no durations** (item 13) | 0 | On this Mac every multi-step typed request is told "on this Mac it takes a few minutes" while it runs on OpenRouter within an 18 s budget. | h |
| **Graceful exhaustion: rounds = calls + 2, one final answer-only round, no bare "safe limit"; a repeated call becomes a repair** (amend P1-06 / P1-04) (items 18–20) | 1 | At `balanced`, 4 rounds cannot absorb a rebuttal or a repair on a 3-step plan. The call-cap exit drops the verified result. | h |
| **A revised voice objective gets a fresh round deadline** (amend P1-06) (item 17) | 1 | (M) 09-14 follow-ups timed out 2–3 s after arriving because the budget was spent on the superseded revision. | h |
| **`agentCloudConsent` migration: an explicit `.cloud` role counts as consent** (amend P4-09, and consider moving P4-09's lane mapping to Phase 1) (items 14–16) | 4 (lanes → 1) | As written, P4-09 would demote this user's chosen OpenRouter model to on-device. | h |
| **`agentAutoRunReadTools` enforced by the realtime planner; knowledge visibility decoupled from it** (item 22) | 1 | The planner hard-codes `autoApproveReads: true`, so the setting's promise is false. | h |
| **Record each MeetingAgent pass; reader-scaled rounds** (with P0-20 / P4-05) (item 25) | 4 (logging in 0 with P0-20) | 0 proposals across 6 meetings with 4 "You" action items, and nothing says why. | h |
| **Memory review: a refused untargeted update is retried as `remember`** (with P4-07) (item 23) | 4 | 25 of 40 review refusals were this single cause. | h |
| **Never recommend "delete old" before the decode check** (amend P0-02) (item 24) | 0 | The sheet leans toward the policy that deleted the working model whenever free space after the download is under 8 GB. | h |
