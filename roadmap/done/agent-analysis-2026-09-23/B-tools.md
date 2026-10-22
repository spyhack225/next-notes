# B — Agent tool calling: why it says "I don't have access" and why it goes silent

> **Historical model assumptions — revised 2026-09-30:** this completed plan/audit
> preserves its dated measurements and implementation history. For new work, follow
> the [independent-role/shared-file contract](../../in-progress/SHARED-BRAIN/00-README.md): Meetings, Agent and cleanup
> may use different appropriate models; exact verified artifacts are reused, with
> workload-specific consent and request ownership. Agent-only file selection,
> universal model defaults and deletion based only on the Agent are superseded.
> MiniCPM cleanup + Apple guard/fallback is concurrent work, not evidence that this
> historical build used it. Re-measure quality/latency on the actual current engine.

Read-only analysis, 2026-09-23. Repo: `/Users/sergekadjo/Documents/Claude/Projects/speechify` (working tree, uncommitted changes included). Evidence: `~/Library/Application Support/Next Notes/agent-audit.jsonl` (515 rows), `agent-conversation.json`, `metrics.jsonl`, `Models/library.json`, `defaults read ai.pivotstudio.nextnotes`, `gws auth status`. I ran one self-test, `--selftest-toolloop`, and it printed `TOOLLOOP_OK`. It uses a fake provider, so it proves nothing about a real model.

---

## 0. The short version

There are four separate failure classes. They stack.

1. **No working model on this Mac right now.** The agent role is stored as the 59 MB Gemma **MTP draft head**, and the real weights are gone. Every typed turn at 21:02Z and 21:03Z answered `The model could not answer: Inference could not start.` With the current build, every path falls back to Apple Foundation Models (about 3B parameters, 4,096-token window). The planner prompt was never designed for that model.
2. **The plumbing assumes one model family and one call format.** The prompt is ChatML with a Qwen `<think>` block for every GGUF, including the Gemma the app ships. The parser accepts only Hermes `<tool_call>{json}</tool_call>`. The header check accepts only `<answer/>`, `<answer>` or `<use_tools/>`. Anything else ends the turn, or gets shown as the answer.
3. **Any error ends the turn.** An unknown tool name, a failed tool, a malformed or truncated call, or a timeout each end the turn with a one-line error. Typed turns get **18 seconds** for the whole plan (voice gets 120 s). Nothing is fed back to the model for repair.
4. **What the model is told and what it can call disagree.** The capability lines, the rules and the skills section name tools that the top-24 keyword filter dropped from "Available tools". MCP and Composio tools can never be planned. The refusal guard is keyword-based, has holes and false positives, and never runs on the voice frontend's answers.

---

## 1. Pipeline: routing and tool exposure

```
                             ┌──────────────────────── TYPED (Agent pane) ─────────────────────────┐
user text ──► RealtimeAgent.handle (RealtimeAgent.swift:207)
               │  AgentHarnessRouter.choose ── explicit "use/ask/have claude|codex|…" ──► .delegate → ACP task (background)
               │  AgentTurnIntent.resolve (AgentTurnIntent.swift:52)
               │     ├─ prefix "ask the agent|ask agent|ask the app|ask the local model|ask qwen…" ─► .localModel
               │     │        answer-only, tools FORBIDDEN (RealtimeAgent.swift:563-574)  ◄── DEFECT 10
               │     └─ everything else ─► .toolLoop
               ▼
         runModelTurn (ToolLoop.swift:329)
           ├─ CodexComputerUse.route(prompt)  (regex "open chrome|click|type…") ─► Codex app, or fall back + raw error note
           ├─ provider = AgentModelRouting.provider(for:voice:false)  (ModelRoleStore.swift:726)
           │        role .agent → installed:mtp-gemma… (!!)  → builtIn → Gemma not on disk → Apple FM
           ├─ FIRST PASS: system = voiceRoutingSystem (persona + grounding + header rules), NO tool schema,
           │   maxTokens 112, budget 18 s (warm) / 45 s (cold)          ◄── DEFECTS 3, 4, 6
           │   VoiceResponseEnvelope.parse:
           │      <answer/>… ─► AgentRefusalGuard.rebuttal? ─yes─► planner   ─no─► reply (maybe a denial)
           │      <use_tools/> ─► planner
           │      anything else starting "<" (e.g. <tool_call>, <use_tools>, <think>) ─► "The model could not answer: …invalid response header."
           ▼
         runPlannedToolLoop (ToolLoop.swift:725)
           ├─ AgentDirectIntent.parse ─► open app / open URL / locate+reveal (NO model)   ◄── DEFECT 9 (drops rest of sentence)
           ├─ tools = plannableTools() (allowlist ∩ registry ∩ switches, ≈63)             ◄── MCP/Composio never included
           │          → relevantTools(): 9 core + 15 by 4-letter keyword overlap (cap 24) ◄── DEFECT 8
           ├─ system = persona + grounding (FULL roster in prose) + rules (name memory.remember,
           │           schedule.list/create) + "Available tools:" (FILTERED 24) + skills section (names skills.*)
           ├─ loop ≤ 8 rounds, maxTokens 256/round, total budget 18 s typed / 75 s OpenRouter / 120 s voice worker
           │    parse Hermes only ─ none & text has literal "<tool_call>" ─► "invalid tool request" (END)
           │                     ─ none & no literal tag ─► text returned AS THE ANSWER (incl. XML junk)
           │    call.name not in registry/allowlist ─► "requested an unavailable tool; nothing else was run." (END)
           │    tool throws ─► "The tool X did not run: <error>" (END, no repair)
           │    read OK ─► result appended UNCAPPED to next user message
           └─ timeout ─► "Did <tool ids> (step n/8). Timed out on … Remaining steps are unfinished."
                                                                                                    └──────────┘
                             ┌──────────────────────── VOICE ─────────────────────────────────────┐
speech ──► VoiceConversationCoordinator.handle (Coordinator.swift:278)
   ├─ hesitation ("uh/um") → hold
   ├─ explicit cancel phrase → cancel job
   ├─ namingTarget → append to job / "open <name>"
   ├─ pendingIntent (only set after a capability-shaped ANSWER) + bare ack → submit(original)
   ├─ tool-shape gate: AgentDirectIntent.parse | toolShapeMatch(verb AND noun) → submit   ◄── coverage gaps (DEFECT 7)
   ├─ knownNoise exact set {"okay","ok","did","am",…} → clarifier once                   ◄── eats "okay" confirmations
   └─ LocalVoiceFrontend (Apple FM, always):
        route  (@Generable LocalVoiceRoute, 64 tok) ─ startExternalTask ─► submit(text) → "I'm on it."
                                                   ─ answerQuestion ─► answer stage (capability inventory, NO tools)
                                                         streamed to TTS immediately; no rebuttal; backstop only
                                                         on the 2nd IDENTICAL denial                  ◄── DEFECT 7
submit → RealtimeAgent(voiceWorker).runVoiceObjective → [knowledge ask] → runPlannedToolLoop(voice:true)
        provider = LLMProviders.resolve(.appLLM) (voice never follows roles) → announce result
                                                                                                    └──────────┘
Meeting side (separate): MeetingAgent / FunctionCallWatcher use AgentPrompts.toolBlock (full JSON schema,
risk-filtered) and, for Needle/local, grammar-constrained JSON (LocalModelFunctionCallProposer.swift:187-198).
The live agent planner uses neither.
```

**Models per path on this Mac (right now):**

| Path | Code | Configured | What actually runs |
|---|---|---|---|
| Typed first pass and planner | `AgentModelRouting.provider` → `ModelRoleStore.provider(for: .agent)` | `modelRoles.agent = installed:ggml-org/gemma-4-E4B-it-GGUF/mtp-gemma-4-E4B-it-Q4_0.gguf` | Before today's 17:34 build: the MTP head, so "Inference could not start" (audit 21:02Z, 21:03Z; `model.load 0.43s`). Current build: `activeModel` filters it out, the built-in Gemma is not on disk, so `LLMProviders.resolve` falls through to **Apple FM** (`LLMProvider.swift:263-278`). |
| Voice frontend (route and answer) | `LocalVoiceFrontend` | fixed | Apple FM |
| Voice worker planner | `LLMProviders.resolve(preferring: .appLLM)` | ignores roles | Apple FM (same fallback) |
| "ask the agent …" | `answerLocally(forceOnDevice:)` | appLLM | Apple FM, tools forbidden |

`Models/` holds only `ggml-org--mtp-gemma-4-E4B-it-Q4_0.gguf` (59.7 MB), plus s1-mini, embeddinggemma and potion. `library.json` lists the head as `displayName: "gemma-4-E4B-it", parameterBillions: 7.5`. `postDownloadPolicy = switchDeleteOld`. The Gemma weights that answered at 06:36Z–20:39Z (`model.load 2.1–9.3 s`, `prefill prompt_tokens=1180–2317`) are no longer on disk, which is consistent with the policy deleting them once the head "loaded".

**Prompt size (measured, `metrics.jsonl` model.prefill, 2026-09-23):** the first pass is 1,180–1,301 prompt tokens. The planner is 2,203–2,317 tokens with 24 tools. Prefill takes 2.5–5.2 s per round. On Apple FM's 4,096-token window, a planner round is about 2.3K tokens of system prompt, plus up to about 600 tokens of history (2,500 characters when `contextTokens < 8000`), plus uncapped tool results, plus 256 output tokens. One large tool result overflows it.

---

## 2. Ranked defects

Each entry gives the symptom, the root cause (file:line), the evidence, and the fix.

### D1 [P0]: The agent has no usable model; the role points at a draft head
- **Symptom:** "hi" gets `The model could not answer: Inference could not start.` (audit 2026-09-23T21:02:52Z and 21:03:35Z; `agent-conversation.json` holds only these 4 rows). After today's build it silently drops to Apple FM for every path.
- **Root cause:** The picker installed the MTP head as a model. `ModelLibraryStore.decide(.switchDeleteOld, loadSucceeded:)` (`Support/ModelLibrary/ModelLibraryStore.swift:557-561`) deletes the previous model after a "successful" load. llama opens a head, then fails when it builds a context. `ModelRoleStore.provider(for:)` still checks `InstalledModelLibrary.model(withID:)` (`InstalledModelLibrary.swift:171-173`), which searches `models` including auxiliary files, not `usableModels`, and re-sets `activeAgentModelID` to the head on every typed turn (`ModelRoleStore.swift:573-578`). The stored role token and `library.json` row are never repaired. Voice never consults roles (`ModelRoleStore.swift:727`).
- **Fix:** Make `model(withID:)` return nil for an auxiliary file, or check `usableModels` in `provider(for:)`. At launch, reset any role that points at an auxiliary file and tell the user once. Define "load succeeded" for `switchDeleteOld` as one real decoded token, not an opened file. Show the fallback ("answering with Apple's model because …") in the pane.

### D2 [P0]: Hard-coded ChatML/Qwen template and lossy detokenization
- **Symptom:** Tool calls come out in a foreign syntax, and fragments of them are shown as the reply:
  - `Every night at 10, remind me to put the book out` → reply `name="reminders">` (06:37Z)
  - `Can you make a document that summarize everything that you know about me` → reply `name="search_knowledge"> name="query">user\n name="memory.recall"> name="query">user` (06:39Z)
- **Root cause:** `NotesModelRuntime.chatMLPrompt` (`Formatting/LLM/NotesModelRuntime.swift:1030-1042`) wraps every model in `<|im_start|>` with a pre-closed Qwen `<think>` block and stops on `<|im_end|>` (`:1044`). The shipped model is Gemma 4 E4B (`NotesModels.swift:10-13`), which uses neither. Tokenization parses special tokens (`LlamaHelpers.swift:23-31`, `parse_special = true`), but `piece()` renders with `special = false` (`LlamaHelpers.swift:43,46`). A model whose tool-call delimiters are control tokens therefore emits calls whose tags disappear. The Hermes check at `ToolLoop.swift:934` then sees no literal `<tool_call>` and returns the remainder as the answer (`:950`).
- **Fix:** Use the GGUF's own template (`llama_model_chat_template` plus `llama_chat_apply_template`), or keep a per-architecture table. Keep the `<think>` suppression only for Qwen3-family models. Render special tokens in planner output (`special = true`), or detect tool-call control tokens by id.

### D3 [P0]: Format rigidity turns a valid intent into silence or an error
- **Symptom:** "The model could not answer: The model returned an invalid response header." / "The model returned an invalid tool request." / "The tool planner returned an invalid tool request." / raw XML as the answer.
- **Root cause:**
  - `VoiceResponseEnvelope.parse` (`VoiceConversationWork.swift:45-65`) accepts only exact `<answer/>`, `<answer>` or `<use_tools/>`. `<use_tools>`, `<Answer/>`, `<tool_call>…` (a tool-tuned model skipping the header, which the grounding invites by naming `filesystem.find`), and `<think>` all fall into `.invalid` → `ToolLoop.swift:432-433` ends the turn.
  - `<answer/>` followed by a tool call → `:462-464` ends the turn instead of escalating.
  - `AgentToolCallParser` (`AgentToolCall.swift:26-38, 44-51`) accepts only Hermes JSON. It rejects `"parameters"` in place of `"arguments"` (the arguments are silently emptied), bare JSON, `<function=…>`, Gemma or Qwen3 XML calls, single quotes and trailing commas.
  - A call cut off at the 256-token cap (`ToolLoop.swift:888,891`; `draft_email` or `create_doc` bodies easily exceed it) has no closing tag, so the turn ends as "invalid tool request" (`:934-935`).
- **Fix:** Treat an unknown header or a direct `<tool_call>` as `<use_tools/>`, and feed that call straight to the planner. Use a tolerant multi-format parser (Hermes, OpenAI JSON, `parameters`/`arguments`, Qwen/Gemma XML). Better still, use constrained decoding (D-arch 2). Raise the planner token cap to at least 1,024 for write tools. On a parse failure, run one repair round ("your call was malformed: …; emit exactly …").

### D4 [P0]: The 18-second budget makes typed tool plans time out
- **Symptom:** "I stopped the tool plan because it took too long." / "No message matches older:1d. I stopped the tool plan because it took too long. Remaining steps are unfinished." (typed, 09-15T01:13Z). The same appears in many voice turns on 09-14.
- **Root cause:** `runPlannedToolLoop` gives a non-worker local turn `Duration.seconds(18)` for **all** rounds together (`ToolLoop.swift:796-798`). One local round is 2.5–5.2 s of prefill plus up to 256 decoded tokens, so a two-step "search, then summarise" plan cannot fit. The typed first pass has its own 18 s (`RealtimeAgent.swift:31`, `ToolLoop.swift:386-388`). A voice worker gets 120 s, the reverse of what the user sees: typed users wait at the screen.
- **Fix:** Give typed turns a per-round deadline (about 30 s) plus an overall ceiling (about 120 s), with progress shown. Charge prefill once per session when the prefix cache hits. Never throw away the last verified result; at minimum, answer from it.

### D5 [P1]: Errors end the turn; nothing is repaired
- **Symptom:** `The tool computer.open_app did not run: Nothing is connected that can do “No application named Claude Code is installed.”.`, twice, while the user said "check Claude instead" (09-14T16:54Z). Also `The tool planner requested an unavailable tool; nothing else was run.`
- **Root cause:**
  - An unknown or alias name returns immediately (`ToolLoop.swift:962-967`). The alias is now resolved before the allowlist, so AGENTS.md's note is half stale, but a miss still abandons the whole plan. `ToolRouter.resolve`'s fuzzy mapping (`Agent/Tools/ToolRouter.swift:16-40`) is never used here.
  - Any tool error ends the turn (`:1072-1081`) by design: "Do not hand a denial/error back to the model." That rule is right for *denials* and wrong for *errors* such as not found, bad date or empty query.
  - `ComputerToolExecutor.swift:79` wraps "app not installed" as `.noIntegration`, which renders as "Nothing is connected that can do …" (`AgentModels.swift:286`). That reads as an access problem.
- **Fix:** Split `AgentError` into *user/policy denial* (end the turn), *recoverable* (not found, invalid argument, unknown tool name: return an `ERROR: … valid options are …` result to the model and allow up to 2 repairs), and *infrastructure* (end the turn with plain words). Route unknown names through `ToolRouter.resolve` plus an edit-distance match against the roster. Use `.notFound` for missing apps.

### D6 [P1]: The typed first pass is a tool-less model that must pick a header, and it produces most of the "I don't have access" replies
- **Symptom (09-22T00:58–01:01Z, five times, identical):** "Summarize my last emails and list me my events for tomorrow" → *"I don't have access to your email or calendar data without a tool call … would you like me to do that?"*. Then "yes" gets the same reply, and "use them" and "i am telling you to use your tools…" get the same reply again. Also *"I don't have access to browsers or external tools"* for "Open chrome" (00:57Z).
- **Root cause:**
  - The first pass (`ToolLoop.swift:399-419`, `voiceRoutingSystem` at `:494-537`) tells the model *"You are a conversational assistant with tools for calendar…"* but gives it no tools and a 112-token budget, so small models reason about their access and ask permission.
  - The typed path has **no pending-intent slot**. Voice has one (`Coordinator.swift:359-367`), so a bare "yes" or "use them" goes back to the model with its own denial in history (`chatHistoryForCurrentTurn`, `:382`).
  - The deterministic direct-intent and tool-shape gates run only for voice (`Coordinator.swift:371-378`). On the typed path, `AgentDirectIntent` is reachable only *after* the first pass picks `<use_tools/>` (`ToolLoop.swift:741-745`).
  - `AgentRefusalGuard` (`AgentRefusalGuard.swift:35-68`) matches phrases only. It misses subjects such as "Drive", "Google Docs", "tasks", "web", "history" and "tools", and "I'd need to use your tools — would you like me to?" contains no denial phrase at all.
  - The guard also has false positives: `"i don't have"` matches *"I don't have enough information to set that reminder"*, which forced a re-plan (audit 06:37:52Z, "Re-planned after a false refusal", 11.6 s) and told the model *"Do not repeat the denial. Call the tool"*, which pushes a write with missing fields.
  - 112 tokens also truncates ordinary typed answers (`:414,418`).
- **Fix:** Remove the header pass for typed turns and send them straight to the planner, which answers directly when no tool is needed (its rules already allow that). If the header pass stays, run `AgentDirectIntent` and `toolShapeMatch` before it, add a typed pending-intent slot, give it at least 512 tokens for text answers, and treat "offer to use a tool" replies as `<use_tools/>`. Tighten the guard: require the denial to govern the subject in the same clause, and exclude "enough information", "not sure" and "don't have a …".

### D7 [P1]: The voice frontend speaks denials unchecked; gate coverage gaps; "okay" is treated as noise
- **Symptom:**
  - *"I don't have access to your calendar or tasks."* for "What is on your to-do list for today?" (09-14T14:28Z), followed by 4 more denials with different wording.
  - *"I cannot access your emails directly … paste the text"* (09-14T17:44–17:48Z, reworded each time).
  - "Can you hear me?" clarified as garble twice (09-22T21:44Z; the current list no longer contains it).
- **Root cause:**
  - The answer stage streams to TTS as tokens arrive (`Coordinator.swift:446-447`) with no `mayBeDenial` hold, and `AgentRefusalGuard.rebuttal` is never called on the voice frontend (the only call sites are `ToolLoop.swift:471,942`).
  - The backstop fires only on the **second identical** denial text (`Coordinator.swift:484-495`), and models reword.
  - `toolShapeMatch` requires verb AND noun (`AgentDirectIntent.swift:244-253`, table at `:193-239`), so these all go to Apple FM's router: "what's on my calendar", "what's on my to-do list", "any new emails?", "remind me to …" (no schedule entry at all), and "what did we decide last meeting" (no meeting or knowledge entry).
  - The answer stage has the capability inventory but no tools, and it is told "no promises to perform work" (`LocalVoiceDecision.swift:145-156`). A mis-route therefore *must* produce a refusal or a guess.
  - `knownNoiseFragments` contains `"okay"` and `"ok"` (`Activation/VoiceTurnPolicy.swift:56-59`). The planner's reminder rule asks for the user's yes before `schedule.create` (`ToolLoop.swift:686-688`), and that question comes back from a *finished* worker, so `pendingIntent` is nil (it is set only on the answer path, `Coordinator.swift:479-481`). "Okay" then gets "Sorry — I didn't catch that." and the reminder is never created.
- **Fix:** Run `rebuttal()` on the answer stage (hold speech while `mayBeDenial`, as the typed path does). On the first contradicted denial, escalate to `submit(text)`; don't wait for an identical second one. Add calendar, to-do/reminder, meeting and knowledge patterns (question forms) to the gate; adding routes follows the "may only add" rule. When a worker result ends in a question, set `pendingIntent` to the worker's objective. Drop "okay"/"ok" from the noise list while a pending question exists.

### D8 [P1]: The prompt names tools the schema does not list; MCP and Composio are invisible
- **Symptom:** "I cannot access past meetings / reminders / skills" while those tools exist. Connected MCP or Composio tools can never be used by the agent.
- **Root cause:**
  - `relevantTools` (`ToolLoop.swift:603-633`) keeps 9 core tools plus 15 chosen by substring overlap with request words of 4 or more letters (`Skills/SkillPromptIndex.swift:92-100`). There is no stemming, so "to-do", "mail" (4 letters, but descriptions say "Gmail"/"email"…), "what did we decide" and "Sarah said" don't reach meeting, knowledge or schedule tools. Ties fill alphabetically (`append_doc`, `assemble`, `browser.*` …).
  - Meanwhile the grounding line lists surfaces from the **full** roster (`publishGrounding`, `ToolLoop.swift:1093-1101`; `AgentGrounding.swift:139-155`). The rules name `memory.remember`, `schedule.list` and `schedule.create` (`:683-691`). The skills section names `skills.read/search/install` (`SkillPromptIndex` header and footer). The file summary names `filesystem.find/tree`. At the same time the rules say *"Never … use a tool outside the available tools listed below"* (`:677-678`).
  - The execution check uses the global allowlist, not the roster (`:962-964`), so such a call would work. The model is told not to try it.
  - The rebuttal uses the filtered roster (`:831,942`), so a denial of a dropped tool counts as "honest" and is spoken.
  - `RealtimeToolSelection.allowedIDs` is a hard-coded set (`ToolLoop.swift:29-58`), so MCP and Composio tools registered by `MCPClient.swift:173` are never plannable, advertised or allowed.
  - Workspace surfaces are advertised whatever the gws install or auth state (the text path only; the voice snapshot qualifies them, `VoiceCapabilitySnapshot.swift:95-107`). gws **is** signed in on this Mac (`gws auth status`: `has_refresh_token: true`), so "I don't have access to your email" is false here. AGENTS.md's "gws reports no credentials" is stale.
- **Fix:** Build one per-turn capability manifest and derive all four things from it: schema, prose, guard and allowlist (D-arch 1). Choose tools by namespace (intent classes: calendar, mail, files, meetings/knowledge, reminders, memory, screen, browser) instead of keyword top-k, and always include the whole namespace. Let registry sources (`.mcp`, `.composio`) join the allowlist by risk class.

### D9 [P1]: The direct-intent shortcut drops the rest of a compound request
- **Symptom:**
  - "open youtube and play the latest Cortech video" → "Opened youtube.com."
  - "find the pricing doc and email it to Marcus" → "I searched Desktop, Documents and Downloads for “pricing email marcus” and found nothing…"
  - Related (report 2026-09-14 line 722): "Open Chrome and check Claude sessions" ran only `open_app`.
- **Root cause:** `parseOpen` returns `.openURL` whenever any URL or known-site word appears and never checks the remainder (`AgentDirectIntent.swift:121-124`). `parseLocate` (`:283-293`) turns any sentence with a file word into a name search. It runs before the planner, with no conjunction or verb-count check (`ToolLoop.swift:741-745`). `MultiStepPlanRouting` uses `parse == nil` as a veto (`ModelRoleStore.swift:795`), the opposite of what is needed.
- **Fix:** Take the shortcut only when the whole sentence is consumed: no "and", "then", "after", no second action verb, and no leftover content words. Otherwise fall through to the planner.

### D10 [P1]: "Ask the agent …" turns off tools
- **Symptom:** "Ask the agent what's on my calendar" or "ask the app to check my email" gets "I don't have that information."
- **Root cause:** `AgentTurnIntent.resolve` sends the prefixes "ask agent", "ask the agent", "ask the app" and "ask app" to `.localModel` (`AgentTurnIntent.swift:61-65, 75-83, 112-119`). That route's rules forbid tool calls and tell the model to say facts are absent (`RealtimeAgent.swift:563-574`). The prefix check is also not word-bounded ("ask app…" matches "ask apple").
- **Fix:** Drop "agent" and "app" from the answer-only prefixes (the product *is* "the agent"). Keep only explicit "on-device model" phrasing, and even then allow read tools.

### D11 [P2]: Mail tool results are unusable for the requests people actually make
- **Symptom:** Every result reads "from unknown sender" (09-14 audit rows, 5 of 5). "summarize my last 10 emails" is impossible. Invented queries (`older:1d`, `in:after 2026-09-04`) return "No message matches".
- **Root cause:**
  - `searchEmail` (`WorkspaceToolRunner.swift:55-83`) requires a Gmail query, fetches 5 results (`:19`) one by one through `gws gmail +read`, and returns only ids and subjects.
  - The `header()` parser (`:450-456`) apparently doesn't match the `+read` JSON shape, so every sender comes back unknown.
  - No read-message or snippet tool is in `allowedIDs`, and the schema example gives no guidance for "latest N".
- **Fix:** Make the query optional (default `in:inbox`) and add `maxResults`. Return date, from and snippet in one `messages.list` + `format=metadata` batch. Add `read_email(id)` as a read tool. Fix header parsing for the Gmail `payload.headers[]` array. Check the query against Gmail operators, and return a repair hint to the model (D5).

### D12 [P2]: Planner context is not budgeted
- **Root cause:** `AgentToolLoop.userMessage` appends every result verbatim (`AgentToolLoop.swift:35-45`), with no per-result cap (the meeting side caps at `MeetingAgent.maxLookupCharacters = 1200`). On Apple FM (4,096 tokens) one tree, recall or email result overflows, giving `exceededContextWindowSize` → "The tool planner failed: …" (`ToolLoop.swift:927-929`). On llama the same thing surfaces as `inputTooLong` (`NotesModelRuntime.swift:586-588`).
- **Fix:** Cap each result (about 1,200 characters) and summarise older ones. Count tokens before each round and drop history before dropping results.

### D13 [P2]: Replies leak jargon
- **Examples:**
  - The timeout sentence prints raw tool ids and step counts ("Did search_email (step 1/8). Timed out on get_agenda."), `ToolLoop.swift:849-862`. The self-test *requires* this (`RealtimeAgentToolLoopSelfTest.swift:549-553`), against the persona's "never expose tool names" rule.
  - "The tool X did not run: …".
  - The Codex handoff prepends the raw error and URL (`ToolLoop.swift:364-369`; audit 09-22T00:57Z: "Codex stopped: ERROR: You've hit your usage limit. Visit https://chatgpt.com/…"). `voiceSafeReply` applies only to voice.
- **Fix:** Put one user-facing renderer on every path, and keep ids in the audit log only.

### D14 [P2]: Identity and persona confusion
- **Symptom:** "Who am I?" gets *"I'm Will, Serge's autonomous alter ego agent…"*. This reply was identical to the one for "Who are you?" (09-23T17:16Z and 17:18Z).
- **Root cause:** The user's `persona.md` says "You are Will, Serge's autonomous alter ego living in his Mac". The grounding says "You are talking with Serge…". The first pass then copies its previous answer from history.
- **Fix:** Add a fixed rule: "The user is <name>; you are <assistant>; 'I/me/my' in user turns means the user". Consider flagging "alter ego" wording in the persona editor.

### D15 [P3]: Dead code and tests that pass on prompts nothing uses
- `AgentTurnIntent.resolve` never produces `.capabilities`, `.reply`, `.unknown`, `.calendar`, `.mail`, `.files`, `.drive` or `.computer`, and ignores `hasConversationContext` (`AgentTurnIntent.swift:57`). `capabilitiesReply` is stale ("Hey Next", "ask the model", "use tools to") (`RealtimeAgent.swift:456-478`).
- `modelTurnSystem`/`modelTurnRules` (`ToolLoop.swift:548-585`) have **no production caller**. Self-tests (`RealtimeAgentToolLoopSelfTest.swift:330-430`, `PersonaSelfTest.swift:124`) grade a prompt the app never sends. This is the "finished feature with no call site" trap from AGENTS.md.

---

## 3. Evidence digest (real turns)

| When (UTC) | User | Agent | Defect |
|---|---|---|---|
| 09-23 21:02, 21:03 | "Hi" / "hi" | "The model could not answer: Inference could not start." | D1 |
| 09-23 06:37 | "Every night at 10, remind me to put the book out" | `name="reminders">` | D2, D3 |
| 09-23 06:37 | "Remind me tomorrow at 9 to …" | re-planned "false refusal" → "I don't have enough information … exact name of the reminder" | D6 guard false positive |
| 09-23 06:39 | "make a document that summarize everything … about me" | `name="search_knowledge"> name="query">user …` | D2, D3 |
| 09-23 17:18 | "Who am I?" | "I'm Will, Serge's autonomous alter ego…" | D14 |
| 09-22 00:57 | "Open chrome" | "Codex stopped: ERROR … https://… I don't have access to browsers…" | D6, D9, D13 |
| 09-22 00:58–01:01 | "Summarize my last emails…", "yes", "use them", "i am telling you to use your tools" | the same "I don't have access … would you like me to do that?" five times | D6 |
| 09-22 03:00 | "1. Check the map 2. Open Google Chrome 3. Write an email" | "I cannot check the map … Use filesystem.find to search…" (tool id leaked) | D6, D13 |
| 09-20 20:43 | "What are the project I am working on?" | "I don't know what you are working on…" | D6 (grounding fix later) |
| 09-19 23:05 | "can you open another note for me" | "I do not have the tool to create new Google Docs or Notes" (`create_doc` registered) | D8 |
| 09-15 01:13 | "Check my email, check the last email and then do a summary" | "No message matches older:1d. I stopped the tool plan because it took too long." | D4, D11 |
| 09-14 17:44–17:49 | "check my last 10 emails…", "Check your tools. You have access to Gmail…" | "I cannot access your emails directly … paste the text", reworded 4 times, then "The model took too long to answer." ×3 | D7, D4 |
| 09-14 16:54 | "open Claude" (Claude Code) | "The tool computer.open_app did not run: Nothing is connected that can do “No application named Claude Code is installed.”" ×2 | D5 |
| 09-14 14:28 | "What is on your to-do list for today?" | "I don't have access to your calendar or tasks." then 4 more denials | D7 |

Since the 09-14 and 09-22 turns, several guards have been added (grounding, rebuttal, pending intent, tool-shape gate). They cover some phrasings but none of the structural causes above.

---

## 4. Architectural recommendations

1. **One capability manifest per turn as the single source of truth.** Build `AgentCapabilityManifest(turn)` once, from the registry (native + MCP + Composio), switches, consent, the reader (cloud or local) and live readiness (gws auth, Accessibility, index built). Everything reads it: the planner's schema, the grounding prose, the voice inventory, the refusal guard, the execution allowlist, and the "what can you do" answer. Delete `RealtimeToolSelection.allowedIDs` as a literal and replace it with risk-class policy over the manifest. Subset by **namespace intent**, never top-k keywords.
2. **Native or constrained function calling, not prose tags.**
   - Apple FM: use the FoundationModels `Tool` protocol with `@Generable` arguments (the app already uses `@Generable` for voice routing).
   - llama: reuse `GBNFGrammar` with a tool-name enum and per-tool argument objects. `LocalModelFunctionCallProposer.grammar(for:)` (`FunctionCalling/LocalModelFunctionCallProposer.swift:187-198`) already does this for meetings. Apply the model's own chat template.
   - OpenRouter: use the OpenAI `tools` field.
   - Result: parse failures, unknown names and malformed arguments become impossible rather than turn-ending.
3. **One planner, no separate header pass.** The planner answers directly when no tool is needed. On voice, keep Apple FM's structured router for latency, but route any *capability-shaped* or *contradicted-denial* answer to work. The deterministic gates may only add routes.
4. **An error-repair loop.** Return recoverable tool errors to the model as structured results (`{"error": "not_found", "hint": "apps named like 'Claude': Claude, ChatGPT"}`), with at most 2 repairs per turn. End the turn only on user or policy denial. Never answer "requested an unavailable tool". Map the name through `ToolRouter`, or show the model the valid list.
5. **Honest degraded mode.** When the configured model is missing, name the fallback in one sentence. Size the prompt to the actual reader (Apple FM 4K: fewer tools, compact grounding, capped results). Budget per round, not per plan. Measure with a real-model harness: add `--selftest-toolloop-live` that runs about 30 canonical requests ("what's on my calendar", "summarize my last 5 emails", "remind me at 9 to…", "what did we decide in the last meeting", "open youtube and search cats") on whatever model resolves, and fails on any refusal, timeout or wrong tool. Every current tool-loop self-test uses a scripted fake, which is how all of the above coexists with `TOOLLOOP_OK`.
6. **Confirmation state that outlives a worker.** A worker whose final answer is a question ("Shall I set it for 10 pm?") should leave a typed pending action (tool + arguments). The next "yes", "okay" or "do it" executes it through the approval card instead of starting a fresh model turn or being treated as noise.
7. **Data tools that fit the questions.** Email needs recent-by-default search, snippets and a read tool. Calendar needs ranges ("tomorrow", "this week"). Put meeting and knowledge questions ("what did we decide…") behind a single `search_knowledge`, always exposed when the index is on.
