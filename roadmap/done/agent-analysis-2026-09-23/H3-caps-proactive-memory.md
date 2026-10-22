# H3: caps, gates and defaults in proactivity, memory, consent and settings

> **Historical model assumptions — revised 2026-09-30:** this completed plan/audit
> preserves its dated measurements and implementation history. For new work, follow
> the [independent-role/shared-file contract](../../in-progress/SHARED-BRAIN/00-README.md): Meetings, Agent and cleanup
> may use different appropriate models; exact verified artifacts are reused, with
> workload-specific consent and request ownership. Agent-only file selection,
> universal model defaults and deletion based only on the Agent are superseded.
> MiniCPM cleanup + Apple guard/fallback is concurrent work, not evidence that this
> historical build used it. Re-measure quality/latency on the actual current engine.

Date: 2026-09-23. This is a read-only audit. No source, settings or roadmap file was changed.
Scope: `Agent/FunctionCalling/**`, `MeetingAgent`/`AgentService`/`AgentPrompts`, `Agent/Schedules/**`,
`Agent/Goals`, `Agent/Tasks`, `Agent/Permissions/**`, `Memory/**`, `Knowledge/**`, `Calendar/**`,
`Meetings/**`, `Context/**`, `Support/Settings.swift`, `UI/Island/**`, `UI/Settings/**`.

Evidence was read on this Mac from `~/Library/Application Support/Next Notes/`:
`agent-memory-review.json`, `next-memory.json`, `agent-audit.jsonl`, `metrics.jsonl`, the six `Meetings/*`
folders, `knowledge.sqlite` (read-only), `function-calling.json`, and `defaults read ai.pivotstudio.nextnotes`.

**Two facts change how the existing analysis should be read:**

1. **"200 review runs" is a ledger cap, not a lifetime count.** `MemoryReviewStateStore.runLimit = 200`
   (`Memory/RoutineSuggestions.swift:132`). The 200 rows cover only 2026-09-22 16:05 to 2026-09-23 22:40,
   about 30 hours. Separately, the backfill read 86 past sources and saved 4 facts.
2. **This Mac has almost every capability switch turned on by hand.** Its defaults include
   `knowledgeIndexEnabled`, `knowledgeAgentToolsEnabled`, `knowledgeGraphEnabled`, `includeDictation`,
   `includeRoutines`, `agentEnabled`, `agentLiveDuringMeeting` and `voiceWakeEnabled`, all set to 1. A fresh
   install gets none of these. So the "defaults" findings below would not show up in this Mac's logs, but
   they decide what every other user gets.

---

## 1. Summary table (most harmful first)

Coverage: **P#-NN** means an existing roadmap task already handles it. **partial** means a task touches it
but misses the part named here. **NEW** means nothing in `roadmap/in-progress/AGENT-OVERHAUL` handles it.

| # | Limit / gate | Value | Where | Verdict | Coverage |
|---|---|---|---|---|---|
| 1 | Knowledge-index switch has two different defaults | `Settings.knowledgeIndexEnabled ?? false`, but `KnowledgeIndexSettings.enabled ?? true` | `Support/Settings.swift:1078` vs `Knowledge/KnowledgeIndexer.swift:10,34` | **HURTS** | NEW |
| 2 | Agent knowledge tools off by default | `knowledgeAgentToolsEnabled ?? false` | `Support/Settings.swift:1083`, `Knowledge/KnowledgeTools.swift:28-33` | **HURTS** | partial (P1-03) |
| 3 | Post-meeting review's fixed reservations exceed Apple's 4K window | 900 output + 256 headroom + 512 lookup reserve + ≈2.9K system/schemas; `minimumTranscriptTokens` 500 | `Agent/MeetingAgent.swift:49-61,416-424` | **HURTS** (estimated; verify) | NEW |
| 4 | Post-meeting transcript is cut from the tail only | `cut(... keepingTail: true)` | `Agent/MeetingAgent.swift:447,468-469` | **HURTS** on ≤8K windows | NEW |
| 5 | Island approval cards vanish after 8 s while the request stays pending | `DS.Motion.islandNotice = 8`; no live kind for `PermissionGate.pending` | `UI/DesignSystem.swift:784`, `UI/Island/IslandState.swift:366,496-541` | **HURTS** | NEW (P3-08/P3-09 are adjacent) |
| 6 | Needle card slot held for 180 s against an 8 s card | `cardLifetime 180`, `maximumOutstandingCards 1` | `Agent/FunctionCalling/FunctionCallWatcher.swift:59,67` | **HURTS** (follows from #5) | NEW |
| 7 | Memory review is shown the current memory verbatim, so a ~3B model echoes it | `"Current memory (data): " + render(memory)` | `Memory/MemoryReviewer.swift:581` | **HURTS** | NEW (P4-07 does not touch it) |
| 8 | Harvest drops every sentence under 24 characters | `MemoryHarvest.minimumSentence = 24` | `Memory/MemorySources.swift:30,214` | **HURTS** | NEW |
| 9 | Memory skip regexes are too broad (environment failure, "search") | `environmentFailure`, `oneOff` | `Memory/MemoryReviewer.swift:465-491` | **HURTS** (1 of 1 real firings was wrong) | NEW |
| 10 | Routines have no Apple Intelligence route | `.auto` → local, else cloud, else `.skip` | `Agent/Schedules/ScheduledRunner.swift:28-56` | **HURTS** | NEW |
| 11 | Routine output capped at 384 tokens per round and "three sentences" | `maxTokens: 384`; rules line | `ScheduledRunner.swift:441,531,535` | **HURTS** (digest, podcast) | partial (P4-06 fixes the sentence line only) |
| 12 | First-ingestion gate blocks scheduled mail/calendar reads for good | `authority.isScheduled` → `noConsentPathLine` | `Agent/Tools/AgentToolExecutor.swift:325-329` | **MIXED** | NEW |
| 13 | Meeting follow-ups off until the user finds the switch | `agentEnabled ?? false` | `Support/Settings.swift:1060`, `Agent/AgentService.swift:143,198` | **MIXED** | NEW |
| 14 | Needle watcher needs the LLM live-pass switch, which is off by default | `noticesMeetings` = `agentLiveDuringMeeting ?? false` | `FunctionCallStore.swift:196-198`, `Settings.swift:1062` | **MIXED** | NEW |
| 15 | Meetings finished before Google sign-in are never reviewed | `review` returns if not `isReady`; nothing re-runs later | `Agent/AgentService.swift:197-209` | **MIXED** | NEW |
| 16 | Evidence quote must match exactly (whitespace and case only) | `isTranscriptEvidence`: `body.contains(cleaned)`, ≥ 12 characters | `Agent/MeetingAgent.swift:358-364` | **MIXED** | partial (P4-05 adds a lane beside it) |
| 17 | Memory in the prompt: fixed character budgets per path | voice 300, meeting/knowledge 600, tool loop 3,400 | `Persona/AgentPromptContext.swift:56-76` | **MIXED** | partial (P4-08 scales history only) |
| 18 | Meeting brief caps are fixed, not derived from the model | 700/500/400/900/300 chars; 3 passages; 5 files | `Meetings/MeetingNotesContext.swift:104-122` | **MIXED** | NEW (low) |
| 19 | Routine-suggestion detector needs an exact key on 3 days | `requiredDays 3`, sorted content-word key | `Memory/RoutineSuggestions.swift:48,57-61,76-78` | **MIXED** | partial (P4-06) |
| 20 | Background result spoken only while the session is open; long result replaced by a stock line | `enqueue` guard; `brief.count <= 300` | `Agent/VoiceAnnouncementQueue.swift:12-15,46-48` | **MIXED** | P3-04a |
| 21 | Island reply card gets 8 s whatever its length | `showAgentReply` → `islandNotice` | `UI/Island/IslandState.swift:395-397` | **MIXED** | NEW (small) |
| 22 | New heads-up cards will inherit the 8 s notice | P4-04 design uses `DS.Motion.islandNotice` | `05-PHASE-4-PROACTIVE.md:899` | **MIXED** | fix inside P4-04 |
| 23 | Quiet hours hold a routine's result even at a time the user chose | 21:00–08:00; reminders exempt, routines not | `AgentScheduler.swift:144-150,646-669`; `Settings.swift:1074-1075` | **MIXED** (minor) | NEW |
| 24 | ASR bias waits only 60 ms for the screen harvest (measured 133–143 ms in Cursor) | `awaitCapture(within: .milliseconds(60))` | `Transcription/AppleSpeechEngine.swift:150-151` | **MIXED** (does not apply here: engine = parakeet) | NEW (low) |
| 25 | Review ledger keeps 200 rows, so the Memories "last looked" history is ~30 h | `runLimit = 200` | `Memory/RoutineSuggestions.swift:132` | **MIXED** (diagnostics) | NEW (low) |
| 26 | Needle watcher: 1 card at a time, 3 per 10 min, 20 s after an agent turn, ≥ 12 chars, 700 ms debounce | as named | `FunctionCallWatcher.swift:52-74` | HELPS | — |
| 27 | Needle confidence floors 0.35/0.5, echo 0.8, grounding, time-word rule for events | as named | `FunctionCallRelevance.swift:195-199`, `FunctionCallGrounding.swift:164-177` | HELPS (measured) | — |
| 28 | Needle sees only writes in 3 families, at most 8 tools | `minimumRisk .modify`, `maxTools 8` | `FunctionCallStore.swift:12,22,34` | HELPS (see #14 for the missing read lane) | P4-05 (suggestion lane) |
| 29 | Meeting proposals ≤ 3; write needs a quote; argument grounding | `maxProposals 3` | `AgentPrompts.swift:9`, `MeetingAgent.swift:327-339` | HELPS (keep; see #16) | — |
| 30 | Memory provenance: ≤ 1 unsupported word; ¾ Jaccard or containment duplicate; update/forget target check | as named | `Memory/MemoryGuard.swift:273-311,393-402,489-496` | HELPS (all 36 real refusals were correct) | — |
| 31 | Memory review route: local only after 60 s idle, never while recording | `requiredLocalIdle 60` | `MemoryReviewer.swift:109-148` | HELPS | — |
| 32 | Store budgets profile 2,400 / note 4,000 chars; entry ≤ 300 | as named | `Memory/NextMemory.swift:61-66,270` | HELPS (uses 2 facts ≈ 230 chars) | — |
| 33 | Routine budget 180 s / 8 tool calls; silence token; routines never write memory or schedules | as named | `AgentSchedule.swift:40`, `ScheduledRunner.swift:65-70,203` | HELPS | — |
| 34 | Calendar look-ahead 24 h / look-behind 1 h / 5 min poll | as named | `Calendar/CalendarService.swift:29-34` | HELPS (arming only; the agent's agenda tool is `gws`) | — |
| 35 | Wake word, graph, embedder, cloud-graph and vision consent off by default | as named | `Settings.swift:1063,1082-1086` | HELPS (consent / measured unreliability) | — |

---

## 2. Detailed entries

### 1. The knowledge-index switch has two different defaults (HURTS, NEW)

- **Value:** `Settings.knowledgeIndexEnabled = defaults.object(...) as? Bool ?? false`
  (`Support/Settings.swift:1078`; its doc comment at `:706` still says "Off by default"). The indexer reads
  `KnowledgeIndexSettings.fromDefaults`, where `enabled ?? true` (`Knowledge/KnowledgeIndexer.swift:10,34`).
- **History:** commit `5b16b2c` switched the index on by default and AGENTS.md now documents it as on. Only
  the struct was changed. The `Settings` property, which drives the UI and the agent gate, was not.
- **What goes wrong on a fresh install:**
  - The indexer builds `knowledge.sqlite` in the background.
  - The sidebar hides Search (`UI/Sidebar.swift:108`).
  - The Search screen offers "Turn on the knowledge index" (`UI/Knowledge/KnowledgeSearchView.swift:48,71`).
  - The Settings toggle reads off (`UI/Settings/KnowledgeSection.swift:24`).
  - `KnowledgeToolGate.isAvailable` is false (`Knowledge/KnowledgeTools.swift:28-33`), so
    `search_knowledge` is never offered to the planner or to `MeetingAgent.advertisedTools`
    (`Agent/MeetingAgent.swift:170-181`).

  The index exists, but no user and no agent can see it. The graph gate
  (`KnowledgeGraphPane.swift:41`, `DecisionThreadView.swift:225`) reads the same wrong bit.
- **Why nothing caught it:** the harness forces `KnowledgeIndexSettings(enabled: false)`, and
  `--selftest-index` pins only the struct's default.
- **Change:** make `Settings.swift:1078` `?? true`, and read both from one constant
  (`KnowledgeIndexSettings.defaultEnabled`). Add a `--selftest-index` check that
  `Settings().knowledgeIndexEnabled == KnowledgeIndexSettings.fromDefaults.enabled` against an empty
  defaults suite. Fix the stale comments at `Settings.swift:706` and `KnowledgeIndexer.swift:131`.

### 2. The agent's knowledge tools are off by default (HURTS, partial via P1-03)

- **Value:** `knowledgeAgentToolsEnabled ?? false` (`Settings.swift:1083`). `KnowledgeToolGate.isAvailable`
  requires the index, this switch and *look things up without asking*.
- **Harm:** this is finding T7 ("I cannot access past meetings") on every fresh install. It happens even
  after #1 is fixed, and even though the tools are read-only and the data is the user's own. The only way in
  is a button on the Ask screen (`UI/Knowledge/AskView.swift:268`). The Agent's local-data reads (files, mail
  search) are already auto-run reads. Its own index is not.
- **Change:** default this to `true` (it only has effect while the index is on). Keep the cloud-reader
  restriction exactly as it is: `KnowledgeGraphScope` / `graphCloudConsent` still gates `expand_node` and
  `timeline` for cloud readers. P1-03's manifest should derive availability from these switches. P1-03 does
  not say to change the default, so add that as a line in P1-03.

### 3. The post-meeting review likely cannot fit on Apple Intelligence (HURTS, estimated; NEW)

- **Values:** `maxOutputTokens 900`, `headroomTokens 256`, `lookupTokens 512` (reserved whenever
  `autoRunReadTools && maxRounds > 1`, which is true for `AgentPolicy.fromSettings()`), and
  `minimumTranscriptTokens 500` (`Agent/MeetingAgent.swift:49-61,418-424`).
- **The system prompt is large:**
  - full persona (≤ 1,688 chars)
  - full grounding (≈ 850)
  - memory (600)
  - `AgentPrompts.rules` (≈ 2,300)
  - the tool-block framing
  - JSON schemas for 11 Workspace tools, plus up to 3 knowledge tools
- **Estimate:** that is roughly 2,800–3,000 tokens. Adding 900 + 256 + 512 gives ≈ 4,500–4,700, which is more
  than Apple's 4,096. `fit()` then throws `AgentError.contextTooSmall` ("This model has too little room left
  to read the meeting…"). Even with the lookup reserve removed, fewer than 500 tokens would be left for the
  transcript.
- **Evidence:** 6 of 6 meetings on this Mac have `agentActions: []` and no `proposals.json`. The analysis
  (D §3) also says the agent role now resolves to Apple FM, because the library is empty.
  **Not measured.** `problems[id]` is in-memory only and the error log has aged out. This needs one probe
  before the fix: run `--selftest-agent` with the Apple provider and print `reserved` and `budget`.
- **Change (derive from the window, not constants):** when `contextTokens ≤ 8K`:
  - Do not reserve `lookupTokens`. Use `AgentPolicy.live`-style no-reads.
  - Output 600 instead of 900.
  - Short persona card.
  - Advertise only the write tools that `MeetingContext.candidateActions` point at (`send` → `draft_email`
    and `send_email`, `schedule` → `create_event`, and so on) instead of all 11.

  Also persist the failure on the meeting (`agentProblem` with `decodeIfPresent`). Right now a failure that
  prevents every proposal is invisible after relaunch.

### 4. The post-meeting transcript is cut from the tail only (HURTS on small windows, NEW)

- **Value:** `cut(transcript, to: budget, keepingTail: true)` (`MeetingAgent.swift:447`). The comment says
  "the sentences that matter are the ones near the end".
- **Harm:** on a 4K window, whatever is left after #3 is a few minutes of the end of a 25-minute call. "I'll
  send you the pricing" said at minute 8 is gone before the model reads anything. Meanwhile the app already
  has a whole-meeting index of asks: `MeetingContextStore` `candidateActions` and `actionItems` with
  `evidence` and `evidenceStart`. The WhatsApp/Facetime `context.json` files on this Mac contain them.
- **Change:** when the transcript does not fit, build the transcript section from the ±30 s around each
  `candidateActions`/`actionItems` `evidenceStart` (newest first) plus the tail. The evidence rule stays
  valid because those windows are exact transcript text.

### 5. Island approval cards disappear after 8 s while the request is still pending (HURTS, NEW)

- **Value:** `PermissionGate.raiseIsland` → `IslandState.propose` → `push(.agentProposal, for:
  DS.Motion.islandNotice)`, and `islandNotice = 8` s (`UI/DesignSystem.swift:784`,
  `UI/Island/IslandState.swift:366`). After expiry, `refresh()` falls back to `liveKind()`
  (`:496-541`). That function has no case for `PermissionGate.shared.pending`, so the island returns to
  hidden (or to the meeting-recording strip). Hovering pauses the countdown, but only if the user is already
  on the card.
- **Harm:** the tool loop, the ACP session, the Needle watcher and the first-ingestion consent all wait on
  `PermissionGate.ask`, and none of them time out. In voice use the main window is usually closed, so after
  8 s nothing on screen says the agent is blocked on the user. This is the visual half of C8 ("writes stall
  at a card"). P3-08 adds spoken approvals and P3-09 island ownership, but neither keeps the card visible.
- **Change:** add a live kind `.pendingApproval(IslandProposal)`, derived from `PermissionGate.shared.pending`
  and placed below dictation and agent-listening in `liveKind()`. After the 8 s notice it collapses to a
  small persistent badge ("1 waiting") rather than disappearing. It clears only on `respond` or cancel.
  Phase 1, alongside P1-07.

### 6. The Needle card holds its slot for 180 s while the island shows it for 8 s (HURTS, NEW)

- **Values:** `cardLifetime 180`, `maximumOutstandingCards 1`, `maximumCardsPerWindow 3` per 600 s
  (`FunctionCallWatcher.swift:59-70`).
- **Harm:** each value is sensible on its own (AGENTS.md; the self-test measures them). Combined with #5, a
  meeting proposal is visible for 8 s and then keeps the only slot for up to 172 s with no visible card.
  Every later actionable sentence is dropped with "a card of ours is already waiting".
- **Change:** fix #5 first. Then withdraw the watcher's outstanding card when its island notice lapses
  un-hovered, or make the badge from #5 its surface. Keep 1-at-a-time and 3 per 10 min.

### 7. The memory review is primed to echo current memory (HURTS, NEW; this is the real "2 facts" gate)

- **Value:** the review prompt starts with `"Current memory (data): " + render(memory)`
  (`Memory/MemoryReviewer.swift:581`) and says "Most of it needs nothing".
- **Evidence (all 200 ledger rows, 2026-09-22 16:05 → 09-23 22:40):**

  | Measure | Value |
  |---|---|
  | Runs by model | Apple 136, local 31, OpenRouter 33 (all 33 failed with "OpenRouter rate-limited", up to 27 in a row on 09-22) |
  | Runs by trigger | dictation 170, conversation-ended 16, conversation-turns 3, meeting 11 |
  | Proposals | 103 |
  | Saved | 4 (all from the backfill, all on Apple) |
  | Skipped "already remembered" | **57 (55%)**, all restating one of the stored facts |
  | Refused "you didn't say which memory to change" | **25 (24%)**, the same restatements sent as `memory.update` with no real target |
  | Successful runs that proposed nothing | 83 |
  | Conversation reviews (19 runs) | 0 saves; every proposal was one of the 2 stored facts |

  Of the 4 facts saved, 2 were later removed ("mini cpm5-2b model as default LM", "already closes the
  cover"). The removals came through `memory.forget` audit rows that have no request or reply, which is the
  self-test pollution pattern (P0-11).
- **Reading:** the code-level gates behaved correctly. The 36 real refusals and skips were right (except
  #9). The model spends its 5-call budget re-stating the memory it was shown. That, plus an input mix that is
  85% dictations aimed at other apps, is why memory does not grow. P4-07 adds a direct save path for explicit
  statements but leaves this prompt as it is.
- **Change:**
  - For providers with `contextTokens ≤ 8K` (Apple FM, the ~3B local models), stop sending full memory.
  - Send only the entries whose content words overlap the job's user text, since only those can be
    `update`/`forget` targets, capped at 5. Label them "facts already saved — do not repeat".
  - Keep the code-level duplicate check.
  - Add a `--selftest-memory-review` fixture: a scripted echo model must see no unrelated memory in the
    prompt.
  - Target: echo share of proposals under 15% on the next 50 ledger rows.

### 8. The harvest drops every short sentence (HURTS, NEW)

- **Value:** `MemoryHarvest.minimumSentence = 24` characters (`Memory/MemorySources.swift:30`, applied at
  `:214`) on every dictation and meeting-line job.
- **Harm:** it removes most durable personal facts:
  - "My brother is Cyril." (20)
  - "My dad is Mathieu." (18)
  - "I live in Paris." (16)
  - "Call me Serge." (14)

  Its stated purpose is to drop filler ("okay", "yeah, sure"). A character floor is the wrong tool for that.
- **Change:** replace it with `contentTokens(text).count >= 2 && !isFiller` (reuse
  `RoutineSuggestionDetector.filler` or `MemoryGuard.contentTokens`). Keep the 6,000-character job budget.

### 9. The memory skip regexes are too broad (HURTS, NEW)

- **Value:** `MemoryReviewSkipRules.environmentFailure` matches any `error`, `bug`, `offline`,
  `unavailable`, `fail…`, `not working`. `oneOff` matches any `today|tomorrow|this week|for now` and **any
  word starting with `search`** (`Memory/MemoryReviewer.swift:465-491`).
- **Evidence:** this rule fired once in the ledger, and that one firing was wrong. "The user works on new
  branches and code that need to be production ready, tested, and fully thought out…" is a durable
  work-style fact. It was dropped as "an environment failure".
- **Examples that would be dropped:** "The user is unavailable on Fridays", "The user prefers offline-first
  tools", "The user's company builds search software", "The user fixes bugs before features".
- **Change:**
  - Require an environment frame: a failure noun or verb together with an app, device, network or
    permission object, or a present-tense "isn't/doesn't/won't … work/connect/load" clause.
  - Drop the bare `\bsearch\w*\b` clause.
  - Keep the "is searching / wants to know / asked" continuous forms.
  - Add the four sentences above as keep-cases in `Tests/Fixtures/memory-review.json`.

### 10. Routines have no Apple Intelligence route (HURTS, NEW)

- **Value:** `RoutineModelRouter.route`: `.auto` → local if runnable, else cloud if configured, else `.skip`
  (`Agent/Schedules/ScheduledRunner.swift:28-56`). The local route is a bare `LlamaLLMProvider()`
  (`:531`), which ignores `ModelRoleStore`.
- **Harm:** the memory review had exactly this bug. Its router comment says "every route was `.wait`… the
  review waited for ever". It was fixed there by adding `.appleFoundation`, but routines never got that fix.
  With no GGUF installed (this Mac today) and a rate-limited or absent OpenRouter, every routine, trigger
  (`meetingStarting`, `notesReady`) and goal nudge that needs a model skips. That includes P4-04's
  pre-meeting brief and P4-06's digest if they run as routines.
- **Change:** add `.appleFoundation` after local in `.auto` and `.local`, mirroring
  `MemoryReviewRouter`, and resolve the local provider through the agent role. Pin every row in
  `--selftest-schedule`. Phase 4, before P4-04 and P4-06.

### 11. Routine output: 384 tokens per round and "three sentences" (HURTS for digest and podcast; partial via P4-06)

- **Values:** `ProviderMemoryReviewModel(..., maxTokens: 384)` for both local and cloud
  (`ScheduledRunner.swift:531,535`). The rules line says "answer … in at most three sentences"
  (`:441`).
- **Harm:** `DigestTemplate.swift:32-36` and `PodcastTemplate.swift:27` already document the conflict. A
  sectioned digest (masthead, week grid, desks, watch items) or a two-host script cannot fit in 384 tokens,
  even with the prompt override. P4-06 changes the sentence rule and leaves the token cap.
- **Change:**
  - Make the cap a field on the schedule's `Budget`: `maxOutputTokens`, default 384 for plain routines,
    1,536 for the digest template, and 4,096 for the podcast template, clamped to
    `provider.contextTokens / 3`.
  - Add a `decodeIfPresent` default so stored schedules decode.
  - Add the field to P4-06.

### 12. The first-ingestion gate blocks scheduled reads for good (MIXED, NEW)

- **Value:** in `AgentToolExecutor.swift:325-329`, if an account's first read has not been approved in a
  conversation, a scheduled run gets `noConsentPathLine` and nothing is read. The account key is
  `"google-workspace:\(method)"` (`FirstIngestionGate.swift:83-87`). That key is the auth method, not an
  address.
- **Evidence:** `first-ingestion.json` does not exist on this Mac, so no Workspace read has passed the gate
  since it landed. The last `search_email` in the audit is from 2026-09-15.
- **Why keep it:** the rule is right; nobody can consent in an unattended run.
- **Harm:** the morning digest (`search_email`, `get_agenda`) created on a fresh account, or by P4-06's offer,
  silently returns "I did not use your mail" every morning until the user happens to ask a mail question by
  hand.
- **Change:** when a routine that includes a Workspace read is created (`schedule.create`, whose test run is
  already visible and attended), run the first-use consent card during that creation test-run. The user is
  there, so it is a real consent path. Also key the record on the account's email when `gws` exposes one,
  and fall back to the method.

### 13. Meeting follow-ups stay off after the user connects Google (MIXED, NEW)

- **Value:** `agentEnabled ?? false` (`Settings.swift:1060`), and `AgentService.isReady =
  agentEnabled && signedIn` (`AgentService.swift:143`).
- **Harm:** the follow-up proposals never run anything without an approval (`AgentRisk`, `PermissionGate`),
  yet the feature stays off after the user has already given the stronger consent of connecting their Google
  account. Onboarding never sets it (`grep` finds only the Workspace settings toggle).
- **Change:** default on when Workspace auth becomes `.signedIn` for the first time, with one island notice
  ("I'll suggest follow-ups after meetings — you approve each one"). An explicit off stays off.

### 14. The Needle watcher is inert unless the live-meeting LLM switch is on (MIXED, NEW)

- **Value:** `FunctionCallStore.noticesMeetings` = `Settings.agentLiveDuringMeeting`, default `false`
  (`FunctionCallStore.swift:196-198`, `Settings.swift:1062`). The watcher only listens in meetings
  (`FunctionCallWatcher.swift:262-275`).
- **Tension:** the store's own comment says the default-off switch meant "the one path the feature exists for
  had never been run end to end". The switch's reason for being off by default ("it spends model time during
  the call", `Settings.swift:631`) is true of the LLM live pass. It is not true of Needle, which measured
  p50 ≈ 60 ms per turn, resident, on 2026-09-23. So `isEnabled = true` by default reaches no user.
- **Change:** split the dependency. The Needle watcher runs in meetings when `FunctionCallStore.isEnabled`
  and the engine is installed. The LLM live pass (`AgentService.handleLiveDelta`) stays behind
  `agentLiveDuringMeeting`. The one-switch principle holds by relabelling rather than adding a switch: the
  Needle section's own toggle becomes "Notice requests during meetings".

### 15. Meetings finished before sign-in are never reviewed (MIXED, NEW)

- **Value:** `review(_:)` returns at `guard isReady` (`AgentService.swift:198`) and is called only from the
  notes-ready branch.
- **Evidence:** meetings on 09-10 and 09-13 predate the first `search_email` (09-14), so they were never
  reviewed.
- **Change:** on the first transition to `isReady`, review the meetings from the last 7 days that have no
  `isFromReview` rows. The existing `reviewed` check makes this idempotent. Show at most 3 cards in total.

### 16. The exact evidence-quote rule (MIXED, partial)

- **Value:** after collapsing whitespace and lowercasing, the quote must be a substring of the transcript and
  at least 12 characters (`MeetingAgent.swift:358-364`). Punctuation is not normalized.
- **Why keep it:** it stopped invented summary Docs, and AGENTS.md depends on it.
- **Harm:** small models routinely drop or add a comma, fix an ASR misspelling, or quote across a segment
  boundary. Each of those rejects a real ask.
- **Change:** normalize punctuation and apostrophes on both sides. Accept a quote whose content-token
  sequence matches a transcript window at ≥ 90% (for example, token-level LCS). Store the *transcript's*
  words as `evidence`, not the model's version. The rule still requires the ask to have been said.

### 17. Memory prompt budgets are fixed per path (MIXED, partial)

- **Values:** `voiceAnswer` 300 (profile only), `meetingAssistant`/`knowledgeAsk` 600, `toolLoop` and
  `scheduledRun` 3,400 (`Persona/AgentPromptContext.swift:56-76`). The `toolLoop` comment still says
  "1,200 + 2,000", but the store budgets are now 2,400 + 4,000 (`NextMemory.swift:61-66`).
- **Harm:** none today, because only 2 facts are stored. After P4-07 and #7/#8, the voice answer lane would
  see only 1–2 of them, whatever the model's window.
- **Change:** derive the limit from `contextTokens`: about 5% of the window in characters×4, with the current
  values as floors. Fix the comment. Fold this into P4-08.

### 18. Meeting brief caps are fixed (MIXED, NEW, low)

`MeetingNotesContextAssembler` caps memory at 700, decisions 500, connections 400, passages 900 (3 × 300)
and files 300 (5) (`Meetings/MeetingNotesContext.swift:104-122`). `MeetingAgent`/`NotesGenerator` already cut
the brief to the window (`briefShare`), so on a 32K+ model these caps waste room. Change: multiply them by
`max(1, contextTokens / 8K)`.

### 19. The routine-suggestion detector needs an exact key (MIXED, partial via P4-06)

- **Value:** `requiredDays = 3`, and the key is the sorted set of content words (`RoutineSuggestions.swift:48,
  57-61`).
- **Evidence:** 68 logged requests produced 58 distinct keys and 0 suggestions. The top keys are `who` and
  `yeah` (2 days each) and `chrome open` (2). This is the exact-set key that D called "too narrow to ever
  fire".
- **Change:** cluster keys by Jaccard ≥ 0.6. Add `yeah`, `who` and `win` to `filler`, and drop keys with only
  one content word. Keep 3 days, because a suggestion must not be noise.

### 20. Background results: session guard and 300-character rule (MIXED, covered by P3-04a)

`VoiceAnnouncementQueue.enqueue` drops a result when the voice session is inactive (`:12-15`). A first
two clauses longer than 300 characters become "There's an update from your background task…" (`:46-48`).
P3-04a deletes the queue. Its D1–D10 cases should include "a result after the session ended surfaces as an
island heads-up card".

### 21 and 22. The island notice is 8 s for every card (MIXED, NEW / fix inside P4-04)

`showAgentReply` and every notice use 8 s (`IslandState.swift:395-397`, `DS.Motion.islandNotice`). A
300-character reply takes about 15 s to read. Hovering helps only if the user reaches the card in time.
Change: add `DS.Motion.islandNoticeFor(text:)`, computed as `clamp(8 + 0.05 s × characters, 8, 30)`.
P4-04's `agentHeadsUp` should use it rather than the fixed 8 s.

### 23. Quiet hours hold a routine's result (MIXED, minor, NEW)

Reminders at a chosen time inside quiet hours are delivered (`AgentScheduler.swift:144`). Routine results
are held until 08:00 (`:646-669`). A digest the user set for 07:00 therefore lands at 08:00. Change: apply
the reminder rule to routines whose own slot is inside quiet hours, and keep holding trigger results.

### 24. ASR bias waits 60 ms for the screen harvest (MIXED, low, NEW)

`AppleSpeechEngine.context()` waits 60 ms (`:150-151`). AGENTS.md measured the Cursor harvest at 133–143 ms,
so for Cursor the bias slice never arrives. This does not affect this Mac, because `engine = parakeet` and
`cleanupEngine = s1Mini` (s1Mini reads no instructions, so the harvest here is used only for file tags).
Change: cache the last harvest per `(bundleID, window title)` for 60 s and hand it to the ASR immediately.
Keep the 60 ms wait for a cold window.

### 25. The review ledger keeps 200 rows (MIXED, diagnostics, NEW, low)

At the current rate (170 dictation jobs in about 30 h), the ledger holds about a day. That is why "200 runs,
2 facts" was read as a lifetime figure. Change: keep 200 rows, and add running totals (`lifetimeRuns`,
`lifetimeSaved`, `lifetimeProposed`, and skip reasons by count) to `agent-memory-review.json` with
`decodeIfPresent`, shown in the Memories sheet.

### 26–35. Limits to keep (HELPS)

- **26–28 (Needle):** each number has a measurement or a named failure behind it:
  - 700 ms debounce: same window as the live agent.
  - 12-character floor: "Yes." is not a request.
  - 20 s cooldown: avoids answering one sentence twice.
  - Confidence floors: calibrated on 0.41–1.00 true positives against 0.19 noise.
  - Echo 0.8: the 2026-09-20 `append_doc` case.
  - Write-only families: a read card "gets the whole feature switched off".

  The missing read-and-tell lane should be P4-05's suggestion lane, not a looser watcher.
- **29, 30 (quote and grounding rules, memory guards):** all 36 guard refusals in the ledger were correct
  (echoes, meta statements such as "The user has no stated preferences…", one line from another speaker).
- **31–33:** AGENTS.md reasons (GPU contention, recording, unattended authority).
- **34:** the look-ahead only arms meetings. The agent's agenda comes from `gws`.
- **35:** consent and the measured wake-word hit rate (17/24).

---

## 3. Top NEW items for the roadmap

| Proposed task | Phase | Items | Why first |
|---|---|---|---|
| **P0-21 Knowledge index default is one bit, and the Agent may use it** | 0 | #1, #2 | One-line defaults, with a self-test. It removes T7 ("I cannot access past meetings") for every fresh install and makes AGENTS.md true. |
| **P1-14 Pending approvals stay visible until answered** | 1 | #5, #6 | Every approval-gated tool and the Needle watcher wait on a card that disappears after 8 s. Lands with P1-07. |
| **P4-10 Post-meeting review fits a 4K window and reads the asks, not just the tail** | 4 (before P4-05) | #3, #4, #16, plus a persisted failure reason | Probe first: `--selftest-agent` on Apple FM printing `reserved/budget`. If `contextTooSmall` is confirmed, meeting follow-ups are dead on today's model. |
| **P4-11 Memory review stops echoing and keeps short facts** | 4 (with P4-07) | #7, #8, #9, #25 | 55% of proposals are echoes and 24% are echo-updates. The 24-character floor drops "My brother is Cyril." Complements P4-07's direct path. |
| **P4-12 Routines run on Apple Intelligence and may be long when their template says so** | 4 (before P4-04/P4-06) | #10, #11, #23 | Without it, the brief, digest, podcast and goal nudges skip on any Mac with no GGUF or cloud. |
| **P4-13 Consent-shaped defaults for proactive meeting features** | 4 | #12, #13, #14, #15 | Needle's in-meeting noticing, meeting follow-ups and a digest's mail read are all off or blocked for a fresh signed-in user, although each still needs an approval or a real consent card. |

Smaller NEW edits to fold into existing tasks:
- #17 goes in P4-08.
- #18 goes in P4-04 (the brief).
- #19 goes in P4-06.
- #21/#22 go in P4-04.
- #24 goes wherever dictation latency work lands.
