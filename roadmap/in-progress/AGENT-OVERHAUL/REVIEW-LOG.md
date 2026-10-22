# AGENT-OVERHAUL — final review log (2026-09-23)

## Current progress reconciliation — 2026-10-03

**Later implementation update:** P6-06q's actual staged153/154 comparison is now
qualified: original40/151 feature failures →fixed151 PASS,10 launch controls and
19 related flags pass. The broader native-tools local grammar failure is reproduced
on both versions under300s and retained. CORE selected only q passes1/1; no parent
or aggregate gate was promoted. P4-07 COMMON155 reproduces13/70 actual typed/voice
failures; fixed156 passes the same70 and all six related flags. Current quick156
fails3/10 against9; native caption/full/CORE/live statement/latency remain open. P4-08's typed route candidate is receiving
a producer-level saved-claim repair before native admission. Three separate
worktrees retain parallel Source ownership; no install or owner quit occurred.

The following paragraph records the earlier documentation-only reconciliation.

Root reconciled STATUS and [the exact completion checklist](REMAINING-WORK.md)
against the actual staged151/152 caller results, failed152 integration, earlier
qualified shutdown pairs, current task ledger and two parallel read-only audits.
The roadmap remains in progress. P3-06/P6-05/P6-06 parents now reflect started
children; no parent or exit gate was promoted. P6-06q records reviewed preparation,
not a native result.

Corrected stale claims: early implementation-eligibility todo wording; Phase3's
already-committed result-folding follow-up; CU-01/02/03 marked entirely unstarted
despite committed browser/single-action repairs. The retained first CU fixed
report still fails one check; later installed CDP output passes11 assertions,
without full AX/coordinate/live acceptance. X02 has a current40-message display
limit as well as restart/correction acceptance work. Phase4's statement extractor
has no production consumer; typed knowledge routing, memory-budget forwarding and
Assembler output sizing remain implementation work beyond the bounded fitting fixes.

Latest model-caller pair qualifies original4/40 target failures → fixed40PASS.
Related152 integration is incomplete after a5.8s NotesModelRuntime trial fails the
unchanged5s budget. Its cause is not attributed to the separate S1 cleanup loop.
Full crash/fast quit, installation, model quality, latency, live UI, recovery/retry,
remote host and product journeys remain open. Prepared57/33/19/49/151 test counts
are not passing evidence. No Source, index, installation or product test mutation
was part of this documentation reconciliation.

Phase4–6 audit: [source/contract findings](../../../Tests/Reports/agent-overhaul-closure/independent-phase4-6-status-audit-2026-10-03/README.md).

**Current sequencing amendment, owner 2026-10-01:** the dated phase-order and 6A entry decisions below are historical. [README §4.1](00-README.md#41-implementation-eligibility-and-quality-gates--owner-decision-2026-10-01) now permits independently verified implementation from actual task contracts while quick/full/owner/latency and product-readiness gates remain unchanged. No historical measurement or task state is rewritten by this amendment.

Reviewer pass over `00-README.md`, `STATUS.md` and the six phase files, against the common
brief and the working tree. Only roadmap files were edited; no source, no build, no git.
Backups of the pre-review files: the session scratchpad (`…/scratchpad/0*.md`, `STATUS.md`).

## 1. What was checked

| # | Check | Method | Result |
|---|---|---|---|
| 1 | Task inventory | script: every `### P#-NN —` heading vs README tables vs STATUS rows; every `P#-NN[a-z]` reference in all files resolves | 56 headings, 70 README/STATUS rows (56 tasks + 14 lettered subtasks); 0 orphans after fixes |
| 2 | Dependencies | extracted every **Depends on**/**Unblocks** line; checked for unknown ids and cycles; compared with README graph and STATUS | no cycles; README graph and STATUS disagreed in ~20 places → regenerated from the phase files |
| 3 | Shared names / APIs | grep of the 18 architecture names across files; compared definitions (P0-07, P1-02, P1-03, P2-05, P3 §2, P5-01) with later uses | 9 conflicts fixed (list below) |
| 4 | Self-test flags | every `--selftest-*` not already in AGENTS.md; every final marker; tier entries | no contradictory double-creation; table appended to README §11 |
| 5 | Numbers and model | grep for 350 ms, ≤ 0.9 s, ≤ 200 ms, 25/30, 280 chars, model names | 350 ms / 0.9 s / 200 ms / 280 consistent; model and 25/30 denominators fixed |
| 6 | Template + anchors | script check of all 14 mandatory labels in all 56 tasks; ~35 file:line anchors re-read in `Sources/NextNotes/` | 3 tasks missing sections (fixed); 2 wrong anchors (fixed); the rest matched |
| 7 | Workflow rules | grep for `make build`, `make install` without `OPEN=0`, bare `swift build`, direct binary launch, `git add -A`, push, commit format | every task's Verify uses `make build` / `make install OPEN=0` / `Scripts/run-selftest.sh`; commit format `P#-NN: …` consistent |

Anchors verified correct (symbol @ line on 2026-09-23): `ModelRoleStore.provider(for:)` 534 / installed branch 569-579;
`InstalledModelLibrary.activeAgentModelID` 96-104, `adoptInRuntime` 124-131; `LlamaBackend` `llama_log_set` 35;
`HuggingFaceModelDetails` 77-92, `architecture:` 264; `prepareDownload` 390; `NotesModelRuntime.openNative` 213,
`chatMLPrompt` 1030, `turnEnd` 1044, `loadIfNeeded` 1105 (wedge branch 1124-1142), `reserveNativeContext` 698,
`releaseNativeContext` 884, `context` 63; `LlamaHelpers.piece` 41; Coordinator `jobs` 21, `inputPending` 22,
`responseID` 24, `inputEpoch` 25, `hasActiveWork` 40, `PendingIntent` 45, `resolveInput` 238,
`waitForInputResolution` 259, `finishFailure` 546 (comment 572), `frontendRequest` 666, `parse` 785,
`cancelPending` 347/525; ToolLoop `RealtimeToolSelection` 17/29, `runModelTurn` 329/353, `coreToolIDs` 594,
`relevantTools` 608, `plannableTools` 635, `plannerSystem` 656, `runPlannedToolLoop` 725/774, round waits
864/915/954, `<tool_call>` check 934, `isStillValid` 999-1000, `publishGrounding` 1093, `runDirectIntent` 1108;
Capture `idleSession` 107, `deliver` 687, `noteLevel` 884, `considerListeningCandidate` 919,
`stageFrontendIfNeeded` 940, `noteModelEOU` 994, `makeEOUCallback` 1071, `considerSpeechInterruption` 1095,
`tick` 1169, `runVoiceBargeSelfTest` 1533; `RealtimeAudioSession.duckedVolume` 49, `pauseForListening` 389;
`ComputeScheduler.running` 87, `acquire` 142; `AgentSpeechSynthesizer.didBeginAudio` 317;
`VoiceAnnouncementQueue.flush` 39; `VoicePlaybackDelivery` `currentGeneration` 29; `AgentTaskManager.beginVoiceObjective`
88, `persist` 291; `AgentToolLoop.runSelfTest` 179; `WorkspaceToolRunner.header` 450, `gmailHeader` 458;
`AgentModelRouting.provider(for:voice:)` 725-726, consent 735; `AgentGrounding` "You are" 67;
`PersonaStore.builtInBaseText` 66; `LocalVoiceFrontend.streamSplitDecision` 483, `stageNextTurn` 128;
`routeMaximumResponseTokens` 158; `AgentPromptContext.system` 134; `ScheduledRunner` "Now:" 446;
`LiveScheduleEnvironment` 1267; `RealtimeAgent.localModelProviderForTesting` 118, `voiceSafeReply` 178, `beginWork` 516.

## 2. What was fixed

### Inventory and titles
- `01-PHASE-0`: all 16 headings changed from `### P0-NN: title` to the template form `### P0-NN — title`
  (the other five files already used it; grep and the template now match everywhere).
- `00-README.md` §3: every title replaced with the exact heading text of its phase file (about 30 had drifted);
  lettered subtask rows added (P0-14b, P1-10a/b, P2-03b, P3-03a/b, P3-04a/b, P3-06a/b, P3-07a–d); per-phase
  execution order lines added (P3 migration order in particular, which is not numeric).
- `STATUS.md` ledger rewritten: titles = headings, one row per lettered subtask, **Depends on** column copied from
  the phase files (it previously disagreed for P1-10, P2-03, P3-03/04/05/08, P4-02/04/06/09, P5-01/03).
- P0-14b is defined only inside P0-14 step 8; P0-14's header now says so and names its extra dependencies
  (P0-11; green only after P0-01).

### Dependencies
- README §4 mermaid graph regenerated from the phase files' **Depends on** lines. Old graph had P3-01→P3-03 and
  P3-04→P3-06 (phase file: P3-06a precedes P3-03 and P3-04), P5-01→P5-03 (phase file: P5-03 needs P5-02, P5-04),
  missing P0-07→P1-05/P1-07/P3-01, P1-02→P1-06/P1-07, P1-04→P1-09, P1-06→P1-05, P3-08→P5-01.
- Unblocks lines completed: P0-07 (+P1-05, P1-07, P3-01), P0-06 (+P2-03), P0-11 (+P3-01, P4-04, P4-07),
  P0-01 and P0-03 (+P4-09).
- P1-10 had no **Depends on** field; added (a: P1-01; b: P1-04, P1-02).
- P4-09 depends on P0-14 (it checks P0-14's read-only resolution; text wrongly said P0-03 owns it).
- P4-04 notes P3-04 as the dependency of its spoken path (documented fallback without it).
- P5-01 (and the Phase 5 preconditions) now depend on P3-08: `respond_approval` is only offered under P3-08's rule.
- Report D's own recommendation numbers ("P1-11", "P2-16", "P0-3" …) in Phase 4/0 Finding lines collided with task
  ids; relabelled "D-report item …".

### Shared names and API signatures (later phases aligned to the defining phase)
- `mayCommitEffect`: P0-07 defines `RealtimeAgent.mayCommitEffect(risk:)` (+ coordinator `mayCommitEffect()`).
  P1-05 called `mayCommitEffect(taskID:revision:)` → aligned. P3-02's closure called
  `Coordinator.mayCommitEffect(workID:revision:risk:)` → aligned to P0-07's function; P3 §2.5.1 table said reads
  "waited through the closure" under P0-07 → corrected (the gate returns at once for reads; round waits still apply).
- `Interruption`: P2-05 created `Agent/Voice/VoiceEvents.swift` with a payload-less enum while P3 §2 defines it in
  `Agent/Duplex/VoiceContracts.swift` with `TurnID`/`TaskID` payloads → P2-05 now creates the P3 file with a
  placeholder enum; P3-06a step 1 replaces it and updates P2-05's call sites.
- `FrontendResponder`: P3-05 defines a concrete `actor FrontendResponder` but said P5-01 would add
  `protocol FrontendResponding`; P5-01 said "grep `protocol FrontendResponder`". Aligned: P5-01 turns
  `FrontendResponder` into the protocol and renames the actor `LocalFrontendResponder`.
- P5-01/P5-02 put frontend selection "in the reducer" (P3's reducer is pure) → moved to the `VoiceSession` shell;
  `beginSession` → `sessionOpened`; `requestResponse(...) -> OutputID` → takes an `OutputID` (only the shell and
  `OutputScheduler` mint ids, P3 §2.1); "mint an `OutputID`" → ask `OutputScheduler`; `TaskBridge.spawn(objective)`
  returning a `TaskID` → `spawn(objective:userWords:origin:backend:)` returning a `TaskReceipt`; `TaskEvent`
  `sources` spelled out as a fourth associated value of `.completed`.
- `AgentCapabilityManifest.current(reader: .voiceFrontend)` was used by P1-03/P1-07 but never defined → P1-03 step 8
  now defines `current(reader: Reader = .agentRole)` and the `voiceFrontend` / `agentRole` presets.
- Phase 4 used `OutputScheduler.enqueue(OutputRequest(kind: .proactive, …))`; P3-04's API is
  `enqueue(_ item: DeliveryItem)` → aligned, with `DeliveryKind.proactive` added by P4-04.
- P4-06 used the coordinator's `PendingIntent`, which P1-07 replaces with P1-02's `PendingAction` → aligned
  (`offer(_ action: PendingAction)`, typed slot `typedPending`).
- P3-05 and Phase 4 named the live eval file `Agent/RealtimeAgentLiveEvalSelfTest.swift`; P1-01 creates
  `Agent/LiveEval/ToolLoopLiveEval*.swift` → aligned.
- P3-05's "cheap reads" frontend tools had no link to P1-03's `manifest.frontendTools` → one sentence added
  (not built in Phase 3; if built later, from the manifest).

### Self-test flags
- No flag is created twice. Several are extended by many tasks; each keeps one marker.
- P3-04 "replace :56-86" of `--selftest-voice-delivery` would have deleted P0-09's and P2-06's cases → now says to
  keep them and replace only the old announcement cases.
- Live-eval denominator: Phase 4 "added eight cases" and still gated on "≥ 25/30"; three of the eight already were
  P1-01 cases (N01, N02, R01). P1-01 now has a `scored: false` flag for appended cases and a separate
  `TOOLLOOP_LIVE_EXTRA n/m` tally; Phase 4 adds five extra cases (D01, D02, D03, Y03, K04) and its gate/STATUS row
  say exactly what must pass. P3-05's filler cases are also `scored: false`.
- README §11: table of 18 new flags (task, file, final marker, tier) and 22 extended flags.

### Numbers and model
- Phase 1 still said the Agent-role model was K2-Horizon-4B (three places: the P0-01 check, the exit gate, P1-04's
  "captured outputs") → Qwen3-4B-Instruct-2507 Q4_K_M per P0-01; P1-04 now tells the executor to capture samples
  from live-eval reports (P0-04 stores none).
- STATUS Phase 2 gate measured the 0.9 s target with `--selftest-voice-pipeline`; the phase file measures it with
  `--selftest-voice-latency` (median of 5) → aligned, with the other §0.7 criteria.
- Phase 1 exit row in STATUS now carries "two consecutive runs, 0 LEAK, 0 ERROR".

### Template and anchors
- P0-16 lacked Why / Current / Target / Steps / Do not → added briefly (decision task).
- P4-08 and P4-09 lacked **Steps** → added numbered steps derived from their Target sections.
- P0-13: `InstalledModelLibrary.shared.add(newModel)` is at `ModelLibraryStore.swift:506`, not `:520`.
- P5-01: `--selftest-realtime` is at `NextNotesApp.swift:784`, not `:777`.
- README §7: baseline fixture path (`agent-overhaul/haiku16k.wav`) differs from P2-01's
  (`voice-fixtures/haiku16k.wav`, different sample format) → note added: compare latencies within one fixture.

## 3. Known issues the executor should be aware of (not fixed)

1. **Line numbers will drift.** Phases 0–2 edit the same files Phases 3–4 cite (ToolLoop, Coordinator, Capture).
   Every anchor carries a symbol name; grep it. Line numbers inside Phase 3/4 were correct on 2026-09-23 only.
2. **Model precondition.** Nothing in Phase 1 onward can be graded until the owner completes P0-01 (delete
   K2-Horizon, install Qwen3-4B-Instruct-2507, ~2.5 GB with ~4 GB free). Expect `_ABSENT` until then.
3. **`--selftest-toolloop-live` is ~2.5 h per full run** (9,300 s budget). Use `--only` while iterating.
   *Addressed on 2026-09-23 (evening): `--quick` (10 fixed cases) is now the per-task gate; see §4.*
4. **Phase 3 contracts are large** and written ahead of the code; P3 §2 says to adapt signatures to what earlier
   tasks actually shipped (grep first). Where that happens, record a line in STATUS "Decisions and deviations".
5. **`TaskBridge` isolation**: the decision doc says actor; P3 deliberately uses `@MainActor final class`
   (reasoned in P3 §2.5). Not changed.
6. **P2-02 ↔ P1-03/P1-07** and **P2-03 ↔ P1-07** are "coordinate with" notes, not hard dependencies; Phase 1 lands
   first anyway because phase order is strict.
7. **Vendor facts in Phase 5** (model ids, event names, prices) were checked on 2026-09-23 by the writer, not by
   this review; P5 already says to re-verify on the day.
8. **Live-only steps** (P0-01 owner actions, P2-05 echo-live, P2-08 microphone, P5 live runs) need the owner; the
   executor asks and records, never clicks or grants.
9. The Phase 4 exit item 6 (one real weekday of observation) cannot be satisfied unattended.

## 4. Integration of report G (2026-09-23 evening)

Source: `roadmap/done/agent-analysis-2026-09-23/G-model-comparison.md` (real turns on Apple FM, MiniCPM5-2B
GGUF and OpenRouter `inclusionai/ling-3.0-flash-sante:free`). Only files in this folder were edited.
There were no source edits, no build and no git. Pre-edit copies are in the session scratchpad
(`…/scratchpad/bak-*.md`). Every new file:line anchor was re-read in `Sources/NextNotes/` on
2026-09-23 and carries its symbol name.

### 4.1 New tasks and where G's defects went

| G defect | Task | Phase | Placement reason |
|---|---|---|---|
| N1 OpenRouter reasoning eats the cap; `finish_reason` ignored | **P0-17** | 0 | Broke 4/6 ling-3.0 turns together with P0-05's 112 cap. Linked both ways, and they land in the same session. Extends `--selftest-openrouter-contract` and `--selftest-toolloop-production`. |
| N2 no llama KV prefix reuse; wasted typing prewarm | **P0-18** | 0 (not early Phase 2) | (1) Phase 1's eval re-prefills 1.2–2.3 k tokens on every pass, so every per-task gate pays it. (2) The `voiceRoutingSystem` comment (`ToolLoop:492-493`), P4-01's section order and risk note, and P3-07b's slots all **assume** reuse. (3) It is confined to `NotesModelRuntime` and the typed prewarm, not the voice pipeline P2-01 measures. P4-01 and P3-07b now depend on it. New flag `--selftest-llm-prefix-cache`. |
| N3 MiniCPM5 tool delimiters are control tokens | folded into **P0-04** | 0 | P0-04 already owns special-token rendering. Added a `minicpm5` family row (detected by `tokenizer.ggml.pre` or `<function name=`), a generic explicit-BOS rule, and self-test case 5 (pure detection plus a live vocab check when the GGUF is present). The marker is now "6 families". P1-04 recogniser 5 also accepts `<param name=…>`. |
| N4 OpenRouter responses in the disk URL cache | **P0-19** | 0 | Privacy. `PrivateURLSession` (ephemeral, `urlCache = nil`) and a one-time `URLCache.shared.removeAllCachedResponses()` at launch (outside the harness). **Scope extended beyond G:** the Google OAuth and Calendar, MCP and Composio calls use the same shared session and carry the same kind of data. Model downloads and public metadata are excluded. New flag `--selftest-private-network`. |
| N5 replies claim tools that did not run | **P1-11** | 1 | A post-generation `ToolClaimGuard` (one re-plan, then an honest sentence), a speech hold, and a history view with stale claims scrubbed. P1-01's grader gains a `FABRICATED` verdict, so the eval measures it. P4-02 and P4-03 carry a "keep the guard" note. |
| N6 Codex retried while out of quota; fallback ignores the Agent role; raw error shown | **P1-12** | 1 | `CodexQuotaStore` with a parsed reset date (the parser fixture is captured from the real audit line, not guessed), `.outOfQuota` readiness, one plain sentence per quota window, and `.app` falling back to `provider(for: .agent)`. Extends `--selftest-model-roles`. P0-14 unblocks it. |
| N7 "google calendar" opened google.com | **P1-13** | 1 | Extends P1-08's functions and table: multi-word Google site phrases first, words consumed, and a strict parse that sends leftover nouns to the planner. The loose (voice) parse never returns less than today (AGENTS.md: gates may only add). |
| N8 no record of which model answered | **P0-20** | 0 | One `agent.model_pass` span per model call, with `ModelPassRecord` (provider, model, path `text`/`voice`/`worker`, pass, tokens, first-token and total seconds). **P2-01 now depends on it**, and its `source` field reuses the same path strings. Extends `--selftest-metrics` and `--selftest-toolloop-production`. |

G's own ids ("P0-17", "P2-09", "P1-11") were suggestions. P0-17 and P1-11 match; G's "P2-09" became
P0-18 because of the placement decision above.

### 4.2 Other changes

- **Apple FM's window.** G measured 8,192 tokens (`tokengenerationcore`); the roadmap and the code
  said 4,096 (`FoundationModelLLMProvider.contextTokens = 4_096`, `:13`). I confirmed that the SDK
  interface declares `SystemLanguageModel.contextSize`, back-deployed to macOS 26.0. P1-10a step 0
  now reads it at runtime, with 4,096 as the fallback. Corrected wording in:
  - the README glossary;
  - Phase 1: fact 11, exit gate item 2, the P1-03 `voiceFrontend` reader and budget case, and the
    P1-10 "Why";
  - Phase 3: the `AgentDeliveryTiming` comment;
  - Phase 4: P4-02 risk, the P4-03 voice card and risk, and the P4-08 "Why", Target and threshold.

  Scripted 4,096-token readers in tests are kept as the worst case and labelled that way.
- **Live eval runtime.** P1-01 gains `--quick`, a fixed `quickIDs` list of 10 cases (C01, C04, M03,
  M04, M05, K01, R02, F03, A02, N04), with a table mapping each case to the failure class and fix it
  exposes.
  - It prints `TOOLLOOP_LIVE_ELAPSED`, targets ≤ 20 min, has a 3,300 s timeout, a pass bar of 9/10,
    and is exclusive with `--only`.
  - Every P1 task's Verify now runs `--quick` (plus its own `--only` cases) instead of a full run.
    The "total score" thresholds compare quick with quick.
  - Full runs remain for the baseline, the Phase 1 and Phase 4 gates, P1-05's default flip and P4-03.
  - Updated the README workflow step 11, the flags table, the Phase 4 "How the live eval is used"
    paragraph, and STATUS's Phase 1 gate row ("full runs, not `--quick`").
- **P0-01.** Records the evening machine state:
  - `modelRoles.agent = cloud` (ling-3.0, a reasoning model);
  - `activeAgentModelID` = MiniCPM5-2B;
  - `computerUse = app:codex`.

  New step 1b gives G's model-per-role advice as owner actions:
  - voice stays on Apple FM;
  - typed uses Apple FM or a non-reasoning OpenRouter model until P0-05 and P0-17;
  - "Controlling your Mac" moves off Codex until P1-12.
- **D-report label collision.** Phase 4's "D-report item P1-11" and "items P1-12, P1-13" now collide
  with real task ids. They are relabelled `D:P1-11` / `D:P1-12` / `D:P1-13`, with "not this roadmap's
  …".
- **Dependencies added:**
  - P0-18 ← P0-04, P0-06, P0-14;
  - P0-12 ← P0-17…P0-20;
  - P2-01 ← P0-20;
  - P3-07b ← P0-18;
  - P4-01 ← P0-18;
  - P4-09 ← P0-17, P0-19, P0-20;
  - P1-11 ← P1-01, P1-04 (soft P1-10b);
  - P1-12 ← P0-14 (soft P1-10b);
  - P1-13 ← P1-08.

  Unblocks lines on P0-03, P0-04, P0-05 and P0-14 were updated to match. The README mermaid graph,
  the task tables and the order lines, the STATUS rows (and two baseline rows) and the README §7
  baseline loop (`openrouter-contract`, `metrics`) were all updated.
- **P5-02.** Its websocket is created from `PrivateURLSession` (P0-19).

### 4.3 Checks run

- Script: 63 `### P#-NN —` headings; 77 README rows and 77 STATUS rows (63 tasks + 14 lettered
  subtasks); every heading appears in both.
- Every `P#-NN` reference resolves, except report D's own labels in Phase 4, which are marked as
  such.
- All 16 template labels are present in P0-04, P0-17…P0-20 and P1-11…P1-13.
- Anchors re-read today:
  - `OpenRouterLLMProvider` `complete` 418, `streamConversation` 440 (`guard emitted` 467),
    `parseStreamLine` 477-486, `makeRequest` 495-512, `ChatRequest` 523, `StreamEvent` 536,
    `supportsReasoning` 227, `URLSession.shared` 307/361/421/453/612/630;
  - `NotesModelRuntime` `llama_memory_clear` 520/595, `prepareForConversation` 347 (voice system
    prompt at 354, `context == nil` at 350), `ensureContext` `contextSize == size` 1242,
    `decodePromptWhileScheduled` 472;
  - `LlamaHelpers.piece` `special=false` 43/46;
  - `AgentView` prewarm 97-98;
  - ToolLoop `QuickTurnResult` 10, the 112 cap 414/418, "incomplete response" 484, the
    `voiceRoutingSystem` comment 492-493, conversation context 814-819, planner stream 884-892,
    `mayBeDenial` 904, text-only return 931-955, "tool planner failed" 929;
  - `CodexComputerUse.route` 183-202, `errorDescription` 133-147, readiness enum 431;
  - `ModelRoleStore` `.builtIn, .app` 581-582, `builtInProvider` 585-592, the computer pattern 659,
    `AgentModelRouting` 725-726;
  - `AgentDirectIntent` `knownSites` 60-68, `namedURL` 138-156, `namedApp` 157-172;
  - `LatencySpan` 227, `runSelfTest` 340, `MetricsStore.shared` 13-16;
  - `FoundationModelLLMProvider.contextTokens` 13;
  - pinned `llama.h`: `llama_memory_seq_rm` 739 (returns false on a partial removal it cannot do).

### 4.4 Known issues introduced or left open

1. **`--quick` in `make acceptance`.** Acceptance entries take no arguments, so the INTEGRATION entry
   stays a full run (`|9300`). Per-task quick runs are by hand. `make acceptance TIER=core`, which is
   the phase-gate command, does not include the eval.
2. **P1-03's small-reader budget** (`reader.contextTokens ≤ 4_096` → the smaller capability budget)
   will no longer apply to Apple FM once P1-10a reads 8,192. That is intended (more room), but P1-03's
   executor should re-check the `--selftest-capability-manifest` budget case against the runtime
   value.
3. **P0-17's "unknown means send `reasoning`"** relies on OpenRouter ignoring the field for models
   without reasoning. That is documented by OpenRouter but unverified here. The task has a 400
   fallback and a live check (`OPENROUTER_REASONING`).
4. **P0-18's equality check** (the first 4 tokens identical with and without reuse) could in rare
   cases differ, because batched and incremental decoding can round differently. The task says to
   drop to 1 token and record it rather than remove the check.
5. **P0-19 case b** may not reproduce a cache entry on the unmodified code if `URLCache` skips a POST
   in the fixture. The task keeps the configuration check and a source grep as the red evidence, and
   says to record that in STATUS rather than weaken the test.
6. Reports B (D4, D12) and P4-01's rationale were written assuming prefix reuse and a 4,096 FM window.
   The reports themselves were not edited (outside this folder). The roadmap text now points at
   P0-18 and the runtime window.


## 5. Integration of the caps audits H1–H3 and the owner's requests (2026-09-23 night → 2026-09-24)

**Added while execution was in progress; new IDs are appended; done tasks were not modified.** The P0-05 and P0-09
rewrites below were made on 2026-09-23 before the executor picked those tasks up, and the executor implemented the
rewritten text (`6ad6ade`, `05401af`). After the folder moved to `roadmap/in-progress/`, only `todo` tasks were
amended; STATUS rows were inserted, never rewritten.

Sources: `roadmap/done/agent-analysis-2026-09-23/H1-caps-model-tools.md`, `H2-caps-voice.md`,
`H3-caps-proactive-memory.md`; owner requests (remove the 112 cap explicitly; usage and provenance logging for Agent,
Meetings and Dictation; a separate DICTATION-MEETINGS-LIMITS roadmap). Pre-edit copies:
`…/scratchpad/bak-H/*.md`. No source edits, no build, no git.

### 5.1 ID mapping (the audits' own IDs collided: H2 and H3 both proposed "P0-21", "P1-14")

| Audit item | Audit's proposed ID | Final ID | Note |
|---|---|---|---|
| H1 #11, H3 #1 knowledge-index default split | H3 "P0-21" | **P0-21** | deduplicated (found by both) |
| H1 #12, H3 #2 knowledge tools off by default | H3 "P0-21" | **P0-21** | merged with the above; P1-03 gets a line |
| H1 #13 false multi-step notices | — | **P0-22** | |
| H2 V2 "That wasn't for you" is telemetry only | H2 "P0-21" | **P0-23** | |
| H2 V3 + V4 silencer on words; stop at 400 chars | H2 "P0-09 amendment or P0-22" | **P0-09** (amended before execution; done `05401af`) | fixes H2's finding that P0-09 could not pass its own red test |
| H2 V1 echo filter erases "yes" | H2 "P1-14" | **P1-14** | lands before P1-07 |
| H2 V16 goodbye by substring | H2 "P1-15" | **P1-15** | |
| H3 #5, #6 approval cards vanish after 8 s | H3 "P1-14" | **P1-16** | |
| H1 #22 `agentAutoRunReadTools` half enforced | — | **P1-17** | |
| H1 #9 history fixed in characters; 10,000 ceiling | — | **P1-18** | moves P4-08 steps 1–2 into Phase 1 |
| H2 V15 no addressee decision | H2 "P3-10" | **P3-10** | |
| H3 #3, #4, #16; H1 #25 post-meeting review | H3 "P4-10" | **P4-10** | H1 #25's logging half → P0-20b |
| H3 #7, #8, #9, #25; H1 #23 memory review | H3 "P4-11" | **P4-11** | |
| H3 #10, #11, #23 routines | H3 "P4-12" | **P4-12** | |
| H3 #12–#15 proactive defaults | H3 "P4-13" | **P4-13** | |
| Owner: usage and provenance log | — | **P0-20a–e** | P0-20 was `todo`; widened in place into five subtasks |

Amendments to existing `todo` tasks: see §5.3.

### 5.2 Owner requests

1. **112-token cap.** P0-05 was rewritten (2026-09-23) so the typed budget is
   `min(depth budget, contextTokens − promptTokens − 256)` with no literal cap, the cost note, and the four
   `AgentAnswerBudget` kinds; the executor shipped it (`6ad6ade`). What it left open: (a) the planner's literal
   `maxTokens: 256` (`RealtimeAgent+ToolLoop.swift:909`, `:912`) → P1-02 step 6 now calls
   `AgentAnswerBudget.tokens(kind: .plannerRound(…))`; (b) the same-session pairing with P0-17 did not happen →
   P0-17 carries a pairing note and is next on the typed path. No new follow-up task was needed: both remainders
   are in `todo` tasks.
2. **Usage log.** Decision: a new `usage.jsonl`, not `metrics.jsonl` — `MetricsStore` is a 512-span ring rewritten
   at 1,024 lines that held only ~31 h on this Mac (603 rows, 2026-09-22 20:17Z → 09-24 03:38Z, measured), and it
   decodes the whole file at launch. `usage.jsonl` is the single persistent sink: G N8's per-pass record, P2-01's
   per-turn headline stages (`pass: "turn"` rows), meetings and dictation. `metrics.jsonl` stays the short stage
   ring; `runs.jsonl` and `agent-audit.jsonl` gain no timing fields and are joined by id. Schema, privacy rules and
   rotation (8 MB × 2 files, 90 days) are in P0-20. `ModelPassRecorder` keeps its name so P0-17 and P0-18 need no
   edit.
3. **DICTATION-MEETINGS-LIMITS.** 00-README §13: a separate roadmap in `roadmap/done/DICTATION-MEETINGS-LIMITS/`
   that depends on P0-20b and P0-20c for its measurements (the empty folder already exists).

### 5.3 Amendments (all to tasks in `todo`; marked "(H-audit 2026-09-23)" in the text)

| Task | What was added | Source | Depends-on change |
|---|---|---|---|
| P0-02 | step 7 + case 5: the sheet never recommends deleting the only model that answers | H1 #24 | — |
| P0-17 | pairing note: P0-05 landed alone; P0-17 next on the typed path; `visible + allowance` clamped to the window | owner, H1 #2 | — |
| P0-20 | widened into P0-20a–e (unified `usage.jsonl`) | owner, G N8, H1 #25, H3 #3/#25 | P2-01, P4-05, P4-09, P4-10 now read P0-20a/b |
| P0-12 | AGENTS.md trap text now describes `usage.jsonl`, not `agent.model_pass` | — | — |
| P1-02 | step 6 calls P0-05's `AgentAnswerBudget.tokens(kind: .plannerRound(…))` for the literal 256 at `ToolLoop:909/:912`; P0-17 pairing note | owner | — |
| P1-03 | knowledge-tool availability from the two switches whose default P0-21 sets | H3 #2 | soft P0-21, P1-17 |
| P1-04 | first repeated call → one "already ran" note (counts as a repair); second → P1-06's final round | H1 #20 | soft P1-06 |
| P1-06 | rounds = calls + 2; one final answer-only round (also the call-cap exit, keeps `lastVerifiedResult`); a revision restarts the round clock (refill ≤ once per 10 s); dead `Limits.cloudTool` removed; cases 6–9 + a `--selftest-voice-work-lifecycle` case | H1 #17–19, #30 | — |
| P1-07 | depends on P1-14; one shared acknowledgment vocabulary with P3-08 | H2 V13, V22 | +P1-14 |
| P1-10a / P1-10b | reader-scaled result cap (700 / 1,200 / 4,000 / 12,000; 2× for document reads; Workspace reads the same function); error sentences keyed on the outcome, never answer text; a speakable answer is spoken | H1 #10, H2 V5, V18 | — |
| P2-01 | depends on P0-20a; `source` without a model field; step 6b writes one `pass: "turn"` usage row per voice turn | owner | P0-20 → P0-20a |
| P2-05 | optional owner-gated step 7: full speaking level, duck only on onset | H2 V29 | — |
| P2-08 | delivery lane bounded by ≥ 1.0 s of audio, not 8 callbacks | H2 V24 | — |
| P3-03 (a) | unambiguous cancel phrases, newest task when several run; work-status block fitted to the FM window (1,200 / 250) | H2 V21, V19 | — |
| P3-04 (a) | D13: a result after the session ended surfaces as an island heads-up and stays pending | H3 #20 | — |
| P3-07 (a) | measure FM beside a Parakeet window; overlap flag only after three verdicts < 15 % | H2 V26 | — |
| P3-08 | conversation leaves the ACP "Run once" card up | H2 V23 | — |
| P4-04 | `DS.Motion.islandNoticeFor(text:)` reading time; brief caps scale with the reader | H3 #18, #21, #22 | +P4-12 |
| P4-05 | read the `meeting.proposals` usage rows first | H1 #25 | +P4-10, P0-20b |
| P4-06 | suggestion detector clusters keys (Jaccard ≥ 0.6), more filler words | H3 #19 | +P4-12 |
| P4-07 | cross-reference to P4-11 | H1 #23 | — |
| P4-08 | steps 1–2 moved to P1-18; memory prompt budget from the window; Assembler page `min(1_500, contextTokens/4)`; voice history 1,400 stays | H3 #17, H1 #29, H2 V20 | +P1-18 |
| P4-09 | `agentCloudConsent` seeded true when the stored Agent role is already `.cloud` | H1 #16 | — |

Not amended because the task was already done: P0-05 (`6ad6ade`) and P0-09 (`05401af`) — both were rewritten
before execution and shipped as rewritten; their remainders are in P1-02 step 6 and P0-17.

### 5.4 HELPS items

Not turned into tasks. Listed in 00-README §12 "Limits we keep on purpose" so the executor never removes them as a
side effect.

### 5.5 Checks run

- Script: 81 `### / #### P#-NN —` headings (63 + P0-20a–e + 13 new); every new or split task has all 16 template
  labels; every `P#-NN` reference resolves except report D's own labels (P2-16…P2-20), as before.
- STATUS: 23 rows inserted (P0-20a–e, P0-21…P0-23, P1-14…P1-18, P3-10, P4-10…P4-13); existing rows untouched,
  including the executor's state/evidence/commit cells; one line appended to "Decisions and deviations".
- README: task tables, order lines, file map, mermaid graph (new nodes and edges), glossary (`usage.jsonl`,
  `AgentAnswerBudget`), flags tables (3 new flags, 15 extended rows), §12 "Limits we keep on purpose", §13
  DICTATION-MEETINGS-LIMITS.
- Anchors re-read in `Sources/NextNotes/` on 2026-09-24 for the coordinator's tasks: `AgentAnswerBudget` (shipped),
  planner `maxTokens: 256` `ToolLoop:909/:912`, `MetricsStore.defaultRingCapacity` :19 and rewrite :55,
  `LatencySpan` :227, `DictationController` tail `:938`, `:957`, `:976`, `:1062-1078`, `recordRun` :1303, `record:`
  seam :447, `DictationRun.id` :11, `RunLog` :108, `AgentAuditLog` :139-160, `NotesGenerator.notes` :57 with
  `complete` at :81/:150/:181, `NotesService.generate` :43, `MeetingAgent.plan` :194/:211, `fit` :409,
  `AgentService.review` :197 and live :596/:614, `ChunkedTranscriber.transcribe` :254, `TranscriptionQueue` :398/:402,
  `DiarizationService.diarize` :91, `FunctionCallWatcher.propose` :425/:449, `MemoryReviewer.review` :598/:609,
  `ProviderMemoryReviewModel` :322, `ScheduledRunner` :531/:533, `KnowledgeAsk` :140, `ACPAgentBackend.submit` :57,
  `CodexComputerUse.route` :184, `Settings` :1078/:1083/:705, `KnowledgeIndexSettings` :5-41, `KnowledgeToolGate`
  :18-41, `MultiStepNotices` :809-829, `EndpointSource` :111, `endSession` :358, `IslandView` button :439,
  `IslandState.showAgentReply` :395, `WakeWordTelemetry.falseAccepts` :48, `AgentSpeechPolicy` :16-17/:174/:292/:526,
  `ModelLibraryStore.recommendsDeletingOld` :461, `ModelDownloader.minimumFreeBytesAfterDownload` :40,
  `NotesModelRuntime` limits :53-63. The phase writers re-verified their own anchors (P1, P3, P4 files).
- Measured for the P0-20 decision: `metrics.jsonl` 603 rows / 310 KB spanning 2026-09-22 20:17Z → 2026-09-24 03:38Z.

### 5.6 Known issues

1. **Lines keep moving under execution.** `AgentCaptureController.swift`, `NextNotesApp.swift` and
   `NotesModelRuntime.swift` changed during this pass (P0-06, P0-10). Every anchor carries a symbol; grep it.
2. **The P0-20 parent row in STATUS** keeps its old title (rows are never rewritten while the executor works). The
   phase file is authoritative; tick the parent when P0-20e is done.
3. **P0-20a's tool `ms` for writes** must exclude the approval wait; the task lets the executor choose between
   measuring after approval and subtracting the gate's wait, and says to record which in STATUS.
4. **P4-13 depends on P4-04** (its writer added it for `--selftest-proactive`), so P4-13 lands after P4-04 and P4-05 in
   the Phase 4 order.
5. **The H2 V24 amendment (P2-08)** changes a queue bound in the capture path; it is gated on `--selftest-capture`
   and the owner's via-open microphone run, which cannot be done unattended.
6. **`--usage-report`** is a diagnostic in the `--notes-context-live` shape, run through `Scripts/run-selftest.sh`
   with `--out`; it is not in `make acceptance` (it reads the real store on purpose).
7. The three phase writers were cut off once by a usage limit (no edits landed) and re-run on the moved folder;
   their final text was checked by the script above, not re-read line by line.

---

## 6. Integration of the multi-agent durable-jobs roadmap (2026-09-25)

**Input:** `roadmap/todo/next-notes-multi-agent-durable-jobs-memory-roadmap.md`. It was written on
2026-09-23 against `5b16b2c` as a standalone architecture proposal — a separate `AgentJob` type, a
separate `AgentResultBus`, an `AgentUsageLedger`, an `AgentToolScope`, a `MemoryTier` and a
Proposer/Adversary/Judge consolidation pipeline, over eleven phases.

**Method.** Rather than re-review it as a fresh document, it was first rewritten against the tree at
`78cebc9` and every type it named was grepped for. The result: **none of them exist**, and **five
of the subsystems it proposed building already exist and are finished**. That audit is what made
this integration a fold rather than a merge, and it is kept in the source file (§1–§3) because it is
the reusable part.

### 6.1 ID mapping

| Source phase | Fate | Destination |
|---|---|---|
| 0 metrics | absorbed | P0-20a–e (done), P2-01, **P6-07** |
| 1 `AgentOrchestrator`, `spawn_agent` | **deleted (duplicate)** | P3-03a/b `TaskBridge` — already has `TaskState`, `TaskRecord`, `TaskEvent`, `TaskReceipt`, and a `spawn` that returns in milliseconds |
| 2 `ExecutionAgent`, `AgentToolScope` | **deleted (duplicate)** | P1-03 `AgentCapabilityManifest`, P1-05 |
| 3 durable jobs | **new phase** | **Phase 6**, P6-01…P6-10 |
| 4 result bus + observability | channel **deleted (duplicate)**, job view **new** | P3-04a/b D11/D13 for the channel; **P6-08** for the view and `--jobs-report` |
| 5 action lanes | **not made tasks** | requirement recorded in `STATUS.md` against P1-03 and P3-04 |
| 6 revisions + multi-job context | **split** | **P6-09** (revisions survive restart); P3-06 (multi-job context in one conversation) |
| 10 parallel worker graphs | **new task** | **P6-10** |
| 7.0 provenance survives the write | **became a lettered subtask** | **P4-07a**, in `05-PHASE-4-PROACTIVE.md`. Prerequisite for P4-07 and P4-11 |
| 7 tiers, 8 consolidation, 9 auto-apply | **left behind, renamed** | `roadmap/backlog/memory-lifecycle-consolidation-roadmap.md` |

The source file was **deleted** at the end of this integration. Its unique remainder became P4-07a
plus that renamed roadmap; its §0/§2/§3 (absorption map, design rationale, corrections table) is
duplicated here in §6.1/§6.2/§6.3 and in `07-PHASE-6-DURABLE-JOBS.md`.

No existing id was renumbered and no existing row was rewritten. The new ids are `P6-*`.

### 6.2 Four proposals rejected, and what replaced each

| Rejected | Because | Replaced by |
|---|---|---|
| A separate `AgentJob` type | `TaskID.raw` **is** `AgentTask.id` — the same UUID string `agent-tasks.json` holds (P3 §2.1) — and `TaskState` already has a legal-transition table with a persisted-status mapping | `TaskRecord` + `TaskDurability` (Phase 6 §2.1), with a hand-written `init(from:)` per the `Meeting` rule |
| A separate `AgentResultBus` | D11 already makes the compiler enforce that only `OutputScheduler` starts audio; D13 already covers "finished with no session open"; D8 already carries pending deliveries across a close | `OutputScheduler.enqueue` (P3 §2.6.1), with Phase 6 persisting what `setDelivery` sets |
| `AgentUsageLedger` + a `job_usage` table | P0-20a already built the log, its 8 MB rotation, its 90-day compaction, its `sanitise` and its harness temp isolation | `UsageRecord.taskID` and a sum-on-read projection (P6-07 §2.7). Cost stays `nil` — nothing prices a pass |
| `AgentToolScope` | P1-03's manifest is the per-turn source of truth, and the caps that motivated scoping are in §12 (maxTools 8, maxCalls 3; confidence is not comparable across tool sets) | P1-03; P6-10 only *asserts* the fan-out respects it |

A fifth proposal, `MemoryTier`/`MemoryLineage`, is neither rejected nor absorbed: it is blocked on
its own audit finding and is left in the source file (§5.1 there).

### 6.3 The memory half, and why it is one task plus one roadmap rather than a phase

Three reasons, recorded so it is not re-litigated:

1. **A phase whose gate cannot be evaluated is not a gate.** Consolidation's exit is precision and
   recall against a ten-category fixture corpus, **and that corpus does not exist yet.** Building it
   is itself work, and §12's standing rule is that a threshold is only believable with a
   measurement behind it. Adding a phase for it would make Phase 4 unpassable for every other task
   in it — so the work stayed a roadmap in `todo/`.
2. **It has a structural prerequisite the source proposal missed.** `MemoryProvenance`
   (`Memory/MemoryGuard.swift:8`) is a `@TaskLocal` gate consulted *before* a write, and what lands
   on the entry is three flat fields — `origin`, `sourceLabel`, `confidence` — written at
   `NextMemory.swift:633` and `:674-675`. Lineage cannot be built until the write path stops
   destroying it. That fix is executable today, so it did not stay in a roadmap: it became
   **P4-07a**, a lettered subtask of P4-07 (whose write path it is) and a prerequisite for P4-11.
3. **The source proposal's data model had a privacy problem, found while writing P4-07a.** It
   specified `var provenance: [MemoryProvenance]`. `MemoryProvenance` holds `userText` (what the
   user said) and `untrustedText` (other speakers, tool results, emails, files, pages) and is meant
   to be read once and discarded; persisting it would write every source turn's raw text into
   `next-memory.json` and retain exactly the quoted content `UsageLog.sanitise` exists to keep out
   of `usage.jsonl`. **P4-07a persists a `MemoryProvenanceRecord` — the descriptor, never the
   content** — and carries a self-test case that reads the written file back and asserts a
   distinctive phrase from `userText` is absent. That rule governs the whole memory roadmap.

### 6.4 What was checked

- Every symbol the new phase file cites was re-verified by grep on 2026-09-25 (00-README §5 step 2):
  `AgentTaskStatus` `AgentTask.swift:3`; `AgentTask.init(from:)` `:115`; `AgentContextReference`
  `:139`; `AgentTaskManager.init` `:19-28`; `running`/`approvedTaskIDs` `:11-17`; `submit` `:35`;
  `announce` `:311`; `announceArtifacts` `:324`; `AgentTaskStore` (29 lines, no `fileName`
  constant — the path is inline at `:9-11`); `ActionIntent` `ActionRuntime.swift:97`;
  `ActionReceipt` `:285`; `ActionReceiptStore` `:329`; `ActionReceiptStatus` `:255`;
  `ActionReceiptEvent` `:269`; `verifyResult` `:638`; `hasForegroundVoiceActivity` `:900`;
  the island guard `:909`; `PermissionBroker.authorize` `:13`; `AgentRisk` `AgentModels.swift:10`;
  `consequentialIDs` `FunctionCallRelevance.swift:177` (**`private static let`**, hence the P1-03
  requirement); `TranscriptBus.publish` `:56` / `subscribe` `:75`;
  `AgentActivityStore.activities` `:36`; `KnowledgeStore.exec` `:559` / `transaction` `:604`;
  `SelfTestStoreGuard.fileNames` `:24` (13 entries); `IslandState.Kind` `:69`;
  `MeetingStore.resumeAction` `:187` / `isolated()` `:76`; `UsageRecord` `UsageRecord.swift:11`;
  `ModelPassRecorder` `ModelPassRecorder.swift:14`; `SelfTest.isRunning` `NextNotesApp.swift:85`.
- The new file's migration order was checked against Phase 3 §3 for the strangler pattern
  (behind → switch → delete) and against §2.9's "what each new type replaces".
- `07-PHASE-6-DURABLE-JOBS.md` names only files that do not exist yet plus files whose current
  line numbers were re-grepped. It is otherwise additive to P3 §2.5 and §2.6, which are unchanged.

### 6.5 Known issues introduced or left open by this integration

1. **P6-08 and P6-09 are out of numeric order on purpose** (observability after revisions, so the
   Timeline is legible). The **Depends on** lines and Phase 6 §3 are authoritative; an executor
   reading `STATUS.md` top to bottom will hit P6-09 first, which is correct.
2. **`TaskDurability` as a JSON blob in one column** is a compromise: it is not queryable, so
   "every task with a stale heartbeat" needs a read-and-filter. A separate column set was rejected
   as premature, but if P6-08's Timeline turns out to need SQL over it, that is the task to change
   it, not a side effect of another one.
3. **`TaskEventKind` does not cover every `TaskEvent` case yet** — P6-03 step 1 says so and requires
   the mismatch to be written up in `STATUS.md` rather than papered over. A `TaskEvent` with no kind
   is an event recovery cannot see.
4. **The stale windows in Phase 6 §2.10 are start values, not measurements.** They are registered in
   00-README §12 as limits to keep, which is deliberate, but nothing has been observed going stale.
   §5 of the phase file says so.
5. **The file-mutation receipt question** (Phase 6 §2.4.1) is answered *by* P6-06, not before it.
   Until P6-06 lands, a scoped file mutation has no receipt and recovery cannot answer "did it
   already happen?" for one. The phase file requires the alternative to carry a comment naming the
   gap.
6. **`agent-tasks.json` stays in `SelfTestStoreGuard.fileNames` for the whole compatibility window.**
   Nothing removes it; a task that removes it before P6-04's importer has run stops isolating the
   owner's file.

---

## 7. Comparison with CopilotKit OpenMuse (2026-09-27)

**Input:** `github.com/copilotkit/openmuse` at `34b15bc` (2026-09-26), MIT, one squashed commit,
about 14,500 lines of TypeScript. Read: `README.md`, `ROADMAP.md`, `docs/VERIFICATION.md`,
`docs/EXPERIENCE.md`, `apps/server/src/engine/worker.ts` (the task lease), `apps/server/src/actions.ts`
(stored reviews), `apps/worker/src/network.ts` and `proxy.ts` (browser egress). Nothing was run.

**What it is.** A self-hosted personal agent: an Expo/React Native client for iOS, Android and web; a
Hono server running the CopilotKit runtime; a durable task worker on PGlite or PostgreSQL; a Playwright
Chromium worker with persistent profiles and a "Take control" console; an optional Docker Linux
container with no network; reviewed Gmail and Calendar writes; PDF form filling; a CSV spending
summary; goals and web-page watches; and "Ideas" with source evidence. It needs a cloud model key, a
running server, the user's own Google OAuth client, and a CopilotKit Intelligence project key in every
mode — a separate hosted service outside its MIT licence. Voice input and replies are on its roadmap,
not in it. Its `VERIFICATION.md` is as honest as our "What has never run": no live Google account and
no live-model acceptance.

**Method.** Each OpenMuse capability was mapped to the task here that already owns it, and only a
difference that survived a grep of our code became a task. Anchors were re-grepped on 2026-09-27:
`AgentService.decide` `Agent/AgentService.swift:423`, `approve` `:309`; `AgentProposal`
`Agent/AgentModels.swift:115`; `GoogleWorkspaceCLI.authState` `:233` and `AuthStatus` `:262-289`;
`WorkspaceTools` `create_event` `:201`, `append_doc` `:171`, `draft_email` `:239`;
`ActionReceiptStatus` `Agent/ActionRuntime.swift:255`, `ActionReceiptStore` `:329`, `verifyResult`
`:638`; `PreparedAction` `:226-253`; `AgentView.composer` `UI/Agent/AgentView.swift:549-575`,
`send()` `:578-587`, `draft` `:17`; the four `agent.approve(proposal)` call sites in
`UI/Meetings/MeetingActionsView.swift` (`:126`, `:158`) and
`UI/Meetings/MeetingConsoleActionsSection.swift` (`:239`, `:258`); `BrowserToolCatalogue.navigate`
`Agent/Tools/ShellTools.swift:43` (risk `.modify`).

### 7.1 What this roadmap optimises for, stated against a real neighbour

OpenMuse is "a personal agent with a computer". Next Notes is **a personal agent that listens, on
your Mac**. Where the two differ, these are the choices this roadmap keeps, in priority order —
AGENTS.md "What we optimize for" applied to a concrete comparison:

1. **Full-duplex voice is the product, not a feature.** Microphone, model and speaker overlap
   (Phases 2–3). OpenMuse has no voice at all. No task borrowed from it may serialise a turn — that
   is why its follow-up queue was rejected (§7.3) and P3-11 revises instead.
2. **On-device and zero-setup by default.** No account, key, server or terminal on the default path.
   OpenMuse's first step is `pnpm install` and a `.env` file. Nothing here adopts a dependency that
   needs a hosted key to function.
3. **Safety at the irreversible boundary, nowhere else.** OpenMuse's best idea is the same one: a
   read runs by itself, a write waits for one stored review. Its binding of that review to account,
   target and time is stronger than ours, so it was taken (P1-19). Its 30-minute expiry was not,
   because our proposals are meant to be read the next morning.
4. **Background work that survives the process** (Phase 6). OpenMuse ships this and we do not yet.
   It is the one area where it is ahead in kind rather than in detail, so Phase 6 now carries its
   design as prior art (Phase 6 §1.5) and two of its safeguards (P6-06 steps 5–6).
5. **Honest evidence over breadth.** Both projects publish what has never run. Keep it that way:
   a capability without a self-test that can fail is not counted.

What we deliberately **do not** chase: a phone client, a sandboxed Linux computer, PDF form filling,
CSV finance, and page-watch goals. Each is a real feature over there and none has been asked for
here; building one ahead of a need is the expensive complexity AGENTS.md warns about.

### 7.2 What was taken

| Id | OpenMuse does | Our gap (measured) | Destination |
|---|---|---|---|
| O1 | A stored review is bound to the account, a hash of the action and target version, and a 30-minute expiry; an account change voids pending work | A proposal pressed from a leftover banner fires with no account, age or time check (`decide` → `approve`); `gws auth status` reports no account at all | **P1-19** (new). Account tag + time-has-passed refusal + an aged banner opens the card instead of firing. No expiry, no deletion |
| O2 | Send becomes Stop in the same place; stopping keeps the draft; typed follow-ups are visible | Stop is a second button; a typed follow-up **silently cancels** the running turn (`send()` → `interrupt()`); the draft is view state | **P1-20** (new, UI and a visible interim) and **P3-11** (new, the typed turn revises through `TaskBridge`) |
| O3 | Every checkpoint is a compare-and-set on the lease; a lost executor cannot write | Phase 6 has `attempt` but no rule that a superseded attempt's late write is refused | **P6-06 step 5** + §2.6 paragraph + a test case; `staleAttemptDropped` added to `TaskEventKind` |
| O4 | "No hidden retry after an uncertain external write" | §2.6 covers "no terminal status → a person decides" but does not separate *fired, outcome unknown* from *never fired*, nor try a read first | **P6-06 step 6** + §2.6 paragraph + a test case; `outcomeResolved` added to `TaskEventKind` |
| O5 | Ideas exclude sent replies and completed matching work (shipped with a regression test) | P4-05's owed items move to `.done` only by hand, so P4-06 would nudge about finished work | **P4-05 target 9** + Case N. "Looks done" is shown, never set: the app does not claim the match |
| O6 | Lease design, two-worker race and restart tests | — | **Phase 6 §1.5**, a prior-art note for P6-04/P6-05; no new task |

### 7.3 What was rejected, and why

| Rejected | Because |
|---|---|
| A first-in-first-out queue for typed follow-ups | It holds a person's message behind a run that can take a minute — the serialised path AGENTS.md forbids. P3-11 revises the running work instead; the effect gate (P3 §2.5.1) already makes overlap safe |
| A 30-minute approval expiry | AGENTS.md "A proposal outlives the process": notes land after the meeting and are read the next morning. P1-19 decides freshness at the moment of approval and deletes nothing |
| A periodic lease-renewal timer per task | Phase 6 §2.5 beats on events; a timer per task is the cost it exists to avoid |
| A browser egress proxy that refuses private addresses | Their browser is a shared sandbox reachable by untrusted pages. Ours is the person's own browser, and `browser.navigate` is `.modify`, so it runs only on the person's own authority (`ActionRuntime.swift:442` refuses a mutation whose authority is not the user). Revisit if the Agent ever gets its own headless browser. See §7.5 item 5 for what this does **not** cover |
| A separate server, a phone client, a Linux container, PDF forms, CSV finance, page watches | No need has been shown here; see §7.1 |
| A hosted conversation-persistence service | The conversation is local, and a hosted key on the default path breaks rule 2 of §7.1 |

### 7.4 Checks run

- Every anchor in §7's method paragraph was grepped against the working tree on 2026-09-27 (the
  tree was dirty in `Agent/Voice/VoiceLatencyTimeline.swift`, which no new task touches).
- No existing id was renumbered and no existing task's text was rewritten; the amendments are
  additive and marked "(OpenMuse 2026-09-27)".
- `STATUS.md` rows, 00-README §2/§3/§4, and the Phase 1 and Phase 3 order lines were updated
  together. P3-11 is migration step 9c, recorded with its reason under P3 §3.

### 7.5 Known issues introduced or left open

1. **P1-19's account tag depends on a command that was not run.** The Gmail profile read is the
   expected source; P1-19 requires it to be checked against `gws --help` and recorded before use. If
   it cannot be read, the account half degrades to today's behaviour and the task says so.
2. **Target versioning is deferred, not dropped.** No catalogue tool updates or deletes an existing
   event by id today. The first one that does needs OpenMuse's `targetVersion` idea as its own task.
3. **P1-20's interim notice is temporary on purpose.** It makes today's interrupt visible until P3-11
   removes it; P3-11 deletes the notice row.
4. **The `bannerAgeLimit` of 3 days is a start value**, like Phase 6's stale windows, and P1-19
   registers it in 00-README §12 as one.
5. **Injected URLs under a user's own turn were not examined.** Authority is decided per turn, so a
   `browser.navigate` planned from a URL inside an email the user asked the Agent to read carries
   the user's authority. Whether the permission card then asks, and whether it shows the full
   host, depends on `PermissionPolicy` for `.modify` and was not checked in this comparison. It is
   the one security question OpenMuse's egress proxy raised that this log leaves open; it belongs to
   whoever next touches `PermissionPolicy`, not to a new task filed here.

---

## 8. The six-area gap plan (2026-09-27, second pass)

**Question from the owner:** how we close the gap with OpenMuse in six areas: the durable worker,
task-state mechanics, not repeating a write and handling "did it go through?", keeping artifacts
and evidence apart, showing the work, and taking over from the agent. **Method:** OpenMuse's
`packages/domain/src/agent.ts` (task, evidence, artifact and event types),
`packages/integrations/src/google.ts` (`OutcomeUnknownError`, `:19-26`, `:576-605`),
`apps/server/src/engine/service.ts` (plan steps, `:199-205`) and `apps/server/src/browser-console.ts`
(takeover) were read against our code. Every anchor below was grepped on 2026-09-27.

### 8.1 Findings that were not in any plan

1. **A Google write that times out is recorded as failed.** `ActionOrchestrator.execute` records
   `.fired` (`Agent/ActionRuntime.swift:520`), and any error from `fire` becomes `.failed`
   (`:550-561`). `gws` is killed at 60 s (`GoogleWorkspaceCLI.swift:162`, `:431`). So a slow send
   reads as a failure, and pressing it again sends a second copy. This is live today, not a
   recovery case. → **P1-21**.
2. **The receipt store empties itself on one bad record.** `ActionReceiptStore.load()` is
   `(try? decode([ActionReceipt])) ?? []` (`:371-375`), and the next `record` saves the empty
   list over the file. Any new status value, any hand-edit and any downgrade can erase the whole
   audit trail. It was found while writing P1-21, and it is fixed there first, because P1-21 adds
   a status value.
3. **Nothing notices the person using the Mac while the agent drives it.** Computer control posts
   real events (`Computer/AccessibilitySnapshot.swift:139-140`, `:286`, `:303`). The only reader of
   the input clock is the scheduler's idle check (`Agent/Schedules/AgentScheduler.swift:1271`).
   `Computer/` has no password-field refusal either; the nearest rule is
   `Context/ContextPrivacyFilter.swift`, which serves the dictation harvest. → **P1-23**.
4. **Durable work lands last.** P6-04 waits behind about 32 open tasks, while `make install`
   fails every running Agent task several times a day. → the **6A/6B proposal**
   (`07-PHASE-6-DURABLE-JOBS.md` §0).

### 8.2 The plan, by area

| Area | OpenMuse | Here, after this pass |
|---|---|---|
| Durable worker | Leased jobs in PGlite/Postgres, recovered after a restart | Phase 6 as written; **§0 proposes 6A** (the typed-task ledger durable after the Phase 1 gate) and **6B** (voice after Phase 3). Awaiting the owner |
| Task states | queued, running, waiting for approval or input, scheduled, paused, succeeded, failed, cancelled | P3 §2.5's `TaskState` with its allowed-transitions table, plus `.recovering` (P6). **Pause is deliberately not added** (P6-08 "Do not"); scheduled work stays in `AgentScheduler` |
| Not repeating a write | Its own idempotency key on stored reviews; `outcome_unknown` on network errors, 5xx, 408 or an unreadable reply | **P1-21** (not sure, never failed; ask Google before the person). **P1-22** (a client-chosen calendar event id makes a repeat a no-op; a derived `Message-ID` makes a send findable — after measuring both). P6-06 steps 5–6 cover the same questions after a restart |
| Artifacts and evidence | Typed `Evidence`, `AgentArtifact` and receipts kept apart | **Phase 6 §2.2.1 and P6-02 step 7**: artifact rows get a kind and a title. Evidence is a reference with a title, date and source, never a copy of the content. A "Based on" line goes on the card and the result, and a test pins that evidence never becomes authority |
| Showing the work | A plan of steps, a run-event timeline, an avatar status | **P6-08 steps 5–7**: a "Needs you" group first; Retry only for work that is safe to repeat, and "Prepare again" for consequential work. The timeline shows what ran. OpenMuse's fixed four-step plan is **not** copied |
| Taking over | A sandboxed browser, opened after the agent's run ends | **P1-23**: the person's first touch pauses the agent before its next event (target < 100 ms), "Carry on" takes a fresh look before resuming, and sign-in or payment pages are never attempted. This deliberately reverses OpenMuse's order: the person never waits |

### 8.3 Checks run

- All anchors in §8.1 were re-read, not only grepped: `load()`'s whole-file `try?`,
  `LocalAgentBackend.swift:28` calling `AgentToolExecutor.run` without `isStillValid` (which
  corrected a first draft of §0.3), and the absence of any secure-field check in `Computer/` (which
  corrected a first draft of P1-23).
- No existing id was renumbered. The split is written as a proposal with its edit list (§0.6), not
  applied.

### 8.4 Known issues left open

1. **P1-22 may end as won't-do for Gmail.** Whether Gmail keeps a client-set `Message-ID` on send is
   unmeasured. Its step 1 decides, and P1-21's approximate match stays if Gmail rewrites the header.
2. **P1-23's event tag is unmeasured.** Whether `eventSourceUserData` survives
   `post(tap: .cghidEventTap)` into a listen-only tap is step one; the fallback is a time window,
   which is weaker and says so.
3. **The 6A/6B split was approved on 2026-09-27**, with 6A starting after the Phase 1 gate. The §0.6
   edits were applied the same day: P6-04 → P6-04a, a new P6-04b, P6-01's dependency moved to the
   Phase 1 gate, the phase-order exception written into 00-README §4, and a 6A note on P3-03a.

---

## 9. Integration of the live log audit (J, 2026-09-27)

**Input:** `roadmap/done/agent-analysis-2026-09-23/J-live-log-audit-2026-09-27.md`, a read-only audit of the
owner's real Agent logs from 13 to 27 Sep. It covered 225 requests, 76 receipts, 513 metrics rows and
200 memory-review runs, and found 25 findings (L1–L25). Three follow-up traces found root causes the
audit had only guessed at. All ran read-only against the code and the owner's files.

### 9.1 What the traces changed

| Audit guess | Traced cause | Task |
|---|---|---|
| "The indexer never adds ended sessions" (L20) | Sessions **were** indexed. **Clear conversation** has no confirmation and deletes *every* indexed conversation (`AgentSession.clear()` → `removeConversations()` → `deleteSources(kind: .conversation)`), and `--selftest-index` pins that as correct. About 21 sessions of deleted chunks remain in the WAL's free pages | P1-26 |
| "Knowledge search finds nothing" (L21) | Most likely the Knowledge screen recording an empty query as a 0-hit search; this is inferred | P1-26 (note), P1-29 item 5 |
| "The model reloaded 4 times in 16 minutes" | Four **processes** (installs and diagnostic launches), not reloads in one app. The prompt-cache misses come from context growth wiping the cache — the warm-up sizes it for a 1-token answer — and from a per-request middle of the planner prompt | P1-28 |
| "Invented emails after P1-11" (L1) | P1-11's guard is a list of verb phrases; "I pulled…" and claim-less invented lists are outside any claim grammar. A class-based check had already been built and **removed as a net loss** (`RealtimeAgent+ToolLoop.swift:1920-1946`); P1-24 is designed against its three measured failures | P1-24 |
| "Offers ignore yes" after P1-07 (L5) | "Want to see …?" is not in `PendingAction.offerPhrases` | P1-24 |
| Logging gaps | `usage.jsonl` already has `turnID`; the audit log and `metrics.jsonl` do not. The audit file on disk is **never trimmed** — the 400 cap is in memory only | P1-29 |
| Memory-review privacy (L17) | `requests[]`, `refused[]` and `skipped[]` keep full text, including other people's words, and a cleared session is still reviewed | P1-30 |

### 9.2 What was filed

- **P1-24…P1-30.**
- **P4-01 moved into Phase 1.** This is the owner's decision and the second named exception to the
  phase order. It lands before P2-01's baseline.
- **P1-10b amendment:** a `.cutShort` outcome (L8), and scrubbing of the Portrait drafts,
  memory-review notices and routine outputs (L9).
- **The Phase 1 gate gains item 2b:** owner-log cases O01–O09 must pass in both gate runs, 0
  `FABRICATED`, 0 `LEAK` (P1-27).

### 9.3 What J found that this roadmap already covered

- **Fixed and gated:** L7, L10, L12, L14, L19.
- **Planned, still later:** L11 and L18 (P3-10, P3-05), L15 and L16 (P1-11, P4-03), L22 (P1-16,
  P1-19), L23 (P6-10).
- **Known red:** L24 (`--selftest-wake-live`; P1-29 adds near-miss rows).

### 9.4 Known issues left open

1. **P1-26 changes what a button means.** "Clear conversation" becomes "New conversation". The task
   records the alternative if the owner prefers deleting — a mandatory confirmation instead.
2. **The chunks already deleted cannot be recovered** except from a backup.
3. **P1-24 has to beat a measured failure.** Its self-test re-runs K01, A04 and M04; if any of them
   regresses, the task is not done, whatever G1 says.
4. **P1-28's larger context costs memory.** On a 16 GB Mac, the size it records decides whether the
   Agent's context stays at 8,192.
5. **L11 (answering side talk) remains the largest unaddressed experience in the log** — about 52
   utterances — and its fix, P3-10, still waits for Phase 3. No cheap interim was found that obeys
   AGENTS.md's rule that a gate which removes a model answer must match exact signatures.

---

## 10. Agent experience and roadmap design review (2026-09-29)

**Scope:** static review of the current working tree's Agent conversation and Activity views,
`AgentSession`, P1-20/P1-26/P1-28, P3-11, the approved 6A/6B split, and P6-08. The working tree
contains uncommitted UI changes, so these observations describe that tree, not a released build.
No live model run, screenshot evaluation, or interaction test was performed for this review.

| Priority | Finding and evidence | Roadmap change proposed |
|---|---|---|
| **P1** | **6A recovers work before its recovery actions have a durable home in the UI.** §0.3 promises a task is back after quit, but §0.4 defers P6-08's "Needs you", Retry and Cancel view to 6B. Today's conversation renders only its active tasks and eight recent ones (`AgentView.swift`), while Activity's current rail is a count and approvals history. A recovered task that needs input or a safe retry may exist in the store without an obvious action path. | Add a small 6A exit requirement to P6-04a/P6-07: surface recovered and waiting typed tasks in the existing Agent working card or Activity view, with the applicable input, approval, retry or cancel action. Keep P6-08's full journal Timeline and combined "Needs you" projection in 6B. Test the path after a real reopen, including a task beyond the eight recent rows. No second task store or projection service. |
| **P1** | **The visible conversation silently drops history.** `AgentView.timeline` takes `session.messages.suffix(40)` even though `AgentSession` retains up to 120 messages. P1-26 correctly preserves prior conversations in the index, but no Agent UI task lets a person read messages 1–80 of the current retained set or find earlier indexed passages from this pane. | Add a conversation-history subtask near P1-26: show older retained turns on demand and link to the existing Knowledge search for prior indexed passages. Preserve current session boundaries and the 120-row storage cap; do not promise a full transcript after that cap or copy the index into another conversation store. The UI gate should verify that the first turn remains reachable after 41 turns and that a new conversation leaves earlier passages discoverable. |
| **P2** | **New events pull a reader away from older content.** `AgentView` scrolls to `conversation-bottom` whenever the last message or newest audit entry changes, regardless of the reader's scroll position. A long tool run can repeatedly jump the page while the person reads. | Add to the conversation UI subtask: follow the bottom only while it was already in view or when the person sends a turn. Otherwise preserve scroll position and offer a visible jump to the latest item. Cover message and audit updates, not only streamed text. |
| **P2** | **Agent answers are rendered as raw text.** `AgentView.messageRow` uses `Text(message.text)`, so markdown headings, lists and links from a model appear as syntax. `MarkdownView` already renders headings, lists and inline emphasis for meeting notes, but its current block parser has no fenced-code or table cases. P1-20 improves the composer, not the answer body. | Specify a shared answer renderer in the Agent UI subtask, reusing the existing markdown view where it fits and adding only formats the Agent actually emits. Keep selection, accessible text and a one-click Copy answer action. Use ordinary text for the person's own messages. Include a rendered long answer in the visual/interaction gate. |
| **P1** | **P1-28's status overclaims its exit.** Its `Done when` requires R1 and context sizing, but `STATUS.md` marks it `done (R1/R3 unmeasured)` and explicitly says the context was not resized. R2's 90% stable prefix is a real improvement; it does not establish the claimed cache survival across growing conversations. | Mark P1-28 partial or add a named follow-up for R1, context sizing and the before/after turn-time measurement. Keep the Phase 1 gate unmet until its existing model and owner-case thresholds pass. Record R3 as a measurement, as the task already says. |
| **P1** | **The latency baseline is blocked by a quality gate it does not technically require.** `STATUS.md` lists P2-01 as depending on the Phase 1 gate, and `00-README.md` enforces strict phase order, while P2-01's own authoritative `Depends on` names only P0-20a and the Phase 2 dependency table lists no Phase 1 dependency. With the Phase 1 live score still below its threshold, the app's measured voice latency and main-actor stall cannot be refreshed. | Make P2-01 instrumentation and baseline an explicit early measurement exception, as its §0.5 already contemplates, while leaving P2-02…P2-08 and the Phase 2 exit behind the chosen phase gate. Update `STATUS.md` and the README's exception list together. This gathers the numbers before optimizing without changing voice behavior. |

**Suggested order:** correct P1-28's ledger now and permit P2-01's baseline; add the conversation-history, scroll and answer-rendering contract before the next Agent UI pass; require the minimal recovery action path at 6A exit. These changes extend existing views and tasks. They do not change the one-ledger, one-audio-channel, one-tool-manifest or one-usage-log rules.

---

## 11. Agent implementation code review (2026-09-29)

**Scope and evidence:** reviewed the current working tree's `RealtimeAgent`, `AgentSession`,
`AgentTaskManager`/store, permission gate, audit/activity store, Agent conversation, working card,
Activity pane, inspector, and screenshot handoff. `make build` completed; the built binary printed
`AGENT_PANES_OK`, `TASKS_OK`, `ACTIVITY_OK`, and `UI_STRINGS_OK`. Those tests exercise pane structure,
a simple task and public activity titles; they do not render the completed card, rotate the audit
file, interleave two tasks, or test a conversation boundary during a turn. No live model or GUI
interaction test was run. The findings below are code-path findings, not claims about a released
binary or an observed user session.

### 11.1 Confirmed defects

| Priority | Finding | User consequence and repair |
|---|---|---|
| **P0** | **A full spoken or typed request is written to the system log as public text.** `RealtimeAgent.handle` logs `text` with `privacy: .public` (`RealtimeAgent.swift:316`). | Calendar, mail, meeting, and dictated request content can be read from unified logging. Log a turn id, source and length instead; keep request text only in the stores that intentionally hold a conversation, under their retention rules. Add a source or log-capture regression check. This is separate from `usage.jsonl` sanitisation. |
| **P1** | **“New conversation” does not fence an in-flight answer.** The button calls `AgentSession.startNewConversation()` while a turn may still run (`AgentView.swift:195-198`). That rotates `sessionID` and clears messages (`RealtimeAgent.swift:1360-1370`); `RealtimeAgent.finish` later calls `recordAssistant` (`:769-783`), whose `append` stamps the *current* session id (`:1413-1417`). | An answer to the old request can appear as the first answer of a fresh chat. Capture the originating session id with each turn and enforce it at delivery, including late tool results. A new conversation should not silently cancel unrelated background work. Test a delayed answer across the button press. |
| **P1** | **The approvals ledger counts requests and cancellations as approvals.** `ActivityView.approvedHistory` selects every `.permission` row except `detail == "Dismissed"` (`ActivityView.swift:117-120`), while `PermissionGate.present` writes “Approval asked” and cancellation writes “Approval cancelled” with different detail (`PermissionGate.swift:55-59`, `:189-193`). The view labels that set “Recently approved” and “Everything you’ve allowed” (`ActivityView.swift:137-154`). | A person checking what the Agent may do sees unanswered or cancelled requests under granted authority. Record an explicit decision/outcome or filter by a typed approval event, then count only granted decisions. Keep asked, denied and cancelled rows in the general history. Test ask → cancel and ask → approve sequences. |
| **P1** | **The completed working card is unreachable.** `AgentView` creates `AgentWorkingCard` only for queued/running/waiting-permission tasks and uses `taskRow` for recent finished tasks (`AgentView.swift:252-270`). `AgentWorkingCard.terminalCard` contains artifact links, a failure card and a follow-up action (`AgentWorkingCard.swift:229-282`), but its only call site removes it as soon as the task becomes terminal. | Finished work falls back to an unlinked text row; the designed result and recovery controls never appear. Keep the terminal card for at least the recent task, or move those controls into the existing task row. **Before making it reachable**, replace its hard-coded `retryRisk: .modify` (`AgentWorkingCard.swift:233-246`) with the task/tool's actual risk; a consequential write must never be offered as a generic retry. |
| **P1** | **Task errors bypass the user-facing reply renderer.** `AgentTaskManager.execute` passes `error.localizedDescription` straight to `announce` (`AgentTaskManager.swift:262-273`), which puts it into the conversation, island and spoken queue (`:309-319`). `AgentError` itself can include raw tool and argument names (`AgentModels.swift:323-326`). | A background failure can speak or display machine text and persist it as an assistant answer. Classify the error and pass it through `AgentReplyRenderer` once at this boundary; retain raw detail only in diagnostics. Test unknown tool, missing argument and backend error cases. |
| **P1** | **A working card can show another task's screenshot.** It peeks fixed global keys such as `computer.screenshot` (`AgentWorkingCard.swift:163-177`). `ScreenshotStore` is last-write-wins by that key with no task id or expiry (`Computer/ScreenCapture.swift:143-166`). | If task A parks a screenshot without a vision consumer, task B's card can display A's window under “the window I am working in.” Bind a capture to the producing task or capture event and clear it at task completion. Test two interleaved tasks and an unconsumed capture. |
| **P2** | **Concurrent task progress loses its owner.** `AgentActivityStore.begin` replaces one `activeTaskID`; every update changes one `liveAvatarState`; `finish` clears the avatar even if a different task remains active (`AgentActivityStore.swift:54-84`). | With two running jobs, the inspector/island may show no live work or the wrong character state when one finishes. Derive the foreground projection from existing per-task steps and current task states; do not add a second ledger. Test A begins, B begins, B finishes, A continues. |
| **P2** | **Audit rotation makes recent history invisible.** `AgentAuditLog` rotates into `agent-audit.1.jsonl`, but `load()` reads only the active `agent-audit.jsonl` (`AgentActivityStore.swift:203-220`, `:257-265`). Activity and `--usage-report` call that same reader. | At rotation, older rows that are still retained on disk vanish from the UI and report. Read both files in time order and deduplicate by id; test a real rotation and reopen. |
| **P2** | **Task history can be replaced with an empty list after one decode error.** `AgentTaskStore.load()` decodes the entire array with `try?` and returns `[]` for any bad row (`AgentTaskStore.swift:15-20`); the next `save` writes that empty/incomplete in-memory state (`:22-27`). | A malformed or future-version task can hide every task and a later submit can overwrite the file. This will be replaced by Phase 6's store, but until then preserve the old file on decode failure and report the failure. Test a valid row beside one unknown status. |
| **P2** | **Audit rows from background work can inherit an unrelated turn id.** `AgentAuditLog.record` fills any missing `turnID` with `RealtimeAgent.shared.currentTurnID` (`AgentActivityStore.swift:176-195`). `AgentTaskManager.announce` passes none (`AgentTaskManager.swift:316-329`); a typed turn can update the shared id while the older task finishes. | `--usage-report --usage-turn` can attribute that result to the wrong request. Pass the task's initiating turn id (or nil where no turn exists) explicitly; do not use whichever turn happens to be current as a default for asynchronous work. Test two overlapping turns plus a delayed task completion. |

### 11.2 Conversation UX gaps confirmed in code

- `AgentView.timeline` renders only the last 40 of up to 120 retained messages (`AgentView.swift:69-84`; `RealtimeAgent.swift:935`), with no older-turn control. A new conversation preserves searchable passages but does not make the retained older turns accessible in this pane.
- Every new message and audit entry scrolls to the bottom (`AgentView.swift:290-294`), even while the person reads above. Preserve position unless the reader is following the latest item; show a “Latest” control otherwise.
- Assistant messages use `Text(message.text)` (`AgentView.swift:443`), so structured answers render as raw markdown. Use a shared rich answer view, keep the person's messages plain, and include copy and accessible selection. The existing `MarkdownView` covers basic blocks but not fenced code or tables.
- `AgentView.send` clears the draft before the async turn begins (`AgentView.swift:666-681`); if the turn cannot start, the request cannot be edited or retried from the composer. Keep a recoverable draft until a user row has been accepted, and cover the unavailable-harness path. This is an interaction risk inferred from the code; it was not reproduced in a GUI test.

**Repair order:** stop public-text logging; fence conversation boundaries; correct approval truth;
make task results reachable with risk-correct actions; classify task failures; scope screenshots and
live progress per task; repair audit/task-store reads; then finish history, scroll and rich-answer
interaction. Extend the existing self-tests at those seams. No new ledger, output channel, tool
manifest or usage log is needed.


## 12. Independent roles and shared artifacts — owner revision 2026-09-30

The owner rejected mandatory notes→Agent model delegation after reviewing Modules
activation. The SHARED-BRAIN folder/IDs remain but SB-02 now preserves independent
notes/Agent choices and cloud IDs; cleanup stays in its existing engine setting.
SB-01 owns exact verified artifact reuse, SB-03 request/model ownership, SB-04
workload fallback, SB-05/06 setup/UI, SB-07 per-workload evidence and SB-08 gates.
OpenCode separately implements MiniCPM cleanup + Apple guard/fallback; no duplicate
formatter/default/store. Same weights do not merge prompts, histories or consent.

All phase headers now identify old one-file/Agent-centric prose as baseline/migration
constraints. P3-07 admission must account for requested artifact and latency under
notes/cleanup overlap. P1-31's paired Agent experiments remain separate benchmark arms,
and SB-07 cannot choose a normal path below its full/owner/latency gates. P4-09 consent
is Agent-only; notes transcript permission stays separate. P4-07/P4-11 Depends-on
lines and ledger now include the existing provenance prerequisite/order.

Memory lifecycle stays unscheduled behind P4-07a→P4-07→P4-11 and its fixture corpus.
Its durable undo history extends NextMemory, not disposable KnowledgeStore; an index
repair cannot erase the only undo record. Task completion/measurements unchanged.
See BUILD-ORDER's current coordination section before edits; archived audits below
remain evidence, not current model selection instructions.


## 13. P1-31a bounded implementation and paired evidence — 2026-09-30

[Investigation](../../../Tests/Reports/toolloop-live/2026-09-30-p1-31-investigation.md)
preserves red-first failures, the corrected harness roster, exact frozen binary/model
identity, paired quick runs for four existing local candidates and paired Qwen full
runs. Needle remains self-test-only. First-call validation and recall/save continuation
use the existing manifest/runner/grounding; answer-only replies use the existing claim
guard; attempts use isolated `usage.jsonl`. No new queue, ledger or provider default.

The planner's `.live(reader:)` input construction had bypassed the test override;
this correction changes the measured fixture environment, so preliminary 9/10 vs 7/10
is not comparable to the corrected Qwen quick 5/10 vs 6/10. Full ordinary 17/30
(owner 7/10) vs Needle 16/30 (owner 8/10), total-case p95 49.038 vs 51.012 s,
fail promotion. Gemma/Qwen3.5 Needle quick timeouts are incomplete arms, not scores.
Live save/draft/compound work remains red despite passing execution-policy cases.

The unchanged grader's `i ran` phrase mislabels the honest unfinished stop
“I ran out of time…” as FABRICATED. Fix classification red first and keep an
uncompleted stop failing. Native tools is independently 4/5 grammar-valid on two
direct grammar-planner runs; no cause or green is claimed. The usage test's stale
header-row assertion is corrected to P1-02's actual read/reply protocol, without
adding inference. Regression logs and limitations stay with the report.

This is P1-31a, not parent P1-31, SB-07 or Phase 1 completion. Other full candidate
arms, live negatives, first-token/audible/overlap and repeat gate runs remain.
Cleanup and iMessage stay with the concurrent executors; these Agent runs judge
neither cleanup nor notes. Independent role choices and exact shared-file reuse stand.
