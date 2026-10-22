# Agent competitor gap — 20 September 2026

> **Historical model assumptions — revised 2026-09-30:** this completed plan/audit
> preserves its dated measurements and implementation history. For new work, follow
> the [independent-role/shared-file contract](../in-progress/SHARED-BRAIN/00-README.md): Meetings, Agent and cleanup
> may use different appropriate models; exact verified artifacts are reused, with
> workload-specific consent and request ownership. Agent-only file selection,
> universal model defaults and deletion based only on the Agent are superseded.
> MiniCPM cleanup + Apple guard/fallback is concurrent work, not evidence that this
> historical build used it. Re-measure quality/latency on the actual current engine.

What the three competitor recordings show, what Next Notes actually does today (read from the
code and from this Mac's own logs, not from the roadmap), why the distance exists, and the
order in which to close it.

Read-only analysis. No Swift file was touched.

---

## 0. First, what the recordings actually are

The request named "Grok's app" and "Meta's Muse application". Three analysts watched all 112
frames independently and all three reported the same thing: **neither product appears in the
material.**

| Clip | What is actually on screen | Nature |
|---|---|---|
| v1 (65 frames, 130 s) | **"Specs" / "Specs Intelligence"** — left-nav desktop app (Home / Portrait / Corners / Goals), phone app, push notifications, smart glasses | Produced testimonial ad, played inside a YouTube tab |
| v2 (29 frames, ~58 s of a 1:46 video) | Unbranded ad; per-person named bots (Yodo, Louie, Bobby, Cartman). "Grok Bot" appears only as *content* inside a mocked LinkedIn feed for a fictional "SpaceXAI" | Edited ad |
| v3 (18 frames, 37 s) | **"Grok Bot"** wordmark, a multi-bot chat UI, one explicit **Cursor** marketing slide, YouTube "watch next" grid | Edited trailer |

Consequences that matter for planning, stated plainly:

- **These are mockups, not captures.** No timing in them is real latency. Our own numbers
  below are real; theirs are art direction. Do not target "as fast as the video".
- **We cannot verify any of it works.** Every capability below is a *claim in an ad*. The
  honest target is "a user watching our app would believe the same claim", not "match a
  shipped competitor".
- **The most useful single frame set is v1's movie-ticket sequence** (f050–f053): an embedded
  live browser view, a growing checklist of completed steps, an "Approved" pill, a budget cap
  check, and a purchase receipt. That is the clearest picture of what the user wants from us
  and it is the spine of Phase 1.
- v1 itself contains mock-data errors (seats C3/C4 on the receipt vs C1/C2 in the trace; two
  different totals on the same screen), which is further evidence it is not a real session.

**Decision needed** (see §6): accept these ads as the target, or re-source genuine screen
recordings of Grok Desktop / Meta Muse.

---

## 1. What they can do — consolidated capability map

Grouped as asked. Source clip in brackets.

### Understanding the request
- Free-form natural language, typed or spoken, no magic phrases. [v1, v2]
- Voice with environment context: at an airport, "surface my itinerary" is answered with the
  right flight, gate and walk time. [v1 f022–f023]
- Implicit requests: the assistant opens the conversation itself ("Want me to pull your Lisbon
  trip together?") rather than waiting to be asked. [v1 f054–f057]

### Planning
- Multi-step plans held over minutes: find showtime → pick showing → choose seats → check price
  against a stated cap → check out. Five dependent steps, one sentence of input. [v1 f050–f053]
- Cross-source assembly: one "trip page" built from Notes + Messages + Gmail + Slack, reduced
  to three outstanding to-dos. [v1 f012–f013]
- Learn-from-demonstration: the user records themselves doing a task once, and a
  "Learn from demonstration" button turns it into a reusable skill. [v2 0:26–0:36]

### Acting on the Mac — apps, browser, files
- Agentic web browsing inside an embedded browser view, on a live third-party site, including
  a seat-picker (a canvas-ish widget, not a form). [v1]
- Connecting accounts conversationally (Gmail, Slack, Notion, Salesforce). [v1, v2]
- Working "in the cloud on its own" against a CRM dashboard with nobody present. [v2 0:38]

### Multi-step chaining
- Sub-task hand-off between named agents in one thread: `Website Maker` builds the site, then
  @mentions `Copywriter` to fill in headlines. [v3 f005]
- Recurring routines: "daily standup digest, weekdays 9am PT, pulling from a Notion doc",
  confirmed back to the user. [v2 0:38–0:44]

### Showing progress
- **A live step checklist.** Each completed step becomes a line with a checkmark, in the user's
  words ("Chose two seats together, middle block — C1 and C2"), with the in-progress step
  visible at the bottom. [v1 f050–f053]
- **An embedded live view** of what the agent is driving, labelled "Browsing". [v1]
- A status pill ("Approved") pinned top-right for the whole run. [v1]

### Asking permission
- Three distinct surfaces, chosen by context: full-screen push notification (Yes / Not now),
  a native OS permission sheet (Don't Allow / Allow), and inline chat-card buttons
  (Yes handle it / I've got it). [v1]
- **Progressive** — Gmail is asked for conversationally when it is first needed, and the
  Calendar TCC dialog fires only at the moment context is being built, not at onboarding. [v1]
- A budget cap is treated as a checkable precondition, not a prompt instruction. [v1]

### Results and artifacts
- A purchase receipt. A "trip page". An assembled deck. Each is a *thing that persists*, not a
  sentence in a chat log. [v1, v2]

### Voice
- Speech in, synthesized speech out, **always paired with a readable card** — never voice-only.
  Mute/speaker controls visible. A persistent "AI can make mistakes" line in the same position
  across surfaces. [v1]

### Memory and personalisation
- **"Portrait"**: history mined into narrative behaviour insights ("you've texted your mom
  every Sunday for four months — even the week you had three job interviews"). Memory as prose,
  not a settings page. [v1 f036–f038]
- **"Corners"**: life areas auto-organised into cards, each carrying one fresh fact. [v1 f040+]
- A remembered nut allergy "from March" surfaced inside a dinner suggestion. [v1 f014–f017]
- Apple Health pulled in live to answer a marathon-training question, ending in two one-tap
  actions. [v1 f043]

### Speed
- Nothing measurable. Edited ad, cuts every ~2 s.

### Recovery from errors
- **Nothing shown.** Not one failure, retry, or "that didn't work" appears in 112 frames. This
  is the single most important thing to remember: *we are not behind on recovery, we are
  behind on never needing it in the demo.*

---

## 2. Where we are — honest per-capability status

Reliability notes come from `~/Library/Application Support/Next Notes/{agent-audit.jsonl,
agent-conversation.json, agent-tasks.json, metrics.jsonl}` read today.

### Understanding the request

| Capability | Status | Files | Reality |
|---|---|---|---|
| Free-form text in | **Have** | `Agent/RealtimeAgent+ToolLoop.swift` (`runModelTurn`), `UI/Agent/AgentView.swift` | Works. The 20:43 text turns answered in 6–7 s. |
| Free-form voice in | **Partial** | `Activation/**`, `Agent/RealtimeAgent.swift`, `Core/DictationController.swift` | ASR is the weak link. The log contains `"hey win"`, `"Hey we"`, `"boys"` (for "voice"), `"Am"`, `"can you also nothing get to my folder to my document folder in open next project"`, `"note the four days called next note"`. The planner then reasons over that. |
| Wake word | **Partial → unreliable** | `Activation/WakeWord/SherpaKeywordSpotter.swift`, `WakeWordKeywords.swift`, `WakeWordVariants.swift`, `WakeWordTuning.swift`, `WakePhraseConfirmation.swift` | Three `kind: "wake"` events in the entire audit file (09-18, 09-19, 09-20). Zipformer KWS with ARPAbet variants and per-variant thresholds is real engineering, but the phrase is reaching ASR as "hey win"/"Hey we" — consistent with the user's "wake word often fails". Nothing measures miss rate. |
| Environment context in voice | **Missing** | — | No camera, no screen understanding fed to a voice turn. |
| Proactive opening ("want me to…") | **Missing** | `Agent/Schedules/*` exists; no proactive conversational offer | `RoutineSuggestions.swift` proposes routines, not actions. |

### Planning

| Capability | Status | Files | Reality |
|---|---|---|---|
| Multi-round tool planning | **Have (bounded)** | `Agent/AgentToolLoop.swift`, `RealtimeAgent+ToolLoop.swift` (`runPlannedToolLoop`) | Hard caps: 4 rounds / 4 calls on `balanced`, 8/8 on `deep` (`Support/Settings.swift:79–91`). Repeat-call detection, dedupe by argument signature, budget accounting. The machinery is good. |
| A five-step dependent plan surviving to completion | **Missing in practice** | same | **No log line anywhere shows more than 2 tool calls in one turn.** The longest real chains are `browser.navigate` ×1. `agent-tasks.json`: every task has `artifacts: []` and a one-sentence result. |
| Cross-source assembly (trip page) | **Missing** | `Knowledge/HybridSearch.swift`, `GraphStore.swift`, `Files/FileIndex.swift` exist | The retrieval substrate is there (8,796 files indexed, knowledge graph, hybrid search). Nothing assembles a multi-source artifact. |
| Learn-from-demonstration | **Missing** | `Agent/Skills/SkillLibrary.swift` reads pre-written skills (177 found) | No recorder, no generalisation. |

### Acting on the Mac

| Capability | Status | Files | Reality |
|---|---|---|---|
| Open app / URL / focus | **Have** | `Computer/ComputerToolExecutor.swift`, `Agent/AgentDirectIntent.swift` | Works, and `AgentDirectIntent` now bypasses the planner for exactly these. Real success: 21:50:39Z `browser.navigate`. |
| Click / type by accessibility id | **Partial** | `Computer/AccessibilitySnapshot.swift` (80-element cap), `ComputerToolExecutor.swift` | Honest about stub trees. But **no screenshots ever**: the file header says *"Accessibility first, screenshots never"*. Any app with a canvas, a web view without AX labels, or a custom control is invisible. |
| Browser automation | **Partial** | `Computer/BrowserExecutor.swift`, `BrowserCDPClient.swift` (604 lines), `BrowserToolExecutor.swift` | CDP when Chrome runs with `--remote-debugging-port`, else AX. `BrowserExecutor.swift:9` — *"Vision is reserved and is not implemented"*. A seat-picker is out of reach. |
| Files | **Have** | `Knowledge/Files/FileIndex.swift`, `FileIndexTools.swift`, `Agent/Tools/FilesystemTools.swift` | 8,796 files indexed. `filesystem.find` / `filesystem.reveal` / `search` / `read` / `write` all registered and allowlisted. |
| Shell | **Have** | `Agent/Tools/ShellTools.swift` | Gated. |
| Google Workspace | **Have (untested)** | `Agent/WorkspaceTools.swift`, `GoogleWorkspaceCLI.swift` | **No approved tool call has ever actually sent anything, from any workstream** (`roadmap/done/FEEDBACK-2026-09-19-STATUS.md`). No credentials connected. |
| Codex computer-use hand-off | **Partial, never exercised** | `Agent/Backend/CodexComputerUse.swift` | Honest probe, one approval, `codex exec`, `--sandbox read-only`. We cannot sit between Codex and each click. **No real click has gone through it.** |
| Unattended cloud execution | **Partial** | `Agent/Schedules/ScheduledRunner.swift`, `AgentScheduler.swift` | Real design: `.scheduled(scheduleID)` authority, `allowedTools`, anything above a read becomes a draft receipt, `NOTHING_TO_REPORT` = silence. Local-only, on this Mac, not cloud. |

### Multi-step chaining
- **Sequential chaining: Have** (`AgentToolLoop`). **Agent-to-agent hand-off: Missing.**
- **Recurring routines: Have** — `Agent/Schedules/RecurrenceRule.swift`, `ScheduleTools.swift`,
  `UI/Agent/RoutinesView.swift`, `ScheduleNotifications.swift`. The planner is instructed to
  restate when/what/tool-ids and wait for a yes. Never run in the wild.

### Showing progress — **the biggest visible gap**

| Capability | Status | Files | Reality |
|---|---|---|---|
| Any progress at all | **Partial** | `UI/Island/IslandState.swift:90` | `case agentWorking(title: String)` — **one line of text**. `showAgentWork(title:)` overwrites it each time. |
| Step checklist | **Missing** | `Agent/Activity/AgentActivity.swift` has the *model* (kind, title, detail, progress), `AgentActivityProjector.swift` has good public titles ("Looking at Chrome…", "Clicking…") | The data type exists, the projector exists, and nothing renders a list. |
| Live view of what is being driven | **Missing** | — | No embedded browser view, no screenshot strip. |
| Stop button | **Have** | `UI/Island/IslandView.swift:403` | `Button("Stop") { state.cancelAgentWork() }`. |
| After-the-fact trail | **Have** | `UI/Agent/AgentView.swift` timeline over `agent-audit.jsonl` | It is a log, not a live trace. |

### Asking permission

| Capability | Status | Files | Reality |
|---|---|---|---|
| Per-action approval | **Have, and better than theirs** | `Agent/Permissions/PermissionGate.swift`, `PermissionBroker.swift`, `ToolCallReview*.swift`, `UI/Agent/ToolReviewCard.swift` | Review is built *before* the card is raised; blockers are counted; "2 things needed"; nothing with an unanswered field can be approved from the island. |
| Inline chat-card approval | **Partial** | `IslandProposal` (island) + `ToolReviewCard` (sidebar) | Two surfaces, not inline in the transcript. |
| Progressive OS permission | **Partial** | `Permissions.promptForAccessibility()` called lazily in `performComputer` | Onboarding still front-loads most grants. |
| Budget cap as precondition | **Missing** | — | No numeric precondition concept. |
| **Correct** permission card | **Was broken, now guarded** | `Agent/FunctionCalling/FunctionCallRelevance.swift` | 2026-09-20T20:45:08Z the audit shows `permission "Add to a document" / append_doc` **approved** for the utterance "You open Google Chrome and go to youtube.com", then `tool append_doc — "Add to the Doc You open Google Chrome"`. Four independent rules plus a `no_action` abstention tool now stop it. **Not yet verified against live speech.** |

### Results and artifacts
- **Missing.** `AgentTask.artifacts` exists (`Agent/Tasks/AgentTask.swift`) and is `[]` in every
  real task in `agent-tasks.json` except one ACP run. No receipt, no assembled page, no
  "here is the thing I made" card.

### Voice
- **Have**: streaming TTS with barge-in (`Agent/Speech/*`, `AgentToolSpeechTracker`), spoken
  answers held back while a sentence could still be a false denial (`AgentRefusalGuard`),
  ≤220 chars, no URLs/IDs read aloud.
- **Missing**: the paired readable card. Voice replies land in the transcript and the island
  reply line, but there is no "here is the itinerary/receipt, and here is the disclaimer"
  surface. No persistent AI-disclaimer line anywhere.

### Memory and personalisation

| Capability | Status | Files | Reality |
|---|---|---|---|
| Facts about the user | **Have** | `Memory/NextMemory.swift`, `MemoryTools.swift`, `MemoryGuard.swift`, `Persona/AgentGrounding.swift` | `AgentGrounding` (new today) injects name, folders, index count and surfaces into every prompt, with a denial rule. |
| Editable persona | **Have** | `Persona/PersonaStore.swift` + `persona.md` on disk | The user has written a real one ("You are Will, Serge's autonomous alter ego"). |
| Knowledge graph over the user's life | **Have** | `Knowledge/GraphStore.swift`, `LifeExtractor.swift`, `Extractor.swift`, `Ontology.swift` | Decisions/people extracted from meeting notes. |
| Narrative insights ("Portrait") | **Missing** | `Knowledge/LifeExtractor.swift` is the nearest thing | Nothing produces prose insights about behaviour patterns. |
| Life areas ("Corners") | **Missing** | — | |
| Health data | **Missing** | — | No HealthKit. |
| Memory export/import | **Have** | `Memory/Portability/*` | Verified end-to-end today on Apple FM. |
| **Does it work in the moment?** | **No** | — | 2026-09-20T20:43:22Z: *"I don't know what you are working on. I need to check your files and history to find out."* — with 8,796 files indexed and `filesystem.find` allowed. 2026-09-19T23:05:57Z: *"I cannot open a new note. I do not have the tool to create new Google Docs or Notes"* — with `create_doc` in the roster. Both now have guards (`AgentRefusalGuard`, `AgentGrounding`), neither verified live. |

### Speed — measured, from `metrics.jsonl` (n in brackets)

| Metric | min | median | max |
|---|---|---|---|
| `model.load` [3] | 19.4 s | 19.4 s | 22.0 s |
| `model.prefill` [7] | 4.3 s | 16.1 s | **76.4 s** |
| `model.first_token` [7] | 4.7 s | 28.3 s | **101.9 s** |
| `ask.total` [2] | 30.5 s | — | 40.0 s |
| `agent.transcript_to_first_token` [5] | 0.4 s | 3.4 s | 5.5 s |
| `dictation.cleanup` [37] | 0.4 s | 4.2 s | 30.0 s |
| `dictation.speech_to_first_partial` [39] | 0.03 s | 1.8 s | 3.9 s |

And the documented worst case, from `Agent/AgentDirectIntent.swift`'s own header: for
*"You open Google Chrome and go to youtube.com"*, Qwen3.5-4B spent **44.78 s prefilling 3,634
tokens** before its first token; the spoken result landed **47 s** after the request, and the
next request queued **3.76 s** behind it. That is the user's "long lag between speech and
action", quantified.

Also measured from the audit: wake at 13:11:45Z → useful reply 13:12:29Z = **44 s**.
"can you open another note for me" 23:04:06Z → refusal 23:05:57Z = **111 s**.

### Recovery from errors
- **Partial.** `expectedText` / `expectedURL` verification arguments exist on click/fill;
  `ToolCallValidation.withoutInventedValues` strips placeholders; one re-plan is allowed after
  a false refusal; repeat-call detection stops loops. There is **no retry with a different
  approach**, no "that didn't work, trying X", and the user-facing failure sentence is usually
  *"I stopped the tool plan because it took too long. Remaining steps are unfinished."*
  (seen at 811127583 in the conversation log).

---

## 3. Why we are not there yet — the seven root causes

**1. A 4B local model pays the whole planning bill in prefill, every round.**
`AgentModelRouting.provider` (`Support/ModelRoles/ModelRoleStore.swift:670–673`) is
unconditional: `if voice { return await LLMProviders.resolve(preferring: .qwen35_4b) }`. Every
voice turn plans on Qwen3.5-4B. The planner system prompt is persona + rules + memory + date +
file-index sentence + skills index + the full schema of ~50 tools — 3,634 tokens, 44.78 s of
prefill on this M3/8-core/16 GB machine, **charged again on every round**. A 4-round plan is
arithmetically impossible inside the 18 s local budget (`RealtimeAgent.Limits.modelWarm`), and
even the 120 s voice-worker budget buys 2 rounds. *That is why no chain longer than 2 calls
exists in the logs.* Evidence: `model.prefill` max 76.4 s, `model.first_token` max 101.9 s.

**2. Perception is an accessibility tree, deliberately, and the demo tasks need pixels.**
`ComputerToolExecutor.swift:5` — *"Accessibility first, screenshots never"*.
`BrowserExecutor.swift:9` — *"Vision is reserved and is not implemented"*.
`AccessibilitySnapshot` caps at 80 elements and honestly reports `stub tree, 0 names` when a
window exposes nothing. The v1 movie demo requires reading a showtime grid and clicking seats
in a seat-picker. Neither is reachable through AX on a real cinema site. This is a principled
choice with a real cost, and it is the hard blocker on Phase 1 parity.

**3. ASR errors feed the planner, and the planner has no repair step.**
`"hey win"`, `"boys"`, `"Am"`, `"can you also nothing get to my folder to my document folder
in open next project"`, `"note the four days called next note"`. `AgentDirectIntent` now strips
filler including the literal word `"nothing"` (because of that exact turn), and
`AgentEntityResolver` exists — but nothing asks *"did you mean X?"* before spending 45 s of
prefill on a garbled sentence. Three of the ~10 real voice turns in the log were answered
with "what do you mean?" **after** a full planning round.

**4. Tool selection had no way to say "none of these".**
The `append_doc`-for-"open Chrome" card is the textbook case, and `FunctionCallRelevance.swift`
documents it better than I could: the background proposer was given eight tools, no browser
tool among them, and no abstention option, so it returned the nearest neighbour; `document_id`
was free text, the value was a literal substring of the utterance, so grounding passed, so
every required argument was present, so Approve was live. Fixed today with four independent
rules + a `no_action` tool. **Unverified in the wild** — that is the risk to carry forward.

**5. The work is invisible while it happens.**
One line of text (`agentWorking(title:)`) for up to 47 s. The user cannot tell a slow success
from a hang, cannot see which step is running, cannot see what was already done. The v1 demo's
entire persuasive force is the growing checklist next to the live browser. We have the data
model (`AgentActivity`) and the phrasing (`AgentActivityProjector`) and render neither.

**6. Nothing is produced that outlives the sentence.**
`AgentTask.artifacts` is `[]` in every real run. Their demo ends on a receipt and a trip page.
Ours ends on a spoken sentence in a transcript. Even a perfect run currently feels like nothing
happened.

**7. Nothing verifies the end state, so failure is reported as "took too long".**
`expectedText`/`expectedURL` are optional arguments the model is *asked* to supply. When it
doesn't, the executor has nothing to check, and the honest-but-useless
*"Remaining steps are unfinished"* is the result. There is no second attempt, no alternative
route, no "I opened Chrome but the page didn't load".

*(An eighth, smaller: permissions friction is not actually our problem — our approval model is
better than theirs. The problem is that it is spread over two surfaces and none of them is
inline in the conversation.)*

---

## 4. What to build

Model strategy, stated once and applied throughout: **local-first, cloud on explicit opt-in.**
The audience is non-technical and privacy-minded, so the default must work with no account.
The routing rule below is what I would ship.

| Job | Default | Why |
|---|---|---|
| Wake, ASR, dictation cleanup | On-device (Parakeet, Apple FM) | Already the case. Never change. |
| Intent classification / "is this a command" | Deterministic Swift + Needle (35 MB, 0.66–1.2 s measured) | Cheap, private, already downloaded |
| Conversational answer | Apple Foundation Models first, Qwen3.5-4B second | Apple FM is ~free to prefill; Qwen costs 45 s |
| **Tool planning, ≤2 steps** | Qwen3.5-4B with a *small* prompt (see P0-2) | Local, private |
| **Tool planning, ≥3 steps** | Opt-in cloud (OpenRouter), with an explicit one-time consent sheet | 4B cannot hold a 5-step plan; pretending it can is why we're here |
| Screen understanding (pixels) | Opt-in cloud vision, per-run consent, screenshot never stored | No local VLM fits this Mac's 6.4 GB free disk |
| Full computer control of a hostile UI | Codex hand-off, one approval | Already built, never exercised |

Every cloud path stays behind `KnowledgeGraphScope` consent, which already exists.

---

### Phase 0 — fix this week (reliability; no new capability)

**P0-1. Make the wake word measurable, then make it work.**
- *What*: a `--selftest-wake-live` that plays N recorded utterances of the phrase (and N
  near-misses) through the spotter and prints hit/false-accept rates; plus an on-screen
  "say it three times" confirmation in Settings that reports which pronunciation matched.
- *Why*: "often fails" is currently unfalsifiable. Three wake events exist in the whole log.
- *Files*: `Activation/WakeWord/WakeWordCalibrator.swift`, `WakePhraseConfirmation.swift`,
  `SherpaKeywordSpotter.swift`, `WakeWordTuning.swift`.
- *Effort*: M. *Risk*: low. The variant/threshold machinery is already there.
- *Verify*: `--selftest-wake-live` prints `WAKE_HIT_RATE: x/y`; fails under 0.8.
- *Model*: none.

**P0-2. Cut planner prefill from 3,634 tokens to under 800.**
- *What*: (a) rank the tool schema by relevance to the utterance and send the top 12, never all
  ~50; (b) drop the skills index from the planner prompt unless a skill actually matched; (c)
  keep the system prefix byte-identical across rounds so llama.cpp's prefix cache holds — it is
  *almost* identical today, but the file-index sentence and date are interpolated into the
  middle; move them to the tail.
- *Why*: prefill is the entire bill and it is paid per round. 44.78 s → target under 10 s.
- *Files*: `Agent/RealtimeAgent+ToolLoop.swift` (`plannerSystem`, `plannableTools`),
  `Agent/Skills/SkillPromptIndex.swift`, `Persona/AgentPromptContext.swift`.
- *Effort*: M. *Risk*: **medium — a relevance filter that drops the right tool reintroduces the
  `append_doc` failure mode.** Mitigation: the filter may only ever *add* to a fixed core set
  (browser, computer.open_*, filesystem.find/reveal, get_agenda, search_email), never subtract.
- *Verify*: extend `--selftest-toolloop-production` to assert `plannerSystem(...)` token count
  < 800 for a 12-tool roster, and add a fixture asserting "open Chrome and go to youtube.com"
  still selects `browser.navigate` with the filter on.
- *Model*: local.

**P0-3. Confirm a garbled utterance before spending a planning round.**
- *What*: when ASR confidence is low **or** `AgentDirectIntent` fails to parse **or** the
  utterance is under ~12 characters, speak one short clarifier ("Open what?") instead of
  planning. Use the existing `AgentEntityResolver` for the name/label case.
- *Why*: `"boys"`, `"Am"`, `"Take it."`, `"Okay."` each consumed a full turn and produced
  "I'm ready to help" — 4 of ~10 real voice turns.
- *Files*: `Agent/AgentTurnIntent.swift`, `Agent/AgentDirectIntent.swift`,
  `Agent/AgentEntityResolver.swift`, `Agent/VoiceConversationCoordinator.swift`.
- *Effort*: S. *Risk*: low (a clarifier is always recoverable).
- *Verify*: `--selftest-voice-turns` fixture set with the eight real garbled utterances from
  `agent-conversation.json`; assert none reaches the planner.
- *Model*: none (deterministic) + Needle for the borderline case.

**P0-4. Verify the `append_doc` fix against live speech, and make the card self-explaining.**
- *What*: run the exact 20:45:00Z utterance through the live function-call path on device and
  confirm `no_action`. Add the utterance as a permanent fixture. Then: every permission card
  shows *the sentence that caused it* ("because you said: …").
- *Why*: the fix is code-reviewed, not observed. And a card that quotes the trigger makes a
  wrong card obvious in half a second.
- *Files*: `Agent/FunctionCalling/FunctionCallRelevance.swift`, `FunctionCallSelfTest.swift`,
  `Agent/Permissions/ToolCallReviewBuilder.swift`, `UI/Agent/ToolReviewCard.swift`.
- *Effort*: S. *Risk*: low.
- *Verify*: `--selftest-function-calls` includes `browser-command-never-append-doc`.
- *Model*: Needle.

**P0-5. Replace "took too long" with what actually happened.**
- *What*: when the budget expires, report the last completed step and the step in flight
  ("I opened Chrome. I was looking for the search box when I ran out of time."). The data is
  already in `results` and `lastVerifiedResult`.
- *Files*: `Agent/RealtimeAgent+ToolLoop.swift` (`incomplete(_:)`).
- *Effort*: S. *Risk*: none.
- *Verify*: `--selftest-toolloop` fixture asserting the timeout sentence names the last tool.
- *Model*: none.

---

### Phase 1 — parity on the demo tasks

**P1-1. The "agent is working" surface. Build this first; everything else is judged through it.**

Modelled on v1 f050–f053, adapted to our island + Agent pane.

*In the Agent pane (the full surface):*
```
┌────────────────────────────────────────────────┐
│ ● Working · Buying tickets            [ Stop ] │   ← status pill, mirrors "Approved"
├────────────────────────────────────────────────┤
│ ┌──────────────────────────────────────────┐   │
│ │  live view: last screenshot / AX summary │   │   ← the "Browsing" window
│ │  of the window being driven              │   │
│ └──────────────────────────────────────────┘   │
│ ✓ Opened chrome — youtube.com                  │
│ ✓ Found tonight's 7:30 showing                 │
│ ✓ Chose two seats, middle block — C1 and C2    │
│ ◐ Checking the price against your $40 cap…     │   ← in-progress, animated
│                                                │
│ ┌ Approve ─────────────────────────────────┐   │   ← approval INLINE, not elsewhere
│ │ Buy 2 tickets · $33.50 on file           │   │
│ │              [ Not now ]  [ Yes, buy ]   │   │
│ └──────────────────────────────────────────┘   │
├────────────────────────────────────────────────┤
│ Next Notes is AI and can make mistakes.        │   ← persistent, fixed position
└────────────────────────────────────────────────┘
```
*In the island (two lines under the notch):* the current step title, a `3/5` counter, and Stop.
Clicking expands to the pane. This is the only honest thing two lines can carry — same
reasoning the `IslandProposal.needsCount` comment already gives.

*On completion:* the step list collapses into **a result card** — receipt, file, page, or
"opened youtube.com" — that persists in the conversation and in `AgentTask.artifacts`.

- *Why*: it is the single most visible difference, it makes 45 s tolerable instead of broken,
  and it makes every other bug diagnosable by the user instead of by me reading JSONL.
- *Files*: `Agent/Activity/AgentActivityStore.swift` (append steps instead of replacing),
  `AgentActivityProjector.swift` (already has the phrasing), `UI/Island/IslandState.swift`
  (`agentWorking(title:)` → `agentWorking(steps:current:total:)`), `UI/Island/IslandView.swift`,
  `UI/Agent/AgentView.swift`, `UI/Agent/ToolReviewCard.swift` (render inline in the step list),
  `Agent/Tasks/AgentTask.swift` (artifacts).
- *Effort*: **L**. *Risk*: medium — `IslandState.Kind` is pattern-matched in ~8 places
  (`identity`, `orbMood`, `title`, `isPersistent`, decision routing); changing the case shape
  touches all of them. Do it as one mechanical change with `--selftest-island` green first.
- *Verify*: `--selftest-island` asserts a 4-step scripted run renders 4 rows with exactly one
  in-progress; `--selftest-activity` asserts no chain-of-thought reaches a title
  (`AgentActivityProjector.isPublic` already checks this).
- *Model*: none.

**P1-2. Screenshots + an opt-in vision route, for pixels AX cannot see.**
- *What*: a `computer.screenshot` tool (ScreenCaptureKit, focused window only) and a
  `browser.screenshot` (CDP `Page.captureScreenshot`, already trivially reachable from
  `BrowserCDPClient`). Used **only** when `inspect_ui` returns a stub tree or the model asks
  for it. The image goes to a vision model **only** on the cloud-vision opt-in; with the
  opt-in off, the screenshot is still useful locally for the live view in P1-1 and is never
  uploaded, never written to disk.
- *Why*: root cause #2. Without it the movie-ticket demo is unreachable and so is any app with
  a canvas.
- *Files*: new `Computer/ScreenCapture.swift`; `Computer/ComputerToolExecutor.swift`,
  `BrowserCDPClient.swift`, `Agent/Tools/ComputerTools.swift`,
  `Formatting/LLM/OpenRouterLLMProvider.swift` (it already detects `input_modalities: image`,
  line 198 — the plumbing for an image message is the missing half).
- *Effort*: L. *Risk*: **high on privacy perception.** A screenshot leaving the Mac is the
  thing this audience fears most. Mitigations: per-run consent showing a thumbnail of exactly
  what will be sent; default off; a visible "sent 1 screenshot" line in the step list; never
  persisted.
- *Verify*: `--selftest-computer` asserts a screenshot is taken only after a stub tree;
  `--selftest-openrouter-contract` asserts no image part is ever built when consent is off.
- *Model*: cloud vision, opt-in. Never the default.

**P1-3. Let a long plan actually run: route ≥3-step plans away from the 4B.**
- *What*: after P0-2, estimate plan length from the first planner round. If the model emits a
  plan needing ≥3 rounds and a cloud model is configured and consented, continue there; if not,
  say so ("this needs 5 steps; on-device that's about 4 minutes — continue, or use cloud?").
  Raise `toolRoundLimit` above 8 only for the cloud path.
- *Why*: root cause #1. The caps aren't the problem; the per-round cost is.
- *Files*: `Support/ModelRoles/ModelRoleStore.swift` (`AgentModelRouting`),
  `Agent/RealtimeAgent+ToolLoop.swift`, `Support/Settings.swift` (`AgentResponsiveness`).
- *Effort*: M. *Risk*: medium — an honest "this will be slow" prompt is better than a silent
  4-minute wait, but it is friction. Show it once per session, not per turn.
- *Verify*: new `--selftest-model-roles` case asserting a 5-step fixture routes to cloud when
  consented and to the warning when not.
- *Model*: the routing decision itself is deterministic.

**P1-4. Self-verification and one retry.**
- *What*: make `expectedText`/`expectedURL` **mandatory** for click/fill/navigate when the
  destination is knowable (the planner prompt already asks; enforce it in
  `ToolCallValidation`). On mismatch: one re-inspect and one retry with the refreshed tree,
  then report the mismatch in words. Log both attempts as steps in P1-1's list.
- *Why*: root cause #7. Also, one such failure already exists in `agent-tasks.json`:
  *"Next Notes could not independently verify the effect. Inspect the target before retrying."*
- *Files*: `Agent/Permissions/ToolCallValidation.swift`,
  `Computer/ComputerToolExecutor.swift`, `Computer/BrowserToolExecutor.swift`,
  `Agent/RealtimeAgent+ToolLoop.swift`.
- *Effort*: M. *Risk*: low-medium (a retry loop must not double-execute a send — restrict
  retry to `risk <= .modify`, never `.send`).
- *Verify*: `--selftest-computer` fixture where the first click misses and the second succeeds;
  assert exactly two attempts and one reported success.
- *Model*: local.

**P1-5. A real artifact at the end of every run.**
- *What*: populate `AgentTask.artifacts` — a saved file, a URL opened, a doc id, a receipt
  summary — and render it as the terminal card in P1-1.
- *Files*: `Agent/Tasks/AgentTask.swift`, `AgentTaskManager.swift`,
  `Agent/Tools/AgentToolExecutor.swift` (return an artifact alongside `summary`).
- *Effort*: M. *Risk*: low.
- *Verify*: `--selftest-tasks` asserts a completed browser run carries a URL artifact.

**P1-6. The one-tap action card (their "Reserve bouquet" / "Add to calendar").**
- *What*: when a read tool's result implies a next action the user obviously wants, offer it as
  a single button on the result card instead of requiring another sentence. Strictly: only
  actions whose arguments are fully determined by the result the user just saw.
- *Files*: `UI/Agent/ToolReviewCard.swift`, `Agent/Permissions/ToolCallReviewBuilder.swift`.
- *Effort*: M. *Risk*: medium — this is the nearest neighbour of the `append_doc` bug. Gate it
  with the same `FunctionCallRelevance` rules.

---

### Phase 2 — beyond

- **P2-1 "Portrait" — narrative insights.** We already extract people, decisions and files into
  a graph (`Knowledge/GraphStore.swift`, `LifeExtractor.swift`). A weekly local pass that turns
  recurring patterns into two or three prose sentences, shown in the Agent pane, reviewed
  before it is saved (`Memory/MemoryReviewer.swift` already has the review UX). **L**, high
  delight, real creep-risk — it must be deletable per-insight.
- **P2-2 "Corners" / life areas.** A grouping over the existing graph. **M**.
- **P2-3 Morning digest.** `AgentScheduler` + `ScheduledRunner` + `ScheduleNotifications`
  already do the hard part; this is a routine with a fixed prompt and a card. **S–M**, and the
  single cheapest thing in the whole document relative to its demo value.
- **P2-4 Learn-from-demonstration.** Record AX events + screenshots during a user-driven task,
  generalise into a `Skill` the existing `SkillLibrary` can run. **XL**. Defer.
- **P2-5 Agent-to-agent hand-off.** We have `AgentHarnessRouter` and ACP already. **M**, low
  value for a non-technical audience. Defer.
- **P2-6 Persistent AI-disclaimer line.** Trivial, and it is in every competitor surface. Do it
  with P1-1.

---

## 5. Demo scripts — acceptance tests

Each is written as it would be spoken, with pass criteria and a target. Targets assume P0 and
P1 landed. Timings are wall clock from end-of-speech to the stated observable.

### D1 — "Open Chrome and go to YouTube" *(v1's simplest agentic act; our 20:45:00Z failure)*
1. Say "Hey Next" — island shows listening within **1.5 s**.
2. Say "open Chrome and go to youtube.com".
3. Island shows `Opening youtube.com…` within **2 s** of end-of-speech.
4. Chrome is frontmost on youtube.com within **6 s**.
5. Spoken reply names the actual outcome, not an intention.

**Pass**: no permission card mentioning a document ever appears; `agent-audit.jsonl` contains
`browser.navigate` and no `append_doc`; total ≤ 8 s.
**Scripted as**: `--selftest-function-calls` (no append_doc) + `--selftest-browser` (navigate +
verified URL) + a manual voice run.

### D2 — "What am I working on?" *(the 20:43:22Z refusal)*
1. Type or say it.
2. Agent runs `filesystem.find` / `search_knowledge` — visible as steps.
3. Answer names at least two real projects from the 8,796-file index.

**Pass**: the words "I don't know", "I cannot", "I need to check" do not appear.
**Target**: ≤ 10 s text, ≤ 15 s voice.
**Scripted as**: `--selftest-voice-grounding` + `--selftest-file-index` with an assertion on
`AgentRefusalGuard.rebuttal` returning nil for the produced answer.

### D3 — "Open a new note" *(the 23:05:57Z refusal, 111 s)*
1. Say it.
2. Agent asks **one** short question ("What should it be called?") or creates an untitled one.
3. A document exists; the result card links to it.

**Pass**: no "I do not have the tool" sentence; ≤ 12 s to the question.

### D4 — Trip assembly *(v1 f012–f013, scoped down)*
"Pull together everything about the Next Notes launch — files, meetings and notes."
1. Steps visible: search files → search knowledge → read top 3 → compose.
2. Produces a **saved markdown file** listing sources and 3–5 outstanding items, shown as a
   result card.

**Pass**: ≥ 3 distinct sources cited; the file exists on disk; `AgentTask.artifacts` non-empty.
**Target**: ≤ 60 s (cloud), ≤ 3 min with an honest on-device warning.
**Scripted as**: new `--selftest-assemble` with a fixture corpus.

### D5 — Agentic browsing with a cap *(v1 f050–f053, the flagship)*
"Find tonight's 7:30 showing of <film> near me and hold two seats under $40 — ask me before you
pay."
1. Live view + step checklist appear within **3 s**.
2. Steps accumulate: opened site → found showing → chose seats → **price $X, inside your $40 cap**.
3. An inline approval card shows the exact amount and the payment method. Nothing is bought
   without it.
4. On approval: receipt card. On "Not now": nothing happens and the agent says so.

**Pass**: the cap is checked as a step, not asserted in prose; no click happens after Stop.
**Target**: first step ≤ 3 s, plan complete ≤ 90 s, cloud + vision opt-in on.
**This is the one that requires P1-2.** Without screenshots it will fail at the seat-picker.
**Scripted as**: `--selftest-browser` against a locally served fixture page with a seat grid —
do not test against a live cinema site.

### D6 — Recurring routine *(v2's daily digest)*
"Every weekday at 9, tell me what's on my calendar and what I said I'd do."
1. Agent restates when, what, and which tools, and waits for a yes.
2. `agent-audit.jsonl` shows a run at the next slot with `scheduleID`.
3. Anything above a read arrives as a draft receipt, not an action.

**Pass**: `--selftest-routine-authority` stays green (`PermissionGate.askCount` unchanged).
**Target**: setup conversation ≤ 30 s.

### D7 — Wake word reliability *(not in the videos; it gates all of the above)*
Say the phrase 20 times across a day, in three rooms.

**Pass**: ≥ 16/20 wake, ≤ 1 false accept in 8 hours of ambient.
**Scripted as**: `--selftest-wake-live` (P0-1) plus a manual tally.

---

## 6. Decisions for the user

**1. Are these ads the target, or do we re-source the recordings?**
All three analysts independently found no Grok-desktop and no Meta-Muse UI; v1 is "Specs
Intelligence", v3 is "Grok Bot" plus a Cursor slide.
→ **Recommendation: accept them as the target.** v1's movie-ticket sequence is a clear, honest
brief and re-sourcing costs days. But know that we are benchmarking against *marketing*, so the
bar is "believable in a 30-second demo", not "survives a hostile user".

**2. Cloud vision: default on, opt-in, or never?**
Without it, D5 (the flagship demo) cannot pass, and any app with a canvas stays invisible.
With it, a screenshot of the user's screen leaves the Mac.
→ **Recommendation: opt-in, per-run consent, with a thumbnail of exactly what will be sent,
never persisted, and a visible "sent 1 screenshot" line in the step list.** Default off. This
keeps the privacy promise intact and still lets the demo exist for anyone who wants it.

**3. Cloud planning for long chains: opt-in, or do we accept 4-minute on-device plans?**
A 4B model cannot hold a 5-step plan inside any tolerable budget; the arithmetic in §3.1 is not
a tuning problem.
→ **Recommendation: opt-in cloud for ≥3-step plans, with a one-sentence honest warning when it
is off ("this needs 5 steps; on-device that's about 4 minutes").** Never silently slow.

**4. Which demo do we target first?**
→ **Recommendation: D1 → D2 → D3 first (they are our actual reported failures and cost days,
not weeks), then P1-1 the working-UI, then D5.** Shipping D5 on top of a wake word that misses
and a planner that says "I don't know what you're working on" would be building the roof first.

**5. Do we depend on Codex for computer use?**
It is built (`CodexComputerUse.swift`), honest about its limits, and **has never executed a
single real click**. It requires an OpenAI login, and we cannot sit between it and each action.
→ **Recommendation: keep it as an advanced opt-in, do not put it on the demo path.** Our own
AX+CDP+screenshot route (P1-2/P1-4) is the one we control and the one we can show approvals
for. Also worth telling the user again: `~/.codex/config.toml` on this Mac holds a third-party
API key in plain text.

**6. "Portrait"-style behavioural insights — do we want them at all?**
They are the most charming thing in v1 and the most invasive. We have the graph to build them.
→ **Recommendation: yes, but Phase 2, local-only, reviewed before saving (reuse
`MemoryReviewer`), and each insight individually deletable.** If the answer is no, say so now —
it changes what `LifeExtractor` should be collecting.

---

## 7. Addendum 2026-09-22 — post-doc failures from live logs

Read from `agent-conversation.json` (74 turns), `agent-audit.jsonl` (406),
`agent-memory-review.json` and `agent-tasks.json` on 2026-09-22. P0-1–P0-5 and
D1–D3 stand. Three new failure signatures postdate this doc and get new items
below. The memory-review rate-limit storm and auto-title memory pollution belong
to `roadmap/done/PERSONAL-AGENT.md` (M2 amendment 2026-09-22); they are referenced,
not duplicated, here.

**P0-6. Stop the model from ever being the authority on what it can do.**
- *Producer chain (read 2026-09-22):* the denial text is model-generated, not
  code — no such sentence exists in `Sources/`. Every voice turn goes
  `VoiceConversationCoordinator.respond` → `LocalVoiceFrontend` (small Apple
  model, no tools) → `VoiceFrontendEnvelope`: `.answer` is spoken verbatim,
  only `.newWork` reaches `submit` + the tool loop. Two producer defects:
  (a) the follow-up ("use them", "yes") is an ellipsis the frontend must
  resolve from conversation alone, and when it fails it answers instead of
  delegating — the original tool-shaped request is discarded, so there is
  nothing to resolve against; (b) the only deterministic shortcut,
  `AgentDirectIntent.parse` (`RealtimeAgent+ToolLoop.swift:697`), runs
  *after* the frontend has already decided — the small model is the sole
  authority on newWork-vs-answer, including for requests that name a
  registered capability outright.
- *Producer fixes:*
  1. Pending-intent slot in the coordinator: whenever the frontend emits
     `.answer` to a request naming a capability in `VoiceCapabilitySnapshot`,
     store (request text, capability) as pending. A bare acknowledgment
     ("yes", "use them", "do it") resolves deterministically to pending →
     `.newWork` with the original text. No model call, no ellipsis gamble.
  2. Deterministic tool-shape gate *before* the frontend model: if the
     utterance (or utterance + pending) names a capability verb/id from
     `plannableTools()`, route straight to `submit`. Same pattern as the
     existing direct-intent shortcut, extended from open/click/type to every
     capability. The model never gets to deny what the registry offers.
- *Backstop (kept):* cap identical denials at 1 per session; the second one
  plans a read-only round or names the blocker instead.
- *Files*: `Agent/VoiceConversationCoordinator.swift` (slot + gate +
  `frontendRequest`), `Agent/AgentDirectIntent.swift` (verb table),
  `Agent/VoiceCapabilitySnapshot.swift` (capability names source).
- *Effort*: M. *Risk*: low-medium — the gate may only ever *add* newWork
  routes for registry-named capabilities, never subtract answers (same rule
  as P0-2's core tool set).
- *Verify*: `--selftest-voice-turns` replays the 5-turn email/calendar loop;
  assert "use them" routes to `.newWork` with the original request text and
  the denial emits at most once.
- *Model*: none (deterministic).

**P0-7. Type provider errors; generate capability claims from live availability.**
- *Producer chain:* providers surface unstructured error strings and
  `finishVoiceFrontend` speaks assembled text verbatim — hence `Codex
  stopped: ERROR: You've hit your usage limit… I'll do it myself` and `The
  model is not downloaded.` reaching the user. Separately,
  `VoiceCapabilitySnapshot.make(tools:)` builds "what can you do" from tool
  *ids*, not availability states — so the agent promises Chrome control with
  no grant, coding hand-off with no CLI on PATH, and answers with no model
  downloaded.
- *Producer fixes:*
  1. Typed provider errors: quotaExceeded / modelMissing / notConfigured /
     rateLimited / timeout as codes from every `LLMProvider`, ACP and coding
     backend; one renderer at the voice boundary maps codes → user sentences.
     Raw strings stay in the log.
  2. Availability-aware snapshot: probe model resident/downloaded, CLI on
     PATH, `gws` credential state, TCC/tool grants at snapshot build; claim
     only what is live, and name the missing piece otherwise ("to check mail
     hands-free I need Workspace sign-in — open Settings ▸ Workspace?").
- *Backstop (kept):* `--selftest-toolloop` fixture asserting no reply
  contains `ERROR:`, provider URLs, or `is not downloaded`.
- *Files*: `Formatting/LLM/LLMProvider.swift` (error taxonomy),
  `Agent/Backend/*` (adopt), `Agent/VoiceCapabilitySnapshot.swift`
  (availability), `Agent/VoiceConversationCoordinator.swift` (renderer at
  `finishVoiceFrontend`).
- *Effort*: M. *Risk*: low.
- *Model*: none.

### D8 — "Summarise my emails, list tomorrow's events" *(the 2026-09-22 loop)*
1. Say it, then say "use them" when asked.
2. Agent runs `search_email` / `get_agenda` — visible as steps — or names the
   real blocker once (not signed in / no grant).
3. Summary + event list, or one honest blocker sentence.

**Pass**: the denial sentence appears at most once; `agent-audit.jsonl` shows a
read tool call or a named blocker; total ≤ 15 s voice.
**Scripted as**: P0-6 fixture + `--selftest-tools` (reads auto-run) + a manual
voice run with `gws` signed out and signed in.

---

## 8. Addendum 2026-09-22 — Muse (Meta) review: consumer UX gaps

Source: How-I-AI video review transcription (Claire Vo, ~2026-09-13): onboarding,
identity/avatar, Activity lineage, calendar first-task, PDF newsletter artifact,
Feed, Ideas, Goals, Library (docs/sites/images/video/podcasts), permissions,
browser shopping, naming ("tasks, ideas, goals, library" — never
crons/to-dos/tools/artifacts). Compared against this doc (§2–§4) and
`roadmap/done/PERSONAL-AGENT.md`. Rule used throughout: credit what exists, name
only what is actually missing.

### 8.1 Already covered — do not rebuild

| Muse praise | Our equivalent |
|---|---|
| Step checklist + live view while working | P1-1 (build it first; still unbuilt — the praise confirms the priority) |
| Result that persists (receipt, ticket) | P1-5 populated `AgentTask.artifacts` + terminal card |
| Ticket purchase with cap-as-precondition, exact-amount approval | D5 (cap checked as a step, inline approval, receipt) |
| No YOLO mode, ask at the right time | PermissionBroker + scoped grants (§P1-1 approval inline); we are ahead — keep it |
| Persistent AI-disclaimer line | P2-6 (trivial, do with P1-1) |
| Humanized step titles, never tool ids | `AgentActivityProjector` (exists; needs the P1-1 surface) |
| Editable soul + memory (`SOUL.md`, `IDENTITY.md`, Memory) | PERSONAL-AGENT P1/M1 (`persona.md`, Memories list, Forget/undo) |
| Morning newspaper routine | PERSONAL-AGENT P2-3 Morning digest |
| Browser-task verification + one retry | P1-4 (`expectedText`/`expectedURL` mandatory, one re-inspect) |

### 8.2 Partially covered — extend, don't add

- **Activity lineage.** We have the log (`agent-audit.jsonl`) and the in-pane
  timeline; Muse's praise is for *history across days* + an *approvals ledger*
  + heartbeat transparency. Add to P1-1: a cross-session Activity screen
  (filter by day/kind), an "everything you've approved" ledger, and a
  "what it's doing right now" heartbeat row. Drill-down is progressive
  disclosure by design: consumer step → expandable tool/script detail
  (never tool ids on the top line).
- **Guided first success.** D1–D3 prove single tasks; Muse's magic is the
  *sequence*: connect calendar (easy, unscary) → give names → propose one
  real change → permission → done → proactive offer ("want an agenda?").
  Add D9: calendar-connect → name-two-people → one real proposal → approval
  → executed → one follow-up offer. One scripted run, ≤ 3 min.
- **Two-step ingestion consent.** Our reads auto-run — correct for files and
  search, wrong for first-time *personal-data ingestion* (email → family
  facts). Rule: the first ingestion from a newly connected account always
  runs look → show findings → "may I use this?" even under auto-allow reads.
  The gate is per-account-first-use, not per-tool. (Extends the permission
  table, §Asking permission.)
- **Artifact routing + design bar.** Muse failed the same way we do (bullet
  list where an artifact was wanted). Judge rule: "easy to read / print / put
  on the table" ⇒ prepared artifact, not chat text. The bar is frame-verified
  (`references/newsletter.png`, video 11:40): a masthead with edition + date +
  city, weather block, "The Week Ahead" day grid, per-person desks (Kid/School),
  "Parents: watch these", "Around Town", "News to Know" with per-item source +
  date, and "Talk at the Table" discussion questions — one-shot, print-ready,
  no follow-up fixes. P1-5 covers existence; this anatomy is the acceptance
  bar, plus calendar-overlap callouts (BJJ-vs-piano).
- **Failure with explicit undo + recovery buttons.** Frame-verified
  (`references/goals.png`, video 29:34): "Nothing was added to any bag and no
  checkout was started, so nothing to undo. Two ways we can go from here:" +
  two buttons (closest in-stock / watch for restock). Rule for every failed
  action card: state exactly what did and did not happen, what there is to
  undo (by name, or "nothing"), and offer ≤ 2 next actions as buttons — never
  a dead-end sentence. Add to P1-1 acceptance.
- **Status sublines on tracked items.** Frame-verified (`references/goals.png`):
  every goal/tracked row carries a one-line live status ("Waiting for your
  decision on next options…", "Daily reminder fires at 8:52 each morning").
  Our step list shows titles; tracked items (goals, routines, drafts awaiting
  approval) get the same subline treatment in Agent pane + island.
- **Purchase as a risk class.** D5 covers tickets. Generalize: money movement
  is its own `AgentRisk` above `.send` — exact amount + payment method on the
  card, no retry on mismatch (P1-4 retry is `risk <= .modify` only), receipt
  artifact mandatory. Credentials (1Password-style) and payment rails
  (Stripe-Link-style) are explicit opt-in integrations, never stored by
  default.

### 8.3 Missing — new items

- **Consumer naming map (do this before any new surface ships).** Our words —
  crons, routines, artifacts, tools, `AgentTask`, TranscriptBus — must never
  reach the user. Map: schedules/reminders → **Reminders**; routines/triggers
  → **Goals** (PERSONAL-AGENT amendment); `AgentTask.artifacts` → **Library**;
  routine suggestions → **Ideas**; audit timeline → **Activity**. Enforce with
  a UI-string lint: no surface ships containing cron, artifact, tool id, or
  schema key. (The `ToolCallReview` raw-key disagreement in FEEDBACK §6 is
  the same bug.)
- **Ideas gallery (`/ideas`).** Out-of-box, one-tap suggestion cards grouped
  by life area (inbox, returns, relationships, health, finance, home/city) —
  not a blank chat box. Producer: static curated list v1 (no model needed);
  PERSONAL-AGENT routine-suggestions feed it later. Kicks off a goal/routine
  setup flow, never executes directly.
- **Avatar animation states.** *(Built 2026-09-23 as the character: ten states with one
  meaning each, a face generated in onboarding, the island / thinking row / working card /
  About hero wearing it, `--selftest-avatar` and `--avatar-sheet`. One spec deviation:
  "makeover" is the procedural part set (`NotionAvatarConfig.random()` + the editor), not
  local image gen.)* We have the orb vocabulary (nine states, one
  meaning each) and `agent-identity.json` (name + avatar params) — but no
  *character* that works, idles, and celebrates. Spec: idle / working
  (laptop-equivalent: orb + step line) / media-gen (orb) / done states on the
  island avatar; avatar makeover via local image gen as a settings flow;
  Reduce Motion freezes like orbs. Never `scaleEffect` — same rule as orbs.
- **Long-form audio decision.** Our TTS policy (≤220 chars, no long reads)
  directly forbids Muse's most delightful artifact: the 6-minute two-host
  podcast (publishable to Spotify/Apple). Decide: keep spoken replies short
  *and* add an offline-rendered audio artifact path (Library item,章节d,
  interruptible, never auto-played into a call), or concede podcasts. Either
  way it is a decision, not drift.
- **Feed vs digest.** P2-3 digest is a routine with a card. A Feed is a
  persistent surface with tone settings ("clear, skimmable, no clickbait"),
  push delivery, and topic prompts. Requires a web/news source we deliberately
  lack (local-first, no web search tool). Decide: opt-in cloud news source
  behind the existing consent pattern, or no Feed. Do not half-build it on
  email content alone.
- **Exposure discipline.** Muse hides the VM and shows the browser subset.
  Our equivalent, stated as law: internals (ACP transcripts, CLI output,
  schemas, file paths, model names) never render; the browser snapshot and
  the humanized step are the only live views. P1-1's live view must be a
  *subset* (focused window / snapshot), never a machine room.
- **Out of scope, recorded:** phone companion + WhatsApp surface (macOS-only
  product; notifications + speak-if-present are the local equivalent),
  HealthKit, shopping catalog/coupons, credential vault. Revisit only with a
  user asking twice.

### 8.4 Browser honesty, confirmed again

Shoe-shopping failure (wrong colorway, misheard number, stuck loop) is our
P1-2 + P1-4 + P0-3 combined — and the reviewer forgave the success (tickets)
while remembering the failure (shoes). Order matters: P1-4 verification
before P1-2 vision breadth. A browser that says "I couldn't find the right
colorway — here are the 3 closest" beats one that buys the wrong shoes.

---

## Appendix — evidence index

- `~/Library/Application Support/Next Notes/agent-audit.jsonl` — wake events (3 total),
  the 20:45:08Z `append_doc` approval, the refusals.
- `~/Library/Application Support/Next Notes/agent-conversation.json` — 46 turns; the garbled
  ASR set; `"I stopped the tool plan because it took too long."`
- `~/Library/Application Support/Next Notes/agent-tasks.json` — 15 tasks, all `backend: local`,
  all `artifacts: []` but one.
- `~/Library/Application Support/Next Notes/metrics.jsonl` — 521 rows; the table in §2.
- `Sources/NextNotes/Agent/AgentDirectIntent.swift` — the 44.78 s / 3,634-token prefill record.
- `Sources/NextNotes/Agent/FunctionCalling/FunctionCallRelevance.swift` — the `append_doc`
  post-mortem, written today.
- `Sources/NextNotes/Agent/AgentRefusalGuard.swift`, `Sources/NextNotes/Persona/AgentGrounding.swift`
  — the false-refusal post-mortems, written today.
- `/Users/sergekadjo/Library/Caches/NextNotesBuild/competitors/v{1,2,3}/writeup.md`.

---

## 9. Finalization — executed 2026-09-22

The ordered plan above was driven to its code-complete state the same week it was written.
This section records what landed and what stays deliberately deferred; the items below are
the audit's own outstanding list, each now either shipped or recorded as the deliberate
deferral the plan already named.

**Shipped (with scripted acceptance):**

- **P0-4's second half** — the permission card already carried the trigger sentence
  (`review.why` renders `You said "…"`), so the quote was never missing from the card; what
  was missing was its persistence: `PermissionGate.respond` now writes the trigger quote
  into `agent-audit.jsonl` (`AgentAuditEntry.triggerQuote`, hand-written decoder with
  `decodeIfPresent` so old rows still load). `.unattributed` keeps its honesty line; no
  quote is invented.
- **P2-1 "Portrait"** — `Knowledge/Portrait.swift` + `PortraitService`: a 7-day-cadence
  pass over the graph, resolved through the memory-review model routing (`MemoryReviewRouter`,
  no second table), producing 2–3 prose drafts; nothing saves unreviewed; per-insight
  `Cross out`. Scripted: `--selftest-portrait` (review-before-save, keep/discard/delete,
  cadence wait, honest no-graph answer) → `PORTRAIT_OK`.
- **P2-2 "Corners"** — `LifeCorners.corners(graph:)` groups the existing graph into six
  corners (Work, People, Home, Wellbeing, Learning, Goals) derived strictly from what
  `LifeExtractor` emits — there is no finance corner because nothing in the extraction says
  money. Each card carries one fresh fact (`Latest: …`).
- **D4 trip assembly** — `Knowledge/Assembler.swift`: search files → search knowledge →
  read the closest sources → compose → a saved markdown page in `Application
  Support/Assembled` listing every source and 3–5 outstanding items, result card links it,
  `AgentTask.artifacts`/ledger non-empty. With no model the page still writes, from
  retrieved snippets, and says it was written without a model pass. Scripted:
  `--selftest-assemble` → `ASSEMBLE_OK` (4 sources, 4 owed, ledger non-empty).
- **§8.2 two-step first-ingestion consent** — `Agent/Permissions/FirstIngestionGate.swift`:
  the first read from a newly connected account (`google-workspace:<credential>` key until
  the CLI exposes an address) runs look → show findings → "May I use what I found…"; a
  dismiss withholds the findings and the gate stays armed; with no consent path available
  the look does not happen at all. Skipped under the self-test harness.
- **P1-2 vision seam** — found unwired during the roadmap audit and re-wired the same day
  (`completeWithImages` now has its production call site in the tool loop's result path);
  `--selftest-computer-vision` green.
- **§8's status sublines, approvals ledger, UI-strings lint, `AgentRisk.purchase`** — all
  in tree; the morning digest (P2-3) shipped earlier as `--selftest-digest`.

**Deferred, as this plan itself decided (§4 Phase 2):** P2-4 learn-from-demonstration
(XL) and P2-5 agent-to-agent hand-off (low value for a non-technical audience) stay
deferred — recorded as the decision, not outstanding work.

**Unverified in the code-complete sense:** Portrait's pass, Corners and the first-ingestion
gate have never run against a real graph or a real account with models on this machine
(no models downloaded, no Workspace account); the acceptance above is the scripted half.
The two-step consent's settings row and a card-bearing gate self-test are noted as
follow-ups in the tree.
