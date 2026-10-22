# D — Agent answer quality and proactivity (read-only analysis, 2026-09-23)

> **Historical model assumptions — revised 2026-09-30:** this completed plan/audit
> preserves its dated measurements and implementation history. For new work, follow
> the [independent-role/shared-file contract](../../in-progress/SHARED-BRAIN/00-README.md): Meetings, Agent and cleanup
> may use different appropriate models; exact verified artifacts are reused, with
> workload-specific consent and request ownership. Agent-only file selection,
> universal model defaults and deletion based only on the Agent are superseded.
> MiniCPM cleanup + Apple guard/fallback is concurrent work, not evidence that this
> historical build used it. Re-measure quality/latency on the actual current engine.

Scope: which model answers, what it is told, what context it gets, what makes it speak
unasked, and what the stored turns show. Latency, tool plumbing and concurrency belong to
other slices; I name them only where they decide whether an answer exists at all.

Token figures are estimates at about 4 characters per token, measured from the source strings
and from this machine's own `persona.md` and memory. No source files were edited.

---

## 0. The headline, in four facts

1. **Right now the typed Agent has no working model.** The two most recent turns on this Mac
   (`agent-conversation.json`, 21:02Z and 21:03Z today) are `Hi` → *"The model could not
   answer: Inference could not start."* The chain behind it:
   - `modelRoles.agent = installed:ggml-org/gemma-4-E4B-it-GGUF/mtp-gemma-4-E4B-it-Q4_0.gguf`.
     That file is the **59.7 MB MTP draft head**, not the model. `library.json` lists it as
     the only installed model, and it claims 7.5 B parameters.
   - `modelLibrary.postDownloadPolicy = switchDeleteOld`. The post-download check
     (`ModelLibraryStore.applyPostDownloadPolicy` → `NotesModelRuntime.prepare()`,
     `NotesModelRuntime.swift:334`) only *opens* the weights. llama.cpp opens a draft head
     without complaint and only fails later, when it builds a context. So the head passed
     the check and the previous working model was deleted. `lastUsedAt` shows the sequence
     Qwen3.5-4B → MiniCPM5-2B → mtp head, and `Models/` now holds no usable LLM at all.
     `prepareForConversation` (`:347`) does a real one-token decode and would have caught it.
   - Source now marks the head as auxiliary (`ModelFitEstimator.isAuxiliaryGGUF`). But
     `ModelRoleStore.provider(for:)`, `ModelRoleStore.swift:573`, still guards with
     `InstalledModelLibrary.shared.model(withID:)`, which searches **all** files, auxiliary
     ones included, rather than `usableModels`. Even with the fix, the typed path falls
     through to the built-in Gemma 4 E4B, which was never downloaded, and then to Apple
     Foundation Models.
2. **Every path that answers a question lands on Apple's ~3 B on-device model (4,096-token
   context) or on nothing.** The voice frontend is always Apple FM. The fallback for
   voice work and typed turns is Apple FM. The configured cloud model
   (`openRouterAgentModelID = liquid/lfm-2.5-2.6b:free`) is a 2.6 B free model, and it is
   reachable only for "then"-sequenced multi-step requests, and only behind
   `knowledgeGraphCloudConsent`, which is off.
3. **The typed first pass is capped at 112 output tokens** (`RealtimeAgent+ToolLoop.swift:414,418`),
   with a ~1,400-token system prompt that says "Answer briefly" and "be concise". The user
   chose `agentResponsiveness = deep` (500 tokens), but that setting only reaches the
   "ask the model …" path (`RealtimeAgent.swift:643`), never the path that answers typed
   questions.
4. **Nothing proactive is actually configured on this Mac.** There is no
   `agent-schedules.json` and no `agent-goals.json`, so there are zero routines, triggers or
   goals. No meeting folder has a `proposals.json`. The morning-digest and podcast templates
   have **no production call site**, which is the AGENTS.md "finished feature with no call
   site" trap. Every proactive mechanism either needs the user to dictate it first, or
   produces a silent approval card.

Also relevant: Google Workspace **is** signed in. `gws auth status` reports
`has_refresh_token: true` with 21 scopes, including Gmail, Calendar, Drive and Docs. The
AGENTS.md line "`gws auth status` reports no credentials" is stale. The data sources are
there; the brain and the instructions are what fail.

---

## 1. Which model answers, per path, and how big its prompt is

The model column shows what this machine's settings resolve to today. "Installed build" is
the behaviour recorded in the logs. "Current source" is what the tree would do.

| Path | Stage | Model that answers here | System prompt (est.) | Other input | Output cap |
|---|---|---|---|---|---|
| **Voice conversation** (`VoiceConversationCoordinator`) | Route | Apple FM, always (`LocalVoiceFrontend.streamSplitDecision`) | `routeRules` 1,133 ch ≈ **280 tok**; no persona, grounding or inventory | **latest utterance only**: `history: []` (`LocalVoiceDecision.swift:94`) and system messages stripped | 64 tok (structured) |
| | Answer | Apple FM ~3 B, 4,096 ctx | persona **short card**: this user's is 2 lines ≈ 105 ch. Plus compact grounding ≈ 450, `answerRules` 743, memory ≤ 300 (profile only), inventory ≤ 1,650, playback ≤ 420 → ≈ **1,000 tok** | history ≤ 1,400 ch; work status ≤ 5 jobs × 1,250 ch | 256 tok |
| **Voice work** (after "I'm on it.") `runVoiceObjective` → planner | Planner | `AgentModelRouting.provider(voice: true)` is hard-pinned to `.appLLM` (`ModelRoleStore.swift:727`). No usable GGUF, so it falls back to Apple FM | persona full 1,688, grounding ≈ 850, planner rules 2,643 + voice 474, memory ≈ 270 (cap 3,400), date/file line ≈ 300, **24-tool catalogue ≈ 4,000**, skills ≤ 1,200 → ≈ **2,700–3,500 tok** | conversation ≤ 2,500 ch (ctx < 8 k), memory grounding, request, accumulated results → round 1 ≈ 3,400 tok, round 2 ≈ 4,000+ | 256 tok/round; 120 s budget |
| **Typed Agent pane** `handle` → `.toolLoop` → `runModelTurn` | First pass (`<answer/>` vs `<use_tools/>`) | Role *agent* → installed mtp head. **Installed build:** "Inference could not start". **Current source:** built-in (not downloaded) → Apple FM | persona 1,688, grounding ≈ 850, `voiceRoutingRules` 2,745, memory ≈ 270 → ≈ **1,400 tok** | chat history ≤ 2,500 ch ≈ 625 tok; user message + relevant memory | **112 tok** |
| | Planner | same provider | same as the voice planner, without the voice addendum ≈ 2,600–3,400 tok | same | 256 tok/round; **18 s** total budget for a local model (`:798`) |
| "Ask the model …" (`answerLocally`) | — | role provider | `localModelSystem` | — | `localAnswerTokenBudget` (deep = 500) |
| **Meeting live** — Needle watcher | Proposal | Needle (`needle3`, 35 MB resident `--serve`), fallback to the local model | curated ≤ 8 tool schemas | 90 s mic window | card only |
| **Meeting live** — `AgentService` live pass (`:615`) | Proposal | `ModelRoleStore.provider(for: .agent)` → same broken chain | persona + grounding + meeting rules 2,304 ch + memory 600 + tool block | last ~2 min | ≤ 3 cards |
| **Post-meeting** `MeetingAgent.proposals` | Proposal | as above | same, plus review (notes + transcript + brief) | whole meeting | ≤ 3; "often zero" |
| **Scheduled routine** `ScheduledRunner` | Run | `schedule.model = auto` | persona + grounding + 811 ch rules + memory 3,400 + catalogue | none | "at most three sentences" |
| **Voice library question** `answerFromKnowledge` | Ask | `LLMProviders.resolve(.appLLM)` → Apple FM | persona + grounding + rules ≈ 1,000 tok | **up to 20 passages × 700 ch ≈ 3,500 tok. Not fitted to `contextTokens`**, so it overflows 4,096 in later rounds | 512 tok |
| Typed library question | — | not routed to `KnowledgeAsker`; left to the planner | — | — | — |

**Reading of the table.**
- The only stage with room to think, the planner, carries about 3,000 tokens of fixed
  prompt on a 4,096-token model. It then gets 256 tokens to answer and, for typed turns,
  18 seconds.
- The stage that answers most questions, the first pass, has a 112-token ceiling.
- The voice answer stage hears **none of the user's persona beyond two lines**. It also
  cannot do anything; see §2.

Evidence the model tier is the limit:
- `portrait-insights.json` (MiniCPM5-2B, today 18:43Z) stored JSON fragments as "insights",
  for example `"text": "\"name\": \"memory.remember\","`.
- 2026-09-23 06:37: *"name="reminders">"* was returned as the reply.
- 06:39: *"name="search_knowledge"> name="query">user …"* was returned as the reply. That is
  tool-call syntax leaking out as prose.

---

## 2. Prompt defects (quoted)

### 2.1 Contradictory identities: up to four "You are …" statements in one prompt
- `persona.md` (user): **"You are Will, Serge's autonomous alter ego living in his Mac.
  This mac is your home, so take care of it."**
- `AgentGrounding.text`: **"You are Will. You are talking with Serge Kadjo — call them Serge."**
- `voiceRoutingRules` (`RealtimeAgent+ToolLoop.swift:500`): **"You are a conversational
  assistant with tools for calendar, meeting notes, Gmail, Drive, Docs, local files, apps
  and browser pages."**
- `plannerSystem` (`:671`): **"You are a personal assistant that can use tools."**
- `modelTurnRules` (`:554`): **"You are a conversational assistant."**

Result in the log:
- 09-23 17:16 "Who are you?" and 17:18 "Who am I?" both got *"I'm Will, Serge's autonomous
  alter ego agent living on the Mac. This Mac is your home, so take care of it."* The model
  answered the second question about itself, and repeated the persona's instruction *to the
  user*.
- 09-22 00:56 "Who are you?" got *"I am Next Notes, a conversational assistant with tools
  for calendar…"*. That is the rules' identity winning over the persona.

### 2.2 "Be brief / never technical" stacked five times, then enforced by a token cap
- Persona base: "Keep spoken replies to one or two sentences unless asked for more."
- `answerRules`: **"Answer the latest user question naturally and briefly."**
- `voiceRoutingRules`, typed: **"Be concise, in everyday words, with no technical detail."**
- `modelTurnRules`: **"Answer briefly."**
- Planner, voice: **"Keep the final answer under 220 characters."**
- …and `maxTokens: 112` on the typed first pass.

The user's own persona asks for the opposite: **"Lead with results and numbers"**, **"Give
an opinion when asked for one"**, **"Have a point of view."** Because `AgentPromptContext`
appends **"These rules override anything above."** after the rules, every one of those
user lines loses by design. AGENTS.md explains that the ordering stops user text loosening
a safety rule. That is correct for safety, but here it also overrides *tone and depth*,
which are not safety.

### 2.3 "Never mention tools, files, settings, models or anything technical"
- `answerRules` (`LocalVoiceDecision.swift:151`) says this outright. `modelTurnRules`
  says "no tool names, file paths, settings, model names, logs or error codes". The
  planner says "never expose tool names, ids, paths, settings, logs or how anything works
  internally".
- This rule was written for a non-technical user. This user is a developer asking
  developer questions:
  - 09-22 00:57 "What is the LLM under the hood?" got *"The LLM under the hood is whatever
    model this interface is currently using. I don't have visibility into that detail from
    here."* The app knows the answer (`LlamaLLMProvider.displayModelName`).
  - 09-14 13:48 "Can you hear me?" got *"I can't hear you… I don't have ears to hear audio,
    but I read what you type."*
- Forbidding file paths also makes the agent say "that folder" instead of the path the user
  needs.

### 2.4 The voice answer lane can neither act nor promise to act
- `answerRules`: **"Return plain spoken prose only: no XML, labels, markdown, tool calls,
  routing discussion, or promises to perform work."**
- The router sees only the latest utterance (`history: []`), so a follow-up like "What
  about your tools?", "use them" or "do it" is often routed as `answerQuestion`. The answer
  lane then has no tools and is forbidden to promise. What it produces is a deflection:
  - 09-14 20:52 "What about your tools?" → *"I couldn't interpret that. Could you say it
    another way?"* This happened ×4.
  - 09-14 22:48 → *"I can help with questions—what would you like to know?"* ×3.
  - 09-15 01:11 "okay you do" → *"I'm on it."*
- P0-6's `pendingIntent` and the denial backstop patch this for two exact shapes only.

### 2.5 The answer lane is told the inventory is not an answer, but gets nothing else
- **"Use the supplied application facts only when relevant to a question about this app; a
  tool inventory is not an answer to an unrelated question."** Together with "Qualify
  application features needing setup or permission", this produces hedged non-answers.
- Example: 09-14 20:52 "can you list me all of your tasks, all of your capabilities…" →
  *"I don't have tasks or capabilities to list."*

### 2.6 Ask instead of act
- Planner: **"Reminders: … Restate when and what in one sentence and wait for the user's
  yes before schedule.create."** Also **"Never infer an email recipient, file path, date, UI
  element id, or browser target id."**
- The user's persona says the opposite: **"Resourcefulness before questions… Make
  reasonable decisions and continue. Ask only when a real boundary … prevents responsible
  execution."**
- Log examples of the rules winning:
  - 09-23 06:37 "Remind me tomorrow at 9 to …" → *"I don't have enough information to set
    that reminder. Could you tell me the exact name of the reminder…"*
  - 09-20 20:46 → *"Please tell me the exact name of the project or file…"*
  - 09-22 00:58 → *"…I'd need to use your email and calendar tools — would you like me to
    do that?"* The user said "yes", "use them", "i am telling you to use your tools", and got
    the same denial 4×.
  - `AgentRefusalGuard` now rebuts "I don't have access", but "would you like me to…" is
    not in its `denials` list, so an ask-permission deflection passes.

### 2.7 "If you are not sure, say so" with no tools in hand
- Persona: "If you are not sure, say so in one sentence instead of guessing." `modelTurnRules`:
  "If you lack evidence, say so plainly."
- On the first pass the model has no tools, so "not sure" becomes the answer:
  - 09-20 20:43 "What are the project I am working on?" → *"I don't know what you are
    working on. I need to check your files and history to find out."* The refusal guard
    exists because of this turn.
  - 09-14 14:28 "What is on your to-do list for today?" → *"I don't have access to your
    calendar or tasks."*

### 2.8 The persona template leaks into prompts on fresh installs
- `Resources/agent-persona-base.md:15–16` and `PersonaStore.builtInBaseText:81–82` include
  the editor hint **"Add below: the name you want the Agent to use, what it should call
  you, and anything else about how it should sound."**
- `fullPersona()` sends the whole file, so every tool-loop, meeting, knowledge and
  scheduled prompt tells the model to "add below". This user rewrote the file, so it does
  not affect him, but it affects every new install.

### 2.9 The short card throws away the user's persona
- `PersonaStore.shortCard` takes the text only up to the first blank line (`:169`). For
  this user that is the two identity lines. "Core Truths", "Voice" and "Rule of thumb"
  never reach the voice answer lane. The user does not know this, because nothing in the
  file's shape tells him.

### 2.10 Meeting assistant is written to under-propose
- `AgentPrompts.swift:24–25`: **"A follow-up nobody asked for is worse than none."**
  **"At most 3 actions. Usually one or two; often zero."**
- Every write also needs an exact transcript quote (`:40–42`).
- For approval-gated writes this is defensible. But there is no parallel lane for
  *suggestions*, such as "you promised Margaret the deck". So a meeting yields notes and
  nothing actionable. Zero `proposals.json` files exist across 6 meetings. They were
  personal calls, so zero is partly legitimate, but the design has no way to say "here is
  what you owe".

### 2.11 Routines cap their own output
- `ScheduledRunner.swift:441`: **"answer in plain language in at most three sentences."**
  `DigestTemplate` documents this as a known tension with its own multi-section format.

### 2.12 A stale hard-coded help reply
- `RealtimeAgent.capabilitiesReply` (`:456–478`) still says **"Wake from sleep when you say
  'Hey Next'"**, while the wake phrase is "Hey Will". It also advertises "use tools to …"
  and "ask the model …", which are magic phrases the planner rules say not to require.
  `resolve` no longer returns `.capabilities`, so this is mostly dead, but the audit log
  shows it served many times on 09-13.

---

## 3. Context per turn

| Context | Typed first pass | Planner | Voice route | Voice answer |
|---|---|---|---|---|
| Date / time | **no** | yes ("Today is …") | no | **no** |
| Next meeting / today's calendar | no | only via tool | no | no |
| Active app / screen | no | via tool | no | no |
| Memory | profile + notes (≈ 270 ch actual; the store holds **2 facts**) | same + "relevant" matches | none | profile ≤ 300 |
| Knowledge / graph | via tool only | via tool | none | none |
| Conversation | ≤ 2,500 ch chat history | ≤ 2,500 ch on Apple FM, 6,000 on larger | **none** | ≤ 1,400 ch, repair turns removed |
| Running jobs | no | no | status of up to 5 | status of up to 5 |

Findings:
- **History is kept across turns but is short.** 2,500 characters is 3–6 exchanges. One
  email-listing result, capped at 1,800 characters per message, fills most of it, so
  "summarise those" loses the list after one more exchange. The session resets after
  **30 idle minutes** (`AgentSessionBoundary.defaultIdleMinutes`). Compaction then keeps a
  summary of ≤ 1,500 characters, and that summary itself only gets a third of the window.
- **The voice router is context-blind.** "Yes", "use them", "that one" and "the second
  one" cannot be routed correctly without the previous assistant turn.
- **No "now" block anywhere.** The conversational lanes do not know the time, the next
  meeting or the active app. That makes in-conversation proactivity impossible ("you have
  a call with Margaret in 10 minutes"), and it forces a tool round for "what's next?".
- **Memory is almost empty.** It holds 2 profile facts: CEO of ProductFlo.io, and an
  investor-story preference. The review's `suggestions` list is empty. Most of the 58
  "activity" rows are dictionary vocabulary and meeting titles. The review ran 200 times
  and saved almost nothing. Remembering what the user tells it — a persona line — is not
  happening in practice.
- **Self-tests pollute the real stores that feed context.**
  - `agent-tasks.json` holds 9 "Self-test observe the front app" tasks.
  - `agent-audit.jsonl` holds 09-13 fixture replies ("- Send the deck to Sam",
    `mcp.fixture.echo`).
  - Between 09-23 00:54Z and 06:36Z, `agent-audit.jsonl` records 42 `memory.remember` /
    `memory.forget` tool rows and no request or reply, which looks like harness activity.
  - These rows feed routine suggestions, the memory review and task-status context. This is
    the same class of bug as the `RunLog.record` rule in AGENTS.md.

---

## 4. Graded sample of real turns

Source: `agent-audit.jsonl`, 2026-09-14 11:00Z → 2026-09-23 21:03Z, 153 user requests. The
09-13 self-test fixtures are excluded.

Automatic classification of the first reply to each request (heuristic):

| Outcome | Count | Share |
|---|---|---|
| Substantive reply (including "Yes, I can hear you" small talk) | 42 | 27% |
| Clarify / deflect ("could you…", "what would you like…", "didn't catch that") | 34 | 22% |
| Denial / refusal ("I cannot…", "I don't have access…") | 26 | 17% |
| Failure / timeout ("took too long", "could not answer", "Stopped.", "failed while preparing") | 24 | 16% |
| No reply (merged or interrupted) | 15 | 10% |
| "I'm on it." only, never followed by a result in the same exchange | 12 | 8% |

Roughly a quarter of inputs were recogniser fragments ("Am", "boys", "Hope…", "I I"), so
part of this is ASR and wake quality. Even among clean, well-formed requests the pattern
holds.

Hand-graded, clean requests only:

| When | Request | Reply (abridged) | Grade |
|---|---|---|---|
| 09-14 11:29 typed | What's on my calendar for today? | Real 3-item agenda | ✅ answered |
| 09-14 11:16 voice | What's the content of my calendar for today? | agenda for **2023-10-27**, then "Still listening", then "stopped the tool plan" | ❌ wrong date, timeout |
| 09-14 14:28 voice | What is on your to-do list for today? | "I don't have access to your calendar or tasks." | ❌ false denial |
| 09-14 15:31 voice | check my emails … related to Ryan Cajo | `search_email "from: anyone"`, then "stopped the tool plan because it took too long" | ❌ bad query, timeout |
| 09-14 17:41–17:49 voice | summary of my last ten emails (5 attempts) | "cannot access your emails directly… paste the text" ×4, "took too long" ×3 | ❌ denial loop |
| 09-14 20:52 voice | can you list … all of your capabilities? | "I don't have tasks or capabilities to list" | ❌ evasive |
| 09-14 20:53 voice | What are the list of tools that you have? | "I couldn't interpret that." | ❌ deflect |
| 09-15 01:12 typed | Check my email, check the last email and then do a summary | `search_email "older:1d"` → "No message matches… stopped… too long" | ❌ wrong query |
| 09-15 21:49 voice | open youtube on google chrome | "I'm on it." → "YouTube has opened" | ✅ (after 3 tries) |
| 09-19 23:04 voice | can you open another note for me | "I cannot open a new note. I do not have the tool…" | ❌ false denial (`create_doc` exists) |
| 09-20 20:43 typed | What are the project I am working on? | "I don't know… I need to check your files" | ❌ refusal instead of search |
| 09-20 22:05 typed | What can you do? | "The model could not answer: The model is not downloaded." | ❌ no model |
| 09-22 00:57 typed | What is the LLM under the hood? | "whatever model… I don't have visibility" | ❌ evasive (rule 2.3) |
| 09-22 00:58–01:01 typed | Summarize my last emails and list tomorrow's events / yes / use them / "I am telling you…" | same "would you like me to do that?" ×4 | ❌ ask-instead-of-act loop |
| 09-22 19:15–19:17 voice | fragments of a real-life conversation (ambient) | therapist-style "sounds like you're feeling a lot" ×4 | ⚠️ answered ambient speech; the persona's "unwell/grieving" rule over-fires |
| 09-23 06:37 typed | Remind me tomorrow at 9 to … | "I don't have enough information… exact name of the reminder" | ⚠️ reasonable, but no draft offered |
| 09-23 06:39 typed | Make a document that summarizes everything you know about me | `name="search_knowledge"> name="query">user …` | ❌ tool syntax leaked as reply |
| 09-23 17:18 typed | Who am I? | "I'm Will, Serge's autonomous alter ego…" | ❌ wrong subject (§2.1) |
| 09-23 17:28 typed | what can you do? | 444-char capability list | ✅ |
| 09-23 21:02/21:03 typed | Hi / hi | "The model could not answer: Inference could not start." | ❌ no model |

Clean-request score: **3 fully useful out of 20**. The failures cluster into four causes:
1. No or wrong model, the most recent and total failure.
2. The first pass denies or deflects instead of routing to tools.
3. The planner times out (18 s typed / tool budget) or writes a poor query (`"from: anyone"`,
   `"older:1d"`, 2023 dates).
4. The answer lane can't act, and the router has no history.

**Proactive turns found in the log: zero.** Nothing in `agent-audit.jsonl` is
agent-initiated except self-test fixtures and one background-task result delivery.

---

## 5. Proactivity inventory

| Mechanism | Default | This Mac | Trigger | Reaches the user how | Suppressors / caps | Gap |
|---|---|---|---|---|---|---|
| `FunctionCallWatcher` (Needle) | **on** (`FunctionCallStore` isEnabled default true) | on, Needle installed | debounced **mic-track** finals in meetings; silenced whenever the sentence was addressed to the agent (`noteUserTurn`) | approval **card** on the island via `PermissionGate`; never spoken | ≤ 1 outstanding, ≤ 3 per 10 min, card withdrawn after 180 s, ≥ 12 chars, 20 s cooldown after an agent turn, grounding filter | Only "you asked for X, do it?" for write tools. No read-and-tell ("you mentioned the Q3 deck — here it is") |
| `AgentService` live meeting pass | **off** (`agentEnabled` and `agentLiveDuringMeeting` both default false) | both on | candidate actions from `MeetingContextStore` | card, `announce: true` | transcript-quote evidence, `MeetingActionReconciler`, "often zero" | runs on the broken agent-role provider |
| `MeetingAgent` post-meeting proposals | off (`agentEnabled`) | on | notes ready | card and notification; `proposals.json` | ≤ 3, evidence quote, "worse than none" | 0 proposals across 6 meetings; no "what you owe" summary |
| Reminders / routines (`AgentScheduler`) | schedules on | **0 schedules** | user dictates `schedule.create` and must say yes | notification; spoken only "whenPresent" | quiet hours 21:00–08:00, `NOTHING_TO_REPORT` silence token, ≤ 3 sentences | nothing is created unless asked, in an exact shape |
| Triggers (`meetingStarting`, `notesReady`, `callStarted`) | plumbing on | **0 configured** | only as a user-created routine | same as routines | 5 min grace, etc. | the natural pre-meeting brief exists as plumbing but no default instance |
| Morning digest / podcast templates | — | — | **no production caller** (only `DigestSelfTest`/`PodcastSelfTest` call `createArguments()`) | — | — | dead feature; no onboarding offer, no UI entry |
| Goals + nudges | on when created | **0 goals** | user creates | reminder notification | "the model never moves a goal" | never suggested |
| Routine suggestions (`RoutineSuggestions`) | on | 0 suggestions | same request on ≥ 3 days | **shown once, not spoken**, after the first answer of a later session, plus the Ideas view | once per key | too narrow to ever fire in practice |
| Action-item reminders (`ActionItemReminders`) | UI only | — | Knowledge ▸ decision thread | a row in `DecisionThreadView` | the user must open that screen | owed items never pushed |
| Portrait | 7-day pass | drafts are JSON garbage (MiniCPM5-2B) | cadence | review list | nothing saves unreviewed | model too small |
| Memory review | after each ended conversation | 200 runs, 2 facts total | conversation end | silent | "already remembered", low confidence | memory barely grows |
| `VoiceAnnouncementQueue` | on | — | a background voice job finishes while the session is open | **spoken**: first 2 clauses and ≤ 300 ch, otherwise *"There's an update from your background task. The details are in the conversation."* | only if the session is active and the user doesn't have the floor | the only real "speaks unasked" path, and only for work the user started |
| Wake word | off by default | on, "Hey Will" | user speaks | — | 17/24 hit rate at the shipped sensitivity | the prerequisite for any voice proactivity is itself unreliable |
| Island notices | on | on | armed meeting, proposals, replies | visual | — | no agent-authored notice ("heads-up: …") |

**What a proactive assistant would do here that this one doesn't.** Every item below has
plumbing already in the tree.
1. **Pre-meeting brief.** About 5 minutes before a calendar event: "Call with Margaret
   in 5 minutes. Last time you agreed to send the safety-light pricing; that's still open."
   `ScheduleTriggerOccurrence.meetingStarting` is already published each tick, and
   `NotesService`'s `MeetingNotesBrief` already assembles memory, decisions and past
   passages for that meeting.
2. **Post-meeting wrap spoken or notified**, not just filed. "Notes are ready. You owe Dad
   the DIKAD numbers by Friday. Want me to draft the email?" This uses `ActionItemReminders`
   and the `notesReady` trigger.
3. **Morning digest offered once**, during onboarding or on the first morning the pane
   opens. The template exists and only needs a caller and a yes.
4. **Owed-item nudges.** Commitments the knowledge extractor found with the user as owner
   and a date should become reminders, with a one-time consent.
5. **Unanswered-email watch.** "You asked me about Ryan's school email on Monday. He replied
   an hour ago."
6. **Progress narration** on long background jobs. VoiceAnnouncementQueue speaks only at the
   end today; a milestone sentence at ~15 s would help.
7. **A next step after every answer.** "Want me to put those three events in a doc?" The
   persona asks for this, but the answer lane is forbidden to promise work.
8. **"While you were away"** when the pane opens or the wake word fires: new mail from
   people in today's meetings, finished jobs, pending cards.

---

## 6. Ranked improvements

### P0 — give it a brain that can answer
1. **Verify a download by generating a token, not by opening the file.** In
   `applyPostDownloadPolicy`, use `prepareForConversation` (or any one-token decode) instead
   of `prepare()` before `switchDeleteOld` deletes anything
   (`ModelLibraryStore.swift` ~`:575`, `NotesModelRuntime.swift:334/347`). *(The plumbing
   slice may already own this. It is listed because it is why the agent answers nothing
   today.)*
2. **Stop an auxiliary file from winning a role.** In `ModelRoleStore.provider(for:)`
   (`ModelRoleStore.swift:573`), guard with `usableModels.contains(where:)`, not
   `model(withID:)`. Also normalise a stored `modelRoles.agent` that names an auxiliary file
   back to `.builtIn` on launch.
3. **Pick a real default brain for typed turns and background voice work.**
   - Today everything collapses to Apple FM at 4 K context.
   - Recommended: when an online model is configured, route typed Agent-pane turns and
     voice *background* work (after "I'm on it.", where a network round trip does not break
     conversation) to it, behind its **own** consent. Today the only cloud gate is
     `knowledgeGraphCloudConsent`, which is the wrong consent (`ModelRoleStore.swift:735`,
     `RealtimeAgent+ToolLoop.swift:765`).
   - `AgentModelRouting.provider(voice: true)` (`:727`) pins background voice work to
     `.appLLM` even though it is not real-time. Pin only the conversational frontend.
   - The configured OpenRouter model `liquid/lfm-2.5-2.6b:free` is no better than Apple FM.
     Recommend a capable model in the Models UI copy.
   - Locally, the 4.98 GB Gemma 4 E4B built-in needs ~9 GB free; the log shows 10.6 GB free
     today.

### P1 — let it answer fully
4. **Remove the 112-token cap on the typed first pass** (`RealtimeAgent+ToolLoop.swift:418`).
   Use `agentResponsiveness.localAnswerTokenBudget` for typed turns. Keep 112 only for voice,
   if at all; the voice addendum already asks for 1–2 sentences.
5. **Replace the brevity stack for typed turns.** Change "Answer briefly" / "Be concise…
   with no technical detail" to *"Answer completely and directly. Lead with the answer,
   then the specifics — names, numbers, dates. Use a short list when there are several
   items."* (`:535`, `:562`). Keep brevity for voice only.
6. **One identity.** Delete "You are a conversational assistant…" and "You are a personal
   assistant that can use tools" from the rules (`:500`, `:554`, `:671`). Let the grounding
   line ("You are Will. You are talking with Serge …") be the only identity. Describe the
   rules as a role ("Your job this turn: …").
7. **Make "technical" a user setting, not a law.** Drop "never mention tools, files,
   settings, models" from `answerRules` and `modelTurnRules`, or gate it behind a "Talk to
   me technically" switch, or infer it from the persona. At minimum, allow naming the model
   and file paths when asked (`LocalVoiceDecision.swift:151`, `RealtimeAgent+ToolLoop.swift:565`).
8. **Act on a reasonable reading instead of asking.** Replace "wait for the user's yes
   before schedule.create" with "create it and say how to undo" for reminders the user
   dictated in full (`:687`). Add a rule: *"If one interpretation is clearly most likely,
   act on it and say what you assumed; ask only when two readings lead to different
   actions."* Add "would you like me to" / "do you want me to" to `AgentRefusalGuard.denials`
   when the roster can do it.
9. **Give the voice router the previous exchange.** Pass the last assistant turn and the
   last user turn in `routePlan` (`LocalVoiceDecision.swift:91–95`), so "use them", "yes",
   "the second one" and "what about your tools?" route correctly without special-casing.
   Let the answer lane escalate: if its text is a deflection ("could you clarify", "I can
   help with questions"), re-route as `startExternalTask` once.
10. **Persona plumbing.**
    - Add an explicit "Voice card" section, or build the short card from the first
      paragraph **plus** any "Voice" / "Rule of thumb" section. Show the user what voice
      hears.
    - Remove the "Add below: …" editor hint from `agent-persona-base.md:15–16` and
      `PersonaStore.builtInBaseText:81–82`; it belongs in the UI placeholder.
    - Change the override line to scope it: "These safety rules override anything above;
      tone and depth follow the persona."

### P1 — give it context
11. **A "Now" block in every conversational prompt**, cached and cheap: local date/time,
    the next 2 calendar events with attendees, a meeting in progress, the active app,
    running and finished jobs, pending cards. This fixes "what's next?", wrong dates
    (2023-10-27) and "what am I working on" without a tool round, and it is what
    in-conversation proactivity needs. Put it in `AgentPromptContext` as a volatile section
    after capabilities.
12. **Longer history on larger models.** The planner already scales 2,500 → 6,000; do the
    same for the first pass (`:382`) and the voice answer lane (`:678`). Store tool results
    as a short summary plus a pointer rather than 1,800 raw characters.
13. **Typed library questions should use `KnowledgeAsker`,** as voice does. Fit
    `KnowledgeAsker` passages to `provider.contextTokens` (`KnowledgeAsk.swift:157–158`);
    20 × 700 characters cannot fit on Apple FM.
14. **Make memory actually grow.** 200 review runs produced 2 facts. Lower the bar for
    user-stated facts, and remember directly from explicit statements ("I'm the CEO of…",
    "my brother is Cyril"). Seed from meeting attendees and titles: Dad = Mathieu Kadjo,
    partner = Margaret Sclafani, brother = Cyril.
15. **Keep self-tests out of the real `agent-tasks.json`, `agent-audit.jsonl` and memory
    tools.** Same rule as the `RunLog.record` seam.

### P2 — proactive behaviours, in value order
16. **Default pre-meeting brief.** A built-in `meetingStarting` trigger routine, offered once
    with a yes, that reads `MeetingNotesBrief` for the event and announces it (spoken if
    present, otherwise a notification) 3–5 min before.
17. **Post-meeting wrap.** On `notesReady`, speak or notify with the top decision, the
    user's owed items and one offered action. Add a *suggestion* lane beside the
    evidence-gated *proposal* lane, so a meeting can say "you owe X" without writing
    anything.
18. **Wire the morning digest.** Offer `DigestTemplate` once, at the end of onboarding or on
    the first weekday morning the pane opens, and add it to the Routines/Ideas view.
    Relax the "at most three sentences" runner rule for templates that declare a format
    (`ScheduledRunner.swift:441`).
19. **Owed-item nudges** from `ActionItemReminders.suggestions`, pushed as reminder offers
    rather than hidden in `DecisionThreadView`.
20. **A follow-up offer after answers.** One sentence, e.g. "Want me to …?", naming a tool
    the roster has. Persist it as a `pendingIntent` so "yes" executes (the P0-6 slot exists).
21. **Progress narration.** Speak one milestone sentence for voice jobs over ~15 s. When a
    result is longer than 300 characters, speak the first sentence instead of the generic
    *"There's an update from your background task."* (`VoiceAnnouncementQueue.swift:47–48`).
22. **"While you were away"** on pane open or wake: finished jobs, pending cards, new mail
    from today's attendees.

### Where AGENTS.md decisions now hurt the product
- **"The Agent's name is never in a prompt."** Correct for the preset, but the user's own
  persona puts it there, and the rules then assert a second, generic identity (§2.1).
- **Persona-before-rules plus "These rules override anything above."** Right for safety,
  but it silently overrides the user's tone, depth and "act, don't ask" instructions (§2.2, §2.6).
- **"No technical detail or jargon" everywhere** (the persona-care evaluation pins it). This
  was written for non-technical users; for this user it produces evasive answers about the
  app itself (§2.3).
- **"On the conversational path, a deterministic gate may only add, never subtract."**
  Sound, but the router is also starved of history, so the model subtracts instead (§2.4).
- **"A follow-up nobody asked for is worse than none."** Right for writes, but with no
  suggestion lane the meeting side is never proactive (§2.10).
- **Stale facts:** "gws auth status reports no credentials" (it is signed in), and
  `capabilitiesReply` still says "Hey Next".
