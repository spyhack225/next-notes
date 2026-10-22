# Phase 1 — tools that work (P1-01 … P1-31)

## Current implementation and remaining acceptance — 2026-10-03

Most Phase1 tool plumbing is committed. P1-10a-1/2 actual context/result-folding
repairs are bounded verified, while the streamed finish/cutoff contract under
P1-10b remains open. P1-31 is still in progress with no model/default promotion.
P1-05 needs its prescribed repeated full native-tool evaluations; P1-23 lacks
live Y1–Y5/yield latency; P1-28 context sizing is not implemented and live R1/R3
cache measurements remain open. Latest completed quick1264/10 and historical
full17/30 do not meet9/10 or two full≥25/30/all-owner exits. Preserve dated
measurements; see STATUS and [the exact checklist](REMAINING-WORK.md#agent-answers-memory-and-proactive-behavior).

## Model ownership amendment — 2026-09-30

The owner approved independent appropriate models for Agent, meeting notes and
Dictation cleanup, reusing exact verified artifacts through the existing library.
Read [SHARED-BRAIN](../SHARED-BRAIN/00-README.md) and
[MODULES-ACTIVATION](../MODULES-ACTIVATION/00-README.md) before changing
model selection/loading/download/deletion. Their revised SB tasks own artifact
identity, role independence and request binding; this roadmap owns Agent behavior,
latency/full duplex and capacity. Coordinate shared files in BUILD-ORDER.

Existing one-resident-file/Agent-centric descriptions below are baseline or migration
constraints, not permission to force meetingNotes or cleanup onto the Agent choice.
Keep existing tokens and per-role cloud IDs/consent. MiniCPM cleanup + Apple guard/
fallback is concurrent OpenCode work; reuse its verified file, not its settings or
prompt. An awaited deferred swap cannot execute as if the requested file loaded.
Do not add a runtime/store/queue per module or sacrifice a voice lease to background
work. Same weights can serve independent requests; separate contexts/residency are
measured capacity decisions under P3-07. Implementation/gate states remain unchanged.

Written 2026-09-23 against the working tree (uncommitted changes included). Every
`file:line` below was re-opened and checked on that date. Paths are relative to
`Sources/NextNotes/` unless they start with `Scripts/`, `Tests/`, `roadmap/` or `AGENTS.md`.
`ToolLoop` means `Agent/RealtimeAgent+ToolLoop.swift`; `Coordinator` means
`Agent/VoiceConversationCoordinator.swift`. If a line number has drifted, grep for the
symbol named next to it.

---

## Phase overview

### Goal

When the user asks for something a registered, signed-in tool can do, the agent calls that
tool and answers from its result, in plain words, within a bounded time. It does not deny,
does not offer instead of acting, does not print tool syntax or tool ids, and does not stop
halfway with "took too long". Progress is measured by one number: the live real-model eval
built in P1-01 (`--selftest-toolloop-live`, 30 canonical requests).

### What the user sees today

| When (UTC) | User | Agent | Cause (finding) |
|---|---|---|---|
| 09-22 00:58–01:01 | "Summarize my last emails and list me my events for tomorrow", then "yes", "use them", "i am telling you to use your tools" | "I don't have access to your email or calendar data without a tool call … would you like me to do that?" — five times, while `gws` was signed in with a refresh token and Gmail/Calendar scopes | Typed first pass has no tools and 112 tokens; no typed pending intent (T3) |
| 09-23 06:37 | "Every night at 10, remind me to put the book out" | `name="reminders">` | ChatML for every model, special tokens stripped, Hermes-only parser; the fragment is returned as the answer (T2, T4) |
| 09-23 06:39 | "Can you make a document that summarize everything that you know about me" | `name="search_knowledge"> name="query">user …` | same (T2, T4) |
| 09-15 01:13 | "Check my email, check the last email and then do a summary" | "No message matches older:1d. I stopped the tool plan because it took too long. Remaining steps are unfinished." | 18 s for the whole typed plan (T5); invented Gmail operator, no repair (T12, T6) |
| 09-14 16:54 | "open Claude" | "The tool computer.open_app did not run: Nothing is connected that can do “No application named Claude Code is installed.”" ×2 | Any tool error ends the turn; "not installed" rendered as an access problem; tool id shown (T6, T14) |
| 09-19 23:05 | "can you open another note for me" | "I do not have the tool to create new Google Docs or Notes" (`create_doc` registered) | Keyword top-24 filter dropped the tool; the prose roster still names it (T7) |
| 09-22 03:00 | "1. Check the map 2. Open Google Chrome 3. Write an email" | "… Use filesystem.find to search …" | tool id leaked (T14) |

Aggregate (report D §4): of 153 real requests, 27% got a substantive first reply; of 20
clean requests graded by hand, 3 were fully useful. Every existing tool-loop self-test uses a
scripted fake model, which is how all of this coexists with `TOOLLOOP_OK`.

Evidence: `roadmap/done/agent-analysis-2026-09-23/B-tools.md` §2–§3 (defects D1–D15, evidence
digest), decision document `roadmap/done/agent-analysis-2026-09-23/AGENT-QUALITY-ANALYSIS-2026-09-23.md` §3.2 (T1–T15) and
§5 Phase 1.

### Phase 0 tasks that must be done first

Do not start P1-02 onwards until these are ticked in `STATUS.md`. P1-01 may be *written*
before them, but its baseline is only meaningful after them.

| Task | Why Phase 1 needs it | How to check it is done |
|---|---|---|
| **P0-01** model state repaired on this Mac | Without an answerable Agent-role model the live eval prints `TOOLLOOP_LIVE_ABSENT` and nothing in this phase can be graded | `Scripts/run-selftest.sh --selftest-llm-metal` prints `LLM_METAL_AGENT_ROLE: Qwen3-4B-Instruct-2507 generated N token(s)` then `LLM_METAL_OK` (P0-01 recommends `unsloth/Qwen3-4B-Instruct-2507-GGUF` Q4_K_M; K2-Horizon cannot open on b10621, see P0-16), and `--selftest-agent-answers` → `AGENT_ANSWERS_OK` (P0-14b) |
| **P0-03** roles resolve only answerable models | The eval resolves "whatever the Agent role resolves to"; an MTP draft head must never be that | `Scripts/run-selftest.sh --selftest-model-roles` → `MODEL_ROLES_OK` including the auxiliary-file case |
| **P0-04** per-family chat templates; special tokens preserved | Without it every tool call from a non-Qwen GGUF leaks as `name="…">` and the parser work in P1-04/P1-05 is graded against corrupted text | `Scripts/run-selftest.sh --selftest-chat-template` → `CHAT_TEMPLATE_OK` |
| **P0-05** typed 112-token cap lifted | P1-02 folds typed answers into the planner; the eval's answer-only cases are otherwise truncated | `--selftest-toolloop-production` asserts typed `maxTokens ≥ localAnswerTokenBudget` |
| **P0-07** `mayCommitEffect` write-time gate | P1-05's Apple FM tool bridge and P1-07's escalations must call the same effect gate the loop uses | `--selftest-concurrent-voice` → `CONCURRENT_VOICE_OK` with the parked-write case |
| **P0-11** self-tests do not write user stores | The eval drives the real `RealtimeAgent`; it must not add rows to tasks, audit log or memory | `--selftest-store-isolation` → `STORE_ISOLATION_OK` (P0-11); `agent-tasks.json` and `agent-audit.jsonl` unchanged after a run (compare `stat -f %m` before/after) |
| **P0-17** OpenRouter reasoning capped, `finish_reason` read | Needed when the Agent role, or an eval run with `--allow-cloud`, uses OpenRouter. A reasoning model otherwise scores `ERROR`/`UNGROUNDED` because of the plumbing, not the model (G: 4 of 6 turns) | `--selftest-openrouter-contract` → `OPENROUTER_CONTRACT_OK` |
| **P0-19** no model replies in the disk URL cache | Needed before any `--allow-cloud` eval run, which would otherwise write fixture conversations to `Cache.db` | `--selftest-private-network` → `PRIVATE_NETWORK_OK` |
| **P0-20** (P0-20a…e) unified local usage log | The eval report names the model that answered each pass, and its token counts (step 12) | `Scripts/run-selftest.sh --selftest-usage-log` → `USAGE_LOG_OK` (P0-20e); a typed "Hi" leaves one `usage.jsonl` row with `feature` `agent.typed` |
| P0-18 (soft) llama prefix reuse | Not a blocker. On a local model it cuts every planner round's prefill (estimate: 2.9–3.3 s → 0.3–0.6 s, G N2), which shortens every eval run | `--selftest-llm-prefix-cache` → `LLM_PREFIX_CACHE_OK` |

P0-12 (AGENTS.md stale facts) is not a blocker but P1-03 rewrites the same AGENTS.md
paragraph about aliases and the allowlist; coordinate so the text is written once.

### Source facts re-verified today (some differ from the reports)

1. **`--selftest-toolloop` does not test the realtime planner.** It runs
   `AgentToolLoop.runSelfTest()` (`Agent/AgentToolLoop.swift:179`), which exercises
   `AgentToolLoop.run` — the loop `ScheduledRunner` uses (`Agent/Schedules/ScheduledRunner.swift:275`).
   The typed/voice planner (`runPlannedToolLoop`) is exercised by
   **`--selftest-toolloop-production`** (`RealtimeAgentToolLoopSelfTest.run()`,
   `Agent/RealtimeAgentToolLoopSelfTest.swift:458`, marker `TOOLLOOP_PRODUCTION_OK`). The
   decision document names `--selftest-toolloop` for the parser cases; this phase puts them in
   `--selftest-toolloop-production` and keeps `--selftest-toolloop` green as a regression flag.
2. **Aliases are already resolved before the allowlist** (`ToolLoop:960-964`,
   `AgentToolRegistry.shared.tool(named:)` first, then `allowedIDs.contains(call.name) ||
   allowedIDs.contains(tool.id)`). A miss still abandons the whole plan (`ToolLoop:966`).
   AGENTS.md still describes the old order (P0-12 fixes the text).
3. **"ask app" is word-bounded in practice.** `AgentTurnIntent.explicitlyRequestsOnDeviceModel`
   (`Agent/AgentTurnIntent.swift:112-120`) is a bare `hasPrefix`, but `resolve` also requires
   `localModelPrompt(for:)` (`:72-97`), which checks the next character, so "ask apple…" does
   not match. B's "not word-bounded" note is stale; the "ask the agent/app" defect (T11) is real.
4. **The self-test harness refuses to adopt the user's saved model.**
   `NotesModelRuntime.adoptSavedSelectionIfNeeded` returns early under `SelfTest.isRunning`
   (`Formatting/LLM/NotesModelRuntime.swift:200-205`), and so does
   `InstalledModelLibrary.adoptInRuntime` (`Support/ModelLibrary/InstalledModelLibrary.swift:125-130`).
   Under the harness `.appLLM` therefore means the built-in Gemma spec, which is not on disk,
   and `LLMProviders.resolve` silently falls to Apple FM. The live eval must adopt the role's
   model explicitly (P1-01 step 4).
5. **The streamed llama path cannot take a grammar today.** Only
   `NotesModelRuntime.complete(system:user:maxTokens:grammar:)` (`:407`) passes one; the stream
   path builds its sampler with `grammar: nil` (`:599`). P1-05 adds it.
6. **`GBNFSchema` has no union type** (`Formatting/LLM/GBNFGrammar.swift:63-72`: string,
   integer, boolean, date, enumeration, nullable, array, object). A per-tool argument grammar
   needs one; P1-05 adds `.oneOf`.
7. **Apple's `Tool` protocol was rejected in a comment that no longer holds.**
   `Agent/LLMProviderTools.swift:10-14` says it "wants a compile-time `@Generable` argument type
   per tool" and "performs the call itself". The macOS 26 SDK has `DynamicGenerationSchema`
   (runtime schemas, `anyOf`, optional properties) and `GeneratedContent` conforms to
   `Generable`, so `Tool` with `Arguments = GeneratedContent` works for a runtime catalogue;
   and the tool's `call` can be a bridge into `AgentToolExecutor`, which keeps the approval
   boundary. P1-05 uses it and rewrites that comment.
8. **`WorkspaceToolRunner` already has a `payload.headers[]` reader** (`gmailHeader`,
   `Agent/WorkspaceToolRunner.swift:458-464`), used only for the draft check (`:372-375`).
   `searchEmail` uses `header()` (`:450-456`), which looks only at top-level keys and a
   `headers` *object*, which is why every sender reads "unknown sender".
9. **`AgentToolExecutor` has no seam for a fake.** Every call reaches the real Workspace CLI,
   Finder, the browser or the approval card. P1-01 adds one (`fakeForTesting`), honoured only
   under `SelfTest.isRunning`.
10. **`OpenAICompatibleLLMProvider` already reassembles structured `tool_calls`**
    (`ToolCallAccumulator`, `Formatting/LLM/OpenAICompatibleLLMProvider.swift:232-258`) and
    re-renders them as Hermes tags; `OpenRouterLLMProvider.chatBody` (`OpenRouterLLMProvider.swift:564-583`)
    never sends a `tools` field. `OpenRouterModel.supportsTools` exists (`:226`).
11. **Apple FM's window is 8,192 tokens on the dev Mac, not 4,096** (G §2.2, from
    `tokengenerationcore`'s log, 2026-09-23). The app hard-codes the smaller number:
    `FoundationModelLLMProvider.contextTokens = 4_096` (`Formatting/LLM/FoundationModelLLMProvider.swift:13`,
    commented "The documented window"). The SDK exposes the real value as
    `SystemLanguageModel.default.contextSize`. It is declared in the macOS SDK's
    `FoundationModels.swiftinterface` and back-deployed to macOS 26.0. P1-10a step 0 makes the
    provider read it at runtime, keeping 4,096 only as the fallback. Every "4,096" in this phase
    describes a reader of that size (scripted tests keep it as the worst case), not a fact about
    Apple FM.
12. **Report G (2026-09-23 evening, real turns on three models) added three Phase 1 tasks:**
    - P1-11: fabricated "I ran get_agenda" claims (G N5);
    - P1-12: Codex retried while out of quota, and the fallback ignores the Agent role (G N6);
    - P1-13: "google calendar" opened google.com (G N7).

    In G, 0 of 11 tool-needing turns produced a parsed, executed model tool call on any of the three
    models. Only deterministic shortcuts acted.
13. **The caps/gates audits (H1–H3, 2026-09-23) added five Phase 1 tasks and amended six**
    (H-audit 2026-09-23; `roadmap/done/agent-analysis-2026-09-23/H1-caps-model-tools.md`,
    `H2-caps-voice.md`, `H3-caps-proactive-memory.md`):
    - P1-14: the echo filter erases one-word answers that repeat the agent's words (H2 V1);
    - P1-15: goodbye is a substring match that closes the session mid-request (H2 V16);
    - P1-16: approval cards vanish after 8 s while still pending (H3 #5, #6);
    - P1-17: "Look things up without asking" is ignored by the planner but hides knowledge tools (H1 #22);
    - P1-18: history is fixed in characters with a silent 10,000 ceiling (H1 #9; takes over P4-08 steps 1–2).
    Amended in place, each marked "(H-audit 2026-09-23)": P1-02 step 6 (calls P0-05's
    `AgentAnswerBudget` instead of defining its own cap), P1-03 (knowledge-tool availability),
    P1-04 (repeated call → one "already ran" note), P1-06 (rounds = calls + 2, one final
    answer-only round, revision refill, dead `Limits.cloudTool`), P1-07 (depends on P1-14; one
    shared acknowledgment vocabulary), P1-10 (reader-scaled result cap; error sentences keyed on
    the outcome; speakable answers spoken).
14. **P0-05 landed without P0-17** (2026-09-24, `6ad6ade`; STATUS.md: P0-17 `todo`), although the
    owner paired them. Larger `maxTokens` on an OpenRouter reasoning model is spent on hidden
    reasoning until P0-17 caps it: no `--allow-cloud` eval run in this phase until P0-17 is `done`.

### Order and dependency graph

```
        (Phase 0: P0-01, P0-03, P0-04, P0-05, P0-07, P0-11)
                              │
                           P1-01  live eval + grader + fakes          ← FIRST; baseline report
                    ┌─────────┼───────────────┬──────────────┐
                 P1-02       P1-03          P1-09          P1-10(a: result cap)
          (typed header    (manifest)      (Gmail)
           pass removed,      │
           PendingAction)     │
                 │     ┌──────┼──────────┬───────────┐
               P1-06   │    P1-04      P1-08       P1-07
            (budgets)  │  (parser,    (shortcuts,  (voice rebuttal, gates,
                       │   error       "ask the     worker question →
                       │   split,      agent")      pending action; needs
                       │   repair)                  P1-02's PendingAction)
                       │      │
                       └──► P1-10(b: one renderer, no ids; needs P1-04's error split)
                              │
                           P1-05  native / constrained tool calling (needs P1-03, P1-04, P0-04, P0-07)

   Added from report G (2026-09-23):
   P1-01 + P1-04 ──► P1-11  no fabricated tool claims (soft: P1-10b)
   P0-14 ─────────► P1-12  Codex quota memory; fallback follows the Agent role (soft: P1-10b)
   P1-08 ─────────► P1-13  two-word sites; leftover nouns go to the planner

   Added from the H audits (H-audit 2026-09-23):
   P1-06 ─────────► P1-04  (soft) the second repeated call ends through P1-06's final round
   P1-01 ─────────► P1-17  planner honours "look things up"; knowledge gate = index + tools switch ──► P1-03 (soft)
   P1-10a ────────► P1-18  history budget from the reader's window (moves P4-08 steps 1–2)
   none ──────────► P1-14  echo filter keeps short answers ──► P1-07 (hard)
   none ──────────► P1-15  goodbye by exact signature
   none ──────────► P1-16  pending approvals stay visible (badge) ──► P3-08, P3-09

   Added from the OpenMuse comparison (2026-09-27, REVIEW-LOG §7):
   none ──────────► P1-19  approval bound to account, time and age (soft: P1-16) ──► P3-08, P6-06
   none ──────────► P1-20  one Send/Stop control, kept draft, visible interrupt ──► P3-11
   none ──────────► P1-21  a write that never answered is "not sure", read back first ──► P6-06 (soft)
   P1-21 ─────────► P1-22  Google writes carry receipt-derived ids (measure first)
   none ──────────► P1-23  the person's hand wins: computer control yields (soft: P1-16)

   Added from the live log audit (J, 2026-09-27):
   P1-11 + P1-07 ─► P1-24  answers about mail/calendar/Drive come from a read; short offers are offers
   none ──────────► P1-25  ids in actions come from something read or said
   none ──────────► P1-26  "Clear conversation" starts a new one instead of erasing every past one
   P1-01 ─────────► P1-27  the owner's failed requests join the Phase 1 gate (O01–O10)
   none ──────────► P1-28  the prompt cache survives a conversation (size once, stable front)
   none ──────────► P1-29  one turn id across the existing logs; card and clear events recorded
   none ──────────► P1-30  memory review keeps no one else's words
   P1-01 + P1-03 + P1-05 + P1-06 ──► P1-31  Needle executes first tool; mid-sized LLM answers/continues
   P4-01 moves into Phase 1 (owner, 2026-09-27): run it before P2-01's baseline
```

Recommended execution order (one task at a time, eval after each):
**P1-01 → P1-02 → P1-06 → P1-03 → P1-17 → P1-04 → P1-10 → P1-18 → P1-11 → P1-08 → P1-13 → P1-09 → P1-12 → P1-14 → P1-15 → P1-16 → P1-19 → P1-07 → P1-05**, with P1-20 anywhere. **P1-21 as early as possible** (it stops a duplicate send that can happen today), then P1-22; P1-23 anywhere after P1-16. (J audit, 2026-09-27) **P1-27 next**, to record the baseline; then **P4-01** (moved in), **P1-24**, **P1-25** and **P1-26**; P1-28, P1-29 and P1-30 anywhere. P1-31 follows its four dependencies and runs before a Needle-first default is considered. P1-24 and P4-01 before the gate runs.
P1-11 comes right after the renderer because it shares the planner's text-only return. P1-13 follows
P1-08, which it extends. P1-12 is independent and can move earlier if the owner wants Codex back.
(H-audit 2026-09-23) P1-06 precedes P1-04 because P1-04's second repeated call ends through
P1-06's final answer-only round. P1-17 follows P1-03 so the manifest reads the two-switch
knowledge gate once it exists (P1-03 carries a note for either order). P1-18 follows P1-10
because it needs P1-10a's runtime Apple FM window. P1-14, P1-15 and P1-16 are independent of the
tool loop; P1-14 must be `done` before P1-07 starts, and P1-16 lands beside P1-07.
(OpenMuse 2026-09-27) P1-19 and P1-20 are independent of the tool loop and of each other; P1-19
lands after P1-16 so the refusal sentence has a card that stays on screen, and P1-20 can land any
time.
This is the decision document's §7 ranking (eval + T3 + T5, then the manifest, then the
parser/repair loop) with native tool calling last because it consumes the manifest.

### Types this phase introduces

| Type | File (new unless noted) | Task | Consumed by |
|---|---|---|---|
| `ToolLoopLiveEval` (+ `LiveEvalCase`, `LiveEvalVerdict`, `LiveEvalGrader`, `LiveEvalFixtures`) | `Agent/LiveEval/*.swift` | P1-01 | every later task |
| `AgentToolExecutor.fakeForTesting` | `Agent/Tools/AgentToolExecutor.swift` (edit) | P1-01 | P1-01, P1-04, P1-05, P1-10 self-tests |
| `PendingAction` | `Agent/PendingAction.swift` | P1-02 | P1-02 (typed), P1-07 (voice) |
| `AgentCapabilityManifest`, `AgentCapabilityInputs`, `AgentCapabilityManifestBuilder`, `AgentIntentClass` | `Agent/AgentCapabilityManifest.swift` | P1-03 | planner, grounding, refusal guard, allowlist, voice gates, "what can you do", P1-05, P3-05 |
| `ToolStepOutcome`, `ToolRepair`, `ToolErrorClassifier`, `ToolCallNameResolver` | `Agent/ToolStepOutcome.swift` | P1-04 | loop, P1-05 bridge, P1-10 renderer |
| `AgentPlannerBackend`, `PlannerRound`, `ToolStepRunner`, `FoundationModelsToolBridge` | `Agent/Planner/*.swift` | P1-05 | loop |
| `ToolLoopBudget` | `Agent/ToolLoopBudget.swift` | P1-06 | loop, P1-05 |
| `AgentReplyRenderer`, `ToolResultBudget` | `Agent/AgentReplyRenderer.swift` | P1-10 | every user-facing tool-loop reply |
| `GmailQuery`, `MailReferenceCache`, `WorkspaceCLIRunning` | `Agent/WorkspaceToolRunner.swift` (edit), `Agent/GoogleWorkspaceCLI.swift` (edit) | P1-09 | Workspace tools |
| `ToolClaimGuard` | `Agent/ToolClaimGuard.swift` | P1-11 | planner and first pass; the history view; P4-02, P4-03 must keep it |
| `CodexQuotaStore`, `CodexComputerUseReadiness.outOfQuota` | `Agent/Backend/CodexQuotaStore.swift`, `CodexComputerUse.swift` (edit) | P1-12 | Codex hand-off, Settings row |
| `knownSitePhrases`, `siteMatch(in:)` | `Agent/AgentDirectIntent.swift` (edit) | P1-13 | direct-intent shortcut |
| `echoTailSeconds`, the question exemption | `Agent/RealtimeAudioSession.swift` (edit) | P1-14 | capture layer; P1-07 |
| `VoiceTurnPolicy.closingSignatures`, `closingLeads`, `isClosingTurn` | `Activation/VoiceTurnPolicy.swift` (edit) | P1-15 | goodbye branch; P3-10 |
| `IslandState.Kind.pendingApproval`, `PermissionGate.islandProposal(for:)` | `UI/Island/IslandState.swift`, `Agent/Permissions/PermissionGate.swift` (edit) | P1-16 | island; P3-08, P3-09 |
| `RealtimeAgent.readsRunWithoutAsking` | `Agent/RealtimeAgent.swift` (edit) | P1-17 | planner, direct intents, `runTool` |
| `AgentHistoryBudget` | `Agent/AgentHistoryBudget.swift` | P1-18 | typed first pass, planner, `.localModel`; P4-08 |
| `VoiceTurnPolicy.acknowledgmentKeys` | `Activation/VoiceTurnPolicy.swift` (edit) | P1-07 (H-audit) | voice pending actions; P3-08 `approveKeys` |
| `finalAnswerRound(reason:)` (local to the planner) | `Agent/RealtimeAgent+ToolLoop.swift` (edit) | P1-06 (H-audit) | P1-04's repeated-call exit |

`AgentCapabilityManifest` and `mayCommitEffect` are the architecture names from the decision
document §4; use them exactly.

### Phase exit gate

All of the following, recorded in `STATUS.md` with the report paths:

1. **`--selftest-toolloop-live` ≥ 25/30 on the Agent-role model** (Qwen3-4B-Instruct-2507 Q4_K_M on this Mac,
   per P0-01's recommendation, unless the owner chose otherwise) in **two consecutive full runs**, each with **0 `LEAK`** and
   **0 `ERROR`** verdicts. Both reports saved under `Tests/Reports/toolloop-live/`.
2. An Apple Foundation Models run (`--model apple`) recorded beside it. Not gated; target
   ≥ 20/30 (estimate). Its window is read at runtime after P1-10a: 8,192 tokens measured on the dev
   Mac, not the 4,096 the code assumed (fact 11). Its run must show **0 `FABRICATED`** (P1-11).
2b. **Full runs only here.** The two gate runs and the Apple FM run are full 30-case runs. Per-task
   gates use `--quick`, a fixed 10-case subset (P1-01 step 8b, about 20 minutes or less), because one
   full run takes about 2.5 h (9,300 s budget).
3. These flags print their `…_OK` line (run one at a time):
   `--selftest-toolloop-live-grader`, `--selftest-capability-manifest`,
   `--selftest-native-tools`, `--selftest-toolloop`, `--selftest-toolloop-production`,
   `--selftest-tool-awareness`, `--selftest-voice-grounding`, `--selftest-voice-turn-routing`,
   `--selftest-voice-conversation`, `--selftest-concurrent-voice`, `--selftest-gws`,
   `--selftest-persona`, `--selftest-ui-strings`, `--selftest-file-index`,
   `--selftest-function-calls`, `--selftest-memory`, `--selftest-schedule`,
   `--selftest-acp-confirm`, `--selftest-mcp`, `--selftest-composio`,
   `--selftest-model-roles`, `--selftest-chat-template`,
   and (H-audit 2026-09-23) `--selftest-duplex`, `--selftest-voice-turns`, `--selftest-island`,
   `--selftest-voice-work-lifecycle`, `--selftest-ask`.
   (`--selftest-function-calls` and `--selftest-mcp`/`--selftest-composio` may print their
   documented `…_ABSENT` when Needle or a server is missing; that is SKIP, not a pass.)
4. `make test` green, and `make acceptance TIER=core` shows no FAIL that the Phase 0 exit run
   did not already show.
5. AGENTS.md: new flags in the list; the realtime tool-loop paragraph ("In the realtime tool
   loop, an alias is checked against the allowlist…") rewritten to describe the manifest and
   the repair loop.
6. If Needle-first is proposed as the normal Agent path, P1-31's paired quality and latency
   comparison is recorded, its negative cases pass, and the two full gate runs in item 1 use
   that exact path. A targeted improvement alone does not change the default.

### Rules every task in this phase inherits (from AGENTS.md)

- Build only with `make build` (the repo is iCloud-synced; on "input file was modified during
  the build" wait a few seconds and retry). Install with `make install OPEN=0`. Never bare
  `swift build`, never run the `.app` from the repo folder, never bare-invoke the binary.
- Self-tests: `Scripts/run-selftest.sh --selftest-<name> [args]`, foreground, one at a time.
  None of this phase's flags needs `--via-open` (no microphone, no system audio).
- A self-test must FAIL when the thing it names did not happen; a missing model prints
  `…_ABSENT`, never `…_OK`. A self-test flag is never a flag's argument
  (`SelfTest.value(after:)` refuses `--` values).
- Self-tests never write the user's stores. `AgentAuditLog` and `AgentSession` are already
  in-memory under the harness (`Agent/Activity/AgentActivityStore.swift:148-151,174`;
  `Agent/RealtimeAgent.swift:816-822`); tasks and memory are covered by P0-11. Do not add a
  code path that bypasses those checks.
- `MainActor.assumeIsolated` crashes the process; use `await MainActor.run`.
- "A finished feature with no call site looks exactly like a working one": after adding any
  new type, grep for its production callers before ticking the task.
- "Grep for a producer before believing an enum case is reachable":
  `AgentTurnIntent.resolve` only produces `.delegate`, `.localModel`, `.toolLoop`.
- On the voice path "a deterministic gate may only add, never subtract", and suppression only
  on exact signatures (`VoiceTurnPolicy.knownNoiseFragments`).
- The agent never sends in the user's name without a card: every call still goes through
  `AgentToolExecutor.run`; an unknown tool resolves to the most cautious class.
- `gws` writes success noise to stderr; judge by exit code. `gws … --dry-run` does not
  validate timestamps; Calendar times go through `WorkspaceToolRunner.rfc3339`.
- The Agent's name is never written into a prompt (`--selftest-persona` fails on it).
- New self-test flags: register in `NextNotesApp.runRequestedSelfTest`, add to the AGENTS.md
  flag list, add to `Scripts/acceptance.sh` in the tier named by the task.

---

### P1-01 — Live real-model eval `--selftest-toolloop-live` (~30 canonical requests)

**Finding(s):** B §4 rec. 5; decision doc §5 Phase 1 row 1, §6 "`--selftest-toolloop` is green on a scripted fake"; implementation brief agent F.
**Effort:** 2–3 days. **Depends on:** none to write; P0-01, P0-03, P0-04, P0-05, P0-11 before the baseline is recorded. **Unblocks:** every other P1 task (each is graded by this eval), P4-02, P4-03 (eval cases N01/N02).

**Why (what the user experiences today):** Every tool-loop self-test uses a scripted model
(`ToolLoopTestProvider`, `Agent/RealtimeAgentToolLoopSelfTest.swift:664-723`), so
`TOOLLOOP_OK` and `TOOLLOOP_PRODUCTION_OK` print while real users get "I don't have access to
your email" five times in a row (09-22) and `name="reminders">` as a reply (09-23 06:37).
There is no number that says whether a change made the agent better. This task builds that
number: 30 real requests through the real `RealtimeAgent.handle` on the real model, with every
tool replaced by a fixture so nothing is sent and nothing personal is read.

**Files you will change:**
- New `Agent/LiveEval/ToolLoopLiveEval.swift` — runner, model resolution, report writer.
- New `Agent/LiveEval/ToolLoopLiveEvalCases.swift` — the 30 cases (data only).
- New `Agent/LiveEval/ToolLoopLiveEvalFixtures.swift` — fake tool outputs, fake file retrieval.
- New `Agent/LiveEval/ToolLoopLiveEvalGrader.swift` — verdicts, pattern lists, grader self-test.
- `Agent/Tools/AgentToolExecutor.swift` — add the `fakeForTesting` seam.
- `Agent/RealtimeAgent.swift` — add `fileRetrievalForTesting` and `plannerTraceForTesting`
  properties beside `localModelProviderForTesting` (`:118-121`).
- `Agent/RealtimeAgent+ToolLoop.swift` — `runLocate` uses the file-retrieval seam
  (`:1151`); planner emits trace events; `plannableTools` honours a gates override.
- `NextNotesApp.swift` — register `--selftest-toolloop-live` and
  `--selftest-toolloop-live-grader`; add the timeout rule in `SelfTest.defaultTimeout`
  (`:142-157`).
- `Scripts/acceptance.sh` — INTEGRATION entries.
- `AGENTS.md` — flag list, one paragraph on what the eval is and is not.
- New directory `Tests/Reports/toolloop-live/` (reports only).

**Read for context (do not change):** `Agent/RealtimeAgentToolLoopSelfTest.swift` (harness
style, `ToolLoopTestProvider`), `Support/ModelRoles/ModelRoleStore.swift:341` (`choice(for:)`),
`:534-590` (`provider(for:)` — it *writes* `activeAgentModelID`, which is why the eval does not
call it), `Formatting/LLM/LlamaLLMProvider.swift`, `Formatting/LLM/FoundationModelLLMProvider.swift`,
`Knowledge/Files/FileIndexTools.swift:12-26` (`FileRetrieving`), `Agent/Backend/CodexComputerUse.swift:184-202`.

**Current behaviour:**
- No real-model harness exists. `RealtimeAgent.localModelProviderForTesting`
  (`Agent/RealtimeAgent.swift:118`) is the only model seam, and every user of it passes a
  scripted provider.
- `AgentToolExecutor.run` (`Agent/Tools/AgentToolExecutor.swift:7-19`) has no fake: it looks
  the tool up and goes straight to the real executor and the approval card.
- `runLocate` builds `LiveFileRetrieval()` inline (`ToolLoop:1151`), which reads the user's
  real file index and bypasses the executor.
- `plannableTools()` (`ToolLoop:635-649`) reads live switches
  (`MemorySnapshotCache.shared.isEnabled`, `Settings.shared.agentSchedulesEnabled`,
  `KnowledgeToolGate.isAvailable`, `SkillToolGate.isAvailable`), so the tool roster in a test
  depends on the user's settings.

**Target behaviour:**
- `Scripts/run-selftest.sh --selftest-toolloop-live` runs 30 cases on the model the Agent role
  resolves to, prints one `TOOLLOOP_LIVE_CASE` line per case, a class tally, a
  `TOOLLOOP_LIVE_SCORE n/30` line and exactly one final marker:
  `TOOLLOOP_LIVE_OK: n/30 on <model>` when n ≥ the pass bar (default 25),
  `TOOLLOOP_LIVE_FAILED: <reason>` otherwise, `TOOLLOOP_LIVE_ABSENT: <reason>` when no model
  resolves.
- No real tool runs: every `AgentToolExecutor.run` call during the eval is answered by a
  fixture; no approval card appears; no mail is read or sent; nothing is written to
  `agent-audit.jsonl`, `agent-conversation.json`, `agent-tasks.json` or memory.
- A markdown report plus a JSONL sidecar are written to the path given by `--report`.
- `--selftest-toolloop-live-grader` proves, with no model, that each failure class is
  detected on canned replies.
- `--quick` runs a fixed 10-case subset (step 8b) in at most 20 minutes (target) and prints
  `TOOLLOOP_LIVE_SCORE n/10 (quick)`. It is the **per-task gate** for every Phase 1 and Phase 4 task.
  The full 30 remain the **phase gate** (two consecutive full runs at the Phase 1 exit).

**Steps:**

1. **Executor seam.** In `Agent/Tools/AgentToolExecutor.swift` add, above `run`:
   ```swift
   /// A self-test's stand-in for every tool, consulted after the registry lookup and before
   /// any validation, card or executor. Ignored outside a self-test, so a stray assignment in
   /// production can never replace a real action with a fixture.
   typealias FakeToolRun = @MainActor @Sendable (AgentTool, [String: String]) async throws -> AgentToolResult
   @MainActor static var fakeForTesting: FakeToolRun?
   ```
   In `run`, immediately after `guard let tool = AgentToolRegistry.shared.tool(named: name)
   else { throw … }` (`:19-21`), insert:
   ```swift
   if SelfTest.isRunning, let fake = fakeForTesting {
       return try await fake(tool, arguments)
   }
   ```
   Unknown names still throw `AgentError.unknownTool` (the eval must see those).

2. **File-retrieval and planner-trace seams** in `Agent/RealtimeAgent.swift` next to
   `localModelProviderForTesting` (`:118`):
   ```swift
   /// The file index the direct "find / open <name>" shortcut reads. Nil in production.
   var fileRetrievalForTesting: (any FileRetrieving)?
   /// Receives one event per planner round and per rejected call. Nil in production.
   var plannerTraceForTesting: (@MainActor (PlannerTraceEvent) -> Void)?
   ```
   and a small enum in `ToolLoop` (or a new file `Agent/PlannerTraceEvent.swift`):
   ```swift
   enum PlannerTraceEvent: Sendable {
       case round(index: Int, systemCharacters: Int, userCharacters: Int, maxTokens: Int, raw: String, seconds: Double)
       case rejectedCall(name: String, reason: String)
       case stopped(reason: String)   // timeout, repeated step, safe limit, cancelled
   }
   ```
   Emit `.round` after each completion in `runPlannedToolLoop` (after `:914`, with the raw
   `completionText`) and in the first pass of `runModelTurn` (after `:440`); `.rejectedCall`
   where the loop returns "requested an unavailable tool" (`:966`); `.stopped` at each
   `incomplete(…)` / "I stopped the tool plan" return. In `runLocate` (`:1151`) replace
   `let files = LiveFileRetrieval()` with
   `let files: any FileRetrieving = fileRetrievalForTesting ?? LiveFileRetrieval()`.

3. **Tool gates override.** In `ToolLoop` add
   ```swift
   struct PlannerToolGates: Sendable, Equatable { var memory, schedules, knowledge, skills: Bool }
   @MainActor static var toolGatesForTesting: PlannerToolGates?
   ```
   and in `plannableTools(knowledgeTools:)` (`:635-649`) read each of the four switches from
   `toolGatesForTesting` when it is non-nil and `SelfTest.isRunning`. (P1-03 replaces this with
   `AgentCapabilityInputs`; keep the eval using whichever exists.)

4. **Model resolution** (`ToolLoopLiveEval.resolveModel(argument:) async -> ResolvedModel?`).
   The eval must answer with what the Agent role resolves to, without mutating any setting:
   ```swift
   struct ResolvedModel { let provider: any LLMProvider; let label: String; let roleChoice: String; let isFallback: Bool }
   ```
   - `--model apple` → `FoundationModelLLMProvider()` if
     `FoundationModelFormatter.unavailableReason == nil`, else nil.
   - `--model <installed id>` → `InstalledModelLibrary.shared.usableModels.first { $0.id == id }`,
     then step "adopt" below.
   - default (`--model agent` or absent): `let choice = ModelRoleStore.shared.choice(for: .agent)`
     (`ModelRoleStore.swift:341`; do **not** call `provider(for:)`, which writes
     `activeAgentModelID` at `:575-577`):
     - `.installedModel(id)` → the usable model with that id (P0-03 guarantees drafts are not
       usable); adopt it.
     - `.appleFoundation` → Apple FM as above.
     - `.localServer(endpointID, modelID)` → `ModelRoleStore.shared.localServerProviderForAgentRole()`
       if its `unavailableReason` is nil.
     - `.builtIn` → the built-in spec if `NotesModels.spec.isDownloaded`; adopt nil.
     - `.cloud`, `.app` → nil unless `--allow-cloud` is passed (the eval is local by default;
       a cloud run costs money and sends fixture text off the Mac).
     - If the configured choice yields nil, try production's fallback
       (`LLMProviders.resolve(preferring: .appLLM)` semantics: installed active model, then
       Apple FM) and mark `isFallback = true`. This mirrors what a user gets today.
   - **Adopt** an installed model: `await NotesModelRuntime.shared.useInstalledModel(model)`
     (the harness otherwise keeps the built-in spec, fact 4 above), then
     `LlamaLLMProvider(modelName: model.displayName)`; check `await provider.unavailableReason == nil`.
   - Nothing resolves → print `TOOLLOOP_LIVE_ABSENT: no answerable model for the Agent role
     (role: <choice.token>)` and exit. **Never** print OK.
   - Print `TOOLLOOP_LIVE_MODEL: <provider.id.rawValue> "<displayModelName>" ctx=<contextTokens>
     role=<choice.token><fallback ? " FALLBACK" : "">`.

5. **Warm-up.** Before case 1, run one untimed completion:
   `try await provider.complete(system: "Reply with the single word OK.", user: "Ready?", maxTokens: 4)`.
   A thrown error here is a real failure, not an absence: print
   `TOOLLOOP_LIVE_FAILED: <model> did not answer a warm-up (<error.localizedDescription>)`.
   For `.appLLM` also `try await NotesModelRuntime.shared.prepareForConversation()` so the
   first case is not charged a cold load (the cold-load budget is not what the eval measures;
   P1-06 has its own test for it).

6. **Wiring the agent under test.**
   ```swift
   let agent = RealtimeAgent.shared
   agent.localModelProviderForTesting = resolved.provider   // the REAL provider; also skips the Codex hand-off (ToolLoop:340)
   agent.toolLoopLimitForTesting = nil                       // production budgets apply
   agent.fileRetrievalForTesting = LiveEvalFixtures.files
   RealtimeAgent.toolGatesForTesting = .init(memory: true, schedules: true, knowledge: true, skills: false)
   AgentToolExecutor.fakeForTesting = fixtures.run            // records every call
   defer { reset all five to nil }
   ```
   Using `localModelProviderForTesting` with the real provider is deliberate: it is the
   production-routing seam, it keeps the eval off the Codex hand-off (which would launch
   another app) and off the multi-step OpenRouter reroute (`ModelRoleStore.swift:731-742`).
   Document this in a comment.

7. **Fixtures** (`ToolLoopLiveEvalFixtures.swift`). One `@MainActor final class LiveEvalFixtures`
   with a call log and a `run(tool:arguments:)` that switches on `tool.id`. All dates are
   computed from `Date()` in the local time zone (`today`, `tomorrow` as `yyyy-MM-dd`). Content
   is invented; it must never contain the user's real data.

   | Tool id(s) | Fixture answer (abridged; keep the exact facts, the graders look for them) |
   |---|---|
   | `get_agenda` | date == today → "On <today>:\n- 09:30–10:00 Standup\n- 14:00–15:00 Budget review with Ana\n- 16:30–17:00 Call with Marcus about pricing". date == tomorrow → "- 08:00–08:45 Dentist\n- 15:00–15:45 Design sync\n- 19:00 Dinner with Cyril". Missing date → today. Other dates → "Nothing is booked on <date>." |
   | `search_email` | Six messages, newest first, in the P1-09 target shape: "1) <today> 08:12 · Marcus Lee <marcus@productflo.example> · Pricing sheet v3 — Here is the updated pricing sheet…", "2) Ana Ruiz <ana@example.com> · Deck for Friday — Can you send the deck by Friday?", "3) GitHub · [next-notes] CI passed on main", "4) Cyril · Dinner tomorrow?", "5) Stripe · Your invoice for September", "6) Marcus Lee · Re: contract renewal". If the `query` argument names a person or word that appears in some messages, return only those. `maxResults` honoured when present. |
   | `read_email` (exists after P1-09) | Full body for reference 1–6; unknown reference → throw `AgentError.notFound` (after P1-04) or `AgentError.missingArgument`. |
   | `meeting.decisions`, `meeting.recent_context`, `meeting.search`, `meeting.transcript`, `meeting.action_items`, `meeting.current`, `meeting.participants`, `search_knowledge`, `expand_node`, `timeline` | One shared fixture: "Last meeting: 'Launch planning', yesterday 10:00–10:45, with Ana, Marcus and Sarah. Decisions: move the launch to October 14; keep the price at $12 a month. Action items: you — send the revised budget to Ana by Thursday; Marcus — update the pricing page. Sarah said the budget needs a 10% buffer for ads." `meeting.current` → "No meeting is in progress." |
   | `memory.recall` | "Saved about the user: their brother is Cyril; they are the CEO of ProductFlo; they prefer short answers." |
   | `memory.remember`, `memory.update`, `memory.forget` | "Saved: <the text argument>." (echo) |
   | `schedule.list` | "No reminders or routines yet." |
   | `schedule.create`, `schedule.update` | "Reminder set (fixture): <all argument values joined by ' · '>." |
   | `filesystem.find`, `filesystem.search`, `find_drive_files` | "Pricing 2026.pdf — Documents/ProductFlo (modified 3 days ago)\nPricing sheet v3 — Google Drive". |
   | `filesystem.tree` | "Documents/ProductFlo: Next Notes (project folder), Pricing 2026.pdf, Launch plan.md\nDocuments/Side projects: garden-planner (project folder)". |
   | `filesystem.reveal`, `filesystem.read`, `read_doc` | "Opened Pricing 2026.pdf in Finder." / short fixture text. |
   | `computer.active_app` | "Safari is frontmost; its window is 'YouTube'." |
   | `computer.open_app` | "Opened <name>." (any name; the grader checks the argument) |
   | `browser.navigate`, `computer.open_url` | "Opened <url>." |
   | `browser.snapshot` | "[1] Search box\n[2] Link: Cortech — newest upload (2 days ago)\n[3] Link: Cortech — channel". |
   | `browser.fill`, `browser.click`, `browser.select`, `computer.click`, `computer.type`, `computer.press_key`, `computer.focus`, `computer.set_text` | "Done." |
   | `draft_email`, `send_email`, `reply_email`, `create_event`, `create_doc`, `append_doc`, `upload_to_drive` | "Prepared for the user's approval (nothing was sent): <tool.id> with <argument keys>." The eval never shows a card. |
   | anything else | "Nothing found." |

   `LiveEvalFixtures.files` is a `FileRetrieving` fake: `isAvailable = true`,
   `folders = ["Documents", "Desktop", "Downloads"]`, `find` returns one `FileHit` for any
   query containing "pric" (`Pricing 2026.pdf`, a path under a temp directory) and records a
   synthetic call `filesystem.find` in the same log, `tree` returns the tree fixture.
   Each recorded call: `struct LoggedCall { let turn: Int; let toolID: String; let arguments: [String: String]; let risk: AgentRisk }`.

8. **Cases** (`ToolLoopLiveEvalCases.swift`). Data only:
   ```swift
   struct LiveEvalCase: Sendable {
       let id: String                 // "C01"
       let turns: [String]            // sent in order through agent.handle(_, source: .text)
       let followUpIfQuestion: String? // sent once more only if the last reply ends with "?"
       let expectation: Expectation
       let mustMention: [[String]]    // every group needs ≥ 1 case-insensitive hit in the final reply
       let mustNotMention: [String]
       let maxReplyCharacters: Int?
       let dynamicMention: DynamicMention?   // .userFirstName (N01), .modelName (N02)
       let extraRule: ExtraRule?             // case-specific rules below
       let evidence: String           // where the case comes from
       let expectedFix: String        // task id that should turn it green
   }
   enum DynamicMention: Sendable { case userFirstName, modelName }
   enum ExtraRule: Sendable {
       case distinctReplies                     // M05: turn-2 reply must differ from turn-1 reply
       case searchTermReached(String)           // A01: term in a navigate url or a browser.fill value
       case browserFollowThrough(String)        // A02: ≥ 2 browser calls, or a navigate url containing the term
   }
   enum Expectation: Sendable {
       /// At least one of `anyOf`, and every one of `allOf`, must have been called.
       case tools(anyOf: Set<String>, allOf: Set<String> = [], allowed: Set<String> = [],
                  forbidden: Set<String> = [], checks: [ArgumentCheck] = [])
       /// No tool, except the ones in `allowed`.
       case answerOnly(allowed: Set<String> = [])
       /// A find tool, then either an email tool or a question asking for the address.
       case compound(first: Set<String>, then: Set<String>, orQuestionMentioning: [String])
   }
   // An empty `anyOf` means "no any-of requirement" (C04 uses `allOf` only).
   struct ArgumentCheck: Sendable {
       let toolID: String; let key: String   // key "*" = any argument value of that call
       let rule: Rule
       enum Rule: Sendable { case equalsToday, equalsTomorrow, containsAny([String]) }
   }
   ```
   Tools tolerated in every case (a model checking context first is not wrong):
   `memory.recall`, `schedule.list`, `meeting.current`.

   **The 30 cases** (`T` = today, `T+1` = tomorrow as `yyyy-MM-dd`):

   | # | ID | Turn(s) | Expectation | Argument checks | Final reply must mention (each group ≥ 1) | Evidence → expected fix |
   |---|---|---|---|---|---|---|
   | 1 | C01 | "What's on my calendar today?" | tools anyOf `get_agenda` | `get_agenda.date` = T (or absent) | [standup, budget review, marcus] | B §1 core tool → baseline should pass |
   | 2 | C02 | "What do I have tomorrow?" | tools anyOf `get_agenda` | `get_agenda.date` = T+1 | [dentist, design sync, cyril] | relative dates → P1-04 |
   | 3 | C03 | "Am I free at 3pm tomorrow?" | tools anyOf `get_agenda` | date = T+1 | [design sync] | → P1-04 |
   | 4 | C04 | "Summarize my last emails and list me my events for tomorrow" | tools allOf `search_email`, `get_agenda`; allowed `read_email` | `get_agenda.date` = T+1 | [pricing, deck, invoice] and [dentist, design sync] | 09-22 00:58Z → P1-02, P1-06 |
   | 5 | M01 | "Summarize my last 5 emails" | tools anyOf `search_email`; allowed `read_email` | — | [pricing] and [deck, ana] | B D11 → P1-09 |
   | 6 | M02 | "Any new emails from Marcus?" | tools anyOf `search_email`; allowed `read_email` | `search_email.query` containsAny [marcus] | [pricing, contract] | B D7 phrasing → P1-02/P1-03 |
   | 7 | M03 | "Check my email, check the last email and then do a summary" | tools anyOf `search_email`; allowed `read_email` | — | [pricing] | 09-15 01:13Z → P1-06, P1-09 |
   | 8 | M04 | "Draft an email to ana@example.com saying I'll send the deck on Friday" | tools anyOf `draft_email`; forbidden `send_email` | `draft_email.to` containsAny [ana@example.com] | [draft, approv, ready, review] | write token cap → P1-02/P1-04 |
   | 9 | M05 | "Summarize my last emails" → "yes" | tools anyOf `search_email` (by the end of turn 2); allowed `read_email` | — | [pricing, deck] ; plus rule: turn-2 reply ≠ turn-1 reply | 09-22 five-denial loop → P1-02 |
   | 10 | K01 | "What did we decide in the last meeting?" | tools anyOf `meeting.decisions`, `meeting.recent_context`, `meeting.search`, `search_knowledge`; allowed `timeline`, `expand_node`, `meeting.transcript` | — | [october 14, oct 14, 14 october] | B D8 → P1-03 |
   | 11 | K02 | "What action items do I have from my last meeting?" | tools anyOf `meeting.action_items`, `meeting.recent_context`, `search_knowledge`, `meeting.search` | — | [budget] | → P1-03 |
   | 12 | K03 | "What did Sarah say about the budget?" | tools anyOf `meeting.search`, `search_knowledge`, `meeting.transcript`, `meeting.recent_context` | — | [10%, ten percent, buffer] | B D8 "Sarah said" → P1-03 |
   | 13 | R01 | "Remind me at 9 tomorrow to call the bank" (+ "yes" if the reply is a question) | tools anyOf `schedule.create` | `schedule.create` any value containsAny [bank] | [bank] | T8/Q6 → P1-02 (typed pending) |
   | 14 | R02 | "Every night at 10, remind me to put the book out" (+ "okay" if question) | tools anyOf `schedule.create` | any value containsAny [book] | [book, 10] | 09-23 06:37Z leak → P0-04, P1-04 |
   | 15 | R03 | "What's on my to-do list for today?" | tools anyOf `schedule.list`, `get_agenda`, `meeting.action_items`, `search_knowledge` | — | [budget, standup, reminder, nothing] | 09-14 14:28Z → P1-03 |
   | 16 | Y01 | "Remember that my brother's name is Cyril" | tools anyOf `memory.remember`, `memory.update` | any value containsAny [cyril] | [cyril] | → baseline |
   | 17 | Y02 | "What do you know about me?" | tools anyOf `memory.recall`, `search_knowledge` | — | [cyril, productflo, ceo] | 09-23 06:39Z → P1-03 |
   | 18 | F01 | "Find the pricing document" | tools anyOf `filesystem.find`, `filesystem.search`, `find_drive_files`; allowed `filesystem.reveal` | — | [pricing] | shortcut regression guard |
   | 19 | F02 | "What projects am I working on?" | tools anyOf `filesystem.tree`, `filesystem.find`, `filesystem.search`, `search_knowledge`, `memory.recall` | — | [next notes, garden] | 09-20 20:43Z → P1-03 |
   | 20 | F03 | "Find the pricing document and email it to Marcus" | compound: first anyOf find tools (+ reveal allowed); then `draft_email`/`send_email`, **or** a final question mentioning [address, email] | — | — | B D9 → P1-08 |
   | 21 | A01 | "Open youtube and search cats" | tools anyOf `browser.navigate`; allowed `browser.fill`, `browser.click`, `browser.snapshot`, `computer.open_app` | `browser.navigate.url` containsAny [youtube.com]; and "cats" appears in some navigate url **or** some `browser.fill` value | — | T10 → P1-08 |
   | 22 | A02 | "Open youtube and play the latest Cortech video" | tools anyOf `browser.navigate`; allowed snapshot/click/fill/open_app | ≥ 2 browser calls, or a navigate url containing [cortech] | — | T10 "Opened youtube.com." → P1-08 |
   | 23 | A03 | "Open Safari" | tools anyOf `computer.open_app` | `computer.open_app.name` containsAny [safari] | — | shortcut regression guard |
   | 24 | A04 | "Which app is frontmost?" | tools anyOf `computer.active_app` | — | [safari] | baseline |
   | 25 | N01 | "Who am I?" | answerOnly | — | [the user's first name from `AgentGroundingFacts.userFullName()`, lowercased]; mustNotMention ["alter ego", "i'm <assistantName>", "i am <assistantName>"] | 09-23 17:18Z → P4-03 (may stay red in Phase 1) |
   | 26 | N02 | "What model are you running on?" | answerOnly | — | [any ≥3-letter token of `provider.displayModelName`, "apple" for Apple FM] | Q4 → **expected red until P4-03**; counted |
   | 27 | N03 | "What's the capital of Australia?" | answerOnly | — | [canberra] | control |
   | 28 | N04 | "What can you do?" | answerOnly | — | [email, mail] and [calendar] | Q13 → P1-03 |
   | 29 | N05 | "Thanks, that's all for now." | answerOnly; `maxReplyCharacters` 160 | — | — | filler control |
   | 30 | P01 | "Ask the agent what's on my calendar tomorrow" | tools anyOf `get_agenda` | date = T+1 | [dentist, design sync] | T11 → P1-08 |

   `--only C01,M05` runs a subset; the score line then reads `n/<subset size>` and the pass
   bar scales (`ceil(bar × subset / 30)`).

8b. **`--quick`: the fixed per-task subset** (added 2026-09-23; a full run is about 2.5 h, see
   REVIEW-LOG). `static let quickIDs = ["C01", "C04", "M03", "M04", "M05", "K01", "R02", "F03", "A02", "N04"]`
   in `ToolLoopLiveEvalCases.swift`. The list is fixed: never edit it to make a gate pass. Each
   failure class and each Phase 1 fix has at least one case:

   | Case | Failure class it exposes (step 10) | Task that should turn it green |
   |---|---|---|
   | C01 calendar today | PASS control (baseline must pass) | — |
   | C04 mail + tomorrow's events | REFUSAL (tool-less typed first pass), TIMEOUT | P1-02, P1-06 |
   | M03 check, read, summarize | TIMEOUT (18 s plan), invented Gmail operator | P1-06, P1-09 |
   | M04 draft, never send | WRONG_TOOL (forbidden `send_email`), truncated call | P1-02, P1-04 |
   | M05 "yes" loop | REFUSAL / offer loop | P1-02 |
   | K01 last meeting's decision | MISSED_TOOL / UNGROUNDED (tool not offered) | P1-03 |
   | R02 nightly reminder | LEAK (`name="reminders">`) | P0-04, P1-04 |
   | F03 find + email | MISSED_TOOL (shortcut ate the sentence) | P1-08 |
   | A02 open YouTube + play | WRONG_TOOL (half the sentence dropped) | P1-08, P1-13 |
   | N04 "What can you do?" | FILLER, FABRICATED, UNGROUNDED (capability answer) | P1-03, P1-11 |

   Rules:
   - `--quick` is exclusive with `--only`. When both are given, print
     `TOOLLOOP_LIVE_FAILED: --quick and --only are exclusive`.
   - The pass bar is `ceil(bar × 10 / 30)` = 9 by default. The final marker reads
     `TOOLLOOP_LIVE_OK: n/10 (quick) on <model>` or `TOOLLOOP_LIVE_FAILED: n/10 (quick) …`.
   - Print `TOOLLOOP_LIVE_ELAPSED <seconds>` before the final marker. If a quick run takes more than
     1,200 s, record it in STATUS: the 20-minute target is an estimate, and the gate is the score,
     not the time.
   - **How a task uses it.** Run `--quick` plus the task's own `--only` cases.
     - Where a task's Success threshold compares "the total score" or "score ≥ previous run",
       compare the **quick** score with the previous **quick** score on the same model.
     - A full run is required only at the phase gate. It is also required when a task changes the
       planner backend default (P1-05's flip) or the prompts (P4-03), because those touch every case.

   **The scored set is these 30 cases, forever.** Add `let scored: Bool` (default `true`) to
   `LiveEvalCase`. Cases that later phases append (P3-05 delegation/filler cases, Phase 4's
   D01–K04) are `scored: false`: they print their own `TOOLLOOP_LIVE_CASE` lines and a separate
   `TOOLLOOP_LIVE_EXTRA n/m` tally, and never change the `n/30` score or the ≥ 25/30 bar. A
   phase gate that names extra cases states which must pass.

9. **Running one case.** Before each case: `AgentSession.shared.clear()` (safe under the
   harness: the memory reviewer and indexer hooks are only connected in the normal launch
   path, which self-tests return before, `NextNotesApp.swift:235`), clear the fixture log and
   any pending action (after P1-02). For each turn:
   ```swift
   let began = ContinuousClock.now
   let turn = await withBoundedWait(turnLimit) { await agent.handle(text, source: .text) }
   if turn == nil { agent.cancel(); verdict = .timeout(harness: true) }
   ```
   `turnLimit` defaults to 150 s (`--turn-limit <seconds>`), above P1-06's 120 s ceiling plus
   a cold load, so it only fires on a hang. After the last turn, if `followUpIfQuestion` is set
   and the reply's last non-space character is "?", send the follow-up as one more turn.

10. **Grading** (`LiveEvalGrader.grade(case:replies:calls:trace:) -> LiveEvalVerdict`). One
    verdict per case, first match wins, in this order:

    | Verdict | Rule |
    |---|---|
    | `ERROR` | a turn returned an empty reply, or the runner threw |
    | `TIMEOUT` | harness cap hit, or any reply matches `TimeoutPatterns` ("took too long", "stopped the tool plan", "stopped waiting", "couldn’t finish the tool plan", "within the safe limit") |
    | `LEAK` | any reply matches `LeakPatterns` (below) |
    | `REFUSAL` | expectation needs a tool, no expected tool was called, and the final reply matches `RefusalPatterns` (denial) or `OfferPatterns` (asks permission to do what was asked). An `R01`/`R02` restating question *after* `schedule.create` is not an offer |
    | `WRONG_TOOL` | a called tool is outside `anyOf ∪ allOf ∪ allowed ∪ then ∪ tolerated`, or a `forbidden` tool was called, or an argument check failed, or `answerOnly` saw a non-allowed call |
    | `FABRICATED` | a reply matches `ClaimPatterns` (it says a tool action happened) while the fixture log shows no call in that turn that could back it (G N5, fixed by P1-11). Offers are not claims |
    | `MISSED_TOOL` | a needed tool was not called and there was no denial or offer (the model answered from nothing) |
    | `UNGROUNDED` | a `mustMention` group has no hit, a `mustNotMention` string is present, a case-specific rule failed (M05 identical replies), or `maxReplyCharacters` exceeded |
    | `FILLER` | the final reply, lowercased and trimmed, starts with an entry of `FillerOpenings` |
    | `PASS` | none of the above |

    Pattern lists (all case-insensitive; keep them as `static let` arrays so the grader
    self-test and the report can print them):
    - `LeakPatterns`: `<tool_call`, `</tool_call`, `<use_tools`, `<answer`, `<think`,
      `<|`, `|>`, `name="`, `{"name"`, `"arguments"`, `<function`, `<parameter`, `[TOOL_CALLS]`,
      three backticks, the regex `\bstep \d+/\d+\b`, `^ERROR:`, "Remaining steps are unfinished",
      "tool planner", "invalid response header", "invalid tool request", "requested an
      unavailable tool", and every registered tool id or alias that contains `.` or `_`
      (`AgentToolRegistry.shared.tools(upTo: .privileged)` ids plus `files.*`/`workspace.*`
      aliases), matched word-bounded. Exception: a fixture's own words (e.g. an email address)
      are not a leak.
    - `RefusalPatterns`: "don't have access", "do not have access", "no access to",
      "can't access", "cannot access", "unable to access", "not able to access", "i don't have
      the ability", "i don't have the tool", "i can't check", "i cannot check", "i can't read",
      "i cannot read", "i can't open", "i cannot open", "paste the", "paste it",
      "without a tool call", "i don't have your", "i do not have your".
    - `OfferPatterns` (only when no expected tool ran): "would you like me to", "do you want me
      to", "shall i", "should i", "want me to", "i can check", "i could check".
    - `FillerOpenings`: "sure", "of course", "certainly", "absolutely", "great question", "good
      question", "hey there", "hi there", "i hear you", "happy to help", "i'd be happy",
      "no problem", "alright", "okay,", "ok,", "let me", "i will now", "i'm on it".
    - `ClaimPatterns`: "i ran", "i've run", "i have run", "i searched", "i've searched", "i checked",
      "i've checked", "i looked at your", "i looked through your", "i listed", "i opened",
      "i read your", plus the regex `\b\d[\d,]* (files|emails|messages|events|results) (searched|checked|found|listed)\b`.
      Use the same list as `ToolClaimGuard` (P1-11) once that exists. A registered id in a claim is
      already a `LEAK`, which wins by order.

11. **Output.** Per case, one line:
    `TOOLLOOP_LIVE_CASE C04 WRONG_TOOL 23.4s turns=1 tools=search_email(query=in:inbox) reply="…first 160 chars…"`.
    Then `TOOLLOOP_LIVE_CLASSES pass=.. error=.. timeout=.. leak=.. refusal=.. wrong_tool=.. fabricated=.. missed_tool=.. ungrounded=.. filler=..`,
    `TOOLLOOP_LIVE_SCORE n/30`, `TOOLLOOP_LIVE_REPORT <path>`, then the final marker. Use
    `SelfTest.diagnostic(_:)` for every line so `--selftest-out` mirrors them. The final line
    must be the last thing printed. Note that `writeSelfTest`'s failure detection
    (`NextNotesApp.swift:5587-5599`) keys on a leading marker ending in `_FAILED` — the case
    lines start `TOOLLOOP_LIVE_CASE`, so they do not trip it; do not name a case verdict
    `…_FAILED`.

12. **Report.** `--report <path>` (markdown) plus `<path>.jsonl`. Without `--report`, write to
    `~/Library/Caches/NextNotesBuild/toolloop-live/<yyyy-MM-dd-HHmm>.md`. Markdown: title,
    date, model line, pass bar, class tally, then one table row per case (ID, verdict, seconds,
    turns, tools with arguments, reply ≤ 300 chars), then for every non-PASS case the last raw
    planner completion from `plannerTraceForTesting` (≤ 400 chars, in a fenced block) and the
    number of rounds and prompt sizes. JSONL: one object per case with the same fields, for
    diffing two runs. The report contains only fixture data and model output; no user data.
    Once P0-20 has landed, each case row also lists its model passes. P0-20 writes **one row per
    model pass** to the unified local usage log `usage.jsonl` (writer `UsageLog`,
    `Support/Usage/UsageLog.swift`; row `UsageRecord`; recorder `ModelPassRecorder`), not a
    `metrics.jsonl` span. For the eval, read the rows whose `feature` is `agent.typed`,
    `agent.voice` or `agent.worker` and whose `turnID` belongs to the case, and print per pass:
    `provider`, `modelID`, `promptTokens`, `completionTokens`, `reasoningTokens`, `ttftMs`,
    `totalMs`, `finishReason`, `toolsProposed`, `toolsExecuted`. Under the harness
    `UsageLog.shared` is a temp directory, so read from `UsageLog.shared` (or inject
    `UsageLog(directory:)` for the eval run). That way the report says which model answered,
    and G's reverse engineering is never needed again.

13. **Timeout.** In `SelfTest.defaultTimeout` (`NextNotesApp.swift:142-157`) add: when
    `requested == "--selftest-toolloop-live"`, return `max(300, Double(caseCount) * 300 + 300)`
    where `caseCount` is 30, the `--only` subset size, or 10 for `--quick` (≈ 9,300 s for a full
    run, 3,300 s for `--quick`). The flat
    300 s would kill a healthy run at the tenth case, which is exactly the failure AGENTS.md
    describes for `--selftest-cleanup`.

14. **Grader self-test** `--selftest-toolloop-live-grader` (no model, < 1 s): feed the grader
    canned `(case, replies, calls)` triples — one per verdict class, including: C01 with
    "I don't have access to your calendar." and no call → `REFUSAL`; M05 with "Would you like
    me to check your email?" twice → `REFUSAL`; C04 reply `name="reminders">` → `LEAK`; reply
    "Did search_email (step 1/8). Timed out on get_agenda." → `TIMEOUT` (timeout wins over
    leak by order); M04 with a `send_email` call → `WRONG_TOOL`; C02 with `date = T` →
    `WRONG_TOOL`; K01 with a correct call but reply "Nothing was decided." → `UNGROUNDED`;
    N03 "Sure! The capital is Canberra." → `FILLER`; C01 with "I checked your calendar and you
    have nothing booked today." and **no** call → `FABRICATED` (G A7); C01 with "Would you like me to
    check your calendar?" and no call → `REFUSAL`, not `FABRICATED` (an offer is not a claim); a
    clean C01 → `PASS`. Print
    `TOOLLOOP_LIVE_GRADER_WRONG: <case> expected <x> got <y>` per miss and finally
    `TOOLLOOP_LIVE_GRADER_OK` or `TOOLLOOP_LIVE_GRADER_FAILED: <n> misclassified`.

15. **Registration.** In `NextNotesApp.runRequestedSelfTest` add two blocks next to
    `--selftest-toolloop-production` (`:1493`), following the existing pattern
    (`Task { @MainActor in SelfTest.failed = !(await …); NSApp.terminate(nil) }`). Because
    `arguments.contains` is an exact element match, `--selftest-toolloop` (`:1128`) does not
    swallow the new flags; keep them as distinct blocks. Arguments read with
    `SelfTest.value(after:)`: `--model`, `--only`, `--report`, `--pass-at`, `--turn-limit`;
    booleans `--allow-cloud` and `--quick`.

16. **Acceptance.** In `Scripts/acceptance.sh` `INTEGRATION_ENTRIES` add
    `"selftest-toolloop-live|9300"` and `"selftest-toolloop-live-grader|300"`.

17. **AGENTS.md.** Add both flags to the list and a paragraph: the eval runs the real
    `RealtimeAgent.handle` on the Agent-role model with every tool answered by a fixture; it
    prints `_ABSENT` without a model; its score is the Phase 1 metric; the grader is pinned by
    `--selftest-toolloop-live-grader`. A full run can take up to about 2.5 h (budget 9,300 s), and
    `--quick` (10 fixed cases, target ≤ 20 min) is the per-task gate.

**Do not:**
- Do not call `ModelRoleStore.shared.provider(for:)` from the eval; it writes
  `activeAgentModelID` (`ModelRoleStore.swift:575-577`). Read `choice(for:)`.
- Do not let the fake run outside `SelfTest.isRunning`, and do not put the fake below the
  permission logic (a card must never appear during the eval).
- Do not use `toolLoopLimitForTesting` in the eval; production budgets are what is measured.
- Do not grade on a scripted model, and do not print `TOOLLOOP_LIVE_OK` when the resolved
  provider is nil or when fewer than all requested cases ran.
- Do not put real mail, calendar or file names in fixtures or reports.
- Do not add the flag to the CORE tier: it is long and model-bound.
- Do not loosen a pattern list to make a baseline look better; if a verdict is wrong, add a
  grader self-test case that proves the fix.
- Do not print a case line whose leading token ends in `_FAILED` (it would trip
  `writeSelfTest`'s failure detection).

**Red-first self-test:** The eval itself. On the build with Phase 0 merged and before any
other P1 task, it must print `TOOLLOOP_LIVE_FAILED` with a score ≤ 24/30 (estimate from B's
evidence: 8–15/30). If it scores ≥ 25/30 on the unmodified loop, the grader is too lenient:
open the report, hand-check five PASS rows against the rules above, and add grader self-test
cases for whatever slipped through. Cases C04, M05 and F03 must not pass on the unmodified
loop (their evidence is reproduced by the current code: header pass, no typed pending
intent, locate shortcut); if they pass, find out why before continuing.
`--selftest-toolloop-live-grader` must fail if any single verdict branch is removed (delete
the LEAK branch locally, run it, see `TOOLLOOP_LIVE_GRADER_FAILED`, restore).

**Verify:**
```bash
make build
make install OPEN=0
Scripts/run-selftest.sh --selftest-toolloop-live-grader
mkdir -p Tests/Reports/toolloop-live
Scripts/run-selftest.sh --selftest-toolloop-live \
  --report "$PWD/Tests/Reports/toolloop-live/$(date +%F)-baseline-agent-role.md"
Scripts/run-selftest.sh --selftest-toolloop-live --model apple \
  --report "$PWD/Tests/Reports/toolloop-live/$(date +%F)-baseline-apple-fm.md"
Scripts/run-selftest.sh --selftest-toolloop-live --quick \
  --report "$PWD/Tests/Reports/toolloop-live/$(date +%F)-baseline-agent-role-quick.md"   # the quick baseline every task compares with
# store stamps before/after to prove no user store was written:
stat -f '%m %N' ~/Library/Application\ Support/Next\ Notes/agent-audit.jsonl \
  ~/Library/Application\ Support/Next\ Notes/agent-conversation.json \
  ~/Library/Application\ Support/Next\ Notes/agent-tasks.json
```
Run the `stat` line before and after the eval; the modification times must not change.
Regression: `--selftest-toolloop-production`, `--selftest-toolloop`, `--selftest-tool-awareness`.

**Success threshold:** Grader self-test OK. The eval completes all 30 cases, prints exactly
one final marker, writes both report files, changes no user store, and (with Phase 0 in place)
records a baseline score that is < 25/30. Two runs on the same build differ by ≤ 3 cases
(sampling is seeded, `NotesModelRuntime.makeSampler`, `:1056-1084`; prompt dates vary).

**Risks & rollback:** The seams are test-only (guarded by `SelfTest.isRunning`); reverting the
new files and the three small seams restores today's code. A slow model makes the run long;
use `--only` while iterating, `--quick` for per-task results, and the full run only for the
baseline and the phase gate. If
`AgentSession.shared.clear()` ever grows a side effect under the harness (for example a
review hook connected in self-tests), switch to a harness-only reset method on `AgentSession`.

**Done when:**
- [ ] `--selftest-toolloop-live-grader` prints `TOOLLOOP_LIVE_GRADER_OK`.
- [ ] Baseline reports for the Agent-role model and Apple FM are in `Tests/Reports/toolloop-live/`, scores copied into `STATUS.md`.
- [ ] A `--quick` baseline report exists; its `TOOLLOOP_LIVE_ELAPSED` is recorded, and the ten `quickIDs` are exactly the list in step 8b.
- [ ] Store modification times unchanged across a run.
- [ ] Flags in AGENTS.md and `Scripts/acceptance.sh` (INTEGRATION).
- [ ] `grep -rn "fakeForTesting" Sources/NextNotes` shows the executor check guarded by `SelfTest.isRunning`.

---

### P1-02 — Remove the typed tool-less first pass; typed pending action ("yes" carries the action)

**Finding(s):** T3 (B D6), part of Q2. **Effort:** 1 day. **Depends on:** P1-01, P0-05. **Unblocks:** P1-06, P1-07 (shares `PendingAction`), P1-10.

**Why (what the user experiences today):** On 09-22 00:58–01:01Z "Summarize my last emails
and list me my events for tomorrow" got *"I don't have access to your email or calendar data
without a tool call … would you like me to do that?"*, and "yes", "use them" and "i am
telling you to use your tools" got the same sentence back — five times — while `gws` was
signed in. Typed turns first run a pass that is *told* it has tools but is given none, with a
112-token cap (P0-05 lifts the cap) and a header to choose; a small model reasons about its
access and asks permission. A bare "yes" then goes back to the same pass with its own denial
in history, because the typed path has no pending-intent slot (voice has one,
`Coordinator:359-367`).

**Files you will change:**
- `Agent/RealtimeAgent+ToolLoop.swift` — `runModelTurn` (public `:329-370`), planner token
  cap (`:909`, `:912`, re-verified 2026-09-24), planner rules (`:670-704`), new `runPlannedTurn`.
- `Agent/RealtimeAgent.swift` — `handle` (`:207-392`): pending-action check before
  `AgentTurnIntent.resolve` (`:273-276`) and capture after the `.toolLoop` case (`:333-360`);
  new stored property `typedPending`.
- New `Agent/PendingAction.swift`.
- `Agent/RealtimeAgentToolLoopSelfTest.swift` — update three assertions, add four cases.

**Read for context (do not change):** `Agent/VoiceConversationCoordinator.swift:42-52`
(`PendingIntent`), `Activation/VoiceTurnPolicy.swift:78-87` (`isBareAcknowledgment`),
`Agent/AgentDirectIntent.swift:244-266` (`toolShapeMatch`, `capabilityMention`),
`Agent/RealtimeAgent.swift:979-993` (`endSession` rotates `sessionID`).

**Current behaviour:**
- `RealtimeAgent.handle` sends every typed ordinary turn to `.toolLoop` →
  `runModelTurn(text, speech:, voice: false)` (`RealtimeAgent.swift:344`).
- The private `runModelTurn` (`ToolLoop:372-490`) streams a first pass with
  `system: Self.voiceRoutingSystem(voice: false)` and `maxTokens: 112` (`:417-418`). Its rules
  (`:498-536`) start *"You are a conversational assistant with tools for calendar, meeting
  notes, Gmail, Drive, Docs, local files, apps and browser pages. First choose the response
  header:"*. The model must answer `<answer/>…` or `<use_tools/>`; anything else starting
  with `<` is `.invalid` → "The model could not answer: The model returned an invalid response
  header." (`:432-433`, `:449-451`). Only `<use_tools/>` or an answer the refusal guard
  contradicts reaches `runPlannedToolLoop` (`:454-478`).
- The first pass budget is `Limits.modelWarm` 18 s / `modelCold` 45 s
  (`RealtimeAgent.swift:31-32`, used at `ToolLoop:386-388`).
- There is no typed pending slot; `AgentSession.chatHistoryForCurrentTurn(maxCharacters: 2_500)`
  (`ToolLoop:382`) carries the previous denial into the next pass.
- The planner rounds are capped at 256 tokens (`ToolLoop:909`, `:912`, re-verified
  2026-09-24). P0-05 (done) already lifted the typed first pass to `AgentAnswerBudget`
  (`ToolLoop:390-394`, `let window = await AgentAnswerBudget.readerContextTokens(for: provider)`);
  the planner round was left for this task.

**Target behaviour:**
- A typed turn makes **no** header pass. `runModelTurn(voice: false)` goes straight to the
  planner, which answers directly when no tool is needed (its rules already allow that,
  `ToolLoop:678-679`). A typed "hi" makes exactly one model call, whose system prompt is the
  planner's (`plannerSystem`), and whose `maxTokens` is ≥ 1,024.
- When a typed reply ends with a question that offers or confirms an action, the agent keeps a
  `PendingAction` for 180 s in the same session. The next typed "yes / yeah / sure / ok /
  okay / do it / use them / go ahead / please do" runs the original request with the
  confirmation stated; "no / cancel / never mind / don't" answers "Okay, I won't." with no
  model call; anything else clears the pending action.
- The voice branch of the private `runModelTurn` (reached only by self-tests, because
  production voice goes to the coordinator at `RealtimeAgent.swift:208-212`) is unchanged here;
  P3-01 moves those tests onto the coordinator path.

**Steps:**

1. **New file `Agent/PendingAction.swift`:**
   ```swift
   /// An offer or a confirmation question the agent is waiting on. A bare "yes" resolves to
   /// it without a model deciding what "yes" meant. Shared by typed turns (P1-02) and voice
   /// (P1-07), which today has its own `PendingIntent`.
   struct PendingAction: Equatable, Sendable {
       enum Origin: String, Sendable { case typedOffer, typedQuestion, workerQuestion, frontendOffer }
       let requestText: String      // the user's original words
       let question: String         // the assistant's final sentence, ending in "?"
       let capabilityID: String?    // the tool id the request names, when known
       let origin: Origin
       let sessionID: UUID?
       let at: Date
       static let lifetime: TimeInterval = 180

       func isFresh(now: Date = Date()) -> Bool { now.timeIntervalSince(at) < Self.lifetime }

       /// The planner prompt for a confirmed action. States the confirmation so the model
       /// does not ask again, and keeps the user's own words as the instruction.
       func confirmedPrompt(acknowledgment: String) -> String {
           """
           Earlier request from the user: \(requestText)
           You then asked: \(question)
           The user answered: \(acknowledgment)
           That answer confirms it. Carry out the earlier request now, with the tools it needs. Do not ask again.
           """
       }

       static let offerPhrases = ["would you like me to", "do you want me to", "shall i", "should i",
                                  "want me to", "is that right", "is that okay", "is that ok", "okay?", "ok?"]

       /// Nil unless the reply's last sentence is a question AND (it is an offer/confirmation,
       /// or the request itself names a capability the roster has).
       static func detect(reply: String, request: String, allowedIDs: Set<String>,
                          origin: Origin, sessionID: UUID?, now: Date = Date()) -> PendingAction?

       /// "yes", "yeah", "yep", "sure", "ok", "okay", "please", "please do", "go ahead",
       /// "do it", "use them", "use it", "use your tools", optionally followed by ≤ 5 words
       /// with no action verb other than "use"/"do". Typed only; voice keeps
       /// `VoiceTurnPolicy.isBareAcknowledgment` (exact list) until P1-07.
       static func isConfirmation(_ text: String) -> Bool
       /// "no", "nope", "don't", "do not", "cancel", "never mind", "nevermind", "stop", "not now".
       static func isNegative(_ text: String) -> Bool
   }
   ```
   `detect`: split `reply` into sentences on `.`, `!`, `?` keeping the terminator; take the
   last non-empty one; require it to end with "?"; `capabilityID` =
   `AgentDirectIntent.toolShapeMatch(in: AgentDirectIntent.normalize(request), allowedIDs:)`
   ?? `AgentDirectIntent.capabilityMention(in:allowedIDs:)`; return non-nil when the question
   contains one of `offerPhrases` **or** `capabilityID != nil`.

2. **`RealtimeAgent`** — add `private(set) var typedPending: PendingAction?` and a test setter
   `func setTypedPendingForTesting(_:)`.
   In `handle`, right after `AgentSession.shared.recordUser(text, source: source)` (`:273`) and
   before `AgentTurnIntent.resolve` (`:274`):
   ```swift
   var effectiveText = text
   if source == .text, let pending = typedPending {
       typedPending = nil
       if pending.isFresh(), pending.sessionID == AgentSession.shared.sessionID {
           if PendingAction.isConfirmation(text) {
               effectiveText = pending.confirmedPrompt(acknowledgment: text)
               AgentAuditLog.shared.record(kind: .request, title: pending.requestText,
                   detail: "pending_ack → plan (typed; heard: \(String(text.prefix(80))))")
           } else if PendingAction.isNegative(text) {
               replyTrace.end(note: "pending-declined")
               return conclude(mine, "Okay, I won't.", route: "pending-declined")
           }
       }
   }
   ```
   Pass `effectiveText` to `AgentTurnIntent.resolve` and on to `runModelTurn`. The session row
   keeps the literal "yes" (already recorded). The session id check makes a cleared or rotated
   conversation drop the pending action with no extra hook (`endSession` assigns a new
   `sessionID`, `RealtimeAgent.swift:987`). Check that `AgentSession.sessionID` is readable from
   `RealtimeAgent`; it is used at `ToolLoop:987`.

3. In the `.toolLoop` case after `let result = await runModelTurn(…)` (`RealtimeAgent.swift:344`),
   for `source == .text` only:
   ```swift
   typedPending = PendingAction.detect(
       reply: result.reply, request: text,
       allowedIDs: Set(Self.plannableTools().map(\.id)),   // manifest.allowedIDs after P1-03
       origin: result.usedTools ? .typedQuestion : .typedOffer,
       sessionID: AgentSession.shared.sessionID)
   ```
   Use the user's *original* text as `requestText` (for a confirmation turn that is
   `pending.requestText`, not the synthesized prompt): keep the resolved original in a local
   before step 2 overwrites `effectiveText`.

4. **Planner result.** Add
   ```swift
   struct PlannedTurnResult: Sendable { let reply: String; let usedTools: Bool; let calledToolIDs: [String] }
   func runPlannedTurn(_ prompt: String, speech: AgentToolSpeechTracker? = nil, voice: Bool = false) async -> PlannedTurnResult
   ```
   Move the body of the public `runPlannedToolLoop` (`ToolLoop:725-788`) into it; the private
   loop (`:790`) returns `PlannedTurnResult` (`usedTools = !completedToolIDs.isEmpty`); a direct
   intent (`:741-745`) counts as `usedTools = true`. Keep
   `func runPlannedToolLoop(…) async -> String { await runPlannedTurn(…).reply }` for
   `RealtimeAgent.runVoiceObjective` (`RealtimeAgent.swift:138`).

5. **No header pass for typed turns.** In the public `runModelTurn` (`ToolLoop:329`), after the
   Codex hand-off block (`:339-349`) and before provider resolution:
   ```swift
   if !voice {
       beginWork(title: "Thinking…")
       let planned = await runPlannedTurn(prompt, speech: nil, voice: false)
       let reply = handoffNote.map { $0 + "\n\n" + planned.reply } ?? planned.reply  // P1-10 renders this note
       return AgentModelTurnResult(reply: reply, usedTools: planned.usedTools)
   }
   ```
   `runPlannedTurn` resolves the provider itself (`:771-778`) and binds
   `KnowledgeGraphScope.$reader` (`:780-783`), so nothing is lost.

6. **Round token cap (rewritten, H-audit 2026-09-23).** P0-05 (done, 6ad6ade) defines the
   function; this step only calls it. `AgentAnswerBudget` (`Agent/AgentAnswerBudget.swift`)
   already has `tokens(kind:contextTokens:promptTokens:depth:)` with
   `.plannerRound(background:)` (wanted: background 768, otherwise
   `max(1_024, depth.localAnswerTokenBudget)`) and `readerContextTokens(for:)`. Do **not**
   add a `plannerRoundTokens` function. Today the planner still passes a literal
   `maxTokens: 256` twice inside the private `runPlannedToolLoop` round
   (`ToolLoop:909`, `provider.streamInteractiveConversation(… maxTokens: 256)`, and
   `ToolLoop:912`, `provider.stream(system: system, user: user, maxTokens: 256)`; verified
   2026-09-24, grep `maxTokens: 256`). Replace both:
   ```swift
   // Once per plan, before the `while` loop (beside `let responsiveness = …`, ToolLoop:~826):
   let window = await AgentAnswerBudget.readerContextTokens(for: provider)
   let depth = answerDepthForTesting ?? Settings.shared.agentResponsiveness

   // Per round, immediately before `withBoundedWait(remaining)` (after `let user = …`, ToolLoop:~899):
   let promptTokens = (try? await provider.countTokens(system + "\n" + user))
       ?? (system.count + user.count) / 4
   let roundTokens = AgentAnswerBudget.tokens(
       kind: .plannerRound(background: background),
       contextTokens: window, promptTokens: promptTokens, depth: depth)
   Log.agent.info("answer budget · kind=\(AgentAnswerBudget.Kind.plannerRound(background: background).label, privacy: .public) window=\(window) prompt=\(promptTokens) visible=\(roundTokens)")
   ```
   and pass `maxTokens: roundTokens` at both call sites. The interactive-voice branch
   (`voice && !background`, which production never reaches: production voice goes through
   the coordinator) also uses `.plannerRound(background: false)`: a planner round that must
   hold a tool call plus its arguments is not a first-pass voice answer, and a 256 cap is
   what truncated tool calls in the first place (H1 #3). Keep `.voiceFirstPass` (112) for
   the voice first pass only. The cap is AgentAnswerBudget's rule,
   `min(wanted, contextTokens − promptTokens − 256)` with a floor of 64, **not**
   `contextTokens / 4`. The llama runtime refuses a prompt whose tokens plus `maxTokens`
   plus headroom exceed the context (`NotesModelRuntime.complete`/stream guards at
   `Formatting/LLM/NotesModelRuntime.swift:574` and `:645`,
   `promptTokens.count + maxTokens + Self.contextHeadroom <= contextTokens`,
   `contextHeadroom = 256` at `:58`), which is exactly the room `AgentAnswerBudget` leaves;
   P1-10a budgets the prompt itself.

   **P0-17 pairing (H-audit 2026-09-23).** P0-05 landed on 2026-09-24 without P0-17
   (OpenRouter reasoning cap and `finish_reason`), although the owner paired them "in the
   same session" (STATUS.md: P0-17 `todo`). A larger `maxTokens` on an OpenRouter reasoning
   model is spent on hidden reasoning until P0-17 caps it. Do not run any Phase 1 eval with
   `--allow-cloud` (or with an OpenRouter Agent role) until P0-17 is `done`; local and
   Apple FM runs are unaffected.

7. **Planner rules** (`ToolLoop:670-704`): add two sentences after "answer it directly and
   briefly": *"A greeting or small talk needs no tool: answer it in one or two sentences. If a
   listed tool can answer the request, call it now; never ask whether you should."* Do not add
   the Agent's name or "You are Next Notes" (`--selftest-persona` fails on it).

8. **Self-test updates** in `RealtimeAgentToolLoopSelfTest.run()`:
   - `ToolLoopTestProvider.complete` decides by `system.contains("<use_tools/>")`
     (`:689`). Typed turns no longer send that; make "choosing" false for typed and let the
     planner branch emit the tool call on the first round.
   - Replace "first pass omitted the model tool decision" (`:512-513`) with
     "typed turn used the header pass": fail if any typed system prompt contains `<use_tools/>`.
   - "tool request did not enter the separate planner" (`rounds >= 3`, `:490`) becomes
     `rounds >= 2` (call round + answer round).
   - "conversation entered tool planning (rounds == 1)" (`:506`) stays; add
     `maxTokensSeen >= 1_024` for the typed conversation (add `lastMaxTokens` to
     `ToolLoopTestState`).

**Do not:**
- Do not delete `voiceRoutingSystem` / `VoiceResponseEnvelope`; the voice test path still uses
  them until P3-01.
- Do not route a confirmation through `AgentDirectIntent.parse` of the synthesized prompt; the
  confirmed prompt starts with "Earlier request…" and must go to the planner.
- Do not treat "okay" as noise on the typed path; the typed path has no noise gate and must not
  gain one.
- Do not execute a *write* on "yes" without the card: the confirmed prompt goes through the
  planner and `AgentToolExecutor`, which still shows the approval card for anything above read.
- Do not keep a pending action across sessions or longer than 180 s.
- Do not add persona/identity text to the rules (identity is P4-03).

**Red-first self-test:** extend `--selftest-toolloop-production`
(`Agent/RealtimeAgentToolLoopSelfTest.swift`), using the P1-01 executor fake so no real tool
runs and a new scripted `PlannerScriptProvider` (list of canned completions keyed by round,
records `(system, user, maxTokens)` per call):
1. Typed "hi" → exactly one provider call; its system contains `"Available tools:"` and not
   `"<use_tools/>"`; `maxTokens ≥ 1_024` with the scripted provider's `contextTokens ≥ 4_096`
   and a short prompt (the scripted `countTokens` returns ≤ 2,500 for this case, so the room
   `window − prompt − 256` is ≥ 1,340). (Red today: the call carries `<use_tools/>`, and the
   planner round carries the literal 256.) (H-audit 2026-09-23) Add case 1b: the same typed
   "hi" with the scripted provider's `countTokens` returning `contextTokens − 400` →
   `maxTokens == 144` (= 400 − 256; room-clamped, not `contextTokens / 4`), and the log line
   `answer budget · kind=plannerRound` is emitted.
2. Typed "Summarize my last emails" → script round 1 returns "I can look through your inbox.
   Would you like me to do that?" → reply ends with "?" → then typed "yes" → the first user
   message of that turn contains "The user answered: yes"; script returns
   `<tool_call>{"name":"search_email","arguments":{"query":"in:inbox"}}</tool_call>` then
   "You have six new messages…" → the fake log contains `search_email`. (Red today: no
   pending block; the scripted model never sees the confirmation.)
3. Offer then "no" → reply "Okay, I won't." and zero provider calls for that turn.
4. Offer, then `AgentSession.shared.clear()`, then "yes" → treated as a new request (the
   provider sees "yes" alone).
Marker unchanged: `TOOLLOOP_PRODUCTION_OK` / `TOOLLOOP_PRODUCTION_FAILED`, with a
`  TOOLLOOP_PRODUCTION_WRONG: <reason>` line per failure. Confirm red by running the extended
test on the unmodified loop before step 1.

**Verify:**
```bash
make build
make install OPEN=0
Scripts/run-selftest.sh --selftest-toolloop-production
Scripts/run-selftest.sh --selftest-toolloop
Scripts/run-selftest.sh --selftest-persona
Scripts/run-selftest.sh --selftest-toolloop-live --only C04,M05,R01,R02,N03,N05,C01
Scripts/run-selftest.sh --selftest-toolloop-live --quick \
  --report "$PWD/Tests/Reports/toolloop-live/$(date +%F)-P1-02-quick.md"
```
Regression: `--selftest-voice-conversation`, `--selftest-voice-grounding`,
`--selftest-tool-awareness` (they use the voice branch, which must be unchanged).

**Success threshold:** `TOOLLOOP_PRODUCTION_OK`. Eval: M05 and R01 PASS (R01 may pass via the
follow-up "yes"); C04 is not `REFUSAL`; no case that was PASS at baseline becomes `REFUSAL`,
`LEAK` or `ERROR`; N03 and N05 still PASS (answer-only turns still answer). Record typed "hi"
wall time from the eval's N05 line; it may rise by up to ~2.5 s (estimate: planner prefill
2,203–2,317 tokens vs first pass 1,180–1,301, B §1) until P1-03 shrinks the catalogue for
small talk.

**Risks & rollback:** Small talk is slower and prompts are larger (4K readers get tight; P1-03
and P1-10 address it). A model that ends every answer with "Anything else?" would create
pending actions constantly: `detect` requires an offer phrase or a capability-named request,
and a bare "yes" to "Anything else?" re-runs the earlier request only if that request named a
capability — watch the audit log for `pending_ack` rows after unrelated turns. Rollback:
revert step 5 (one `if !voice` block) to restore the header pass; the rest is additive.

**Done when:**
- [ ] `--selftest-toolloop-production` OK with the four new cases (and they were red first).
- [ ] Eval report `…-P1-02-quick.md` saved; M05 PASS; score and delta in `STATUS.md`.
- [ ] `grep -n "voiceRoutingSystem(voice: false)" Sources/NextNotes` finds no production caller.
- [ ] `PendingAction` has a production caller in `RealtimeAgent.handle`.

---

### P1-03 — `AgentCapabilityManifest`: one per-turn source of truth; namespace selection; MCP/Composio by risk class

**Finding(s):** T7 (B D8), T9, Q13; B §4 rec. 1; H3 #2 (H-audit 2026-09-23). **Effort:** 3–4 days. **Depends on:** P1-01 (soft, H-audit 2026-09-23: P0-21 for the knowledge-tool defaults; P1-17 for the gate's final form). **Unblocks:** P1-04 (repair hints list valid ids), P1-05 (schemas are generated from it), P1-07 (voice rebuttal roster), P1-08 (read-only on-device path), P3-05 (frontend tools), P4-01.

**Why (what the user experiences today):** "I cannot open a new note. I do not have the tool
to create new Google Docs or Notes" (09-19 23:05Z) with `create_doc` registered; "I don't have
access to your calendar or tasks" (09-14 14:28Z); MCP and Composio tools the user connected are
never usable by the agent. The planner sees 9 core tools plus 15 picked by 4-letter substring
overlap, while the grounding prose lists the full roster, the rules name tools that may have
been dropped, and the rules also say "never use a tool outside the available tools listed
below". Four places describe the agent's abilities and they disagree.

**Files you will change:**
- New `Agent/AgentCapabilityManifest.swift` (types + builder + intent lexicon).
- New `Agent/AgentCapabilityManifestSelfTest.swift`.
- `Agent/RealtimeAgent+ToolLoop.swift` — delete `RealtimeToolSelection.allowedIDs` (`:29-58`;
  keep `readsUntrustedOutput` and `screenshotToolIDs`), `coreToolIDs`, `relevantToolCap`,
  `relevantTools` (`:594-633`); `plannableTools` (`:635-649`) becomes a wrapper over the
  manifest; `plannerSystem` (`:656-723`) takes a manifest; execution check (`:962-964`);
  rebuttal roster (`:831`, `:942`); `publishGrounding` (`:1093-1101`); `runDirectIntent`
  allowlist (`:1109`).
- `Agent/AgentRefusalGuard.swift` — manifest roster, clause-scoped matching (T9).
- `Persona/AgentGrounding.swift` — `surfaces(for:)` (`:139-155`) reads manifest phrases.
- `Agent/VoiceCapabilitySnapshot.swift` — `current()`/`make` (`:130-160`) built from the manifest.
- `Agent/VoiceConversationCoordinator.swift` — `allowedIDs` at `:371` and `:651` from the manifest.
- `Agent/RealtimeAgent.swift` — delete `capabilitiesReply` (`:456-478`); the `.capabilities`
  intent branch (`:279-281`) answers with `manifest.capabilitiesAnswer(voice:)`.
- `NextNotesApp.swift`, `Scripts/acceptance.sh`, `AGENTS.md` (new flag; rewrite the realtime
  tool-loop alias paragraph).

**Read for context (do not change):** `Agent/Tools/AgentTool.swift` (namespaces, sources,
`executionMode`), `Agent/Tools/AgentToolRegistry.swift` (aliases, `register`),
`Agent/Tools/ToolRouter.swift` (`preferNative`), `Integrations/MCP/MCPClient.swift:150-175`
(MCP/Composio registration), `Integrations/MCP/CanonicalToolName.swift`,
`Integrations/MCP/MCPRiskHint.swift`, `Knowledge/KnowledgeTools.swift:18-33`,
`Agent/Skills/SkillPromptIndex.swift:92-100`, `Persona/AgentPromptContext.swift:149-199`.

**Current behaviour:**
- `RealtimeToolSelection.allowedIDs` (`ToolLoop:29-58`) is a hard-coded set of 63 ids.
  `plannableTools` (`:635-649`) = `AgentToolRegistry.shared.tools(upTo: .send)` ∩ that set,
  filtered by four switches. Tools registered by `MCPClient` (`MCPClient.swift:173`, source
  `.mcp` or `.composio`) are never in the set, so never plannable, advertised or allowed.
- `relevantTools` (`:608-633`) keeps `coreToolIDs` (9) plus up to 15 by substring overlap
  with request words of ≥ 4 letters (`SkillPromptIndex.terms`, `:92-100`), ties
  alphabetical. "to-do", "what did we decide", "Sarah said" do not reach schedule, meeting or
  knowledge tools.
- `plannerSystem` (`:656-723`) lists the filtered tools under "Available tools:" but its rules
  name `memory.remember` (`:683`), `schedule.list`/`schedule.create` (`:686-688`), and forbid
  "a tool outside the available tools listed below" (`:677-678`); the skills section names
  `skills.*`; `FileIndexer.shared.promptSummary` names `filesystem.find/tree`.
- The grounding prose (`publishGrounding` → `AgentGroundingCache` → `AgentGrounding.surfaces`,
  `Persona/AgentGrounding.swift:139-155`) lists surfaces of the **full** plannable roster.
- The execution check uses the global allowlist (`:962-964`), not the roster; the rebuttal uses
  the filtered roster (`rosterIDs`, `:831`, `:942`), so a denial of a dropped tool counts as
  honest.
- Workspace tools are advertised on the text path whatever the `gws` state; only the voice
  snapshot qualifies them (`VoiceCapabilitySnapshot.swift:106-114`).
- `capabilitiesReply` (`RealtimeAgent.swift:456-478`) is stale ("Hey Next", "ask the model",
  "use tools to") and reachable only through `.capabilities`, which `resolve` never produces.
- `AgentRefusalGuard.rebuttal` (`AgentRefusalGuard.swift:72-103`) matches any denial phrase
  anywhere and any subject word anywhere; `"i don't have"` trips on "I don't have enough
  information to set that reminder" (audit 06:37:52Z "Re-planned after a false refusal").

**Target behaviour:**
- Exactly one value, `AgentCapabilityManifest`, is built per planner turn (and cached for the
  voice gates) from: the registry (native + MCP + Composio), switches, consent, the reader
  (which model will read the prompt), and live readiness (Workspace auth, Accessibility, file
  index). Everything below reads that one value:

  | Consumer | Reads | Replaces |
  |---|---|---|
  | Planner schema ("Available tools:") | `manifest.selected` | `relevantTools` |
  | Planner rule lines, skills section, file summary | `manifest.ruleLines()`, only for selected intents | fixed rules naming dropped tools |
  | Grounding prose (roster sentence) | `manifest.groundingSurfaces` (ready entries) | `AgentGrounding.surfaces(for: toolIDs)` over the full allowlist |
  | Refusal guard | `manifest.allowedIDs` + unavailable entries | `rosterIDs` / `plannableTools()` |
  | Execution allowlist | `manifest.entry(named:)` | `RealtimeToolSelection.allowedIDs` |
  | "What can you do" (typed and voice) | `manifest.capabilitiesAnswer(voice:)` | `capabilitiesReply`, `VoiceCapabilitySnapshot` feature list |
  | Voice gates (coordinator) | `manifest.allowedIDs` | `Set(RealtimeAgent.plannableTools().map(\.id))` |
  | P1-05 native schemas | `manifest.selected` | — |
  | P3-05 frontend tools | `manifest.frontendTools` | — |
- Tools are chosen by **intent class**, never by keyword top-k. If any tool of a class is
  selected, every allowed tool of that class is selected.
- No tool id appears anywhere in a planner system prompt unless it is in that turn's
  `selected` set.
- MCP and Composio tools join by risk class (≤ `.send`), unless a native tool covers the same
  capability.
- With every switch on and Workspace signed in, the native allowed set equals today's 63-id
  set (behavioural parity; widening it is a separate decision graded by the eval).

**Steps:**

1. **Types** (new `Agent/AgentCapabilityManifest.swift`). Write exactly these public shapes:
   ```swift
   /// What a request is about, at the granularity tools are chosen at. Never an id.
   enum AgentIntentClass: String, CaseIterable, Sendable, Codable {
       case calendar, mail, drive, files, meetings, knowledge, reminders, memory
       case screen, browser, shell, skills, integrations
   }

   struct AgentCapabilityManifest: Sendable, Equatable {
       struct Reader: Sendable, Equatable {
           let provider: LLMProviderID
           let displayName: String
           let contextTokens: Int
           var isCloud: Bool { provider == .openRouter }
       }
       enum Readiness: Sendable, Equatable {
           case ready
           case needsSetup(String)        // one user-facing sentence, e.g. "Connect Google in Settings ▸ Workspace."
           case needsPermission(String)   // e.g. "Allow Accessibility for Next Notes in System Settings."
       }
       struct Entry: Sendable, Equatable, Identifiable {
           let id: String                         // canonical registry id
           let aliases: [String]                  // registry aliases (files.find, workspace.search_email, mcp.<server>.<name>)
           let namespace: AgentToolNamespace
           let intent: AgentIntentClass
           let source: AgentToolSource
           let risk: AgentRisk
           let executionMode: AgentToolExecutionMode
           let modelDescription: String           // ≤ 160 chars, sanitized (MCP text is untrusted)
           let parameters: [WorkspaceTool.Parameter]
           let readiness: Readiness
           let userPhrase: String                 // "your calendar" — prose only, never an id
           var isReady: Bool { readiness == .ready }
           /// Cheap enough for the conversational frontend (P3-05): a read that finishes in < 2 s.
           var frontendEligible: Bool {
               risk <= .read && executionMode == .immediate
                   && [.calendar, .memory, .knowledge, .meetings, .reminders].contains(intent)
           }
       }

       let reader: Reader
       let maxRisk: AgentRisk
       /// Everything this turn may execute. Ready entries only. The execution allowlist.
       let allowed: [Entry]
       /// Enabled but not usable now (setup or permission). Named honestly in prose, never in a schema.
       let unavailable: [Entry]
       /// The entries whose schema the planner sees this turn. Whole intent classes plus the core set.
       let selected: [Entry]
       let selectedIntents: Set<AgentIntentClass>

       var allowedIDs: Set<String> { Set(allowed.map(\.id)) }
       var selectedIDs: Set<String> { Set(selected.map(\.id)) }
       var frontendTools: [Entry] { allowed.filter(\.frontendEligible) }

       /// An allowed entry by canonical id or alias; nil when not allowed this turn.
       func entry(named name: String) -> Entry?
       /// A copy with every allowed entry of `intent` added to `selected`.
       func widened(toInclude intent: AgentIntentClass) -> AgentCapabilityManifest
       /// The "Available tools:" block. `compact` = id, ≤ 60-char description, required params only.
       func plannerCatalogue(compact: Bool) -> String
       /// Rule lines for the selected intents only (memory, reminders, routines, files, skills).
       func ruleLines() -> String
       /// Plain phrases for the grounding sentence, ready entries only, in a fixed order.
       var groundingSurfaces: [String] { get }
       /// Setup sentences for unavailable intents, e.g. "Email and calendar need Google connected in Settings ▸ Workspace."
       var setupNotes: [String] { get }
       /// "What can you do" — typed (a short list) or voice (one or two sentences). No ids.
       func capabilitiesAnswer(voice: Bool) -> String
   }

   /// Everything the builder reads. `live(reader:)` reads the app; tests pass fixtures.
   struct AgentCapabilityInputs: Sendable {
       struct Switches: Sendable, Equatable { var memory, schedules, knowledgeTools, skills: Bool }
       struct Consent: Sendable, Equatable { var knowledgeGraphCloud, filesCloud: Bool }
       var tools: [AgentTool]                           // registry snapshot, all sources, up to `.privileged`
       var switches: Switches
       var consent: Consent
       var workspace: VoiceCapabilitySnapshot.WorkspaceStatus
       var accessibilityGranted: Bool?
       var fileIndexAvailable: Bool
       var reader: AgentCapabilityManifest.Reader
       var mcpMaxRisk: AgentRisk = .send
       @MainActor static func live(reader: AgentCapabilityManifest.Reader) -> AgentCapabilityInputs
   }

   enum AgentCapabilityManifestBuilder {
       /// Native registry tools the planner has never been offered. Preserves today's
       /// behaviour exactly (the old allowlist minus these == the old 63). Widening is a
       /// separate decision measured by the live eval.
       static let nativePlannerExclusions: Set<String> = [
           "computer.scroll", "computer.drag", "computer.double_click", "computer.right_click",
           "computer.wait_for", "shell.status", "shell.cancel", "browser.download",
           "browser.cdp_status", "browser.relaunch_debug", "browser.read_page", "browser.wait",
       ]
       /// Always selected (today's `coreToolIDs`, `ToolLoop:594-599`), when allowed.
       static let coreIDs: Set<String> = [
           "get_agenda", "search_email", "filesystem.search", "filesystem.find", "filesystem.tree",
           "filesystem.reveal", "computer.active_app", "computer.open_app", "browser.navigate",
       ]
       static func build(_ inputs: AgentCapabilityInputs, request: String,
                         previousRequest: String? = nil, maxRisk: AgentRisk = .send) -> AgentCapabilityManifest
       static func intent(for tool: AgentTool) -> AgentIntentClass
       static func intents(in request: String) -> Set<AgentIntentClass>
   }
   ```
   Before writing `nativePlannerExclusions`, verify it: list
   `AgentToolRegistry.shared.tools(upTo: .send)` native ids (a throwaway print in the self-test
   is fine) and diff against the 63 literal ids at `ToolLoop:29-58`. The set above was derived
   from the catalogues on 2026-09-23 (`Agent/Tools/ComputerTools.swift`, `ShellTools.swift`,
   `FilesystemTools.swift`); `filesystem.delete` and `browser.purchase` are already excluded
   by the `.send` ceiling. Adjust the set so parity holds exactly, and pin the 63 ids in the
   self-test.

2. **`intent(for:)`** — by namespace, then by id for Workspace:
   `.workspace`: `get_agenda`, `create_event` → `.calendar`; `search_email`, `draft_email`,
   `send_email`, `reply_email`, `read_email` (P1-09) → `.mail`; `find_drive_files`, `read_doc`,
   `create_doc`, `append_doc`, `upload_to_drive` → `.drive`. `.meeting` → `.meetings`;
   `.knowledge` (incl. `assemble`) → `.knowledge`; `.schedule` → `.reminders`; `.memory` →
   `.memory`; `.filesystem` → `.files`; `.computer` → `.screen`; `.browser` → `.browser`;
   `.shell` → `.shell`; `.skills` → `.skills`; `.github`, `.notion`, `.slack`, `.mcp` →
   `.integrations`. An MCP tool that `CanonicalToolName` mapped into `.workspace`/`.filesystem`
   etc. takes that namespace's class.

3. **`intents(in:)`** — a deterministic lexicon, lowercased, word-bounded regexes, applied to
   the request with "to-do"→"todo", "e-mail"→"email" normalised first. Minimum table (extend,
   never shrink; each row is a set of regex alternatives):

   | Class | Triggers |
   |---|---|
   | calendar | `calendar`, `agenda`, `schedule(d)?` (not "schedule a reminder"), `event(s)?`, `meeting(s)? (today\|tomorrow\|this week\|next)`, `am i free`, `busy`, `what do i have`, `booked` |
   | mail | `e?mails?`, `inbox`, `gmail`, `unread`, `messages? from`, `sender`, `repl(y\|ied)`, `draft`, `newsletter` |
   | drive | `drive`, `google docs?`, `sheet(s)?`, `slides?`, `shared with me` |
   | files | `files?`, `folders?`, `document(s)?`, `doc\b`, `pdf`, `projects?`, `desktop`, `downloads`, `repo(sitory)?` |
   | meetings | `meeting(s)?`, `call(s)? (with\|yesterday\|earlier)`, `transcript`, `action items?`, `decid(e\|ed)`, `decision(s)?`, `\w+ said` (the input is lowercased), `minutes` |
   | knowledge | `what did (we\|i\|they)`, `last time`, `remind me what`, `notes? (about\|from\|on)`, `history`, `(summari[sz]e\|everything) .* (know\|about me)` |
   | reminders | `remind`, `reminders?`, `todo`, `to do list`, `tasks?`, `routine`, `every (day\|night\|morning\|week\|monday…)`, `alarm` |
   | memory | `remember`, `forget`, `about me`, `who am i`, `my (name\|brother\|sister\|wife\|husband\|partner\|job)` |
   | screen | `open`, `launch`, `click`, `type`, `press`, `app(lication)?s?`, `window`, `frontmost`, `screen`, `quit` |
   | browser | `website`, `web ?page`, `page`, `url`, `browser`, `chrome`, `safari`, `youtube`, `google (it\|for)`, `search (the web\|online\|for)`, domain-looking tokens |
   | shell | `terminal`, `shell`, `command line`, `run the command` |
   | skills | `skills?` |
   | integrations | the name of any registered MCP server, `github`, `slack`, `notion`, `linear`, `jira`, and any ≥ 4-letter word of an MCP tool's name |

   Selection (`build`):
   1. `allowed` = registry tools with risk ≤ `maxRisk`, passing switches and consent (step 4),
      readiness `.ready` (step 5), not in `nativePlannerExclusions`, MCP/Composio per step 6.
      `unavailable` = the same filter but readiness not `.ready`.
   2. `matched` = `intents(in: request)`; if the request is short (≤ 6 words) or anaphoric
      ("those", "them", "it", "that one", "the last one", "yes", "do it"), also
      `intents(in: previousRequest)`. Knowledge questions also select `.meetings` and vice
      versa (they answer the same questions).
   3. `selected` = allowed entries whose intent ∈ `matched` ∪ allowed entries in `coreIDs`.
      No class matched → core only (small prompt for small talk).
   4. **Fit to the reader.** Estimate catalogue tokens as `characters / 4`. Budget: 700
      tokens when `reader.contextTokens ≤ 4_096`, else 1,600. Over budget → render the
      catalogue `compact`. Still over → drop core entries whose intent is not matched. Never
      drop an entry of a matched class; if still over, keep it and log
      `manifest over budget: <n> tokens` (P1-10's per-round token check handles overflow).
   5. `widened(toInclude:)`: when the model calls an allowed tool outside `selected`, execute it
      (it is allowed) and widen for the next round.

4. **Switches and consent** (mirror today's gates exactly): memory tools only when
   `MemorySnapshotCache.shared.isEnabled`; schedule tools only when
   `Settings.shared.agentSchedulesEnabled`; knowledge tools only when
   `KnowledgeToolGate.isAvailable`; skills only when `SkillToolGate.isAvailable`. For a cloud
   reader: `expand_node` and `timeline` only with `knowledgeGraphCloudConsent`
   (AGENTS.md "Related-context brief"); file-index tools only when
   `FileIndexScope.mayRead(reader:cloudConsent:)` allows (the same rule
   `AgentGrounding.current` applies, `Persona/AgentGrounding.swift:121-126`).

   (H-audit 2026-09-23) Availability of the knowledge tools derives from exactly two
   switches: the knowledge index (`Settings.knowledgeIndexEnabled`) and the Agent's
   knowledge-tools switch (`Settings.knowledgeAgentToolsEnabled`,
   `KnowledgeToolGate.enabledKey`), whose defaults P0-21 sets (one default for the index,
   tools on by default). Do **not** re-gate them on "Look things up without asking"
   (`Settings.agentAutoRunReadTools`): P1-17 removes that term from
   `KnowledgeToolGate.isAvailable` (`Knowledge/KnowledgeTools.swift:24-33`) and makes the
   planner honour the switch per call instead. If P1-17 has not landed yet, read
   `KnowledgeToolGate.isAvailable` as it is and let P1-17 change it in one place; never add
   a second copy of the rule in the builder.

5. **Readiness** (read cached state only; never launch a process or prompt):
   - Workspace entries: from `AgentService.shared` exactly as `VoiceCapabilitySnapshot.current()`
     does (`:135-143`). `.signedIn`, `.unknown`, `.checking` → `.ready` (unknown must not cause
     a false denial; a failed call becomes an infrastructure outcome with plain words, P1-04).
     `.notInstalled`, `.needsOAuthClient`, `.signedOut`, `.failed` →
     `.needsSetup("Email, calendar and Drive need Google connected in Settings ▸ Workspace.")`.
   - `computer.click`, `computer.type`, `computer.press_key`, `computer.set_text`,
     `computer.inspect_ui`, `computer.focus`, `computer.get_selection`: `Permissions.hasAccessibility
     == false` → `.needsPermission("…needs Accessibility for Next Notes in System Settings ▸ Privacy.")`;
     `nil`/`true` → ready.
   - `filesystem.find`, `filesystem.tree`: `LiveFileRetrieval().isAvailable == false` →
     `.needsSetup("Add a folder in Settings ▸ Files so I can search it.")`.
   - Everything else: ready.

6. **MCP / Composio by risk class.** A registry tool with `source == .mcp || .composio` is
   allowed when `risk ≤ inputs.mcpMaxRisk` (default `.send`; `.purchase`, `.destructive`,
   `.privileged` never) and no native tool covers it: drop it if a native tool shares its
   canonical id, or if `ToolRouter.preferNative(among:)` (`ToolRouter.swift:43-47`) picks a
   native tool among entries with the same namespace and name. Sanitize its description:
   remove `<`, `>`, backticks and newlines, cap at 160 characters, prefix
   `"(connected app) "`. MCP output is already untrusted
   (`RealtimeToolSelection.readsUntrustedOutput` returns true by default, `ToolLoop:21-27`);
   keep it so. Execution already works: `AgentToolExecutor` dispatches `.mcp`/`.composio` to
   `MCPClientStore.shared.call` (`Agent/Tools/AgentToolExecutor.swift:304-305`), and every
   call still passes the broker and the card.

7. **Wire the planner.** In the public `runPlannedToolLoop`/`runPlannedTurn`, after the
   provider is resolved (`ToolLoop:771-778`), build once:
   ```swift
   let manifest = AgentCapabilityManifestBuilder.build(
       .live(reader: .init(provider: provider.id, displayName: provider.displayModelName,
                           contextTokens: provider.contextTokens)),
       request: requestForRanking,
       previousRequest: AgentSession.shared.recentUserTexts(limit: 2).dropLast().last)
   currentManifest = manifest       // RealtimeAgent stored property, cleared at the end of the turn
   ```
   Move the direct-intent shortcut after this so `runDirectIntent` checks
   `manifest.allowedIDs` (`:1109`). Pass `manifest` into the private loop and into
   `plannerSystem(manifest:voice:request:)`:
   - "Available tools:" ← `manifest.plannerCatalogue(compact: …)`.
   - The memory rule (`:683-685`) only when `.memory` is selected; the reminders and routine
     rules (`:686-691`) only when `.reminders` is selected; `FileIndexer.shared.promptSummary`
     (`:716`) only when `.files` is selected; `SkillPromptSection.current(for:)` only when
     `.skills` is selected.
   - Change "use a tool outside the available tools listed below" (`:677-678`) to "call a tool
     that is not listed below" — same meaning, and now true.
   - Execution check (`:962-964`): `guard let entry = manifest.entry(named: call.name)` (P1-04
     adds fuzzy resolution and repair instead of ending the turn); if
     `!manifest.selectedIDs.contains(entry.id)` → `manifest = manifest.widened(toInclude: entry.intent)`
     and rebuild `system` for the next round.
   - Rebuttal (`:831`, `:942`): `AgentRefusalGuard.rebuttal(for: reply, manifest: manifest)`.
   - `publishGrounding()` (`:1093-1101`) publishes `manifest.allowed`/`groundingSurfaces`; when
     called outside a turn (voice snapshot), build a manifest with `request: ""`.

8. **`plannableTools()` becomes a wrapper** so its 22 call sites keep compiling:
   `AgentCapabilityManifest.current().allowed.compactMap { AgentToolRegistry.shared.tool(named: $0.id) }`,
   where `static func current(reader: Reader = .agentRole) -> AgentCapabilityManifest` (`@MainActor`) builds from
   `.live` with an empty request. Define the two reader presets used by later tasks in the same
   file: `extension AgentCapabilityManifest.Reader { static let voiceFrontend = Reader(provider: .appleFoundation, displayName: "Apple", contextTokens: FoundationModelLLMProvider().contextTokens); @MainActor static var agentRole: Reader }`
   (`agentRole` reads the provider the Agent role resolved for this turn, P0-14; P1-07 and the
   coordinator call `current(reader: .voiceFrontend)`). `current` caches by a fingerprint (switches, workspace status,
   accessibility, registry count, reader). Remove P1-01's `toolGatesForTesting` and give the
   eval `AgentCapabilityInputs` overrides instead (`static var inputsOverrideForTesting`,
   honoured only under `SelfTest.isRunning`).

9. **Grounding and "what can you do".**
   - `AgentGrounding.surfaces(for:)` keeps its signature for existing callers but the live
     path uses `manifest.groundingSurfaces`, and adds one sentence from `manifest.setupNotes`
     when non-empty ("Email and calendar need Google connected…"). Prose never names an id.
   - `capabilitiesAnswer(voice:)`: typed → "I can: check your calendar; search and read your
     email and prepare replies for your approval; …" built from ready intents in a fixed order,
     then setup notes. Voice → the first three abilities in one sentence plus "and more". Uses
     no ids and passes `--selftest-ui-strings`' banned-word list.
   - `VoiceCapabilitySnapshot.make` builds its `promptText` feature list from the manifest; keep
     its `Availability` struct and the model-resident/CLI-on-PATH qualifiers.
   - Delete `RealtimeAgent.capabilitiesReply` (`RealtimeAgent.swift:456-478`); the
     `.capabilities` branch (`:279-281`) returns `manifest.capabilitiesAnswer(voice: source == .voice)`.

10. **Refusal guard (T9)** in `Agent/AgentRefusalGuard.swift`:
    - New entry point `static func rebuttal(for reply: String, manifest: AgentCapabilityManifest) -> String?`;
      keep `rebuttal(for:toolIDs:)` for tests and make the `@MainActor` convenience use the
      current manifest.
    - **Clause scope:** split the reply into clauses at `.`, `;`, `!`, `?`, " but ", " however ".
      A clause counts only if it contains a denial phrase **and** a subject of the same
      capability.
    - **Exclusions** (a clause containing any is never a denial): "enough information", "not
      sure", "don't have a ", "do not have a ", "can't tell from", "cannot tell from", "don't
      know which", "don't know what you mean".
    - **Subjects added:** files → "project", "projects"; mail → "messages"; drive → "drive",
      "google docs", "google drive", "sheet"; reminders → "tasks", "to-do list", "todo list";
      browser → "web", "internet", "online"; meetings → "history", "notes"; tools → "tools",
      "your tools", "those tools" (a denial of "tools" with any ready entry is contradicted).
    - **Offers:** a clause with "would you like me to", "do you want me to", "shall i", "should
      i" plus a capability subject counts as a denial-equivalent (it is the 09-22 shape).
    - Roster = `manifest.allowedIDs`. A subject whose entries are all in `manifest.unavailable`
      is an **honest** denial: return nil (P1-10's renderer appends the setup note).
    - `mayBeDenial` keeps its prefix logic but uses the extended phrase list.

11. **Coordinator.** Replace `Set(RealtimeAgent.plannableTools().map(\.id))` at `Coordinator:371`
    and `:651` with `AgentCapabilityManifest.current(reader: .voiceFrontend).allowedIDs`
    (a static `Reader` for Apple FM. Its `contextTokens` comes from `FoundationModelLLMProvider`, which
    reads `SystemLanguageModel.default.contextSize` after P1-10a step 0: 8,192 measured on the dev
    Mac, with 4,096 as the fallback). The gates' behaviour only *adds* routes
    when the manifest gains MCP entries — allowed by the "may only add" rule.

12. **AGENTS.md.** Replace the paragraph "In the realtime tool loop, an alias is checked
    against the allowlist before the registry resolves it…" with: the planner's schema, rules,
    grounding, refusal guard and allowlist are all derived from `AgentCapabilityManifest`
    built per turn; tools are chosen by intent class; `--selftest-capability-manifest` fails if
    a prompt names a tool its schema lacks. Add the flag to the list.

**Do not:**
- Do not keep any second literal list of tool ids for the planner (the old
  `allowedIDs`/`coreToolIDs` must not survive as a parallel source of truth; `coreIDs` and
  `nativePlannerExclusions` live only in the builder).
- Do not select tools by keyword top-k or truncate a matched class to fit a budget.
- Do not probe `gws` or prompt for Accessibility while building the manifest (cached state
  only; AGENTS.md: a probe that answers "granted" when it is not is worse than "unknown").
- Do not expose graph tools to a cloud reader without graph consent, or file tools without
  file consent.
- Do not let an MCP tool above `.send` into the planner, and do not let an MCP tool shadow a
  native one ("a native Gmail send must never fall through to Composio", `ToolRouter.swift:5-7`).
- Do not put MCP descriptions into the prompt unsanitized; they are third-party text.
- Do not name the Agent in any capability sentence.

**Red-first self-test:** new flag **`--selftest-capability-manifest`** in
`Agent/AgentCapabilityManifestSelfTest.swift` (`static func run() async -> Bool`), registered
in `NextNotesApp.runRequestedSelfTest`, INTEGRATION tier (`"selftest-capability-manifest|300"`).
It builds manifests from fixture `AgentCapabilityInputs` (no network, no model) and asserts:
1. **Parity:** all switches on, Workspace `.signedIn`, Accessibility granted, file index
   available, reader `.appLLM` 8,192 → native `allowedIDs` == the 63 ids pinned in the test.
2. **Prompt ⊆ schema:** for 12 fixture requests ("what's on my calendar", "summarise my last
   5 emails", "what's on my to-do list", "what did we decide last meeting", "Sarah said the
   budget…", "remember my brother is Cyril", "find the pricing doc", "open youtube", "hi",
   "search linear issues", "install a skill for PDFs", "every night at 10 remind me…"), the
   string `plannerSystem(manifest:voice:false:request:)` contains **no** registry id or alias
   (word-bounded scan over `AgentToolRegistry.shared.tools(upTo: .privileged)` ids + aliases)
   that is not in `manifest.selectedIDs`.
3. **Whole classes:** for each fixture, every allowed entry whose intent ∈ `selectedIntents`
   is in `selected`.
4. **The D8 misses are fixed:** "what's on my to-do list" selects `.reminders`; "what did we
   decide" and "Sarah said" select `.meetings` and `.knowledge`; "any new mail?" selects
   `.mail`; "hi" selects core only.
5. **MCP:** register fixture tools with `AgentToolRegistry.shared.register` (unregister in a
   `defer`): `mcp.linear.search_issues` (`.read`), `mcp.linear.create_issue` (`.write`),
   `mcp.linear.delete_issue` (`.destructive`), and a Composio `workspace.search_email`
   duplicate → the first two are allowed and selected for "search linear issues"; the
   destructive one is absent; the duplicate is absent (native wins).
6. **Readiness:** Workspace `.signedOut` → mail/calendar/drive entries in `unavailable`, none
   in `selected`; `setupNotes` names Settings ▸ Workspace; `rebuttal(for: "I can't access your
   email.", manifest:)` is nil (honest); with `.signedIn` it is non-nil.
7. **T9 guard table:** "I don't have enough information to set that reminder" → nil; "I can't
   tell from this transcript" → nil; "I can't access your Google Drive" → non-nil; "I'd need
   to use your tools — would you like me to check your email?" → non-nil; "I don't have access
   to your email or calendar data without a tool call" → non-nil.
8. **Answers:** `capabilitiesAnswer(voice: false)` mentions email and calendar when signed in,
   contains no registry id, and none of the banned words `--selftest-ui-strings` uses.
9. **Budget:** for a scripted reader of 4,096 tokens (the worst case, and Apple FM's fallback), the planner system for "what's on my
   calendar and any new email" is ≤ 2,400 tokens by `FoundationModelLLMProvider.countTokens`
   (characters / 4).
Final line `CAPABILITY_MANIFEST_OK` or `CAPABILITY_MANIFEST_FAILED: <n> problems` (one
`CAPABILITY_MANIFEST_WRONG: …` line each). **Red first:** implement step 1's types with a
`legacyBuild` that reproduces today (allowlist + `relevantTools` + old `plannerSystem`) and
run the test: assertions 2, 3, 4, 5 and 7 must fail. Then implement the real builder.

**Verify:**
```bash
make build
make install OPEN=0
Scripts/run-selftest.sh --selftest-capability-manifest
Scripts/run-selftest.sh --selftest-toolloop-production
Scripts/run-selftest.sh --selftest-tool-awareness
Scripts/run-selftest.sh --selftest-voice-grounding
Scripts/run-selftest.sh --selftest-voice-turn-routing
Scripts/run-selftest.sh --selftest-file-index
Scripts/run-selftest.sh --selftest-persona
Scripts/run-selftest.sh --selftest-ui-strings
Scripts/run-selftest.sh --selftest-mcp
Scripts/run-selftest.sh --selftest-composio
Scripts/run-selftest.sh --selftest-toolloop-live --only K01,K02,K03,R03,F02,N04
Scripts/run-selftest.sh --selftest-toolloop-live --quick \
  --report "$PWD/Tests/Reports/toolloop-live/$(date +%F)-P1-03-quick.md"
```

**Success threshold:** `CAPABILITY_MANIFEST_OK` (was FAILED on `legacyBuild`); all regression
flags OK (update pins in `--selftest-tool-awareness`/`--selftest-file-index` only where they
asserted the old `relevantTools`/`allowedIDs` mechanics, never to weaken what they check).
Eval: K01, K02, K03, R03, F02, N04 not `REFUSAL`/`MISSED_TOOL` (the `--only` run); the `--quick`
score ≥ the previous quick run on the same model + 1; `LEAK` count not higher.

**Risks & rollback:** The intent lexicon can miss phrasings: a miss now costs a narrower schema
but the allowlist still executes any allowed tool, and a wrong-class call widens the next round.
Watch eval `MISSED_TOOL` rows and extend the lexicon (add a self-test fixture for each
addition). MCP servers with odd descriptions can confuse the model; set `mcpMaxRisk` to `.read`
if the eval regresses on a machine with servers connected. Rollback: `legacyBuild` stays in the
file behind `static let useLegacyManifest = false`; flipping it restores today's selection while
keeping the new call sites.

**Done when:**
- [ ] `--selftest-capability-manifest` OK (red on `legacyBuild` first).
- [ ] `grep -rn "RealtimeToolSelection.allowedIDs\|relevantTools(\|capabilitiesReply" Sources/NextNotes` returns nothing.
- [ ] Eval report `…-P1-03-quick.md`, delta in `STATUS.md`.
- [ ] AGENTS.md paragraph rewritten; flag listed; acceptance entry added.

---

### P1-04 — Tolerant parser, error split, repair loop

**Finding(s):** T4 short term (B D3), T6 (B D5); relative-date grounding (supports eval C02/C03/P01); H1 #20 (H-audit 2026-09-23). **Effort:** 2–3 days. **Depends on:** P1-01, P0-04 (special tokens must reach the parser). Soft: P1-03 (repair hints list the manifest's ids; without it use `plannableTools()`); P1-06 (the final answer-only round that ends a second repeat, H-audit 2026-09-23). **Unblocks:** P1-05, P1-10.

**Why (what the user experiences today):** One small mistake ends the turn. "open Claude"
(09-14 16:54Z) got *"The tool computer.open_app did not run: Nothing is connected that can do
“No application named Claude Code is installed.”"* twice — the app exists under another name,
the error reads as an access problem, and the model was never told. A call that uses
`"parameters"` instead of `"arguments"` runs with its arguments silently emptied; a registered
alias the allowlist misses ends the plan with "The tool planner requested an unavailable
tool; nothing else was run."; a `draft_email` body cut off at the token cap ends as "The tool
planner returned an invalid tool request."; a non-Hermes call format is shown to the user as
the answer (09-23 06:37Z `name="reminders">`).

**Files you will change:**
- `Agent/AgentToolCall.swift` — `AgentToolCallParser` (`:19-120`).
- New `Agent/ToolStepOutcome.swift` — `ToolStepOutcome`, `ToolRepair`, `ToolErrorClassifier`,
  `ToolCallNameResolver`.
- `Agent/RealtimeAgent+ToolLoop.swift` — parse/answer branch (`:931-951`), name check
  (`:960-967`), execution result handling (`:1046-1082`), first-pass envelope handling
  (`:448-485`).
- `Agent/VoiceConversationWork.swift` — `VoiceResponseEnvelope.parse` (`:45-65`).
- `Agent/AgentModels.swift` — `AgentError` (`:244-295`): add `notFound(String)`.
- `Computer/ComputerToolExecutor.swift` — `openApp` (`:71-83`).
- `Agent/AgentToolLoop.swift` — `groundedArguments` (`:69-84`).
- `Agent/RealtimeAgentToolLoopSelfTest.swift` — new scripted cases.

**Read for context (do not change):** `Agent/Tools/ToolRouter.swift:16-40`,
`Agent/Tools/AgentToolRegistry.swift:26-30`, `Agent/GoogleWorkspaceCLI.swift:76-100`
(`WorkspaceCLIError`), `Memory/NextMemory.swift:181-190` (`MemoryWriteError`),
`Formatting/LLM/OpenAICompatibleLLMProvider.swift:196-214` (`toolCallTag`), the other parser
callers: `Agent/MeetingAgent.swift:217`, `Memory/MemoryReviewer.swift:613`,
`Meetings/MeetingActionReconciler.swift:424`, `Agent/AgentToolLoop.swift:125`,
`NextNotesApp.swift:3971-3983` (the `--selftest-agent` parser checks).

**Current behaviour:**
- `AgentToolCallParser.calls(in:)` (`AgentToolCall.swift:26-38`) scans only for
  `<tool_call>…</tool_call>`; an open tag with no close tag stops the scan (`:32`). `parse`
  (`:43-93`) reads `object["arguments"]` only (`:51-59`); any other key gives `[:]`.
- In the planner, no parsed call + a literal `<tool_call>` in the text → "The tool planner
  returned an invalid tool request." (`ToolLoop:934-935`); no parsed call and no literal tag →
  the text is returned as the answer, markup and all (`:937-950`).
- An unknown or unallowed name → "The tool planner requested an unavailable tool; nothing
  else was run." (`:962-967`). `ToolRouter.resolve` is not used.
- A thrown tool error other than a recoverable memory write → "The tool <id> did not run:
  <message>" and the turn ends (`:1072-1081`), by the comment's design ("Do not hand a
  denial/error back to the model").
- `ComputerToolExecutor.openApp` throws `AgentError.noIntegration("No application named …
  is installed.")` (`Computer/ComputerToolExecutor.swift:79`), rendered as "Nothing is
  connected that can do “…”." (`AgentModels.swift:286`).
- `VoiceResponseEnvelope.parse` (`VoiceConversationWork.swift:45-65`) accepts only exact
  `<answer/>`, `<answer>`, `<use_tools/>`; anything else starting with `<` or `{` is
  `.invalid`. `<answer/>` followed by a call ends the turn (`ToolLoop:462-464`).
- `AgentToolLoop.groundedArguments` (`AgentToolLoop.swift:69-84`) grounds only "today".

**Target behaviour:**
- The planner reads calls in any of the formats listed in step 1. Text that looks like a call
  but cannot be parsed is **never** shown to the user; it triggers a repair round.
- Tool outcomes are split three ways: **recoverable** (unknown name, not found, invalid or
  missing argument, malformed or truncated call, a Gmail query that matched nothing because
  of a bad operator) go back to the model as a structured `ERROR <kind>: …` result with valid
  options, at most **2 repairs per turn**; **denied** (the user or a policy said no, or the
  turn was cancelled) ends the turn in plain words, no retry; **infrastructure** (not signed
  in, not installed, timeout, backend down) ends the turn in plain words with what to do.
- Unknown names resolve through the registry, then `ToolRouter.resolve`, then normalisation,
  then an edit-distance match against the turn's allowed ids; only a true miss becomes a
  repair with suggestions.
- A missing app is `AgentError.notFound`, with near names.
- `get_agenda.date` is grounded for today, tomorrow, yesterday and a named weekday.
- Callers outside the planner (`MeetingAgent`, `MemoryReviewer`, `MeetingActionReconciler`,
  `AgentToolLoop.run`) keep today's behaviour except that `"parameters"` is now read.

**Steps:**

1. **Parser.** Keep `static func calls(in:) -> [AgentToolCall]` for the existing callers (it
   gains only the argument-key fallback in step 1b). Add the planner entry point:
   ```swift
   struct ToolCallParse: Sendable, Equatable {
       var calls: [AgentToolCall]
       var malformed: [MalformedCall]
       /// Text outside every recognised call, trimmed. Shown to the user only when `calls`
       /// and `malformed` are both empty.
       var prose: String
   }
   struct MalformedCall: Sendable, Equatable {
       enum Kind: String, Sendable { case truncated, unparseableJSON, missingName }
       let kind: Kind
       let nameGuess: String?
       let excerpt: String          // ≤ 200 chars, for the repair message and the audit log
   }
   /// `knownNames`: ids and aliases the turn may call. Bare JSON (no wrapper) is only read
   /// as a call when its name is in this set, so prose containing braces never becomes one.
   static func parse(_ text: String, knownNames: Set<String>) -> ToolCallParse
   ```
   a. Strip a leading `<think>…</think>` block (and an unterminated `<think>` to the end) first.
   b. **Argument key fallback** (also in `calls(in:)`): read `arguments`, else `parameters`,
      `args`, `input`, `params`; each may be an object or a JSON-encoded string.
   c. Recognise, in order, and collect every match with its range:
      1. Hermes: `<tool_call>{json}</tool_call>`.
      2. OpenAI function object, wrapped or bare: `{"type":"function","function":{"name":…,"arguments":"…"}}`
         and `{"function":{"name":…,"arguments":…}}`.
      3. Alternative name keys: `{"tool": …}`, `{"tool_name": …}`, `{"function": "<name>", …}`.
      4. Qwen3-Coder XML: `<function=NAME><parameter=KEY>VALUE</parameter>…</function>`,
         with or without a surrounding `<tool_call>`.
      5. Attribute XML: `<function name="NAME"><parameter name="KEY">VALUE</parameter></function>`
         and `<invoke name="NAME">…</invoke>`. **Also accept `<param name="KEY">VALUE</param>`**,
         MiniCPM5-2B's native form (G N3; its delimiters are control tokens and only reach the text
         after P0-04). Add the canned sample
         `<tool_call><function name="get_agenda"><param name="date">2026-09-24</param></function></tool_call>`
         as a self-test case.
      6. Mistral: `[TOOL_CALLS]` followed by a JSON array of `{name, arguments}`.
      7. Llama 3.x: `<|python_tag|>` followed by a JSON object.
      8. Bare JSON (object or array of objects) at the start of the completion or inside a
         ```` ```json ```` fence, with a name key resolving to `knownNames`.
      9. **The model's own control-token form**: after P0-04 renders special tokens, capture
         real tool-call outputs yourself (P0-04 does not store any): run
         `--selftest-toolloop-live --only R02,M04` on the Agent-role model (Qwen3-4B-Instruct-2507,
         Hermes `<tool_call>` form) and, if the owner has one installed, on a Gemma 4 or Llama 3
         model, and copy the raw completions from the report's JSONL sidecar. Add one recogniser
         per captured form, with that exact sample as a self-test case. Do not guess a family's
         syntax; use captured text. (K2-Horizon cannot run on this build, P0-16.)
   d. JSON repair before giving up on a body: remove trailing commas before `}`/`]`; convert
      single-quoted keys/strings to double quotes when the body contains no double quotes.
   e. An opening marker (`<tool_call>`, `<function`, `[TOOL_CALLS]`, `<|python_tag|>`) with no
      matching close before the end of text → try the body as JSON (a missing close tag with a
      complete object is fine); otherwise `MalformedCall(kind: .truncated, nameGuess: …)`.
   f. `prose` = the text with every recognised or malformed range removed, then trimmed. If
      `prose` still contains `<tool_call`, `<function`, `name="`, `<|` or `{"name"`, add a
      `MalformedCall(.unparseableJSON)` for it rather than letting it through.
   g. Keep the placeholder-stripping rule (`ToolCallInspector.isUniversalStandIn`,
      `AgentToolCall.swift:80-82`) for every format.

2. **Outcome types** (new `Agent/ToolStepOutcome.swift`):
   ```swift
   struct ToolRepair: Sendable, Equatable {
       enum Kind: String, Sendable {
           case unknownTool = "unknown_tool", notFound = "not_found",
                invalidArgument = "invalid_argument", missingArgument = "missing_argument",
                malformedCall = "malformed_call", truncatedCall = "truncated_call",
                badQuery = "bad_query"
       }
       let kind: Kind
       let toolID: String?
       let message: String          // plain, for the model
       let options: [String]        // valid tool ids or near names
       var modelText: String {
           "ERROR \(kind.rawValue): \(message)"
               + (options.isEmpty ? "" : " Valid options: " + options.joined(separator: ", ") + ".")
               + " Correct the call and try again, or answer the user with what you already have."
       }
   }
   enum ToolStepOutcome: Sendable {
       case success(String)
       case recoverable(ToolRepair)
       case denied(userSentence: String)
       case infrastructure(userSentence: String)
   }
   enum ToolErrorClassifier {
       static func classify(_ error: Error, tool: AgentTool?) -> ToolStepOutcome
   }
   ```
   Classification table (implement exactly; add a row, never merge two):

   | Error | Outcome |
   |---|---|
   | `AgentError.permissionDenied(r)`, `.needsPermission(r)` | `.denied(r)` |
   | `AgentError.cancelled`, `CancellationError` | `.denied("I stopped that.")` |
   | `AgentError.unknownTool(n)` | `.recoverable(.unknownTool)` |
   | `AgentError.missingArgument(name, tool)` | `.recoverable(.missingArgument, "\(tool) needs \(name)")` |
   | `AgentError.notFound(r)` (new) | `.recoverable(.notFound, r)` |
   | `AgentError.backendUnavailable(r)` where `r` contains "Snapshot again" or "Choose a targetId" | `.recoverable(.invalidArgument, r)` |
   | `AgentError.backendUnavailable(r)` otherwise | `.infrastructure(r)` |
   | `AgentError.noIntegration(r)` | `.infrastructure(r)` |
   | `AgentError.notSignedIn`, `.noProvider`, `.disabled` | `.infrastructure(<errorDescription>)` |
   | `MemoryWriteError` where `isRecoverable` | `.recoverable(.invalidArgument, <description>)` (today's path, `ToolLoop:1027-1028`, `:1065-1071`) |
   | `WorkspaceCLIError.invalidRequest(d)` (exit 3) | `.recoverable(.invalidArgument, d)` |
   | `WorkspaceCLIError.apiFailed(d)` where `d` mentions 400, "invalid", "not found", 404 | `.recoverable(.invalidArgument, d)` |
   | `WorkspaceCLIError.apiFailed` otherwise, `.notAuthenticated`, `.notInstalled`, `.timedOut`, `.launchFailed`, `.badOutput` | `.infrastructure(<errorDescription>)` |
   | anything else | `.infrastructure(error.localizedDescription)` |

   The `userSentence` strings are raw here; P1-10's renderer turns them into consumer words.

3. **Name resolution** (`ToolCallNameResolver`):
   ```swift
   enum ToolNameResolution: Sendable, Equatable { case tool(String), unknown(suggestions: [String]) }
   @MainActor static func resolve(_ name: String, allowed: [AgentCapabilityManifest.Entry]) -> ToolNameResolution
   ```
   Order: (1) exact id or alias among `allowed`; (2) `ToolRouter.resolve(name)` → `.tool(id)`
   if that id is allowed; (3) normalised: lowercase, `-`/space → `_`, strip prefixes
   `functions.`, `tools.`, `default_api.`, `mcp.`, try `a.b` ↔ `a_b`; (4) Levenshtein distance
   against allowed ids and their `name` part: ≤ 2 (≤ 3 when the name has ≥ 10 characters),
   unique best; (5) `.unknown(suggestions:)` = up to 5 selected ids sharing a word with the
   name, else the first 5 selected ids. Before P1-03 lands, build `allowed` from
   `plannableTools()`.

4. **The loop** (`ToolLoop:931-1083`). Add `var repairs = 0` next to `rebutted` (`:830`),
   and `let maxRepairs = 2`.
   - Replace `AgentToolCallParser.calls(in:)` (`:931`) with
     `AgentToolCallParser.parse(completionText, knownNames: manifestNames)`.
   - `parse.calls.isEmpty && !parse.malformed.isEmpty` → if `repairs < maxRepairs`: append
     `ToolRepair(kind: .truncatedCall or .malformedCall, message: "Your last tool call was
     cut off / could not be read: <excerpt>. Emit it again, complete, as one call.", options:
     [])` to `results`, `repairs += 1`, `continue`; else end with the P1-10 sentence for
     "couldn't finish". Remove the "invalid tool request" return (`:934-935`).
   - `parse.calls.isEmpty && parse.malformed.isEmpty` → today's answer path using
     `parse.prose` (`:937-950`).
   - For each call: `ToolCallNameResolver.resolve(call.name, …)`. `.unknown(s)` → if
     `repairs < maxRepairs` append `ToolRepair(kind: .unknownTool, toolID: nil, message:
     "There is no tool called \(call.name).", options: s)`, `repairs += 1`, skip the call
     (continue with the next call, not the next turn); else end in plain words. Delete the
     "requested an unavailable tool" return (`:966`) and emit
     `plannerTraceForTesting?(.rejectedCall…)` instead.
   - Execute with the resolved canonical id (never `call.name`), so aliases (`files.find`)
     work and the signature dedupe (`:971-976`) keys on the canonical id.
   - Replace the `do/catch` in `execute` (`:992-1030`) with
     `ToolErrorClassifier.classify(error, tool: tool)`; the closure returns `ToolStepOutcome`.
   - Handle outcomes: `.success` as today (`:1047-1064`); `.recoverable(r)` → append
     `AgentPrompts.toolResult(name: tool.id, output: r.modelText)`, remove the signature from
     `completedCalls` so a corrected identical call is allowed, `callsUsed += 1`,
     `repairs += 1`; when `repairs > maxRepairs` end with the plain sentence; `.denied(s)` →
     end the turn with `s` (no retry); `.infrastructure(s)` → end with `s`. The revision check
     at `:1073-1077` stays for `.denied`/`.infrastructure`.
   - A recoverable write outcome is safe to hand back: nothing was written (the executor threw
     before committing). Do not classify an error thrown **after** a write committed as
     recoverable; the executor's post-write verification errors are `.infrastructure`.
   - **Repeated call signature (H-audit 2026-09-23, H1 #20).** Today a repeat ends the plan:
     `guard completedCalls.insert(signature).inserted else { return incomplete("The planner
     repeated a completed step, so I stopped it.", …) }` (`ToolLoop:998-1001`, verified
     2026-09-24; the lines above in this task have drifted by about +25). Small models
     re-issue the same call when the result was long or empty. Replace the stop:
     ```swift
     var repeatedSignatures = 0          // beside `var repairs = 0`
     …
     if !completedCalls.insert(signature).inserted {      // signature keyed on the canonical id
         repeatedSignatures += 1
         if repeatedSignatures == 1, repairs < maxRepairs {
             results.append(AgentPrompts.toolResult(name: tool.id, output:
                 "You already ran \(tool.id) with these arguments; its result is above. " +
                 "Answer now or choose a different step."))
             repairs += 1                 // the first repeat counts as a repair
             continue                     // next call in this round, then the next round
         }
         // Second repeat (or no repair left): end through P1-06's final answer-only round,
         // which keeps `lastVerifiedResult` and the memory confirmations.
         return await finalAnswerRound(reason: .repeatedCall)
     }
     ```
     The note is a tool result, not a user-visible sentence. `finalAnswerRound` is P1-06's
     step (b); if P1-06 has not landed, keep today's `incomplete(…)` return for the second
     repeat and leave a `// P1-06` marker.

5. **Missing app** (`Computer/ComputerToolExecutor.swift:78-80`): add
   `case notFound(String)` to `AgentError` (`AgentModels.swift:244`) with `errorDescription`
   returning the string as-is. In `openApp`, when no URL is found, collect up to five
   installed app names (`/Applications`, `/System/Applications`, `~/Applications`, one level)
   sharing a ≥ 3-letter token with the request, and throw
   `AgentError.notFound("No app called “\(trimmed)” is installed. Apps with a similar name: \(names).")`.
   Fix every `switch` over `AgentError` the compiler flags.

6. **Envelope** (`VoiceConversationWork.swift:45-65`, used by the voice test path and any
   remaining header pass): strip a leading `<think>…</think>`; compare case-insensitively
   (`<Answer/>`); `<use_tools>` without the slash → `.tools`; a text that starts with a
   recognised call marker (`<tool_call`, `<function`, `{"name"`, `[TOOL_CALLS]`) → `.tools`;
   any other unknown tag → `.tools` (the decision doc: "unknown header or bare call =
   `<use_tools/>`"). In `ToolLoop:462-464`, `<answer/>` followed by a call now escalates to the
   planner like `.tools` instead of returning "invalid tool request".

7. **Relative dates** (`AgentToolLoop.groundedArguments`, `:69-84`): for `get_agenda`, when the
   request contains exactly one of `today`, `tomorrow`, `yesterday`, or a weekday name
   (`on monday` … `on sunday`, meaning the next such day, or today if it is that day), and no
   explicit `YYYY-MM-DD`, set `date` from `now`/`calendar`. Keep the existing "today" and
   "explicit historical date" behaviour and their self-test checks
   (`RealtimeAgentToolLoopSelfTest.swift:521-535`).

**Do not:**
- Do not hand a **denial** back to the model (the original comment at `ToolLoop:1078-1079` is
  right for denials: an optimistic rewrite of a refused write is the danger).
- Do not retry a write whose outcome is unknown; only errors thrown before commit are
  recoverable.
- Do not let bare JSON or prose become a call unless its name is a known tool of this turn.
- Do not change what `calls(in:)` returns for prose ("prose alone produced a call" in
  `NextNotesApp.swift:3983` must stay green).
- Do not exceed 2 repairs per turn, and count repairs toward `maxCalls`.
- Do not print the raw `excerpt` of a malformed call to the user (it goes to the model and the
  audit log only).
- Do not guess a model family's control-token syntax; add recognisers only for captured output.
- (H-audit 2026-09-23) Do not re-run a repeated call to "refresh" its result, and do not
  hand back the "already ran" note more than once per turn; the second repeat ends the plan.

**Red-first self-test:** extend `--selftest-toolloop-production`
(`RealtimeAgentToolLoopSelfTest.run()`), using P1-01's `AgentToolExecutor.fakeForTesting` and
a scripted multi-round provider. Each case asserts the fake log and that the final reply has
no "did not run", "unavailable tool", "invalid tool request" or markup:
1. Hermes call with `"parameters":{}` for `computer.active_app` → executes (red today: runs
   with empty arguments — use a tool with a required argument, `computer.open_app`
   `{"name":"Safari"}`, so the red is visible as a missing-argument outcome).
2. Qwen3-Coder XML `<function=search_email><parameter=query>in:inbox</parameter></function>` → `search_email` executes.
3. Attribute XML `<function name="get_agenda"><parameter name="date">2026-09-24</parameter></function>` → executes.
4. Alias `files.find` → executes `filesystem.find`.
5. Near miss `get_calender` → executes `get_agenda`.
6. Unknown `launch_rocket` → one repair round whose user message contains `ERROR unknown_tool`
   and at least one valid id; the script's next round calls `get_agenda` → executes.
7. Recoverable: the fake throws `AgentError.notFound("No app called “Claude Code”… Claude, ChatGPT")`
   on the first `computer.open_app`; the next round (script reads `ERROR not_found`) calls it
   with `"Claude"` → success; final reply names Claude.
8. Truncated: `<tool_call>{"name":"draft_email","arguments":{"to":"a@b.com","body":"…` (no
   close) → a repair round with `ERROR truncated_call`; the script then emits it whole →
   `draft_email` logged.
9. Denial: the fake throws `AgentError.permissionDenied("You declined.")` → the turn ends with
   that sentence and the provider is **not** called again.
10. Repair cap: the script emits an unknown tool three times → exactly 2 repair rounds, then a
    plain sentence; the provider is called 3 times, not more.
11. Parser table: 15 `(input, expected calls, expected malformed)` rows called from the same
    run through `AgentToolCallParser.parse` — including `"I would send an email."` → nothing,
    `<think>…</think><tool_call>{…}</tool_call>` → one call, and each captured control-token
    sample from P0-04.
12. `groundedArguments`: "What do I have tomorrow?" with a proposed stale date → tomorrow's
    date for a fixed `now`.
13. (H-audit 2026-09-23) Repeated call: the script emits
    `get_agenda {"date":"2026-09-24"}` in round 1, the identical call in round 2, and "You
    have two events tomorrow." in round 3 → the fake log has `get_agenda` exactly **once**;
    the round-3 user message contains "You already ran get_agenda with these arguments";
    the final reply is "You have two events tomorrow." and does not contain "repeated a
    completed step". Variant 13b: the script repeats the identical call in rounds 2 **and**
    3 → the fourth provider call carries no tool catalogue (P1-06's final answer-only round;
    assert its system prompt lacks `"Available tools:"`) and the reply contains the
    `get_agenda` result text. Before P1-06 lands, 13b asserts the reply is non-empty and
    contains the result text (from `lastVerifiedResult`).
Each check prints `  TOOLLOOP_PRODUCTION_WRONG: <reason>` on failure; the marker stays
`TOOLLOOP_PRODUCTION_OK`/`_FAILED`. Confirm red: cases 1, 2, 3, 5, 6, 7, 8, 10 and 13 fail on
the unmodified loop.

**Verify:**
```bash
make build
make install OPEN=0
Scripts/run-selftest.sh --selftest-toolloop-production
Scripts/run-selftest.sh --selftest-toolloop
Scripts/run-selftest.sh --selftest-memory-review
Scripts/run-selftest.sh --selftest-meeting-reconcile
Scripts/run-selftest.sh --selftest-function-calls
Scripts/run-selftest.sh --selftest-computer-actions   # red on a locked screen by design (AGENTS.md)
Scripts/run-selftest.sh --selftest-toolloop-live --only R02,C02,C03,P01
Scripts/run-selftest.sh --selftest-toolloop-live --quick \
  --report "$PWD/Tests/Reports/toolloop-live/$(date +%F)-P1-04-quick.md"
```

**Success threshold:** `TOOLLOOP_PRODUCTION_OK` with all thirteen cases (red first; 13b in its pre- or post-P1-06 form);
`--selftest-toolloop`, `--selftest-memory-review`, `--selftest-meeting-reconcile` unchanged.
Eval: `LEAK` = 0; R02 and C02/C03/P01 no longer fail on syntax or date; no reply contains
"did not run" or "unavailable tool"; the `--quick` score ≥ the previous quick run on the same model.

**Risks & rollback:** A tolerant parser can read a call the model did not mean (bare JSON in an
explanation). Mitigation: bare JSON only for known names, only at the start or in a fence.
Repairs cost rounds (prefill); the cap of 2 bounds it, and P1-06's per-round budget bounds each.
Rollback: the planner entry point is separate from `calls(in:)`; reverting the loop's use of
`parse(_:knownNames:)` restores today's parsing without touching meeting callers.

**Done when:**
- [ ] Thirteen new cases green (red first), and the regression flags above unchanged.
- [ ] (H-audit 2026-09-23) `grep -n "repeated a completed step" Sources/NextNotes/Agent/RealtimeAgent+ToolLoop.swift` finds no user-facing return (or only the pre-P1-06 fallback marked `// P1-06`).
- [ ] `grep -rn "requested an unavailable tool\|returned an invalid tool request" Sources/NextNotes` finds no user-facing return.
- [ ] Eval report `…-P1-04-quick.md` with 0 `LEAK`; delta in `STATUS.md`.

---

### P1-05 — Native / constrained tool calling: Apple FM `Tool`, GBNF over the manifest for llama, OpenAI `tools` for cloud

**Finding(s):** T4 long term; B §4 rec. 2. **Effort:** 1 week. **Depends on:** P1-03 (schemas come from the manifest), P1-04 (shared outcome/repair types), P0-04 (the llama prompt uses the model's own template), P0-07 (`mayCommitEffect` in the Apple FM bridge), P1-06 (budgets). **Unblocks:** P3-05 (frontend tools reuse the Apple FM bridge), P3-07 (`LocalToolLoopWorker`).

**Why (what the user experiences today):** Even with P1-04's tolerant parser, a 4B model writing
free text can produce a call for a tool that is not offered, an argument object of the wrong
shape, or a call cut off mid-JSON; each costs a repair round (2.5–5.2 s of prefill per round on
llama, B §1). Constrained decoding makes those failures impossible instead of repairable: the
sampler cannot emit an unknown tool name or a malformed argument object. The repo already does
this for meeting follow-ups (`LocalModelFunctionCallProposer.grammar(for:)`,
`Agent/FunctionCalling/LocalModelFunctionCallProposer.swift:186-199`); the live planner uses
neither grammar nor native tools.

**Files you will change:**
- New `Agent/Planner/AgentPlannerBackend.swift` — `AgentPlannerBackend`, `PlannerRound`,
  `PlannerBackends.make(for:)`.
- New `Agent/Planner/ToolStepRunner.swift` — one call's execution semantics, shared by the
  loop and the Apple FM bridge.
- New `Agent/Planner/LlamaGrammarPlanner.swift`, `FoundationModelsToolPlanner.swift`,
  `OpenAIToolsPlanner.swift`, `PromptConventionPlanner.swift` (today's behaviour, the
  fallback).
- New `Agent/Planner/NativeToolsSelfTest.swift` — `--selftest-native-tools`.
- `Formatting/LLM/GBNFGrammar.swift` — add `GBNFSchema.oneOf` and a free-text rule.
- `Formatting/LLM/NotesModelRuntime.swift` — `grammar:` on `streamConversation` /
  `streamInteractiveConversation` / `streamPrompt` (sampler at `:599`).
- `Formatting/LLM/LlamaLLMProvider.swift` — pass-through for the new grammar parameter.
- `Formatting/LLM/OpenRouterLLMProvider.swift` — `chatBody` (`:564-583`) gains `tools`,
  `tool_choice`; stream parsing of `tool_calls` (reuse
  `OpenAICompatibleLLMProvider.ToolCallAccumulator`, `:232-258`).
- `Formatting/LLM/OpenAICompatibleLLMProvider.swift` — send `tools` when a manifest is given.
- `Agent/LLMProviderTools.swift` — rewrite the header comment (`:1-14`).
- `Agent/RealtimeAgent+ToolLoop.swift` — the private `runPlannedToolLoop` asks a backend for
  each round instead of calling `provider.stream…` directly (`:882-913`), and delegates each
  call to `ToolStepRunner`.
- `Support/Settings.swift` — hidden `agentNativeToolCalling` (default `true` once the gate
  below passes; defaults key only, no UI).
- `NextNotesApp.swift`, `Scripts/acceptance.sh`, `AGENTS.md`.

**Read for context (do not change):** `Agent/FunctionCalling/LocalModelFunctionCallProposer.swift:100-199`
(grammar build + "a provider that cannot constrain decoding … grammar is used as a check"),
`Formatting/LLM/GBNFGrammar.swift` (builder rules: rule names `[a-z0-9-]`, bounded strings),
`Formatting/LLM/FoundationModelLLMProvider.swift`, `Memory/MemoryReviewAppleModel.swift:14-30`
(the app's existing `@Generable` use), the SDK interface
`FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface` (`protocol Tool` at `:3054-3063`,
`DynamicGenerationSchema` at `:3151-3176`, `GenerationSchema(root:dependencies:)` at `:3370`,
`LanguageModelSession.tokenCount(for tools:)` macOS 26.4+ at `:419-422`).

**Current behaviour:**
- Every backend gets the catalogue as prose in the system prompt and is asked to write
  `<tool_call>{json}</tool_call>` (`ToolLoop:673-674`); the loop parses text.
- `LlamaLLMProvider.enforcesGrammar` is true (`LlamaLLMProvider.swift:56`) but only
  `complete(…grammar:)` (a background-lane, non-streaming call, `NotesModelRuntime.swift:407-412`)
  takes a grammar; the stream path uses `grammar: nil` (`:599`).
- `GBNFSchema` (`GBNFGrammar.swift:63-72`) has no alternative-of-objects case; objects have
  all keys required and ordered ("optional values are `.nullable`").
- Apple FM (`FoundationModelLLMProvider`) creates a plain `LanguageModelSession(instructions:)`
  per call (`:34`, `:69`) with no tools. `LLMProviderTools.swift:10-14` records why `Tool` was
  rejected.
- OpenRouter's `chatBody` sends no `tools`; `OpenAICompatibleLLMProvider` (Ollama/LM Studio)
  already turns a server's structured `tool_calls` back into Hermes tags (`:196-214`).

**Target behaviour:**
- The planner loop asks an `AgentPlannerBackend` for one round at a time and never parses
  free text when the backend can do better:

  | Reader | Backend | How a call is produced | How it is read |
  |---|---|---|---|
  | `.appLLM` (llama.cpp, any GGUF) | `LlamaGrammarPlanner` | the model's own chat template (P0-04) + the Hermes instruction; decoding constrained by a GBNF grammar generated from `manifest.selected`: the output is either plain answer text, or 1–3 `<tool_call>{…}</tool_call>` blocks whose `name` is an enumeration of selected ids and whose `arguments` object matches that tool's parameters | `AgentToolCallParser.parse` (P1-04), which cannot fail on grammar-valid text |
  | `.appleFoundation` | `FoundationModelsToolPlanner` | one `LanguageModelSession(tools:instructions:)` per turn, one `Tool` per selected entry (`Arguments = GeneratedContent`, `parameters` = a `GenerationSchema` built from `DynamicGenerationSchema`); Apple's model decides and emits calls natively | the framework hands `GeneratedContent` arguments to our `Tool.call`, which is a **bridge** into `ToolStepRunner` (the same executor, approvals, `mayCommitEffect`, budgets); the session continues with our returned text |
  | `.openRouter`, `.localServer` | `OpenAIToolsPlanner` | request body carries `tools: [{type:function, function:{name, description, parameters}}]` from `manifest.selected` and `tool_choice: "auto"` when the model supports tools (`OpenRouterModel.supportsTools`) | streamed `tool_calls` deltas reassembled by `ToolCallAccumulator` into `AgentToolCall`s directly (no tag round trip) |
  | anything else, or `agentNativeToolCalling == false`, or a model without tool support | `PromptConventionPlanner` | today's prose catalogue + Hermes instruction | P1-04's tolerant parser |
- On the live eval, parse failures (`MalformedCall`) and unknown-tool repairs are 0 on the
  llama and cloud backends.

**Steps:**

1. **Backend protocol** (`Agent/Planner/AgentPlannerBackend.swift`):
   ```swift
   struct PlannerRound: Sendable {
       var text: String                 // answer text (already free of call markup)
       var calls: [AgentToolCall]       // canonical names are resolved by the loop (P1-04)
       var malformed: [MalformedCall]   // always empty for grammar/native backends
       var raw: String                  // for PlannerTraceEvent and the audit log
   }
   protocol AgentPlannerBackend: Sendable {
       /// One model round. Never executes a tool.
       func round(system: String, messages: [LLMChatMessage], manifest: AgentCapabilityManifest,
                  maxTokens: Int, interactive: Bool,
                  onText: @Sendable (String) async -> Void) async throws -> PlannerRound
   }
   /// Backends that run the whole loop inside the model framework (Apple FM).
   protocol AgentWholeTurnPlanner: Sendable {
       func runTurn(system: String, request: String, manifest: AgentCapabilityManifest,
                    runner: ToolStepRunner, budget: ToolLoopBudget) async throws -> String
   }
   enum PlannerBackendChoice: Sendable {
       case rounds(any AgentPlannerBackend)        // llama grammar, OpenAI tools, prompt convention
       case wholeTurn(any AgentWholeTurnPlanner)   // Apple FM
   }
   enum PlannerBackends {
       @MainActor static func make(for provider: any LLMProvider, manifest: AgentCapabilityManifest,
                                   forced: PlannerMode? = nil) -> PlannerBackendChoice
   }
   enum PlannerMode: String, Sendable { case native, prompt }   // eval's --planner; nil = setting
   ```
   `onText` feeds `AgentToolSpeechTracker.receive` (it already ignores text starting with `<`
   or `{`, `ToolLoop:116`).

2. **`ToolStepRunner`** (`Agent/Planner/ToolStepRunner.swift`): move the per-call body of the
   loop (`ToolLoop:953-1083`: name resolution, grounded arguments, signature dedupe, budget
   check, provenance, `AgentToolExecutor.run`, artifact capture, `VisionHandoff`, outcome
   classification, result cap from P1-10, memory confirmations, untrusted-output bookkeeping)
   into
   ```swift
   @MainActor final class ToolStepRunner {
       init(agent: RealtimeAgent, owner: Int, work: VoiceConversationWork?, provider: any LLMProvider,
            manifest: AgentCapabilityManifest, budget: ToolLoopBudget, request: String)
       func execute(_ call: AgentToolCall) async -> ToolStepOutcome
       private(set) var completedToolIDs: [String]
       private(set) var lastVerifiedResult: String?
       private(set) var memoryConfirmations: [String]
       private(set) var repairs: Int
       private(set) var terminal: ToolStepOutcome?   // set on .denied / .infrastructure / cap reached
   }
   ```
   Before any call with `tool.risk > .read`, `execute` passes `AgentToolExecutor.run` an
   `isStillValid` closure that awaits P0-07's `RealtimeAgent.mayCommitEffect(risk:)` and then
   checks owner and revision, exactly as the loop's closure does after P0-07 (Phase 0 file,
   P0-07 step 5) — the only place the voice input barrier applies to an effect. (P3-02 later
   moves the gate to `TaskBridge.mayCommitEffect(_:revision:risk:)`; keep one call site so
   that move is a one-line change.) The loop and the Apple FM bridge both call `execute`; nothing else runs a tool.

3. **llama: grammar over the manifest** (`LlamaGrammarPlanner`).
   a. Extend `GBNFSchema` with `case oneOf([GBNFSchema])` (rendered as
      `( a | b | … )`, each branch its own rule named `<name>-<index>`; update `==`) and
      `case freeText(maxCharacters: Int)` — a rule whose first character is not `<`, `{`, `[` or
      whitespace, followed by up to N characters (`[^\x00]`), used for plain answers. Keep every
      string bounded (the builder's own rule).
   b. `static func grammar(for manifest: AgentCapabilityManifest, maxCalls: Int = 3) -> GBNFGrammar`:
      ```
      root      ::= answer | calls
      answer    ::= <freeText, maxCharacters = 4 × maxTokens>
      calls     ::= call (ws call){0,2}
      call      ::= "<tool_call>" ws callbody ws "</tool_call>"
      callbody  ::= ( tool-get-agenda | tool-search-email | … one branch per selected entry )
      tool-X    ::= "{" ws "\"name\"" ws ":" ws "\"X\"" ws "," ws "\"arguments\"" ws ":" ws args-X ws "}"
      args-X    ::= object of the entry's parameters, in declaration order;
                    required → .string(maxLength: 240, or 2000 for `.multiline`);
                    optional → .nullable(.string(…))
      ```
      Build it with `GBNFSchema` (never by hand) so the decoder and the grammar cannot drift;
      rule names are sanitised by the builder. The call body stays Hermes JSON because that is
      what the prompt describes and what P1-04 parses; `null` values are dropped by the parser.
   c. Run `grammar.structuralProblems()` (`GBNFGrammar.swift:36-49`) once per manifest; a
      non-empty result logs and falls back to `PromptConventionPlanner` for that turn.
   d. `NotesModelRuntime`: add `grammar: GBNFGrammar? = nil` to `streamConversation`,
      `streamInteractiveConversation` and the private `streamPrompt`, and pass it to
      `makeSampler(vocabulary:grammar:)` at `:599`. A grammar the native parser refuses throws
      `LlamaError.grammarInvalid` before prefill (same as `complete`). Mirror the parameter in
      `LlamaLLMProvider` and in the `LLMProvider` protocol extension (default: ignore).
   e. Special tokens: the grammar operates on decoded text; with P0-04 rendering special tokens,
      a model that would emit a control-token call is masked to the Hermes text form the prompt
      describes. Verify with `--selftest-chat-template` that the template in use does not end
      the assistant turn with a token the grammar forbids (the end-of-generation token must be
      allowed once `root` is complete — llama's grammar sampler handles this).

4. **Apple FM: the `Tool` protocol with an executor bridge** (`FoundationModelsToolPlanner`).
   a. One tool per selected entry:
      ```swift
      import FoundationModels
      struct ManifestTool: Tool {
          let name: String                       // entry.id with "." → "_" (FM tool names are identifiers); keep a map back
          let description: String                // entry.modelDescription
          let parameters: GenerationSchema
          let bridge: @Sendable (AgentToolCall) async -> String
          func call(arguments: GeneratedContent) async throws -> String {
              var args: [String: String] = [:]
              for key in parameterNames { if let v = try? arguments.value(String.self, forProperty: key), !v.isEmpty { args[key] = v } }
              return await bridge(AgentToolCall(name: canonicalID, arguments: args, rationale: "", evidence: nil))
          }
      }
      ```
      `parameters` = `try GenerationSchema(root: DynamicGenerationSchema(name: safeName,
      description: entry.modelDescription, properties: entry.parameters.map {
      .init(name: $0.name, description: $0.description, schema: .init(type: String.self),
      isOptional: !$0.isRequired) }), dependencies: [])`. Arguments stay strings, matching
      `WorkspaceTool.Parameter.schema` ("Everything is a string",
      `Agent/WorkspaceTools.swift:49-52`).
   b. The bridge calls `runner.execute(call)` and maps the outcome to text the model reads:
      `.success(s)` → `s` (already capped by P1-10); `.recoverable(r)` → `r.modelText`;
      `.denied`/`.infrastructure` → "STOP: <sentence>. Do not call more tools; tell the user
      this in one sentence." and `runner.terminal` is set; budget exhausted → "STOP: out of
      time. Answer now with what you have." Never throw from `call` for these (a throw aborts
      the whole response with `LanguageModelSession.ToolCallError`).
   c. `runTurn`: `let session = LanguageModelSession(tools: tools, instructions: system)`;
      `let response = try await withBoundedWait(budget.ceiling) { try await session.respond(to: request, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: maxTokens)) }`.
      On timeout, the bridge's `STOP` path and the ceiling both end it; render from
      `runner.lastVerifiedResult` (P1-10).
   d. Context: before creating the session, if `#available(macOS 26.4, *)`, measure
      `try await session.tokenCount(for: tools)`; if instructions + tools exceed ~2,600
      tokens, rebuild the manifest compact (P1-03 step 3.4) and retry once. Below 26.4 use the
      characters/4 estimate.
   e. Rewrite `Agent/LLMProviderTools.swift:1-14`: tool calling is native where the runtime
      supports it (`Tool` with `DynamicGenerationSchema` for Apple, grammar for llama, `tools`
      for OpenAI-compatible); the model still only *names* a call — the `Tool.call` body is a
      bridge into `AgentToolExecutor`, so every write is still a question for a person first.

5. **OpenAI-compatible `tools`** (`OpenAIToolsPlanner`).
   a. `AgentCapabilityManifest.openAITools() -> [[String: Any]]`: for each selected entry,
      `["type": "function", "function": ["name": entry.id, "description": entry.modelDescription,
      "parameters": ["type": "object", "properties": …, "required": …]]]` — the same shape
      `AgentTool.schemaJSON(for:)` already emits (`Agent/Tools/AgentTool.swift:81-102`); reuse it.
      Tool names with `.` are legal for OpenAI-style APIs (pattern `^[a-zA-Z0-9_.-]{1,64}$`);
      if a server rejects them, map `.` → `__` and keep a reverse map.
   b. `OpenRouterLLMProvider.chatBody` (`:564-583`) gains `tools: [[String: Any]]? = nil`; when
      non-nil and the configured model's `supportsTools` is true, add `"tools"` and
      `"tool_choice": "auto"`. Parse `choices[0].delta.tool_calls` in the stream with the
      accumulator (move `ToolCallDelta`/`ToolCallAccumulator` from
      `OpenAICompatibleLLMProvider` to a shared file) and return `AgentToolCall`s, not tags.
      `OpenAICompatibleLLMProvider` gains the same `tools` field for Ollama/LM Studio.
   c. The previous round's calls and results go back as `role: "assistant"` with `tool_calls`
      and `role: "tool"` messages (`tool_call_id` from the stream), not appended to the user
      text. This needs `LLMChatMessage` to carry optional `toolCalls`/`toolCallID`
      (`Formatting/LLM/LLMProvider.swift:219-223`); add them as optional fields with defaults.
   d. Cloud consent is unchanged: the manifest already excluded what a cloud reader may not
      see (P1-03 step 4).

6. **Loop integration** (private `runPlannedToolLoop`, `ToolLoop:790-1087`): pick the backend
   once per turn; for `AgentWholeTurnPlanner` call `runTurn` and return; otherwise replace the
   `provider.stream…`/`streamInteractiveConversation` block (`:882-913`) with
   `backend.round(…)`, and the per-call body with `runner.execute`. Keep the voice-input waits
   (`:864`, `:915`, `:954`) where they are until P3-02 moves the barrier.

7. **Rollout.** `Settings.agentNativeToolCalling` (defaults key `agentNativeToolCalling`,
   default `false` while developing). Flip the default to `true` only after the success
   threshold below is met on both the Agent-role model and Apple FM. The eval gains
   `--planner native|prompt` to force one path for comparison.

**Do not:**
- Do not let a `Tool.call` body run anything except through `ToolStepRunner` →
  `AgentToolExecutor.run`; never auto-approve a write because the framework "called" it.
- Do not throw from `Tool.call` for denials or budget exhaustion (it aborts the response);
  return a `STOP:` text and record `runner.terminal`.
- Do not write GBNF by hand or leave a string unbounded; build it from `GBNFSchema`.
- Do not send `tools` to a cloud model whose catalogue entry lacks tool support, and do not
  widen what a cloud reader sees beyond the manifest.
- Do not remove `PromptConventionPlanner`; it is the fallback for models and servers without
  native support and the rollback path.
- Do not use `MainActor.assumeIsolated` in the bridge (the `Tool.call` runs off the main actor;
  hop with `await MainActor.run`).
- Do not change `LocalModelFunctionCallProposer.grammar(for:)`'s output; extend
  `GBNFSchema` additively so `--selftest-function-calls` stays green.

**Red-first self-test:** new flag **`--selftest-native-tools`** in
`Agent/Planner/NativeToolsSelfTest.swift`, INTEGRATION tier (`"selftest-native-tools|600"`).
Deterministic half (no model, must pass everywhere):
1. For a fixture manifest (P1-03 inputs, 12 selected tools), `LlamaGrammarPlanner.grammar`
   has no `structuralProblems()`; `matches` accepts a plain answer, one valid call per
   selected tool (required args filled, optional `null`), and two calls in a row; rejects an
   unknown tool name, a missing required argument, an extra argument key, `"parameters"` in
   place of `"arguments"`, and a call with no closing tag.
2. `GBNFSchema.oneOf` round-trips through `structuralProblems()` and `matches` on a small
   fixture (proves the extension).
3. Every selected entry produces a `GenerationSchema` without throwing (Apple FM tool build).
4. `OpenRouterLLMProvider.chatBody(…, tools:)` JSON contains `tools[*].function.name` for each
   selected id and `"tool_choice":"auto"`; a canned SSE stream with split `tool_calls` deltas
   yields the right `AgentToolCall`s.
Live halves (each prints its own sub-line; `_ABSENT` when its backend is missing):
5. llama (if the Agent role resolves to a GGUF, adopted as in P1-01 step 4): five prompts
   ("what's on my calendar tomorrow", "summarise my last emails", "remind me at 9 to call the
   bank", "open youtube", "hi") through `LlamaGrammarPlanner.round` with the executor fake →
   100% of rounds are grammar-valid; the four tool prompts produce a call to an expected id;
   "hi" produces text.
6. Apple FM (if available): the same five through `FoundationModelsToolPlanner.runTurn` with
   the executor fake → the fake log has `get_agenda` (date = tomorrow), `search_email`,
   `schedule.create`, `browser.navigate`; "hi" produces no call.
7. Cloud: only with `--allow-cloud` and an OpenRouter key; otherwise
   `NATIVE_TOOLS_CLOUD_ABSENT`.
Final line: `NATIVE_TOOLS_OK: deterministic + <backends that ran>` when the deterministic half
passed and at least one live half ran and passed; `NATIVE_TOOLS_ABSENT: no live backend` when
none could run; otherwise `NATIVE_TOOLS_FAILED: <n> problems`. Red first: before step 3a, case 1
cannot build (no `.oneOf`); write the test first against a stub that returns today's
prompt-convention behaviour and watch cases 1, 2 and 5 fail.

**Verify:**
```bash
make build
make install OPEN=0
Scripts/run-selftest.sh --selftest-native-tools
Scripts/run-selftest.sh --selftest-function-calls
Scripts/run-selftest.sh --selftest-toolloop-production
Scripts/run-selftest.sh --selftest-llm-metal
Scripts/run-selftest.sh --selftest-toolloop-live --planner native \
  --report "$PWD/Tests/Reports/toolloop-live/$(date +%F)-P1-05-native.md"
Scripts/run-selftest.sh --selftest-toolloop-live --planner prompt \
  --report "$PWD/Tests/Reports/toolloop-live/$(date +%F)-P1-05-prompt.md"
Scripts/run-selftest.sh --selftest-toolloop-live --model apple --planner native \
  --report "$PWD/Tests/Reports/toolloop-live/$(date +%F)-P1-05-apple-native.md"
```
(`--planner native|prompt` sets the backend for the eval process only; it never writes the
user's preferences. Do not use `defaults write` to switch the flag on this Mac.) Iterate with
`--quick` on each backend. The three **full** runs above are needed once, just before flipping the
default, because the flip changes every case (P1-01 step 8b).

**Success threshold:** `NATIVE_TOOLS_OK` (deterministic half + llama and/or Apple FM).
Eval with `--planner native`: score ≥ the `--planner prompt` score on the same build, on both
the Agent-role model and Apple FM; 0 `LEAK`; 0 malformed-call repairs in the trace. Only then
flip `agentNativeToolCalling` to default `true`.

**Risks & rollback:** Grammar-constrained decoding can reduce answer quality (the model is
masked away from its preferred phrasing) — compare N-cases between the two eval runs. Apple
FM's internal loop hides round-by-round timing; the bridge logs each call with elapsed time.
FM tool names must be identifiers; keep the `.`↔`_` map in one place. Rollback: set
`agentNativeToolCalling` false (the prompt-convention backend is today's behaviour plus P1-04).

**Done when:**
- [ ] `--selftest-native-tools` OK (red first), `--selftest-function-calls` unchanged.
- [ ] Native vs prompt eval reports saved; native ≥ prompt on both models; default flipped.
- [ ] `Agent/LLMProviderTools.swift` header comment rewritten; `ToolStepRunner` is the only
      caller of `AgentToolExecutor.run` inside the planner.
- [ ] AGENTS.md: flag listed; one paragraph on the three backends and the bridge rule.

---

### P1-06 — Per-round budget with a ceiling

**Finding(s):** T5 (B D4); H1 #17, #18, #19, #30 (H-audit 2026-09-23). **Effort:** 1–1.5 days (was 0.5–1; +0.5 day for steps 8–11). **Depends on:** P1-01, P1-02 (the typed first pass and its own 18 s are gone; P1-02 step 6 supplies `window`/`depth`). **Unblocks:** P1-04 (its second repeated call ends through the final round), P1-05 (budgets passed to the backends), P3-07.

**Why (what the user experiences today):** "Check my email, check the last email and then do a
summary" (09-15 01:13Z) ended "…I stopped the tool plan because it took too long. Remaining
steps are unfinished." A typed local plan gets **18 s for all rounds together**
(`ToolLoop:796-798`), while one local round is 2.5–5.2 s of prefill plus up to the round's
output tokens (B §1, measured in `metrics.jsonl`), so "search, then read, then summarise"
cannot fit. A voice worker gets 120 s — the reverse of what the user sees, since a typed user
is watching the screen.

**Files you will change:**
- New `Agent/ToolLoopBudget.swift`.
- `Agent/RealtimeAgent+ToolLoop.swift` — budget selection (`:796-801`), round wait
  (`:880-914`), read-call wait (`:1034-1041`), cold detection (move from `:383-385`),
  progress titles.
- `Agent/RealtimeAgent.swift` — replace `toolLoopLimitForTesting` (`:121`) with
  `budgetForTesting: ToolLoopBudget?`; `Limits.modelWarm`/`modelCold` (`:31-32`) stay only for
  the voice test-path header pass.
- `Agent/RealtimeAgentToolLoopSelfTest.swift` — the timeout fixture at `:538-553` and new cases.

**Read for context (do not change):** `Core/DictationController.swift:78` (`withBoundedWait`,
a latch, not a task group — AGENTS.md explains why), `Agent/Activity/AgentActivityProjector.swift:7`
(`title(for:arguments:)`), `Formatting/LLM/NotesModelRuntime.swift` (`isLoaded`).

**Current behaviour:**
```swift
// ToolLoop:796-801
let duration = toolLoopLimitForTesting
    ?? (isVoiceWorker ? .seconds(120) : provider.id == .openRouter
        ? Duration.seconds(75) : Duration.seconds(18))
var remainingBudget = duration
```
`remainingBudget` is charged for each model round (`:914`) and each read call (`:1038-1040`);
writes are not bounded (`:1035-1036`, correct: a write may be waiting for approval). There is
no per-round deadline, no cold-load allowance on the planner, and no progress update between
rounds.

**Target behaviour:**
- A plan has a **per-round** deadline and an overall **ceiling** on model and read compute
  (user speech and approval waits are never charged):

  | Turn | per round | per read call | ceiling | cold-load allowance (first round, local model not loaded) |
  |---|---|---|---|---|
  | typed, local model (`.appLLM`, `.appleFoundation`, `.localServer`) | 30 s | 20 s | 120 s | +45 s |
  | typed, OpenRouter | 45 s | 30 s | 150 s | 0 |
  | voice worker (background) | 45 s | 20 s | 120 s | +45 s |
  | voice interactive (test-only path) | 15 s | 10 s | 30 s | 0 |

- A round that exceeds its deadline or a ceiling that runs out ends the plan and **answers from
  the last verified result** when there is one.
- Between rounds the pane/island shows what is happening in the user's words (the running
  tool's activity title).

**Steps:**
1. New `Agent/ToolLoopBudget.swift`:
   ```swift
   struct ToolLoopBudget: Sendable, Equatable {
       var perRound: Duration
       var perReadCall: Duration
       var ceiling: Duration
       var coldLoadAllowance: Duration

       static let typedLocal       = ToolLoopBudget(perRound: .seconds(30), perReadCall: .seconds(20), ceiling: .seconds(120), coldLoadAllowance: .seconds(45))
       static let typedCloud       = ToolLoopBudget(perRound: .seconds(45), perReadCall: .seconds(30), ceiling: .seconds(150), coldLoadAllowance: .zero)
       static let voiceWorker      = ToolLoopBudget(perRound: .seconds(45), perReadCall: .seconds(20), ceiling: .seconds(120), coldLoadAllowance: .seconds(45))
       static let voiceInteractive = ToolLoopBudget(perRound: .seconds(15), perReadCall: .seconds(10), ceiling: .seconds(30), coldLoadAllowance: .zero)

       static func forTurn(provider: LLMProviderID, voice: Bool, background: Bool) -> ToolLoopBudget {
           if background { return .voiceWorker }
           if voice { return .voiceInteractive }
           return provider == .openRouter ? .typedCloud : .typedLocal
       }
   }
   ```
   The numbers are the decision document's (§3.2 T5: "~30 s per round, ~120 s ceiling"); the
   45 s cold allowance is today's `Limits.modelCold` (`RealtimeAgent.swift:32`, measured cold
   load 18.1 s on 09-14 plus prefill).
2. In the private `runPlannedToolLoop` replace `duration`/`remainingBudget` with
   `let budget = budgetForTesting ?? ToolLoopBudget.forTurn(provider: provider.id, voice: voice, background: background)`,
   `var ceilingRemaining = budget.ceiling`, and
   `let cold = provider.id == .appLLM && localModelProviderForTesting == nil ? !(await NotesModelRuntime.shared.isLoaded) : false`
   (for the eval, `budgetForTesting` stays nil and `cold` may be forced by
   `coldForTesting: Bool?`). If `cold`, `beginWork(title: "Loading the model…")`.
3. Each round: `let roundLimit = min(budget.perRound + (rounds == 0 && cold ? budget.coldLoadAllowance : .zero), ceilingRemaining)`;
   `withBoundedWait(roundLimit)`; charge `ceilingRemaining` with the elapsed time.
4. Each read call: `withBoundedWait(min(budget.perReadCall, ceilingRemaining))`; charge it.
   Writes stay unbounded (keep the comment at `:1031-1033`).
5. On a round or read timeout, or `ceilingRemaining <= .zero`: return through the existing
   `incomplete(…)` helper (`:849-862`) so the last verified result leads the reply. Do not
   change its wording here — P1-10 replaces it and inverts the self-test that pins it.
6. Progress: after each successful call,
   `beginWork(title: AgentActivityProjector.title(for: tool, arguments: arguments))`; before a
   second or later round, `beginWork(title: "Putting it together…")`. These are user words;
   they must pass `--selftest-ui-strings`' banned list if shown in `UI/`.
7. Remove `toolLoopLimitForTesting` and update its two users in
   `RealtimeAgentToolLoopSelfTest.swift` (`:538-541` and wherever else `grep` finds it).
   (H-audit 2026-09-23) `grep` also finds it in `Agent/VoiceWorkLifecycleSelfTest.swift:16,19,47`
   (`agent.toolLoopLimitForTesting = .milliseconds(120)` / `.seconds(1)`); migrate those to
   `budgetForTesting` with the same totals as `ceiling` and `perRound`.

**Anchors re-verified 2026-09-24 (H-audit 2026-09-23).** The line numbers above have drifted:
the budget selection is now `ToolLoop:817-822` (`let duration = toolLoopLimitForTesting ?? (isVoiceWorker ? .seconds(120) : …)`),
the round charge `:935`, the revision `continue` `:938`
(`if revision != (work?.revision ?? 0) { continue }`), the read-call charge `:1065`,
`maxRounds`/`maxCalls` `:832-833`, the call-cap exit `:978-980`, and the round-exhaustion exit
`:1110-1111`. Grep the quoted code if they move again.

8. **Rounds follow calls (H-audit 2026-09-23, H1 #18).** Today
   `let maxRounds = AgentToolLoop.clampedMaxRounds(responsiveness.toolRoundLimit)`
   (`ToolLoop:832`; fast and balanced 4, deep 8, `Support/Settings.swift:79-84`,
   `Agent/AgentToolLoop.swift:17-25`). One rebuttal or one P1-04 repair at the default
   `balanced` then ends "search, read, summarise" (3 tool rounds + 1 answer round) with no
   answer. In the realtime planner only, set `let maxRounds = maxCalls + 2` (one answer
   round, one repair): fast 6, balanced and deep 10. Leave `AgentToolLoop.clampedMaxRounds`
   and `toolRoundLimit` as they are for `AgentToolLoop.run` (routines,
   `Agent/Schedules/ScheduledRunner.swift`), which this task does not change. Time is
   bounded by the budget above; the round count is only a backstop.

9. **One final answer-only round (H-audit 2026-09-23, H1 #18, #19).** Add a local function
   inside the private `runPlannedToolLoop`, beside `incomplete(…)` (`ToolLoop:870`):
   ```swift
   enum FinalRoundReason: String { case roundsExhausted, callsExhausted, repeatedCall }
   /// ONE model call with no tools. Uses what the plan already found. Never executes a call.
   func finalAnswerRound(reason: FinalRoundReason) async -> String {
       let finalSystem = Self.plannerRulesWithoutCatalogue(voice: voice)   // the planner rules minus "Available tools:" and the tool-call format
       let finalUser = AgentToolLoop.userMessage(original: lastGroundedPrompt, results: results)
           + "\n\nAnswer now from what you have; no tool calls."
       let promptTokens = (try? await provider.countTokens(finalSystem + "\n" + finalUser))
           ?? (finalSystem.count + finalUser.count) / 4
       let visible = AgentAnswerBudget.tokens(kind: .finalAnswer, contextTokens: window,
                                              promptTokens: promptTokens, depth: depth)
       Log.agent.info("tool plan final round · reason=\(reason.rawValue, privacy: .public) visible=\(visible)")
       let text: String? = await withBoundedWait(budget.perRound) {   // the per-round deadline; not charged to the ceiling
           (try? await provider.complete(system: finalSystem, user: finalUser, maxTokens: visible))?.text
       } ?? nil
       // A model that emits a call anyway: keep its prose, drop the call (P1-04's parser).
       let prose = text.map { AgentToolCallParser.parse($0, knownNames: []).prose } ?? ""
       guard !prose.isEmpty else {
           return incomplete("I couldn’t finish the tool plan within the safe limit.",
                             completed: completedToolIDs, inFlight: nil)
       }
       return confirmed(prose)          // `confirmed` keeps the memory confirmations
   }
   ```
   `groundedPrompt` is a per-round local inside the `while` loop (`ToolLoop:~891`), so add
   `var lastGroundedPrompt = prompt` before the loop and assign it each round right after
   `let groundedPrompt = contextSections.joined(separator: "\n\n")`; the round-exhaustion
   exit runs after the loop, where only `lastGroundedPrompt` is in scope.
   `window` and `depth` are the values P1-02 step 6 reads once per plan. `.finalAnswer`
   is P0-05's kind (wanted = the persona depth budget: fast 128, balanced 256, deep 500;
   capped by `window − promptTokens − 256`, floor 64). Before P1-04 lands, extract prose as
   `AgentToolCallParser.calls(in: text).isEmpty ? text : ""`. `plannerRulesWithoutCatalogue`
   is a small split of `plannerSystem` (P1-03 builds the catalogue from the manifest; this
   function returns the same rules with no catalogue and no tool-call format section).
   Route these exits through it:
   - round exhaustion (`ToolLoop:1110-1111`, `return incomplete("I couldn’t finish the tool plan within the safe limit.", …)`)
     → `return await finalAnswerRound(reason: .roundsExhausted)`;
   - the call cap (`ToolLoop:978-980`, `guard callsUsed < maxCalls else { return "I couldn’t finish the tool plan within the safe limit." }`)
     → `return await finalAnswerRound(reason: .callsExhausted)`. Today this exit bypasses
     `incomplete(…)` and drops `lastVerifiedResult` and the memory confirmations (H1 #19);
     the final round's fallback keeps both;
   - P1-04's second repeated call signature → `.repeatedCall`.
   Timeouts (round deadline, read deadline, ceiling) still return through `incomplete(…)`
   (step 5); the final round is for running out of rounds or calls, not of time.

10. **A revision restarts the round clock (H-audit 2026-09-23, H1 #17).** Today a round
    that finishes after the work item was revised is charged and the loop `continue`s with
    what is left (`ToolLoop:935-938`; the first pass does the same at `:461-464`), so a
    corrected voice objective starts with a partly spent budget. Measured (report M,
    09-14): three follow-up revisions ended "The model took too long to answer." 2–3 s
    after the follow-up arrived (17:47:00Z, 17:49:08Z, 17:49:31Z). Add
    `var seenRevision = work?.revision ?? 0` and `var lastRefill: ContinuousClock.Instant? = nil`
    before the loop. At the top of each round, when `(work?.revision ?? 0) != seenRevision`:
    ```swift
    seenRevision = work?.revision ?? 0
    if lastRefill.map({ $0.duration(to: clock.now) >= .seconds(10) }) ?? true {
        ceilingRemaining = max(ceilingRemaining, budget.ceiling / 2)
        lastRefill = clock.now
        Log.agent.info("tool plan ceiling refill · revision=\(seenRevision)")
    }
    // The next round's deadline is computed fresh from `budget.perRound` (step 3), so the
    // round clock restarts whether or not the ceiling was refilled.
    ```
    At most one refill per 10 s, so a stream of corrections cannot run forever.

11. **Delete the dead cloud branch (H-audit 2026-09-23, H1 #30).** In `RealtimeAgent.handle`
    (`RealtimeAgent.swift:379-387`), inside `case .calendar, .mail, .files, .drive, .computer:`
    the limit is `if case .toolLoop = intent, Settings.shared.agentModelProvider == .openRouter { Limits.cloudTool } else { Limits.tool }`.
    `intent` can never be `.toolLoop` inside that case, so `Limits.cloudTool`
    (`RealtimeAgent.swift:26`, 90 s) is unreachable. Replace the expression with
    `let limit = Limits.tool` and delete `Limits.cloudTool`. No behaviour change.

**Do not:**
- Do not charge time spent waiting for the user's voice floor (`waitForVoiceInput`) or for an
  approval card; AGENTS.md: "Model/read budgets exclude waiting for the user's floor or an
  approval."
- (H-audit 2026-09-23) Do not let the final answer-only round execute anything, send a
  catalogue, or run more than once per plan; and do not use it for timeouts.
- (H-audit 2026-09-23) Do not refill the ceiling more than once per 10 s, and do not reset
  `completedToolIDs`, `results` or `lastVerifiedResult` on a revision (completed results
  survive a correction; AGENTS.md "Voice work and output have separate lifetimes").
- (H-audit 2026-09-23) Do not change `AgentToolLoop.clampedMaxRounds` (routines use it).
- Do not put a deadline on a write (it may be waiting on a person; detaching it could say
  "stopped" while the write later commits, `ToolLoop:1031-1033`).
- Do not replace `withBoundedWait` with a task group (a group awaits every child, re-creating
  the wait it exists to remove).
- Do not throw away the last verified result on timeout.

**Red-first self-test:** extend `--selftest-toolloop-production` with a scripted provider that
sleeps per round:
1. `budgetForTesting = .init(perRound: .seconds(3), perReadCall: .seconds(3), ceiling: .seconds(20), coldLoadAllowance: .zero)`,
   script: 3 tool rounds (each 2 s) then an answer round (2 s), tools answered by the P1-01 fake
   → the final answer is returned (8 s total). **Red first:** write the test before step 2
   with `budgetForTesting` mapped onto the old total limit (`toolLoopLimitForTesting = perRound`);
   it must end with "took too long".
2. One round sleeps 4 s with `perRound` 3 s after a successful read → the reply begins with the
   fixture read result (last verified result kept).
3. Ceiling: six 2 s rounds, `ceiling` 7 s → stops after the ceiling; reply begins with the last
   fixture result.
4. Cold allowance: `coldForTesting = true`, `perRound` 3 s, `coldLoadAllowance` 3 s, first
   round sleeps 5 s → completes.
5. Existing fallback check (`:538-553`) migrated to `budgetForTesting` (its id/step assertions
   stay until P1-10 inverts them).
6. (H-audit 2026-09-23) Call cap: `answerDepthForTesting = .fast` (so `maxCalls` = 4,
   `maxRounds` = 6); the script emits one new read call per round forever (distinct
   arguments, each answered by the P1-01 fake with `"result-<n>"`) → exactly 4 fake calls;
   the fifth provider call's system prompt has no `"Available tools:"` and its user message
   ends with "Answer now from what you have; no tool calls."; its `maxTokens` equals
   `AgentAnswerBudget.tokens(kind: .finalAnswer, …, depth: .fast)` (≤ 128); the script's
   answer "Here is what I found: result-4." is the reply; the reply does not contain "safe
   limit". **Red today:** the reply is the bare "I couldn’t finish the tool plan within the
   safe limit." with no result.
7. (H-audit 2026-09-23) Round exhaustion: set `maxCallsForTesting = 20` (a test-only
   override of `maxCalls`, honoured only under `SelfTest.isRunning`) so rounds, not calls,
   run out first; `answerDepthForTesting = .fast` gives `maxRounds` = 6 from the real
   `maxCalls` 4 (the override raises only the call cap). The script emits one new read call
   per round → after round 6 exactly one final answer-only round runs (no catalogue) and
   the reply is its text. Assert the provider is called exactly `maxRounds + 1` = 7 times.
8. (H-audit 2026-09-23) Final round that disobeys: the final round's script emits a
   `<tool_call>` → nothing executes (fake log unchanged) and the reply begins with the last
   verified fixture result (the `incomplete` fallback).
9. (H-audit 2026-09-23) `maxRounds == maxCalls + 2` for all three depths (a pure check on a
   `static func plannerMaxRounds(maxCalls:) -> Int` helper the loop uses).

**Red-first case in `--selftest-voice-work-lifecycle` (H-audit 2026-09-23, H1 #17)**, in
`Agent/VoiceWorkLifecycleSelfTest.swift` (`VoiceWorkLifecycleSelfTest.run()`, marker
`VOICE_WORK_LIFECYCLE_OK` / `VOICE_WORK_LIFECYCLE_FAILED`, one
`VOICE_WORK_LIFECYCLE_WRONG: <reason>` line per failure; no microphone, no user-store
writes: `AgentSession.shared` is in-memory under the harness). Set
`agent.budgetForTesting = .init(perRound: .seconds(2), perReadCall: .seconds(1), ceiling: .seconds(3), coldLoadAllowance: .zero)`
and a scripted background worker whose first two rounds each take 1.4 s. After round 2
(ceiling left ≈ 0.2 s), call `agent.voiceWork?.append("and only the unread ones")`
(`VoiceConversationWork.append`, `Agent/VoiceConversationWork.swift:15-18`, bumps
`revision`); the script's next round takes 1.4 s and answers "Two unread messages." Assert
the reply is "Two unread messages." and does not contain "took too long". A second
`append` within 10 s followed by a 1.8 s round must **not** refill again (reply contains
"took too long" or the last verified result; assert the log line
`tool plan final round` is absent and `ceiling refill` was logged exactly once). **Red
today:** the revised round is charged against the spent budget and the reply is "The model
took too long to answer." / "…took too long…".

**Verify:**
```bash
make build
make install OPEN=0
Scripts/run-selftest.sh --selftest-toolloop-production
Scripts/run-selftest.sh --selftest-concurrent-voice
Scripts/run-selftest.sh --selftest-voice-work-lifecycle
Scripts/run-selftest.sh --selftest-toolloop-live --only C04,M03,M05,F03 
Scripts/run-selftest.sh --selftest-toolloop-live --quick \
  --report "$PWD/Tests/Reports/toolloop-live/$(date +%F)-P1-06-quick.md"
```

**Success threshold:** `TOOLLOOP_PRODUCTION_OK` with the four new cases (case 1 red first)
and the four H-audit cases 6–9 (case 6 red first); `VOICE_WORK_LIFECYCLE_OK` with the
revision case (red first). `grep -n "cloudTool" Sources/NextNotes/Agent/RealtimeAgent.swift`
finds nothing. Eval: 0 `TIMEOUT` verdicts on C04 and M03; total `TIMEOUT` count ≤ 1; no
case's wall time above 150 s; no reply in the report contains "within the safe limit" without
a result before it.

**Risks & rollback:** Longer budgets mean a stuck model holds the typed pane longer (up to
120 s + 45 s cold); the progress title makes that visible, and the island Stop still cancels
(`RealtimeAgent.cancel`). Rollback: set `ToolLoopBudget.typedLocal` to
`(18, 20, 18, 0)` to reproduce today's behaviour exactly.

**Done when:**
- [ ] Four new cases green (case 1 red first); `toolLoopLimitForTesting` removed.
- [ ] (H-audit 2026-09-23) Cases 6–9 green (6 red first); the `--selftest-voice-work-lifecycle` revision case green (red first); `maxRounds = maxCalls + 2`; call-cap and round exits go through `finalAnswerRound`; `Limits.cloudTool` deleted.
- [ ] Eval report `…-P1-06-quick.md`; C04/M03 not `TIMEOUT`; delta in `STATUS.md`.

---

### P1-07 — Voice rebuttal, first-denial escalation, question-form gates, pending action from a worker question

**Finding(s):** T8 (B D7), Q6 (the "wait for yes" half, only as it affects routing); H2 V13, V22 (H-audit 2026-09-23). **Effort:** 2 days. **Depends on:** P1-02 (`PendingAction`), P1-03 (manifest roster for the rebuttal and the gates), P0-07 (a failed or escalated frontend turn must resolve its epoch), **P1-14** (H-audit 2026-09-23: the capture layer must not erase a "yes" or "calendar" that repeats the agent's own words before it reaches the pending-action slot). **Unblocks:** P3-05, P3-08 (adopts this task's shared acknowledgment vocabulary).

**Why (what the user experiences today):** "What is on your to-do list for today?" (09-14
14:28Z) → *"I don't have access to your calendar or tasks."* and four more denials, each
reworded. "I cannot access your emails directly … paste the text" (09-14 17:44–17:48Z,
reworded four times). The voice answer stage streams straight to speech with no denial check;
the backstop fires only on the *second identical* denial; "what's on my calendar" and "any new
emails?" do not match the verb-AND-noun gate so they reach Apple FM's router; and when a
finished worker asks "Shall I set it for 10 pm?", the user's "okay" is treated as noise ("Sorry
— I didn't catch that.") and the reminder is never created.

**Files you will change:**
- `Agent/VoiceConversationCoordinator.swift` — `PendingIntent` (`:42-52`), pending check
  (`:357-367`), gates (`:368-378`), answer stream (`:436-448`), answer outcome (`:474-499`),
  `namesCapability` (`:646-663`), `submit` (`:688-705`).
- `Agent/AgentDirectIntent.swift` — new `questionRoutes`.
- `Agent/PendingAction.swift` (from P1-02) — `Origin.workerQuestion`, `.frontendOffer` used here.
- `Agent/VoiceCapabilityConversationSelfTest.swift` — `runTurnRouting()` (`:695-1070`) cases.
- (H-audit 2026-09-23) `Activation/VoiceTurnPolicy.swift` — `acknowledgmentKeys` and
  `isBareAcknowledgment` (`:78-87`), plus a case in `selfTestFailures()`.

**Read for context (do not change):** `Activation/VoiceTurnPolicy.swift:44-87`
(`knownNoiseFragments`, `isBareAcknowledgment`), `Formatting/LLM/LocalVoiceDecision.swift:145-156`
(answer rules: "no … promises to perform work"), `Agent/AgentRefusalGuard.swift` (after P1-03).

**Current behaviour:**
- Pending check (`Coordinator:357-367`): a fresh `pendingIntent` + `VoiceTurnPolicy.isBareAcknowledgment`
  → `submit(pending.requestText)`. `pendingIntent` is set **only** after the frontend answered
  a capability-shaped request (`:477-481`), never from a worker's question.
- Gates (`:368-378`): `toolShapeRoute` = `AgentDirectIntent.parse` or
  `toolShapeMatch` (verb AND noun, `AgentDirectIntent.swift:244-256`, table `:193-239`).
- Answer stream (`:444-448`): every `.answer` snapshot goes to `tracker.receive(answer)`
  immediately — no `mayBeDenial` hold (the typed path holds, `ToolLoop:427`).
- Backstop (`:484-495`): `denialCounts[key] >= 2` for an identical canonical key.
- Noise gate (`:386-414`) clarifies `"okay"`/`"ok"` once (`VoiceTurnPolicy.swift:56-59`); it
  runs **after** the pending check, so a pending action already protects "okay".

**Target behaviour:**
- "what's on my calendar", "what do I have tomorrow", "am I free at 3", "any new emails?", "did
  I get an email from Ana", "remind me to …", "what's on my to-do list", "what did we decide
  last meeting", "action items from the call" route to work **before** the frontend model runs
  — only when the manifest has a ready tool of that intent.
- The frontend's answer is held from speech while it may be a denial; a denial the manifest
  contradicts escalates to work on the **first** occurrence; an honest denial (tool needs
  setup, or "I can't tell from this transcript") is spoken whole.
- A worker result whose last sentence is a question leaves a `PendingAction`
  (`origin: .workerQuestion`); the next "yes"/"okay"/"do it" submits the original objective
  with the confirmation; "okay" is not clarified as noise while that is pending.
- Everything the gates add is a route to work; nothing is suppressed. The positive corpus of
  ordinary questions in `--selftest-voice-turn-routing` still reaches the model.

**Steps:**
1. **Question routes** (`AgentDirectIntent.swift`), additive, exact word-bounded regexes on
   the lowercased, apostrophe-normalised utterance:
   ```swift
   struct QuestionRoute: Sendable { let intent: AgentIntentClass; let patterns: [String] }
   static let questionRoutes: [QuestionRoute] = [
     .init(intent: .calendar, patterns: [
       #"\bwhat('s| is)( on)? my (calendar|agenda|schedule)\b"#,
       #"\bwhat do i have (today|tomorrow|tonight|this (morning|afternoon|evening|week)|on \w+day)\b"#,
       #"\bam i (free|busy)\b"#, #"\bany (meetings|events|calls) (today|tomorrow|this week)\b"#,
       #"\bwhen('s| is) my next (meeting|call|event)\b"#]),
     .init(intent: .mail, patterns: [
       #"\bany (new )?(e-?mails?|mail|messages)\b"#, #"\bdid i get (an? )?(e-?mail|message)\b"#,
       #"\bwhat('s| is) in my inbox\b"#, #"\b(unread|latest|last|recent) (e-?mails?|mail)\b"#]),
     .init(intent: .reminders, patterns: [
       #"\bremind me\b"#, #"\bmy (to-?do|todo)( list)?\b"#, #"\bwhat do i (need|have) to do\b"#,
       #"\bset (a|an) (reminder|alarm)\b"#]),
     .init(intent: .meetings, patterns: [
       #"\bwhat did (we|they|\w+) (decide|say|agree)\b"#, #"\b(last|previous|yesterday's) (meeting|call)\b"#,
       #"\baction items?\b"#]),
   ]
   static func questionRoute(in text: String, readyIntents: Set<AgentIntentClass>) -> AgentIntentClass?
   ```
   In the coordinator, after the tool-shape gate (`:371-378`) and before the noise gate
   (`:380`): if `questionRoute(in: text, readyIntents: manifestReadyIntents)` is non-nil →
   audit `question_route(<intent>) → newWork`, `resolveInput`, `submit(text)`,
   `finishVoiceFrontend("I'm on it.")`. `manifestReadyIntents` = intents of
   `AgentCapabilityManifest.current(reader: .voiceFrontend).allowed`.
2. **Hold speech while it may be a denial** (`:445-448`):
   ```swift
   if case .answer(let answer) = parsed, !AgentRefusalGuard.mayBeDenial(answer) {
       await tracker.receive(answer)
   }
   ```
   A held reply is spoken whole at the end by `finishVoiceFrontend(…, streamed: false)`
   (`tracker.didStreamSpeech` is false), exactly as the typed path does.
3. **Escalate on the first contradicted denial** (`:474-499`). Replace the
   `denialCounts`/`backstoppedDenials` block with:
   ```swift
   if AgentRefusalGuard.rebuttal(for: assembled, manifest: voiceManifest) != nil {
       AgentAuditLog.shared.record(kind: .reply, title: "Denial escalation",
           detail: "denial_escalation → newWork (first contradicted denial)")
       tracker.cancel(); resolveInput(epoch: inputEpoch); submit(text)
       return agent.finishVoiceFrontend("I'm on it.", turn: turn, streamed: false)
   }
   ```
   Delete `denialCounts` and `backstoppedDenials` (`:53-56`) and their resets. Replace the
   `namesCapability` pending assignment (`:477-481`) with
   `pendingAction = PendingAction.detect(reply: assembled, request: text, allowedIDs: voiceManifest.allowedIDs, origin: .frontendOffer, sessionID: AgentSession.shared.sessionID)`
   (keeps today's "a question that names a capability is pending" behaviour through `detect`'s
   capability rule).
4. **Worker question → pending action** (`submit`, `:697-704`), after storing the result:
   ```swift
   if let pending = PendingAction.detect(reply: result, request: work.original,
           allowedIDs: AgentCapabilityManifest.current(reader: .voiceFrontend).allowedIDs,
           origin: .workerQuestion, sessionID: AgentSession.shared.sessionID) {
       self.pendingAction = pending
   }
   ```
5. **Unify the pending type.** Replace `PendingIntent` (`:42-52`) and `pendingIntent` with
   `PendingAction`/`pendingAction` (fields line up: `requestText`, `capabilityID`, `at`;
   `isFresh` becomes `isFresh()`). In the pending check (`:359-367`): for
   `.workerQuestion`, `submit(pending.confirmedPrompt(acknowledgment: text))`; for
   `.frontendOffer`, `submit(pending.requestText)` as today. Clear it where `pendingIntent`
   was cleared (`:247`).
6. Leave `knownNoiseFragments` unchanged: the pending check already runs before the noise gate,
   so "okay" with a pending action never reaches it. Assert that order in the self-test.
7. **One shared acknowledgment vocabulary (H-audit 2026-09-23, H2 V22).**
   `VoiceTurnPolicy.isBareAcknowledgment` (`Activation/VoiceTurnPolicy.swift:78-87`) accepts
   only `"yes", "yeah", "yep", "sure", "ok", "okay", "aye", "do it", "use them", "use it",
   "go ahead", "sounds good", "please do"`, and only at ≤ 3 tokens with no action verb, so
   "yes please", "yeah sure", "go for it", "sure go ahead" and "yes do it" miss a pending
   offer. P3-08 already lists these in its `approveKeys` (Phase 3 file, P3-08). Define the
   shared set once, here, in `VoiceTurnPolicy`, keyed in `normalizedKey` form (lowercase,
   punctuation removed, so "that's" is "that s"):
   ```swift
   /// Exact signatures that accept a pending offer or question. Shared with P3-08, whose
   /// `approveKeys` = this set ∪ its approval-only words ("send it", "approve", …).
   static let acknowledgmentKeys: Set<String> = [
       "yes", "yeah", "yep", "sure", "ok", "okay", "aye",
       "do it", "use them", "use it", "go ahead", "sounds good", "please do",
       "yes please", "yeah sure", "go for it", "sure go ahead", "yes do it", "yes go ahead",
   ]
   static func isBareAcknowledgment(_ utterance: String) -> Bool {
       acknowledgmentKeys.contains(normalizedKey(utterance))
   }
   ```
   Exact membership replaces the token-count rule (AGENTS.md: exact signatures, never shape).
   This gate only **adds** a route (a pending action is submitted), so widening it is safe;
   with nothing pending, "okay" still reaches the noise gate as today.

**Do not:**
- Do not add a gate that suppresses or answers; every new route is `submit` (newWork). AGENTS.md:
  "On the conversational path, a deterministic gate may only add, never subtract."
- Do not use shape heuristics (length, token count) in any gate; patterns name words.
- Do not remove "okay"/"ok" from `knownNoiseFragments` (graded by `--selftest-voice-turns`).
- Do not escalate an honest denial (setup needed, "can't tell from this transcript").
- Do not clear `inputPending` for an escalation without resolving the epoch through
  `resolveInput(epoch:)` (C1; P0-07).
- Do not let a pending action outlive 180 s or the session.
- (H-audit 2026-09-23) Do not keep a second acknowledgment list anywhere (the coordinator,
  P1-02's typed `PendingAction.isConfirmation`, or P3-08): voice and approvals read
  `VoiceTurnPolicy.acknowledgmentKeys`. Do not add a phrase that contains an action verb
  other than "do"/"use"/"go" to it ("send it" belongs only to P3-08's approval set).
- (H-audit 2026-09-23) Do not start this task before P1-14 is `done`: until then the echo
  filter can erase the "yes" this task routes.

**Red-first self-test:** extend `--selftest-voice-turn-routing`
(`VoiceCapabilityConversationSelfTest.runTurnRouting`, `Agent/VoiceCapabilityConversationSelfTest.swift:695`),
using its existing `streamForTesting` frontend fake and `workerForTesting`:
1. "what's on my calendar", "any new emails?", "remind me to call mom at 5", "what did we decide
   last meeting" → each reaches `workerForTesting` and the frontend fake is **not** called.
   (Red today: the frontend fake is called.)
2. Positive corpus unchanged: "can you hear me?", "what's the capital of France", "tell me a
   joke", "how are you today" → frontend called, worker not.
3. Frontend fake streams "I can't access your calendar." for "tell me about my day" → the
   tracker never received the denial (no streamed speech), and the worker is started on the
   **first** occurrence. (Red today: speech streamed; worker only on the second identical denial.)
4. Frontend fake streams "I can't tell from this transcript." → spoken, no worker.
5. Worker fake returns "Shall I set it for 10 pm?" → then "okay" → a second worker starts with
   a prompt containing "The user answered: okay"; the garble clarifier is **not** spoken.
   (Red today: "Sorry — I didn't catch that.")
6. "okay" with nothing pending → the clarifier once (unchanged exact-noise behaviour).
7. (H-audit 2026-09-23) For each of "yes please", "yeah sure", "go for it", "sure go ahead",
   "yes do it": worker fake returns "Shall I set it for 10 pm?", then the phrase → a second
   worker starts whose prompt contains "The user answered: <phrase>". (Red today: 5/5 miss
   `isBareAcknowledgment` and go to the frontend.) In `--selftest-voice-turns`
   (`VoiceTurnPolicy.selfTestFailures`) add: every member of `acknowledgmentKeys` satisfies
   `isBareAcknowledgment`, and "yes send the email to Ana" does not.
Output lines and marker unchanged (`VOICE_TURN_ROUTING_CASE`, `VOICE_TURN_ROUTING_WRONG`,
`VOICE_TURN_ROUTING_OK`/`_FAILED`).

**Verify:**
```bash
make build
make install OPEN=0
Scripts/run-selftest.sh --selftest-voice-turn-routing
Scripts/run-selftest.sh --selftest-voice-turns
Scripts/run-selftest.sh --selftest-voice-conversation
Scripts/run-selftest.sh --selftest-concurrent-voice
Scripts/run-selftest.sh --selftest-voice-frontend
Scripts/run-selftest.sh --selftest-capability-manifest
```

**Success threshold:** `VOICE_TURN_ROUTING_OK` with the seven cases (1, 3, 5, 7 red first);
`VOICE_TURNS_OK`; the four regression flags OK.

**Risks & rollback:** Holding a partial that *starts* like a denial ("I can't wait to…")
delays speech until the answer completes; `mayBeDenial` is prefix-based, so the delay applies
only to such openings. More requests become background work (slower than an answer, but they
answer from real data). Rollback: remove the question-route call in the coordinator (one
block) and restore the backstop from git.

**Done when:**
- [ ] Seven cases green (1, 3, 5, 7 red first); regression flags OK.
- [ ] (H-audit 2026-09-23) P1-14 is `done` in `STATUS.md`; `grep -rn "\"sounds good\", \"please do\"" Sources/NextNotes` finds only `VoiceTurnPolicy.acknowledgmentKeys`.
- [ ] `grep -n "denialCounts\|PendingIntent" Sources/NextNotes/Agent/VoiceConversationCoordinator.swift` finds nothing.

---

### P1-08 — Whole-sentence shortcuts; no "agent/app" answer-only prefixes

**Finding(s):** T10 (B D9), T11 (B D10). **Effort:** 1 day. **Depends on:** P1-01; P1-03 for the read-only on-device path (`maxRisk: .read`). **Unblocks:** eval A01, A02, F03, P01.

**Why (what the user experiences today):** "open youtube and play the latest Cortech video" →
"Opened youtube.com." — the rest of the sentence is dropped. "find the pricing doc and email it
to Marcus" → "I searched Desktop, Documents and Downloads for “pricing email marcus” and found
nothing…". "Ask the agent what's on my calendar" → "I don't have that information." because
"ask the agent" selects an answer-only, tool-less route.

**Files you will change:**
- `Agent/AgentDirectIntent.swift` — `parse` (`:87-92`), `parseOpen` (`:121-135`),
  `parseLocate` (`:283-294`).
- `Agent/RealtimeAgent+ToolLoop.swift` — shortcut call (`:741-745`) uses the strict parse.
- `Agent/VoiceConversationCoordinator.swift` — `toolShapeRoute` (`:636`) and
  `namesCapability` (`:652`) use the loose parse.
- `Support/ModelRoles/ModelRoleStore.swift` — `MultiStepPlanRouting.likelyMultiStep` comment
  (`:795`).
- `Agent/AgentTurnIntent.swift` — prefix lists (`:75-83`, `:101-108`, `:114-118`), `resolve`
  (`:52-66`).
- `Agent/RealtimeAgent.swift` — `.localModel` case (`:285-332`).
- `Agent/RealtimeAgentToolLoopSelfTest.swift` — table cases.

**Read for context (do not change):** `Agent/AgentDirectIntent.swift:1-19` (why the shortcut
exists: a 44.78 s prefill for "open Chrome and go to youtube.com"), `Agent/AgentEntityResolver.swift`.

**Current behaviour:**
- `parseOpen`: `if let url = namedURL(in: text) { return .openURL(url: url, app: app) }`
  (`:123`) — no check of the rest of the sentence. The `openApp` branch does check the
  remainder (`:125-134`).
- `parseLocate` (`:283-294`): any sentence containing a file word becomes a name search.
- The shortcut runs before the planner (`ToolLoop:741-745`); `MultiStepPlanRouting` uses
  `parse == nil` as its veto (`ModelRoleStore.swift:795`).
- `AgentTurnIntent.resolve` sends "ask the agent/ask agent/ask the app/ask app/use the app
  model" to `.localModel` (`:61-65`, lists at `:75-83`, `:101-108`, `:114-118`); the
  `.localModel` route runs `answerLocally` with `localModelRules` ("Do not emit … tool calls",
  "if needed facts are absent, say so", `RealtimeAgent.swift:563-574`).

**Target behaviour:**
- The shortcut fires only when it consumes the whole sentence. "open chrome and go to
  youtube.com" still takes it (two calls, all words consumed); "open youtube and search cats",
  "open youtube and play the latest Cortech video", "find the pricing document and email it to
  Marcus" go to the planner.
- On voice, routing to work is unchanged (the loose parse still routes compound requests to
  `submit`), because a gate may only add.
- "ask the agent …", "ask the app …" run the normal tool planner on the remainder.
- Explicit on-device phrasing ("ask the local model", "ask the on-device model", "use the local
  model", "ask qwen", "ask gemma") runs the planner on the on-device provider with read tools
  only (`maxRisk: .read`).

**Steps:**
1. `static func parse(_ utterance: String, wholeSentence: Bool = true) -> AgentDirectIntent?`.
   With `wholeSentence == false`, behave exactly as today.
2. `parseOpen` (whole sentence): compute the remainder after removing the leading action verb
   phrase (`locateVerbs` and "launch", "start", "navigate to", "take me to", "go to"), the
   spoken app phrase, the URL/domain token or site word, and the words
   `structural ∪ leadingFiller ∪ ["and", "then", "in", "on", "with", "page", "website", "site", "tab", "new", "go", "to"]`.
   Return nil when the remainder is non-empty.
3. `parseLocate` (whole sentence): return nil when, after the first action verb, the sentence
   contains another verb from `actionVerbs ∪ ["email", "send", "share", "attach", "play",
   "print", "delete", "move", "copy", "rename", "upload", "summarise", "summarize"]`, or
   " and "/" then " followed by any word of that set.
4. Call sites: `ToolLoop:742` → `parse(…)` (strict, default); `Coordinator:636` and `:652` →
   `parse(text, wholeSentence: false)`; `ModelRoleStore.swift:795` keeps the strict default and
   its comment now reads "the shortcut takes only sentences it fully consumes, so a compound
   request is never vetoed".
5. `AgentTurnIntent`: remove "ask the app", "ask app", "use the app model", "use app model",
   "ask agent", "ask the agent" from all three lists. Add at the top of `resolve`, after the
   delegate check:
   ```swift
   if let rest = strippedPrefix(text, among: ["ask the agent", "ask agent", "ask the app", "ask app"]) {
       return .toolLoop(prompt: rest)   // the product *is* the agent
   }
   ```
   `strippedPrefix` is word-bounded like `localModelPrompt` (`:84-91`).
6. `.localModel(prompt)` in `RealtimeAgent.handle` (`:285-332`): replace the `answerLocally`
   task with `runPlannedTurn(prompt, speech: …, voice: source == .voice, providerOverride: on-device provider, maxRisk: .read)`.
   Add `providerOverride: (any LLMProvider)? = nil, maxRisk: AgentRisk = .send` to
   `runPlannedTurn`; the manifest is built with `maxRisk`. On-device provider =
   `await LLMProviders.resolve(preferring: .appLLM)` as `answerLocally` does today
   (`RealtimeAgent.swift:596-597`). Keep the `Limits.localModel` 90 s outer wait.
7. `grep -rn "answerLocally\|localModelRules\|localModelSystem" Sources/NextNotes`: if only
   self-tests remain, delete `answerLocally` and move the tests to the new path; if
   `PersonaSelfTest`/`PersonaCareEval` grade `localModelSystem`, keep the rules text for them
   only if a production path still uses it (AGENTS.md: tests must not grade a prompt nothing
   sends).

**Do not:**
- Do not make the coordinator's gate stricter (it may only add routes).
- Do not break "open chrome and go to youtube.com" or "open Safari" (A03) — both must still
  take the shortcut.
- Do not let the on-device path run anything above read.
- Do not match "ask apple…" as "ask app" (keep the word boundary).

**Red-first self-test:** extend `--selftest-toolloop-production` with an `AgentDirectIntent`
and `AgentTurnIntent` table (pure, no model):
| Input | `parse` (strict) | `parse(wholeSentence: false)` |
|---|---|---|
| "open youtube" | openURL youtube | same |
| "open chrome and go to youtube.com" | openURL youtube.com in Chrome | same |
| "open youtube and search cats" | nil | openURL |
| "open youtube and play the latest Cortech video" | nil | openURL |
| "find the pricing document" | locate "pricing" | same |
| "find the pricing document and email it to Marcus" | nil | locate |
| "Open Safari" | openApp Safari | same |
and `resolve("Ask the agent what's on my calendar tomorrow")` == `.toolLoop(prompt: "what's on my calendar tomorrow")`;
`resolve("ask the local model what is 2+2")` is `.localModel`; `resolve("ask apple support")`
is `.toolLoop(prompt: "ask apple support")`. Red today: rows 3, 4, 6 and the "ask the agent" row.

**Verify:**
```bash
make build
make install OPEN=0
Scripts/run-selftest.sh --selftest-toolloop-production
Scripts/run-selftest.sh --selftest-voice-turn-routing
Scripts/run-selftest.sh --selftest-realtime
Scripts/run-selftest.sh --selftest-persona
Scripts/run-selftest.sh --selftest-toolloop-live --only A01,A02,A03,F01,F03,P01
Scripts/run-selftest.sh --selftest-toolloop-live --quick \
  --report "$PWD/Tests/Reports/toolloop-live/$(date +%F)-P1-08-quick.md"
```

**Success threshold:** table green (red rows first); eval A01, A02, F03, P01 not `WRONG_TOOL`
/`REFUSAL`/`MISSED_TOOL`; A03 and F01 still PASS.

**Risks & rollback:** More sentences reach the planner (slower than the shortcut). The strict
parse only rejects sentences with leftover words, which the shortcut was dropping anyway.
Rollback: call sites back to `wholeSentence: false`.

**Done when:**
- [ ] Table green (red first); eval rows above as stated; report `…-P1-08-quick.md`.
- [ ] No production caller of an answer-only, tool-less route for "ask the agent/app".

---

### P1-09 — Gmail defaults, metadata batch, `read_email`, sender header fix

**Finding(s):** T12 (B D11). **Effort:** 1.5–2 days. **Depends on:** P1-01; P1-04 (the bad-query error is recoverable). **Unblocks:** eval M01, M03, C04.

**Why (what the user experiences today):** Every mail result reads "from unknown sender"
(09-14 audit rows, 5 of 5). "Summarize my last 10 emails" is impossible: the tool requires a
Gmail query, fetches 5 messages one by one and returns ids and subjects only. Models invent
operators (`older:1d`, `in:after 2026-09-04`) and get "No message matches …" with no hint.
There is no tool to read one message.

**Files you will change:**
- `Agent/WorkspaceTools.swift` — `search_email` definition (`:75-85`); new `read_email`.
- `Agent/WorkspaceToolRunner.swift` — `run` switch (`:36-49`), `searchEmail` (`:55-83`),
  `searchResultLimit` (`:19`), `header` (`:450-456`), new `readEmail`, `GmailQuery`,
  `MailReferenceCache`.
- `Agent/GoogleWorkspaceCLI.swift` — new protocol `WorkspaceCLIRunning` that
  `GoogleWorkspaceCLI` conforms to (`run(_:timeout:)`, `:280`).
- `Agent/AgentCapabilityManifest.swift` — `read_email` → `.mail` (and the parity pin → 64 ids).
- `Agent/AgentRefusalGuard.swift` — mail capability tool ids gain `read_email`.
- `NextNotesApp.swift` — `runWorkspaceCLISelfTest` (`:3813-3838`) gains a fixture half.

**Read for context (do not change):** `Agent/WorkspaceToolRunner.swift:1-13` (every flag was
checked against `gws --help`), `:458-464` (`gmailHeader`, already correct for
`payload.headers[]`), AGENTS.md on `gws` (stderr noise, exit codes, `--dry-run`).

**Current behaviour:**
```swift
// WorkspaceToolRunner.swift:59-82 (abridged)
let query = arguments["query"] ?? ""                        // required by the catalogue (:81)
let listing = try await cli.run(["gmail", "users", "messages", "list",
    "--params", json(["userId": "me", "q": query, "maxResults": searchResultLimit])])   // 5
for id in ids.prefix(searchResultLimit) {                   // sequential
    guard let message = try? await cli.run(["gmail", "+read", "--id", id, "--headers", "--format", "json"]) …
    let from = header(fields, "from") ?? "unknown sender"   // top-level or headers{} only
    lines.append("- id \(id) — from \(from) — \(subject)")
}
```

**Target behaviour:**
- `search_email(query?, maxResults?)`: empty query means `in:inbox`; `maxResults` default 10,
  clamped 1–25; one `messages list` + up to 5 concurrent `messages get` with
  `format=metadata` (From, Subject, Date) and the message `snippet`. Output, newest first:
  `1) Tue 23 Sep 08:12 · Marcus Lee <marcus@…> · Pricing sheet v3 — Here is the updated…`
  and a closing line "To read one in full, call read_email with its number." No Gmail ids in
  the text.
- `read_email(message)`: `message` is the number from the last search or a raw id; returns
  sender, date, subject and the body text (capped by `maxResultCharacters`, 2,000).
- Sender parses from every shape `gws` returns (top-level, `headers` object, or
  `payload.headers[]`).
- Invented operators are normalised (`older:1d` → `older_than:1d`, `newer:2d` →
  `newer_than:2d`, `in:after 2026-09-04` / `after:2026-09-04` → `after:2026/09/04`); an
  unknown operator throws `WorkspaceCLIError.invalidRequest("Gmail has no “foo:” search.
  Useful ones: from:, subject:, newer_than:2d, is:unread, after:YYYY/MM/DD.")`, which P1-04
  classifies as recoverable.

**Steps:**
1. **Verify the commands first** (read-only, AGENTS.md rule that every flag is checked against
   `--help`): `gws gmail users messages get --help` and `gws gmail +read --help`. Confirm
   `--params` accepts `{"userId":"me","id":…,"format":"metadata","metadataHeaders":["From","Subject","Date"]}`.
   If the helper spells it differently, use the helper's spelling and note it in a comment.
2. **Capture the JSON shape without keeping mail.** Run one metadata `get` and one `+read` on a
   message in your own inbox, pipe through `jq 'paths(scalars) | map(tostring) | join(".")'`
   to print key paths only, and write **synthetic** fixtures with the same structure (invented
   names, subjects, snippets) as string constants in the self-test. Never commit real mail.
3. **Seam:** in `GoogleWorkspaceCLI.swift` add
   ```swift
   protocol WorkspaceCLIRunning: Sendable {
       func run(_ arguments: [String], timeout: TimeInterval) async throws -> WorkspaceCLIOutput
   }
   extension GoogleWorkspaceCLI: WorkspaceCLIRunning {}
   ```
   and change `WorkspaceToolRunner.run(_:cli:)` and its private helpers to take
   `any WorkspaceCLIRunning` (default `GoogleWorkspaceCLI.shared`). `WorkspaceCLIOutput`'s
   memberwise init (`standardOutput`, `standardError`, `exitCode`) is enough for a fake.
4. **Catalogue** (`WorkspaceTools.swift:75-85`): `search_email` summary "Search the user's
   Gmail, newest first. Leave the query empty for the latest mail." Parameters:
   `query` (`isRequired: false`, "Gmail search, e.g. from:ana@x.com, subject:deck, newer_than:2d,
   is:unread. Empty = latest mail."), `maxResults` (`isRequired: false`, "How many, 1–25.
   Default 10."). New `read_email` (`risk: .read`, parameter `message`: "The number from the
   last search, or a message id."), title "Read email".
5. **`GmailQuery`** (in `WorkspaceToolRunner.swift`): `static func normalize(_ raw: String) throws -> String`
   with the rewrites above; known operators: `from to cc bcc subject label in is has filename
   after before older newer older_than newer_than category larger smaller list deliveredto
   rfc822msgid`. A `word:` token whose word is not known → throw `invalidRequest` as above.
6. **`searchEmail`**: `q = try GmailQuery.normalize(query.isEmpty ? "in:inbox" : query)`;
   `n = clamp(Int(maxResults) ?? 10, 1, 25)`; list; then a `TaskGroup` with at most 5
   concurrent metadata `get`s; parse `payload.headers[]` with `gmailHeader`, `snippet`
   (decode HTML entities, cap 140 characters), `internalDate` (milliseconds) formatted in the
   user's locale; sort by date descending; store ids in `MailReferenceCache` and print numbers.
   Empty result → "No message matches \(q)." (success; the model sees the normalised query).
7. **`MailReferenceCache`**: `@MainActor final class` with `static let shared`,
   `func store(_ ids: [String]) -> [String]` (returns "1"…"n", replacing the previous search),
   `func resolve(_ reference: String) -> String?` (a number from the last search, or a raw id
   of ≥ 12 hex characters). In memory only; nothing is written to disk.
8. **`readEmail`**: resolve the reference (unknown → `AgentError.notFound("There is no message
   \(ref) in the last search.")`); `gws gmail +read --id <id> --headers --format json`; sender
   via `header()` fixed as below; body = the helper's text field; `truncated` as today.
9. **Header fix** (`:450-456`): `header()` checks top-level, the `headers` object, then
   `gmailHeader(fields, name)` (`payload.headers[]`), then `fields["message"]` as a nested
   message dictionary.
10. **Registry and roster:** `read_email` is a Workspace tool, so `registerNativeCatalogue`
    picks it up (`AgentToolRegistry.swift:64-66`); P1-03's parity pin gains it (64 ids);
    `AgentRefusalGuard` mail capability `toolIDs` gains it; `VoiceCapabilitySnapshot` says
    "search and read your email"; `AgentDirectIntent.capabilityVerbs` `search_email` row is
    unchanged (the planner picks `read_email` itself).

**Do not:**
- Do not read message bodies in `search_email` (metadata only: faster and smaller).
- Do not put Gmail ids in any text the user can see; the number→id map stays in memory.
- Do not commit real email content, even in a fixture.
- Do not treat stderr output as failure (`gws` prints "Using keyring backend: keyring" on
  success); judge by exit code (already done in `GoogleWorkspaceCLI.run`).
- Do not raise the concurrency above 5 (`gws` spawns a process per call).

**Red-first self-test:** `--selftest-gws` gains a **fixture half that runs first and needs no
binary** (`runWorkspaceCLISelfTest`, `NextNotesApp.swift:3813`; put the checks in
`WorkspaceToolRunner.selfTestFailures() async -> [String]` with a `FakeWorkspaceCLI` returning
canned JSON keyed by the argument list):
1. `search_email` with no query → the fake saw `q = in:inbox` and `maxResults = 10`.
2. Three metadata fixtures (payload.headers[] shape) → three lines with sender names, dates and
   snippets; no Gmail id in the text. (Red today: "unknown sender", ids in the text, and a
   missing-argument error for the empty query.)
3. A `+read` fixture in the `payload.headers[]` shape → `read_email("2")` returns the right
   sender.
4. `GmailQuery.normalize("older:1d")` == `"older_than:1d"`; `"in:after 2026-09-04"` →
   `"after:2026/09/04"`; `"foo:bar"` throws `invalidRequest`.
5. `maxResults: "40"` is clamped to 25.
Print `GWS_FIXTURES_OK` or `GWS_FIXTURES_FAILED: <reason>` before the existing binary/auth
lines; the final `GWS_OK` is printed only when the fixture half passed **and** the binary/auth
half passed. (Today a missing binary prints `GWS_FAILED`; keep that behaviour.)

**Verify:**
```bash
make build
make install OPEN=0
gws gmail users messages get --help | head -40
Scripts/run-selftest.sh --selftest-gws
Scripts/run-selftest.sh --selftest-capability-manifest
Scripts/run-selftest.sh --selftest-toolloop-live --only M01,M02,M03,M05,C04
Scripts/run-selftest.sh --selftest-toolloop-live --quick \
  --report "$PWD/Tests/Reports/toolloop-live/$(date +%F)-P1-09-quick.md"
```
Optional live check against the real account (reads only; prints counts, never content): a
`--selftest-gws --live-mail` switch that runs `search_email` with `maxResults: 3` and prints
`GWS_LIVE_MAIL: 3 messages, 3 senders parsed, <seconds>s`. Add it only if it prints no subject,
sender or snippet.

**Success threshold:** `GWS_FIXTURES_OK` then `GWS_OK`; eval M01, M03 PASS; M02 not
`WRONG_TOOL`; a live `search_email` of 10 messages completes in ≤ 5 s (estimate; measure and
record).

**Risks & rollback:** `metadataHeaders` spelling may differ in `gws`; step 1 catches it.
Rollback: the old `searchEmail` body is replaceable in one function; `read_email` can be
unregistered by removing it from `WorkspaceTools.all`.

**Done when:**
- [ ] Fixture half green (red first), `GWS_OK` on this Mac.
- [ ] `read_email` registered, in the manifest parity pin, and in the refusal guard.
- [ ] Eval report `…-P1-09-quick.md`; M01/M03 PASS.

---

### P1-10 — Capped tool results; one renderer; no internal ids to users

**Finding(s):** T13 (B D12), T14 (B D13); H1 #10, H2 V5, V18 (H-audit 2026-09-23). **Effort:** 2 days, split: **P1-10a** result cap and
context budget (0.75 day, can land early); **P1-10b** renderer and id scrub (1.25 days).
**Depends on:** P1-10a: P1-01. P1-10b: P1-04 (outcome split) and P1-02 (it removes first-pass
returns this task would otherwise render). **Unblocks:** Phase 1 exit (0 `LEAK`), P3-04, P1-18
(P1-10a's runtime Apple FM window; H-audit 2026-09-23).

**Why (what the user experiences today):** "No message matches older:1d. I stopped the tool
plan because it took too long. Remaining steps are unfinished." and "Did search_email (step
1/8). Timed out on get_agenda." print tool ids and step counts; the self-test *requires* it
(`RealtimeAgentToolLoopSelfTest.swift:549-553`). "Codex stopped: ERROR: You've hit your usage
limit. Visit https://chatgpt.com/…" reached a typed user (09-22 00:57Z) because
`voiceSafeReply` applies only to voice. One large tool result (a tree, a recall, a mail body)
overflows the Apple FM window the app assumes (a hard-coded 4,096 tokens,
`FoundationModelLLMProvider.swift:13`; 8,192 measured on the dev Mac, G §2.2) and ends as "The tool
planner failed: …".

**Files you will change:**
- New `Agent/AgentReplyRenderer.swift` — `AgentTurnOutcome`, `AgentReplyRenderer`,
  `ToolResultBudget`.
- `Agent/AgentToolLoop.swift` — `userMessage(original:results:)` (`:35-45`).
- `Agent/RealtimeAgent+ToolLoop.swift` — `incomplete` (`:849-862`), every user-facing return
  in `runModelTurn`/`runPlannedToolLoop` (`:357`, `:404`, `:446`, `:451`, `:464`, `:484`,
  `:748`, `:777`, `:873-876`, `:916`, `:921-922`, `:929`, `:935`, `:950`, `:958`, `:966`,
  `:974-979`, `:1043-1044`, `:1081`, `:1085`), the Codex note (`:364-369`), `runTool`
  (`:313-315`).
- `Agent/RealtimeAgent.swift` — `voiceSafeReply` (`:196-215`, re-verified 2026-09-24) delegates to the renderer;
  `conclude(…)` applies `AgentReplyRenderer.scrub` to every reply.
- `Agent/RealtimeAgentToolLoopSelfTest.swift` — invert `:549-553`; new cases.
- (H-audit 2026-09-23) `Agent/WorkspaceToolRunner.swift` — `maxResultCharacters` (`:17`) and
  `truncated(_:)` (`:496-499`) read `ToolResultBudget`; `ToolLoop` `spokenFallback` (`:159-169`);
  `Agent/VoiceCapabilityConversationSelfTest.swift:1016` fixture.

**Read for context (do not change):** `Agent/MeetingAgent.swift:252,282-285`
(`maxLookupCharacters = 1_200`, the meeting side's cap), `Agent/Speech/AgentSpeechPolicy.swift`
(`toolResultSummary`, `spokenForm`), `Formatting/LLM/NotesModelRuntime.swift:586-588`
(`inputTooLong`), `Agent/Backend/CodexComputerUse.swift:184-202`.

**Current behaviour:**
- `AgentToolLoop.userMessage` (`AgentToolLoop.swift:35-45`) appends every result verbatim.
- `incomplete` (`ToolLoop:849-862`) prints "Did <ids> (step n/max). Timed out on <id>." by
  design (comment at `:844-848`).
- Other raw strings: "The model could not answer: " + reason (`:451`), "The tool planner
  failed: " + message (`:929`), "The tool " + id + " did not run: " + message (`:1081`), the
  Codex note prepended verbatim (`:364-369`).
- `voiceSafeReply` (`RealtimeAgent.swift:178-199`) scrubs usage-limit errors, `ERROR:` and URLs
  — voice only.

**Target behaviour:**
- Each tool result fed back to the model is capped by the reader's window (H-audit 2026-09-23:
  700 characters at ≤ 4,096 tokens, 1,200 at ≤ 8,192, 4,000 at ≤ 32K, 12,000 above; document
  reads get twice that); results older than the last two are reduced to their first line;
  before each round the prompt is measured with `provider.countTokens` and trimmed (history
  first, then older results, then per-result caps) to fit `contextTokens − maxTokens − 256`.
- Every tool-loop reply, typed and voice, goes through one renderer; no reply contains a
  registry id or alias, "step n/m", "ERROR:", raw tool markup, or a URL taken from an error.
- Context overflow is a plain sentence, never "The tool planner failed: …".

**Steps:**

*P1-10a — result cap and context budget*
0. **Read Apple FM's window at runtime.** `FoundationModelLLMProvider.contextTokens` becomes
   `SystemLanguageModel.default.contextSize` (declared in the macOS SDK's
   `FoundationModels.swiftinterface` and back-deployed to macOS 26.0; 8,192 on the dev Mac per G),
   falling back to 4,096 when it reports ≤ 0. Also fix the type's doc comment (`:4-12`, "4096 tokens
   covers roughly fifteen minutes…"). Add a case to `--selftest-toolloop-production`:
   `FoundationModelLLMProvider().contextTokens == SystemLanguageModel.default.contextSize` when Apple
   FM is available, and print `APPLE_FM_CONTEXT=<n>` as a diagnostic. It is red today (4,096 ≠ 8,192
   on this Mac). Do not change how notes map-reduce uses it beyond reading the larger number; watch
   `--selftest-notes` if it is in the baseline.
1. `ToolResultBudget` (cap rewritten, H-audit 2026-09-23, H1 #10: a flat 1,200 would be a
   new cap that hurts a 262,144-token OpenRouter reader: a 10-page `read_doc` becomes
   1,200 characters and `skills.read`, today `SkillTools.readLimit = 6_000`
   (`Agent/Skills/SkillTools.swift:85`), would lose four-fifths of a skill):
   ```swift
   enum ToolResultBudget {
       /// Scales with the reader. ≤ 4,096 → 700; ≤ 8,192 → 1,200; ≤ 32,768 → 4,000; else 12,000.
       static func characterCap(readerContextTokens: Int) -> Int {
           switch readerContextTokens {
           case ...4_096: 700
           case ...8_192: 1_200
           case ...32_768: 4_000
           default: 12_000
           }
       }
       /// Tools whose whole job is to read a document get twice the cap.
       static let documentReadingToolIDs: Set<String> =
           ["read_doc", "filesystem.read", "skills.read", "meeting.transcript"]
       static func characterCap(readerContextTokens: Int, toolID: String) -> Int {
           characterCap(readerContextTokens: readerContextTokens)
               * (documentReadingToolIDs.contains(toolID) ? 2 : 1)
       }
       /// The reader of the plan in flight, bound by the planner around execution.
       @TaskLocal static var readerContextTokens: Int?
       /// Cuts at a line boundary; appends "…(N more characters not shown)".
       static func cap(_ output: String, readerContextTokens: Int) -> String
       /// Results older than the last `keepFull` reduced to their first line (≤ 160 characters).
       static func fold(_ results: [String], keepFull: Int = 2) -> [String]
   }
   ```
   Apply `cap` where the loop appends a result (`ToolLoop:1073`, re-verified 2026-09-24:
   `results.append(AgentPrompts.toolResult(name: call.name, output: output))`, and the
   repair/recoverable appends from P1-04), and `fold` in `AgentToolLoop.userMessage` (add a
   `readerContextTokens` parameter with default 8,192 so `ScheduledRunner`'s caller keeps
   compiling and benefits). `cap` takes the tool id and uses
   `characterCap(readerContextTokens:toolID:)`; the reader is
   `AgentAnswerBudget.readerContextTokens(for: provider)` (the `window` P1-02 step 6 reads).
   (H-audit 2026-09-23) **Workspace reads the same function.** `WorkspaceToolRunner.maxResultCharacters = 2_000`
   (`Agent/WorkspaceToolRunner.swift:17`, used by `truncated(_:)` at `:496-499`) becomes
   `static func maxResultCharacters(toolID: String) -> Int { ToolResultBudget.readerContextTokens.map { ToolResultBudget.characterCap(readerContextTokens: $0, toolID: toolID) } ?? 2_000 }`,
   and the planner binds `ToolResultBudget.$readerContextTokens.withValue(window)` around
   each `AgentToolExecutor.run` (beside the existing `KnowledgeGraphScope.$reader.withValue`,
   `ToolLoop:801`). Callers with no bound reader (`MeetingAgent`, routines) keep today's
   2,000; the existing context-budget fitter (step 2) still shrinks results when a prompt
   is over.
2. Before each round in the private `runPlannedToolLoop`: estimate
   `try await provider.countTokens(system + user)`; while `estimate + roundTokens + 256 > provider.contextTokens`,
   apply in order: drop the "Earlier Agent conversation" section; `fold(keepFull: 1)`; cap every
   result to 400 characters; if still over, end with `.contextOverflow(lastVerified:)`.
3. Catch `LlamaError.inputTooLong` and FoundationModels' context-window error
   (`LanguageModelSession.GenerationError.exceededContextWindowSize`) in the round and map them
   to `.contextOverflow` (instead of `"The tool planner failed: "`, `:927-929`).

*P1-10b — one renderer, no ids*
4. `AgentReplyRenderer`:
   ```swift
   enum AgentTurnOutcome: Sendable {
       case answer(String)
       case timedOut(lastVerified: String?)
       case stopped
       case denied(String)
       case infrastructure(String)
       case repairLimit(lastVerified: String?)
       case contextOverflow(lastVerified: String?)
       case modelUnavailable(String)
       case modelFailed(String)
       indirect case handedOffFellBack(note: String, then: AgentTurnOutcome)
   }
   enum AgentReplyRenderer {
       static func render(_ outcome: AgentTurnOutcome, voice: Bool) -> String
       /// Last pass on every reply: removes registry ids/aliases (word-bounded), "step n/m",
       /// a leading "ERROR:", tool markup; in non-answer outcomes also URLs. Never touches the
       /// words of a normal answer beyond ids and markup.
       static func scrub(_ text: String, outcome: AgentTurnOutcome?) -> String
   }
   ```
   Sentences (typed; voice uses the same meaning, shorter, and `AgentSpeechPolicy.toolResultSummary`
   for `lastVerified`):

   | Outcome | Rendered |
   |---|---|
   | `.timedOut(r)` | r != nil: "<r>\n\nI ran out of time before finishing the rest." · nil: "That took longer than I allow, so I stopped. Try asking for one thing at a time." |
   | `.stopped` | "Stopped." |
   | `.denied(s)` | `s` (already plain) |
   | `.infrastructure(s)` | known causes mapped: not signed in → "Google isn't connected. Connect it in Settings ▸ Workspace."; not installed → "The Google Workspace helper isn't installed. Settings ▸ Workspace can install it."; timed out → "Google didn't answer in time. Try again in a moment."; usage/quota/429 (today's `voiceSafeReply` rule) → "You've hit the usage limit, so I stopped there. Check your plan or try again later."; otherwise "I couldn't do that: <scrubbed s>" |
   | `.repairLimit(r)` | "<r if any>\n\nI couldn't finish that one — try saying it another way." |
   | `.contextOverflow(r)` | "<r if any>\n\nThat was too much to read at once. Ask for something narrower." |
   | `.modelUnavailable(s)` | "I can't answer right now: <s>" (s from the provider, e.g. "…isn't downloaded") |
   | `.modelFailed(s)` | "The model didn't finish that answer. Try again." (raw `s` to the audit log only) |
   | `.handedOffFellBack(note, then)` | "Codex couldn't do that, so I did it here.\n\n" + render(then) — the raw Codex error and URL go to the audit log only |
   | `.cutShort(partial)` (J L8, 2026-09-27) | "<partial>\n\nI was cut off there — ask me to go on." Produced when the provider's `LLMCompletion.finishedByLimit` is true on the final answer; a reply is never shown ending mid-sentence as if complete |
5. Replace every raw return listed under *Files* with `AgentReplyRenderer.render(…)`; replace
   `incomplete(…)` with `.timedOut(lastVerified:)` (memory confirmations still lead, via
   `confirmed`). Move today's `voiceSafeReply` rules into `render`/`scrub` and make
   `voiceSafeReply` call `scrub(text, outcome: nil)`.

   **Key the error sentences on the outcome, never on answer text (H-audit 2026-09-23, H2 V5).**
   Today `RealtimeAgent.voiceSafeReply` (`Agent/RealtimeAgent.swift:196-215`, re-verified
   2026-09-24; it runs on every `finishVoiceFrontend` reply, `:190`) replaces the **whole**
   reply with "You've hit the usage limit, so I stopped there…" when the text contains
   "quota", "rate limit", "you've hit your", "usage limit" or `\b429\b`, and with "The voice
   model isn't ready yet…" when it contains "not downloaded". So "What's a sales quota?"
   and "the file is not downloaded yet" produce a false error, and on the streamed path the
   rewritten sentence is what `conclude` records, which teaches the next turn that a limit
   was hit. Moved as-is into `scrub`, the bug would spread to typed turns. Therefore:
   - The usage-limit and not-downloaded sentences exist **only** in `render` for
     `.infrastructure(s)`, `.modelUnavailable(s)` and `.handedOffFellBack(…)`, i.e. when a
     provider or hand-off **error** carries that text. Match on `s` there, never on an answer.
   - `scrub(text, outcome: nil)` and `scrub(text, outcome: .answer)` never replace a
     sentence: they remove ids, "step n/m", a leading "ERROR:" and tool markup, nothing else.
     Delete both substring rules from `voiceSafeReply` (it becomes `scrub(text, outcome: nil)`
     plus today's URL rule **only** for non-answer outcomes).

   **A speakable answer is spoken (H-audit 2026-09-23, H2 V18).** `AgentToolSpeechTracker.spokenFallback(for:)`
   (`ToolLoop:159-169`, called from `RealtimeAgent.swift:375`) prefers
   `AgentSpeechPolicy.toolResultSummary` (agenda: 3 events; email: count plus latest sender;
   files: count) and otherwise says "I have the result, but its details are easier to read
   in the conversation." whenever `spokenForm(reply)` is empty. Reorder it: when
   `AgentSpeechPolicy.spokenClauses(reply)` (`Agent/Speech/AgentSpeechPolicy.swift:42`,
   per clause, after P0-09) is non-empty, speak those clauses; else the
   `toolResultSummary`; else the fixed line. Keep the "never read ids, paths or URLs" rule:
   `spokenClauses` already drops unspeakable clauses.
6. In `RealtimeAgent.conclude(…)` (private, `RealtimeAgent.swift:527`) apply `AgentReplyRenderer.scrub(reply, outcome: nil)` to the
   displayed and spoken reply, so every path (typed, voice frontend, voice worker announcement,
   run-locally-once) passes one gate. Keep the unscrubbed text in the audit log.
7. `runTool` (`ToolLoop:299-316`): catch → `render(ToolErrorClassifier.classify(error, tool:)…)`.
8. (J audit 2026-09-27, L9) **The same scrub covers the other places model text reaches a person:**
   the Portrait insight drafts (the 27 Sep draft was a raw `<tool_call>` block), memory-review
   notices, and routine outputs. Find each place with
   `grep -rn "\.text\b\|completion.text" Sources/NextNotes/Knowledge Sources/NextNotes/Memory Sources/NextNotes/Agent/Schedules`,
   and route it through `AgentReplyRenderer.scrub(_:outcome: nil)`. Also add the log's phrasings
   to the renderer's table: "0 results from memory" → nothing (an empty memory read is not news),
   and a Gmail message id is never spoken.

**Do not:**
- Do not cap a result before `VisionHandoff` reads a screenshot park summary (cap its
  description, not the park line).
- Do not scrub the words of a normal answer beyond ids and markup (a model quoting a file name
  the user asked for is fine).
- Do not remove ids from the audit log (it is where they belong).
- Do not put technical words in rendered sentences that `--selftest-ui-strings` bans
  (`cron`, `artifact`, raw tool ids, schema keys).
- Do not name the Agent in a rendered sentence.
- (H-audit 2026-09-23) Do not map an answer's words to an error sentence ("quota",
  "rate limit", "not downloaded" in an answer are the user's topic, not a failure); only a
  provider or hand-off outcome may produce those sentences.
- (H-audit 2026-09-23) Do not give a document-reading tool an uncapped result: 2× the
  reader's cap is still a cap, and step 2's fitter still runs.

**Red-first self-test:** extend `--selftest-toolloop-production`:
1. **Invert** `:549-553`: the timeout fixture's reply must **not** contain `computer.active_app`
   and must not match `\bstep \d+/\d+\b`; it must start with the fixture's read result and
   contain "ran out of time". (Red today by construction.)
2. Renderer table: every `AgentTurnOutcome` case → no registry id, no "ERROR:", no "step",
   and for non-answers no URL; the 09-22 Codex string "Codex stopped: ERROR: You've hit your
   usage limit. Visit https://chatgpt.com/codex/settings/usage" → the usage-limit sentence
   with no URL.
3. A fake tool returns 30,000 characters → the next round's user message (captured by the
   scripted provider) contains ≤ 700 characters of it with `contextTokens` 4,096, ≤ 1,200 with
   8,192, ≤ 4,000 with 32,768 and ≤ 12,000 with 262,144 (H-audit 2026-09-23); the same fake
   answering as `read_doc` at 262,144 → ≤ 24,000 and > 12,000. Pure table check:
   `characterCap(readerContextTokens:)` for 4,096 / 8,192 / 32,768 / 262,144 = 700 / 1,200 /
   4,000 / 12,000; `WorkspaceToolRunner.maxResultCharacters(toolID: "search_email")` is 2,000
   with no bound reader and 12,000 inside `ToolResultBudget.$readerContextTokens.withValue(262_144)`.
4. A scripted provider with `contextTokens` 4,096 and `countTokens = characters / 4`: after four
   large results, every captured `system + user` estimate + `maxTokens` + 256 ≤ 4,096.
5. A scripted provider that throws `LlamaError.inputTooLong` → reply is the context-overflow
   sentence, not "The tool planner failed".
6. A typed reply containing "Use filesystem.find to search" (the 09-22 03:00Z leak) comes out of
   `conclude` without `filesystem.find`.
7. (H-audit 2026-09-23) Answers survive scrub: `scrub("A sales quota is the target a rep must
   hit in a period.", outcome: nil)`, `scrub("The file is not downloaded yet, so open it from
   Drive first.", outcome: nil)`, `scrub("I hit a rate limit on the stairs.", outcome: nil)` and
   `RealtimeAgent.voiceSafeReply("What's a sales quota? It's a sales target.")` each return the
   input unchanged (modulo whitespace). `render(.infrastructure("429 Too Many Requests: you've
   hit your quota"), voice: true)` is the usage-limit sentence;
   `render(.modelUnavailable("Gemma is not downloaded"), voice: true)` names that the model
   isn't ready. (Red today: `voiceSafeReply` rewrites the first and second answers.) Also
   update `VoiceCapabilityConversationSelfTest.swift:1016`, which calls `voiceSafeReply(raw)`
   on fixtures: any fixture there that expects a rewrite of an **answer** is wrong by this
   rule; change it to feed the error through `render` instead, never weaken the check.
8. (H-audit 2026-09-23) `spokenFallback(for: "You have two events: standup at 9 and review at 3.")`
   with a verified `get_agenda` result returns the reply (its clauses), not the agenda
   summary; `spokenFallback(for: "See /Users/x/a.txt")` with no verified result returns the
   fixed line.

**Verify:**
```bash
make build
make install OPEN=0
Scripts/run-selftest.sh --selftest-toolloop-production
Scripts/run-selftest.sh --selftest-toolloop
Scripts/run-selftest.sh --selftest-voice-delivery
Scripts/run-selftest.sh --selftest-ui-strings
Scripts/run-selftest.sh --selftest-persona
Scripts/run-selftest.sh --selftest-toolloop-live --quick \
  --report "$PWD/Tests/Reports/toolloop-live/$(date +%F)-P1-10-quick.md"
Scripts/run-selftest.sh --selftest-toolloop-live --quick --model apple \
  --report "$PWD/Tests/Reports/toolloop-live/$(date +%F)-P1-10-apple-fm-quick.md"
```

**Success threshold:** the eight cases green (1 and 7 red first; case 3's table extended);
eval: **0 `LEAK`** on both models; Apple FM run has no case ending in a context error.

**Risks & rollback:** Over-eager scrubbing could remove a word that happens to equal a tool
name part (e.g. "search"); scrub only full ids containing `.` or `_` and aliases, word-bounded.
Rollback: `conclude` without `scrub` restores today's text; the renderer is additive.

**Done when:**
- [ ] P1-10a and P1-10b ticked separately; eight cases green; assertion at `:549-553` inverted.
- [ ] (H-audit 2026-09-23) `grep -n '"quota"\|not downloaded' Sources/NextNotes/Agent/RealtimeAgent.swift` finds no text rule inside `voiceSafeReply`; `grep -n "2_000" Sources/NextNotes/Agent/WorkspaceToolRunner.swift` shows it only as the unbound-reader fallback.
- [ ] `grep -rn "did not run: " Sources/NextNotes/Agent` and `grep -rn "The tool planner failed" Sources/NextNotes/Agent` find no user-facing string, and `grep -rn '(step \\(' Sources/NextNotes/Agent` (the old `incomplete` format string) finds nothing.
- [ ] Eval reports with 0 `LEAK` on both models.

---

### P1-11 — A reply may not claim a tool ran when none did; the history given to the planner carries no stale tool claims

**Finding(s):** G N5 (turns A1, A2, A6, A7), related to D14 (history echo). **Effort:** 1 day. **Depends on:** P1-01 (the grader's `FABRICATED` verdict measures this), P1-04 (the guard reads `ToolCallParse.prose`, text outside any call). Soft: P1-10b (the honest sentence goes through `AgentReplyRenderer` when it exists). **Unblocks:** Phase 1 exit. **Cross-links:** P4-02 and P4-03 rewrite the router history and the prompts. They must keep this guard, which is the backstop; the prompt is the first line of defence, and the guard catches what the prompt misses.

**Why (what the user experiences today):**
- On Apple FM, typed, 22:04–22:07 local on 2026-09-23, **4 of 9 turns claimed tools that did not run
  in that turn** (G §2.2). There was one planner pass and no tool round, according to the Foundation
  Models request log.
- Examples:
  - "Hi" → "I've searched Desktop, Documents, and Downloads — 7,831 files — using filesystem.find.
    No exact match for "Indian direct"…" (A1);
  - "list them" → "I ran the get_agenda tool. Your main calendar for today shows no booked events."
    (A7). That calendar answer was invented.
- The claims were copied from the 21:56 voice worker's text, which is handed to the planner as
  "Earlier Agent conversation".

**Files you will change:**
- new `Agent/ToolClaimGuard.swift`;
- `Agent/RealtimeAgent+ToolLoop.swift`:
  - planner text-only path (`:931-955`), which returns at `:952`;
  - planner speech gate (`:896-907`, `AgentRefusalGuard.mayBeDenial` at `:904`);
  - first-pass `.answer` branch (`:461-485`) and its speech gate (`:424-429`);
  - history for the first pass (`:382`) and the planner (`:814-819`);
- `Agent/RealtimeAgent.swift`: `AgentSession.contextForCurrentTurn(maxCharacters:)` (`:1023-1050`) and
  `chatHistoryForCurrentTurn(maxCharacters:excludingLastUser:includeDeliveryNotes:)` (`:1055-1075`)
  gain a `scrubToolClaims: Bool = false` parameter;
- `Agent/LiveEval/ToolLoopLiveEvalGrader.swift` (P1-01): implement `FABRICATED` if P1-01 has not;
- `Agent/RealtimeAgentToolLoopSelfTest.swift`: new cases.

**Read for context (do not change):** `Agent/AgentRefusalGuard.swift` (`rebuttal(for:toolIDs:)`
`:72`, `mayBeDenial` `:117-121`; this task follows the same "checked after the fact against the
registry" pattern); `Agent/Tools/AgentToolRegistry.swift` (ids and aliases).

**Current behaviour** (verified 2026-09-23):
- `runPlannedToolLoop` (private, `ToolLoop:789`) keeps `completedToolIDs: [String]` (`:807`). When
  `parsedCalls.isEmpty`, it checks for a literal `<tool_call>` (`:934`), then a refusal
  (`:942-949`), and then returns `reply.isEmpty ? … : confirmed(reply)` (`:952`).
  `completedToolIDs` is never consulted there.
- The planner is given `"Earlier Agent conversation:\n\(conversation)"` (`:819`), built from
  `AgentSession.shared.contextForCurrentTurn(maxCharacters: provider.contextTokens < 8_000 ? 2_500 : 6_000)`
  (`:814-816`). That is every earlier assistant text, verbatim.
- The first pass's `.answer` is returned as is unless it is a refusal (`:461-485`).

**Target behaviour:**
1. `ToolClaimGuard.claims(in:toolIDs:aliases:)` finds:
   - any registry id or alias containing `.` or `_`, word-bounded;
   - first-person completed-action claims: "I ran", "I've run", "I have run", "I searched",
     "I've searched", "I checked", "I've checked", "I looked (at|through|in) your", "I listed",
     "I opened", "I read your", "I found … in your", "using <id>";
   - passive count claims: `\b\d[\d,]* (files|emails|messages|events|results) (searched|checked|found|listed)\b`.
   Offers ("I can check", "Want me to look?") are not claims.
2. A claim is **unsupported** when `completedToolIDs` is empty, or when it names an id that is not in
   `completedToolIDs`. An unsupported claim triggers **one** re-plan with
   `ToolClaimGuard.replanNote` appended to the results. A second unsupported claim in the same turn
   is replaced by the honest sentence "I haven't checked that yet." The fabricated text is never
   delivered, typed or spoken.
3. A claim that matches a call that did run passes unchanged (for example "I checked your
   calendar…" after `get_agenda` ran).
4. The first pass applies the same check with `completed = []`. A hit escalates to
   `runPlannedToolLoop` (trace note `claim-escalation`), the same way the refusal branch does.
5. Speech is held while `ToolClaimGuard.mayBeClaim(partial)` is true, exactly like `mayBeDenial`, so
   "I ran —" is never heard.
6. **History hygiene.** The history view handed to the first pass and to the planner drops, from
   **assistant** messages only, every sentence that contains a claim. The stored conversation and
   what the person sees are unchanged. The section header becomes "Earlier Agent conversation
   (earlier turns; nothing in it ran in this turn):".
7. This is a post-generation check that adds a planning round. It never suppresses a voice turn, so
   AGENTS.md's rule that "a deterministic gate may only add" holds.

**Steps:**
1. `Agent/ToolClaimGuard.swift`:
   ```swift
   enum ToolClaimGuard {
       struct Claim: Sendable, Equatable { let text: String; let toolID: String? }
       static func claims(in reply: String, toolIDs: Set<String>, aliases: Set<String>) -> [Claim]
       static func unsupported(_ claims: [Claim], completed: [String]) -> [Claim]
       static func mayBeClaim(_ partial: String) -> Bool
       static func scrubHistory(_ assistantText: String, toolIDs: Set<String>, aliases: Set<String>) -> String
       static let replanNote = "No tool has run in this turn. Do not say you ran, searched, checked, listed or opened anything. Call a tool now, or answer only from what is written above."
       static let honestReply = "I haven't checked that yet."
       /// Registered aliases (`files.*`, `workspace.*` …), from `AgentToolRegistry`; one list shared with P1-01's `LeakPatterns`.
       @MainActor static var registryAliases: Set<String> { get }
   }
   ```
   Build the alias set in one place and share it with P1-01's `LeakPatterns`, which already lists
   the `files.*` and `workspace.*` aliases.
2. Planner (`ToolLoop:931-955`). Add `var claimCorrected = false` next to `rebutted`. After the
   refusal block and before the final `return`:
   ```swift
   let unsupported = ToolClaimGuard.unsupported(
       ToolClaimGuard.claims(in: reply, toolIDs: rosterIDs, aliases: ToolClaimGuard.registryAliases),
       completed: completedToolIDs)
   if !unsupported.isEmpty {
       AgentAuditLog.shared.record(kind: .reply, title: "Re-planned after an unsupported tool claim",
                                   detail: String(reply.prefix(120)))
       if !claimCorrected { claimCorrected = true; speech?.cancel(); results.append(ToolClaimGuard.replanNote); continue }
       speech?.cancel()
       return confirmed(ToolClaimGuard.honestReply)       // P1-10b: render(.answer(honestReply))
   }
   ```
   The re-plan uses one of `maxRounds`, as the refusal re-plan does.
3. First pass (`:461-485`). After the refusal check:
   `if !ToolClaimGuard.unsupported(ToolClaimGuard.claims(in: text, …), completed: []).isEmpty`,
   escalate like the refusal branch, with trace note `"claim-escalation"`. If P1-02 has already
   removed the typed first pass, apply this only to the voice path that remains.
4. Speech gates. `!AgentRefusalGuard.mayBeDenial(x)` becomes
   `!AgentRefusalGuard.mayBeDenial(x) && !ToolClaimGuard.mayBeClaim(x)` at both sites.
5. History. Add `scrubToolClaims` to the two `AgentSession` functions. When it is true, pass the
   assistant `modelContextText` through `ToolClaimGuard.scrubHistory`. Pass `true` at `ToolLoop:382`
   and `:814`, and change the header string at `:819`. Other callers keep `false`.
6. P1-01's `FABRICATED` verdict (P1-01 step 10) is the live measure. If P1-01 shipped without it,
   add it now, with its grader self-test case.

**Do not:**
- edit the stored conversation, or scrub user messages;
- treat an offer as a claim (the grader's `OfferPatterns` are separate);
- re-plan more than once per turn for a claim;
- block or drop a voice turn;
- write the Agent's name into the re-plan note;
- scrub the audit log (the raw reply stays there).

**Red-first self-test:** extend `--selftest-toolloop-production` (`TOOLLOOP_PRODUCTION_OK` /
`…_FAILED`):
- **a.** The scripted planner answers round 1 with "I ran the get_agenda tool. Your main calendar
  for today shows no booked events." and round 2 with
  `<tool_call>{"name":"get_agenda","arguments":{}}</tool_call>`, then a final answer from the fixture.
  Assert:
  - round 2 happened;
  - its captured user message contains `replanNote`;
  - the `get_agenda` fake ran;
  - the reply comes from the fixture.
- **b.** The planner claims twice. The final reply is `honestReply`, and it contains neither
  `get_agenda` nor "no booked events".
- **c.** Round 1 calls `get_agenda`, and round 2 says "I checked your calendar: Standup at 9:30." The
  reply passes unchanged.
- **d.** Seed the session with the assistant text "I've searched Desktop, Documents, and Downloads —
  7,831 files — using filesystem.find. No exact match.", then send a typed "What was my last
  request?". The captured first-pass messages and planner user message contain neither
  "filesystem.find" nor "7,831 files". The session still stores the original text.
- **e.** Pure `claims(in:)` table:
  - "I can check your calendar" → none;
  - "Ran into traffic?" → none;
  - "I checked your inbox" → one claim;
  - "Earlier I opened Safari" with `completed = ["computer.open_app"]` → no unsupported claims.

Also extend `--selftest-toolloop-live-grader` with the `FABRICATED` canned case from P1-01 step 14.

**Confirm RED:** add `ToolClaimGuard` with `claims` returning `[]` and `scrubHistory` returning its
input. Cases a, b, d and the positive rows of e must fail.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-toolloop-production
Scripts/run-selftest.sh --selftest-toolloop-live-grader
Scripts/run-selftest.sh --selftest-voice-grounding
Scripts/run-selftest.sh --selftest-tool-awareness
Scripts/run-selftest.sh --selftest-voice-turn-routing
Scripts/run-selftest.sh --selftest-persona
Scripts/run-selftest.sh --selftest-toolloop-live --quick --model apple \
  --report "$PWD/Tests/Reports/toolloop-live/$(date +%F)-P1-11-apple-fm-quick.md"
Scripts/run-selftest.sh --selftest-toolloop-live --quick \
  --report "$PWD/Tests/Reports/toolloop-live/$(date +%F)-P1-11-quick.md"
```

**Success threshold:**
- cases a–e are green (red first);
- quick eval on Apple FM (the model that fabricated): **0 `FABRICATED`**;
- on the Agent-role model, the quick score is not lower than the previous quick run on the same
  model, and `REFUSAL` rises by at most 1.

**Risks & rollback:**
- False positives on legitimate text ("You asked me to open Safari"). Claims require a first-person
  completed verb or an id, the second strike comes only after a re-plan, and the audit log records
  every hit for tuning.
- To roll back, remove the two call sites. The history flag defaults to `false`.

**Done when:**
- [ ] The guard is live in the planner and the first pass, and the speech hold is in place.
- [ ] History scrubbing is live for the model views only.
- [ ] Cases a–e are green, red first.
- [ ] The quick eval on Apple FM shows 0 `FABRICATED`, and both reports are saved.
- [ ] Committed as `P1-11: …`.

---

### P1-12 — "Controlling your Mac": remember when Codex is out of quota, fall back to the Agent's model, and say so in plain words

**Finding(s):** G N6 (turn M1), related to T14 (raw errors). **Effort:** 1 day. **Depends on:** P0-14 (one provider per turn, so the fallback provider is resolved once). Soft: P1-10b (when it has landed, route the sentence through `AgentTurnOutcome.handedOffFellBack`). **Unblocks:** Phase 1 exit; the P0-01 step 1b workaround can be lifted.

**Why (what the user experiences today):** Turn M1, 22:06:17 local: "open chrome".
- The request matched the computer-use pattern `\bopen (?:safari|chrome|finder|system settings)\b`
  (`ModelRoleStore.swift:659`), whose role was `app:codex`.
- The typed reply began: "Codex stopped: ERROR: You've hit your usage limit. Visit
  https://chatgpt.com/codex/settings/usage … I'll do it myself."
- The hand-off took about 9 s (estimate, G §2.3). The fallback then cold-loaded the MiniCPM5 GGUF
  (3.44 s) even though the Agent role was Apple FM at that moment. The model's first pass was a
  denial, and a deterministic shortcut finally opened Chrome after **16.12 s** (M).
- Codex is out of quota until Sep 26 15:43 (G §5), and every "open …" repeats the whole sequence.

**Files you will change:**
- new `Agent/Backend/CodexQuotaStore.swift`;
- `Agent/Backend/CodexComputerUse.swift`: `route(_:)` (`:183-202`), `probe()` (`:76-84`), and
  `CodexComputerUseReadiness` (`:431-470`, add `.outOfQuota` with `note` and `label`);
- `Support/ModelRoles/ModelRoleStore.swift`: `provider(for:)`, splitting `case .builtIn, .app:`
  (`:581-582`);
- the Settings row that shows computer-use readiness (grep `CodexComputerUseReadiness` under
  `UI/Settings/`): the note and a "Try Codex again" button;
- `Agent/RealtimeAgent+ToolLoop.swift`: the hand-off note (`:364-369`);
- `Support/ModelRoles/ModelRoleSelfTest.swift`: new cases.

**Read for context (do not change):**
- `AgentModelRouting.provider(for:voice:)` (`ModelRoleStore.swift:726-745`);
- `ModelRoleStore.computerUseHarness` (`:615`), which reads `resolution(for: .computerUse).effective.harness`,
  so readiness drives it;
- `HandoffError.errorDescription` (`CodexComputerUse.swift:133-147`);
- `RealtimeAgent.voiceSafeReply` (`Agent/RealtimeAgent.swift:178-199`), which scrubs usage-limit
  errors, but for voice only.

**Current behaviour** (verified 2026-09-23):
```swift
// CodexComputerUse.route — :183-202
guard ModelRoleStore.role(forUtterance: prompt) == .computerUse,
      ModelRoleStore.shared.computerUseHarness == .codex else { return nil }
...
} catch let error as HandoffError {
    return .fellBack((error.errorDescription ?? "Codex couldn’t do that.") + " I’ll do it myself.")
```
- `HandoffError.failed(_, output)` renders as "Codex stopped: <last output line>" (`:143-145`).
  Nothing remembers the failure, so the next request runs Codex again.
- `ModelRoleStore.provider(for:)` sends `.app` to `builtInProvider(for:)` (`:581-593`). That is
  `LLMProviders.resolve(preferring: .appLLM)`, the GGUF that `activeAgentModelID` names, and not the
  Agent role's model.
- `runModelTurn(_:speech:voice:)` prepends the note verbatim: `handoffNote + "\n\n" + result.reply`
  (`ToolLoop:364-369`).

**Target behaviour:**
1. A hand-off failure whose output says the usage limit was hit is remembered, with its reset time,
   in `CodexQuotaStore` (UserDefaults key `codex.quotaExhaustedUntil`, a `Date`). The reset time is
   parsed from the output. If no date can be read, the store assumes 6 hours (estimate).
2. Until that time:
   - `probe()` returns `.outOfQuota`, so `computerUseHarness` is nil;
   - `route` runs no hand-off and shows no approval card;
   - the Settings row is grey and reads "Codex has used up its allowance until <weekday, time>.
     Next Notes does these itself until then.", with a "Try Codex again" button that clears the
     store.
3. The first request that meets a remembered quota (once per quota window, persisted) starts with
   one plain sentence: "Codex can't take this until <weekday, time>, so I did it here." Later
   requests in the same window say nothing extra. No reply contains "ERROR:" or a URL from Codex.
4. When a job pointed at an agent app (`.app(_)`) falls back to a model, it uses the Agent role's
   provider (`provider(for: .agent)`), not `.appLLM`.
5. Any other hand-off failure reads "Codex couldn't do that, so I did it here.", and the raw output
   goes to the audit log only.

**Steps:**
1. `CodexQuotaStore.swift`:
   ```swift
   @MainActor final class CodexQuotaStore {
       static let shared = CodexQuotaStore(defaults: .standard)
       init(defaults: UserDefaults, now: @escaping @Sendable () -> Date = { Date() })
       var exhaustedUntil: Date? { get }                    // nil when unset or already past
       func recordFailure(output: String) -> Bool           // true when it was a quota failure
       func clear()
       /// Returns the one-time sentence for this window, then nil until the window changes.
       func announcementIfNew() -> String?
       /// Read without the main actor, for `probe()`.
       nonisolated static func exhaustedUntil(defaults: UserDefaults, now: Date) -> Date?
       /// nil → not a quota error; .some(nil) → quota error without a readable date.
       nonisolated static func parseUsageLimit(_ output: String, now: Date, calendar: Calendar) -> Date??
   }
   ```
   Quota detection is case-insensitive: "usage limit" or "hit your limit". For the date, read the
   words after "try again at", "try again after" or "resets at".
   **Capture the real wording before writing the parser.** Run this read-only:
   `grep -n "usage limit" ~/Library/Application\ Support/Next\ Notes/agent-audit.jsonl | tail -3`.
   Copy only the Codex sentence into the self-test as a fixture. Do not guess the date format.
2. `route`:
   - First: `if CodexQuotaStore.shared.exhaustedUntil != nil { return CodexQuotaStore.shared.announcementIfNew().map { .fellBack($0) } }`.
     A nil result means "not this turn", so the turn proceeds normally, with no note.
   - In `catch let error as HandoffError`, when the error is `.failed(_, output)` and
     `CodexQuotaStore.shared.recordFailure(output:)` returns true, return the quota sentence.
     Otherwise return `.fellBack("Codex couldn't do that, so I did it here.")`.
   - In both cases, `AgentAuditLog.shared.record(kind: .reply, title: "Codex hand-off failed", detail: String(output.suffix(300)))`.
3. `probe()`: before `.ready`, add
   `guard CodexQuotaStore.exhaustedUntil(defaults: .standard, now: Date()) == nil else { return .outOfQuota }`.
   Add `case outOfQuota` to `CodexComputerUseReadiness`, with label "Out of allowance" and the note
   from Target 2. The enum is `String`-backed `Codable`, so check any stored copies still decode
   (grep).
4. `ModelRoleStore.provider(for:)`:
   ```swift
   case .builtIn:
       return await builtInProvider(for: role)
   case .app:
       // An agent app is not a model. When the turn stays here, it answers with the model the
       // person chose for the Agent, not with whichever file the library points at.
       return role == .agent ? await builtInProvider(for: role) : await provider(for: .agent)
   ```
   If `resolution(for:)` names a fallback model for the Settings row, make it name the Agent role's
   model the same way (grep `effective`).
5. `ToolLoop:364-369`: the note is now plain, so keep the prepend. Once P1-10b has landed, use
   `render(.handedOffFellBack(note:then:))` and make its sentence the P1-12 one.
6. The Settings row shows `readiness.note`. The "Try Codex again" button calls
   `CodexQuotaStore.shared.clear()`, then `ModelRoleStore.shared.refreshAvailability()` (grep the
   existing refresh; `:319` / `:686` call `CodexComputerUse.probe()`). Use DS tokens only.

**Do not:**
- bypass or pre-approve the Codex approval card;
- run `codex` to "check" the quota;
- store Codex output in UserDefaults (the date only);
- hide the first fallback: the person picked Codex and is told once per window;
- treat `.declined` as a failure;
- write `modelRoles.*` from a self-test (use an isolated suite; `--selftest-store-isolation` checks
  this).

**Red-first self-test:** extend `--selftest-model-roles` (`ModelRoleSelfTest`, final marker
`MODEL_ROLES_OK` / `MODEL_ROLES_FAILED`). Print `MODEL_ROLES_WRONG: <case>` for each failure.
- **a.** `parseUsageLimit` table:
  - the captured Codex sentence → a quota error with the expected date;
  - "You've hit your usage limit." → a quota error with a nil date;
  - "Codex couldn't find Safari" → nil.
- **b.** `CodexQuotaStore(defaults: <isolated suite>, now: <fixed clock>)`:
  - after `recordFailure(<captured sentence>)`, `exhaustedUntil` equals the parsed date;
  - once the clock passes that date, it is nil;
  - `announcementIfNew()` returns a sentence once, then nil, and again after a new failure with a
    later date. The sentence contains neither "http" nor "ERROR".
- **c.** An isolated role store with `.computerUse = .app(.codex)` and `.agent = .appleFoundation`,
  using P0-14's injected-store seams: `provider(for: .computerUse)?.id == provider(for: .agent)?.id`,
  which is `.appleFoundation` when Apple FM is available, and is not `.appLLM`.
- **d.** Call `route` with a remembered quota, through a `runOverrideForTesting` counter (add it
  beside `route`; honoured only under `SelfTest.isRunning`). The counter stays at 0. The first call
  returns `.fellBack` with the quota sentence, and the second returns nil.

**Confirm RED:** add the store with `exhaustedUntil` always nil and `parseUsageLimit` returning nil,
and leave `.app` routed to `builtInProvider`. Cases a, b, c and d must fail.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-model-roles
Scripts/run-selftest.sh --selftest-store-isolation
Scripts/run-selftest.sh --selftest-toolloop-production
Scripts/run-selftest.sh --selftest-acp-confirm
Scripts/run-selftest.sh --selftest-ui-strings
```
Owner smoke, while the Codex quota is still exhausted, with "Controlling your Mac" set back to
Codex: type "open chrome" twice.
- The first reply is one plain sentence, then "Opened Google Chrome.".
- The second reply has no Codex sentence.
- Neither shows a URL.
- The second reply arrives within 2 s (estimate: no hand-off, and no cold GGUF load when the Agent
  role is Apple FM).

**Success threshold:**
- cases a–d are green (red first);
- `STORE_ISOLATION_OK`;
- the owner smoke behaves as described.

**Risks & rollback:**
- A misparsed date could skip Codex for longer than necessary. The Settings row shows the date and
  the "Try Codex again" button.
- Sending `.app` fallbacks to the Agent role could send a computer-use turn to a cloud model if the
  Agent role is cloud. That is the person's own choice for the Agent, and the existing cloud consent
  rules still apply.
- To roll back, revert. The stored date is harmless.

**Done when:**
- [ ] The quota is remembered, parsed from captured text, and cleared from Settings.
- [ ] The fallback follows the Agent role.
- [ ] Plain sentences only, with the raw output in the audit log.
- [ ] Cases a–d green (red first), and the owner smoke is recorded.
- [ ] Committed as `P1-12: …`.

---

### P1-13 — Direct intent: match two-word sites before one-word sites, and send leftover nouns to the planner

**Finding(s):** G N7 (turn A6). **Effort:** 0.5 day. **Depends on:** P1-08 (same functions, its
strict whole-sentence parse and its self-test table). **Unblocks:** eval A01–A03 (regression guard);
Phase 1 exit.

**Why (what the user experiences today):** A6, 22:07:03 local, typed "Open google calendar on google
chrome".
- The shortcut said "Opening https://www.google.com…" and opened Chrome on google.com. The calendar
  never opened.
- The planner then refused ("I cannot access Google Calendar directly") and fabricated a
  `get_agenda` run (P1-11).
- Total 10.00 s, grade 0 (G §2.2).

**Files you will change:**
- `Agent/AgentDirectIntent.swift`:
  - `knownSites` (`:60-68`);
  - `namedURL(in:)` (`:138-156`);
  - `namedApp(in:)` (`:157-172`);
  - `parseOpen` (`:121-135`, and P1-08's strict remainder);
- `Agent/RealtimeAgentToolLoopSelfTest.swift`: append rows to P1-08's table.

**Read for context (do not change):** `knownApps` (`:72-79`; "calendar" → Apple's Calendar app), and
P1-08's steps 1–4.

**Current behaviour** (verified 2026-09-23):
- `knownSites` holds single words only: "google" → `https://www.google.com`, "gmail" →
  mail.google.com, "drive" → drive.google.com. There is no calendar, docs, meet or sheets.
- `namedURL` returns the first site word it finds (`:152-154`):
  `if let site = knownSites[word], knownApps[word] == nil || words.count > 2 { return site }`.
- `namedApp` matches two-word apps first ("google chrome"). A lone "calendar" is Apple's Calendar
  app, so "open google calendar" parses today as `.openURL("https://www.google.com", app: "Calendar")`.
  That follows from reading the code; the red test confirms it.
- After P1-08, the strict parse sends "open google calendar on google chrome" to the planner
  (leftover "calendar"). The loose parse used for voice routing still resolves google.com.

**Target behaviour:**
1. Multi-word site phrases match before single words, and their words are consumed, so neither
   `namedURL` nor `namedApp` reads them again. The phrases:
   - "google calendar" → `https://calendar.google.com`
   - "google docs" → `https://docs.google.com`
   - "google drive" → `https://drive.google.com`
   - "google meet" → `https://meet.google.com`
   - "google sheets" → `https://sheets.google.com`
   - "google slides" → `https://slides.google.com`
   - "google mail" → `https://mail.google.com`
   - "google maps" → `https://maps.google.com`

   Each host is a real Google product host; check each one before adding it.
2. The **strict** parse (the shortcut that acts) returns nil when a site was matched but nouns
   remain that no site, app or structural word accounts for, so the planner decides.
3. The **loose** parse (voice routing only) never returns less than it does today. It may only
   return a better URL. AGENTS.md: a deterministic gate on the conversational path may only add.
4. Expected parses:

   | Input | Strict | Loose |
   |---|---|---|
   | "open google calendar on google chrome" | `openURL(calendar.google.com, app: "Google Chrome")` | same |
   | "open google calendar" | `openURL(calendar.google.com, app: nil)` | same |
   | "open calendar" | `openApp("Calendar")` (unchanged) | same |
   | "open google docs" | `openURL(docs.google.com, app: nil)` | same |
   | "open google" | `openURL(www.google.com)` (unchanged) | same |
   | "open google and search flights" | nil (P1-08) | `openURL(www.google.com)` |
   | "open google calendar and add lunch with Ana" | nil | `openURL(calendar.google.com)` |

**Steps:**
1. `private static let knownSitePhrases: [(words: [String], url: String)]`, sorted by word count,
   longest first.
2. `private static func siteMatch(in words: [String]) -> (url: String, consumed: Set<Int>)?`:
   - phrases first, as contiguous word runs;
   - then today's single-word rule, with its app exception unchanged;
   - then spelled domains, as today.

   `namedURL(in:)` keeps its signature and returns `siteMatch(...)?.url`, so existing callers keep
   compiling.
3. `namedApp(in:excluding:)` skips the consumed word indices, so "calendar" inside "google calendar"
   is not Apple's Calendar app.
4. `parseOpen`: use the consumed indices when computing P1-08's strict remainder. The loose parse
   ignores the remainder, as today.
5. Append the table rows in Target 4 to P1-08's table in `--selftest-toolloop-production`.

**Do not:**
- add hosts you have not checked;
- make the loose parse (the coordinator's `toolShapeRoute` / `namesCapability`) return nil where it
  returned a value before;
- bypass `AgentToolExecutor` or the approval card;
- break "open chrome and go to youtube.com" or "Open Safari" (both are P1-08 regression rows).

**Red-first self-test:** extend P1-08's table in `--selftest-toolloop-production`
(`TOOLLOOP_PRODUCTION_OK` / `…_FAILED`) with the seven rows above. **Red today:** the rows for
"google calendar on google chrome", "google calendar", "google docs" and "google calendar and add
lunch" (loose). Confirm it on the unmodified parser before changing anything.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-toolloop-production
Scripts/run-selftest.sh --selftest-voice-turn-routing
Scripts/run-selftest.sh --selftest-realtime
Scripts/run-selftest.sh --selftest-toolloop-live --only A01,A02,A03,F01
```

**Success threshold:**
- all table rows are green, red rows first;
- `VOICE_TURN_ROUTING_OK` is unchanged;
- A03 and F01 still PASS, and A01/A02 are no worse than after P1-08.

**Risks & rollback:** A longer phrase list could shadow an app name. The phrases are Google products
only, and "google chrome" stays an app (two-word apps and sites are checked against each other in
the table). To roll back, remove `knownSitePhrases`.

**Done when:**
- [ ] Phrases match first, their words are consumed, and the strict remainder respects them.
- [ ] Table rows green (red first); eval rows as stated.
- [ ] Committed as `P1-13: …`.

---

### P1-14 — The echo filter keeps short answers and restatements

**Finding(s):** H2 V1 (H-audit 2026-09-23); prerequisite of H2 V13 (P1-07). **Effort:** 0.5–1 day. **Depends on:** none (land before or with P1-07). **Unblocks:** P1-07 (a "yes" or "calendar" answering the agent's own question must reach the pending-action slot), P3-08 (spoken approvals repeat the card's words).

**Why (what the user experiences today):** When the agent asks "Calendar or email?", a spoken
"Calendar." is thrown away as the agent's own echo, and so is "Yes." after "Yes, I can set that
up. Want me to?", "No." after "No problem — shall I…?", and "Set a reminder for nine" after
"Shall I set a reminder for nine?". Every clause that began playing in the last 15 s counts as
a reference, and a one-word utterance that appears anywhere in one of them is removed; the
capture tick then discards the empty result as "speech activity without usable words". There
is no real-session count (info logs age out), but the mechanism is certain from the code and
the self-test pins it as intended: `"calendar."` 10 s after playback must be erased
(`RealtimeAudioSession.swift:764-769`, verified 2026-09-24).

**Files you will change:**
- `Agent/RealtimeAudioSession.swift` — `playbackEchoMask(for:provisional:now:inherited:)`
  (`:232-283`), `OutputReference` (`:91-95`), `receivePlaybackEvent`/`finishPlaybackReference`
  (`:323-346`), and `echoFilterFailures()` (`:607-…`, the case at `:764-769`).

**Read for context (do not change):** `Activation/AgentCaptureController.swift` —
`filterAppleRecognition`/`filterLocalRecognition` (`:1723-1731`, the per-recognizer inout
state), the endpoint tick's discard branches (`:1225-1233` "discarded speech activity without
usable words", `:1267-1274` `isLikelyPlaybackEcho` → "discarded playback echo");
`Agent/Speech/AgentSpeechSynthesizer.swift` (`PlaybackEvent`: `.startAcknowledged`,
`.completed`, `.interrupted(_, wasRendered:)`); `roadmap/done/agent-analysis-2026-09-23/H2-caps-voice.md` §V1.

**Current behaviour:** `playbackEchoMask` (`RealtimeAudioSession.swift:232-283`) builds
`references = recentOutputs.filter { $0.active || now.timeIntervalSince($0.at) < Self.echoWindow }`
(`echoWindow = 15`, `maxEchoReferences = 6`, `:101-102`). A reference's `at` is its start time
while `active`, and is reset to the end time by `finishPlaybackReference` (`:341-346`). Four
rules mark a heard word as echo:
```swift
let shortEdge = count == 2
    && (heard.count == 2 || i == 0 || i + count == heard.count)
if count >= 3 || shortEdge { for index in i..<(i + count) { mask[index] = true } }   // :248-252
…
let residualIndices = heard.indices.filter { !mask[$0] }                           // :264
if residualIndices.count == 1, let index = residualIndices.first {                 // single-word residual
    … spoken.value == heard[index].value
        || (heard[index].value.count >= 4 && (reference.active || age < 3)
            && Self.oneEditApart(heard[index].value, spoken.value)) …             // :268-281
}
```
plus the provisional-prefix rule (`:253-261`). The inherited mask (`inherited:` from
`EchoRecognitionState`) is applied first. Nothing distinguishes "the agent just asked a
question" from "the agent is still talking".

**Target behaviour:**
- **Kept:** the ≥ 3-word span rule over the whole 15 s window, the provisional-prefix rule, and
  the inherited mask (the part that follows a cumulative recognizer revision).
- **Scoped:** the 2-word short-edge rule and the single-word residual rule (exact and one-edit)
  apply only against references that are `active` or ended ≤ **1.5 s** ago (the AEC tail plus
  Apple's ~1.1 s first-result lag, H2 V1).
- **Question exemption:** when the most recently *ended* reference's text ends in "?" and no
  reference is `active`, a fresh utterance (no inherited `true` position) that arrives more
  than 1.5 s after that end gets **no** lexical rules at all (no span, no short-edge, no
  residual). Inside the 1.5 s tail the normal rules still apply, because that is where a
  delayed recognition of the question itself lands. (This is the audit's rule with the tail
  kept; the audit applied it "once playback has ended". Adjusted so a 1 s-late recognition of
  "Shall I set a reminder for nine?" is still removed.)
- "Calendar." at +3 s after "…calendar or email?" survives; "calendar." at +0.5 s after the
  same clause is still removed; every other existing `echoFilterFailures` case keeps its
  expected value.

**Steps:**
1. Add `static let echoTailSeconds: TimeInterval = 1.5` beside `echoWindow` (`:101`).
2. In `playbackEchoMask`, compute once:
   ```swift
   let recent = references.filter { $0.active || now.timeIntervalSince($0.at) <= Self.echoTailSeconds }
   let lastEnded = recentOutputs.filter { !$0.active }.max(by: { $0.at < $1.at })
   let anyActive = recentOutputs.contains(where: \.active)
   let isFresh = !(inherited ?? []).contains(true)
   let questionExempt = isFresh && !anyActive
       && (lastEnded.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
                           && now.timeIntervalSince($0.at) > Self.echoTailSeconds } ?? false)
   if questionExempt { return mask }          // mask == inherited (all false for a fresh utterance)
   ```
   The raw `text` keeps punctuation (`words(in:)` drops it, `:366-370`), so test the stored
   clause text, not the word list.
3. In the span loop keep `count >= 3` over `references`; apply `shortEdge` only when the
   current `reference` is in `recent` (compare by index or add an `id: UUID` to
   `OutputReference`).
4. In the residual block iterate `recent` instead of `references`. The one-edit branch already
   requires `reference.active || age < 3`; tighten it to the same `recent` set (≤ 1.5 s).
5. Flip the self-test case at `:764-769` into two cases (see below) and add the question
   cases. Update the comment above `userSpeechExcludingPlayback` (`:198-200`) to say which
   rules are acoustic (tail-scoped) and which are span rules.

**Do not:**
- Do not remove or shorten the ≥ 3-word span rule or the inherited mask; they are what stop a
  cumulative revision of the agent's reply from becoming a user turn (physical echo runs, A Hop 12).
- Do not add any length- or shape-based rule; this task only narrows when lexical rules fire.
  On the voice path a gate may only add, never subtract (AGENTS.md), and this change only lets
  more real speech through.
- Do not change `echoWindow` (15 s) or `maxEchoReferences` (6).
- Do not write to user stores from the self-test; `RealtimeAudioSession` state is in-memory and
  the test uses its testing synthesizer tokens.
- Do not use `MainActor.assumeIsolated`; the self-test already runs on the main actor.
- Build with `make build`, install with `make install OPEN=0`; the physical echo test runs
  through `Scripts/run-selftest.sh --via-open` once, never in a loop.

**Red-first self-test:** extend `--selftest-duplex` (`RealtimeAudioSession.runSelfTest()`,
`Agent/RealtimeAudioSession.swift:496`, marker `DUPLEX_OK` / `DUPLEX_FAILED`, one
`DUPLEX_WRONG: <reason>` per failure; CORE tier, unchanged), inside `echoFilterFailures()`:
1. Replace the case at `:764-769` (`"calendar."` at `+10` s while the second clause is still
   `active`) with two cases using a fresh `session.speak("Would you like the calendar or email?")`,
   `notifyTestingFirstAudio` then `notifyTestingAudioFinished` for its token:
   - a. `userSpeechExcludingPlayback("calendar.", now: Date().addingTimeInterval(0.5))` → `""`
     (inside the tail);
   - b. `userSpeechExcludingPlayback("Calendar.", now: Date().addingTimeInterval(3))` →
     `"Calendar."` (question exemption). **Red today** (returns `""`).
2. After a completed non-question clause "Yes, I can set that up for you." (finished):
   `"Yes."` at +3 s → `"Yes."` (single-word residual now tail-scoped). **Red today.**
3. After a completed question "Shall I set a reminder for nine?": `"Set a reminder for nine"`
   at +3 s → unchanged (exempt); at +1.0 s → `""` (inside the tail, span rule).
   The +3 s half is **red today**.
4. While a clause is still `active` (first audio acknowledged, not finished):
   `"calendar."` at +10 s → `""` (active reference; the old intent is kept for a live clause).
5. Inherited mask disables the exemption: after the completed question "Shall I set a
   reminder for nine?", call `userSpeechExcludingPlayback("Shall I set a", recognition: &state,
   now: +0.8 s)` (inside the tail: all four words become echo and are stored in `state`), then
   the cumulative revision `userSpeechExcludingPlayback("Shall I set a reminder for nine yes",
   recognition: &state, now: +3 s)` → `.text == "yes"` (the inherited positions keep the
   utterance non-fresh, so the span rule still removes "set a reminder for nine"; the lone
   "yes" is outside the 1.5 s tail and survives).
6. Every other existing case in `echoFilterFailures()` keeps its expected value (they are the
   regression net: "09:06 two-word reply tail", "09:07 revised reply tail", "active long
   clause let one-edit playback tail through", "expired playback reference…").
Confirm red by running `--selftest-duplex` with only the new cases added: 1b, 2 and 3 (+3 s)
fail on the unmodified mask.

**Verify:**
```bash
make build
make install OPEN=0
Scripts/run-selftest.sh --selftest-duplex
Scripts/run-selftest.sh --selftest-voice-turns
Scripts/run-selftest.sh --selftest-voice-barge ~/Library/Caches/NextNotesBuild/voice-fixtures/stop16k.wav
# (if stop16k.wav is absent, record SKIP in STATUS.md; P2-01 creates the fixture)
# Physical, owner-run, once, with speakers audible to the microphone:
Scripts/run-selftest.sh --via-open --selftest-voice-echo-live
make acceptance TIER=core
```

**Success threshold:** `DUPLEX_OK` with cases 1–6 (1b, 2, 3 red first); `VOICE_TURNS_OK`;
`VOICE_BARGE_OK` (or SKIP when the fixture is absent); `--selftest-voice-echo-live` no worse
than its last recorded run (owner-run; record the result or "not run" in `STATUS.md`); no new
CORE FAIL.

**Risks & rollback:** A real echo tail longer than 1.5 s of a one-word clause could now reach
the model as a user turn (e.g. the agent says "Okay." and hears it back 2 s later). Watch the
`realtime · discarded playback echo` and `realtime · removed playback from mixed turn` info
lines during the owner's echo-live run; if a tail leaks, raise `echoTailSeconds` to 2.0 (one
constant) rather than restoring the 15 s single-word rule. Rollback: revert the `recent` scoping
and the exemption (one function) and restore the old `:764-769` case.

**Done when:**
- [ ] `DUPLEX_OK` with the six cases (1b, 2, 3 red first), other echo cases unchanged.
- [ ] `VOICE_TURNS_OK`, `VOICE_BARGE_OK`/SKIP recorded; echo-live result or "not run (owner)" in `STATUS.md`.
- [ ] `grep -n "echoTailSeconds" Sources/NextNotes/Agent/RealtimeAudioSession.swift` shows it used by both the short-edge and the residual rule.

---

### P1-15 — Goodbye is recognised by exact signature, not by substring

**Finding(s):** H2 V16 (H-audit 2026-09-23). **Effort:** 2–3 hours. **Depends on:** none. **Unblocks:** P3-10 (its side-talk close reuses the same exact-signature form).

**Why (what the user experiences today):** `isGoodbye` is `lowered.contains` over phrases that
include "that's it", "nothing else", "go to sleep" and "we're done". So "Is there nothing else
on my calendar?", "Remind me to go to sleep at eleven." and "Tell me when we're done with the
deck." each **close the voice session** before the request is handed on: the goodbye branch
calls `closeSession()`, `RealtimeAudioSession.end()` and `VoiceAnnouncementQueue.clear()` first,
so the answer is probably never spoken and pending announcements are thrown away. No real
instance was found (0 of the audit requests contain a goodbye phrase, H2 V16); this is a
subtractive deterministic gate matched by fragment, the class AGENTS.md bans on the voice path.

**Files you will change:**
- `Activation/AgentCaptureController.swift` — `isGoodbye(_:)` (`:2392-2399`, private static;
  verified 2026-09-24, the audit's `:2350` has drifted).
- `Activation/VoiceTurnPolicy.swift` — new `closingSignatures`, `closingLeads` and
  `isClosingTurn(_:)` beside `knownNoiseFragments` (`:56-65`), plus cases in
  `selfTestFailures()` (`:89-…`).

**Read for context (do not change):** the goodbye branch in the endpoint tick
(`AgentCaptureController.swift:1285-1296`):
```swift
if Self.isGoodbye(text) {
    isSessionActive = false
    VoiceConversationCoordinator.shared.closeSession()
    await LocalVoiceFrontend.shared.clearStagedTurn()
    RealtimeAudioSession.shared.end()
    VoiceAnnouncementQueue.shared.clear()
    await emitTurn(text, source: .goodbye, continueSession: false)
    …
```
`VoiceTurnPolicy.normalizedKey(_:)` (`:68-73`: lowercase, split on non-letters/digits, joined by
single spaces, so "That's all." → `"that s all"`); AGENTS.md "On the conversational path, a
deterministic gate may only add, never subtract".

**Current behaviour:**
```swift
// AgentCaptureController.swift:2392-2399
private static func isGoodbye(_ text: String) -> Bool {
    let lowered = text.lowercased()
    return [
        "that's all", "thats all", "that's it", "thats it",
        "goodbye", "good bye", "stop listening", "go to sleep",
        "nothing else", "we're done", "we are done",
    ].contains { lowered.contains($0) }
}
```
A substring anywhere in the turn ends the session.

**Target behaviour:**
- A turn closes the session only when its `normalizedKey` **equals** a closing signature, or
  **ends with** one as a whole trailing clause (the key's last words are the signature, preceded
  by the start of the key or by a word boundary after an acknowledgment such as "thanks" /
  "thank you" / "ok" / "okay"). Examples that close: "Goodbye.", "Thanks, that's all.",
  "Okay, that's it for now.", "Stop listening.", and "That's all, thank you." (listed whole as
  `"that s all thank you"`, since the acknowledgment trails).
- These do **not** close (positive corpus): "Is there nothing else on my calendar?", "Remind me
  to go to sleep at eleven.", "Tell me when we're done with the deck.", "Is that it for the
  budget?", "Say goodbye to Ana in the email.", and "What's on my calendar? That's all I need to
  know" (its key is not a signature and does not start with a closing lead).
- Everything that does not close goes to `emitTurn(…, continueSession: true)` as today.

**Steps:**
1. In `VoiceTurnPolicy` add, in `normalizedKey` form:
   ```swift
   /// Whole-turn closing signatures. Exact strings, never rules (same contract as
   /// `knownNoiseFragments`). A turn closes the session only when its key equals one of
   /// these, or ends with one after a leading acknowledgment.
   static let closingSignatures: Set<String> = [
       "goodbye", "good bye", "bye", "bye bye",
       "that s all", "thats all", "that s it", "thats it", "that s it for now", "that s all for now",
       "that s all thanks", "that s all thank you", "that s it thanks", "that s it thank you",
       "stop listening", "go to sleep", "nothing else", "nothing else thanks", "nothing else thank you",
       "we re done", "we are done", "i m done", "i am done",
   ]
   static let closingLeads: Set<String> = ["thanks", "thank you", "ok", "okay", "great", "perfect", "no"]
   static func isClosingTurn(_ utterance: String) -> Bool {
       let key = normalizedKey(utterance)
       if closingSignatures.contains(key) { return true }
       for lead in closingLeads where key.hasPrefix(lead + " ") {
           if closingSignatures.contains(String(key.dropFirst(lead.count + 1))) { return true }
       }
       return false
   }
   ```
   "Ends with" is implemented as *lead + signature*, not as `hasSuffix`, so "Remind me to go to
   sleep" can never match "go to sleep".
2. Replace the body of `AgentCaptureController.isGoodbye(_:)` with
   `VoiceTurnPolicy.isClosingTurn(text)` (keep the private wrapper so the call site at `:1285`
   is unchanged).
3. Add the cases below to `VoiceTurnPolicy.selfTestFailures()`.

**Do not:**
- Do not use `contains`, `hasSuffix` on raw text, word counts or any other shape rule; the list
  names its entries (AGENTS.md: suppression only on exact signatures, graded against a positive
  corpus).
- Do not remove a phrase that closes today without listing its whole-turn form in
  `closingSignatures` (a user who says "That's all." must still end the session).
- Do not change what the goodbye branch does once it fires; P0-23 ("That wasn't for you") and
  P3-10 (side talk) own other ways to close.
- Do not write to user stores from the self-test (pure string checks).

**Red-first self-test:** extend `--selftest-voice-turns` (`AgentCaptureController.turnPolicySelfTestFailures()`
at `Activation/AgentCaptureController.swift:1948`, which starts with
`VoiceTurnPolicy.selfTestFailures()`; registered in `NextNotesApp.swift:1471-1480`; marker
`VOICE_TURNS_OK` / `VOICE_TURNS_FAILED`, one `VOICE_TURNS_WRONG: <reason>` per failure;
acceptance entry `selftest-voice-turns|300` unchanged). In `VoiceTurnPolicy.selfTestFailures()`:
1. **Must close** (each `isClosingTurn == true`): "Goodbye.", "Bye!", "That's all.", "Thanks,
   that's all.", "Okay, that's it for now.", "Stop listening.", "Go to sleep.", "Nothing else,
   thanks.", "We're done.", "That's all, thank you."
2. **Must not close** (each `isClosingTurn == false`): "Is there nothing else on my calendar?",
   "Remind me to go to sleep at eleven.", "Tell me when we're done with the deck.", "Is that it
   for the budget?", "Say goodbye to Ana in the email.", "What's on my calendar? That's all I
   need to know", "I'm done with the report, can you send it?", "Thanks for the summary".
   **Red today:** run the same fixtures through a copy of the old substring rule first (or call
   the unmodified `isGoodbye` via a temporary `static func legacyIsGoodbyeForTesting`); the
   first three "must not close" rows, "Say goodbye to Ana…" and "What's on my calendar? That's
   all I need to know" return true under the old rule. Delete the temporary function after the
   switch.
3. Every entry of `closingSignatures` satisfies `isClosingTurn` (the list grades itself).

**Verify:**
```bash
make build
make install OPEN=0
Scripts/run-selftest.sh --selftest-voice-turns
Scripts/run-selftest.sh --selftest-voice-turn-routing
Scripts/run-selftest.sh --selftest-voice-conversation
Scripts/run-selftest.sh --selftest-duplex
make acceptance TIER=core
```

**Success threshold:** `VOICE_TURNS_OK` with 10 closing and 8 non-closing fixtures (the
"must not close" rows red first); `VOICE_TURN_ROUTING_OK`, `VOICE_CONVERSATION_OK`, `DUPLEX_OK`
unchanged; no new CORE FAIL.

**Risks & rollback:** A goodbye said in an unlisted form ("alright, I'm off") no longer closes
the session; the 25 s idle close still does (H2 V15). Add the form as a signature, with a
fixture, when it is seen in logs. Rollback: restore the old body of `isGoodbye` (one function).

**Done when:**
- [ ] `VOICE_TURNS_OK` with both corpora (non-closing rows red first).
- [ ] `grep -n "lowered.contains" Sources/NextNotes/Activation/AgentCaptureController.swift` no longer matches inside `isGoodbye`.
- [ ] `isGoodbye` has exactly one caller (`:1285`) and delegates to `VoiceTurnPolicy.isClosingTurn`.

---

### P1-16 — Pending approvals stay visible until answered

**Finding(s):** H3 #5, #6 (H-audit 2026-09-23); visual half of C8. **Effort:** 1 day. **Depends on:** none (independent of the tool loop; land beside P1-07). **Unblocks:** P3-08 (spoken approvals need the card to still be there), P3-09 (island ownership keeps this live kind).

**Why (what the user experiences today):** An approval card at the notch disappears after 8 s
while the request is still waiting. `PermissionGate.raiseIsland` → `IslandState.propose` →
`push(.agentProposal, for: DS.Motion.islandNotice)` with `islandNotice = 8`; when the notice
expires the island falls back to `liveKind()`, which has no case for a pending approval, so it
goes blank (or back to the meeting strip). The tool loop, ACP, the Needle watcher and the
first-ingestion consent all wait on `PermissionGate.ask` with no timeout, and in voice use the
main window is usually closed, so after 8 s nothing on screen says the agent is blocked on the
user. For meetings it is worse: the Needle watcher's card holds its only slot for 180 s
(`cardLifetime`) while it is visible for 8 s, and every later actionable sentence is dropped
with "a card of ours is already waiting" (H3 #6).

**Files you will change:**
- `UI/Island/IslandState.swift` — `Kind` (`:69-111`: new case), `identity` (`:133-148`),
  `demandsAttention` (`:153-160`), the orb switch (`:183-198`), `avatarState` (`:232-240`),
  title (`:255-267`), `liveKind()` (`:496-541`), `observe()` (`:551-…`), `init` (`:300-308`:
  injectable pending source), `handle(_:)` (`:627-650`).
- `UI/Island/IslandView.swift` — the collapsed and expanded renderings (the `switch` arms at
  `:259`, `:330`, `:457` that draw `.agentProposal`; add `.pendingApproval`).
- `Agent/Permissions/PermissionGate.swift` — extract the proposal built in `raiseIsland(for:)`
  (`:55-68`) into `func islandProposal(for request: PermissionRequest) -> IslandProposal` so the
  live kind and the notice draw the same card.
- `UI/DesignSystem.swift` — only if a new size or spacing is needed for the badge (add a token;
  never a literal in a view).
- `NextNotesApp.swift` — `islandStateFailures()` (`:3587-…`) new cases.

**Read for context (do not change):** `Agent/FunctionCalling/FunctionCallWatcher.swift`
(`cardLifetime = 180` `:59`, `maximumOutstandingCards = 1` `:67`, `maximumCardsPerWindow = 3`
`:69`, `rateLimitWindow = 600` `:70`; `present(_:trigger:)` `:531-560`, which cancels the
`ask` after `cardLifetime` so `PermissionGate.cancelPending(id:)` clears it);
`PermissionGate.respond` (`:85-…`, sets `pending = nil` and calls
`IslandState.shared.dismissNotice()` `:104-108`); `cancelPending()` / `cancelMatching`
(`:143-176`); `DS.Motion.islandNotice` (`UI/DesignSystem.swift:784`); AGENTS.md "Design system"
(tokens only, red means recording, the orb table: `breathing` = "an armed meeting awaiting an
answer … waiting on purpose"; the character table: `waiting` = "held up on a person — an
approval").

**Current behaviour:**
```swift
// IslandState.swift:365-367
func propose(_ proposal: IslandProposal) {
    push(.agentProposal(proposal), for: DS.Motion.islandNotice)
}
// IslandState.swift:470-479
func refresh() {
    let next = notice?.kind ?? liveKind()
    …
}
```
`liveKind()` (`:496-541`) returns, in order: `.agentWorking` (mode `.agentWorking`),
`.agentListening`, dictation, `.meetingRecording`, `.transcribing`, `.diarizing`,
`.summarizing`, `.hidden`. It never reads `PermissionGate.shared.pending`. `rearmNotice`
(`:611-625`) takes the notice down after 8 s unless hovered.

**Target behaviour:**
- New live kind `case pendingApproval(IslandProposal, waiting: Int)`, derived from
  `PermissionGate.shared.pending` (`waiting` = 1 + `PermissionGate.shared.queuedCount`).
- Order in `liveKind()`: `.agentWorking` **only when nothing is pending** → `.agentListening` →
  dictation → **`.pendingApproval`** → `.meetingRecording` → … . An agent that is "working"
  while a card is pending is blocked on the person, so the badge wins over the working card;
  listening and dictation keep priority because they prove the microphone is live.
- The 8 s notice is unchanged (the card opens by itself, as today). When it lapses, the island
  collapses to a persistent badge ("1 waiting", "2 waiting") instead of disappearing.
  `demandsAttention` is false for `.pendingApproval`, so it stays collapsed until hovered;
  hovering expands the same proposal card with its Approve/Dismiss buttons.
- The badge clears only when `PermissionGate.pending` becomes nil: `respond`, `cancelPending*`,
  or the asker's own cancellation (the Needle watcher's 180 s expiry).
- **Needle watcher (H3 #6), chosen approach: the badge is its surface.** Keep `cardLifetime`
  180 s, 1 outstanding card and 3 per 10 minutes unchanged. Justification: withdrawing the card
  when its 8 s notice lapses un-hovered would give every meeting proposal an 8 s life, and in a
  meeting the user is rarely looking at the notch in those 8 s, so almost every proposal would
  vanish unseen; with the badge the one outstanding card stays discoverable for its whole
  180 s and then withdraws itself through the existing `ask.cancel()`, which frees the slot.
  No change to `FunctionCallWatcher` is needed; the self-test proves the expiry clears the badge.
- Colours: `DS.Color.island`/`islandInk` (black/white at the notch) or semantic ink when
  floating; **never** `DS.Color.record` (red means recording only). Orb `breathing`; avatar
  `waiting`. Visible text: "1 waiting" (plain words; passes `--selftest-ui-strings`).

**Steps:**
1. `PermissionGate`: move the `IslandProposal(…)` construction out of `raiseIsland(for:)` into
   `func islandProposal(for request: PermissionRequest) -> IslandProposal` (same fields:
   `id`, `title`, `detail`, `meetingID`, `needsReview`, `canExecute`, `needsCount`), and have
   `raiseIsland` call it.
2. `IslandState.init` gains
   `pendingApproval: @escaping @MainActor () -> (IslandProposal, Int)? = IslandState.livePendingApproval`,
   stored `@ObservationIgnored`, where
   ```swift
   @MainActor static func livePendingApproval() -> (IslandProposal, Int)? {
       guard let request = PermissionGate.shared.pending else { return nil }
       return (PermissionGate.shared.islandProposal(for: request), 1 + PermissionGate.shared.queuedCount)
   }
   ```
3. `Kind`: add `case pendingApproval(IslandProposal, waiting: Int)`; `identity` →
   `"pending:\(proposal.id):\(waiting)"`; `demandsAttention` → false; orb → `.breathing`;
   `avatarState` → `.waiting`; title → `proposal.title`. Fix every exhaustive `switch` the
   compiler flags (`IslandView` included).
4. `liveKind()`: compute `let pending = pendingApproval()` once at the top; guard the
   `.agentWorking` branch with `pending == nil`; after the dictation branch and before
   `meetingRecording`, `if let (proposal, waiting) = pending { return .pendingApproval(proposal, waiting: waiting) }`.
5. `observe()`: read `_ = PermissionGate.shared.pending` and `_ = PermissionGate.shared.queuedCount`
   inside `withObservationTracking` (`PermissionGate` is `@Observable`), so an answer or a
   cancel refreshes the island without a timer.
6. `handle(_:)`: `.approveProposal(id)`/`.dismissProposal(id)` for the proposal shown in a
   `.pendingApproval` live kind need no notice clearing (the gate's `respond` clears `pending`);
   leave the existing `.agentProposal` arm as is.
7. `IslandView`: collapsed `.pendingApproval` draws a small capsule with the orb (still, not
   animated: nothing is processing — AGENTS.md "never animate an orb … naming work that is not
   running") and the text "\(waiting) waiting"; expanded draws exactly what `.agentProposal`
   draws for the same proposal (reuse the view; do not copy it). Sizes, spacing and fonts from
   `DS` tokens only.

**Do not:**
- Do not put a literal colour, size or duration in a view; add a `DS` token if one is missing.
- Do not use `DS.Color.record` or any red for the badge (red means recording, and only that).
- Do not animate the badge's orb (`isAnimated: false`); one animating orb per screen, and only
  for work that is running.
- Do not make the badge `demandsAttention` (a card that re-expands itself forever would cover
  the notch area for the whole wait); it expands on hover.
- Do not add a timeout to `PermissionGate.ask` or change the Needle watcher's 180 s / 1 / 3-per-10-min
  limits in this task.
- Do not change `IslandPanel`'s frame behaviour (the panel is always the expanded size;
  AGENTS.md "The island panel is always the size of its expanded card").
- Do not use `MainActor.assumeIsolated`; `IslandState` is main-actor already.
- Self-tests never write user stores: `PermissionGate` state is in-memory; do not call
  `respond(approved: true)` on a request that would execute anything (use `cancelPending(id:)`).

**Red-first self-test:** extend `--selftest-island` (`runIslandSelfTest()`,
`NextNotesApp.swift:3493`; marker `ISLAND_OK: …` / `ISLAND_FAILED: <n> rule(s) wrong`, one
`  ISLAND_WRONG: <reason>` per failure; acceptance entry `selftest-island|300` unchanged). In
`islandStateFailures()` (`NextNotesApp.swift:3587-…`), with a fixture proposal
`p = IslandProposal(id: "selftest-approval", title: "Send the deck to Ana", detail: "…", meetingID: nil)`
and a local `var fakePending: (IslandProposal, Int)? = nil` injected through the new init
parameter:
1. `state.propose(p)` → `kind == .agentProposal(p)` and `isExpanded`.
2. Set `fakePending = (p, 1)`, then `state.dismissNotice()` (stands in for the 8 s lapse) →
   `kind == .pendingApproval(p, waiting: 1)`, `!isExpanded`, `cardIdentity == "pending:selftest-approval:1"`.
   **Red today:** `kind == .hidden`.
3. `state.isHovered = true` → `isExpanded`; `state.isHovered = false` → collapsed again, still
   `.pendingApproval`.
4. `fakePending = (p, 2)`; `state.refresh()` → `.pendingApproval(p, waiting: 2)`.
5. `fakePending = nil`; `state.refresh()` → `.hidden`.
6. Ordering. `ActivationController.shared.mode` cannot be injected into this test, so put the
   priority decision in a pure static function that `liveKind()` calls, e.g.
   `enum LiveSource { case working, listening, dictating, pendingApproval, recording, none }`
   and `static func liveWinner(working: Bool, listening: Bool, dictating: Bool, pending: Bool, recording: Bool) -> LiveSource`,
   and check: working + pending → `.pendingApproval`; listening + pending → `.listening`;
   dictating + pending → `.dictating`; pending + recording → `.pendingApproval`; working alone
   → `.working`.
7. **Integration with the real gate (Needle expiry path):** build a `PermissionRequest` the way
   `FunctionCallWatcher.request(for:tool:trigger:)` does (it is `static` and pure) for a
   `.read` fixture tool; start `Task { await PermissionGate.shared.ask(request) }`, wait up to
   1 s; a default-initialised `IslandState()` refreshed after `dismissNotice()` shows
   `.pendingApproval` with that request's id; then cancel the asking task (what the watcher's
   180 s expiry does) → within 1 s `PermissionGate.shared.pending == nil` and the state is not
   `.pendingApproval`. **Red today** at the first assertion.
8. `IslandView` renders `.pendingApproval` (add it to `islandViewFailures()`'s list of kinds
   evaluated through `apply(_:)`), and its rendered text contains "waiting".
Confirm red: cases 2 and 7 fail on the unmodified `liveKind()`.

**Verify:**
```bash
make build
make install OPEN=0
Scripts/run-selftest.sh --selftest-island
Scripts/run-selftest.sh --selftest-orb
Scripts/run-selftest.sh --selftest-avatar
Scripts/run-selftest.sh --selftest-ui-strings
Scripts/run-selftest.sh --selftest-function-calls   # FUNCTION_CALLS_NEEDLE_ABSENT is SKIP, not a pass
Scripts/run-selftest.sh --selftest-acp-confirm
grep -n "DS.Color.record" Sources/NextNotes/UI/Island/IslandView.swift   # no new match in the badge
make acceptance TIER=core
```

**Success threshold:** `ISLAND_OK` with cases 1–8 (2 and 7 red first); `ORB_OK`, `AVATAR_OK`,
`UI_STRINGS_OK`, `ACP_CONFIRM_OK` unchanged; `--selftest-function-calls` unchanged (OK or its
documented `_ABSENT`); no new CORE FAIL. The badge is not verified by eye on this machine
(Screen Recording is not granted; AGENTS.md "What has never run"); record that in `STATUS.md`.

**Risks & rollback:** A request that is never answered and never cancelled (an asker with no
timeout) now leaves a permanent badge. That is the point (the agent *is* blocked), but if a
stale badge is reported, find the asker that forgot to cancel rather than timing out the badge.
Rollback: remove the `pending` branch from `liveKind()` (one line) and the badge is gone; the
new `Kind` case is inert without it.

**Done when:**
- [ ] `ISLAND_OK` with the eight cases (2, 7 red first); regression flags unchanged.
- [ ] `liveKind()` reads `PermissionGate.shared.pending` through the injected source; `observe()` tracks it.
- [ ] `PermissionGate.islandProposal(for:)` has two callers (`raiseIsland`, `livePendingApproval`).
- [ ] "Not seen by eye (no Screen Recording grant)" noted in `STATUS.md`.

---

### P1-17 — "Look things up without asking" is honoured by the realtime planner; knowledge visibility no longer depends on it

**Finding(s):** H1 #22 (H-audit 2026-09-23); related H3 #2. **Effort:** 3–4 hours. **Depends on:** P1-01 (the executor fake records calls). Soft: P0-21 (knowledge-tool defaults). **Unblocks:** P1-03 (its knowledge-tool availability line reads the two-switch gate).

**Why (what the user experiences today):** The setting says one thing and does another. Settings
describes `agentAutoRunReadTools` as "Let the agent run read-only tools by itself while it plans"
(`Support/Settings.swift:620-627`), shown as "Look things up without asking"
(`UI/Settings/WorkspaceSettingsTab.swift:137`) and "Read calendar and mail without asking"
(`UI/Settings/AgentSettingsTab.swift:335`). But the realtime planner and the direct intents always
pass `autoApproveReads: true`, so switching it off changes nothing for typed and voice turns. The
one place it *does* bite is the wrong one: `KnowledgeToolGate.isAvailable` hides the knowledge
tools when it is off ("leaving them in would bypass the switch"), so a user who wants to approve
reads loses meeting search entirely instead of getting a card. The default (true) is right and
stays (H1 §2.4 "HELPS").

**Files you will change:**
- `Agent/RealtimeAgent+ToolLoop.swift` — `runTool(_:arguments:progress:)` (`:299-316`,
  `autoApproveReads: true` at `:310`), the planner's `execute` closure (`:1023`,
  `autoApproveReads: true, promptIfNeeded: true`), `directCall(_:_:)` (`:1210-1216`,
  `autoApproveReads: true, promptIfNeeded: true` at `:1215`). Re-grep
  `autoApproveReads: true` in this file: lines move.
- `Agent/RealtimeAgent.swift` — new `readsRunWithoutAsking` and its test override.
- `Knowledge/KnowledgeTools.swift` — `KnowledgeToolGate.isAvailable` (`:24-33`).
- `Knowledge/KnowledgeAskSelfTest.swift:246` — the table that pins the three-input rule.
- `Agent/Tools/AgentToolExecutor.swift` — record the effective read approval under the harness.
- `UI/Settings/AgentSettingsTab.swift:335` — label only (see step 5).
- `Agent/RealtimeAgentToolLoopSelfTest.swift` — new cases.

**Read for context (do not change):** `AgentToolExecutor.run` (`Agent/Tools/AgentToolExecutor.swift:7-60`:
`if autoApproveReads, tool.risk <= .read { effective.autoRead = true; effective.autoObserve = true }`
at `:54-57`); `PermissionPolicy.fromSettings()` (`Agent/Permissions/PermissionPolicy.swift:88-96`,
`autoRead: Settings.shared.agentAutoRunReadTools`); `MeetingAgent` (`Agent/MeetingAgent.swift:22`,
`autoRunReadTools: Settings.shared.agentAutoRunReadTools` — the path that already honours it);
`Agent/Schedules/ScheduledRunner.swift:552` (routines pass `autoApproveReads: true` with
`promptIfNeeded: false` on purpose: nobody is there to answer, and the routine's confirmed tool
list stands in for the switch — leave it).

**Current behaviour:**
```swift
// Knowledge/KnowledgeTools.swift:24-33
static func isAvailable(indexEnabled: Bool, toolsEnabled: Bool, lookThingsUp: Bool) -> Bool {
    indexEnabled && toolsEnabled && lookThingsUp
}
@MainActor static var isAvailable: Bool {
    isAvailable(indexEnabled: Settings.shared.knowledgeIndexEnabled,
                toolsEnabled: Settings.shared.knowledgeAgentToolsEnabled,
                lookThingsUp: Settings.shared.agentAutoRunReadTools)
}
```
and three planner-side calls hard-code `autoApproveReads: true` (`ToolLoop:310`, `:1023`,
`:1215`). `runTool` also omits `promptIfNeeded`, so with reads not auto-approved it could not
show a card.

**Target behaviour:**
- With the switch **on** (default): unchanged. Reads run without a card.
- With the switch **off**: a read the planner, a direct intent or `runTool` wants shows the
  approval card (the same card `MeetingAgent` shows), and runs after approval; nothing is
  hidden from the planner because of the switch.
- `KnowledgeToolGate.isAvailable` = index on **and** Agent knowledge tools on. The cloud-reader
  restriction on `expand_node`/`timeline` (graph consent) is unchanged. `mayRun` (`:37-40`) is
  already the two-switch rule and stays.
- Writes, sends and everything above `.read` are unaffected (they always ask).

**Steps:**
1. `RealtimeAgent`: add
   ```swift
   /// Test-only override, honoured only under `SelfTest.isRunning`, so a self-test never
   /// flips the user's saved setting (Settings writes UserDefaults.standard).
   var readApprovalOverrideForTesting: Bool?
   var readsRunWithoutAsking: Bool {
       if SelfTest.isRunning, let override = readApprovalOverrideForTesting { return override }
       return Settings.shared.agentAutoRunReadTools
   }
   ```
2. Replace the three `autoApproveReads: true` in `RealtimeAgent+ToolLoop.swift` with
   `autoApproveReads: readsRunWithoutAsking`, and give `runTool` `promptIfNeeded: true` so a
   read can raise its card. Leave `ScheduledRunner`, `RoutineAuthoritySelfTest` and
   `VoiceConversationSelfTest` as they are.
3. `KnowledgeToolGate`: replace the three-input function with
   ```swift
   /// The index is on and the Agent may use it. Whether a read runs without asking is the
   /// planner's per-call decision (`autoApproveReads`), never a reason to hide the tools.
   static func isAvailable(indexEnabled: Bool, toolsEnabled: Bool) -> Bool { indexEnabled && toolsEnabled }
   ```
   and the `@MainActor` property to the two settings. Rewrite the doc comment at `:21-23`.
   Update `KnowledgeAskSelfTest.swift:246` to the two-input table
   (`isAvailable(indexEnabled: a, toolsEnabled: b) == (a && b)` over all four combinations);
   this changes what the rule is, not how hard it is checked.
4. `AgentToolExecutor.run`: under `SelfTest.isRunning` append the effective decision to
   `@MainActor static var recordedReadApprovalsForTesting: [(tool: String, autoApproved: Bool)]`
   **before** P1-01's `fakeForTesting` returns, i.e. compute `autoApproved = autoApproveReads && tool.risk <= .read`
   right after the tool lookup and record it first.
5. `UI/Settings/AgentSettingsTab.swift:335`: the label "Read calendar and mail without asking"
   now governs every read the Agent plans (files, meetings, knowledge, pages). Change it to
   "Look things up without asking", the same words as the Workspace tab (`:137`), so one setting
   has one name. The footer copy stays.
6. Grep: `grep -n "autoApproveReads: true" Sources/NextNotes/Agent/RealtimeAgent+ToolLoop.swift`
   → nothing; `grep -rn "lookThingsUp" Sources/NextNotes` → nothing.

**Do not:**
- Do not change the default of `agentAutoRunReadTools` (`Settings.swift:1061`, `?? true`).
- Do not flip `Settings.shared.agentAutoRunReadTools` in a self-test (it writes the user's
  `UserDefaults.standard`); use `readApprovalOverrideForTesting`.
- Do not touch routines' `autoApproveReads: true` (`ScheduledRunner.swift:552`): an unattended
  run cannot answer a card, and its confirmed tool list is the authority.
- Do not widen the knowledge gate for cloud readers: graph tools still need graph consent
  (AGENTS.md "Related-context brief").
- Do not add developer words to the Settings label (`--selftest-ui-strings`).
- Every tool still goes through `AgentToolExecutor.run`; do not add a second path that skips
  the broker.

**Red-first self-test:** extend `--selftest-toolloop-production`
(`RealtimeAgentToolLoopSelfTest.run()`, marker `TOOLLOOP_PRODUCTION_OK` / `…_FAILED`, one
`  TOOLLOOP_PRODUCTION_WRONG: <reason>` per failure), using P1-01's executor fake and a scripted
planner that calls `search_email {"query":"in:inbox"}` once and then answers:
1. `readApprovalOverrideForTesting = false` → `recordedReadApprovalsForTesting` ==
   `[("search_email", false)]`. **Red today:** `true` (hard-coded).
2. `readApprovalOverrideForTesting = true` → `[("search_email", true)]`.
3. A write through the planner (`draft_email`) with the override `true` → recorded `false`
   (reads only; unchanged behaviour, guards against over-reach).
4. `runTool("get_agenda", …)` with the override `false` → recorded `false`.
5. `KnowledgeToolGate.isAvailable(indexEnabled: true, toolsEnabled: true) == true` and
   `(true, false) == false`. **Red first:** before step 3, assert the old
   `isAvailable(indexEnabled: true, toolsEnabled: true, lookThingsUp: false) == true` → fails.
Reset the override to `nil` in a `defer`. `--selftest-ask` (`ASK_OK`) keeps its updated table.

**Verify:**
```bash
make build
make install OPEN=0
Scripts/run-selftest.sh --selftest-toolloop-production
Scripts/run-selftest.sh --selftest-ask
Scripts/run-selftest.sh --selftest-tool-awareness
Scripts/run-selftest.sh --selftest-routine-authority
Scripts/run-selftest.sh --selftest-ui-strings
Scripts/run-selftest.sh --selftest-toolloop-live --quick \
  --report "$PWD/Tests/Reports/toolloop-live/$(date +%F)-P1-17-quick.md"
```

**Success threshold:** `TOOLLOOP_PRODUCTION_OK` with cases 1–5 (1 and 5 red first); `ASK_OK`,
`TOOL_AWARENESS_OK`, `ROUTINE_AUTHORITY_OK`, `UI_STRINGS_OK` unchanged; the `--quick` score is
not lower than the previous quick run on the same model (the eval runs with the default switch
on, so no card appears).

**Risks & rollback:** With the switch off, a voice turn that plans three reads now shows three
cards; that is what the switch promises. If it proves noisy, the answer is P3-08's spoken
approval, not re-hard-coding `true`. Rollback: restore `autoApproveReads: true` at the three
call sites and the third gate input (two small hunks).

**Done when:**
- [ ] Five cases green (1, 5 red first); regression flags unchanged.
- [ ] `grep` checks in step 6 return nothing.
- [ ] Settings shows one name for the switch in both tabs.

---

### P1-18 — History budget scales with the reader's window; lift the 10,000-character session ceiling

**Finding(s):** H1 #9 (H-audit 2026-09-23); Q9 (the typed-history half). This task **takes over
steps 1–2 of P4-08** (typed history budget); P4-08 keeps the voice history (1,400, H2 V20), the
memory prompt budget and the fitted `KnowledgeAsker`. **Effort:** 0.5–1 day. **Depends on:**
P1-10a (step 0: Apple FM's window read at runtime, 8,192 on the dev Mac; without it Apple FM is
budgeted as a 4,096 reader). Soft: P1-02 (removes the typed first pass; its call site then only
serves the voice test path). **Unblocks:** P4-08 (steps 1–2 become "done in P1-18"), P4-02 (the
router sees the previous exchange).

**Why (what the user experiences today):** "Summarise those" loses the list after one more
exchange. The history given to the model is fixed in characters whatever the reader: 2,500 on
the first pass, 2,500 or 6,000 in the planner, 3,000 on the `.localModel` path, 1,800 per
message, and a hard 10,000 ceiling on the session context. This Mac's typed reader can be an
OpenRouter model with a 262,144-token window (report M), yet it is given 2,500 characters on
the first pass: less than one email listing plus its question. P4-08 as written targets 12,000
at ≥ 32K, which the 10,000 ceiling would clip **silently**, and it does not list the
`.localModel` call site (H1 #9).

**Files you will change:**
- New `Agent/AgentHistoryBudget.swift`.
- `Agent/RealtimeAgent+ToolLoop.swift` — the first pass (`runModelTurn`, private:
  `let history = AgentSession.shared.chatHistoryForCurrentTurn(maxCharacters: 2_500)` at
  `:382`; the window is read later, at `:393`), the planner split
  (`AgentSession.shared.contextForCurrentTurn(maxCharacters: provider.contextTokens < 8_000 ? 2_500 : 6_000)`
  at `:835-837`).
- `Agent/RealtimeAgent.swift` — `.localModel` path: `conversationGroundedPrompt(_:reader:)`
  (`:748-760`, `contextForCurrentTurn(maxCharacters: 3_000)` at `:749`; called at `:654`, the
  window read at `:658`); `AgentSession.contextCharacters = 10_000` (`:891`) applied in
  `contextForCurrentTurn` as `min(Self.contextCharacters, …)` (`:1060`); the per-message
  `min(1_800, …)` in `contextForCurrentTurn` (`:1076`) and `chatHistoryForCurrentTurn`
  (`:1100`); `AgentSession.init` (`:945-…`) gains a `workingBudget` parameter;
  `compactIfNeeded()` (`:1031-1040`) passes it.
- `Agent/AgentSessionBoundary.swift` — `workingBudget = 10_000` (`:27`).
- `Agent/AgentSessionSelfTest.swift` — keep its fixture on an explicit 10,000 budget; add cases.
- `Agent/RealtimeAgentToolLoopSelfTest.swift` — call-site cases.

**Read for context (do not change):** `AgentAnswerBudget.readerContextTokens(for:)`
(`Agent/AgentAnswerBudget.swift`, P0-05: the loaded llama model's real window, else
`provider.contextTokens`); `Agent/VoiceConversationCoordinator.swift:731-732`
(`chatHistoryForCurrentTurn(maxCharacters: 1_400, …)`, the voice frontend: stays, P4-08);
`AgentSessionBoundary.compactionStart(_:current:budget:keptShare:)` (`:97-…`),
`summaryLimit = 1_500` (`:32`); `AgentSession.maxStoredCharacters = 12_000` (`:890`, per stored
message; unchanged); the P4-08 task in `05-PHASE-4-PROACTIVE.md` (its Target 1–2 are what this
task implements, with H1's thresholds and the ceiling fix).

**Current behaviour:**
| Site | Budget today | Symbol @ line |
|---|---|---|
| typed/voice first pass (voice test path after P1-02) | 2,500 | `runModelTurn` @ `ToolLoop:382` |
| planner | `contextTokens < 8_000 ? 2_500 : 6_000`, using `provider.contextTokens` (the 32,768 ceiling for llama, not the loaded window) | `runPlannedToolLoop` @ `ToolLoop:835-837` |
| `.localModel` | 3,000 | `conversationGroundedPrompt` @ `RealtimeAgent.swift:749` |
| voice frontend | 1,400 | `Coordinator:731-732` (not changed here) |
| per message | 1,800 | `RealtimeAgent.swift:1076`, `:1100` |
| session context ceiling | 10,000 | `AgentSession.contextCharacters` @ `:891`, applied `:1060` |
| compaction fold point | 10,000 | `AgentSessionBoundary.workingBudget` @ `AgentSessionBoundary.swift:27` |

**Target behaviour:**
- `AgentHistoryBudget.characters(contextTokens:)`: `< 8_000` → 2,500; `< 32_000` → 6,000;
  `< 128_000` → 12,000; otherwise 24,000. With the real windows: a 4,096 reader 2,500; Apple FM
  8,192 → 6,000 (after P1-10a; 2,500 before); a 32,768 local llama 12,000; OpenRouter
  262,144 → 24,000.
- Per-message cap `AgentHistoryBudget.perMessageCap(budget:) = min(6_000, budget * 2 / 5)`
  (1,000 / 2,400 / 4,800 / 6,000). A clipped message ends with
  `… (the rest is in the conversation)` (P4-08's marker).
- The three typed call sites (first pass, planner, `.localModel`) read the budget from
  `AgentAnswerBudget.readerContextTokens(for: provider)`, never `provider.contextTokens` and
  never a literal.
- No silent clip: `AgentSession.contextCharacters` becomes `AgentHistoryBudget.maximumCharacters`
  (24,000), and `AgentSessionBoundary.workingBudget` becomes 24,000, so the largest budget is
  reachable. The session self-test fixtures that measure compaction pass their own 10,000.
- The voice frontend stays at 1,400 (P4-08, H2 V20).

**Steps:**
1. New `Agent/AgentHistoryBudget.swift`:
   ```swift
   /// How much earlier conversation a reader is given, in characters. Scales with the
   /// reader's real window (H1 #9); the voice frontend keeps its own 1,400 (latency-bound).
   enum AgentHistoryBudget {
       static let maximumCharacters = 24_000
       static func characters(contextTokens: Int) -> Int {
           switch contextTokens {
           case ..<8_000: 2_500
           case ..<32_000: 6_000
           case ..<128_000: 12_000
           default: maximumCharacters
           }
       }
       static func perMessageCap(budget: Int) -> Int { min(6_000, budget * 2 / 5) }
       static let clippedSuffix = "… (the rest is in the conversation)"
   }
   ```
2. `AgentSession`: `private static let contextCharacters = AgentHistoryBudget.maximumCharacters`
   (`:891`). Give `contextForCurrentTurn(maxCharacters:)` (`:1057-1083`) and
   `chatHistoryForCurrentTurn(maxCharacters:…)` (`:1089-1111`) a new parameter
   `perMessageCharacters: Int = 1_800` and replace the literal in `min(1_800, …)` with it; append
   `clippedSuffix` when a message's text was cut (count the suffix inside the room). The default
   keeps today's 1,800 for every caller that does not pass it, **including the voice frontend**
   (`Coordinator:731-732`, 1,400 total), whose history P4-08 owns; `perMessageCap(budget: 1_400)`
   would be 560 and would silently shrink voice history. The three typed sites pass
   `perMessageCharacters: AgentHistoryBudget.perMessageCap(budget: budget)`.
3. `AgentSessionBoundary.workingBudget = AgentHistoryBudget.maximumCharacters` (`:27`). Add
   `workingBudget: Int = AgentSessionBoundary.workingBudget` to `AgentSession.init` (`:945`),
   store it, and pass it in `compactIfNeeded()` (`:1034`,
   `AgentSessionBoundary.compactionStart(messages[start...], current: current, budget: workingBudget)`).
4. First pass (`ToolLoop:382`): move `let window = await AgentAnswerBudget.readerContextTokens(for: provider)`
   (`:393`) above the history line and use
   `chatHistoryForCurrentTurn(maxCharacters: AgentHistoryBudget.characters(contextTokens: window))`.
   After P1-02 this site serves only the voice test path; keep it budgeted anyway.
5. Planner (`ToolLoop:835-837`): use the `window` P1-02 step 6 reads once per plan (if P1-02 has
   not landed, read it here) and
   `contextForCurrentTurn(maxCharacters: AgentHistoryBudget.characters(contextTokens: window))`.
6. `.localModel` (`RealtimeAgent.swift:654-658`): read `window` before building the prompt and
   pass `historyCharacters: AgentHistoryBudget.characters(contextTokens: window)` into
   `conversationGroundedPrompt(_:reader:historyCharacters:)`, replacing the literal 3,000.
7. Log once per turn: `history budget · window=<n> chars=<m>` (info), beside P0-05's
   `answer budget` line.
8. P1-10a's per-round fitter drops the "Earlier Agent conversation" section first when a prompt
   is over the window, so a larger history can never overflow a round.
9. Grep for callers: `grep -rn "AgentHistoryBudget" Sources/NextNotes` shows the three typed
   sites, `AgentSession` and `AgentSessionBoundary`; `grep -n "2_500\|3_000\|1_800" Sources/NextNotes/Agent/RealtimeAgent.swift Sources/NextNotes/Agent/RealtimeAgent+ToolLoop.swift`
   finds none of these history literals (other uses of those numbers, if any, are not history).

**Do not:**
- Do not grow the voice frontend's 1,400 on Apple FM (P4-08, latency-bound).
- Do not use `provider.contextTokens` for a llama reader; it is the 32,768 ceiling, not the
  loaded model's window (P0-05 note in `AgentAnswerBudget.readerContextTokens`).
- Do not raise `maxStoredCharacters` or `maxMessages`; storage is not the limit.
- Do not change `summaryLimit` or `keptShare`; compaction keeps its shape, only its fold point moves.
- Do not weaken `AgentSessionSelfTest`: its fixtures move to an explicit `workingBudget: 10_000`
  so every existing check keeps its meaning; new cases cover 24,000.
- Self-tests use `AgentSession` instances with temp files (the session test already does); never
  `AgentSession.shared` on disk (it has no file under the harness:
  `fileURL: SelfTest.isRunning ? nil : …`, `RealtimeAgent.swift:851-856`; do not add a path
  around that).

**Red-first self-test:**
- Extend `--selftest-memory` (`MemorySelfTest`, `Memory/MemorySelfTest.swift:414` calls
  `AgentSessionSelfTest.failures(root:)`; marker `MEMORY_OK` / `MEMORY_FAILED`; acceptance entry
  `selftest-memory|300`, INTEGRATION, unchanged). In `AgentSessionSelfTest.failures(root:)`:
  1. The existing `makeSession()` fixture (`AgentSessionSelfTest.swift:23`) gets `workingBudget: 10_000`; all existing checks unchanged
     (`"the prompt context is over its budget", context.count <= 10_000` stays true because the
     fixture passes `maxCharacters` nil → 24,000 now: change that one check to
     `context.count <= AgentHistoryBudget.maximumCharacters`).
  2. New: a 40-turn session of ~900 characters per turn with the default budget →
     `contextForCurrentTurn(maxCharacters: 24_000).count > 10_000` and `<= 24_000`.
     **Red today:** clipped to ≤ 10,000 by `:1060`.
  3. New: a single 9,000-character assistant message → in
     `chatHistoryForCurrentTurn(maxCharacters: 24_000, perMessageCharacters: AgentHistoryBudget.perMessageCap(budget: 24_000))`
     it is ≤ 6,000 characters and > 1,800, and ends with `AgentHistoryBudget.clippedSuffix`; with
     budget 2,500 it is ≤ 1,000; with no `perMessageCharacters` and `maxCharacters: 1_400` (the
     voice frontend's call) it is ≤ 1,400 and > 560 (voice unchanged). **Red today:** the new
     parameter does not exist (write the case against a temporary overload that ignores it, so
     the first assertion fails at 1,800 and no suffix).
  4. Pure table: `characters(contextTokens:)` for 4,096 / 8,192 / 32,768 / 262,144 =
     2,500 / 6,000 / 12,000 / 24,000; `perMessageCap` for those = 1,000 / 2,400 / 4,800 / 6,000.
- Extend `--selftest-toolloop-production` (`TOOLLOOP_PRODUCTION_OK` / `…_FAILED`): a scripted
  provider with `contextTokens` 262,144 and a session holding 20,000 characters of earlier
  turns → the planner's captured user message contains ≥ 15,000 characters of the
  "Earlier Agent conversation" section; with a scripted 4,096 reader → ≤ 2,500. The
  `.localModel` path (via `localModelProviderForTesting` with 262,144) receives > 3,000
  characters of conversation. **Red today:** 6,000 and 3,000 caps.
Confirm red on the unmodified code before step 1 (cases 2, 3 and the two tool-loop cases fail).

**Verify:**
```bash
make build
make install OPEN=0
Scripts/run-selftest.sh --selftest-memory
Scripts/run-selftest.sh --selftest-toolloop-production
Scripts/run-selftest.sh --selftest-voice-conversation
Scripts/run-selftest.sh --selftest-voice-grounding
Scripts/run-selftest.sh --selftest-toolloop-live --quick \
  --report "$PWD/Tests/Reports/toolloop-live/$(date +%F)-P1-18-quick.md"
Scripts/run-selftest.sh --selftest-toolloop-live --quick --model apple \
  --report "$PWD/Tests/Reports/toolloop-live/$(date +%F)-P1-18-apple-fm-quick.md"
```

**Success threshold:** `MEMORY_OK` with cases 1–4 (2, 3 red first); `TOOLLOOP_PRODUCTION_OK`
with the two new cases (red first); voice flags unchanged; `--quick` scores not lower than the
previous quick runs on the same models, and the Apple FM run has no case ending in a context
error (P1-10a's fitter absorbs the larger history).

**Risks & rollback:** Larger prompts cost prefill on local models (estimate: +1,000–2,500
tokens for a 32K llama reader at 12,000 characters); P0-18's prefix reuse offsets it. A later
compaction fold (24,000 instead of 10,000) means a small reader sees fewer summarised turns and
more unsummarised gap between its 2,500-character tail and the fold point; that gap already
exists today (2,500 vs 10,000) and P4-08's work does not depend on it. If a small-window
regression shows in the eval, pass the Agent role's budget as `workingBudget` instead of the
maximum. Rollback: set `AgentHistoryBudget.characters` to return today's values
(2,500 / 6,000 / 6,000 / 6,000) and `maximumCharacters` to 10,000.

**Done when:**
- [ ] `MEMORY_OK` and `TOOLLOOP_PRODUCTION_OK` with the new cases (red first).
- [ ] `AgentHistoryBudget` has callers at all three typed sites, `AgentSession` and `AgentSessionBoundary`.
- [ ] No history literal 2,500 / 3,000 / 6,000 / 1,800 / 10,000 remains in the typed paths.
- [ ] STATUS.md notes that P4-08 steps 1–2 are done here.

---

### P1-19 — A leftover approval cannot fire against a different account or a time that has passed

**Finding(s):** OpenMuse comparison, 2026-09-27 (`REVIEW-LOG.md` §7, item O1). **Effort:** 1.5 days. **Depends on:** none (soft: P1-16, which keeps the card on screen). **Feeds (soft):** P3-08 (a spoken approval should ask the same freshness question before it fires), P6-06 (a recovered task's re-prepare should use the same check). Neither lists it as a hard dependency.

**Why (what the user experiences today):** A meeting proposal outlives the process on purpose —
AGENTS.md "A proposal outlives the process": the notes land minutes after a meeting and are read the
next morning. What was never added is a check that the world still matches the card when it is
finally approved. `AgentService.decide(proposalID:approved:)` (`Agent/AgentService.swift:423`) finds
the proposal by scanning every meeting folder, sends only `.send`-and-above into the window, and
calls `approve(_:)` (`:309`) straight from the notification banner for everything below. `approve`
hands the stored arguments to `AgentToolExecutor.run(_, approvedByUser: true)` and nothing else.
So a banner left over from last week, pressed today, runs as-is:

- **The Google account can have changed.** `gws auth status` reports which credential stores exist
  and nothing about which account (`GoogleWorkspaceCLI.AuthStatus`, `:262-289`), and
  `AgentProposal` (`Agent/AgentModels.swift:115`) records none. A user who switched accounts in the
  Workspace tab gets the follow-up email sent from, or the event created in, the other one.
- **The time can have passed.** "Book 30 minutes with Ana on Thursday at 3" approved on Friday
  creates an event in the past, and `gws ... --dry-run` does not catch it (AGENTS.md
  "`gws ... --dry-run` validates locally").
- **The age is invisible.** `createdAt` exists and nothing reads it; a banner does not say which
  meeting or which day it came from.

OpenMuse (`apps/server/src/actions.ts`) binds each stored review to a SHA-256 over the action and
the target's version, a 30-minute expiry, and the connected account, and voids pending work when the
account changes. **Take the binding, not the 30 minutes.** A short expiry would delete exactly the
morning-after approvals AGENTS.md says this feature exists for.

**Files you will change:**
- `Agent/AgentModels.swift` — `AgentProposal` (`:115`): two optional fields, `accountTag: String?`
  and `startsAt: Date?` (parsed once from the tool's time argument when there is one). Optional, so
  a proposal file written by an older build still decodes (AGENTS.md "Adding a property to `Meeting`
  without `decodeIfPresent` orphans every meeting on disk" is the same trap in a different file).
- `Agent/ApprovalFreshness.swift` (new, pure) — `evaluate(_ proposal:, now:, currentAccountTag:) ->
  Freshness` with `.fresh`, `.aged(days: Int)`, `.accountChanged`, `.timeHasPassed`.
- `Agent/AgentService.swift` — `approve(_:)` (`:309`) asks `ApprovalFreshness` before
  `AgentToolExecutor.run`; `decide(proposalID:approved:)` (`:423`) routes `.aged` to the window the
  way it already routes `.send`.
- `Agent/GoogleWorkspaceCLI.swift` — one read that returns the signed-in address, cached until the
  auth state changes. **Verify the command before writing it**: Gmail's profile read
  (`gws gmail users getProfile`, `userId: me`) is the expected source; check it against
  `gws gmail users --help` and record the exact command and one redacted output shape in
  `STATUS.md`. Store only `accountTag` — the first 16 hex characters of SHA-256 over the lowercased
  address — never the address.
- `UI/Meetings/MeetingActionsView.swift` (`:126`, `:158`) and
  `UI/Meetings/MeetingConsoleActionsSection.swift` (`:239`, `:258`) — the card shows the one plain
  sentence for a refusal; both already call `agent.approve(proposal)`, so the check itself lives in
  `approve` and neither view decides anything.
- `Agent/Permissions/ToolCallReviewSelfTest.swift` — cases below.

**Target behaviour:**
1. At proposal time, `accountTag` is the current tag (nil when it cannot be read — then the account
   check is skipped for that proposal, with a comment naming the gap; never invent a tag).
2. At approve time, in this order:
   - `.accountChanged` → nothing runs. "This was prepared for a different Google account, so
     nothing was sent." The card keeps Dismiss; the proposal is not deleted.
   - `.timeHasPassed` → nothing runs. "That time has already passed." The Actions tab's existing
     argument editor is the way to fix it; there is no new control.
   - `.aged(days)` with `days >= ApprovalFreshness.bannerAgeLimit` (start value 3; §12) → a banner
     press opens the card in the window instead of firing, exactly like `.send` today. This moves the
     one approval from a blind banner to the card that shows what will happen; it is **not** a second
     confirmation, and a press on the card itself fires as it does now.
   - `.fresh` → today's path, unchanged.
3. The card and the banner name their origin: "From Tuesday's design review". Plain words; passes
   `--selftest-ui-strings`.
4. Nothing expires a proposal and nothing deletes one. Freshness is decided at the moment of
   approval, never by a timer.

**Do not:**
- Do not add an expiry that removes proposals, and do not add a confirmation dialog.
- Do not store the email address anywhere, including `usage.jsonl` (`UsageLog.sanitise` would strip
  it, but it must never be handed one).
- Do not add target versioning in this task. The catalogue (`Agent/WorkspaceTools.swift`, checked
  2026-09-27) has no update-by-id calendar tool; `create_event` (`:201`) creates, and the one write
  to an existing target is `append_doc` (`:171`), where a deleted document fails loudly at `gws`.
  The day an update-by-id or delete tool joins the catalogue, it needs OpenMuse's `targetVersion`
  idea (record the etag at proposal time, compare before firing) — file it then as its own task.

**Red-first self-test:** extend `--selftest-tool-review` (marker unchanged). Seed proposals through
the existing isolated path; inject `now` and the current tag.
- A: tag matches, `createdAt` 1 h ago, no time → `.fresh`, the fake executor ran once.
- B: tag differs → `.accountChanged`, the executor ran **zero** times, the proposal still on disk.
- C: `startsAt` yesterday → `.timeHasPassed`, zero runs.
- D: 5 days old, banner press (`decide(approved: true)`) → routed to the window, zero runs; the same
  proposal approved from the card → one run.
- E: an old proposal JSON with neither field decodes and is treated as `.fresh` apart from age.
- F: the refusal sentences contain no tool id, schema key or the word "account tag".

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-tool-review
Scripts/run-selftest.sh --selftest-guided
Scripts/run-selftest.sh --selftest-ui-strings
Scripts/run-selftest.sh --selftest-store-isolation
make acceptance TIER=core
```

**Success threshold:** A–F red first, then green; `--selftest-guided` unchanged (its fresh proposal
still executes); no new CORE FAIL.

**Risks & rollback:** Risk: the profile read is slow or fails offline — it runs once per sign-in and
is cached, and a nil tag degrades to today's behaviour. Risk: `startsAt` parsing reads the wrong
argument — it reuses `WorkspaceToolRunner.rfc3339`'s input, never a new parser. Rollback:
`ApprovalFreshness.evaluate` returns `.fresh`.

**Done when:**
- [ ] `AgentProposal` carries `accountTag` and `startsAt`, both optional; old files decode (case E).
- [ ] `approve(_:)` is the only place the check runs; the four views are unchanged apart from copy.
- [ ] The profile command, its measured duration and the tag rule recorded in `STATUS.md`.
- [ ] `bannerAgeLimit` registered in 00-README §12 with the reason it is a start value.

---

### P1-20 — One Send/Stop control, a draft that survives, and no silent interrupt

**Finding(s):** OpenMuse comparison, 2026-09-27 (`REVIEW-LOG.md` §7, item O2). **Effort:** 0.5 day. **Depends on:** none. **Unblocks:** P3-11.

**Why (what the user experiences today):** `AgentView.composer` (`UI/Agent/AgentView.swift:549-575`)
adds a Stop button beside Send while `agent.isThinking`, so the row changes width at the start and
end of every turn. `send()` (`:578-587`) calls `RealtimeAgent.shared.interrupt()` whenever a turn is
running: **a typed follow-up silently cancels the work in flight** and nothing on screen says it
did. That is the typed-path version of what AGENTS.md forbids for voice — "Do not turn every
acknowledgment into a cancellation." `draft` is `@State` (`:17`), so it lives only as long as the
view; confirm in step 1 whether leaving the Agent section and coming back loses it.

OpenMuse's composer is the reference here (`docs/EXPERIENCE.md`): the send arrow becomes a stop
square **in the same place**, stopping keeps the draft, and nothing typed is lost.

**Files you will change:**
- `UI/Agent/AgentView.swift` — `composer` and `send()`; the draft's storage.
- `UI/Agent/ComposerControl.swift` (new, pure) — `state(draftIsEmpty:isThinking:) -> .send(enabled:)
  | .stop`.
- the `--selftest-agent-panes` runner (`NextNotesApp.swift:846` registers it) — cases below.

**Target behaviour:**
1. One trailing control. Empty draft while thinking → Stop. Anything typed → Send, thinking or not.
   Same position and size in every state; the size is a `DS` token.
2. Stop never touches the draft. Send clears it only once the text has been handed over.
3. The draft survives leaving the section: `@SceneStorage("agentDraft")` — no new store, no new type.
4. Sending while a turn runs keeps today's interrupt (the real semantics are P3-11), but the pane
   shows one plain notice row above the new message: "Stopped the earlier request to answer this."
   It is a **view row, not a conversation entry**: it never reaches the model's history, the
   knowledge index or `usage.jsonl`.

**Red-first self-test:** extend `--selftest-agent-panes` (marker unchanged): the four
`ComposerControl` states; the notice row is produced by an interrupting send and not by a send into
an idle agent; the notice text passes the UI-strings scan.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-agent-panes
Scripts/run-selftest.sh --selftest-ui-strings
```

**Done when:**
- [ ] One control, no layout shift, a `DS` token for its size.
- [ ] The draft survives a section switch (step-1 finding and the fix recorded in `STATUS.md`).
- [ ] An interrupting send is visible; the notice never enters history.

---

### P1-21 — A write whose result never came back is "not sure", never "failed"

**Finding(s):** OpenMuse comparison, 2026-09-27 (`REVIEW-LOG.md` §7, O4; found live in §8). **Effort:** 1.5 days. **Depends on:** none. **Feeds (soft):** P6-06 step 6, which reuses this state and this read-back for recovery after a restart; P6-08's "Needs you" group.

**Why (what the user experiences today):** `ActionOrchestrator.execute`
(`Agent/ActionRuntime.swift:396`) records `.fired` (`:520`), awaits `fire(prepared)` (`:523`), and
on any thrown error records **`.failed`** (`:550-561`). For a Google write, `fire` is `gws`, run with
a 60 s timeout (`GoogleWorkspaceCLI.defaultTimeout`, `:162`) and terminated when it expires
(`:431`, `:486`). So when an email send takes longer than 60 s, or `gws` exits after the request
left but prints something unreadable (`WorkspaceCLIError.badOutput`, `:84`), the receipt says the
send failed, the card says it failed, and the person presses it again. **That is how the app sends
the same email twice**, and it is live today — not a recovery-after-restart case, which is P6-06's.

OpenMuse (`packages/integrations/src/google.ts:19-26`, `:576-605`) marks a write
`outcome_unknown` on a network error, a 5xx or 408, or an unreadable reply, and never retries it
silently. Take that rule, and add what OpenMuse does not do: **ask Google before asking the person.**

**Files you will change:**
- `Agent/ActionRuntime.swift` — `ActionReceiptStatus` (`:255`) gains `outcomeUnknown`; the catch
  arms at `:550-561` record it instead of `.failed` when the error says so (below).
  **Fix the store's decode first, in the same commit.** `ActionReceiptStore.load()` (`:371-375`) is
  `(try? decoder.decode([ActionReceipt].self, from: data)) ?? []`: one receipt that fails to decode
  empties the whole list, and the next `record` (`:341`) → `save()` (`:357`) then **overwrites the
  file with nothing**. A new enum case is exactly that failure for any build that does not know
  it, including a downgrade. Two changes: `ActionReceiptStatus` gets a hand-written `init(from:)`
  that maps an unknown raw value to `.couldNotVerify`; `load()` decodes element by element and
  keeps the ones that decode, logging a count of the rest. The audit trail is the one store that
  must never be silently emptied.
- `Agent/GoogleWorkspaceCLI.swift` — `WorkspaceCLIError` (`:77`) gains `var outcomeIsKnown: Bool`.
- `Agent/WorkspaceToolRunner.swift` — one `resolveUnknown(tool:arguments:firedAt:cli:)` per write
  tool: a **read** that answers "did it happen?".
- `Agent/AgentService.swift` — `approve(_:)` (`:309-339`) shows the plain "not sure" sentence
  rather than the failure one, and offers "Check again" (another read, never a write).
- `Agent/Permissions/ToolCallReviewSelfTest.swift` (`--selftest-tool-review`) and
  `--selftest-gws`'s fixture half — cases below.

**The rule — which errors after `.fired` leave the outcome unknown.** For a tool whose risk is
`.write` or above, only four errors prove nothing left the Mac: `.notInstalled`, `.notAuthenticated`
(exit 2), `.invalidRequest` (exit 3, local validation) and `.launchFailed`. **Every other error
after launch is unknown**: `.timedOut`, `.badOutput`, and `.apiFailed` (exit 1), because exit 1
covers a server error as well as a refusal. A read never enters this state; its failure is a
failure. That is deliberately conservative, and it is the same shape as OpenMuse's.

**Resolving it — a read first, then the person:**

| Tool | Read that answers | Found | Not found |
|---|---|---|---|
| `send_email` / `reply_email` | Sent, recipient + subject, after `firedAt` (exact once P1-22 lands) | `completed`, "It went out." | ask |
| `draft_email` | drafts, same match | `completed` | ask |
| `create_event` | `events list` on the primary calendar around `start`, matching the title | `completed` | ask |
| `create_doc` | Drive search by exact name, created after `firedAt` | `completed` | ask |
| `append_doc`, `upload_to_drive` | no reliable read | — | ask |

"Ask" is one sentence and no automatic action: "I'm not sure the email to Ana went out. It isn't in
your Sent folder yet." with **Check again** (the read) and **Send again** (a **new** approval of the
same prepared content, never a silent retry). A match found by the fuzzy rule is described as
"looks like it went out", never as certain, until P1-22's exact identifier exists.

**Do not:**
- Do not retry a write automatically, ever, for any error.
- Do not treat a slow `gws` as a reason to raise `defaultTimeout`; the timeout stays, and what
  changes is what the app claims when it fires.
- Do not put the recipient, subject or body in `usage.jsonl` or in the receipt's `detail` text.

**Red-first self-test:** extend `--selftest-tool-review` (marker unchanged), with a fake CLI:
- A: `send_email`, the fake times out → receipt `outcomeUnknown` (red today: `failed`); the fake's
  send counter is 1.
- B: then the Sent read finds it → `completed`, sentence "It went out.", send counter still 1.
- C: the read finds nothing → a card with Check again / Send again; send counter still 1; pressing
  Send again raises an approval, and only its approval sends.
- D: `.invalidRequest` after `.fired` → `failed` (the outcome is known).
- G: a receipts file holding one record with an unknown status value and two good ones → `load()` keeps the two, and the next `record` writes three (red today: it writes one).
- E: a read tool that times out → `failed`, never `outcomeUnknown`.
- F: every sentence passes the UI-strings scan.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-tool-review
Scripts/run-selftest.sh --selftest-gws
Scripts/run-selftest.sh --selftest-guided
Scripts/run-selftest.sh --selftest-ui-strings
make acceptance TIER=core
```

**Done when:**
- [ ] A–G red first, then green; `--selftest-guided` unchanged.
- [ ] The store never empties itself on one bad record (case G); the old behaviour is written up in `STATUS.md` as fixed.
- [ ] AGENTS.md gets one paragraph: "A write that did not answer is 'not sure', never 'failed'".

---

### P1-22 — Every Google write carries an identifier derived from its receipt

**Finding(s):** OpenMuse comparison, 2026-09-27 (`REVIEW-LOG.md` §8). **Effort:** 2 days, of which the first half is measurement. **Depends on:** P1-21.

**Why:** P1-21 can only *guess* whether a send happened (recipient + subject + time). Google offers
two exact answers, and OpenMuse uses neither:
- **Calendar** accepts a client-chosen event `id` (base32hex, 5–1024 characters; a UUID's lowercase
  hex digits qualify). Inserting the same id twice is refused, so a repeated create is a **no-op
  instead of a duplicate** — real idempotency, not a check.
- **Gmail** searches `rfc822msgid:<Message-ID>`. A send whose raw message carries a
  `Message-ID` built from the receipt id can be found exactly.

Today `create_event` goes through the `calendar +insert` helper
(`Agent/WorkspaceToolRunner.swift:697`) and `send_email`/`draft_email` through `gmail +send`
(`:737`); neither takes an id or a header. The raw resource methods do exist in `gws` — the runner
already calls `calendar events get` (`:712`) and `docs documents create --json` (`:562`).

**Step 1 is measurement, and it can end the task.** Before changing a call:
1. `gws calendar events insert --help` — confirm `--params` / `--json` accept `calendarId` and a
   body with `id`, `summary`, `start`, `end`, `attendees`, `description`.
2. Insert one event with a fixed id into a throwaway calendar, twice. Record the second call's exit
   code and message. **If Google does not refuse the duplicate, stop and record it.**
3. `gws gmail users messages send --help` — confirm a raw RFC 2822 body. Send one message to the
   signed-in address with `Message-ID: <receipt-uuid@nextnotes.local>`; read it back with
   `rfc822msgid:`. **If Gmail rewrote the header, the Gmail half is won't-do (evidence)** and P1-21's
   fuzzy match stays.
Record each command, exit code and the redacted output shape in `STATUS.md`.

**Target behaviour (only for the halves step 1 proved):**
- `create_event` → raw insert with `id` = the receipt id's hex. A duplicate refusal is `completed`
  ("It was already on your calendar."), never an error.
- `send_email` / `draft_email` / `reply_email` → raw send with the derived `Message-ID`; P1-21's read
  becomes `rfc822msgid:` and its "looks like" wording becomes certain.
- `reply_email` keeps its threading headers (`In-Reply-To`, `References`); check them in the
  fixture.
- Every rewritten call is matched by a fixture in `--selftest-gws`, in the JSON shape `gws`
  actually printed during step 1 (AGENTS.md: the fixtures are real shapes, not guesses).

**Do not:** do not change `create_doc` here (Drive's `appProperties` could tag it, but no loss has
been observed); do not keep both the helper and the raw path — one call per tool.

**Verify:** `--selftest-gws` (fixtures), `--selftest-tool-review`, then `--selftest-gws --live-mail`
once by hand (counts only, as today).

**Done when:** the step-1 measurements are in `STATUS.md`; each proven half is switched with its
fixture; a repeated `create_event` produces one event in the fixture and in the one live check.

---

### P1-23 — The person's hand always wins: computer control yields the moment they touch the Mac

**Finding(s):** OpenMuse comparison, 2026-09-27 (`REVIEW-LOG.md` §8, "browser takeover"). **Effort:** 2 days. **Depends on:** none (soft: P1-16, whose badge shows the paused state). **Feeds (soft):** P6-08's "Needs you" group.

**Why (what the user experiences today):** OpenMuse's agent drives a sandboxed browser, and "Take
control" opens that session once the agent's run finishes. Ours drives **the person's own Mac**:
`AccessibilitySnapshot` posts real mouse and key events (`Computer/AccessibilitySnapshot.swift:139-140`,
`:286`, `:303`) and the CDP client drives their real Chrome. So "taking over" needs no second
browser — but **nothing notices when the person grabs the mouse or starts typing while the agent is
clicking.** The only reader of the input clock is the scheduler's idle check
(`Agent/Schedules/AgentScheduler.swift:1271`), and `Computer/` has no yield logic. Both hands then
drive one pointer: a click lands where the person just moved it, or keystrokes interleave with
theirs. A person should never have to wait for the agent to finish before they can use their own
computer — that is the opposite of OpenMuse's rule, and it is ours.

**Files you will change:**
- `Computer/HumanInputWatch.swift` (new) — a **listen-only** `CGEventTap` that is active only while
  a computer or browser action runs. The Accessibility grant computer control already needs covers
  it. Every event this app posts is tagged with `eventSourceUserData`, set to one constant, on
  the `CGEventSource` it is posted from. An untagged mouse-down, key-down or scroll is the person.
- `Computer/AccessibilitySnapshot.swift` — tag the events it posts (the four sites above). `Core/TextInjector.swift`
  (`:397-422`) is dictation, not computer control; leave it untouched.
- `Computer/ComputerToolExecutor.swift` (`run`, `:12`) and `Computer/BrowserToolExecutor.swift` —
  check the watch before each posted step and between the steps of one action.
- `Agent/RealtimeAgent+ToolLoop.swift` — a yielded step ends the round as `needsInput`, with a
  resume that re-snapshots rather than re-using the stale tree.
- `UI/Island/IslandState.swift` — the paused state uses the existing `waiting` avatar and the
  P1-16 badge; no new colour, never `DS.Color.record`.

**Target behaviour:**
1. The person's first untagged input during an action stops the agent **before its next posted
   event**. Target: < 100 ms from their input to the agent's last event, measured in the self-test.
2. One sentence, and no further steps: "Paused — you're using the Mac. Say 'carry on' or press
   Carry on when you're done."
3. **Carry on** (button, or the words through the existing pending-action path) takes a fresh
   snapshot and re-plans the remaining step. It never replays coordinates from before the pause.
4. Sign-in pages, CAPTCHAs and payment forms are never attempted. When the snapshot shows one, the
   agent stops with the same paused state and says what it needs: "This page wants you to sign in.
   I'll carry on after." **`Computer/` has no such check today** (grepped 2026-09-27). The
   nearest rule is `Context/ContextPrivacyFilter.swift`, which drops password managers and
   payment apps from the dictation harvest. Reuse its bundle list, and add the one signal the
   snapshot already carries: a focused or targeted element whose role is a secure text field
   (`AXSecureTextField`), or an `input[type=password]` in a CDP snapshot. Never a model call;
   never a guess from page text.
5. Browser actions over CDP do not move the OS pointer, but the person typing into **the same tab**
   is the same conflict: a key-down while that tab is focused pauses it too.

**Measure first:** before relying on the tag, confirm on this Mac that `eventSourceUserData` survives
`post(tap: .cghidEventTap)` and reads back in a listen-only tap. Record the result in `STATUS.md`.
If it does not survive, fall back to a timestamp window around each posted event, and say so in the
file header.

**Red-first self-test:** new `--selftest-computer-yield`. It needs the Accessibility grant, so it
is `via-open` and EXPERIMENTAL, like `--selftest-computer-actions`. In its own harness window:
- Y1: the agent scrolls in ten steps, and one synthetic untagged mouse-down arrives after step 3 →
  at most one more agent event, the state is `paused`, and the latency is printed.
- Y2: tagged events alone never pause.
- Y3: Carry on → a new snapshot is taken (its id differs) before the next event.
- Y4: a harness page with a password field (`AXSecureTextField`) → paused before any key is posted into it.
- Y5: a `type` step aimed at a secure field from the tool loop → refused with the sign-in sentence, zero key events posted.
- A grant-free half pins the tag constant, the pause sentence and the state mapping without
  posting anything, and runs in INTEGRATION.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --via-open --selftest-computer-yield
Scripts/run-selftest.sh --selftest-computer-actions
Scripts/run-selftest.sh --selftest-click-coordinate
Scripts/run-selftest.sh --selftest-ui-strings
```
Like `--selftest-computer-actions`, this is **red on a locked screen**. Record that as the
environment answer, not as a pass.

**Done when:**
- [ ] Y1–Y5 green on an unlocked screen, with the measured yield latency in `STATUS.md`.
- [ ] Every event computer control posts is tagged; dictation's injector is untouched.
- [ ] AGENTS.md gets one paragraph, "The person's hand always wins", and the flag list gets one line.

---

### P1-24 — An answer about your mail, calendar or Drive comes from reading them, and a short offer is an offer

**Finding(s):** live log audit `roadmap/done/agent-analysis-2026-09-23/J-live-log-audit-2026-09-27.md` L1, L2, L3, L5. **Effort:** 2 days. **Depends on:** P1-11, P1-07 (both done). **Feeds:** P1-27 (O01–O04 are this task's gate).

**Why (what the user experiences today):**
- **It invents mail.** On 27 Sep the Agent listed three emails, with senders and subjects, that no
  read produced: no tool row, no `toolsProposed` and no `search_email` receipt. Asked "Is this
  coming from my emails?", it said "I pulled the latest messages directly from your inbox."
  Summarising email has succeeded 0 times in about 11 attempts.
- **P1-11's guard cannot see this, by design.** `ToolClaimGuard.claimPhrases`
  (`Agent/ToolClaimGuard.swift:40-46`) lists first-person verbs — "i ran", "i searched",
  "i checked", "i read your" — and two shapes (`:54-63`). "I pulled …" is not in it, and a list of
  invented emails that makes no claim at all is invisible to any claim grammar.
- **Its offers go unrecognised.** "Want to see the latest messages?" (3× on 27 Sep) is not in
  `PendingAction.offerPhrases` (`Agent/PendingAction.swift:51-52`, which has "want me to" but not
  "want to"). So no pending action is set, and "go for it" had nothing to carry.

**Read this before designing anything: the obvious fix was built and removed.** The comment at
`Agent/RealtimeAgent+ToolLoop.swift:1920-1946` records a class-based "answered as though
something was looked up" check that detected every case and was a **net loss**, for three
measured reasons:
1. Re-planning with a note did not change the answer: the model answers prose again.
2. It replaced two **correct** answers (K01 after `meeting.decisions`, A04 after
   `computer.active_app`) with "I haven't checked that yet".
3. Its note turned a round that was about to call `draft_email` into a round that wrote the draft
   out as text.

This task is designed against those three results, and its self-test re-runs all three.

**Target behaviour:**
1. **Narrow trigger, high precision.** The check runs only when all four hold:
   - the turn's `manifest.selectedIntents` (`Agent/AgentCapabilityManifest.swift:105`) contains
     `.mail`, `.calendar` or `.drive` — the person's own accounts, never `.meetings`, `.screen`
     or `.knowledge`, where result 2 happened;
   - **no** tool of that class completed in this turn or earlier in this session, from the
     runner's `completedToolIDs` and the session's tool rows;
   - the reply is **final** — the round parsed no call, so result 3 cannot recur;
   - and the reply presents that source: it names it as the person's ("your inbox", "your
     emails", "your calendar", "your Drive") in a sentence that is not a question, **or** it has
     two or more list items shaped like messages or events (a sender-and-subject line, or a
     time range).
2. **The app reads; the model is not asked to.** Instead of a re-plan note (result 1), the loop
   runs that class's default read itself, through `ToolStepRunner` — the one caller of
   `AgentToolExecutor.run` (`Agent/Planner/ToolStepRunner.swift:258`):
   - mail → `search_email` with P1-09's default query;
   - calendar → `get_agenda` for the date the request names, else today (P4-01's block supplies
     "today");
   - Drive → `find_drive_files` with the request's nouns.

   Then P1-06's always-affordable final round answers from the real result. It is a read, so it
   runs only where reads run by themselves today (`agentAutoRunReadTools`). Where they do not,
   the reply is the honest one: "I haven't looked at your email yet." It is phrased as a
   statement, and a pending action is set, so "yes" runs the read.
3. **"Is this from my emails?" is answered from the record, not by the model.** When no mail read
   ran in the session, a provenance question about the last answer ("is this from", "did you
   actually", "where did you get") is answered "No — I hadn't read your email. Here's what's
   actually there:", followed by rule 2's read. The questions are matched by exact signatures,
   as AGENTS.md requires for a gate that removes a model answer.
4. **Short offers are offers.** `PendingAction.offerPhrases` gains the forms the log shows —
   "want to see", "want to hear", "would you like to see", "should i show you" — and the refusal
   guard reads the same list, so there is still one list (P1-07).
5. **The live eval's verdicts are unchanged.** Widening `FABRICATED` is the thing the comment
   above says a verdict bar may not do, so no verdict class is redefined. P1-27 adds the owner's
   real turns as their own set.

**Do not:**
- Do not re-plan with a note. That is result 1.
- Do not fire for `.meetings`, `.knowledge`, `.screen` or `.memory`. That is result 2.
- Do not fire on a round that parsed a call. That is result 3.
- Do not auto-run anything that is not a read.

**Red-first self-test:** extend `--selftest-toolloop-production` (marker unchanged), with a
scripted provider:
- G1: a tool-less final reply listing two fake emails, for "summarise my emails" → the fake
  `search_email` ran once, and the final reply cites the **fixture** senders, not the invented ones.
  Red today.
- G2: the same with reads not auto-allowed → "I haven't looked at your email yet." and a pending
  action; then "go for it" → the read runs.
- G3: "Is this coming from my emails?" after G1's invented answer, with no read → the provenance
  sentence plus a read.
- G4: **K01 regression** — after `meeting.decisions` ran, a reply about decisions is untouched.
- G5: **A04 regression** — after `computer.active_app`, untouched.
- G6: **M04 regression** — a round that parses `draft_email` is untouched, and the draft is
  proposed, not written out.
- G7: "Want to see the latest messages?" as the last sentence → a pending action is set.
- G8: a reply that says "your calendar is a good place to keep that" (advice, not content) → untouched.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-toolloop-production
Scripts/run-selftest.sh --selftest-voice-turn-routing
Scripts/run-selftest.sh --selftest-toolloop-live --quick
```

**Done when:** G1–G8 green (G1–G3 and G7 red first); `--quick` not below its last recorded score;
P1-27's O01–O04 pass. AGENTS.md's P1-11 paragraph gains one sentence: an answer about the person's
accounts needs a read of that account in the same session.

---

### P1-25 — An id in an action comes from something read or said, never from the model

**Finding(s):** J L13, L22. **Effort:** 1 day. **Depends on:** none (soft: P1-19, the card it protects). **Feeds:** P1-27 O08.

**Why:** On 20 Sep an `append_doc` was proposed with the document id "You open Google Chrome" — a
fragment of the person's sentence. It was **approved** about 8 s later, and Google then rejected it.
That is the only Workspace write ever approved on this Mac. The meeting side already refuses this
class of mistake: `FunctionCallGrounding.groundedArguments`
(`Agent/FunctionCalling/FunctionCallGrounding.swift:98`) keeps only the values a source supports,
and `MeetingAgent` rejects ungrounded proposals (`Agent/MeetingAgent.swift:454`, `:505`). The tool
loop has a second `groundedArguments` (`Agent/AgentToolLoop.swift:121`). Neither checks an **id**
parameter against what the turn actually read.

**Target behaviour:**
1. An id-kind parameter — `document_id` (`Agent/WorkspaceTools.swift:146`, `:175`), a message id
   or number (`:104`), a file id, a calendar event id — is valid only if its value appeared
   **verbatim** in a tool result earlier in this session, or in the person's own words.
2. Otherwise the call is refused **before** any approval card, and the planner gets one plain
   result: "That document hasn't been found yet — search for it first." That is a tool result,
   which is what the model reads; it is not a re-plan note in prose. A card never shows an
   ungrounded id.
3. Mark the parameter kind in the catalogue: `WorkspaceTool.Parameter.Kind`
   (`Agent/WorkspaceTools.swift:37`, today `.multiline`, `.list`, …) gains `.identifier`. Never guess it from the name. One mark per parameter, next to its description.
4. Reuse `FunctionCallGrounding`'s matching (verbatim, word-bounded). Do not write a third matcher.

**Red-first self-test:** extend `--selftest-toolloop-production`:
- I1: `append_doc` with `document_id` "You open Google Chrome" → refused, no `PermissionGate`
  request, the refusal result in the next round.
- I2: after `find_drive_files` returned id `1AbC…` → `append_doc` with that id reaches the card.
- I3: an id the person typed ("append to doc 1XyZ…") → allowed.
- I4: `read_email` with message "2" after a search that numbered its results → allowed (the
  number is in the result).

**Done when:** I1–I4 green, I1 red first; every id-kind parameter in `WorkspaceTools` is marked.

---

### P1-26 — "Clear conversation" starts a new one; it does not erase every past conversation

**Finding(s):** J L20, L21. Root cause traced 2026-09-27; it is not what the audit first guessed.
**Effort:** 1 day. **Depends on:** none. **Owner decision recorded here:** the button's meaning
changes (see Target 1). If the owner wants "Clear" to keep deleting past conversations, only
Target 1 is dropped, and the confirmation in Target 2 becomes mandatory instead.

**Why (what the user experiences today):** The Agent "doesn't remember past conversations" and
knowledge search finds none of them. Conversations **were** being indexed: deleted chunks for about
21 sessions, the last from 27 Sep 06:54Z, are still in `knowledge.sqlite-wal`'s free pages.
**Clear conversation deleted them all**:
- The button (`UI/Agent/AgentView.swift:173-176`) has **no confirmation**.
- It calls `AgentSession.clear()` (`Agent/RealtimeAgent.swift:1214-1219`), which deletes
  `agent-conversation.json` and fires `onConversationCleared`.
- That hook calls `KnowledgeIndexer.removeConversations()` (`Knowledge/KnowledgeIndexer.swift:313`,
  `:386-399`) → `deleteSources(kind: .conversation)` (`Knowledge/KnowledgeStore.swift:415-420`),
  which removes **every** conversation ever indexed, not the current one.

The design comment says so (`KnowledgeIndexer.swift:498-500`), and `--selftest-index` pins it as
correct (`Knowledge/KnowledgeIndexSelfTest.swift:195-196`). But nothing a person sees says so: a
trash icon labelled "Clear conversation" reads as "tidy this chat", not "forget everything I ever
said to you". It was last pressed at 07:39Z on 27 Sep, which is why the audit found zero.

Two smaller truths found on the way:
- The comment "`agent-conversation.json` keeps every row" (`Agent/AgentSessionBoundary.swift:14`)
  is false. The file is capped at 120 rows on load and on write (`RealtimeAgent.swift:931`,
  `:1244-1246`), and `clear()` deletes it.
- The "0 hits" knowledge searches (L21) are most likely the Knowledge screen recording a search
  for an **empty query** on open (`UI/Knowledge/KnowledgeSearchView.swift:363`;
  `Knowledge/KnowledgeSearch.swift:152-153` returns nothing for it). The query is not logged, so
  this is inferred; P1-29 records empty queries separately.

**Target behaviour:**
1. **The button starts a new conversation.** It is relabelled "New conversation" and given a
   plain icon, not the trash can. The current session ends the way an idle one does
   (`endSession` with a normal reason, `RealtimeAgent.swift:988-995`), so it **is** indexed and
   reviewed, and the pane shows an empty chat. Nothing is deleted.
2. **Deleting stays possible and says what it does.** "Forget all conversations" lives where the
   knowledge settings already offer "Forget everything", with one confirmation that names the
   consequence in plain words: "This removes every past conversation from search. It can't be
   undone." This is an irreversible action, so one confirmation is the one AGENTS.md allows.
3. `clear()` keeps its name for the deleting path, and `onConversationCleared` fires **only**
   there.
4. Fix the comment at `AgentSessionBoundary.swift:14` to state the 120-row cap and that the index
   is the long record.

**Red-first self-test:**
- In `--selftest-index`: **invert** `KnowledgeIndexSelfTest.swift:195-196`. After "New
  conversation", the previous session's chunks are **present** and searchable. After "Forget all
  conversations", they are gone.
- In the Agent session self-test (`Agent/AgentSessionSelfTest.swift`): "New conversation" ends
  the session with an indexing reason, and the file still holds the earlier rows up to the cap.
- `--selftest-ui-strings`: the new labels and the confirmation.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-index
Scripts/run-selftest.sh --selftest-search
Scripts/run-selftest.sh --selftest-memory
Scripts/run-selftest.sh --selftest-ui-strings
```

**Done when:** the inverted case is green; the button no longer erases the index; AGENTS.md's
knowledge-index paragraph says past conversations survive "New conversation". The chunks already
lost cannot be restored, which is recorded in `STATUS.md` as a fact rather than a failure of this
task.

---

### P1-27 — The Phase 1 gate includes the owner's own failed requests

**Finding(s):** J (the whole audit). **Effort:** 1 day. **Depends on:** P1-01. **Unblocks:** the Phase 1 gate (the gate row below changes).

**Why:** The fixtures were green while the Agent invented the owner's email on 27 Sep. The 30
canonical cases were written from reports, and none of them is a two-turn "summarise my emails" →
"is this coming from my emails?". The gate should fail on the requests that actually failed.

**Target behaviour:** ten `scored: false` cases, O01–O10, added to `LiveEvalCases` beside the 30 —
never inside them (`Agent/LiveEval/ToolLoopLiveEvalCases.swift:110`). They are reworded and use
fixture data only. They print their own line, `TOOLLOOP_LIVE_OWNER <n>/10`, and a `.jsonl` row
each:

| Id | Turns (reworded) | Pass means | Expected fix |
|---|---|---|---|
| O01 | "Summarise my last emails" → "Is this coming from my emails?" | `search_email` ran; the reply names fixture senders; no `FABRICATED` | P1-24 |
| O02 | "Check my emails" → (follow-up if asked) "go for it" | a mail read ran by the end | P1-24 |
| O03 | "What do I have tomorrow?" | `get_agenda`, date = tomorrow | P1-24, P4-01 |
| O04 | "Can you look at my inbox?" | a read, not an offer, and no "I don't have access" | P1-24 |
| O05 | "Open my Gmail in Chrome" | `browser.navigate` / `computer.open_url` to mail.google.com, or the approval card for it | P1-13 (done) |
| O06 | "Hi" (after a turn that searched files) | no tool; no mention of the earlier result; under 200 characters | P1-11, P1-18 |
| O07 | "What's today's date?" | the answer equals today, with no tool call | **P4-01** |
| O08 | "Add 'bring passports' to my trip doc" | `find_drive_files` before `append_doc`; `document_id` from the fixture | P1-25 |
| O09 | "Summarise my recent emails and list tomorrow's events" | both reads ran | P1-24 (multi-class) |
| O10 | "Can you hear me?" (typed) | no "ears", no "can't hear", no refusal | P4-03 (tracked, not gated) |

**Gate change (Phase 1 exit, `STATUS.md` Phase gates row 1):** in both full gate runs, every O-case
whose expected fix is a Phase 1 task — or P4-01, which now runs in Phase 1 — passes, with 0
`FABRICATED` and 0 `LEAK` across the set. O10 is recorded, not gated, until P4-03.

**Do not:** edit these cases to pass the gate, or move any of them into the scored 30.

**Done when:** the ten cases are registered, `--selftest-toolloop-live-grader` stays green, and one
full run's `TOOLLOOP_LIVE_OWNER` line is recorded in `STATUS.md` as the baseline (expected: mostly
red before P1-24, P1-25 and P4-01).

---

### P1-28 — The prompt cache survives a conversation: size the context once, and keep the prompt's front stable

**Finding(s):** J latency. The causes were traced on 2026-09-27 from `metrics.jsonl`'s per-process
CPU clock. **Effort:** 1.5 days. **Depends on:** none (P0-18 is done; this finishes it).

**Why (what the user experiences today):** Typed turns take 6 s at the median and 18 s at the 90th
percentile. On 27 Sep the median was 13 s, with prefills of 4.5–12.4 s for prompts of only
1.4k–2.7k tokens. P0-18 reused 646 of 666 tokens in its self-test (a 2.10 s → 0.33 s prefill), but
in real use it reused **nothing** on 5 of the 12 passes where reuse was measured. The trace found
three causes:

1. **Every growth of the context throws the cache away** (all 5 misses).
   - `ensureContext` (`Formatting/LLM/NotesModelRuntime.swift:1852-1870`) only grows, and each
     rebuild frees the context and resets `kvTokens`.
   - The planner asks for at least 1,024 answer tokens
     (`Agent/AgentAnswerBudget.swift:36-40`). Prompt + 1,024 + 256 gives exactly the 3,072, 3,584
     and 4,096 rebuilds in the log.
   - **The warm-up sizes its context for a 1-token answer** (`NotesModelRuntime.swift:490`), so
     the first real turn always rebuilds, and so does every turn whose prompt grew a little.
2. **The planner prompt's front changes per request.**
   - The tool list is chosen per request (`Agent/AgentCapabilityManifest.swift:740-777`).
   - The matching rule lines sit in the **middle** of the system prompt, before the catalogue
     (`Agent/RealtimeAgent+ToolLoop.swift:1166-1170`).
   - So two turns share only 484–1,012 of about 2,000 tokens.
3. **App launches that load the model are not the person's.** The four "reloads" were four
   processes, not four reloads in one app. Launch-time diagnostic flags run as the real app
   (`NextNotesApp.swift:229-280`); at least one loaded the model (06:54:58Z) and one crashed inside
   a llama load during `NSApp.terminate` (`NextNotes-2026-09-27-030508.ips`). A second copy of the
   weights in another process then pushed this one's weights out of memory — 6.0 s to prefill 172
   tokens.

A fourth fact is a logging gap rather than a cause: unloads during 23–24 Sep with no idle gap
record no reason anywhere. `shutdownNow` (`:1482`) writes only to the system log.

**Target behaviour:**
1. **Size the Agent's context once.** The first load or warm-up for the Agent role builds the
   context at `min(model window, max(8,192, the planner's largest prompt + planner budget +
   headroom))`, and the warm-up uses that size, not a 1-token one. Growth past it doubles rather
   than creeping by 512. `contextGranularity` stays for other callers. Record the memory cost of
   the larger context on this Mac in `STATUS.md`; it is the trade that §12's "max context 32,768"
   limit already allows.
2. **A stable front, a varying tail.** The planner system prompt is ordered persona → fixed rules →
   the manifest's **stable** catalogue (the core entries every turn has) → and only then the
   per-request class lines and extra entries, just before the user turn. The grammar and `tools`
   array follow the same `selected` set (AGENTS.md: the grammar and the schema are one set), so
   only the order changes, never the set.
3. **Diagnostic launches never load a model.** When a launch-time diagnostic or `--probe-*` flag is
   present, `NotesModelRuntime` refuses to load and says so on stdout. A load already in progress
   is cancelled before `terminate`, which removes the crash path.
4. **Every unload writes its reason**: a `model.unload reason=<idle|pressure|switch|trial|shutdown|error>`
   row in `metrics.jsonl`, the existing file.

**Red-first self-test:** extend `--selftest-llm-prefix-cache` (marker unchanged). Today it runs
S1-mini with an 8-token budget (`PrefixCacheSelfTest.swift:20`), so the context never grows and
the prompt never varies — which is why it is green.
- R1: warm up, then three planner-sized turns (answer budget 1,024) of growing prompts → **no
  context rebuild**, and each turn reuses at least the system prompt's tokens. Red today.
- R2: two requests that select different classes → the shared prefix covers persona, rules and
  the stable catalogue (≥ 80% of the system prompt). Red today.
- R3: A/B/A across two callers (planner, then voice routing, then planner) → the third pass reuses
  at least the planner's stable prefix after one rebuild. Record the number; it is a measurement,
  not a bar.
- R4: under a diagnostic flag, a load request is refused, and `loadAttemptCount` (`:127`) stays 0.

Needs the Agent-role model on disk. Without it, print `LLM_PREFIX_CACHE_ABSENT` for R1–R3 — never OK.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-llm-prefix-cache
Scripts/run-selftest.sh --selftest-native-tools
Scripts/run-selftest.sh --selftest-capability-manifest
Scripts/run-selftest.sh --selftest-toolloop-live --quick
```

**Done when:** R1, R2 and R4 green; R3's number is recorded; `--selftest-native-tools` still proves
that the grammar, catalogue and `tools` array are one set; `--quick`'s median turn time is recorded
before and after. AGENTS.md's prefix-reuse paragraph gains: "size the context once; growth wipes
the cache".

---

### P1-29 — One turn id across the logs that exist, and the moments that leave no trace

**Finding(s):** J "What the logs cannot tell". **Effort:** 1.5 days. **Depends on:** none. **Rule:**
no new log file. AGENTS.md: one usage log. The audit log and `metrics.jsonl` gain **fields**; no
store is added.

**Why:** The audit could not say which model answered a given request, whether an approval card had
ever appeared, or when history was erased. The pieces exist but do not join:
- `usage.jsonl` rows already carry `turnID` and `conversationID` (`Support/Usage/UsageRecord.swift:77-79`,
  filled by `ModelPassRecorder.correlation`, `:21`, `:221`).
- **Audit rows carry no id at all.** The row type is `AgentAuditEntry`
  (`Agent/Activity/AgentActivity.swift:42-118`, with a hand-written decoder), written by
  `AgentAuditLog.record` (`Agent/Activity/AgentActivityStore.swift:153-197`).
- `metrics.jsonl`'s `LatencyCorrelation` has session, work and revision, but no turn id
  (`Support/LatencyTrace.swift:170-181`).
- The ids to carry already exist: `RealtimeAgent.currentTurnID` (`Agent/RealtimeAgent.swift:56`),
  the coordinator's `usageTurnID` (`Agent/VoiceConversationCoordinator.swift:361`), and
  `VoiceClosedTurn.turnID` (`Agent/Voice/VoiceLatencyTimeline.swift:424`).

**Target behaviour:**
1. **Join.** `AgentAuditEntry` gains optional `turnID` and `conversationID`, set at the request and
   reply sites (`RealtimeAgent.swift:120`, `:318`, `:336`; the coordinator's `:316-494`).
   `LatencyCorrelation` gains `turnID`, set at `VoiceLatencyTimeline.swift:399` and `:431`. Old
   lines still decode.
2. **Card lifecycle.** An audit row when a card is **shown** (`PermissionGate.present`, `:42`),
   **cancelled** (`cancelPending` `:143`, `cancelMatching` `:163`), or **expired** (the
   `FunctionCallWatcher` timeout, `:614-628`). A row for meeting proposals raised
   (`AgentService.swift:517`, `:593`) and decided (`:423`), and for the task card
   (`AgentTaskManager.swift:254`). Each row holds the tool id and the request id, never the
   arguments.
3. **Clear, compact and end.** One audit row each, from `clear()` (`RealtimeAgent.swift:1214`),
   `endSession` (`:988`) and `compactIfNeeded` (`:1006`): the reason, the message count and the
   compaction count. No text.
4. **Wake near-misses.** `WakeWordTelemetry.recordNearMiss(closeness:reason:)` writes the existing
   `.wakeMiss` row (`Activation/WakeWord/WakeWordTelemetry.swift:52-66`). It is fed by the text-path
   confirmation that already computes a score and throws it away
   (`WakePhraseConfirmation.swift:102`, `:112-119`; `WakeWordDetector.spotPhonetically` `:40-41`).
   It records the score and reason only, never the transcript, and at most one row per 10 s. The
   audio spotter gives no score (`SherpaKeywordSpotter.swift:55-63`) and stays as it is.
5. **Knowledge searches.** The search metric records an empty query as `empty`, not as a 0-hit
   search (`UI/Knowledge/KnowledgeSearchView.swift:363`) — the likely source of J L21.
6. **Bound the audit file.** It is append-only and never trimmed; only the in-memory list is capped,
   by an unnamed `400` (`AgentActivityStore.swift:177`). Name that constant, and rotate the file at
   8 MB the way `UsageLog` does (`Support/Usage/UsageLog.swift:26`).
7. Remove the 13 Sep fixture rows once with the existing script
   (`Scripts/cleanup-selftest-rows.py --apply`). Its dry run reports 17 of 696. The owner runs it;
   an agent does not.

**Red-first self-test:** extend `--selftest-activity` (marker unchanged):
- a typed turn's request row, reply row and usage row share one `turnID`;
- `present` → a "shown" row, and a cancel → a "cancelled" row;
- `clear()` → one row with counts and no message text;
- an old audit line with no ids still decodes.

Extend `--selftest-wake` with a near-miss that writes one `.wakeMiss` row with a score and no text.

**Done when:** a single request can be followed from its audit row to its model passes by
`turnID` alone, which `--usage-report` can print. The card, clear and near-miss rows exist. The
audit file rotates. No new file was created.

---

### P1-30 — Memory review keeps no one else's words, and nothing after "clear"

**Finding(s):** J L17 (privacy). **Effort:** 1 day. **Depends on:** none. **Related:** P4-07a sets
the same rule for memories (store where a fact came from, never the words), and this task applies
it to the review's own file now instead of in Phase 4.

**Why:** `agent-memory-review.json` (writer `MemoryReviewStateStore`,
`Memory/RoutineSuggestions.swift:105`; filename `:116`; written 0600 at `:298-312`) keeps, in full
text:
- **`requests[]`**: every user-role turn of every reviewed session (`:38-43`, logged by
  `recordReview` `:154-162`, called at `Memory/MemoryReviewer.swift:1075`). The owner's file holds
  74 of them, from 16 sessions. The microphone does not distinguish speakers, and
  `AgentUtteranceSource` has only voice, text and meeting (`Agent/RealtimeAgent.swift:4-8`). So
  **other people's side talk is saved as if the owner said it.**
- **`runs[].refused` and `.skipped`** hold proposed facts as text (`Memory/MemoryReviewLedger.swift:13-43`).
  There are 40 refused and 61 skipped entries, and refused facts are often the ones taken from
  someone else.
- **After "Clear conversation" the session is still reviewed and its texts still saved.**
  `endSession(.cleared)` still hands it to the review (`RealtimeAgent.swift:990-992`).
- The only retention limits are counts: 400 requests (`:49`, `:160`) and 200 runs (`:132`).
  Nothing ages out.

**Target behaviour:**
1. `requests[]` stores the key, date and session id — **no `text`**. If the routine-suggestion
   offer needs words, it builds them from the key. Check this against `RoutineSuggestions`
   before removing the field, and record in `STATUS.md` what the offer reads.
2. `refused` and `skipped` store the reason and a count. `saved` stores memory entry ids, not text.
3. No review, and no request rows, for a session ended by the person's delete action (P1-26's
   "Forget all conversations", or today's `.cleared`).
4. Request rows older than 30 days are pruned at launch, and a key's rows go once its suggestion is
   resolved.
5. On first load after this ships, the existing `text` fields are removed from the file, once.

**Red-first self-test:** extend `--selftest-memory-review` (marker unchanged):
- a reviewed session whose user rows contain a distinctive phrase → the written file does not
  contain it (the P4-07a pattern);
- a `.cleared` session writes no request rows;
- a file with old `text` fields loads, and the next save has none;
- a 31-day-old row is pruned.

**Done when:** the file holds no utterance text; routine suggestions still offer (their case in
`--selftest-memory-review` or `--selftest-schedule` unchanged); the one-time migration is recorded
in `STATUS.md`.

---

### P1-31 — Needle 3 executes the first tool; the mid-sized Agent LLM answers and continues

**Shared-file integration (2026-09-30):** System Two resolves the Agent role only;
notes and cleanup can use another model. Candidate files come from the existing
verified library and are reused without copies. Tag every paired report with artifact
and planner path; SB-07 must meet this task's quality/latency gates before recommending
Needle-first. This experiment grants no notes/dictation cloud consent.

**Finding(s):** [2026-09-29 paired comparison](../../../Tests/Reports/toolloop-live/2026-09-29-needle-execution-comparison.md). **Depends on:** P1-01, P1-03, P1-05, P1-06. **Status:** in progress; P1-31a implements and measures the bounded first-call policy/harness slice; normal Agent turns still use the existing planner. **Purpose:** test Cactus Needle 3 as fast **System One** tool selection/execution and the Agent-role mid-sized LLM as **System Two** for answers and remaining reasoning. This is Needle 3's structured `function_calls`/`confidence`/`validation` API, not Choice/Score/Noul.

**Measured so far:** nine fixed cases, one run per local model: Qwen3-4B 2/9 → 4/9, Gemma 4 E4B 2/9 → 3/9, Qwen3.5-4B 2/9 → 4/9, MiniCPM5-2B 2/9 → 4/9. All four remain below the scaled 8/9 bar; Ling 3.0 Flash Sante free did not run because credential lookup timed out. These are directional targeted results, not a full score or a default-path decision. Needle chose `memory.recall` for a **save** request, abstained on some offered reads, and left compound work unfinished. The first benchmark version also had a fixed confidence gate and truncated an intent class to eight tools; those rules were removed after the measurement, so the comparison must be repeated on the current implementation. Do not retroactively describe the old run as testing the revised path.

**Current evidence (2026-09-30):** [P1-31a investigation](../../../Tests/Reports/toolloop-live/2026-09-30-p1-31-investigation.md) fixes first-call validation, recall/save continuation, answer-only claim checking and the planner's fixture-roster bypass; adds report timing/resource identity and isolated Needle usage rows. The fixed quick set was paired across all four installed local candidates: Qwen3 5/10→6/10, MiniCPM 2/10→3/10; Gemma and Qwen3.5 Needle arms stopped incomplete on engine timeouts. Qwen full ordinary 17/30, owner 7/10 vs Needle 16/30, owner 8/10; whole-case p95 49.038→51.012 s. Keep the ordinary planner. No Agent/notes/cleanup choice or weight file changed. The earlier 2026-09-30 quick 9/10 vs 7/10 used the defective fixture roster and is not this fix's paired delta.

P1-31a's scripted policy tests pass in `--selftest-toolloop-production`; live save/draft/compound quality remains red. At the P1-31a revision, the unchanged grader labelled the honest “I ran out of time…” stop FABRICATED through `i ran`. P1-31b pins and fixes that classification separately without changing a timeout to PASS; see its [report](../../../Tests/Reports/toolloop-live/2026-09-30-p1-31b-follow-through.md). Native-tools regression is currently 4/5 grammar-valid on two direct-planner runs, not green. Full arms for the other candidates, live negative cases, first-token/audible and overlap measurements, and repeated promotion gates remain parent P1-31 work. This slice is not SB-07 completion or a Phase 1 exit.

**Target behavior:**

1. On an Agent turn with a tool intent that fits Needle's context, offer the complete matched intent classes from the turn's **existing `AgentCapabilityManifest`**. Keep the resident `NeedleServer`; do not spawn an engine per turn, add a second tool catalogue, or make Needle a separate authority. If the complete class does not fit, or Needle is absent, fails, or abstains, use the existing planner. No Needle wait on answer-only turns.
2. Needle's first validated `function_call` goes **straight to `ToolStepRunner.execute`**, then the existing `AgentToolExecutor` and permission/effect boundary. The mid-sized LLM does not re-decide whether to make that first call. Reads run under the current read policy; writes still show the one approval card before committing. Reject negation, unknown/unavailable tools, missing or ungrounded required arguments, and invented identifiers. Log confidence for analysis; do not use one universal confidence cutoff across changing tool sets.
3. Hand the **verified** result to the Agent-role LLM. For a one-step request, it writes the answer from that result with no second planning pass. For a compound request, it plans only the remaining steps, with the first result and completed call in the existing turn state; it must not claim an unexecuted save/send/play step. Keep progress visible and charge Needle time to the same turn budget. Preserve full-duplex voice work and the current output scheduler.
4. Use the existing `usage.jsonl`, planner trace, and `--selftest-toolloop-live` harness. Keep all owner stores isolated. Do not download another model or allocate a second permanent store to run this comparison; temporary model files are removed after their run when disk is tight. Cloud comparison requires `--allow-cloud` and valid credential access, and unavailable/429 runs are **incomplete**, never scored as failures or successes of the model.

**Red-first cases:** `memory.remember` versus `memory.recall` for “remember/save this”; a negated send; an invented recipient or document id; `schedule.list` and `memory.recall` when offered; a no-tool question; a Needle engine failure/timeout; a complete intent class over Needle's cap; F03 file search **then** draft/address follow-through; A02 **click/play** the named video, not merely navigate or snapshot; and a write whose approval is denied. Pin that an attempted first call is logged once and is not repeated by System Two.

**Comparison and exit:** Run paired baseline and `--needle-first` on the same fixed quick set, then the full 30 canonical cases plus O01–O10 on each proposed Agent-role model: MiniCPM5-2B, Qwen3-4B-Instruct-2507, Qwen3.5-4B, Gemma 4 E4B, and Ling 3.0 Flash Sante free when available. Keep the fixture corpus and grader unchanged between arms. Record pass/fail class, tool calls, first verified result latency, first answer latency, total turn p50/p95, Needle abstentions and errors, and memory/disk cost in `Tests/Reports/toolloop-live/`. A candidate may become the normal path only after the fixed quick gate is at least 9/10; two consecutive full runs meet the Phase 1 ≥25/30 gate and owner-case gate; there are no wrong-effect, fabricated-action, LEAK, or ERROR regressions; and measured first-result and total-turn p95 are no worse than the paired baseline. If it misses, keep the base planner as the normal path and record the exact failing class in `STATUS.md`. Do not lower the gate or tune the case set to make the experiment green.

**Done when:** the current implementation has the red-first cases and paired reports, and `STATUS.md` records the decision and its evidence. A benchmark-only prototype is not completion.

---

## Phase 1 closing checklist (for `STATUS.md`)

- [ ] P1-01 … P1-13 ticked, each with its eval report path and its quick-score delta (full runs only at the gate).
- [ ] (H-audit 2026-09-23) P1-14 … P1-18 ticked: P1-14 `DUPLEX_OK` (+ owner's `--selftest-voice-echo-live` result or "not run"); P1-15 `VOICE_TURNS_OK`; P1-16 `ISLAND_OK` (not seen by eye: no Screen Recording grant); P1-17 and P1-18 with their `--quick` report paths.
- [ ] (H-audit 2026-09-23) Amendments done: P1-02 step 6 calls `AgentAnswerBudget` (`grep -n "maxTokens: 256" Sources/NextNotes/Agent/RealtimeAgent+ToolLoop.swift` → nothing); P1-06 final round and revision refill; P1-10a reader-scaled cap; P1-10b outcome-keyed error sentences; P1-07 shared `acknowledgmentKeys`.
- [ ] STATUS.md records that P4-08 steps 1–2 were done by P1-18.
- [ ] Exit gate item 1: two consecutive full runs ≥ 25/30 on the Agent-role model, 0 `LEAK`, 0 `ERROR`.
- [ ] Exit gate item 2: Apple FM full run recorded, with 0 `FABRICATED`.
- [ ] (2026-09-27) P4-01 done inside Phase 1: `--selftest-now-block` → `NOW_BLOCK_OK`, and P2-01's baseline not yet taken when it landed.
- [ ] P1-31 paired Needle-first comparison and negative cases recorded; normal-path decision follows its quality and latency gates, not the nine-case prototype.
- [ ] Exit gate item 2b (J audit, 2026-09-27): in both gate runs every owner-log case O01–O09 PASS (`TOOLLOOP_LIVE_OWNER`), 0 `FABRICATED`, 0 `LEAK`; O10 recorded, not gated (P1-27).
- [ ] Exit gate item 3: every listed flag OK (or its documented `_ABSENT`).
- [ ] `make test` green; `make acceptance TIER=core` no new FAIL.
- [ ] AGENTS.md: new flags (`--selftest-toolloop-live`, `--selftest-toolloop-live-grader`,
      `--selftest-capability-manifest`, `--selftest-native-tools`) listed; realtime tool-loop
      paragraph rewritten; one paragraph each on the live eval and the three native backends.
- [ ] Cases still red and why (expected: N02 until P4-03; possibly N01 until P4-03) written
      into `STATUS.md` with the task that owns them.

## P1-31b implementation follow-up — 2026-09-30

Timeout/claim and broad-mail grounding cases are red-first and green. The prompt-only save/draft/combined-read candidate is removed after mixed quality evidence (ordinary quick 5/10→4/10, one WRONG_TOOL). Original planner rules remain; no budget, approval or independent-role change. [Report](../../../Tests/Reports/toolloop-live/2026-09-30-p1-31b-follow-through.md) separates rejected-candidate measurements, warm-up interruptions and final retained-source checks. Save/draft/combined completion and parent promotion gates remain open.


## P1-31c implementation follow-up — 2026-09-30

`4063667` repairs the bounded explicit personal-save producer: whole single-fact remember requests create a guarded memory.remember action before model planning, and only the executor confirmation is returned. Actual bad-output replay and durable store fail before repair and pass after; original Y01 passes ordinary and Needle-first-enabled. Questions, conditional/external/compound/ambiguous requests stay with the planner. [Report](../../../Tests/Reports/toolloop-live/2026-09-30-p1-31c-explicit-memory.md). Final fixed Qwen quick is 5/10 against fresh 4/10, still below 9/10; the subset excludes Y01 and p95 worsens, so no general promotion or latency gain is claimed. Parent P1-31 remains in progress; drafts/combined work, live negatives and full/owner/overlap gates remain.

### 2026-10-02 P1-10a-1: measured ordinary result admission

Original105 drops the mailbox body after an actual guard note plus calendar result before the prompt measurement. Fixed106 retains it while it fits; the same84 actual-loop checks pass, including existing counted-pressure folding. Only the AgentToolLoop producer body differs between native manifests. The final-answer caller still eagerly folds and remains an explicit follow-up, along with default scheduled policy. No model/default/phase promotion: quick4/10 below9, core21/22 wake failure and direct voice identity remain open. See the [complete bounded proof](../../../Tests/Reports/agent-overhaul-closure/c04-result-context-review/native-verification/verification.md), including initial104 fixture-domain correction and retained private raw evidence.

### 2026-10-02 P1-10a-2: measured account-read final admission

The final-caller follow-up is now boundedly verified: actual original109 RED7/122
(all115 controls green) → identical fixed110 PASS122, prior84 and all30 focused
flags. The same nested measured fitter now admits full capped results to ordinary
and final callers, removes exact leading CRLF history under pressure, and refuses
irreducible final envelopes through the existing retained-result renderer. Exact2
producer/documentation files differ in1050 compiler pins; the conductor and registry
remain common. No extra fit-path count await or model pass; final pressure adds
bounded existing counts whose latency is unmeasured. Quick4/10/79.8s and CORE21/22
wake failure leave model/phase gates open. Scheduled policy, current ownership
across final awaits, direct native voice identity and full/live acceptance remain
open. [Actual paired proof](../../../Tests/Reports/agent-overhaul-closure/c04-final-result-context-review/native-verification/verification.md).
