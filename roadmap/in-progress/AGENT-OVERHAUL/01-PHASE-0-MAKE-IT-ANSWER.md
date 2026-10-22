# Phase 0: make it answer

## Current acceptance position — 2026-10-03

The committed Phase0 implementation and dated baseline below remain valid within
their recorded scope. P0-10's immediate EOU-to-tick logic already exists; actual
native endpoint/fallback/late-EOU acceptance remains blocked/open. P0-11 isolation
invariants do not prove absence of owner reads. Current staged152 model-unopenable
integration fails a5.8s fresh NotesModelRuntime trial against the unchanged5s
budget; do not describe today's whole gate as green from older passing runs or
attribute it to S1 cleanup without evidence. See STATUS and
[the remaining checklist](REMAINING-WORK.md).

**Shared deletion follow-up:** P0-02's committed trial/deletion measurements below
are history, not a complete future multi-role deletion policy. SB-02/SB-04 must
retain any artifact used by another enabled role, cleanup, pending job, runtime lease
or required fallback. The Agent-only otherAnsweringModels count is insufficient.

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

**Goal: every typed and spoken turn gets an answer from a real model, and nothing lies about
which model that was.**

All paths below are relative to `Sources/NextNotes/` unless they start with `Scripts/`,
`Resources/`, `Tests/` or `roadmap/`. Every line number was re-verified against the working
tree on 2026-09-23. **Always grep for the named symbol before editing, because lines drift.**
`ToolLoop` means `Agent/RealtimeAgent+ToolLoop.swift`. `Coordinator` means
`Agent/VoiceConversationCoordinator.swift`.

Before starting, read `00-README.md` (workflow, rules and baseline), then
`roadmap/done/agent-analysis-2026-09-23/F-planner-load-failure.md`, which is the live bug. Read B,
C and D for the rest.

---

## Phase overview

### The live bug, in one paragraph

On 2026-09-23 at 17:49, the typed Agent answered "Hi" and "Who are you?". Then it replied
**"The tool planner failed: The model could not be loaded."** to "What can you do?". The
causes:

- The Agent role points at `K2-Horizon-4B-Q4_K_M.gguf`. That file is complete and valid, but its
  `general.architecture` is `k2-horizon`, which the linked llama.cpp **b10621** does not have.
- `ModelRoleStore.provider(for:)` writes the file into `InstalledModelLibrary.activeAgentModelID`
  on every call. The runtime adopts the change in a **fire-and-forget `Task`**.
- The first pass therefore read a stale spec (Gemma 4 E4B, not on disk) and fell through to
  Apple FM, which answered "Hi" by accident.
- The tool planner **resolved the provider a second time** (`ToolLoop:774`). By then the runtime
  had switched to K2. The load failed in about 0.1 s. It reverted to a Gemma that is not on disk
  and threw `.modelLoadFailed`. It also marked the runtime wedged, and logged "went back to
  Gemma 4 E4B", which is false.
- Every keystroke's prewarm repeated the failed load: 4 times in 34 s.
- Nothing checked the architecture before the download, even though `HuggingFaceClient`
  already fetches it. "Use for agent turns" accepted a file that had just failed to open.
- `--selftest-model-roles`, `--selftest-model-fit` and `--selftest-llm-metal` were all green
  through all of this.

### Order of work

1. **P0-01 (user actions)** first. The owner puts the Agent on Apple's model today, deletes K2
   and installs a supported model. The executor cannot click. It prepares the instructions,
   asks, and verifies afterwards.
2. **P0-13 → P0-14 → P0-03 → P0-02.** First the architecture guard, then one provider per turn,
   then answerable roles, then a download verify that decodes a token. These four stop the live
   bug from recurring with any other model.
3. **P0-04**: per-family chat templates, and control tokens preserved.
4. The rest, in any order that respects **Depends on**: P0-05, P0-06, P0-07, P0-08, P0-09,
   P0-10, P0-11, P0-15. P0-12 (AGENTS.md) goes **last**, because it documents what the others
   changed. P0-16 is decided by evidence, and the current evidence says "won't do".
5. **Added 2026-09-23 from report G** (`roadmap/done/agent-analysis-2026-09-23/G-model-comparison.md`,
   real turns on Apple FM, MiniCPM5-2B and OpenRouter ling-3.0). They are part of the same order:
   - **P0-17** (OpenRouter reasoning and `finish_reason`), in the same session as **P0-05**;
   - **P0-20** (provenance record) early, because every later measurement reads it;
   - **P0-19** (URL cache privacy) any time;
   - **P0-18** (llama prefix reuse) after P0-04, P0-06 and P0-14.
   The MiniCPM5 control-token case (G N3) is folded into **P0-04**.
6. **Added 2026-09-24 from the caps audits H1–H3** (`roadmap/done/agent-analysis-2026-09-23/H1…H3`, while
   execution was in progress; see REVIEW-LOG §5):
   - **P0-20 widened** into a unified local usage log, subtasks **P0-20a → P0-20b / P0-20c → P0-20d → P0-20e**;
   - **P0-21** (knowledge index default; Agent knowledge tools on) before P1-01's baseline;
   - **P0-22** (truthful multi-step notices) and **P0-23** ("That wasn't for you" ends the session) any time;
   - **P0-17 next** among the typed-path tasks: P0-05 landed without it (see P0-17's pairing note);
   - amendments to still-open tasks: **P0-02** step 7. P0-05 and P0-09 were rewritten before they were executed
     and are done as rewritten.

### Phase exit gate

All of the following must hold, recorded in `Tests/Reports/AGENT-OVERHAUL-P0-<date>.md`:

1. Every P0 self-test named below ends `_OK`: `--selftest-model-roles`, `--selftest-model-fit`,
   `--selftest-hf-search`, `--selftest-llm-metal` (with the agent-role leg),
   `--selftest-model-unopenable`, `--selftest-chat-template`, `--selftest-toolloop-production`,
   `--selftest-voice-scheduling`, `--selftest-concurrent-voice`, `--selftest-acp-confirm`,
   `--selftest-voice-delivery`, `--selftest-voice-pipeline <haiku wav>`,
   `--selftest-store-isolation`, `--selftest-ui-strings`, `--selftest-openrouter-contract` (P0-17),
   `--selftest-llm-prefix-cache` (P0-18; `_ABSENT` only when S1-mini is missing),
   `--selftest-private-network` (P0-19), `--selftest-metrics`, `--selftest-usage-log` (P0-20a–e,
   `USAGE_LOG_OK: 20 cases`), `--selftest-index` (P0-21) and `--selftest-voice-turns` (P0-23).
2. **`--selftest-agent-answers` (P0-14b) prints `AGENT_ANSWERS_OK`.** This runs the typed turns
   "Hi", "What can you do?" and "What's on my calendar today?" through the same
   `RealtimeAgent.handle(_:source: .text)` entry point the Agent pane uses, with the real model
   the Agent role resolves to. None of the replies may contain an error string, and each reply
   names the model that answered.
3. `make test` passes, and `make acceptance TIER=core` shows no regression against the baseline.

**Manual smoke (the owner does this; the executor asks for it and records the answer):** quit
and relaunch Next Notes. Open the Agent pane. Check that the input field reads "Ask
<agent name>…". Type "Hi", then "What can you do?", then "What's on my calendar today?".
Expected:

- three answers, and none of them says "failed", "could not be loaded", "unavailable" or "took
  too long";
- the calendar answer lists today's events (or says there are none);
- the caption under the conversation names the answering model (P0-03).

Ask the owner to paste the three replies into `STATUS.md`'s P0 gate row.

---

### P0-01 — User actions: put the Agent on a model that answers, install one this llama.cpp can open, run the smoke check

**Finding(s):** T1, F (R1–R5), Q1 (part). **Effort:** 30 min of the owner's time, plus a
~2.5 GB download. **Depends on:** none. **Unblocks:** P0-14b, the Phase 0 exit, P1-01, P4-09.

**Why (what the user experiences today):** Every tool-using typed turn fails with "The tool
planner failed: The model could not be loaded." (`agent-conversation.json`, 21:49:48Z). Plain
answers come from Apple FM only because of a race. The Agent role names
`installed:IFM/K2-Horizon-3.7B-GGUF/K2-Horizon-4B-Q4_K_M.gguf`. That file can never open on
this build, because upstream llama.cpp has no `k2-horizon` (see P0-16). Free disk is **5.9 GiB**
(`df -h /`, 2026-09-23 22:17Z).

**Files you will change:** none in source. You will write
`Tests/Reports/AGENT-OVERHAUL-P0-01-<date>.md`, a short record of the before and after state.
**Read for context (do not change):** `UI/Settings/ModelsSettingsTab.swift`,
`UI/Settings/ModelRoleSection.swift`, `Support/ModelLibrary/ModelLibraryStore.swift`
(`PostDownloadPolicy`), and `roadmap/done/agent-analysis-2026-09-23/F-planner-load-failure.md`.

**Current behaviour** (from `defaults read ai.pivotstudio.nextnotes`, 2026-09-23):

```
"modelRoles.agent" = "installed:IFM/K2-Horizon-3.7B-GGUF/K2-Horizon-4B-Q4_K_M.gguf";
"modelRoles.meetingNotes" = builtin;          // Gemma 4 E4B, not on disk → Apple FM
"modelLibrary.activeAgentModelID" = "built-in/gemma-4-e4b";
"modelLibrary.postDownloadPolicy" = switchDeleteOld;
```

`~/Library/Application Support/Next Notes/Models/` holds `IFM--K2-Horizon-4B-Q4_K_M.gguf`
(3.16 GB), `s1-mini-q4_k_m.gguf` (the qwen3-architecture punctuation model),
`embeddinggemma-300M-qat-Q4_0.gguf`, `needle3*` and `potion*`. It holds no Gemma 4 E4B weights.

**The state changed again on the evening of 2026-09-23** (G §1, `defaults read`, 22:10 local). Re-read
it before step 1. Do not assume either snapshot:

```
"modelRoles.agent" = cloud;                                  // OpenRouter
"openRouterAgentModelID" = "inclusionai/ling-3.0-flash-sante:free";   // a reasoning model (P0-17)
"modelLibrary.activeAgentModelID" = "openbmb/MiniCPM5-2B-GGUF/MiniCPM5-2B-Q4_K_M.gguf";
"modelRoles.computerUse" = "app:codex";                      // Codex, out of quota until Sep 26 15:43
"modelRoles.meetingNotes" = builtin;                         // resolves to .appLLM → MiniCPM5 while it is active
"agentResponsiveness" = deep;
```
MiniCPM5-2B Q4_K_M is installed (1.56 GB, `general.architecture = llama`, and it loads on b10621).
It gave the best local prose in G (grade 2 on "What can you do?"), but at 4.7–6.1 s per turn until
P0-18. Its tool calls cannot parse until P0-04's MiniCPM5 row lands (G N3). Qwen3-4B-Instruct-2507
therefore stays rank 1 for the Agent role, and MiniCPM5 is an acceptable answer-only fallback.

**Target behaviour:** The Agent and meeting-notes roles resolve to a model that generates
tokens. An installed GGUF, whose architecture b10621 supports, is on disk and used for agent
turns. `--selftest-llm-metal` (with P0-02's agent-role leg) and `--selftest-agent-answers`
(P0-14b) both prove it.

**Recommended models.** All three were verified on the Hugging Face API on 2026-09-23. Their
architectures are in b10621's `src/llama-arch.cpp`.

| Rank | Repo (search this in Settings ▸ Models) | File the app will pick | Size | `general.architecture` | Chat family (P0-04) | Tool-call format | Licence | Why |
|---|---|---|---|---|---|---|---|---|
| **1** | `unsloth/Qwen3-4B-Instruct-2507-GGUF` (mirror: `lmstudio-community/Qwen3-4B-Instruct-2507-GGUF`) | `Qwen3-4B-Instruct-2507-Q4_K_M.gguf` | **2.50 GB** | `qwen3` | ChatML, no thinking | Hermes `<tool_call>{"name":…,"arguments":…}</tool_call>`, which the **current** parser accepts | Apache-2.0 | This is the only candidate that works with today's code, before P0-04 and P1-04. The ChatML template matches the hard-coded one, and its tool calls match `AgentToolCallParser`. It has a 262K trained context and is non-thinking (the "2507" instruct), so it wastes no tokens on `<think>`. |
| 2 | `unsloth/Qwen3.5-4B-GGUF` | `Qwen3.5-4B-Q4_K_M.gguf` | 2.74 GB | `qwen35` | ChatML with thinking (`<think>\n\n</think>` pre-closed) | XML `<tool_call><function=name><parameter=k>v</parameter></function></tool_call>`. **Needs P1-04's tolerant parser** | Apache-2.0 | This Mac ran it before (`lastUsedAt`, per D §0). It is stronger at reasoning, but its tool calls are not parseable until P1-04. |
| 3 | `unsloth/Llama-3.2-3B-Instruct-GGUF` (or `bartowski/…`) | `Llama-3.2-3B-Instruct-Q4_K_M.gguf` | 2.02 GB | `llama` | Llama 3 (`<\|start_header_id\|>`, stop `<\|eot_id\|>`). **Needs P0-04** | JSON `{"name":…,"parameters":…}`. **Needs P1-04** (`"parameters"` is emptied today) | Llama 3.2 Community | The smallest. A fallback if disk stays tight. |

Rejected: Gemma 3 4B (`ggml-org/gemma-3-4b-it-GGUF`, 2.49 GB, `gemma3`) has no tool-call
tokens. Gemma 4 E4B (4.98 GB) needs about 9 GB free, counting the downloader's 4 GiB reserve
(`ModelDownloader.minimumFreeBytesAfterDownload`). K2-Horizon cannot be opened (P0-16).

The app's file picker (`HuggingFaceModelDetails.recommendedFile`, which uses
`ModelFitEstimator.quantizationPreferenceRank`) ranks `Q4_K_M` first. The file it picks is
therefore the one in the table. Confirm the file name on the confirmation sheet.

**Steps.** The owner does these. The executor sends them as a message and waits. Do not
perform UI actions yourself. If the owner explicitly authorises it in writing, the executor
may apply steps 1–2 with `defaults write` **while the app is quit**. The commands are given,
but the UI is preferred, because `setChoice` also mirrors the choice into
`Settings.agentModelProvider`.

1. **Put the Agent on a model that answers now.** Go to Settings ▸ Agent, find the model rows,
   and set **Agent** and **Meeting notes** to "Apple's built-in intelligence". Equivalent
   commands:
   `defaults write ai.pivotstudio.nextnotes modelRoles.agent -string apple` and
   `defaults write ai.pivotstudio.nextnotes modelRoles.meetingNotes -string apple`.
   **Do not press "Restore default model"**: it starts a 4.98 GB Gemma download that cannot fit.
1b. **Model per role until the fixes land** (G §5, measured on 2026-09-23). Send this to the owner
   with step 1:

   | Job (Settings ▸ Agent) | Set it to | Until |
   |---|---|---|
   | Voice | Nothing to set. The voice frontend is always Apple's built-in intelligence (frontend first text in 0.8–2.5 s, G §2.2). | — |
   | Agent (typed) | **Apple's built-in intelligence** (a plain answer in about 2 s, no download). Or keep OpenRouter but pick a model **without** the "Reasoning" label, and check it with `Scripts/run-selftest.sh --selftest-openrouter`. Do **not** keep `ling-3.0` or another reasoning model: it is cut off after 112 tokens. | P0-05 **and** P0-17 are `done` |
   | Controlling your Mac | **Built-in or Apple's built-in intelligence**, not Codex. Codex is out of quota until Sep 26 15:43, and every "open …" costs about 9 s and shows the raw Codex error. | P1-12 is `done`, or the quota resets |
   | Meeting notes | Apple's built-in intelligence (step 1). | P0-04 is `done` |

   Tell the owner, in plain words, that Apple's model sometimes says it "ran" a tool that did not
   run (4 of 9 typed turns in G, fixed by P1-11), so its tool claims should not be trusted until then.
   The equivalent command for the computer-use row (only with written authorisation, app quit) is
   `defaults write ai.pivotstudio.nextnotes modelRoles.computerUse -string apple`.
2. **Stop automatic deletion until P0-02 ships.** In Settings ▸ Models, set "When I download a
   new brain" to "Download only". Equivalent command:
   `defaults write ai.pivotstudio.nextnotes modelLibrary.postDownloadPolicy -string downloadOnly`.
3. **Delete K2-Horizon.** In Settings ▸ Models, delete "K2-Horizon-3.7B". This frees 3.16 GB,
   bringing free space to roughly 9 GB. Keep it only if P0-16 is ever approved, which it is not
   today.
4. **Install rank 1.** In Settings ▸ Models, search "Qwen3-4B-Instruct-2507". Pick the unsloth
   repo, check that the sheet names `Qwen3-4B-Instruct-2507-Q4_K_M.gguf` (2.5 GB), and
   download. With K2 deleted, 2.5 GB plus the 4 GiB reserve fits.
5. **Point the Agent at it.** Do this only after the download finishes and the row shows no
   "wouldn't open" notice. Set **Agent** to the new model, either with "Use this one" → "Use for
   agent turns" or in Settings ▸ Agent. Leave **Meeting notes** on Apple's model until P0-04
   has landed.
6. The executor verifies from a terminal:
   - `defaults read ai.pivotstudio.nextnotes | grep -E "modelRoles|modelLibrary"`
   - `ls -la ~/Library/Application\ Support/Next\ Notes/Models/`
   - `df -h /`
   - `Scripts/run-selftest.sh --selftest-llm-metal`. Before P0-02 lands, this proves only
     Metal. After P0-02, its agent-role leg must print `LLM_METAL_AGENT_ROLE: Qwen3-4B-Instruct-2507 generated N token(s)`.
   - `Scripts/run-selftest.sh --selftest-timeout 900 --selftest-agent-answers`, once P0-14b
     exists.
7. Write `Tests/Reports/AGENT-OVERHAUL-P0-01-<date>.md` with the before and after values.
   Commit it: `P0-01: record model state repair on the development Mac`.

**Do not:**
- click or type in the app yourself;
- run `tccutil`;
- delete any model file from Finder or with `rm`. Use the app, so `library.json` stays in step;
- download Gemma 4 E4B on this disk;
- set the Agent role to the new file before its download has verified. Before P0-02, the
  "verify" only opens the file;
- pick a Hugging Face repo whose `gguf.architecture` is not in the b10621 list (P0-13 has the
  list).

**Red-first self-test:** none (this is a user action). The proof is the smoke output in step 6.
Before step 1, record `Scripts/run-selftest.sh --selftest-llm-metal` as the "before" line. It is
expected to be `LLM_METAL_OK` on S1-mini, which is exactly the false-green this phase removes.

**Verify:**
```bash
defaults read ai.pivotstudio.nextnotes | grep -E "modelRoles|modelLibrary"
ls -la ~/Library/Application\ Support/Next\ Notes/Models/ && df -h /
Scripts/run-selftest.sh --selftest-llm-metal
```

**Success threshold:**
- `modelRoles.agent` is `installed:unsloth/Qwen3-4B-Instruct-2507-GGUF/Qwen3-4B-Instruct-2507-Q4_K_M.gguf`,
  or `apple` until step 5 is done.
- No `k2-horizon` file remains in `Models/`.
- After P0-02 lands, `LLM_METAL_AGENT_ROLE` reports at least 1 generated token from the
  installed model.

**Risks & rollback:** If the download fails on disk space, the owner deletes other models in
Models ▸ "Free up space…". If Qwen misbehaves, set the Agent role back to "Apple's built-in
intelligence". Nothing else is lost.

**Done when:**
- [ ] The Agent role and the meeting-notes role are on Apple's model (step 1).
- [ ] "Controlling your Mac" is off Codex, and the typed Agent is not on a reasoning OpenRouter model (step 1b). The owner's choices are recorded in the report.
- [ ] The post-download policy is `downloadOnly` (step 2).
- [ ] K2-Horizon is deleted (step 3).
- [ ] Qwen3-4B-Instruct-2507 Q4_K_M is installed (step 4).
- [ ] The Agent role points at Qwen (step 5).
- [ ] The report is committed, and `STATUS.md` is updated with the before and after lines.

---

### P0-13 — Architecture support guard (before download, on install, before a role is assigned)

**Finding(s):** F R1, T1. **Effort:** 1 day. **Depends on:** none.
**Unblocks:** P0-14, P0-03, P0-02, P0-04, P0-16.

**Why (what the user experiences today):** The owner downloaded 3.16 GB of K2-Horizon.
Nothing warned that this app cannot open it. `HuggingFaceModelDetails.architecture` is
fetched with the doc comment "Used to warn before a download that llama.cpp may refuse", but
**nothing reads it**. `grep -rn "\.architecture" Sources/NextNotes/Support/ModelLibrary/`
finds only the assignment and self-test fixtures. The first failed load happened after the
download finished (`metrics.jsonl` `model.load`, 21:47:24Z). The role was then assigned
anyway.

**Files you will change:**
- new `Formatting/LLM/LlamaArchitectures.swift` (generated). It holds the supported set and
  the build tag.
- new `Scripts/gen-llama-architectures.sh`, the generator and binary cross-check.
- new `Formatting/LLM/GGUFMetadata.swift`, a header reader built on the linked `gguf_*` C API.
- new `Formatting/LLM/LlamaLoadProbe.swift`, a vocab-only open with the llama log captured.
- `Support/ModelLibrary/HuggingFaceClient.swift`: also decode `gguf.chat_template` (for P0-04)
  and add a `supportVerdict`.
- `Support/ModelLibrary/ModelLibraryStore.swift`: a pre-download verdict in
  `prepareDownload`, and a post-download probe before `InstalledModelLibrary.add`.
- `Support/ModelLibrary/InstalledModelLibrary.swift`: `usableModels` excludes files with a
  failed verdict.
- `UI/Settings/ModelsSettingsTab.swift`: the sheet sentence, the row note, and "Use for agent
  turns" gated.
- new `Support/ModelLibrary/ModelSupportSelfTest.swift`, the `--selftest-model-unopenable` body
  (shared with P0-14).
- `NextNotesApp.swift`: register the flag.
- `AGENTS.md`: the flag list.
- `Scripts/acceptance.sh`: INTEGRATION tier.

**Read for context (do not change):**
- `Formatting/LLM/NotesModelRuntime.swift` (`openNative`, `load`);
- `Formatting/LLM/LlamaBackend.swift`, where `llama_log_set` silences llama at line 35;
- the llama headers at
  `~/Library/Caches/NextNotesBuild/scratch/out/Products/Debug/llama.framework/Versions/A/Headers/`
  (`llama.h`, `gguf.h`).

**Current behaviour:**
- `HuggingFaceModelDetails` @ `Support/ModelLibrary/HuggingFaceClient.swift:77-92`:
  ```swift
  /// "qwen3", "llama", "gemma3". Used to warn before a download that llama.cpp may refuse.
  let architecture: String?
  ```
  It is filled at `:264` (`architecture: entry.gguf?.architecture`). There are no readers.
- `ModelLibraryStore.prepareDownload` @ `ModelLibraryStore.swift:390-436` checks gating, fit
  and replacement. It never checks architecture.
- `ModelLibraryStore.run` @ `:467-533` calls `InstalledModelLibrary.shared.add(newModel)` at
  `:506` with no probe (re-verified 2026-09-23; grep `InstalledModelLibrary.shared.add(newModel)`).
  It then calls `applyPostDownloadPolicy`.
- `NotesModelRuntime.openNative` @ `NotesModelRuntime.swift:213-223` calls
  `llama_model_load_from_file` with full parameters. On an unknown architecture it returns
  `nil` in about 0.1 s. The reason is logged by llama, but `LlamaBackend` silences all llama
  logs (`LlamaBackend.swift:35`: `llama_log_set({ _, _, _ in }, nil)`).
- There is **no llama API that lists supported architectures.** `llama.h` exposes
  `llama_model_meta_val_str`, `llama_model_chat_template`, `llama_chat_builtin_templates` and
  the `vocab_only` / `no_alloc` load parameters (`llama.h:336-340`). `gguf.h` exposes
  `gguf_init_from_file`, `gguf_find_key` and `gguf_get_val_str`, and `import llama` reaches
  them (the umbrella module map exports every header; `nm` shows `_gguf_init_from_file`).
- The b10621 architecture table is `src/llama-arch.cpp` at tag `b10621`
  (`https://raw.githubusercontent.com/ggml-org/llama.cpp/b10621/src/llama-arch.cpp`). It has
  148 `{ LLM_ARCH_…, "name" }` rows, including `clip` (a dummy) and `(unknown)`. It contains
  `qwen3`, `qwen35`, `llama`, `gemma3`, `gemma4` and `kimi-k3`, and **no `k2-horizon`**.

**Target behaviour:**
1. **Before download:** if the Hub reports an architecture that is not in
   `LlamaArchitectures.supported`, the confirmation sheet opens instead of downloading, and says
   in plain words: "This model is built in a way Next Notes can’t run yet, so it won’t be able
   to answer. Download it anyway?". The primary button is "Cancel". When the architecture is
   unknown (the Hub returned none), the download proceeds, and the install-time probe decides.
2. **On install** (after the bytes verify, before `InstalledModelLibrary.add`):
   - `GGUFMetadata.read(url)` reads `general.architecture`, `tokenizer.ggml.pre` and
     `tokenizer.chat_template`.
   - `LlamaLoadProbe.probe(url)` opens the file with `vocab_only = true` and classifies the
     outcome as `.opens`, `.unsupportedArchitecture(name)`, `.unsupportedTokenizer(name)` or
     `.failedToOpen(reason)`.
   - The verdict is stored on the manifest row (`InstalledLocalModel.support`, a new
     `decodeIfPresent` field). A model whose verdict is not `.opens` is still listed so it can
     be deleted, is excluded from `usableModels`, and is never adopted or offered to a role.
3. **Existing rows** with no stored verdict are probed once, lazily, off the main actor, the
   first time `usableModels` is needed after launch (and in `refresh()`). The result is
   persisted.
4. **"Use for agent turns"** (`ModelsSettingsTab.swift:339-341`) and "Use this one" are
   disabled for a model whose verdict is not `.opens`. The row explains why: "Next Notes can’t
   run this model. Delete it to free the space." After P0-02, both also require
   `lastTrial == .answered`.
5. **Full weights are never loaded** for a file whose header or probe says unsupported.

**Steps:**
1. **Generator.** Write `Scripts/gen-llama-architectures.sh`. Usage:
   `Scripts/gen-llama-architectures.sh` with no arguments. It:
   - reads the tag from `Package.swift` with `grep -oE 'download/b[0-9]+/' Package.swift | grep -oE 'b[0-9]+'`;
   - fetches `https://raw.githubusercontent.com/ggml-org/llama.cpp/<tag>/src/llama-arch.cpp`
     with `curl -fsSL`;
   - extracts names with
     `grep -oE '\{ LLM_ARCH_[A-Z0-9_]+,\s*"[^"]+"' | sed -E 's/.*"([^"]+)"/\1/'`;
   - drops `clip` and `(unknown)`, sorts, and de-duplicates;
   - **cross-checks against the built binary.** For each name, it runs
     `strings -a "$HOME/Library/Caches/NextNotesBuild/scratch/out/Products/Debug/llama.framework/Versions/A/llama" | grep -Fxq "<name>"`,
     and fails with a list of misses if any name is absent;
   - writes `Formatting/LLM/LlamaArchitectures.swift`:
     ```swift
     // Generated by Scripts/gen-llama-architectures.sh from llama.cpp <tag> src/llama-arch.cpp.
     // Do not edit by hand. Regenerate whenever Package.swift's LlamaFramework tag changes.
     enum LlamaArchitectures {
         static let buildTag = "b10621"
         static let supported: Set<String> = ["afmoe", "apertus", /* … sorted … */ "xverse"]
         static func isSupported(_ architecture: String) -> Bool { supported.contains(architecture.lowercased()) }
     }
     ```
   - also has `--check` mode: it regenerates to a temp file and `diff`s it against the committed
     file, exiting non-zero on drift. The **Verify** section runs `--check`.
2. **`GGUFMetadata`** (`Formatting/LLM/GGUFMetadata.swift`):
   ```swift
   import llama
   struct GGUFMetadata: Sendable, Equatable {
       let architecture: String?
       let preTokenizer: String?          // tokenizer.ggml.pre
       let chatTemplate: String?          // tokenizer.chat_template
       let name: String?                  // general.name
       static func read(_ url: URL) -> GGUFMetadata?   // nil when the file is not a readable GGUF
   }
   ```
   Implement it with `gguf_init_from_file(url.path, gguf_init_params(no_alloc: true, ctx: nil))`.
   Then use `gguf_find_key` and `gguf_get_val_str` for each key, and `gguf_free`. This reads
   only metadata and tensor descriptors, never tensor data. It is synchronous and runs off the
   main actor.
3. **`LlamaLoadProbe`** (`Formatting/LLM/LlamaLoadProbe.swift`):
   ```swift
   enum LlamaProbeVerdict: String, Codable, Sendable, Equatable {
       case opens, unsupportedArchitecture, unsupportedTokenizer, failedToOpen
   }
   struct LlamaProbeResult: Codable, Sendable, Equatable {
       let verdict: LlamaProbeVerdict
       let detail: String?      // e.g. "k2-horizon"
       let llamaBuildTag: String // LlamaArchitectures.buildTag at probe time
       let fileBytes: Int64
   }
   enum LlamaLoadProbe {
       /// Header check first (no llama load at all when the architecture is unknown), then
       /// a vocab-only open with llama's log captured. Never loads weights.
       static func probe(_ url: URL) async -> LlamaProbeResult
       /// Test seam: counts full-weight loads anywhere in the process (see NotesModelRuntime.openNative).
       static func fullWeightLoadCount() -> Int
   }
   ```
   - **Header step:**
     - If `GGUFMetadata.read` returns nil, the verdict is `.failedToOpen("not a model file")`.
     - If `architecture` is present and `!LlamaArchitectures.isSupported(arch)`, the verdict is
       `.unsupportedArchitecture(arch)`. **Return without calling any llama load.**
   - **Vocab-only step:**
     - Run `await LlamaBackend.shared.initialize()`.
     - Then run on the `LlamaBackend` actor, so it is serialised: install a capturing log
       callback, call
       `llama_model_load_from_file(path, params)` with
       `params = llama_model_default_params(); params.vocab_only = true; params.n_gpu_layers = 0`,
       free the model if it is non-nil, and restore the silent callback.
   - **Capturing callback.** A C callback cannot capture Swift context. Use a file-scope
     `Mutex<String>` from the `Synchronization` module (macOS 15+). The callback appends `text`
     to it. Keep at most 16 KB.
   - **Classification from the captured text:**
     - `unknown model architecture: '<x>'` → `.unsupportedArchitecture(x)`
     - `unknown pre-tokenizer type: '<x>'` → `.unsupportedTokenizer(x)`
     - any other nil model → `.failedToOpen(<last error line>)`
     - non-nil → `.opens`
   - **`fullWeightLoadCount`.** Increment a process counter inside
     `NotesModelRuntime.openNative`, immediately before its `llama_model_load_from_file`.
4. **Store the verdict.**
   - Add `var support: LlamaProbeResult?` to `InstalledLocalModel`. Add a hand-written
     `init(from:)` with `decodeIfPresent`, or give the property a default. Old `library.json`
     rows must still decode; test that with a fixture row that lacks the key.
   - Add `var isRunnable: Bool { support?.verdict == .opens }`.
   - A verdict is **stale**, and re-probed, when `llamaBuildTag != LlamaArchitectures.buildTag`
     or `fileBytes != bytes`.
   - Change `InstalledModelLibrary.usableModels` to
     `models.filter { !$0.isAuxiliary && $0.isRunnable }`. **The built-in row counts as
     runnable** without a probe (it is pinned by `NotesModels.spec`).
   - Add `func refreshSupportVerdicts() async`, which probes rows with a missing or stale
     verdict and saves the manifest. Call it from `InstalledModelLibrary.refresh()` through a
     `Task` that is not awaited on the main path, and **also** await it from P0-14's provider
     path before returning an installed model (so a turn never uses an unprobed file).
5. **Install path.** In `ModelLibraryStore.run`, after `ModelDownloader.download` and before
   `InstalledModelLibrary.shared.add(newModel)`:
   - run `let support = await LlamaLoadProbe.probe(destination)` and attach it to `newModel`;
   - if the verdict is not `.opens`, set
     `downloads[model.id] = .failed("Next Notes can’t run this model, so it won’t answer. It’s kept so you can delete it.")`,
     **skip `applyPostDownloadPolicy` entirely**, and never switch or delete anything.
6. **Pre-download verdict.** In `prepareDownload`, after `details` is fetched:
   ```swift
   if let arch = details.architecture, !LlamaArchitectures.isSupported(arch) {
       downloads[model.id] = nil
       pendingConfirmation = PendingDownload(/* existing fields */, unsupportedReason: .architecture(arch))
       return
   }
   ```
   Extend `PendingDownload` with `unsupportedReason`. The sheet shows the sentence from Target 1,
   with "Cancel" as the default button. "Download anyway" is allowed, because a person may be
   collecting files, but the downloaded row will be unrunnable.
7. **UI** (`ModelsSettingsTab.installedModels`):
   - The `statusNote` for `!model.isRunnable` is "Next Notes can’t run this model. Delete it to
     free the space."
   - Pass `canUse: !model.isAuxiliary && model.isRunnable`.
   - In the confirmation dialog, render the "Use for agent turns" button only when
     `model.isRunnable`.
   - Use `DS.Font.caption` / `DS.Color.textSecondary`, as the neighbouring code does. Use no
     literals and none of the words "architecture", "GGUF" or "llama".
8. Register `--selftest-model-unopenable` in `NextNotesApp.runRequestedSelfTest`, next to
   `--selftest-model-roles` (line ~384). It calls `await ModelSupportSelfTest.run()`, which
   returns `[String]` failures. It writes `MODEL_UNOPENABLE_OK: …` or
   `MODEL_UNOPENABLE_FAILED: <n> problem(s)` and emits each failure as a diagnostic, the same
   shape as `MODEL_ROLES`. Add the flag to AGENTS.md's list, and to `Scripts/acceptance.sh`
   `INTEGRATION_ENTRIES` next to `selftest-model-roles|300`.

**Do not:**
- load full weights to decide support;
- hard-code `k2-horizon` anywhere. The generated list decides;
- edit `LlamaArchitectures.swift` by hand;
- use `URL.resourceValues` for sizes (AGENTS.md). Use `ModelDownloader.fileSize(at:)`;
- add a property to `InstalledLocalModel` without `decodeIfPresent`, which would orphan
  `library.json` rows;
- leave the global llama log callback capturing after the probe. Restore the silent one in a
  `defer`;
- show the words "architecture", "GGUF", "llama.cpp", "tokenizer" or "token" in UI copy;
- download anything in the self-test.

**Red-first self-test:** `--selftest-model-unopenable` in
`Support/ModelLibrary/ModelSupportSelfTest.swift`. P0-14 adds more cases to the same file.

- **Fixture writer**, which lives in the test:
  ```swift
  static func writeGGUF(to url: URL, kv: [(String, GGUFValue)]) throws
  // GGUFValue: .string(String) (type 8) | .uint32(UInt32) (type 4)
  // bytes: "GGUF" | u32 3 | u64 0 (tensors) | u64 kv.count | for each: u64 keyLen, key UTF-8,
  //        u32 type, value (string: u64 len + UTF-8; uint32: 4 bytes LE)
  ```
  Write to `FileManager.default.temporaryDirectory/NextNotesSelfTest-gguf-<pid>/`.
- **Case A (unknown architecture):** the fixture has `general.architecture = "nn-selftest-unknown"`
  and `general.alignment = 32`. Assert that `GGUFMetadata.read` returns architecture
  `nn-selftest-unknown`, and that `LlamaLoadProbe.probe` returns `.unsupportedArchitecture`
  with detail `nn-selftest-unknown`. Assert **`fullWeightLoadCount()` is unchanged** across the
  call.
- **Case B (supported but broken):** the fixture has `general.architecture = "llama"` and no
  hparams. Expect `.failedToOpen` (not `.unsupportedArchitecture`). This proves the log
  classification.
- **Case C (a real supported file):** use `S1MiniModels.spec.fileURL` if
  `S1MiniModels.spec.isDownloaded`. That file is a `qwen3` architecture. Expect `.opens`. When
  S1-mini is absent, record `S1MINI_ABSENT` as a diagnostic and skip only this case.
- **Case D (the library excludes unrunnable rows):**
  - Build an **isolated** `InstalledModelLibrary(manifestURL: temp/library.json, defaults: UserDefaults(suiteName: "NextNotesSelfTest-\(pid)")!)`.
    Add the `defaults: UserDefaults = .standard` init parameter in this task, replacing every
    `UserDefaults.standard` inside `InstalledModelLibrary`. P0-14 builds on it.
  - `add` the Case A fixture as an `InstalledLocalModel` whose `bytes` equal the fixture's size.
  - Assert it is in `models` and **not** in `usableModels`.
- **Case E (pre-download verdict):** make a `HuggingFaceModelDetails` with
  `architecture: "k2-horizon"` and assert the verdict function
  (`ModelLibraryStore.downloadSupportVerdict(for:)`, a pure static) says unsupported. Do the
  same with `"qwen3"` and assert it says supported.
- **Case F (the generated list matches the build):** assert `LlamaArchitectures.supported`
  contains `qwen3`, `qwen35`, `llama`, `gemma3` and `gemma4`, and does not contain `k2-horizon`.
- **Confirm RED first.** Add the seams with today's behaviour:
  - `LlamaLoadProbe.probe` returns `.opens` whenever `GGUFMetadata.read` is non-nil;
  - `usableModels` is unchanged;
  - `downloadSupportVerdict` always says supported.

  Then build, install, run, and expect
  `MODEL_UNOPENABLE_FAILED: 4 problem(s)` or more (cases A, B, D and E).
- The final lines are `MODEL_UNOPENABLE_OK: unsupported files refused before any weight load`
  or `MODEL_UNOPENABLE_FAILED: <n> problem(s)`.

**Verify:**
```bash
Scripts/gen-llama-architectures.sh --check
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-model-unopenable
# regressions
Scripts/run-selftest.sh --selftest-model-roles
Scripts/run-selftest.sh --selftest-model-fit
Scripts/run-selftest.sh --selftest-hf-search      # network; ABSENT-style diagnostics are fine, FAILED is not
Scripts/run-selftest.sh --selftest-ui-strings
```

**Success threshold:**
- Cases A–F all pass.
- Case A performs 0 full-weight loads and finishes in < 50 ms.
- Case C finishes in < 2 s.
- `--check` reports no drift.

**Risks & rollback:**
- A vocab-only probe could still be slow on a huge vocab. Measure Case C; if it takes more than
  2 s, probe only at install and cache.
- A wrong list would refuse good models. The binary cross-check in the generator guards
  against that.
- To roll back: revert the commit. Manifest rows carrying `support` still decode under the old
  code, because Codable ignores unknown keys.

**Done when:**
- [ ] The generator, generated file and `--check` exist.
- [ ] The probe and metadata reader are implemented.
- [ ] Verdicts are persisted, `usableModels` filters on them, and the UI gates "Use".
- [ ] The pre-download sheet warns.
- [ ] `MODEL_UNOPENABLE_OK`.
- [ ] Regressions are unchanged.
- [ ] `STATUS.md` is updated and the work is committed as `P0-13: …`.

---

### P0-14 — One provider per turn, no stale fallback, failed loads remembered

**Finding(s):** F R2–R5, T1. **Effort:** 1–1.5 days. **Depends on:** P0-13 (the probe, the verdicts and the
`InstalledModelLibrary(defaults:)` seam). The lettered subtask **P0-14b** (step 8, `--selftest-agent-answers`,
its own STATUS row and commit) also depends on P0-11 (snapshot helper) and goes green only after P0-01.
**Unblocks:** P0-03, P0-12, P0-18 (one reset point for the prefix cache), P1-01, P1-12 (the
computer-use fallback resolves once), P4-09, and the Phase 0 exit (P0-14b).

**Why (what the user experiences today):** The same turn used two different models. "What can
you do?" was routed by Apple FM (the first pass), then planned on K2 (the second resolution),
which failed with "The tool planner failed: The model could not be loaded."
(`RealtimeAgent+ToolLoop.swift:929`). The log line "K2-Horizon-3.7B wouldn't open on this Mac,
so Next Notes went back to Gemma 4 E4B" was false, because Gemma is not on disk. It repeated 4
times in 34 s as typing prewarms retried the same failed load. The runtime was also marked
**wedged** (`NotesModelRuntime.swift:1136`) instead of retryable.

**Files you will change:**
- `Support/ModelRoles/ModelRoleStore.swift`: `provider(for:)`, `builtInProvider(for:)`,
  `AgentModelRouting`, and the injected `library` / `runtime`.
- `Support/ModelLibrary/InstalledModelLibrary.swift`: an injected `defaults` and
  `runtimeAdopter`, and the removal of the `SelfTest` guard in `adoptInRuntime`.
- new `Support/ModelLibrary/ModelOpenFailureStore.swift`.
- `Formatting/LLM/NotesModelRuntime.swift`: `select(_:)` (awaited), `load` failure semantics,
  the failure sink, and `loadAttemptCount` for tests.
- `Formatting/LLM/LlamaHelpers.swift`: a new `LlamaError.modelUnopenable(String)`.
- `Formatting/LLM/LlamaLLMProvider.swift`: an injected `runtime`.
- `Agent/RealtimeAgent+ToolLoop.swift`: pass one provider from `runModelTurn` into
  `runPlannedToolLoop`, and add a single honest fallback.
- `Support/ModelLibrary/ModelLoadNotice.swift`: truthful sentences.
- `Support/ModelLibrary/ModelSupportSelfTest.swift`: add cases.
- new `Agent/AgentAnswersSelfTest.swift` (P0-14b).
- `NextNotesApp.swift`, `AGENTS.md`, `Scripts/acceptance.sh`.

**Read for context (do not change):**
- `Formatting/LLM/LLMProvider.swift` (`LLMProviders.resolve` @ :263-278, `make` @ :227);
- `Support/ModelLibrary/ModelLibraryStore.swift` (`applyPostDownloadPolicy`);
- `UI/Agent/AgentView.swift:97-98` (prewarm on typing);
- `Agent/RealtimeAgent.swift:207-360` (`handle`).

**Current behaviour** (verified):
- `ModelRoleStore.provider(for:)` @ `ModelRoleStore.swift:534-584`, `.installedModel` branch
  at `:569-579`:
  ```swift
  guard InstalledModelLibrary.shared.model(withID: id) != nil else {
      return await builtInProvider(for: role)
  }
  if InstalledModelLibrary.shared.activeAgentModelID != id {
      InstalledModelLibrary.shared.activeAgentModelID = id      // write on every turn
  }
  return await LLMProviders.resolve(preferring: .appLLM)        // before the runtime adopted it
  ```
- `InstalledModelLibrary.activeAgentModelID` `didSet` @ `:96-104` calls `adoptInRuntime()`,
  and `adoptInRuntime` @ `:124-131` is
  ```swift
  guard !SelfTest.isRunning else { return }
  let chosen = activeModel
  Task { await NotesModelRuntime.shared.useInstalledModel(chosen) }   // not awaited
  ```
- `LlamaLLMProvider.unavailableReason` @ `LlamaLLMProvider.swift:33-42` reads
  `NotesModelRuntime.shared.activeSpec()`, which is the **stale** spec until that `Task` runs.
- `runModelTurn` resolves at `ToolLoop:353`
  (`AgentModelRouting.provider(for: prompt, voice: voice)`). `runPlannedToolLoop` resolves
  **again** at `ToolLoop:774`. Other callers of `runPlannedToolLoop` are
  `Agent/RealtimeAgent.swift:138` (voice worker) and `ToolLoop:458,475`.
- In `NotesModelRuntime.load` @ `:1153-1232`, when `openNative` fails for a non-built-in file:
  ```swift
  await revertToBuiltIn(message: ModelLoadNotice.couldNotOpen(failed, fallback: NotesModels.spec.displayName))
  if spec.isDownloaded { opened = Self.openNative(spec, parameters: modelParameters) }
  guard let (loadedModel, loadedVocabulary) = opened else { throw LlamaError.modelLoadFailed }
  ```
  `revertToBuiltIn` @ `:230-237` moves the **library** selection to built-in. The role then
  re-asserts the file on the next turn. `loadIfNeeded` @ `:1124-1142` marks anything except
  `.modelMissing` as **wedged**.
- `ModelLoadNotice.couldNotOpen` @ `Support/ModelLibrary/ModelLoadNotice.swift` names the
  fallback as the built-in model, whether or not it is on disk. It is shown only in Models
  settings (`ModelsSettingsTab.swift:19`).
- `AgentView.swift:97-98` calls `NotesModelRuntime.shared.prewarm()` on `.task` and on **every
  change of `draft`**. Each call re-resolves the provider (`AgentModelRouting.resolvesToLocalModel`)
  and, with K2 selected, attempts a load.
- The harness hides all of this. `adoptInRuntime` (`:128`) and
  `NotesModelRuntime.adoptSavedSelectionIfNeeded` (`:205`) are both skipped under
  `SelfTest.isRunning`. That is why `--selftest-model-roles` stayed green.

**Target behaviour:**
1. **Provider resolution is read-only and deterministic.** `ModelRoleStore.provider(for:)`
   performs no writes to `activeAgentModelID`, and returns the same answer when called twice in
   a row with nothing changed.
2. **The switch is awaited before the provider is returned.** For `.installedModel(id)`:
   - the model must be in `library.usableModels`, with verdict `.opens` (P0-13), and must not be
     in the `ModelOpenFailureStore`;
   - then `await runtime.select(model)` completes the spec swap, or records it as pending behind
     in-flight work, **before** returning;
   - the returned `LlamaLLMProvider` names that model.
3. **One provider per turn.** `runModelTurn` resolves exactly once. It passes that provider to
   `runPlannedToolLoop(… provider:)`, which never resolves again when it is given one. The voice
   worker path, which resolves inside `runPlannedToolLoop`, still resolves exactly once per
   objective.
4. **A failed full load is remembered and never re-selected.**
   - `ModelOpenFailureStore` records `(fileURL.path, bytes, LlamaArchitectures.buildTag) → reason`.
     The production store persists under `UserDefaults` key `modelLibrary.openFailures`; the
     test store uses an injected suite.
   - `provider(for:)` treats a recorded file like a missing one.
   - The entry clears automatically when the byte size or the build tag changes.
5. **The fallback is truthful.**
   - When the chosen installed file cannot be used, `provider(for:)` falls back through
     `builtInProvider(for:)` → `LLMProviders.resolve(preferring: .appLLM)`, which reaches Apple FM
     when Gemma is absent.
   - It reports **one** `ModelLoadNotice` per `(file, fallback)` pair per launch, naming the
     provider that will actually answer: "K2-Horizon-3.7B can’t run on this Mac, so answers come
     from Apple’s built-in intelligence."
   - The runtime **never** touches the library selection and never opens a fallback file on its
     own.
6. **The load outcome is honest.**
   - A chosen file that fails `openNative` throws `LlamaError.modelUnopenable(displayName)`
     ("<name> can’t run on this Mac.") and records it in the failure store.
   - The runtime returns to the built-in spec **without** opening it.
   - `loadIfNeeded` marks both `.modelMissing` and `.modelUnopenable` as **unloaded**, not wedged.
7. **In-turn fallback.** If a turn's stream fails with `.modelUnopenable` or `.modelMissing`
   anyway (a first-time failure of a file the probe passed), the turn re-resolves **once**. That
   resolution now excludes the recorded file, and the turn continues on the new provider. The
   reply is prefixed by nothing; the pane caption (P0-03) names the model. The planner never
   returns "The tool planner failed: The model could not be loaded."
8. **Typing never triggers repeated failed loads.** After one failure, `prewarm()` resolves to a
   non-local provider (Apple), so it is a no-op: 0 further load attempts.

**Steps:**
1. **Seams, without behaviour change yet.**
   - `InstalledModelLibrary.init(manifestURL: URL? = nil, defaults: UserDefaults = .standard, runtimeAdopter: (@Sendable (InstalledLocalModel?) async -> Void)? = nil)`.
     The `.shared` instance passes
     `runtimeAdopter: SelfTest.isRunning ? nil : { await NotesModelRuntime.shared.useInstalledModel($0) }`.
     `adoptInRuntime` calls the adopter when it is non-nil, replacing the in-method `SelfTest`
     guard. Replace every `UserDefaults.standard` in the class with `defaults`.
   - `ModelRoleStore.init(defaults:catalog:availability:library: InstalledModelLibrary = .shared, runtime: NotesModelRuntime = .shared, failures: ModelOpenFailureStore = .shared, notice: ModelLoadNotice = .shared)`.
     Replace every `InstalledModelLibrary.shared` inside `provider(for:)` and
     `builtInProvider(for:)` with `library`.
   - `LlamaLLMProvider(modelName:runtime: NotesModelRuntime = .shared)`, and use `runtime` in
     every method.
   - `AgentModelRouting.provider(for:voice:roles: ModelRoleStore = .shared)` and
     `resolvesToLocalModel(voice:roles:)`.
   - `NotesModelRuntime`: add `private(set) var loadAttemptCount = 0`, incremented at the top of
     `load(schedulerJobID:)`. Add `var openFailureSink: (@Sendable (ModelSpec, String) async -> Void)?`.
2. **`ModelOpenFailureStore`** (`@MainActor final class`):
   ```swift
   struct Key: Hashable, Codable { let path: String; let bytes: Int64; let buildTag: String }
   init(defaults: UserDefaults = .standard)
   func record(_ model: InstalledLocalModel, reason: String)
   func hasFailed(_ model: InstalledLocalModel) -> Bool   // key match with the current build tag
   func clear(_ model: InstalledLocalModel)
   static let shared = ModelOpenFailureStore(defaults: SelfTest.isRunning
       ? UserDefaults(suiteName: "NextNotesSelfTest-\(ProcessInfo.processInfo.processIdentifier)")!
       : .standard)
   ```
3. **`NotesModelRuntime.select(_ model: InstalledLocalModel?) async`.** Add it as a thin
   awaited wrapper over the existing `useInstalledModel`. It is already actor-isolated and
   synchronous inside the actor, so awaiting it from the caller is what removes the race. The
   post-condition is `(pendingSpec ?? spec).fileURL == target.fileURL`.
4. **Rewrite the `.installedModel` branch of `provider(for:)`:**
   ```swift
   case .installedModel(let id):
       guard let model = library.usableModels.first(where: { $0.id == id }) else {
           return await fallback(for: role, because: library.model(withID: id), reason: .notRunnable)
       }
       await library.refreshSupportVerdictIfNeeded(model)          // P0-13; cached
       guard model.isRunnable, !failures.hasFailed(model) else {
           return await fallback(for: role, because: model, reason: .failedBefore)
       }
       await runtime.select(model)                                  // awaited; no library write
       let provider = LlamaLLMProvider(modelName: model.displayName, runtime: runtime)
       return await provider.unavailableReason == nil ? provider
           : await fallback(for: role, because: model, reason: .missing)
   ```
   `fallback(for:because:reason:)` calls `builtInProvider(for:)`, then reports the notice once
   (see step 7). Make `builtInProvider(for:)` stop writing `activeAgentModelID` too: resolution
   is read-only. The `.builtIn` choice must still load the built-in file. Achieve that by
   `await runtime.select(nil)` (built-in), not by writing the library.
5. **Runtime failure semantics** (`NotesModelRuntime.load`):
   - Replace the `revertToBuiltIn` + reopen block at `:1203-1214` with:
     ```swift
     guard let (loadedModel, loadedVocabulary) = Self.openNative(spec, parameters: modelParameters) else {
         let failed = spec
         if !isUsingBuiltInModel {
             await openFailureSink?(failed, "open failed")
             spec = NotesModels.spec; pendingSpec = nil        // back to built-in, NOT opened
             throw LlamaError.modelUnopenable(failed.displayName)
         }
         throw LlamaError.modelLoadFailed
     }
     ```
   - Do the same for the file-missing branch at `:1160-1169`: throw `.modelMissing` without
     touching the library. Delete `revertToBuiltIn`'s library write. If nothing else calls
     `revertToBuiltIn`, delete the function.
   - In `loadIfNeeded` (`:1124-1142`), treat `.modelMissing` **and** `.modelUnopenable` as
     `markUnloaded`.
   - The production `openFailureSink` is set once at launch (`applicationDidFinishLaunching`,
     after `runRequestedSelfTest` returns false). It hops to the main actor, finds the
     `InstalledLocalModel` whose `fileURL` matches, and calls
     `ModelOpenFailureStore.shared.record`.
6. **One provider per turn** (`ToolLoop`):
   - Add a `provider: (any LLMProvider)? = nil` parameter to the public
     `runPlannedToolLoop(_:speech:voice:)` at `:725`.
   - When non-nil, skip the resolution at `:772-779` and use it.
   - In the private `runModelTurn(…provider:)`, pass `provider: provider` at the two calls
     `:458` and `:475`.
   - Keep `RealtimeAgent.swift:138` (voice worker) resolving once, as today.
7. **In-turn fallback and truthful notice.**
   - In `runPlannedToolLoop` (private, around `:925-930`), and in `runModelTurn`'s `.failed`
     branch (`:444-446`), detect the two errors:
     ```swift
     if case .failure(let error) = …, error.isModelUnavailable  // .modelUnopenable or .modelMissing
     ```
     Then, once per turn: `provider = await AgentModelRouting.provider(for: prompt, voice: voice)`.
     That call now excludes the failed file. If it returns a different `id`, retry the same
     round. If it returns nil, reply
     "I can’t answer right now because no model on this Mac can run. Choose one in Settings ▸ Models."
   - `ModelLoadNotice`:
     - Add `static func cannotRun(_ name: String, answeringWith: String) -> String`, which
       returns "\(name) can’t run on this Mac, so answers come from \(answeringWith)."
     - Keep `fileMissing`, but give it an `answeringWith` argument too.
     - Remove `couldNotOpen(_:fallback:)` once nothing calls it.
     - `ModelRoleStore.fallback` reports at most once per `(model.id, provider.id)` per process.
       Keep a `Set<String>`.
8. **P0-14b: the phase-exit harness `--selftest-agent-answers`** (`Agent/AgentAnswersSelfTest.swift`):
   - Add `SelfTest.allowsSavedModelSelection: Bool`, true only when `--selftest-agent-answers`
     or `--selftest-llm-metal` is present.
     `NotesModelRuntime.adoptSavedSelectionIfNeeded` checks
     `!SelfTest.isRunning || SelfTest.allowsSavedModelSelection`. The same applies to the
     `.shared` library's adopter. This is **read-only** use of the owner's choice.
   - Prompts: `["Hi", "What can you do?", "What's on my calendar today?"]`. For each, call
     `await RealtimeAgent.shared.handle(prompt, source: .text)`, the same entry the Agent pane
     uses (`AgentView.swift:528` calls `handleLive`, which calls `handle`).
   - Before each turn, record which provider answered, from the P0-03 "answering model" state.
     If P0-03 has not landed, use `AgentModelRouting.provider(for:voice:false)` to print the id
     and name.
   - **Fail** a turn when:
     - the reply is empty;
     - the reply contains any of these (case-insensitive): "tool planner failed",
       "could not be loaded", "model could not answer", "selected model is unavailable",
       "took too long", "invalid response header", "invalid tool request",
       "inference could not start", "unavailable tool";
     - or, for the calendar turn, the route is not `model-tools`. Expose the route of the last
       turn as `RealtimeAgent.lastRouteForTesting`, set in `conclude`.
   - Deny every write in the test. If `PermissionGate` has no auto-deny seam, add
     `PermissionGate.shared.autoDenyForTesting = true`. Reads run (the calendar read is
     read-only).
   - Stores: `AgentSession`, `AgentAuditLog`, `AgentTaskManager.persist`, `NextMemory` and
     `MetricsStore` are already isolated under `SelfTest.isRunning` (verified: `RealtimeAgent.swift:818`,
     `Agent/Activity/AgentActivityStore.swift:150,178`, `Agent/Tasks/AgentTaskManager.swift:292`,
     `Memory/NextMemory.swift:254`). Assert that again with P0-11's snapshot helper.
   - Output lines:
     - `AGENT_ANSWER <n>: <provider id> · <model name> · <route> · <first 120 chars of reply>`;
     - `AGENT_ANSWERS_OK: 3/3 answered by <model name>`;
     - `AGENT_ANSWERS_FAILED: <which turn>: <reason>`;
     - `AGENT_ANSWERS_ABSENT: no model on this Mac can answer`, when
       `AgentModelRouting.provider(for: "Hi", voice: false)` is nil.
   - Register it in `NextNotesApp.runRequestedSelfTest`. It needs `--selftest-timeout 900`,
     because a cold 2.5 GB load plus three turns can exceed 300 s. Add it to `Scripts/acceptance.sh`
     EXPERIMENTAL as `"selftest-agent-answers|900"`; it needs a model and the network. Add it to
     the AGENTS.md list.

**Do not:**
- write `activeAgentModelID` from any resolution path;
- use `MainActor.assumeIsolated` to read the library from the runtime. Use `await MainActor.run`;
- special-case `SelfTest.isRunning` inside production decisions. Every test difference goes
  through an injected dependency;
- let the self-test write the owner's `UserDefaults`. Use a `UserDefaults(suiteName:)` suite
  and remove it at the end with `removePersistentDomain(forName:)`;
- open the built-in (or any other) file as a silent replacement inside the runtime;
- claim a fallback model by name unless it is the provider that resolved;
- touch `Settings.notesProvider`. It was deleted on purpose (AGENTS.md).

**Red-first self-test:** extend `--selftest-model-unopenable`
(`Support/ModelLibrary/ModelSupportSelfTest.swift`) with the F-report cases. Everything is
isolated:

- a temp manifest;
- a `UserDefaults(suiteName:)`;
- a fresh `NotesModelRuntime(spec: NotesModels.spec, gpuLayers: 0)`;
- an `InstalledModelLibrary` whose `runtimeAdopter` calls that runtime's `useInstalledModel`.
  This is the **real** switch path the harness used to skip;
- a `ModelRoleStore` built on all of the above;
- the unknown-architecture fixture from P0-13, added to the manifest **directly**, with a
  pre-seeded `support = .opens` verdict. That forces the first-time-failure path, as with a
  file the probe missed.

With the role set to `.installedModel(fixture.id)` through the isolated store's `setChoice`,
assert:

1. `try await runtime.prepare()` throws `LlamaError.modelUnopenable`, **not** `.modelLoadFailed`.
   Check that `ModelRuntimeManager` does not report `.notes` as wedged. If `ModelRuntimeManager`
   is a singleton, read its state for `.notes` right after, then reset it.
2. Two consecutive `await AgentModelRouting.provider(for: "What can you do?", voice: false, roles: store)`
   calls return the **same** `id`, and neither is `.appLLM`. Today the first returns
   `.appleFoundation` and the second `.appLLM`.
3. After step 1, `library.activeAgentModelID` was never written by resolution. Wrap the property
   with a write counter seam, or compare the suite's value before and after.
4. A planner turn:
   - set `RealtimeAgent.shared.localModelProviderForTesting` to a stub whose first pass returns
     `<use_tools/>` and whose planner stream throws `LlamaError.modelUnopenable("fixture")`;
   - set `plannerFallbackResolverForTesting` to return an Apple-like stub that answers "Done.";
   - the reply must **not** contain "The tool planner failed:".
5. With the probe seam from P0-06/P0-13 set to use the real routing (`isLocalRoute: { await AgentModelRouting.resolvesToLocalModel(voice: $0, roles: store) }`),
   call `runtime.prewarm().value` three times after the failure. `runtime.loadAttemptCount`
   increases by **0**.
6. The notice: after the fallback, `notice.message` contains "can’t run on this Mac" and does
   **not** contain "Gemma" when `NotesModels.isDownloaded == false`.

**Confirm RED:** add the seams (steps 1–3 only, with the old logic kept). Build, install and run.
Expect `MODEL_UNOPENABLE_FAILED` naming at least assertions 1, 2, 3 and 5.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-model-unopenable
Scripts/run-selftest.sh --selftest-model-roles
Scripts/run-selftest.sh --selftest-toolloop-production
Scripts/run-selftest.sh --selftest-realtime
Scripts/run-selftest.sh --selftest-voice-scheduling
Scripts/run-selftest.sh --selftest-store-isolation        # after P0-11
# after P0-01 step 5 (a runnable model is the Agent role):
Scripts/run-selftest.sh --selftest-timeout 900 --selftest-agent-answers
```

**Success threshold:**
- All 6 assertions pass.
- 0 load attempts on prewarm after a failure.
- `AGENT_ANSWERS_OK: 3/3` on this Mac once P0-01 is done.
- `--selftest-model-roles` and `--selftest-toolloop-production` are unchanged from the
  baseline.

**Risks & rollback:**
- `select` awaited on the turn path adds an actor hop. It must not load, so measure it: add
  `LatencyTrace` around it, and the threshold is < 5 ms.
- Removing `revertToBuiltIn`'s library write changes what the Models tab shows after a failure.
  P0-03's caption covers that.
- To roll back: revert the commit. The persisted `modelLibrary.openFailures` key is ignored by
  old code.

**Done when:**
- [ ] Resolution is read-only.
- [ ] The switch is awaited.
- [ ] There is one provider per turn.
- [ ] Failures are remembered and cleared on change.
- [ ] Notices are truthful.
- [ ] `.modelUnopenable` is marked unloaded, not wedged.
- [ ] `MODEL_UNOPENABLE_OK` with the P0-14 cases.
- [ ] `--selftest-agent-answers` exists (P0-14b) and is `_OK` after P0-01.
- [ ] Regressions are unchanged.
- [ ] Committed as `P0-14: …` and `P0-14b: …`.

---

### P0-03 — Roles resolve only answerable models; launch-time role repair with one notice; the pane names the answering model

**Finding(s):** T1, F R2, D §6 (D-report item P0-2). **Effort:** 0.5–1 day. **Depends on:** P0-13, P0-14.
**Unblocks:** P1-01, P4-09. **Related:** P0-20 writes the same "which model answered" fact to
`metrics.jsonl` per model pass. The caption here is for the person, and P0-20's record is for
measurement. Both read `provider.displayModelName`, so they cannot disagree.

**Why (what the user experiences today):**
- Earlier on 09-23, the role named a 59.7 MB MTP draft head
  (`installed:ggml-org/gemma-4-E4B-it-GGUF/mtp-gemma-4-E4B-it-Q4_0.gguf`). Every turn answered
  "The model could not answer: Inference could not start." (audit 21:02Z, 21:03Z).
- Today the role names K2, which cannot run, and nothing repairs it.
- The pane never says which model answered. The Models tab claimed K2 was in charge while Apple
  FM answered.

**Files you will change:**
- `Support/ModelRoles/ModelRoleStore.swift`: `repairUnanswerableRoles()`, and
  `answering` state for the UI.
- `NextNotesApp.swift`: call the repair at launch, after `runRequestedSelfTest()` returns false.
- `Agent/RealtimeAgent.swift`: publish the answering provider per turn.
- `UI/Agent/AgentView.swift`: a caption naming the answering model, plus the load notice.
- `Support/ModelRoles/ModelRoleSelfTest.swift`: new cases.

**Read for context (do not change):**
- `Support/ModelLibrary/InstalledModelLibrary.swift` (`usableModels` @ :161, `isAuxiliary` @ :48);
- `Support/ModelLibrary/ModelFitEstimator.swift` (`isAuxiliaryGGUF` @ :321-340);
- `UI/Settings/ModelsSettingsTab.swift:265-289`.

**Current behaviour:**
- `provider(for:)` guards `.installedModel` with `InstalledModelLibrary.shared.model(withID:)`
  @ `ModelRoleStore.swift:573`. That is `models.first { $0.id == id }` (`InstalledModelLibrary.swift:171-173`)
  and **includes auxiliary files**.
- P0-14 moves the guard to `usableModels`.
- Nothing ever rewrites a stored `modelRoles.<role>` token.
- `ModelLoadNotice` is observed only by `ModelsSettingsTab` (`:19`).
- `AgentView` shows no model name.

**Target behaviour:**
1. `provider(for:)` never returns an installed provider for an auxiliary, unrunnable (P0-13) or
   failed (P0-14) file. P0-14 does most of this. This task pins it with the auxiliary case.
2. **Launch repair.** For each role whose stored choice is `.installedModel(id)`, where `id` is
   missing from `models`, auxiliary, unrunnable or recorded as failed:
   - rewrite the choice to `.appleFoundation` if Apple FM is available, else to `.builtIn`,
     through `setChoice` (which persists and mirrors);
   - report **one** notice per repaired `(role, id)`, ever. Persist the shown keys under
     `modelRoles.repairNotices`. The text: "The model chosen for <role display name> can’t run
     on this Mac, so it now uses <new choice display name>. You can pick another in Settings ▸
     Agent."
3. **The pane names the answering model.**
   - `RealtimeAgent` publishes `answeringModel: (providerID: LLMProviderID, name: String)?`,
     set once per turn from the resolved provider (`provider.displayModelName`).
   - `AgentView` shows a caption above the composer: "Answered by <name>". When it differs from
     the Agent role's choice, it shows "Answered by <name> — <chosen> can’t run on this Mac."
     using the P0-14 notice text.
   - Use `DS.Font.caption` and `DS.Color.textSecondary`. Hide the caption until the first turn.
   - Also show `ModelLoadNotice.shared.message` in the pane when it is non-nil, with a
     "Settings" link button that sets `NavigationState.shared.selectedSettingsTab = .agent`.

**Steps:**
1. Add `func isAnswerable(_ id: String) -> Bool` to `ModelRoleStore`:
   `library.usableModels.contains { $0.id == id && $0.isRunnable } && !failures.hasFailed(model)`.
   Use it in `provider(for:)` (P0-14 already did the equivalent) and in `resolution(for:)`, so
   the Settings row's green dot agrees.
2. `func repairUnanswerableRoles() async -> [String]` returns the repaired role names for
   logging. For each `role in ModelRole.allCases`:
   ```swift
   guard case .installedModel(let id) = choice(for: role), !isAnswerable(id) else { continue }
   let appleReady = await LLMProviders.make(.appleFoundation).unavailableReason == nil
   let replacement: ModelRoleChoice = appleReady ? .appleFoundation : .builtIn
   setChoice(replacement, for: role)
   let key = "\(role.rawValue)|\(id)"
   if !shownRepairKeys.contains(key) { notice.report(…); shownRepairKeys.insert(key); persist }
   ```
   Before the loop, `await library.refreshSupportVerdicts()` (P0-13) so verdicts exist.
3. At launch, in `AppDelegate.applicationDidFinishLaunching`, after `if runRequestedSelfTest() { return }`:
   `Task { @MainActor in _ = await ModelRoleStore.shared.repairUnanswerableRoles() }`.
4. In `RealtimeAgent`, add `private(set) var answeringModel: AnsweringModel?`, where
   `struct AnsweringModel: Equatable { let id: LLMProviderID; let name: String }`. Set it in
   `runModelTurn` right after the single resolution (`ToolLoop:353`), and again if P0-14's
   in-turn fallback switches.
5. In `AgentView`, read `RealtimeAgent.shared.answeringModel` and `ModelRoleStore.shared.displayName(for: .agent)`,
   and add the caption view above `composer`. Keep the copy free of "provider", "model id",
   "GGUF" and "llama". "Model" is acceptable.

**Do not:**
- repair a role pointed at `.cloud`, `.localServer` or `.app`. Those have their own
  availability rules;
- repair silently, or repeat the notice every launch;
- add literal colours, fonts or sizes in `AgentView`;
- put the Agent's name into any prompt. This caption is UI, which is allowed.

**Red-first self-test:** extend `--selftest-model-roles` (`Support/ModelRoles/ModelRoleSelfTest.swift`)
with `answerableOnly()` and `launchRepair()`, using the isolated stores from P0-14.

- **`answerableOnly`:**
  - Create a **sparse** file named `mtp-gemma-4-E4B-it-Q4_0.gguf` of 59,700,000 bytes in a temp
    directory: `FileHandle(forWritingTo:)` then `truncate(atOffset:)`. It uses no real disk.
  - Add it to the isolated library as an `InstalledLocalModel` with `bytes: 59_700_000`.
  - Set the role to `.installedModel(thatID)`.
  - Assert that `await store.provider(for: .agent)` is **not** a `LlamaLLMProvider` naming that
    file. Its `displayModelName` must not be the head's name, or its id must not be `.appLLM`
    when Gemma is absent.
- **`launchRepair`:**
  - Write the token `installed:<head id>` into the suite under `modelRoles.agent`.
  - Build the store, and run `await store.repairUnanswerableRoles()`.
  - Assert the choice is now `.appleFoundation` (Apple FM available) or `.builtIn`, that
    `notice.message` contains "can’t run on this Mac", and that a second call reports **no**
    new notice.
- **Answering model:** with `localModelProviderForTesting` set to a stub whose
  `displayModelName` is "Stub", run one typed turn. Assert
  `RealtimeAgent.shared.answeringModel?.name == "Stub"`.
- **Confirm RED:** before implementing, add the method stubs so they compile.
  `repairUnanswerableRoles` returns `[]` and `answeringModel` stays nil. Run it, and expect
  `MODEL_ROLES_FAILED` with the three new failures. `answerableOnly` may already pass once
  P0-14 has landed. Note that in `STATUS.md`, and keep it as a regression pin.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-model-roles
Scripts/run-selftest.sh --selftest-model-unopenable
Scripts/run-selftest.sh --selftest-ui-strings
Scripts/run-selftest.sh --selftest-agent-panes
```

**Success threshold:** the three new cases pass. `MODEL_ROLES_OK`, `UI_STRINGS` and
`AGENT_PANES` are unchanged from the baseline.

**Risks & rollback:**
- A wrong verdict could repair a good role away. The notice tells the owner, and they can set it
  back.
- To roll back: revert. The `modelRoles.repairNotices` key is harmless.

**Done when:**
- [ ] Auxiliary, unrunnable and failed files are never answering.
- [ ] Launch repair runs, with one notice.
- [ ] The caption names the answering model.
- [ ] The self-test cases pass.
- [ ] Committed as `P0-03: …`.

---

### P0-02 — Download verification decodes one token before `switchDeleteOld` deletes anything, and never races the switch

**Finding(s):** T1, D §6 P0-1, F timeline step 1, H1 #24 (step 7). **Effort:** 0.5–1 day.
**Depends on:** P0-13. **Unblocks:** P0-04, P0-01 step 5 (safe role assignment).

**Why (what the user experiences today):**
- On 09-23 the "switch and delete old" policy deleted a working model after a check that only
  **opened** the new file. The new file was an MTP draft head, which opens but cannot build a
  context. From then on, every typed turn answered "Inference could not start."
- The K2 post-download verification at 21:47:24Z took **0.001 s**
  (`metrics.jsonl`, `model.load`, `note: app_llm failed`). That is too fast for any file open. It
  is consistent with `prepare()` running **before** the fire-and-forget adoption Task had swapped
  the spec. In that case it "verified" the absent built-in Gemma (`.modelMissing`), not K2. The
  outcome happened to be safe, but the check tested the wrong file.

**Files you will change:**
- `Formatting/LLM/NotesModelRuntime.swift`: new `trial(_:)`.
- `Support/ModelLibrary/ModelLibraryStore.swift`: `applyPostDownloadPolicy` uses the trial
  before any switch, with an injected verify for tests.
- `Support/ModelLibrary/InstalledModelLibrary.swift`: `lastTrial` on the row
  (`decodeIfPresent`).
- `UI/Settings/ModelsSettingsTab.swift`: "Use for agent turns" requires a successful trial.
- `Support/ModelLibrary/ModelLibraryStore.swift`: `recommendsDeletingOld(fileBytes:)` @ `:461-464` becomes a pure
  static function that also knows whether the previous model is the only one that answers (H-audit 2026-09-23).
- `UI/Settings/ModelLibrary/ModelLibraryViews.swift`: its one reader @ `:365` (unchanged call shape).
- `NextNotesApp.swift`: `runMetalSelfTest` gains the agent-role leg.
- `Support/ModelLibrary/ModelLibrarySelfTests.swift` or `ModelSupportSelfTest.swift`: cases.

**Read for context (do not change):** `ModelLibraryStore.decide` @ `:544-563` (a pure table,
correct as is).

**Current behaviour:**
- `ModelLibraryStore.applyPostDownloadPolicy` @ `ModelLibraryStore.swift:579-603`:
  ```swift
  InstalledModelLibrary.shared.activeAgentModelID = newModel.id   // fires adoptInRuntime Task (not awaited)
  do {
      try await NotesModelRuntime.shared.prepare()                // opens whatever spec is current
      loadSucceeded = InstalledModelLibrary.shared.activeAgentModelID == newModel.id
  } catch { loadSucceeded = false }
  …
  if let deleteID = outcome.deleteID { InstalledModelLibrary.shared.remove(id: deleteID) }
  ```
- `NotesModelRuntime.prepare()` @ `:334-342` only runs `loadIfNeeded`, which opens the file.
- `prepareForConversation` @ `:347-360` would decode a token, but it `guard context == nil else { return }`
  and uses the ChatML routing prompt.
- `runMetalSelfTest` @ `NextNotesApp.swift:2634-2716` loads `NotesModels.spec` or
  `S1MiniModels.spec`, **never** the Agent role's model. It passed on 09-23 on S1-mini.

**Target behaviour:**
1. `NotesModelRuntime.trial(_ model: InstalledLocalModel) async -> ModelTrialResult` loads
   **that exact file**. It builds a context, decodes the prompt, and generates up to 8 tokens
   with the model's own template (P0-04; until then, ChatML). It then restores the previous
   spec, unloading if needed.
   - It returns `.answered(tokens: Int, seconds: Double)`, `.opensButCannotAnswer(String)`
     (a context or decode failure, e.g. an MTP head), or `.cannotOpen(String)`.
   - It **never** touches `InstalledModelLibrary`.
2. `applyPostDownloadPolicy` calls `trial(newModel)` **before** changing
   `activeAgentModelID`. `loadSucceeded` is `true` only for `.answered(tokens ≥ 1)`. Only
   then does it switch and (for `switchDeleteOld`) delete the previous model.
3. The trial result is stored on the row (`lastTrial`). The Models tab's "Use this one" and
   "Use for agent turns" require `lastTrial` to be `.answered`, or offer "Check it works"
   first, which runs the trial.
4. `--selftest-llm-metal` gains an **agent-role leg**:
   - if the Agent role resolves to an installed model (read-only, via
     `SelfTest.allowsSavedModelSelection` from P0-14b), it runs `trial` on it and prints
     `LLM_METAL_AGENT_ROLE: <name> generated <n> token(s) in <s>s`;
   - it fails the whole test when `n == 0`;
   - it prints `LLM_METAL_AGENT_ROLE: apple` (informational) when the role is on Apple FM.

**Steps:**
1. `enum ModelTrialResult: Codable, Sendable, Equatable { case answered(tokens: Int, seconds: Double); case opensButCannotAnswer(String); case cannotOpen(String) }`.
2. Implement `NotesModelRuntime.trial(_:)`:
   - Run it inside `withLane(.background)`.
   - Wait until `swapMustWait(...)` is false. The lane already serialises generations, and
     `conversationLeases` must be empty; if a voice session holds a lease, return
     `.cannotOpen("busy")` and let the caller retry later.
   - Save `let previous = spec`. `shutdownNow()` if loaded, then set `spec = Self.spec(for: model)`
     and `pendingSpec = nil`.
   - Call `openNative`. On nil: `.cannotOpen`.
   - Otherwise build a context with `ensureContext`, tokenize a fixed trial prompt ("Reply with
     the single word OK."), decode it, and sample up to 8 tokens, stopping at EOG.
   - On any thrown error: `.opensButCannotAnswer(error.localizedDescription)`.
   - **Always** `shutdownNow()` and set `spec = previous` in a `defer`, so the runtime is back
     where it was.
   - Increment `loadAttemptCount`.
3. Give `ModelLibraryStore` an injectable verify:
   `var verifyForTesting: ((InstalledLocalModel) async -> ModelTrialResult)?`. In
   `applyPostDownloadPolicy`:
   ```swift
   guard policy != .downloadOnly, previousActiveID != newModel.id else { return }
   let trialResult = await (verifyForTesting ?? { await NotesModelRuntime.shared.trial($0) })(newModel)
   library.setLastTrial(trialResult, for: newModel.id)
   let loadSucceeded: Bool = { if case .answered(let n, _) = trialResult { return n > 0 }; return false }()
   let outcome = Self.decide(policy: policy, previousActiveID: previousActiveID, newModelID: newModel.id, loadSucceeded: loadSucceeded)
   // Never set the Agent role here: the Models tab asks, and only offers it after `.answered`.
   if library.activeAgentModelID != outcome.activeID { library.activeAgentModelID = outcome.activeID }
   if let deleteID = outcome.deleteID { library.remove(id: deleteID) }
   ```
   Inject `library: InstalledModelLibrary = .shared` into `ModelLibraryStore` too.
4. Add `lastTrial: ModelTrialResult?` to `InstalledLocalModel`, with a hand-written
   `init(from:)` or `decodeIfPresent`. Add `InstalledModelLibrary.setLastTrial(_:for:)`, which
   rewrites the manifest row.
5. UI: in `ModelsSettingsTab`, for a runnable row whose `lastTrial` is not `.answered`, show a
   "Check it works" button that runs the trial through `ModelLibraryStore.checkModel(_:)`, which
   hops off the main actor. Show a `ProgressView` while it runs. Gate "Use for agent turns" on
   `.answered`.
6. `runMetalSelfTest`: after the S1-mini leg, add the agent-role leg described in Target 4. It
   must not change any setting.
7. **(H-audit 2026-09-23, H1 #24.) Never steer toward deleting the only model that answers.** Today
   `recommendsDeletingOld(fileBytes:)` (`ModelLibraryStore.swift:461-464`) returns
   `free − fileBytes < minimumFreeBytesAfterDownload * 2` (8 GB), so on this Mac (4.3 GB free) the confirmation
   sheet always leans toward "switch and delete old", the policy that deleted the working model (T1). Replace it with
   ```swift
   nonisolated static func recommendsDeletingOld(freeBytes: Int64, fileBytes: Int64,
                                                 otherAnsweringModels: Int) -> Bool {
       guard otherAnsweringModels > 0 else { return false }   // the old one is the only model that answers
       return freeBytes - fileBytes < ModelDownloader.minimumFreeBytesAfterDownload * 2
   }
   ```
   where `otherAnsweringModels` counts installed rows other than the current `activeAgentModelID` whose `lastTrial`
   is `.answered` (step 4). The new file has no trial before it is downloaded, so on a Mac with one working model the
   sheet never recommends deleting it; the delete itself still happens only after the new file's trial answers
   (step 3). The 4 GB reserve is unchanged (it is on the "Limits we keep on purpose" list in `00-README.md`).

**Do not:**
- delete anything unless a token was generated by the **new** file;
- set `activeAgentModelID` before the trial (that was the race);
- leave the trial's model resident. It must restore the previous spec;
- call `beginCleanup()` from the trial. The cleanup gate is one-directional (AGENTS.md);
- run the trial while a voice session holds a conversation lease;
- let the self-test download or delete a real model file;
- recommend deleting a model when no other installed model has answered a trial (H-audit 2026-09-23).

**Red-first self-test:** add `postDownloadVerify()` to `ModelSupportSelfTest` (run under
`--selftest-model-unopenable`), with isolated stores:

1. Seed a temp library with a previous model row A (a sparse file) and a new row B (a sparse
   file). Set `store.verifyForTesting = { _ in .opensButCannotAnswer("context") }`. Run
   `await store.applyPostDownloadPolicyForTesting(.switchDeleteOld, previousActiveID: A, newModel: B)`
   (a thin internal wrapper). Assert that A's file **still exists**, and that `activeAgentModelID == A`.
2. The same, with `.answered(tokens: 3, seconds: 0.2)`. Assert that A is deleted and B is active.
3. **Ordering.** Record the order of events through the seams: the verify closure records
   "verify", and the library's `activeAgentModelID` write counter records "switch". Assert
   "verify" happens before "switch". Today, the switch comes first.
4. **Live leg:** if S1-mini is downloaded, run
   `await NotesModelRuntime(spec: NotesModels.spec, gpuLayers: 0).trial(<S1-mini as InstalledLocalModel>)`.
   Expect `.answered` with tokens ≥ 1. Also run `trial(<P0-13 unknown-architecture fixture>)`
   and expect `.cannotOpen`. Print `S1MINI_ABSENT` and skip only the first part when S1-mini
   is absent.

5. **(H-audit 2026-09-23.)** Pure table for step 7: `recommendsDeletingOld(freeBytes: 4.3 GB, fileBytes: 2.5 GB,
   otherAnsweringModels: 0) == false`; the same with `otherAnsweringModels: 1` `== true`;
   `(freeBytes: 40 GB, fileBytes: 2.5 GB, otherAnsweringModels: 1) == false`. RED today: the current rule has no
   answering-model input, so the stub that forwards to it returns `true` for the first row.

**Confirm RED:** add `verifyForTesting` and the wrapper, but leave the old `prepare()`-based
logic, with the verify closure ignored. Assertion 1 then fails (A is deleted, because
`prepare()` on an isolated setup throws, which is actually safe) or assertion 3 fails
(ordering). Make sure at least assertion 3 fails, and record the output.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-model-unopenable
Scripts/run-selftest.sh --selftest-llm-metal
Scripts/run-selftest.sh --selftest-model-fit
Scripts/run-selftest.sh --selftest-model-roles
```

**Success threshold:**
- Assertions 1–5 pass.
- The S1-mini trial takes < 5 s.
- `LLM_METAL_OK` prints an `LLM_METAL_AGENT_ROLE` line.
- On this Mac, after P0-01, the agent-role leg reports ≥ 1 token from Qwen3-4B-Instruct-2507.

**Risks & rollback:**
- The trial frees resident weights, so the next answer pays a cold load. It runs only after a
  download or an explicit "Check it works", which is acceptable.
- To roll back: revert. Old rows decode, because `lastTrial` is optional.

**Done when:**
- [ ] `trial` exists and restores the previous state.
- [ ] Policy uses the trial before the switch.
- [ ] The UI is gated on it.
- [ ] llm-metal has the agent-role leg.
- [ ] The sheet never recommends deleting the only model that answers (step 7).
- [ ] Cases pass.
- [ ] Committed as `P0-02: …`.

---

### P0-04 — Per-family chat templates; special and control tokens preserved in planner output

**Finding(s):** T2, F R6, B D2, **G N3** (MiniCPM5 control-token tool delimiters, folded in on
2026-09-23). **Effort:** 1.5–2 days. **Depends on:** P0-13 (metadata reader), P0-02 (trial uses
the template). **Unblocks:** P1-04, P1-05, P0-18 (the reused prefix is the family-rendered one), and
meeting notes on an installed model.

**Why (what the user experiences today):**
- Tool calls came out as fragments shown as the reply: "Every night at 10, remind me…" →
  `name="reminders">`, and "make a document… about me" →
  `name="search_knowledge"> name="query">user …` (B §3, 09-23 06:37Z and 06:39Z).
- The runtime wraps **every** model in ChatML with a pre-closed Qwen `<think>` block.
- It detokenizes with `special = false`, so a model whose tool-call delimiters are control
  tokens loses them.
- Gemma 4 uses `<|turn>` and `<|tool_call>call:name{…}<tool_call|>`. Llama 3 uses
  `<|start_header_id|>` and `<|eot_id|>`. Neither is ChatML.
- **MiniCPM5-2B, installed on this Mac (G N3, read from the GGUF vocabulary):**
  - `<tool_call>` (id 2), `</tool_call>` (3), `<function` (18), `</function>` (19), `<param` (20)
    and `</param>` (21) are all `token_type = control`. With `special = false` they decode as "".
  - A native call `<function name="x"><param name="k">v</param></function>` therefore reaches the
    parser as ` name="x"> name="k">v`. That is the exact shape of the 09-23 06:37Z
    `name="reminders">` leak.
  - Its template is ChatML with a `<think>` block (so `chatmlThinking` otherwise). It begins with
    `{{ bos_token }}` (`<s>`, id 0), while `add_bos_token = false`, and the app never adds that BOS
    token.

**Scope decision:** P0-16 is "won't do", so the K2 `<|ifm|im_start|>` family is **out of
scope**. Cover these families:

| Family | Detected when `tokenizer.chat_template` contains… | Prompt | Stop marker (as text) | Notes |
|---|---|---|---|---|
| `chatmlThinking` | `<\|im_start\|>` **and** `<think>` | `<\|im_start\|>system\n{sys}<\|im_end\|>\n` + turns + `<\|im_start\|>assistant\n<think>\n\n</think>\n\n` | `<\|im_end\|>` | Qwen3 hybrid, Qwen3.5 (`qwen35`), S1-mini. Today's prompt, unchanged. |
| `chatml` | `<\|im_start\|>` without `<think>` in the generation prompt. Qwen3-Instruct-2507 has `<think>` only in the history-stripping part, so use architecture `qwen3` **and** the absence of `enable_thinking` in the template | the same, but end with `<\|im_start\|>assistant\n` | `<\|im_end\|>` | Qwen3-4B-Instruct-2507, recommended in P0-01. |
| `llama3` | `<\|start_header_id\|>` | `<\|start_header_id\|>system<\|end_header_id\|>\n\n{sys}<\|eot_id\|>` + for each turn `<\|start_header_id\|>{role}<\|end_header_id\|>\n\n{text}<\|eot_id\|>` + `<\|start_header_id\|>assistant<\|end_header_id\|>\n\n` (BOS is added by the tokenizer's `addSpecial`, so do not write `<\|begin_of_text\|>` as text) | `<\|eot_id\|>` | Llama 3.2 3B. |
| `gemma` | `<start_of_turn>` | `<start_of_turn>user\n{sys}\n\n{first user}<end_of_turn>\n` … `<start_of_turn>model\n` (no system role: merge it into the first user turn; assistant → `model`) | `<end_of_turn>` | Gemma 2 and 3. |
| `gemma4` | `<\|turn>` | `<\|turn>system\n{sys}<turn\|>\n` + `<\|turn>{user\|model}\n{text}<turn\|>\n` + `<\|turn>model\n` (do not emit `<\|think\|>`, so thinking stays off) | `<turn\|>` | The built-in Gemma 4 E4B (template verified from `ggml-org/gemma-4-E4B-it-GGUF`, lines 188–384). Tool calls look like `<\|tool_call>call:NAME{…}<tool_call\|>`. |
| `minicpm5` | `tokenizer.ggml.pre == "minicpm5"` (from `GGUFMetadata.preTokenizer`), **or** the template contains `<function name=` | the `chatmlThinking` prompt, preceded by the BOS **token** (see Steps 1 and 3) | `<\|im_end\|>` | MiniCPM5-2B (installed, G N3). Tool calls are `<function name="NAME"><param name="KEY">VALUE</param></function>`, optionally inside `<tool_call>…</tool_call>`, and every delimiter is a control token. P1-04 parses the form; this task makes the delimiters survive. |
| `unsupported` | anything else | not used | | The model is refused at trial with the sentence "Next Notes can’t talk to this model yet." Also, `LlamaLoadProbe` or trial marks it unrunnable. |

The markers above were verified on 2026-09-23 by fetching `gguf.chat_template` from the Hugging
Face API for `unsloth/Qwen3-4B-Instruct-2507-GGUF`, `unsloth/Qwen3.5-4B-GGUF`,
`unsloth/Llama-3.2-3B-Instruct-GGUF` and `ggml-org/gemma-4-E4B-it-GGUF`. Re-check a template by
reading it from the GGUF (`GGUFMetadata.read(url).chatTemplate`) whenever a family misbehaves.
`llama_chat_apply_template` is **not** a substitute. Its built-in list at b10621 (`src/llama-chat.cpp`)
has `chatml`, `llama3` and `gemma`, but no `gemma4` and no Qwen thinking variant.

**Files you will change:**
- new `Formatting/LLM/ChatTemplate.swift`, holding `ChatTemplateFamily`, detection and rendering;
- `Formatting/LLM/NotesModelRuntime.swift`: `chatMLPrompt` callers → `render(system:messages:)`,
  stop markers per family, detection at load, and `renderSpecial`;
- `Formatting/LLM/LlamaHelpers.swift`: `piece(_:vocabulary:renderSpecial:)`;
- `Agent/RealtimeAgent+ToolLoop.swift`: nothing, as long as the planner path requests special
  rendering through the provider. If a flag is needed, add
  `LLMProvider.streamConversation(…, purpose: .planner)`;
- new `Formatting/LLM/ChatTemplateSelfTest.swift`;
- `NextNotesApp.swift`, `AGENTS.md`, `Scripts/acceptance.sh` for `--selftest-chat-template`
  (INTEGRATION).

**Read for context (do not change):**
- `Agent/AgentToolCall.swift` (the parser is P1-04's job);
- `Formatting/LLM/S1MiniRuntime.swift`, which has its own prompt. Leave it alone.

**Current behaviour:**
- `NotesModelRuntime.chatMLPrompt(system:messages:)` @ `:1030-1042` always emits ChatML and
  ends with `<|im_start|>assistant\n<think>\n\n</think>\n\n`. `turnEnd = "<|im_end|>"` @ `:1044`.
  The callers are at `:353, :421, :429, :438, :513`. The decode loops @ `:537-559` and
  `:612-651` stop on EOG or on the literal `<|im_end|>`.
- `LlamaHelpers.tokenize` @ `LlamaHelpers.swift:15-33` passes `parse_special = true` (the last
  argument of `llama_tokenize`).
- `LlamaHelpers.piece` @ `:40-50` calls `llama_token_to_piece(…, 0, false)`, which means
  `special = false`, so control tokens render as "".
- `ToolLoop:934`: `if completionText.contains("<tool_call>") || completionText.contains("</tool_call>")`.
  A Gemma 4 or other control-token call never matches, so the remainder is returned as the
  answer (`ToolLoop:950`).

**Target behaviour:**
1. At load (and in `trial`), the runtime detects the family from
   `llama_model_chat_template(model, nil)`, falling back to `GGUFMetadata.chatTemplate`, plus
   `general.architecture`. It stores `family`, and renders every prompt with it.
2. Stop handling uses the family's stop marker. EOG tokens still stop generation.
3. Planner and tool output are decoded with `renderSpecial: true`, so `<|tool_call>` or
   `<tool_call>` survive into the text the parser sees. Notes and plain answers strip any
   leftover family control markers (`<|channel>…<channel|>`, `<think>…</think>`) before they
   are shown.
4. A model whose family is `unsupported` fails the trial with `.opensButCannotAnswer`, and is
   never offered to a role.
5. **Explicit BOS.** When the chat template begins with `{{ bos_token }}` (also accept
   `{{- bos_token }}` and `{{bos_token}}`) and `llama_vocab_get_add_bos(vocab)` is false, the runtime
   prepends `llama_vocab_bos(vocab)` as a **token** to the prompt's token list. It is never written
   as the text `<s>`. This is generic, and MiniCPM5 is the known case.
6. For `minicpm5`, the planner text keeps `<function name=…>`, `<param name=…>`, `</param>`,
   `</function>` and `<tool_call>`, so P1-04's recogniser can read the call.

**Steps:**
1. `ChatTemplate.swift`:
   ```swift
   enum ChatTemplateFamily: String, Codable, Sendable { case chatmlThinking, chatml, llama3, gemma, gemma4, minicpm5, unsupported }
   enum ChatTemplate {
       static func detect(template: String?, architecture: String?, preTokenizer: String? = nil) -> ChatTemplateFamily
       /// True when the template starts with `{{ bos_token }}` and the vocabulary does not add BOS itself.
       static func needsExplicitBOS(template: String?, vocabularyAddsBOS: Bool) -> Bool
       static func render(_ family: ChatTemplateFamily, system: String, messages: [LLMChatMessage]) -> String
       static func stopMarker(_ family: ChatTemplateFamily) -> String
       static func controlMarkers(_ family: ChatTemplateFamily) -> [String]   // stripped from user-visible text
   }
   ```
   Keep the existing `safe()` escaping (`<|` → `< |`), and extend it per family: for Gemma,
   also escape `<start_of_turn>` and `<end_of_turn>`; for Gemma 4, `<|turn>` and `<turn|>`.
   Map roles: `system` / `user` / `assistant`, with `assistant` → `model` for both Gemma
   families.
   Detection order:
   - `preTokenizer == "minicpm5"` or `<function name=` in the template → `minicpm5` (checked
     **before** the ChatML rule, because MiniCPM5's template also contains `<|im_start|>`)
   - `<|turn>` → `gemma4`
   - `<start_of_turn>` → `gemma`
   - `<|start_header_id|>` → `llama3`
   - `<|im_start|>` → `chatmlThinking` if the template contains `enable_thinking` or its
     generation prompt emits `<think>`, else `chatml`
   - otherwise → `unsupported`

   When the template is absent and the architecture is `qwen2`, `qwen3` or `qwen35`, fall back
   to `chatmlThinking` (S1-mini's case).
2. `NotesModelRuntime`:
   - Add `private(set) var family: ChatTemplateFamily = .chatmlThinking`, set in `load` after
     `openNative` succeeds.
   - Replace every `Self.chatMLPrompt(...)` call with `ChatTemplate.render(family, …)`.
   - Replace `Self.turnEnd` with `ChatTemplate.stopMarker(family)` in both decode loops. Keep
     `chatMLPrompt` as a deprecated wrapper only if a self-test still calls it; otherwise delete
     it.
3. `LlamaHelpers.piece(_ token:, vocabulary:, renderSpecial: Bool = false)` passes
   `renderSpecial` as the last argument.
   - `streamWhileScheduled` gains a `renderSpecial` parameter.
   - `streamConversation` and `streamInteractiveConversation`, which are the planner and first
     pass, set it to `true`.
   - `complete` (notes) keeps `false`, then strips `controlMarkers`.
4. `ToolLoop:934`: also treat the Gemma 4 `<|tool_call>` marker and MiniCPM5's `<function name=`
   as tool-call signals. Parsing them is P1-04. In Phase 0, such a call becomes "invalid tool
   request" (honest) rather than leaking as the answer.
5. **BOS.** At load, store `addsBOS = llama_vocab_get_add_bos(vocabulary)` and
   `explicitBOS = ChatTemplate.needsExplicitBOS(template:vocabularyAddsBOS:)`. Wherever the runtime
   tokenizes a rendered prompt (`completeWhileScheduled`, `streamWhileScheduled`,
   `prepareForConversation`), prepend `llama_vocab_bos(vocabulary)` when `explicitBOS` is true and the
   first token is not already BOS. `LlamaHelpers.tokenize` keeps passing `add_special` as today; the BOS
   rule is separate and explicit.

**Do not:**
- change S1-mini's prompt (`S1MiniRuntime`);
- use `llama_chat_apply_template` as the only mechanism (no `gemma4` at b10621);
- emit `<|think|>` for Gemma 4, or leave an open `<think>` for Qwen. Thinking must stay off in
  Phase 0;
- let control markers reach speech or the conversation view. `AgentSpeechPolicy` must never
  speak `<|…|>`;
- edit the persona or the prompts' wording. That is P4-03.

**Red-first self-test:** `--selftest-chat-template` in `Formatting/LLM/ChatTemplateSelfTest.swift`.
Pure, except for the S1-mini case.

1. **Detection.** Fixture snippets are written in the test file. Use short marker strings, not
   whole templates:
   - `"{{- '<|turn>system\n' -}}…{{- '<|turn>model\n' -}}"` → `gemma4`
   - `"<start_of_turn>user"` → `gemma`
   - `"<|start_header_id|>"` → `llama3`
   - `"<|im_start|>… enable_thinking …<think>"` → `chatmlThinking`
   - `"<|im_start|>assistant\n"` with architecture `qwen3` and no `enable_thinking` → `chatml`
   - `"<|ifm|im_start|>"` → `unsupported`
2. **Rendering.** For `gemma4`, with system "S" and user "U", the output equals exactly
   `"<|turn>system\nS<turn|>\n<|turn>user\nU<turn|>\n<|turn>model\n"`. **Fail if any Gemma
   rendering contains `<|im_start|>`.** Write similar exact-string checks for `llama3`, `gemma`
   and `chatml`.
3. **The runtime uses the family.** Assert that `NotesModelRuntime.render(forFamily: .gemma4, …)`,
   the helper the runtime calls, does not produce ChatML.
4. **Special tokens (live, S1-mini).**
   - If `S1MiniModels.spec.isDownloaded`, open its vocabulary with
     `vocab_only = true`.
   - Tokenize `"<|im_end|>"` with `parse_special = true`, and assert it is exactly 1 token.
   - Assert that `LlamaHelpers.piece(tok, vocabulary:, renderSpecial: true) == "<|im_end|>"`.
   - Assert that the **planner decode path** helper
     (`NotesModelRuntime.plannerPiece(tok, vocabulary)`, a static that wraps the call with the
     planner's flag) returns `"<|im_end|>"`. It fails today because the planner uses
     `special = false`.
   - Print `S1MINI_ABSENT` and skip only this case when the file is missing.
5. **MiniCPM5 (G N3).**
   - Pure part: `detect(template: "{{ bos_token }}<|im_start|>…<function name=", architecture: "llama", preTokenizer: nil)`
     is `.minicpm5`, and so is `detect(template: nil, architecture: "llama", preTokenizer: "minicpm5")`.
     `needsExplicitBOS(template: "{{ bos_token }}<|im_start|>", vocabularyAddsBOS: false)` is true;
     with `vocabularyAddsBOS: true` it is false.
   - Live part: find a `*MiniCPM5*.gguf` in `~/Library/Application Support/Next Notes/Models/`,
     read-only (do not use the library store). Open it with `vocab_only = true`. Tokenize
     `<function name="x"><param name="k">v</param></function>` with `parse_special = true`.
     - Assert that ids 18, 20, 21 and 19 appear.
     - Assert that `NotesModelRuntime.plannerPiece` returns the literal markers for them.
     - Assert that `LlamaHelpers.piece(…, renderSpecial: false)` returns "" for id 18. This
       documents the loss that the planner flag fixes.
     - Print `MINICPM5_ABSENT` and skip only this live part when no file is present.
6. The final lines are `CHAT_TEMPLATE_OK: 6 families detected and rendered; control tokens survive planner decode`
   or `CHAT_TEMPLATE_FAILED: <n> problem(s)`.

**Confirm RED:** add `ChatTemplate` with `detect` returning `.chatmlThinking` for everything,
`render` delegating to `chatMLPrompt`, `needsExplicitBOS` returning false, and `plannerPiece` using
`special: false`, matching today. Run it, and expect failures in cases 1–5. Case 5's live part fails
only when the MiniCPM5 file is present, which it is on this Mac today.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-chat-template
Scripts/run-selftest.sh --selftest-llm-metal
Scripts/run-selftest.sh --selftest-toolloop-production
Scripts/run-selftest.sh --selftest-model-unopenable
Scripts/run-selftest.sh --selftest-cleanup-structure     # S1-mini untouched
Scripts/run-selftest.sh --selftest-timeout 900 --selftest-agent-answers   # with Qwen installed
```

**Success threshold:**
- All 6 cases pass (the MiniCPM5 live part is not skipped on this Mac).
- `AGENT_ANSWERS_OK` is still 3/3 on Qwen3-4B-Instruct-2507, now rendered as `chatml`.
- `LLM_METAL_AGENT_ROLE` still reports ≥ 1 token.

**Risks & rollback:**
- A wrong detection would render the wrong turns. The trial (P0-02) catches models that then
  produce nothing.
- The notes quality on an installed model could shift. It was always ChatML before, which was
  already wrong for non-Qwen models.
- To roll back: revert.

**Done when:**
- [ ] Families are detected, rendered and stopped correctly, including `minicpm5`.
- [ ] Planner decode renders special tokens, and an explicit BOS token is added where the template asks for it.
- [ ] `CHAT_TEMPLATE_OK`.
- [ ] Agent answers are unchanged or better.
- [ ] Committed as `P0-04: …`.

---

### P0-05 — Remove the fixed 112-token typed cap: the answer budget comes from the model's window and the persona depth

**Finding(s):** Q2 (part), B D6, G (turns O2, O3, O5), H1 #2 and #3, owner request 2026-09-23. **Effort:** 3 h.
**Depends on:** none. **Unblocks:** P1-02 (its step 6 calls the function defined here for planner rounds), P1-06 (its final
answer-only round calls it too).
**Linked task: P0-17 — land both in the same session.** On a reasoning model (OpenRouter `ling-3.0`, G §2.1) a
larger visible budget alone does not help: the model spends the budget thinking before it writes. G O5 measured
105 of 112 completion tokens spent on reasoning and `finish_reason: "length"`. P0-05 decides how many **visible**
tokens a typed answer may have; P0-17 adds the bounded reasoning allowance on top and reads `finish_reason`. Either
one alone still loses those turns, so run P0-17's `--selftest-openrouter-contract` again after this task, and do
not commit P0-05 on a day P0-17 cannot follow.

**Why (what the user experiences today):**
- Typed answers are cut mid-sentence even with `agentResponsiveness = deep`, which promises 500 tokens. The typed
  first pass is hard-coded to `maxTokens: 112` (`ToolLoop:414`, `:418`), so the setting reaches only the
  `.localModel` path (`Agent/RealtimeAgent.swift:643`, `:647`).
- G O2 was clipped mid-list, and O5 ended after "I have tools for these: – **Calendar** — agenda, events" (M, G §2.1).
- The planner writes the final typed answer too, and it is hard-coded to `maxTokens: 256` per round (`ToolLoop:888`,
  `:891`). A `draft_email` body is cut there and then parses as an invalid call (B T4, H1 #3).
- Neither number looks at the model. This Mac's typed reader was a 262,144-token OpenRouter model (H1, M), and the
  same 112 applied to it as to a 4,096-token Apple FM window.

**Files you will change:**
- new `Agent/AgentAnswerBudget.swift`: `AgentAnswerBudget`.
- `Agent/RealtimeAgent+ToolLoop.swift`: the private `runModelTurn` first-pass call sites (`:408-419`); a testing seam
  `answerDepthForTesting`.
- `Agent/RealtimeAgent.swift`: the `.localModel` call sites (`:643`, `:647`) go through the same function.
- `Agent/RealtimeAgentToolLoopSelfTest.swift`: `ToolLoopTestProvider` (`:664`, `contextTokens` fixed at 4,096 on
  `:671`) gains a settable window and records `maxTokens`; four cases.

**Read for context (do not change):**
- `AgentResponsiveness.localAnswerTokenBudget` @ `Support/Settings.swift:71-77` (fast 128, balanced 256, deep 500).
  This is the persona depth budget. It stays the user's one setting.
- `LLMProvider.contextTokens` and `countTokens(_:)` @ `Formatting/LLM/LLMProvider.swift:84`, `:89`.
- `LlamaLLMProvider.contextTokens` @ `Formatting/LLM/LlamaLLMProvider.swift:24` returns
  `NotesModelRuntime.maxContextTokens` (32,768), not the loaded model's trained window.
  `NotesModelRuntime.contextTokens` @ `Formatting/LLM/NotesModelRuntime.swift:266` is the real one once the model is
  loaded, and the runtime refuses `promptTokens + maxTokens + contextHeadroom (256) > contextTokens` with
  `inputTooLong` (`:515`, `:586`).
- `FoundationModelLLMProvider.contextTokens = 4_096` @ `Formatting/LLM/FoundationModelLLMProvider.swift:13`
  (P1-10a step 0 later reads the runtime value; G measured 8,192).
- `OpenRouterLLMProvider.init` @ `Formatting/LLM/OpenRouterLLMProvider.swift:396-402`:
  `contextTokens = max(2_048, min(published − 2_048, 200_000))`.
- `Limits.modelWarm` 18 s / `modelCold` 45 s @ `Agent/RealtimeAgent.swift:31-32`. P1-06 owns time budgets.

**Current behaviour:** in the private `runModelTurn` @ `ToolLoop:372-490` (grep `private func runModelTurn`):
```swift
let stream = if voice {
    await LatencyCorrelation.$current.withValue(correlation) {
        await provider.streamInteractiveConversation(
            system: Self.voiceRoutingSystem(voice: true), messages: messages, maxTokens: 112)
    }
} else {
    await provider.streamConversation(
        system: Self.voiceRoutingSystem(voice: false), messages: messages, maxTokens: 112)
}
```
The planner round, in the private `runPlannedToolLoop` @ `ToolLoop:884-892`, passes `maxTokens: 256` on both
branches. `RealtimeAgent.swift:643` and `:647` pass `Settings.shared.agentResponsiveness.localAnswerTokenBudget`
directly, with no check against the model's window.

**Target behaviour:**
1. **No fixed typed cap remains.** The typed first pass asks for
   `AgentAnswerBudget.tokens(kind: .typedAnswer, contextTokens: W, promptTokens: P)`, where `W` is the reader's real
   window and `P` is the counted system prompt plus messages. The rule is:
   ```
   visible = min(wanted(kind, depth), W − P − safetyTokens)      safetyTokens = 256, floor 64
   wanted(.typedAnswer) = depth budget: fast 128 · balanced 256 · deep 500
   ```
   `grep -n "maxTokens: 112" Sources/NextNotes/Agent/RealtimeAgent+ToolLoop.swift` finds no typed call site.
2. **The persona "deep" budget of 500 is honoured** whenever the window has room for it. On every reader this Mac
   has used (Apple FM 4,096/8,192, llama ≥ 4,096, OpenRouter 262K) a typed turn's prompt of 1.2–2.3 K tokens (B §1)
   leaves room, so `deep` gets exactly 500.
3. **The same rule for planner rounds.** P1-02 step 6 replaces the literal `256` with
   `AgentAnswerBudget.tokens(kind: .plannerRound(background:), …)`. Its wanted value (typed ≥ 1,024 and at least the
   depth budget, voice worker 768) is P1-02's; the cap `W − P − 256` is this task's. P1-06's final answer-only round
   uses `.finalAnswer` (wanted = the depth budget). This task defines all four kinds, so P1-02 and P1-06 only call
   it.
4. **Voice keeps its own wanted value, not a cap.** `.voiceFirstPass` wants 112 visible tokens (one or two spoken
   sentences; a latency choice) and is clamped by the same room rule. It is reached only by self-tests today: a
   production voice turn goes to the coordinator (`RealtimeAgent.swift:208-212`), whose frontend answer cap (256) and
   route cap (64) are kept on purpose (00-README "Limits we keep on purpose").
5. **The `.localModel` path** (`RealtimeAgent.swift:643`, `:647`) uses `.typedAnswer` through the same function, so a
   small window can no longer be asked for more than it holds.

**Cost of the larger budget (read before deciding it is too expensive):**
- The budget is a **ceiling**, not a target. A model that answers in 40 tokens stops at 40.
- Streaming is unchanged, so **time to first token does not change**. The first words appear exactly as soon as
  today.
- The only cost is the time to *finish* a long answer on a slow local model. At MiniCPM5-2B's measured ~45 tok/s
  decode (G), a full 500-token `deep` answer takes about 11 s instead of about 2.5 s for 112 (estimate from the G
  rate). Inside the 18 s warm first-pass budget that leaves about 7 s for prefill (G measured 2.2–5.2 s, H1 #1); a
  cold load uses the 45 s budget. P1-02 removes the typed first pass and P1-06 moves to per-round budgets, so this
  pressure is temporary.
- OpenRouter spend is negligible: the free `ling-3.0` costs nothing, and on a paid model 388 extra output tokens at
  an illustrative $0.60 per million is about $0.0002 per turn (estimate). P0-17's reasoning allowance is bounded
  separately.
- **Context room is protected**, because the budget is derived from `contextTokens − promptTokens`, never added
  blindly: a 4,096-token reader with a 3,800-token prompt gets `4,096 − 3,800 − 256 = 40` → the floor of 64, and the
  runtime's own `inputTooLong` check is never provoked by this change. P1-10a's fitter shrinks prompts that leave
  less.

**Steps:**
1. New file `Agent/AgentAnswerBudget.swift`:
   ```swift
   /// How many visible tokens one model pass may write. Derived from the reader's real window
   /// and the user's depth setting; never a fixed constant (P0-05).
   enum AgentAnswerBudget {
       enum Kind: Sendable, Equatable {
           case typedAnswer                     // typed first pass; `.localModel` answers
           case plannerRound(background: Bool)  // P1-02 step 6 supplies the wanted value
           case finalAnswer                     // P1-06's answer-only round
           case voiceFirstPass                  // test-only voice branch of runModelTurn
       }
       static let safetyTokens = 256            // = NotesModelRuntime.contextHeadroom
       static let floorTokens = 64

       static func wanted(_ kind: Kind, depth: AgentResponsiveness) -> Int {
           switch kind {
           case .typedAnswer, .finalAnswer: depth.localAnswerTokenBudget
           case .voiceFirstPass: 112
           case .plannerRound(let background):
               background ? 768 : max(1_024, depth.localAnswerTokenBudget)   // P1-02 step 6 owns these two numbers
           }
       }

       static func tokens(kind: Kind, contextTokens: Int, promptTokens: Int,
                          depth: AgentResponsiveness) -> Int {
           let room = contextTokens - promptTokens - safetyTokens
           return max(floorTokens, min(wanted(kind, depth: depth), room))
       }

       /// The reader's real window. For the in-process llama model this is the loaded model's
       /// trained window, not `LlamaLLMProvider.contextTokens` (always 32,768).
       static func readerContextTokens(for provider: any LLMProvider) async -> Int {
           if provider.id == .appLLM, await NotesModelRuntime.shared.isLoaded {
               return await NotesModelRuntime.shared.contextTokens
           }
           return provider.contextTokens
       }
   }
   ```
   `wanted(.plannerRound)` is written here so P1-02 has one place to edit. If P1-02 changes the planner numbers, it
   changes them here.
2. In `RealtimeAgent` add a testing seam:
   `var answerDepthForTesting: AgentResponsiveness?` (read as
   `answerDepthForTesting ?? Settings.shared.agentResponsiveness`). A self-test must never write
   `agentResponsiveness` into the user's defaults.
3. In the private `runModelTurn`, before the `while` loop, compute once per turn:
   ```swift
   let window = await AgentAnswerBudget.readerContextTokens(for: provider)
   let system = Self.voiceRoutingSystem(voice: voice)
   let promptTokens = (try? await provider.countTokens(system + messages.map(\.content).joined(separator: "\n")))
       ?? (system.count + messages.reduce(0) { $0 + $1.content.count }) / 4
   let visible = AgentAnswerBudget.tokens(kind: voice ? .voiceFirstPass : .typedAnswer,
                                          contextTokens: window, promptTokens: promptTokens, depth: depth)
   ```
   `messages` is rebuilt inside the loop when a revision changes; recount there too (it is cheap for every
   provider: llama tokenizes, the others estimate). Pass `maxTokens: visible` at both call sites.
4. `RealtimeAgent.swift:643` and `:647`: compute `visible` the same way with `.typedAnswer`, using the grounded
   prompt and `Self.localModelSystem`.
5. Leave `Limits.modelWarm` / `modelCold` alone (P1-06), and leave the planner's `256` for P1-02 step 6, which now
   has the function to call.
6. Log once per pass at info level: `answer budget · kind=<k> window=<W> prompt=<P> visible=<n>` so a clipped answer
   can be explained from the log (P0-20 records `completionTokens` and `finishReason` persistently).

**Do not:**
- keep any literal token cap on a typed path. A number that does not come from the depth setting or the reader's
  window is the bug this task removes;
- read `LlamaLLMProvider.contextTokens` as the llama window (it is the 32,768 ceiling); use
  `readerContextTokens(for:)`;
- change the voice frontend's 256 / 64 caps or the 25 s voice deadline (kept on purpose, H1 §2.4, H2 V33);
- change the prompt wording (P4-03) or the time budgets (P1-06);
- write `Settings.shared.agentResponsiveness` from a self-test (use `answerDepthForTesting`);
- add the reasoning allowance here. It is P0-17's, on top of `visible`, for OpenRouter only.

**Red-first self-test:** extend `--selftest-toolloop-production` (`RealtimeAgentToolLoopSelfTest.run`). The decision
document names this check under `--selftest-toolloop`, but that flag runs the pure `AgentToolLoop.runSelfTest`; the
provider-driven test is `--selftest-toolloop-production`.
- Give `ToolLoopTestProvider` a stored `window: Int = 4_096` returned by `contextTokens`, and a
  `streamConversation(system:messages:maxTokens:)` that records `maxTokens` into
  `ToolLoopTestState.firstPassMaxTokens`. Its `countTokens` stays `text.count / 4 + 1` (`:684`).
- **a. Deep on a large window.** `answerDepthForTesting = .deep`, `window = 32_768`, typed turn
  `runModelTurn("What's 2+2?", voice: false)` with the stub answering `<answer/>4.` → recorded max == 500.
- **b. Fast.** Same with `.fast` → 128.
- **c. Small window.** `.deep`, `window = 1_536`, and a history padded so the counted prompt is about 900 tokens →
  recorded max == `1_536 − P − 256` (about 380, below the 500 the depth wants), where `P` is the test's own count of
  the same system + messages. The test provider's id is `.appLLM`, but under the harness the runtime is not loaded,
  so `readerContextTokens(for:)` returns the provider's `window`.
- **d. Pure table.** `AgentAnswerBudget.tokens` for (typedAnswer, deep, W 262_144, P 2_000) = 500;
  (plannerRound(background: false), deep, 32_768, 2_000) = 1_024; (plannerRound(background: true), fast, 8_192,
  2_000) = 768; (finalAnswer, balanced, 4_096, 3_900) = 64.
- Failure lines: `TOOLLOOP_PRODUCTION_WRONG: typed first pass asked for <n>, expected <m>`. The final marker stays
  `TOOLLOOP_PRODUCTION_OK` / `TOOLLOOP_PRODUCTION_FAILED`.
- **Confirm RED:** add the seam, the test provider changes and a stub `AgentAnswerBudget.tokens` that returns 112.
  Cases a, b and c fail (112 ≠ 500, 112 ≠ 128, 112 ≠ about 380). Case d fails until the real body exists.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-toolloop-production
Scripts/run-selftest.sh --selftest-toolloop
Scripts/run-selftest.sh --selftest-voice-grounding
Scripts/run-selftest.sh --selftest-tool-awareness
Scripts/run-selftest.sh --selftest-openrouter-contract     # P0-17's, re-run in the same session
grep -n "maxTokens: 112" Sources/NextNotes/Agent/RealtimeAgent+ToolLoop.swift   # no typed call site may match
```

**Success threshold:**
- Cases a–d pass and were red first: 500 at `deep` on a 32K window, 128 at `fast`, the small-window value ≤ the
  room, the four table values exact.
- The grep finds no typed `maxTokens: 112`.
- `--selftest-toolloop`, `--selftest-voice-grounding`, `--selftest-tool-awareness` end as in the baseline.
- Owner smoke (after P0-17 in the same session, Agent role on the reasoning OpenRouter model, `deep`): "What can you
  do?" ends in a complete sentence. Paste the reply's last sentence into STATUS.

**Risks & rollback:**
- A long typed answer on a slow local model can reach the 18 s warm budget (see the cost note). Watch for "The model
  took too long to answer." in the smoke; if it appears, record it for P1-06 rather than lowering the depth budget.
- `countTokens` on a cold llama model loads the tokenizer; it already happens for notes. If it throws, the character
  estimate is used.
- Rollback: make `AgentAnswerBudget.wanted(.typedAnswer, …)` return 112. The call sites stay.

**Done when:**
- [ ] `AgentAnswerBudget` exists with the four kinds, and every typed and `.localModel` call site uses it.
- [ ] No typed call site passes a literal token count.
- [ ] Cases a–d green (red first).
- [ ] P0-17 landed in the same session, and its contract test was re-run after this task.
- [ ] Committed as `P0-05: …`.

---

### P0-06 — Worker warmup off the voice lane; cancellable `ComputeScheduler.acquire`; a drain timeout detaches

**Finding(s):** L1, C ranks 2 and 11. **Effort:** 1 day. **Depends on:** none.
**Unblocks:** P2-02, P2-03, P3-07.

**Why (what the user experiences today):** The first turns of a voice session take 3–9 s, or
fail at ~2 s with "The local voice model failed while preparing that response." That happened
in 3 of 15 real turns on 09-22 (A Hop 8). The cause is that the worker prewarm loads and
prefills the 4B GGUF at `.realtimeAgent`, the same class the Apple FM frontend acquires. Equal
priority does not preempt. `acquire` cannot be cancelled. The 2 s drain barrier then turns into
`FrontendError.unavailable`. AGENTS.md already forbids warming up at the frontend's priority
(line ~1292).

**Files you will change:**
- `Formatting/LLM/NotesModelRuntime.swift`: `prewarmWorkClass(voice:)` and its use at `:326`;
- `Core/Compute/ComputeScheduler.swift`: a cancellation-aware `acquire`;
- `Formatting/LLM/LocalVoiceFrontend.swift`: detach on drain timeout;
- `Agent/VoiceConversationCoordinator.swift`: prewarm only on plausible work;
- `Formatting/LLM/NotesModelRuntime.swift`: `conversationSchedulingSelfTest` gains cases;
- `Agent/ConcurrentVoiceSelfTest.swift`: the prewarm-trigger case.

**Read for context (do not change):**
- `Core/Compute/ComputeJob.swift:33-47` (priorities; `preempts` is strict `<`);
- `Activation/ActivationController.swift:59` (a wake-arm prewarm, which may stay; it becomes
  `.background`).

**Current behaviour:**
- `NotesModelRuntime.prewarmIfNeeded` @ `:292-331` ends with
  `try await prepareForConversation(workClass: voice ? .realtimeAgent : .background)` (`:326`).
- `LocalVoiceFrontend` acquires `.realtimeAgent` at `:248` and `:388`.
- `ComputeScheduler.acquire` @ `ComputeScheduler.swift:142-152`:
  ```swift
  let job = ComputeJob(workClass: workClass)
  submit(job)
  if running?.id == job.id { return job.id }
  await withCheckedContinuation { continuation in resumeWaiters[job.id] = continuation }   // no cancellation handler
  return job.id
  ```
- `LocalVoiceFrontend.waitForPriorInference` @ `:312-316` gives a 2 s bounded wait. The caller at
  `:350-356` then returns a stream that throws
  `FrontendError.unavailable("Previous voice inference did not stop.")`.
- `VoiceConversationCoordinator.speechStarted()` @ `:201-207` calls `prewarmWorkerModel()` on
  **every** session's first speech. That is `:222-230`, a once-per-session
  `NotesModelRuntime.shared.prewarm(voice: true)`.

**Target behaviour:**
1. A voice prewarm runs at `.background`. A frontend `acquire(.realtimeAgent)` issued while a
   prewarm holds the lane returns at once, because it preempts at the next checkpoint. The load
   already checkpoints (`load` → `ComputeScheduler.checkpoint`).
2. The coordinator prewarms the worker only when work is plausible: in the `.newWork` branch
   (`Coordinator:~512`, just before `submit(text)`), and when a tool-shape gate routes to work.
   It does not prewarm on `speechStarted`.
3. `acquire` is cancellation-aware. A cancelled waiter is removed from `queued` and resumed, and
   the caller sees `CancellationError`, or a sentinel it checks.
4. On drain-barrier timeout, the new turn **detaches**. It stops waiting, marks the old producer
   as abandoned (its output is ignored), and proceeds on a fresh `LanguageModelSession`. The turn
   does not fail.

**Steps:**
1. `nonisolated static func prewarmWorkClass(voice: Bool) -> WorkClass { .background }`. Use it
   at `:326`. Keep `voice` in the signature for the log line.
2. `ComputeScheduler.acquire`:
   Keep source compatibility: add `func acquireCancellable(_ workClass: WorkClass) async -> UUID?`,
   where nil means the caller was cancelled while waiting. Implement it with
   `withTaskCancellationHandler`:
   - on cancel, hop into the actor (`Task { await self.cancelWaiter(job.id) }`);
   - `cancelWaiter` removes the job from `queued`/`parked`, and resumes and removes its
     continuation;
   - return nil when cancelled.

   Then:
   - make the old `acquire` call the new one, and treat nil as "cancelled";
   - in `NotesModelRuntime.withLane` (`:684`) and in `LocalVoiceFrontend` (`:248`, `:388`),
     check for nil and throw `CancellationError()`. Release nothing, because nothing was
     acquired.
3. Coordinator: delete the `prewarmWorkerModel()` call from `speechStarted()`. Call it at the top
   of the `.newWork` branch and in the tool-shape submit path (`Coordinator:371-378`) instead.
   Add `var prewarmObserverForTesting: (@MainActor () -> Void)?`. When it is set,
   `prewarmWorkerModel` calls it instead of the runtime, still respecting `didPrewarmWorker`.
4. `LocalVoiceFrontend.unsharedStream`: when `waitForPriorInference(drain)` returns false,
   - emit `drain_barrier_detached` timing;
   - set a new `abandonedGeneration` so that the old producer's yields are dropped. The producer
     already checks its epoch; add a check if not;
   - clear `drainBarrier` and `nativeGeneration` for the new turn;
   - continue on a fresh session.

   The old native task is not awaited. Apple FM sessions do not share state, per A §3 #1.
   **Do not** reuse the old session object.

**Do not:**
- change the priority numbers in `ComputeJob.swift`;
- take Apple FM out of the scheduler. That is a Phase 3 decision (C3, measured first);
- remove the load's `checkpoint` calls;
- let a detached producer's text reach TTS;
- add a prewarm on every utterance under another name.

**Red-first self-test:** extend `--selftest-voice-scheduling`
(`NotesModelRuntime.conversationSchedulingSelfTest`, `NotesModelRuntime.swift:725-786`), and
`--selftest-concurrent-voice`.

1. **The prewarm class does not block the frontend.**
   - `let holder = await ComputeScheduler.shared.acquire(NotesModelRuntime.prewarmWorkClass(voice: true))`.
   - Then `let got = await withBoundedWait(.milliseconds(200)) { await ComputeScheduler.shared.acquire(.realtimeAgent) }`.
   - Assert `got != nil`. Release both in `defer`.
   - RED today: the seam returns `.realtimeAgent`, which today's code uses, so it waits.
2. **Cancellable acquire.**
   - Hold the lane with `.realtimeAgent`.
   - Start `let waiter = Task { await ComputeScheduler.shared.acquireCancellable(.background) }`.
   - Sleep 50 ms, then `waiter.cancel()`.
   - Assert that `await withBoundedWait(.milliseconds(100)) { await waiter.value }` returns
     `.some(nil)`, and that `occupancy()` no longer lists `.background`.
   - RED: the seam delegates to the old `acquire`, so it hangs. The bounded wait returns nil.
3. **Drain detaches.**
   - `LocalVoiceFrontend.shared.setGenerationForTesting` gets a producer that ignores
     cancellation for 3 s on its first call and answers "Second." on its second.
   - Start turn 1, then commit turn 2 after 100 ms.
   - Assert turn 2 yields "Second." within 2.5 s, and never throws `FrontendError.unavailable`.
   - Restore the seam in `defer`.
   - RED today: turn 2 throws after 2 s.
4. **In `--selftest-concurrent-voice`:** set `conversation.prewarmObserverForTesting` to a
   counter. Call `agent.userSpeechStarted()` and assert 0 prewarms. Then call
   `speak("Check my calendar.")` (a `.newWork` route in the existing stub) and assert 1 prewarm.
   RED today: the first assertion sees 1.

The final lines are `VOICE_SCHEDULING_OK` / `VOICE_SCHEDULING_FAILED` and `CONCURRENT_VOICE_OK`
/ `CONCURRENT_VOICE_FAILED`, which exist already. Add `SelfTest.diagnostic` lines that name the
failing case.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-voice-scheduling
Scripts/run-selftest.sh --selftest-concurrent-voice
Scripts/run-selftest.sh --selftest-scheduler
Scripts/run-selftest.sh --selftest-residency
Scripts/run-selftest.sh --selftest-voice-conversation
Scripts/run-selftest.sh --selftest-voice-pipeline ~/Library/Caches/NextNotesBuild/agent-overhaul/haiku16k.wav --voice-feed-10ms
```

**Success threshold:**
- Case 1 acquires in ≤ 200 ms.
- Case 2 unblocks in ≤ 100 ms.
- Case 3 answers in ≤ 2.5 s with no `unavailable`.
- Case 4 counts 0 then 1.
- `--selftest-voice-pipeline`'s `ENDPOINT_TO_FIRST_AUDIO` is no worse than the baseline + 10%.

**Risks & rollback:**
- A worker's first job now waits for its own cold load. That load happens while the frontend
  says "I'm on it.", which is acceptable.
- A detached FM request could still use the ANE for a while. Measured impact belongs to P2-01.
- To roll back: revert.

**Done when:**
- [ ] Prewarm runs at `.background`.
- [ ] Prewarm fires only on work.
- [ ] `acquire` is cancellable.
- [ ] Drain detaches.
- [ ] Four cases are green.
- [ ] Committed as `P0-06: …`.

---

### P0-07 — A frontend failure resolves its own epoch; write-time effect gate `mayCommitEffect`

**Finding(s):** C1, plus the write half of C2 (C rank 1). **Effort:** 1 day.
**Depends on:** none. **Unblocks:** P1-05, P1-07, P3-01, P3-02.

**Why (what the user experiences today):** After one failed voice reply, for example the L1
2-second failure or a 25 s deadline, background "I'm on it" work **silently stops**, and the
microphone stays open. `finishFailure` deliberately leaves `inputPending = true`. Workers poll
`waitForInputResolution()` every 20 ms before every round and call. Only a new valid utterance,
or closing the session, releases them (C §3 Q6 #8).

**Files you will change:**
- `Agent/VoiceConversationCoordinator.swift`: `finishFailure`, a new effect hold, and
  `mayCommitEffect`;
- `Agent/RealtimeAgent.swift`: `mayCommitEffect(risk:)`;
- `Agent/RealtimeAgent+ToolLoop.swift`: the `isStillValid` closure at `:999-1002` uses the gate
  for `risk > .read`;
- `Agent/ConcurrentVoiceSelfTest.swift`: the new case.

**Read for context (do not change):**
- `Agent/ActionRuntime.swift:515-519`, where `isStillValid` is checked after approval and before
  `fire`;
- `Agent/AgentModels.swift:10-25` (`AgentRisk`).

**Current behaviour:**
- `VoiceConversationCoordinator.finishFailure` @ `:546-574`:
  ```swift
  lastFailure = failure
  AgentAuditLog.shared.record(kind: .reply, title: "Voice response failed", detail: failure.auditDetail)
  // Keep the effect barrier closed. A subsequent valid turn or closing the
  // voice session is responsible for resolving an unresolved correction.
  return agentFailureReply(failure, turn: turn)
  ```
- `waitForInputResolution` @ `:259-263` polls `inputPending` every 20 ms.
- `resolveInput(epoch:)` @ `:238-242` clears the flag only when the epoch matches.
- `RealtimeAgent.waitForVoiceInput` @ `RealtimeAgent.swift:99-107` delegates to the coordinator
  for workers.
- `ToolLoop:999-1002`:
  ```swift
  isStillValid: {
      await self.waitForVoiceInput()
      return self.isCurrent(owner) && revision == (work?.revision ?? 0)
  }
  ```
- There is no `mayCommitEffect` anywhere (grep confirms).

**Target behaviour:**
1. On a failure other than cancellation, `finishFailure` resolves its own epoch
   (`resolveInput(epoch: inputEpoch)`), so `inputPending` goes false and planning and reads
   resume. It also sets `effectHoldEpoch = inputEpoch`, which records that this input was never
   classified.
2. `mayCommitEffect() async -> Bool` (coordinator) waits while
   `inputPending || effectHoldEpoch != nil`, for as long as the session is active and the task
   is not cancelled. The hold clears when a **later** epoch is classified, meaning any
   successful route resolves (`resolveInput` from a non-failure path with
   `epoch > effectHoldEpoch`), or on `closeSession()` / `discardInput()`. It returns `false` if
   cancelled.
3. `RealtimeAgent.mayCommitEffect(risk: AgentRisk) async -> Bool`:
   - for `risk <= .read`, it returns `true` immediately (the round barrier still applies);
   - for workers, it awaits the coordinator gate;
   - for the shared (typed) agent, it keeps today's `waitForVoiceInput()` and returns `true`.
4. The tool loop's `isStillValid` uses `mayCommitEffect(risk: tool.risk)`, plus the existing
   revision and owner checks. A write therefore waits for a classified epoch, while reads run.

**Steps:**
1. In the coordinator, add `private(set) var effectHoldEpoch: UInt64?`. In `finishFailure`, in
   the non-cancelled branch before `agentFailureReply`:
   `resolveInput(epoch: inputEpoch); effectHoldEpoch = inputEpoch`.
2. Make `resolveInput` a two-way helper. Add
   `private func resolveClassified(epoch:) { resolveInput(epoch: epoch); if let hold = effectHoldEpoch, epoch > hold { effectHoldEpoch = nil } }`.
   Replace every `resolveInput(epoch: inputEpoch)` in the successful route branches
   (`:492-529`) with `resolveClassified`. In `closeSession()` and `discardInput()`, set
   `effectHoldEpoch = nil`.
3. Add
   `func mayCommitEffect() async -> Bool { while (inputPending || effectHoldEpoch != nil) && AgentCaptureController.shared.isSessionActive && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }; return !Task.isCancelled }`.
   Polling matches the existing style; P3-06 replaces it with continuations.
4. In `RealtimeAgent`, add `func mayCommitEffect(risk: AgentRisk) async -> Bool` (Target 3).
5. `ToolLoop` at the `execute` closure: the resolved `tool` (`AgentToolRegistry.shared.tool(named:)`
   at `:962`) is in scope, so capture `let risk = tool.risk` and write:
   ```swift
   isStillValid: {
       guard await self.mayCommitEffect(risk: risk) else { return false }
       return self.isCurrent(owner) && revision == (work?.revision ?? 0)
   }
   ```

**Do not:**
- release the barrier on failure **without** the effect hold. AGENTS.md: "effects wait until the
  latest input is classified";
- move the round-boundary barriers at `ToolLoop:864, 915, 954`. Narrowing those is P3-02;
- clear `effectHoldEpoch` from a failure path;
- use `MainActor.assumeIsolated`.

**Red-first self-test:** extend `--selftest-concurrent-voice` (`Agent/ConcurrentVoiceSelfTest.swift`),
using its existing seams (`streamForTesting`, `workerForTesting`, `responseDeadlineForTesting`).

- Set `conversation.responseDeadlineForTesting = .milliseconds(150)`, and a `streamForTesting`
  that never yields for the utterance "Stall please."
- Start a fake worker through `workerForTesting`:
  - it runs `await RealtimeAgent.shared.waitForVoiceInput()`, which is the read round barrier,
    and records `readResumedAt`;
  - it then runs `await RealtimeAgent.shared.mayCommitEffect(risk: .write)` and records
    `writeAt`.
- Drive `agent.userSpeechStarted()`, `agent.userSpeechEnded()`, then
  `await agent.handle("Stall please.", source: .voice)`, which fails at the deadline.
- Assert that `readResumedAt` is set within **200 ms** of the failure reply. RED today: it never
  resumes until the session closes.
- Assert that `writeAt` is still nil 300 ms later. Then speak a classified utterance ("What is a
  haiku?", which the stub answers), and assert that `writeAt` is set within 200 ms.
- Assert that after `closeSession()` no hold remains.
- The final line is `CONCURRENT_VOICE_OK` / `CONCURRENT_VOICE_FAILED`, as today.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-concurrent-voice
Scripts/run-selftest.sh --selftest-voice-conversation
Scripts/run-selftest.sh --selftest-voice-work-lifecycle
Scripts/run-selftest.sh --selftest-voice-turn-routing
Scripts/run-selftest.sh --selftest-toolloop-production
Scripts/run-selftest.sh --selftest-duplex
```

**Success threshold:** reads resume in ≤ 200 ms after a failure. The write waits until the next
classified turn, then commits in ≤ 200 ms. All regressions are unchanged.

**Risks & rollback:**
- A missed `resolveClassified` site would leave writes held until the session closes. That is
  safe but annoying. The test's third assertion catches the main route.
- To roll back: revert.

**Done when:**
- [ ] The epoch is resolved on failure, with an effect hold.
- [ ] `mayCommitEffect` exists and is used for `risk > .read`.
- [ ] The case is green.
- [ ] Committed as `P0-07: …`.

---

### P0-08 — "Run locally once" never submits a task without a tool

**Finding(s):** T15, C rank 14. **Effort:** 2 h. **Depends on:** none. **Unblocks:** nothing.

**Why (what the user experiences today):** On the missing-ACP card, pressing [Run once] could
answer "I’ll work on that locally, once." followed by "Nothing local can do that." That happens
when a task with `tool == nil` is handed to `LocalAgentBackend`, which refuses any task
without a tool.

**Source has moved since the reports.** `AgentTurnIntent.resolve` (`Agent/AgentTurnIntent.swift:51-66`)
now returns only `.delegate`, `.localModel` or `.toolLoop`. With the local choice built in
`runWithLocalToolsOnce`, an ordinary request resolves to `.toolLoop` and runs through `perform`.
That part is fixed. The broken branch remains reachable for **`.localModel`**: any request that
starts with an on-device phrase such as "ask the agent …" or "ask the app …"
(`explicitlyRequestsOnDeviceModel`). The dead cases `.capabilities`, `.reply`, `.unknown` and
`.delegate` fall into the same branch.

**Files you will change:** `Agent/RealtimeAgent+ToolLoop.swift` (`runWithLocalToolsOnce`) and
`Agent/ACPConfirmation.swift` (the self-test).
**Read for context (do not change):** `Agent/Backend/LocalAgentBackend.swift:19-25` and
`Agent/RealtimeAgent.swift:560-650` (`answerLocally`).

**Current behaviour:** `runWithLocalToolsOnce` @ `ToolLoop:216-246`:
```swift
case .capabilities, .reply, .localModel, .delegate, .unknown:
    if !SelfTest.isRunning {
        AgentTaskManager.shared.submit(objective: text, …, backend: .local, source: source.rawValue)   // tool == nil
    }
    let reply = "I’ll work on that locally, once."
```

**Target behaviour:**
- `.localModel(prompt)` answers through the same on-device answer path `handle` uses for
  `.localModel`. Find it by grepping `case .localModel` in `RealtimeAgent.swift`; it is
  `answerLocally`.
- Every other case runs `perform(.toolLoop(prompt: text))`.
- No path submits a `tool == nil` task to the local backend.

**Steps:**
1. Add a pure router:
   ```swift
   enum LocalOnceRoute: Equatable { case perform(AgentTurnIntent), answerLocally(String) }
   static func localOnceRoute(for intent: AgentTurnIntent, text: String) -> LocalOnceRoute
   ```
   It maps `.calendar`, `.mail`, `.files`, `.drive`, `.computer` and `.toolLoop` to
   `.perform(intent)`, `.localModel(let p)` to `.answerLocally(p)`, and everything else to
   `.perform(.toolLoop(prompt: text))`. `AgentTurnIntent` must be `Equatable`; add the
   conformance if it is missing.
2. Rewrite `runWithLocalToolsOnce` to switch on that route. Keep recording the session and
   showing the island reply as today. `delegated` is `false` for both routes.
3. Delete the `AgentTaskManager.shared.submit(... tool: nil ...)` call from this function.

**Do not:** change `LocalAgentBackend`'s refusal (it is correct for tool-less tasks), or change
`ACPConfirmation.entryAction`.

**Red-first self-test:** extend `--selftest-acp-confirm` (`ACPConfirmation.runSelfTest` @
`Agent/ACPConfirmation.swift:145`, which is synchronous).

- Add the pure `localOnceRoute` seam, first returning a `.submitWithoutTool` case to mirror
  today's behaviour for the five cases. Then assert:
  - `localOnceRoute(for: .localModel(prompt: "hi"), text: "ask the agent hi") == .answerLocally("hi")`;
  - for `.unknown`, `.capabilities`, `.reply` and `.delegate`, the result is
    `.perform(.toolLoop(prompt:))`;
  - no input produces `.submitWithoutTool`.
- RED on the seam.
- The final line is the existing ACP confirm marker; check the current text in
  `ACPConfirmation.runSelfTest` and keep it.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-acp-confirm
Scripts/run-selftest.sh --selftest-acp
Scripts/run-selftest.sh --selftest-realtime
Scripts/run-selftest.sh --selftest-tasks
```

**Success threshold:** the new assertions pass. The `.submitWithoutTool` case is deleted from
the enum after green. The regressions are unchanged.

**Risks & rollback:** Minimal. Revert to roll back.

**Done when:**
- [ ] The router is added and used.
- [ ] The tool-less submit is removed.
- [ ] The test is green.
- [ ] Committed as `P0-08: …`.

---

### P0-09 — The 280-character speech cap applies per clause; speech silencers match ids, not words, and never stop a playing clause on length

**Finding(s):** L6 (part); H2 V3, V4, V7 (H-audit 2026-09-23). **Effort:** 5 h (was 3 h). **Depends on:** none.
**Unblocks:** P2-06, P1-10b (its "speak the answer, not the fixed line" rule needs per-clause speakability).

**Why (what the user experiences today):**
- Long spoken answers go silent partway. Each streamed delta re-runs `AgentSpeechPolicy.spokenForm` over the
  **whole** buffer. Once the buffer passes 280 characters, `isShortAnswer` fails and `spokenForm` returns "".
  Nothing after that is enqueued (A Hop 10). A non-streamed reply over 280 characters (`RealtimeAudioSession.speak`,
  which appends and finalizes the whole text) is not spoken at all.
- **(H-audit 2026-09-23, H2 V4.)** The streaming path also *stops the clause already playing* at 400 characters or
  more than 3 lines: `StreamingSpeechBuffer.append` checks `isUnsafeForStreaming` against the cumulative buffer before
  every flush and calls `synthesizer.stop()`. The voice answer cap is 256 tokens (about 1,000 characters), so a
  `deep` answer reaches 400. **Without this amendment P0-09's own red test (a 600-character reply whose last sentence
  must be spoken) cannot turn green:** per-clause length in `flush` never runs once `append` has cancelled the
  buffer at character 401.
- **(H-audit 2026-09-23, H2 V3.)** The tool-name silencer matches ordinary sentence ends. `containsToolName` does a
  plain `contains` against `toolMarks`, which include `"meeting."`, `"browser."`, `"computer."`, `"workspace."` and
  `"mcp."`. "You're free until your 3 PM meeting.", "Open it in your browser." and "It's on your computer." are
  therefore "tool names": a one-shot reply is silent, and mid-stream the playing clause is cut. Calendar answers are
  the most exposed, because they end in "meeting.".

**Files you will change:**
- `Agent/Speech/AgentSpeechPolicy.swift`: new `isSpeakableReply`, `speakableClauses`; `isUnsafeForStreaming`
  narrowed; `containsToolName` id-shaped; `runSelfTest` cases;
- `Agent/Speech/StreamingSpeechBuffer.swift`: `flush` uses safety on the whole buffer and length per clause;
  `append`/`finalize` stop only on content silencers;
- `Agent/VoiceDeliverySelfTest.swift`: the new streaming cases.

**Read for context (do not change):** `Agent/Speech/AgentSpeechSynthesizer.swift`; `RecordingSpeechBacking`
(`stopCount` @ `AgentSpeechSynthesizer.swift:899`, used by `AgentCaptureController.overlappingBackchannelSelfTestFailures`).

**Current behaviour:**
- `AgentSpeechPolicy.shortLimit = 280` and `spokenCap = 400` @ `AgentSpeechPolicy.swift:16-17`.
- `spokenForm` @ `:20-33`: URL, tool name or code → ""; permission or done ≤ 400; file listing or long listing
  (≥ 4 lines) → ""; `isShortAnswer` (≤ 280 characters and ≤ 3 lines) → text; otherwise "".
- `isUnsafeForStreaming` @ `:174-184`:
  ```swift
  return containsURL(trimmed) || containsToolName(trimmed) || containsCode(trimmed)
      || isFileListing(trimmed) || isLongListing(trimmed)
      || trimmed.count > spokenCap
      || lineCount(trimmed) > 3
  ```
- `containsToolName` @ `:292-295` is `toolMarks.contains { lowered.contains($0) }`; `toolMarks` @ `:526-531`
  includes `"filesystem."`, `"computer."`, `"browser."`, `"meeting."`, `"workspace."`, `"mcp."`, plus exact ids
  (`"search_email"`, `"get_agenda"`, `"find_drive_files"`, `"inspect_ui"`, `"active_app"`, `"shell.run"`, …).
- `StreamingSpeechBuffer.append` @ `StreamingSpeechBuffer.swift:38-52` calls `synthesizer.stop()` when
  `isUnsafeForStreaming(next)`; `finalize` @ `:56-63` does the same; `flush` @ `:79-91` calls `spokenForm(buffer)` and
  returns early when it is empty.

**Target behaviour:**
- **Content silencers stay whole-reply and may stop audio.** A URL, a tool **id**, code or a file listing anywhere in
  the buffer silences the reply and stops a playing clause, exactly as today.
- **Length never stops audio.** `isUnsafeForStreaming` no longer tests `count > spokenCap` or `lineCount > 3`.
- **A long listing (≥ 4 lines) is a whole-reply "do not start" decision**, taken in `flush`: no new clause is
  enqueued, but a clause already playing is **not** stopped.
- **Length is judged per clause.** Each clause from `splitIntoClauses` is spoken if it is at most 280 characters. A
  longer single clause is split at the last comma or space before 280 characters and spoken in parts.
- A 600-character, 5-sentence, single-paragraph reply is spoken in full: every clause is enqueued, including the
  last, and `synthesizer.stop()` is never called.
- **A tool id is id-shaped.** `meeting.search`, `computer.click` and `search_email` still silence a reply;
  "…your 3 PM meeting.", "…in your browser." and "…on your computer." are spoken.

**Steps:**
1. In `AgentSpeechPolicy`:
   - `static func isSpeakableReply(_ text: String) -> Bool` returns true when none of the whole-reply silencers apply
     (URL, tool id, code, file listing, long listing).
   - `static func speakableClauses(_ text: String) -> [String]` is `splitIntoClauses(text)`, with any clause over
     `shortLimit` split with a new private helper `splitLongClause(_:limit:)` (last comma, else last space, before the limit).
   - Keep `spokenForm` as it is for its other callers: the tool-result forms (`toolResultSummary` @ `:46-96`), and the `spokenFallback`
     paths.
2. In `StreamingSpeechBuffer.flush`: `guard AgentSpeechPolicy.isSpeakableReply(buffer) else { return }`, then
   `let all = AgentSpeechPolicy.speakableClauses(buffer)`. The rest is unchanged (`completePrefix` and
   `flushedCount`).
3. Make `AgentSpeechPolicy.spokenClauses` (`:37-41`) use the same two functions, so the non-streamed path agrees.
   Check its callers with `grep -rn "spokenClauses" Sources/NextNotes`; `RealtimeAgent.handle` uses it to decide
   `speakable`.
4. **(H-audit 2026-09-23, V4.)** `isUnsafeForStreaming` keeps only the content silencers:
   ```swift
   return containsURL(trimmed) || containsToolName(trimmed) || containsCode(trimmed) || isFileListing(trimmed)
   ```
   Remove `isLongListing`, `trimmed.count > spokenCap` and `lineCount(trimmed) > 3` from it. The long-listing decision
   now lives only in `isSpeakableReply` (step 1), which `flush` checks before enqueuing, so a listing is still never
   read out, but nothing already playing is cut for being long. `spokenCap` stays for `spokenForm`'s permission and
   done messages.
5. **(H-audit 2026-09-23, V3.)** Make `containsToolName` id-shaped:
   ```swift
   private static let namespacedID = try! NSRegularExpression(
       pattern: #"\b(filesystem|computer|browser|meeting|workspace|mcp|memory|shell)\.[a-z_]"#,
       options: [.caseInsensitive])
   private static let exactIDs: Set<String> = ["search_email", "get_agenda", "find_drive_files",
                                               "inspect_ui", "active_app"]
   static func containsToolName(_ text: String) -> Bool {
       let range = NSRange(text.startIndex..., in: text)
       if namespacedID.firstMatch(in: text, range: range) != nil { return true }
       let words = text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "_") }
       return words.contains { exactIDs.contains(String($0)) }
   }
   ```
   A namespace followed by a period and an identifier character is an id; the same word ending a sentence is not.
   Delete `toolMarks` once nothing reads it. After P1-03 lands, derive `exactIDs` and the namespaces from
   `AgentCapabilityManifest`'s ids (P1-03 owns that change; leave a one-line comment pointing at it).

**Do not:**
- loosen the URL, tool-id, code or listing silencers. They exist so ids and paths are never spoken;
- stop a playing clause for any reason other than a content silencer (URL, tool id, code, file listing). Length and
  line count are "do not start", never "stop";
- speak `<|…|>` markers (see P0-04);
- change clause boundaries (comma-first chunking is P2-06);
- widen the id regex to plain words (`\bmeeting\b`); that is the bug.

**Red-first self-test:**
- **Extend `--selftest-voice-delivery`** (`Agent/VoiceDeliverySelfTest.swift`, harness-only, using
  `RecordingSpeechBacking`):
  - **a.** Build `StreamingSpeechBuffer(synthesizer: .shared)` with the recording backing. Call `begin()`. Append a
    fixed 600-character prose reply of five sentences, with no URLs or lists, in 20-character chunks. The last
    sentence is "That is the fifth and final sentence." Then call `finalize()`. Assert that the recorder's enqueued
    clauses include that exact last sentence, that the total enqueued text length is ≥ 580, **and that
    `recorder.stopCount == 0`** (H-audit 2026-09-23: this is the assertion that fails on today's `append` at
    character 401).
  - **b.** A reply with a URL is still fully silent, and a URL arriving after one spoken clause makes
    `stopCount == 1`.
  - **c. (H-audit 2026-09-23, V3.)** A 150-character reply ending "…until your 3 PM meeting." streamed in 20-character
    chunks is fully enqueued with `stopCount == 0`.
  - **d. (H-audit 2026-09-23, V4.)** A five-line numbered listing streamed after a first spoken sentence: no listing
    line is enqueued, and `stopCount == 0` (the first sentence finishes).
  - RED today: a stops before 280 characters and `append` calls `stop()` at 401; c is cut at "meeting."; d calls
    `stop()` at the fourth line.
  - The final line is the existing `VOICE_DELIVERY_OK` / `VOICE_DELIVERY_FAILED`.
- **Extend `--selftest-tts`** (`AgentSpeechPolicy.runSelfTest` @ `:335`) with a table (H-audit 2026-09-23, V3):
  `spokenForm` is non-empty for "You're free until your 3 PM meeting.", "Open it in your browser.", "It's on your
  computer." and "The workspace is ready."; it is empty for "Use meeting.search next.", "I called computer.click.",
  "search_email returned 5 results." and "Try mcp.github_list." RED today: the first four are empty.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-voice-delivery
Scripts/run-selftest.sh --selftest-tts
Scripts/run-selftest.sh --selftest-tts-stream
Scripts/run-selftest.sh --selftest-voice-conversation
Scripts/run-selftest.sh --selftest-playback-ledger
Scripts/run-selftest.sh --selftest-voice-turns
```

**Success threshold:**
- Case a: the last clause is spoken, at least 580 of the 600 characters are enqueued, and `stopCount == 0`.
- Cases b–d as stated; the `--selftest-tts` table 8/8.
- The existing TTS policy cases are unchanged, and `--selftest-voice-conversation`, `--selftest-playback-ledger` and
  `--selftest-voice-turns` end as in the baseline.

**Risks & rollback:**
- Longer speech means a longer talk time. Barge-in still cuts it.
- A tool id written without a namespace and not in `exactIDs` (say a new `read_email`) would now be spoken. P1-03
  closes that by deriving the set from the manifest; until then, add new exact ids here when a tool is added
  (`grep -n "exactIDs" Sources/NextNotes/Agent/Speech/AgentSpeechPolicy.swift`).
- Rollback: revert. Steps 4 and 5 are independent and can be reverted alone.

**Done when:**
- [ ] Per-clause length is in place, and length never stops audio.
- [ ] Whole-reply content safety is kept; the tool silencer is id-shaped.
- [ ] Cases a–d and the `--selftest-tts` table are green (red first).
- [ ] Committed as `P0-09: …`.

---

### P0-10 — `tick` runs immediately from `noteModelEOU`

**Finding(s):** L3 (part). **Effort:** 3 h. **Depends on:** none. **Unblocks:** P2-03, P2-04.

**Why (what the user experiences today):** After Parakeet confirms the end of an utterance,
nothing commits the turn until the next 100 ms VAD tick. `VOICE_MODEL_EOU_TO_ENDPOINT` was
measured at 9–106 ms (66 ms on the 09-23 run; `roadmap/done/agent-analysis-2026-09-23/pipeline-run2.txt:57`). That is pure
polling cost, stretched further by any main-actor stall.

**Files you will change:** `Activation/AgentCaptureController.swift`.
**Read for context (do not change):** the `LocalVoiceTurnDetector` EOU debounce (320 ms), which
Phase 2 owns.

**Current behaviour:**
- `startVAD` @ `AgentCaptureController.swift:862-870` loops `tick(force: false)` then sleeps
  `Limits.tick` (100 ms, `:108`).
- `noteModelEOU` @ `:994-1022` records `modelEOUAt = Date()` and prepares the response, but
  never ticks.
- `tick(force:)` @ `:1169-…` commits when `modelEOUAt != nil` (among other conditions) and
  `inputLevel <= Limits.silenceLevel || force`.
- `:1294-1295` prints `VOICE_MODEL_EOU_TO_ENDPOINT=<s>` under the self-test.

**Target behaviour:** A confirmed model EOU triggers an immediate evaluation. All of `tick`'s
gates stay in force; use `force: false`, so the silence gate still applies. The commit happens
in the same main-actor turn when the gates pass. Two concurrent `tick` evaluations can never
commit the same turn twice.

**Steps:**
1. Add `private var tickInFlight = false`. Wrap `tick`'s body: `guard !tickInFlight else { return false }; tickInFlight = true; defer { tickInFlight = false }`.
   This is needed because `tick` awaits (`clearStagedTurn`, `emitTurn`), and the loop and the
   EOU could otherwise interleave.
2. At the end of `noteModelEOU` (only in the words branch, after `prepareResponseForRecognizedSpeech`):
   `lastEndpointTrigger = .eou; Task { @MainActor [weak self] in _ = await self?.tick(force: false) }`.
3. Record what triggered the commit: `enum EndpointTrigger { case eou, loop }`. The loop sets
   `.loop` before its call, unless `.eou` is pending. At the `:1294` diagnostic, also print
   `VOICE_ENDPOINT_TRIGGER=<eou|loop>`.

**Do not:**
- pass `force: true` from the EOU path. That bypasses the silence gate that protects against
  echo;
- lower `Limits.tick` or the EOU debounce (Phase 2);
- touch the echo, barge-in or VAD thresholds.

**Red-first self-test:** extend `--selftest-voice-pipeline <wav>`
(`AgentCaptureController.runVoicePipelineSelfTest`).

- After a run where a model EOU occurred, add a failure `"model EOU waited for the VAD tick"`
  when the endpoint trigger is not `.eou`.
- It is deterministic RED today: every commit is a loop tick. The trigger diagnostic prints
  `loop` with the seam added.
- Use the WAV from `00-README.md` §7:
  `~/Library/Caches/NextNotesBuild/agent-overhaul/haiku16k.wav` with `--voice-feed-10ms`.
- The final line is `VOICE_PIPELINE_OK` or `VOICE_PIPELINE_WRONG: …` then `…FAILED`, as today.

**Verify:**
```bash
make build && make install OPEN=0
for i in 1 2 3; do Scripts/run-selftest.sh --selftest-voice-pipeline ~/Library/Caches/NextNotesBuild/agent-overhaul/haiku16k.wav --voice-feed-10ms | grep -E "VOICE_MODEL_EOU_TO_ENDPOINT|VOICE_ENDPOINT_TRIGGER|VOICE_PIPELINE_(OK|FAILED)"; done
Scripts/run-selftest.sh --selftest-voice-barge ~/Library/Caches/NextNotesBuild/agent-overhaul/haiku16k.wav
Scripts/run-selftest.sh --selftest-voice-turns
Scripts/run-selftest.sh --selftest-duplex
```

**Success threshold:**
- `VOICE_ENDPOINT_TRIGGER=eou` on all 3 runs.
- The median `VOICE_MODEL_EOU_TO_ENDPOINT` is ≤ 0.010 s (baseline 0.066 s).
- No regression in `--selftest-voice-turns` or `--selftest-duplex`.

**Risks & rollback:**
- A double commit, which the `tickInFlight` guard prevents.
- A commit during loud residual echo is prevented, because `force: false` is kept.
- To roll back: revert.

**Done when:**
- [ ] The immediate tick and the trigger diagnostic are in place.
- [ ] 3/3 runs trigger on `eou`.
- [ ] The median is ≤ 10 ms.
- [ ] Committed as `P0-10: …`.

---

### P0-11 — Self-tests never write the user's real stores: seams, an isolation self-test, and a one-off cleanup script

**Finding(s):** Decision document §6 (housekeeping), D §3. **Effort:** 1 day.
**Depends on:** none. **Unblocks:** P1-01 (its eval must be provably write-free), P0-14b, P3-01, P4-04, P4-07.

**Why (what the user experiences today):** Self-test fixtures sit in the owner's real history,
and they feed routine suggestions, memory review and task status:

- `agent-tasks.json` holds **9** "Self-test observe the front app" tasks, dated
  2026-09-13T03:40Z to 2026-09-14T00:01Z. This was verified today.
- `agent-audit.jsonl` holds **17** fixture rows, all from 2026-09-13 (`mcp.fixture.echo`,
  "Send the deck to Sam").

**What changed since.** Guards now exist, verified in the current tree:

- `AgentTaskManager.persist` @ `Agent/Tasks/AgentTaskManager.swift:291-294` returns under
  `SelfTest.isRunning`;
- `AgentAuditLog.record` @ `Agent/Activity/AgentActivityStore.swift:178` skips the disk under
  the harness;
- `AgentSession.shared` has `fileURL: nil` under the harness (`Agent/RealtimeAgent.swift:818`);
- `NextMemory.shared` uses a temp directory (`Memory/NextMemory.swift:254`);
- `MetricsStore.shared` uses a temp directory.

So the historical rows are from before these guards (the `persist` guard is in git history from
2026-09-16). What is still unguarded:

- **`UserDefaults.standard` writes.** `InstalledModelLibrary.activeAgentModelID.didSet` writes
  `modelLibrary.activeAgentModelID` and `modelLibrary.lastUsedAt`, and `ModelRoleStore.setChoice`
  writes `modelRoles.*`. Both are reachable from any self-test that drives `.shared`.
- **Any store that nobody has checked.**

The 42 `memory.remember`/`memory.forget` audit rows (09-23 00:54Z–06:36Z) are **not** self-test
rows. They match the production `MemoryReviewer`, which writes through `AgentToolExecutor` →
audit (`Memory/MemoryReviewer.swift:396-413`). Leave them.

**Files you will change:**
- new `Support/SelfTestStoreGuard.swift`: a snapshot and compare of user files and defaults;
- new `Support/StoreIsolationSelfTest.swift`: the `--selftest-store-isolation` body;
- `Support/ModelLibrary/InstalledModelLibrary.swift` and `Support/ModelRoles/ModelRoleStore.swift`:
  under the harness, `.shared` uses a volatile `UserDefaults(suiteName:)` (building on P0-14's
  `defaults:` injection);
- new `Scripts/cleanup-selftest-rows.py`: the one-off cleanup;
- `NextNotesApp.swift`, `AGENTS.md`, `Scripts/acceptance.sh` (INTEGRATION).

**Read for context (do not change):** `Agent/Tasks/AgentTaskStore.swift` and
`Memory/NextMemory.swift:245-262`.

**Current behaviour:** as described in *Why*. The user store files in
`~/Library/Application Support/Next Notes/` include `agent-tasks.json`, `agent-audit.jsonl`,
`agent-conversation.json`, `next-memory.json`, `agent-memory-review.json`, `runs.jsonl`,
`metrics.jsonl`, `action-receipts.json`, `permission-grants.json`, `persona.md`,
`agent-identity.json`, `portrait-insights.json` and `Models/library.json`.

**Target behaviour:**
1. `--selftest-store-isolation`:
   - snapshots `(size, mtime, SHA-256)` of each file above;
   - snapshots every `UserDefaults.standard` key with prefix `modelRoles.`, `modelLibrary.` or
     `agent`;
   - runs, in process, `ModelRoleSelfTest.run()`, `RealtimeAgentToolLoopSelfTest.run()`, the
     memory tools (`memory.remember` then `memory.forget` through `AgentToolExecutor.run` with
     `autoApproveReads: true`), and one typed `RealtimeAgent.shared.handle("hello", source: .text)`
     with a stub provider;
   - re-snapshots, and fails on any difference.
2. Under `SelfTest.isRunning`, `InstalledModelLibrary.shared` and `ModelRoleStore.shared` read
   and write a per-process `UserDefaults(suiteName: "NextNotesSelfTest-<pid>")`. **Exception:**
   when `SelfTest.allowsSavedModelSelection` (P0-14b) is on, they **read** the owner's values
   (copied into the suite at start) and still write only the suite.
3. `Scripts/cleanup-selftest-rows.py`:
   - it is a dry run by default, and `--apply` writes;
   - it writes a timestamped backup of each file it changes, next to the original
     (`*.bak-YYYYMMDDHHMMSS`);
   - it removes tasks whose `objective` starts with `"Self-test "`, and audit rows from
     2026-09-13 whose JSON contains `mcp.fixture` or `Send the deck to Sam`;
   - it prints the counts. **It never touches memory rows.**

**Steps:**
1. `SelfTestStoreGuard`:
   ```swift
   struct StoreSnapshot: Equatable { var files: [String: String]; var defaults: [String: String] }  // path → "size|mtime|sha"
   static func take() -> StoreSnapshot
   static func diff(_ a: StoreSnapshot, _ b: StoreSnapshot) -> [String]
   ```
   Use `AppIdentity.applicationSupportDirectory`. Read `UserDefaults.standard.dictionaryRepresentation()`
   and filter by the prefixes. Stringify values with `String(describing:)`.
2. Build the volatile suites (Target 2). Remove the suite with `removePersistentDomain` in the
   self-test harness exit path, where `NSApp.terminate` is called.
3. Write the cleanup script with Python 3 stdlib only.
4. Register the flag. Add it to AGENTS.md's list and to `Scripts/acceptance.sh`
   `INTEGRATION_ENTRIES` as `"selftest-store-isolation|300"`.

**Do not:**
- run the cleanup with `--apply` without the owner's explicit yes in chat. Show them the
  dry-run counts first. That counts as modifying the owner's data;
- delete memory rows or real conversation history;
- make `SelfTestStoreGuard` itself write anything.

**Red-first self-test:** `--selftest-store-isolation`. Its current state is probably **green**,
because the file guards exist. The UserDefaults leg is RED only if some flow writes the owner's
defaults. Prove the test can fail:

1. Temporarily add, in the test itself, a flow that calls
   `ModelRoleStore.shared.setChoice(.appleFoundation, for: .computerUse)`. That is a real write
   to the owner's defaults in today's code.
2. Run the test, and confirm `STORE_ISOLATION_FAILED: modelRoles.computerUse changed`.
3. Keep that flow in the test. After Target 2, the same call goes to the volatile suite, and the
   test goes green. Restore the value in `defer` either way. **Before running the RED
   confirmation, write down the owner's current `modelRoles.computerUse` value
   (`defaults read ai.pivotstudio.nextnotes modelRoles.computerUse`), and verify it afterwards.**

The final lines are `STORE_ISOLATION_OK: <n> files and <m> defaults unchanged` and
`STORE_ISOLATION_FAILED: <what changed>`.

**Verify:**
```bash
defaults read ai.pivotstudio.nextnotes | grep -E "modelRoles|modelLibrary" > /tmp/nn-defaults-before.txt
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-store-isolation
defaults read ai.pivotstudio.nextnotes | grep -E "modelRoles|modelLibrary" | diff /tmp/nn-defaults-before.txt - && echo DEFAULTS_UNCHANGED
python3 Scripts/cleanup-selftest-rows.py            # dry run: expect 9 tasks, 17 audit rows
Scripts/run-selftest.sh --selftest-model-roles
Scripts/run-selftest.sh --selftest-tasks
Scripts/run-selftest.sh --selftest-memory
```

**Success threshold:**
- `STORE_ISOLATION_OK`, and `DEFAULTS_UNCHANGED`.
- The dry run reports 9 tasks and 17 audit rows. It reports 0 memory rows touched.

**Risks & rollback:**
- Under the harness, tests that relied on reading the owner's roles now see empty suites. Fix
  any such test to set up its own state.
- To roll back: revert. The script only acts with `--apply` and makes backups.

**Done when:**
- [ ] The guard and the self-test exist.
- [ ] The volatile suites are in place.
- [ ] The script exists (dry run shown to the owner; `--apply` only after a yes).
- [ ] The test is green.
- [ ] Committed as `P0-11: …`.

---

### P0-15 — The input placeholder uses the Agent's name

**Finding(s):** F secondary UI #2. **Effort:** 1 h. **Depends on:** none. **Unblocks:** nothing.

**Why (what the user experiences today):** The owner named the Agent "Will". The input still
says "Ask Next…". That is hard-coded, and it contradicts AGENTS.md's rule that the user names
the Agent. Onboarding already does it right: `"Ask \(assistantName)…"` at
`UI/Onboarding/OnboardingOutcome.swift:116,129`.

**Files you will change:**
- `UI/Agent/AgentView.swift` (`composer`, at `:493`);
- `UI/UIStringsLint.swift`: ban the literal.

**Read for context (do not change):** `Agent/Identity/AgentIdentityStore.swift`. It has
`static let defaultName = "Next"` and `var name: String`, which trims and falls back to the
default.

**Current behaviour:** `AgentView.swift:493`:
`TextField("Ask Next…", text: $draft, axis: .vertical)`.

**Target behaviour:** The placeholder reads `"Ask \(AgentIdentityStore.shared.name)…"`: "Ask
Will…" on this Mac, and "Ask Next…" on a fresh install. It updates live when the name is
changed in About, because the store is `@Observable`.

**Steps:**
1. In `AgentView`, add `@State private var identity = AgentIdentityStore.shared`. This follows
   the pattern used for other shared stores in the Settings views.
2. Replace the literal with `TextField("Ask \(identity.name)…", text: $draft, axis: .vertical)`.
3. In `UIStringsLint`, add a rule that fails on any `"Ask Next…"` or `"Ask Next..."` literal under
   `UI/`. Report the file and line like the existing rules do.
4. Optional, cosmetic: the large empty area above short conversations comes from
   `.defaultScrollAnchor(.bottom)` (`AgentView.swift:180-235`). Leave it unless it is trivial to
   pin the "Conversation" label at the top when content is shorter than the viewport. If you do
   it, use DS tokens only.

**Do not:**
- put the name into any prompt. This is UI only;
- add a literal font or colour.

**Red-first self-test:** `--selftest-ui-strings` with the new rule. It is RED today because
`AgentView.swift:493` contains `"Ask Next…"`. The final line is the existing lint marker.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-ui-strings
Scripts/run-selftest.sh --selftest-agent-panes
Scripts/run-selftest.sh --selftest-avatar
```

**Success threshold:** the lint is green with the rule in place. Manual smoke (owner): the field
reads "Ask Will…".

**Risks & rollback:** None. Revert to roll back.

**Done when:**
- [ ] The placeholder uses the name.
- [ ] The lint rule is added.
- [ ] Green.
- [ ] Committed as `P0-15: …`.

---

### P0-17 — OpenRouter: cap reasoning, read `finish_reason`, and never end a cut-off reply as "incomplete response"

**(H-audit 2026-09-24) Pairing note:** P0-05 landed on its own (commit `6ad6ade`, 2026-09-24), not in the same
session as this task. Until P0-17 lands, a reasoning OpenRouter model on the Agent role still loses turns: the
larger visible budget (`AgentAnswerBudget`, 500 at `deep`) is spent thinking, and `finish_reason: "length"` is still
ignored. **Do P0-17 next among the Phase 0 tasks that touch the typed path**, and until then keep the owner's G advice
(typed on Apple FM or a non-reasoning OpenRouter model, P0-01 step 1b). Use `AgentAnswerBudget.tokens(…)` as the
"caller's visible budget" in Target 1.

**Finding(s):** G N1 (`roadmap/done/agent-analysis-2026-09-23/G-model-comparison.md` §2.1, §4, §6), with Q2/B D6 (P0-05). **Effort:** 1 day. **Depends on:** none. **Land it together with P0-05**: the two defects broke 4 of 6 OpenRouter turns together (G §2.1), and neither fix alone repairs them. **Unblocks:** P1-01 cloud runs (`--allow-cloud`), P1-05 (the OpenAI `tools` request reuses this request builder), P4-09, P5-01.

**Why (what the user experiences today):** From 21:52 to 22:10 local on 2026-09-23 the Agent role was
OpenRouter `inclusionai/ling-3.0-flash-sante:free`, a reasoning model. Its first byte arrived in
0.61–1.09 s (M, G §2.1), so it was the fastest of the three models tried. But the app sent
`max_tokens: 112`, no reasoning control, and ignored `delta.reasoning` and `finish_reason`. The one
stream still on disk (turn O5, "list all your tools") shows **prompt 1,726 tokens (512 cached),
completion 112, reasoning 105, `finish_reason: "length"`** (M). The user saw "I have tools for
these: – **Calendar** — agenda, events" and nothing more (O5), a sentence cut mid-list (O2), and
"The model returned an incomplete response." (O3). The app lost those turns, not the model.

**Files you will change:**
- `Formatting/LLM/OpenRouterLLMProvider.swift`:
  - `OpenRouterError` (`:6-60`): add `cutOff(visibleText: Bool)`;
  - `OpenRouterLLMProvider.init` (`:396-402`): take a reasoning policy;
  - `complete` (`:418-430`);
  - `streamConversation` (`:440-475`);
  - `parseStreamLine` (`:477-486`);
  - `makeRequest(messages:maxTokens:stream:)` (`:495-512`);
  - `ChatRequest` (`:523-529`), `CompletionResponse` (`:530-535`), `StreamEvent` (`:536-541`);
  - `chatBody` (vision, `:564-583`);
  - `OpenRouterContractSelfTest.run` (`:684-740`).
- new `Formatting/LLM/OpenRouterReasoning.swift`: `OpenRouterReasoningPolicy`, `OpenRouterUsage`,
  `OpenRouterStreamEvent`, `OpenRouterStreamSummary`.
- `Support/Settings.swift`: `openRouterModelReasons: [String: Bool]` (model id → reasons), stored as
  one dictionary key.
- `UI/Settings/OpenRouterModelSelection.swift`: record the flag where a model is picked (`:52-54`),
  and show one caption when the chosen model reasons.
- `Formatting/LLM/LLMProvider.swift`: `LLMProviders.make` (`:227-245`) passes the policy.
- `Agent/RealtimeAgent+ToolLoop.swift`: `QuickTurnResult` (`:10-13`), the first-pass catch in the
  private `runModelTurn` (`:408-443`) and its result switch (`:449-486`), and the planner round's
  stream and catch (`:882-900`, reported as "The tool planner failed: " at `:927-929`).
- `Agent/RealtimeAgentToolLoopSelfTest.swift`: two cases.

**Read for context (do not change):**
- `OpenRouterModel.supportsReasoning` (`OpenRouterLLMProvider.swift:227`) and `tags` (`:229-236`),
  which already label a model "Reasoning" in the picker;
- `OpenRouterCatalog` (`:270-296`). It is in-memory and loads only when Settings asks, so a turn
  cannot rely on it;
- `ModelRoleStore.provider(for:)` `.cloud` branch (`Support/ModelRoles/ModelRoleStore.swift:549-563`).

**Current behaviour** (verified 2026-09-23):
```swift
// OpenRouterLLMProvider.makeRequest(messages:maxTokens:stream:) — :506-511
request.httpBody = try JSONEncoder().encode(ChatRequest(
    model: modelID, messages: messages, max_tokens: maxTokens, stream: stream))
// parseStreamLine — :485
return event.choices?.first?.delta.content          // reasoning and finish_reason dropped
// streamConversation — :467
guard emitted else { throw OpenRouterError.invalidResponse }
```
- `StreamEvent.Choice.Delta` decodes only `content`. `finish_reason` and `usage` are not decoded.
- The typed first pass asks for 112 tokens (`ToolLoop:414,418`; P0-05 replaces that with
  `AgentAnswerBudget`, which gives `deep` 500 visible tokens). A reasoning model spends them thinking. If no `<answer/>` or `<use_tools/>` header arrives, the
  envelope is `.pending`, and the turn ends at `ToolLoop:482-484`: "The model returned an incomplete
  response."

**Target behaviour:**
1. For a model that reasons (or whose status is unknown), every request carries
   `"reasoning": {"effort": "low", "exclude": true}`, and `max_tokens` = the caller's visible budget
   + a reasoning allowance of 1,024 (estimate: ling-3.0 spent 105 tokens on a short prompt; planner
   prompts are longer). For a model known not to reason, the body is unchanged. The visible budget is
   whatever the caller passed, which after P0-05 is `AgentAnswerBudget.tokens(…)`; the total
   `visible + allowance` is still clamped to `contextTokens − promptTokens − AgentAnswerBudget.safetyTokens`
   (H-audit 2026-09-23: the two budgets are added, never allowed to overrun the window).
2. The stream decoder reads `delta.content`, `delta.reasoning` (counted, never yielded, never
   logged), `choices[0].finish_reason` and the final `usage` object (`prompt_tokens`,
   `prompt_tokens_details.cached_tokens`, `completion_tokens`,
   `completion_tokens_details.reasoning_tokens`).
3. When `finish_reason == "length"` and **no visible text** was produced, the provider retries
   once with the allowance doubled (capped at `min(4_096, contextTokens / 4)`). If it is still cut
   off, it throws `OpenRouterError.cutOff(visibleText: false)`.
4. When `finish_reason == "length"` **after** visible text, the text is yielded as usual, then
   `cutOff(visibleText: true)` is thrown.
5. The typed turn never shows "The model returned an incomplete response." for this cause:
   - a cut-off with no text reads: "The model spent its whole answer thinking and wrote nothing.
     Try again, or pick a model without the Reasoning label in Settings ▸ Agent.";
   - a cut-off after an answer keeps the answer and ends with "(The answer was cut off.)". Voice
     adds nothing.
6. The picker keeps the existing "Reasoning" tag. When the chosen Agent model reasons, a caption
   under it reads: "This model thinks before it answers, so its first words come later."

**Steps:**
1. `OpenRouterReasoning.swift`:
   ```swift
   enum OpenRouterReasoningPolicy: Sendable, Equatable {
       case off
       case capped(allowance: Int)
       static let defaultAllowance = 1_024                       // estimate, see Target 1
       /// Known true or unknown → capped; known false → off.
       @MainActor static func policy(for modelID: String) -> OpenRouterReasoningPolicy
   }
   struct OpenRouterUsage: Sendable, Equatable {
       var promptTokens: Int?; var cachedTokens: Int?; var completionTokens: Int?; var reasoningTokens: Int?
   }
   enum OpenRouterStreamEvent: Sendable, Equatable {
       case content(String), reasoning(characters: Int), finish(String), usage(OpenRouterUsage)
   }
   struct OpenRouterStreamSummary: Sendable, Equatable {
       var visibleCharacters = 0, reasoningCharacters = 0
       var finishReason: String?
       var usage: OpenRouterUsage?
   }
   ```
   Sending `reasoning` when the status is unknown follows OpenRouter's documentation, which says
   models without reasoning ignore the parameter. Step 8 checks that claim live. If a provider
   answers HTTP 400 and the message mentions `reasoning`, retry once without the field and store
   `false` for that model id.
2. `ChatRequest` gains `let reasoning: Reasoning?`, where
   `struct Reasoning: Encodable { let effort: String; let exclude: Bool }`. The synthesized
   `Encodable` omits a nil optional, so a non-reasoning body stays byte-identical. Add
   `static func requestBody(model:messages:visibleMaxTokens:stream:policy:) throws -> Data`, make
   `makeRequest` use it, and do the same in `chatBody`. The self-test calls it.
3. Decoding. Add `static func parseStreamEvents(_ line: String) throws -> [OpenRouterStreamEvent]`.
   One SSE line can carry content, a finish reason and usage at once. Extend
   `StreamEvent.Choice.Delta` with `reasoning: String?`, add `finish_reason: String?` to `Choice`,
   and add a top-level `usage` with the nested detail structs. Keep `parseStreamLine` as a wrapper
   that returns the joined `.content` strings, because the existing contract cases call it.
4. Move the loop body of `streamConversation` into
   `static func drain<S: AsyncSequence>(lines: S, yield: (String) -> Void) async throws -> OpenRouterStreamSummary where S.Element == String`.
   `streamConversation` then does this:
   ```swift
   var allowance = policy.allowance                 // 0 for .off
   for attempt in 1...2 {
       let summary = try await Self.drain(lines: bytes.lines) { continuation.yield($0) }
       ModelPassRecorder.current?.report(openRouter: summary.usage)   // only if P0-20 has landed
       if summary.finishReason == "length" {
           if summary.visibleCharacters == 0 && attempt == 1 && allowance > 0 {
               allowance = min(allowance * 2, max(1_024, contextTokens / 4), 4_096); continue
           }
           throw OpenRouterError.cutOff(visibleText: summary.visibleCharacters > 0)
       }
       guard summary.visibleCharacters > 0 else { throw OpenRouterError.invalidResponse }
       break
   }
   ```
   `complete` follows the same rule on the non-streamed `finish_reason`: retry once when the
   content is empty; throw `cutOff(false)` if it is still empty; return the content when the text
   is only truncated, and log `finish=length`.
5. `OpenRouterError.cutOff` descriptions:
   - `false`: the sentence in Target 5;
   - `true`: "The answer was cut off."
   `voiceCode` maps both to `.unavailable`.
6. ToolLoop:
   - add `case cutOff(String)` to `QuickTurnResult`, and in the first-pass closure
     `catch OpenRouterError.cutOff(let visible)` return `visible ? .cutOff(assembled) : .failed(OpenRouterError.cutOff(visibleText: false).localizedDescription)`;
   - in the result switch, `.cutOff(raw)` parses the envelope:
     - `.answer(text)` → the reply is `text`, plus (typed only) `"\n\n(The answer was cut off.)"`;
     - `.tools` → as today;
     - `.pending`/`.invalid` → the `cutOff(false)` sentence.
   - `.failed` for a cut-off must not get the "The model could not answer: " prefix. Special-case it
     with `reason == OpenRouterError.cutOff(visibleText: false).localizedDescription`, or better,
     carry a typed error.
   - Planner round: `cutOff(true)` → use the assembled text as `completionText` (P1-04 later
     repairs a truncated call); `cutOff(false)` → return its sentence without the "The tool planner
     failed: " prefix.
7. Settings:
   - `Settings.openRouterModelReasons: [String: Bool]`, key `openRouterModelReasons`;
   - in `OpenRouterModelSelection`'s button action (`:52-54`), add
     `Settings.shared.openRouterModelReasons[model.id] = model.supportsReasoning`;
   - show the caption from Target 6 (DS tokens only).
   - `LLMProviders.make(.openRouter, …)` and the `.cloud` branch pass
     `OpenRouterReasoningPolicy.policy(for: modelID)`.
8. Live check (not a gate; it needs the owner's key and the network): extend `--selftest-openrouter`
   so that it prints `OPENROUTER_REASONING: policy=<…> finish=<…> reasoning_tokens=<n> visible=<n>`
   for the configured Agent model. Record the line in STATUS.

**Do not:**
- show, speak, log or store reasoning text. Count its characters only;
- change the visible budget P0-05's `AgentAnswerBudget` computes (voice's wanted value stays 112). The allowance comes on top, and only
  for OpenRouter. Voice turns do not reach OpenRouter today (`AgentModelRouting.provider(for:voice:)`
  returns `.appLLM` for voice, `ModelRoleStore.swift:727`);
- use "token", "provider" or "reasoning tokens" in user-visible text (`--selftest-ui-strings`);
- retry more than once, or retry a cut-off that already showed text (that would repeat words the
  user has read);
- touch Apple FM or llama.

**Red-first self-test:** extend `--selftest-openrouter-contract` (`OpenRouterContractSelfTest.run`,
pure, no network). Print `OPENROUTER_CONTRACT_WRONG: <case>` for each failure, and keep the final
marker `OPENROUTER_CONTRACT_OK` / `OPENROUTER_CONTRACT_FAILED`.
- **a. Request body.** For policy `.capped(1_024)` with a visible budget of 112, the JSON has
  `reasoning.effort == "low"`, `reasoning.exclude == true` and `max_tokens == 1_136`. For `.off`
  there is no `reasoning` key and `max_tokens == 112`.
- **b. Decoding.**
  - `data: {"choices":[{"delta":{"reasoning":"Thinking…"}}]}` → exactly `[.reasoning(characters: 9)]`,
    with no content.
  - `data: {"choices":[{"delta":{},"finish_reason":"length"}],"usage":{"prompt_tokens":1726,"completion_tokens":112,"prompt_tokens_details":{"cached_tokens":512},"completion_tokens_details":{"reasoning_tokens":105}}}`
    → `.finish("length")` and a usage of exactly 1726 / 512 / 112 / 105 (the O5 numbers).
- **c. All-reasoning stream.** Feed 105 reasoning lines and then the length line through `drain`,
  with a retry closure that counts calls and returns the same canned lines. It must throw
  `cutOff(visibleText: false)` after exactly 2 attempts. It must never finish silently and never
  throw `.invalidResponse`.
- **d. Truncated answer.** Content "I have " followed by the length line yields "I have ", then
  throws `cutOff(visibleText: true)`.

Also extend `--selftest-toolloop-production`:
- **e.** A scripted provider throws `cutOff(false)` on the typed first pass. The reply must equal
  the Target 5 sentence. It must not be "The model returned an incomplete response." and must not
  start with "The model could not answer:".
- **f.** A scripted provider yields "<answer/>Hello the", then throws `cutOff(true)`. The typed reply
  must start with "Hello the" and end with "(The answer was cut off.)".

**Confirm RED:**
- add `requestBody` (today's body, no reasoning), `parseStreamEvents` (content only), `drain` (today's
  loop) and `cutOff` (not yet thrown);
- expect a (no reasoning key), b (no reasoning or finish event), c (`.invalidResponse`) and e/f
  (today's strings) to fail.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-openrouter-contract
Scripts/run-selftest.sh --selftest-toolloop-production
Scripts/run-selftest.sh --selftest-ui-strings
Scripts/run-selftest.sh --selftest-openrouter          # network + key; prints OPENROUTER_REASONING, not a gate
Scripts/run-selftest.sh --selftest-model-roles
```

**Success threshold:**
- cases a–f pass, and were red first;
- `OPENROUTER_CONTRACT_OK` and `TOOLLOOP_PRODUCTION_OK`;
- owner smoke with the reasoning model on the Agent role: "what can you do?" and "list all your
  tools" each end with a complete sentence. Neither says "incomplete response". Record the
  `OPENROUTER_REASONING` line.

**Risks & rollback:**
- A provider may reject `reasoning`. Step 1's fallback handles that, and the model id is remembered
  as `false`.
- A larger `max_tokens` costs more on paid models. The allowance is bounded, and nothing is spent
  unless the model reasons.
- To roll back: set `OpenRouterReasoningPolicy.policy(for:)` to return `.off`. The decoder changes
  are additive.

**Done when:**
- [ ] The body, decoder, retry and typed error are in place, and cases a–f are green (red first).
- [ ] The picker records the reasoning flag and shows the caption.
- [ ] The `OPENROUTER_REASONING` line is recorded in STATUS.
- [ ] Committed as `P0-17: …`.

---

### P0-18 — llama prefix reuse: keep the KV cache across calls and decode only the tokens that changed

**Finding(s):** G N2 (§2.3, §4 MiniCPM5, §6). **Effort:** 1.5 days. **Depends on:** P0-04 (prompts are
rendered per family, and the reused prefix must be the rendered one), P0-14 (a model switch is
awaited, so the cache has one reset point), P0-06 (prewarm work class). **Unblocks:** P1-01 (shorter
eval runs on a local model; estimate), P1-05 (grammar-constrained rounds share one prefix), P1-06 (the
round budgets are sized on warm rounds), P3-07b (per-slot prefix state), P4-01 (the Now block's
placement assumes a reused prefix).

**Placement decision: Phase 0, not Phase 2.**
1. Phase 1's only metric, the live eval (P1-01), runs every case through this runtime two to four
   times. Each pass re-prefills 1.2–2.3 k tokens at about 500 tok/s (G M1–M3; planner prompts are
   2,203–2,317 tokens per B §1). Every per-task gate in Phase 1 pays that cost again.
2. Code comments and three roadmap tasks already assume reuse exists:
   - `voiceRoutingSystem` is documented as "identical across the turns of a session so the
     llama.cpp prefix cache holds" (`ToolLoop:492-493`), but nothing reuses it;
   - P4-01's section order and its risk note;
   - P3-07b's per-context slots.
3. The change is confined to `NotesModelRuntime` and the typed prewarm. It does not touch the voice
   pipeline that P2-01 measures, or the Apple FM frontend.

**Why (what the user experiences today):** On MiniCPM5-2B (G §2.3), typing in the Agent pane
prewarmed the model and prefilled 1,180 tokens (2.42 s). The turn then waited 0.89 s behind that
prewarm, and re-prefilled 1,478 tokens from zero (2.91 s). The time to first text was **5.04 s**, and
the next turn repeated all of it (M). Expected effect (estimate, G N2): prefill on a warm turn drops
from 2.9–3.3 s to about 0.3–0.6 s, and MiniCPM5's time to first text from about 4 s to 1–1.5 s.

**Files you will change:**
- `Formatting/LLM/NotesModelRuntime.swift`:
  - `decodePromptWhileScheduled` (`:472-494`);
  - `completeWhileScheduled` (`:496-569`; the clear is at `:520`);
  - `streamWhileScheduled` (`:571-654`; the clear is at `:595`, the prefill note at `:597`);
  - `ensureContext(promptTokens:maxTokens:)` (`:1234-1265`);
  - `prepareForConversation(workClass:)` (`:347-360`) and `prewarmIfNeeded(voice:)` (`:292-331`);
  - `shutdownNow` (`:915`), `useInstalledModel` (`:141`), `revertToBuiltIn` (`:230`);
  - new state `kvTokens`, `lastPrefillStats`, and test accessors.
- `Formatting/LLM/ChatTemplate.swift` (created by P0-04): `renderPrefix(_:system:)` and
  `renderHistory(_:system:messages:)`.
- new `Formatting/LLM/PrefixReuse.swift` (pure helpers) and
  `Formatting/LLM/PrefixCacheSelfTest.swift`.
- `Agent/AgentAnswersSelfTest.swift` (P0-14b): per-turn prefill diagnostics.
- `NextNotesApp.swift`, `AGENTS.md`, `Scripts/acceptance.sh`: `--selftest-llm-prefix-cache`
  (INTEGRATION, `|600`).

**Read for context (do not change):**
- `llama.h` in the pinned framework
  (`~/Library/Caches/NextNotesBuild/scratch/artifacts/speechify/LlamaFramework/llama.xcframework/ios-arm64/llama.framework/Headers/llama.h`).
  Line 739, `llama_memory_seq_rm(mem, seq_id, p0, p1) -> bool`: "Returns false if a partial sequence
  cannot be removed". Line 730, `llama_memory_clear(mem, data)`;
- `UI/Agent/AgentView.swift:97-98` (prewarm on `.task` and on every keystroke);
- `RealtimeAgent.voiceRoutingSystem(voice:)` (`ToolLoop:492-495`).

**Current behaviour** (verified 2026-09-23):
- `streamWhileScheduled` (`:594-597`):
  ```swift
  let prefillTrace = LatencyTrace.start(.modelPrefill)
  llama_memory_clear(llama_get_memory(context), true)
  try await decodePromptWhileScheduled(promptTokens, context: context, jobID: jobID)
  prefillTrace.end(note: "app_llm prompt_tokens=\(promptTokens.count)")
  ```
  `completeWhileScheduled` clears the same way at `:520`. `decodePromptWhileScheduled` always
  decodes from position 0.
- `ensureContext` uses `if let context, contextSize == size { return context }` (`:1242`). When the
  rounded size differs (granularity 512, `:46`), even a larger existing context is freed and
  rebuilt, which discards the KV cache.
- The typed prewarm (`AgentView.swift:98` → `prewarm()` → `prewarmIfNeeded(voice: false)` →
  `prepareForConversation(workClass: .background)` at `:326`) prefills
  `chatMLPrompt(system: RealtimeAgent.voiceRoutingSystem(voice: true), user: "Hello.")`. That is the
  **voice** system prompt, while typed turns use `voiceRoutingSystem(voice: false)`. It runs only when
  `context == nil` (`:350`).
- An unexplained reload happened 3 s after M2 (`model.load 0.174 s`, `had_context=false` at
  02:08:42Z; G §4).

**Target behaviour:**
1. The runtime tracks `kvTokens`: exactly the tokens whose KV entries sit at positions `0..<count`
   in the live context.
2. Each prefill works like this:
   - `keep = min(commonPrefix(kvTokens, promptTokens), promptTokens.count − 1)`, so the last prompt
     token is always decoded and produces logits;
   - call `llama_memory_seq_rm(mem, 0, keep, -1)`. If it returns false (hybrid, recurrent or
     sliding-window memory may refuse a partial removal), fall back to `llama_memory_clear` and
     `keep = 0`;
   - decode `promptTokens[keep...]` from position `keep`.
3. `ensureContext` only grows: it keeps any context with `contextSize >= needed`. Rebuilding frees
   the KV cache and resets `kvTokens`.
4. `kvTokens` is reset on context free or rebuild, `shutdownNow`, model swap (`useInstalledModel`,
   `applyPendingSpec`), `revertToBuiltIn`, a load failure, any thrown decode error, and cancellation
   during prefill or generation, when the KV contents are no longer known.
5. After generation, `kvTokens = promptTokens + every generated token that was passed to llama_decode`.
   The last sampled token that ended the loop was not decoded, so it is not included.
6. The typed prewarm prefills the typed prefix: `ChatTemplate.renderPrefix(family, system: RealtimeAgent.voiceRoutingSystem(voice: false))`,
   decoded with no sampling. The voice prewarm uses `voice: true`. A prewarm is skipped when
   `kvTokens` already starts with that prefix.
7. The `model.prefill` note reads `app_llm prompt_tokens=<n> reused=<k> decoded=<n−k>`.
8. Where the gain comes from (estimates):
   - planner rounds of one turn share the system prompt and the start of the user message, because
     results are appended (`AgentToolLoop.userMessage(original:results:)`);
   - consecutive typed turns share the system prompt and the history;
   - the first pass and the planner only share the persona head of their system prompts.

   P1-02 removes the typed first pass, which leaves the planner-to-planner reuse.

**Steps:**
1. `PrefixReuse.swift` (pure):
   ```swift
   enum PrefixReuse {
       static func commonPrefixLength(_ a: [llama_token], _ b: [llama_token]) -> Int
       /// Tokens of `cached` kept for `prompt`; never the whole prompt (one token must be decoded).
       static func keepCount(cached: [llama_token], prompt: [llama_token]) -> Int
       static var enabled = true      // one switch for rollback; false → keepCount returns 0
   }
   struct PrefillStats: Sendable, Equatable { let promptTokens: Int; let reused: Int; let decoded: Int; let seconds: Double }
   ```
2. In `NotesModelRuntime`:
   - `private var kvTokens: [llama_token] = []`;
   - `private(set) var lastPrefillStats: PrefillStats?`;
   - `func prefillStatsForTesting() -> PrefillStats?`;
   - `func resetPrefixCacheForTesting()`, which clears memory and sets `kvTokens = []`.
3. Replace both clear-then-decode blocks with
   `let start = try await preparePrefix(promptTokens, context: context, jobID: jobID)`:
   ```swift
   private func preparePrefix(_ prompt: [llama_token], context: OpaquePointer, jobID: UUID) async throws -> Int {
       let began = ContinuousClock.now
       var keep = PrefixReuse.keepCount(cached: kvTokens, prompt: prompt)
       let memory = llama_get_memory(context)
       if keep == 0 || !llama_memory_seq_rm(memory, 0, llama_pos(keep), -1) {
           llama_memory_clear(memory, true); keep = 0
       }
       kvTokens = Array(kvTokens.prefix(keep))
       do {
           try await decodePromptWhileScheduled(Array(prompt[keep...]), startPosition: keep, context: context, jobID: jobID)
       } catch { llama_memory_clear(memory, true); kvTokens = []; throw error }
       kvTokens = prompt
       lastPrefillStats = PrefillStats(promptTokens: prompt.count, reused: keep, decoded: prompt.count - keep,
                                       seconds: began.duration(to: .now).seconds)   // add a small helper if needed
       return prompt.count
   }
   ```
   `decodePromptWhileScheduled(_:startPosition:context:jobID:)` uses the position
   `startPosition + index`. Logits are requested only for the final prompt token.
4. In both generation loops, after each successful `llama_decode` of a sampled token, call
   `kvTokens.append(token)`. Wrap each loop body so that any thrown error (including
   `CancellationError`) resets: `llama_memory_clear` and `kvTokens = []`.
5. `ensureContext`: change `contextSize == size` to `contextSize >= size`. In the free/rebuild branch,
   set `kvTokens = []`. Also reset in `shutdownNow`, `useInstalledModel`, `applyPendingSpec`,
   `revertToBuiltIn`, and on every `load` failure path.
6. `ChatTemplate`:
   - `renderPrefix(_ family:, system:)` is the exact text that `render(family, system:, messages:)`
     starts with, for any messages;
   - `renderHistory(_ family:, system:, messages:)` is `render` without the trailing generation
     prompt.
   - Both are pinned by the self-test for every family.
   - If P0-04 added an explicit BOS token, it is part of `promptTokens` and stable, so the prefix
     compare includes it.
7. Prewarm:
   - `prepareForConversation(workClass:voice:)` renders
     `renderPrefix(family, system: RealtimeAgent.voiceRoutingSystem(voice: voice))`, tokenizes it,
     skips when `kvTokens.starts(with:)` it, and otherwise calls `preparePrefix` with no sampling;
   - `prewarmIfNeeded(voice:)` passes `voice` through;
   - remove the `guard context == nil` shortcut;
   - keep P0-06's work class (`prewarmWorkClass`).
8. Prefill note (Target 7). If P0-20 has landed, also report `cachedTokens: reused` to
   `ModelPassRecorder.current`.
9. **Investigate, do not guess:** after steps 1–8, drive two typed turns on an installed model and
   read `model.load` rows in `~/Library/Application Support/Next Notes/metrics.jsonl`. A load with
   `had_context=false` within 10 minutes of the previous turn is the unexplained reload. Record what
   you find in `STATUS.md` "Decisions and deviations". Fix it only if the cause is proven.

**Do not:**
- compare text instead of tokens;
- reuse the cache across models, contexts or (later) P3-07b slots;
- reuse it after a cancellation or an error;
- skip decoding the final prompt token (the sampler needs its logits);
- call llama from outside the actor, or use `MainActor.assumeIsolated`;
- load the **shared** runtime in a self-test (`prewarmIfNeeded` refuses under the harness, `:295`).
  Use a private `NotesModelRuntime(spec:gpuLayers:)`, as `runMetalSelfTest` does
  (`NextNotesApp.swift:2664-2667`);
- raise the prewarm to `.realtimeAgent` for typing (P0-06; AGENTS.md: background warmup must not
  take the frontend's priority).

**Red-first self-test:** new `--selftest-llm-prefix-cache` in `Formatting/LLM/PrefixCacheSelfTest.swift`.
Print `LLM_PREFIX_CACHE_WRONG: <text>` for each problem.
- **Part A (pure, always runs).**
  - `keepCount` table: `([], [1,2,3]) → 0`; `([1,2,3], [1,2,3]) → 2`; `([1,2,3,4], [1,2,9]) → 2`;
    `([1,2], [1,2,3,4]) → 2`; `([5], [1]) → 0`.
  - For every `ChatTemplateFamily` except `unsupported`:
    - `render(f, S, [u1]).hasPrefix(renderPrefix(f, S))`;
    - `render(f, S, [u1, a1, u2]).hasPrefix(renderHistory(f, S, [u1]))`.
- **Part B (live, private runtime on S1-mini, `S1MiniModels.spec`).** When the file is missing, print
  `LLM_PREFIX_CACHE_ABSENT: S1-mini not downloaded` as the last line, but only after Part A passed.
  If Part A failed, the result is FAILED. S is a fixture system prompt of at least 600 tokens
  (repeat a paragraph).
  1. `streamConversation(system: S, messages: [u1], maxTokens: 8)`, drained. `stats1.reused == 0`.
  2. `streamConversation(system: S, messages: [u1, a1, u2], maxTokens: 8)`, where `a1` is call 1's
     text. Assert:
     - `stats2.reused ≥ 0.8 × stats1.promptTokens`;
     - `stats2.decoded < 0.5 × stats2.promptTokens`;
     - `stats2.seconds < stats1.seconds`.
  3. A system prompt that differs in its first sentence gives `reused ≤ 8`.
  4. Record call 2's first 4 generated tokens. Run `resetPrefixCacheForTesting()`, repeat call 2,
     and assert the first 4 tokens are identical.
  5. Call `prepareForConversation(workClass: .background, voice: false)`, then a typed-shaped call
     with `voiceRoutingSystem(voice: false)`. `reused ≥ tokens(renderPrefix)`.
  6. After `shutdown()`, one more call gives `reused == 0`.

  Final line: `LLM_PREFIX_CACHE_OK: reused <k>/<n> tokens, prefill <t1>s → <t2>s` or
  `LLM_PREFIX_CACHE_FAILED: <n> problem(s)`.
- **Also extend P0-14b** (`--selftest-agent-answers`). When the answering provider is `.appLLM`,
  print `AGENT_ANSWERS_PREFILL turn=<n> reused=<k> decoded=<m>` for each turn, from
  `NotesModelRuntime.shared.prefillStatsForTesting()`.

**Confirm RED:** add `PrefixReuse.keepCount` returning 0, `lastPrefillStats` filled with
`reused: 0`, the prewarm unchanged (voice system prompt), and `renderPrefix`/`renderHistory`
implemented for real (they are new helpers, not a behaviour change). Part B cases 2 and 5 must fail
(`reused 0`), and so must the `keepCount` rows.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-llm-prefix-cache
Scripts/run-selftest.sh --selftest-chat-template
Scripts/run-selftest.sh --selftest-llm-metal
Scripts/run-selftest.sh --selftest-voice-scheduling
Scripts/run-selftest.sh --selftest-residency
Scripts/run-selftest.sh --selftest-toolloop-production
Scripts/run-selftest.sh --selftest-cleanup-structure     # S1-mini's own runtime is untouched
Scripts/run-selftest.sh --selftest-timeout 900 --selftest-agent-answers   # with an installed model on the Agent role
```
Owner smoke: on an installed model, type "What can you do?" and then "list all your tools". Then run
`grep '"model.prefill"' ~/Library/Application\ Support/Next\ Notes/metrics.jsonl | tail -3`. The
second turn's note shows `reused=` greater than 0.

**Success threshold:**
- Part A passes. Part B: reuse ≥ 80% on call 2, prefill time ≤ 50% of call 1, and identical first
  tokens.
- On the owner's installed model, the second typed turn's `model.first_token` is at least 1.5 s
  lower than the same turn before this task (estimate from G: 2.9–3.3 s of prefill today). Record
  both numbers.

**Risks & rollback:**
- A stale KV cache would give wrong answers. Mitigations: exact token comparison, a reset on every
  error or cancellation, and the equality check in Part B.
- A context that only grows holds up to `contextTokens` of KV memory until the 10-minute idle
  unload.
- To roll back, set `PrefixReuse.enabled = false`, which restores clear-every-time.

**Done when:**
- [ ] Prefix reuse is in both decode paths, the context only grows, and every reset point is covered.
- [ ] The typed prewarm prefills the typed prefix.
- [ ] `LLM_PREFIX_CACHE_OK` (red first), and the regression flags are unchanged.
- [ ] Before/after first-token numbers and the reload finding are recorded in STATUS.
- [ ] The flag is registered, listed in AGENTS.md, and in `Scripts/acceptance.sh` INTEGRATION.
- [ ] Committed as `P0-18: …`.

---

### P0-19 — Keep model replies and account data out of the on-disk URL cache, and purge what is there

**Finding(s):** G N4 (privacy). **Effort:** 0.5–1 day. **Depends on:** none. **Unblocks:** P1-01 runs with
`--allow-cloud`, P4-09 (the cloud-consent text can say nothing is kept on disk), P5-02 (cloud
websocket sessions use the same factory).

**Why (what the user experiences today):**
- `~/Library/Caches/ai.pivotstudio.nextnotes/Cache.db` holds an entry for
  `https://openrouter.ai/api/v1/chat/completions`.
- `fsCachedData/2380718E-…` holds the **full** 22:09:48 SSE stream, including the model's reasoning,
  which paraphrases the system prompt (M, G N4).
- The `fsCachedData` folder held 69 files on 2026-09-23 (`ls … | wc -l`; not all of them are
  OpenRouter).
- Every model call goes through `URLSession.shared`, whose default `URLCache` writes to disk.
  Conversations, persona text and memory facts therefore land in a cache file that nobody asked
  for.

**Files you will change:**
- new `Support/PrivateNetworking.swift` (`PrivateURLSession`) and
  `Support/PrivateNetworkingSelfTest.swift`;
- `Formatting/LLM/OpenRouterLLMProvider.swift`: `URLSession.shared` at `:307`, `:361`, `:421`, `:453`,
  `:612`, `:630`;
- `Formatting/LLM/OpenAICompatibleLLMProvider.swift`: `:54`, `:81`, `:129`, `:389`. Add an injectable
  `session` so the self-test can use a loopback fixture;
- `Calendar/Google/GoogleOAuthClient.swift:141` (token responses) and
  `Calendar/Google/GoogleCalendarProvider.swift:198` (events);
- `Integrations/MCP/MCPSession.swift:279` (tool results);
- `Integrations/Composio/ComposioBrowserAuth.swift:68,193` (auth);
- `NextNotesApp.swift`: the one-time purge at launch, and the flag registration;
- `AGENTS.md`, `Scripts/acceptance.sh` (INTEGRATION, `|300`).

**Scope note:** G names only OpenRouter. The five other files above carry the same kind of data (a
chat with a local server, OAuth tokens, calendar events, MCP results, Composio auth) through the same
shared session, so they are included. Excluded on purpose, because their responses are public or
loopback metadata, or because they need their own resumable sessions:
- `HuggingFaceClient`;
- `ModelDownloader`;
- `WakeWordModelManager`;
- `SkillRegistryClient`;
- `LocalRuntimeDiscovery`;
- `BrowserCDPClient`.

**Read for context (do not change):**
- `Support/ModelRoles/ModelRoleSelfTest.swift` (its loopback `NWListener` fixture server);
- `Support/ModelDownloader.swift:331` (a custom session; leave it).

**Current behaviour:** `grep -rn "URLSession.shared" Sources/NextNotes` lists the sites above. None of
them sets `cachePolicy`, and no session sets `urlCache = nil`.

**Target behaviour:**
1. Every request in the listed files goes through `PrivateURLSession.shared`. That is an
   `.ephemeral` configuration with `urlCache = nil` and
   `requestCachePolicy = .reloadIgnoringLocalCacheData`. Nothing from these requests reaches
   `Cache.db` or `fsCachedData`.
2. At the first normal launch after this ships (never under the self-test harness),
   `URLCache.shared.removeAllCachedResponses()` runs once and records
   `privacy.urlCachePurged.v1 = true`.
3. After that launch, the owner's `Cache.db` has no `openrouter.ai` row.

**Steps:**
1. `PrivateNetworking.swift`:
   ```swift
   enum PrivateURLSession {
       /// For every request that carries a person's words, a model's reply, a token or account data.
       static let shared = URLSession(configuration: configuration)
       static var configuration: URLSessionConfiguration {
           let c = URLSessionConfiguration.ephemeral
           c.urlCache = nil
           c.requestCachePolicy = .reloadIgnoringLocalCacheData
           return c
       }
       /// Once per install; the caller passes stores so a self-test can isolate them.
       static func purgeLegacyCache(cache: URLCache = .shared, defaults: UserDefaults = .standard) -> Bool
   }
   ```
   The ephemeral configuration keeps in-memory cookies, which is enough for the OAuth token
   endpoint.
2. Replace `URLSession.shared` at every listed site. `OpenAICompatibleLLMProvider` gains
   `let session: URLSession`, defaulting to `PrivateURLSession.shared` (its `init` at `:27`). The
   other providers use the static directly.
3. `OpenRouterLLMProvider.makeRequest` also sets `request.cachePolicy = .reloadIgnoringLocalCacheData`,
   so a future caller that uses the shared session is still safe.
4. In `AppDelegate.applicationDidFinishLaunching`, after `if runRequestedSelfTest() { return }`, add
   `_ = PrivateURLSession.purgeLegacyCache()`.
5. Add a trap to AGENTS.md, in the "Things that look like bugs" style: "Model calls use
   `PrivateURLSession`; `URLSession.shared` wrote a full OpenRouter stream, reasoning included, into
   `Cache.db`." Name the flag.

**Do not:**
- `rm` the cache directory. Use the URLCache API, at launch, inside the app;
- purge under the self-test harness;
- move model downloads onto the ephemeral session (resumable downloads need `ModelDownloader`'s own
  session);
- log response bodies while debugging this.

**Red-first self-test:** new `--selftest-private-network` in `Support/PrivateNetworkingSelfTest.swift`.
Print `PRIVATE_NETWORK_WRONG: <text>` for each problem.
- **a.** `PrivateURLSession.shared.configuration.urlCache == nil`, and the cache policy is
  `.reloadIgnoringLocalCacheData`.
- **b. Loopback.**
  - Start an `NWListener` fixture that answers `POST /v1/chat/completions` with
    `Cache-Control: public, max-age=3600`: a JSON body for `stream:false`, and an SSE body for
    `stream:true`.
  - For the duration of the test, set `URLCache.shared` to a temp
    `URLCache(memoryCapacity: 0, diskCapacity: 50_000_000, directory: <tmp>)`.
  - Call `OpenAICompatibleLLMProvider(baseURL: fixture, …)`, once with `complete` and once with
    `streamConversation`.
  - Assert that the temp cache has no response for either request, and that `<tmp>` contains no
    `fsCachedData` blob.
  - Restore `URLCache.shared`.
- **c. Purge.** Use an isolated `URLCache` and `UserDefaults(suiteName:)`. Store a fake cached
  response, then purge:
  - the response is gone and the flag is set;
  - a second call returns false and does nothing.
- Final line: `PRIVATE_NETWORK_OK` or `PRIVATE_NETWORK_FAILED: <n> problem(s)`.

**Confirm RED:** make the seam `PrivateURLSession.shared = URLSession.shared` (today's behaviour), and
keep the providers unchanged. Case a fails. Case b should fail too, because G observed a POST stream
being cached. If case b does not reproduce a cache entry on the unmodified code, record that in
STATUS and keep a plus the grep in **Verify** as the red evidence. Do not weaken case b.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-private-network
Scripts/run-selftest.sh --selftest-openrouter-contract
Scripts/run-selftest.sh --selftest-model-roles        # uses its own loopback server
Scripts/run-selftest.sh --selftest-calendar
Scripts/run-selftest.sh --selftest-mcp
Scripts/run-selftest.sh --selftest-composio
! grep -n "URLSession.shared" Sources/NextNotes/Formatting/LLM/OpenRouterLLMProvider.swift \
    Sources/NextNotes/Formatting/LLM/OpenAICompatibleLLMProvider.swift Sources/NextNotes/Calendar/Google \
    Sources/NextNotes/Integrations/MCP/MCPSession.swift Sources/NextNotes/Integrations/Composio
```
After the owner has relaunched the app once (read-only check):
```bash
sqlite3 ~/Library/Caches/ai.pivotstudio.nextnotes/Cache.db \
  "select count(*) from cfurl_cache_response where request_key like '%openrouter.ai%';"   # expect 0
```

**Success threshold:**
- `PRIVATE_NETWORK_OK`, red first;
- the grep prints nothing;
- the owner's `Cache.db` count is 0 after one relaunch;
- `--selftest-calendar`, `--selftest-mcp` and `--selftest-composio` end as they did in the
  baseline.

**Risks & rollback:**
- An OAuth flow that needs persistent cookies would break. Google's token endpoint does not use
  them; watch `--selftest-calendar` and a manual Google sign-in by the owner.
- To roll back, revert. The purge has already run once and is harmless.

**Done when:**
- [ ] Every listed site uses `PrivateURLSession`, and the grep is empty.
- [ ] The one-time purge runs at launch.
- [ ] `PRIVATE_NETWORK_OK` (red first).
- [ ] The owner's `Cache.db` check shows 0 rows.
- [ ] The trap is in AGENTS.md, and the flag is in the list and in INTEGRATION.
- [ ] Committed as `P0-19: …`.

---

### P0-20 — One local usage log for Agent, Meetings and Dictation: which model or engine ran each pass, how long it took, what it cost and whether it worked

**Status of this rewrite (H-audit 2026-09-24).** P0-20 was `todo` when it was widened at the owner's request. The
original task wrote one `agent.model_pass` span per Agent model call into `metrics.jsonl`. It now writes one
**usage row** per model or engine pass, for the Agent, Meetings and Dictation, into a new local file `usage.jsonl`,
and it is split into five subtasks, each with its own STATUS row and commit:

| Subtask | Scope | Effort |
|---|---|---|
| **P0-20a** | Schema, writer, rotation, privacy sanitiser, clear API; the Agent paths (typed, voice frontend, voice worker, routines, hand-offs), memory review and Knowledge Ask | 1.5 days |
| **P0-20b** | Meetings: transcription, speaker separation, notes (single, map, reduce), post-meeting proposals, live meeting proposals, the Needle watcher | 1 day |
| **P0-20c** | Dictation: the speech engine, the cleanup pass, and the drain / transcribe / names / cleanup split persisted and joined to `runs.jsonl` | 0.5 day |
| **P0-20d** | `--usage-report` diagnostic flag, and a small Usage section in Settings ▸ Models | 1 day |
| **P0-20e** | `--selftest-usage-log` exit cases: all three features end to end, privacy scan, store isolation, acceptance registration | 0.5 day |

Order: P0-20a → P0-20b and P0-20c (either order) → P0-20d → P0-20e. P0-20a is the only one the rest of the roadmap
waits for.

**Finding(s):** G N8 (§1, §7); owner request 2026-09-23 ("usage and provenance logging for Agent, Meetings and
Dictation"); H1 #25 (MeetingAgent passes leave no persistent trace); H3 #3 (a post-meeting failure that prevents
every proposal is invisible after relaunch); H3 #25 (the memory-review ledger is read as a lifetime count).
**Depends on:** none (soft: P0-14; before P0-14 one turn can resolve two providers, and the log then shows both, which
is exactly the evidence that was missing). P0-17 and P0-18 fill in more fields when they land.
**Unblocks:** P2-01 (hard; its per-turn stage timings are written onto the same rows), P1-01 (the eval report reads the
rows of each case's turn), P4-09 (which model did typed and background work), P4-05 and P4-10 (they read
`meeting.proposals` rows before changing any gate), P4-11 (lifetime totals cross-check), and the separate
`roadmap/done/DICTATION-MEETINGS-LIMITS/` roadmap, which takes all its measurements from P0-20b and P0-20c.

**Why (what the user experiences today):**
- No store says which model answered an Agent turn. `agent-conversation.json`, `agent-audit.jsonl` and
  `metrics.jsonl` have no provider or model field. G had to attribute 17 typed turns from CFNetwork byte counts and
  `tokengenerationcore` log lines (G §1); token counts for 5 of 6 OpenRouter turns are estimates from response sizes
  (G §7); one turn (M1) was answered by a model other than the one chosen, and nothing recorded it.
- Meetings: six finished meetings on this Mac have `agentActions: []` and no `proposals.json`, and nothing on disk
  says whether the post-meeting pass ran and found nothing, ran out of room (`AgentError.contextTooSmall`, H3 #3), or
  never ran (H1 #25). `problems[id]` is in memory only; the `agent round N: K call(s)` line is info-level and ages
  out in minutes.
- Dictation: the drain / transcribe / names / cleanup split is already recorded as `dictation.*` spans in
  `metrics.jsonl` (`DictationController.swift:957`, `:976-980`, `:1062-1072`), but that file is a ring: **603 rows
  covered only 2026-09-22 20:17Z → 2026-09-24 03:38Z, about 31 hours (M, this Mac)**, and nothing joins those spans
  to the dictation in `runs.jsonl` they belong to. "Dictation got slow last week" cannot be answered.
- The owner asked for one place that answers, for every feature: which model or engine ran, local or cloud, warm or
  cold, how long to the first token and in total, how many tokens, whether it was cut off, which tools ran and which
  failed, and why a fallback happened.

**Decision: a new `usage.jsonl`, not an extended `metrics.jsonl`.** Reasons, each checked against source today:
1. **Retention.** `MetricsStore` keeps a 512-span ring (`defaultRingCapacity` @ `Support/MetricsStore.swift:19`) and
   rewrites the file to the ring once it passes 1,024 lines (`:55-58`). Measured: 31 hours of history on this Mac.
   Per-pass usage rows plus P2-01's ~17 stage spans per voice turn plus 8 dictation spans per dictation would cut that
   to hours. A median "over the last 30 days" needs weeks of rows.
2. **Load cost.** `MetricsStore.init` decodes the whole file into memory (`init` `:30-45`, `load(from:)` `:75-82`). A
   30-day usage log (estimate: ~400 rows/day × ~650 bytes ≈ 8 MB/month) must not be read into RAM at launch; the
   usage writer appends and only `--usage-report` and the Settings section read it, on demand, off the main actor.
3. **Schema.** A `LatencySpan` is one duration plus a `ProcessSnapshot` (`LatencyTrace.swift:227-257`). A usage row
   has about 30 fields. Bolting them onto every latency row as an optional blob (the original P0-20 design) makes every
   span consumer decode it.
4. **Clear semantics.** A usage history is something a person may want to clear from Settings; `metrics.jsonl` is an
   engineering ring nobody clears.
`metrics.jsonl` stays what it is: the short ring of per-stage latency spans. **`usage.jsonl` is the single persistent
sink for per-pass usage and provenance**: G N8's record, P2-01's per-turn headline timings (P2-01 writes them onto
the voice turn's row, see P2-01 step 3), and the meeting and dictation passes. `runs.jsonl` (`RunLog`,
`Support/RunLog.swift:108`) keeps the dictated *text*; `agent-audit.jsonl` (`AgentAuditLog`,
`Agent/Activity/AgentActivityStore.swift:139-160`) keeps what the agent *did* in user-facing words. Neither gains
timing fields; usage rows join to them by id.

**The row (JSON Lines, one object per line, ISO-8601 dates, keys exactly as below; optional keys omitted when nil):**
```swift
struct UsageRecord: Codable, Sendable, Equatable {
    var v: Int = 1                        // schema version; readers skip rows with v > known
    var id: UUID
    var ts: Date                          // when the pass ended
    var feature: String                   // UsageFeature.rawValue, see below
    var pass: String                      // "answer" | "planner" | "final" | "frontend-route" | "frontend-answer"
                                          // | "round" | "single" | "map" | "reduce" | "review" | "live"
                                          // | "window-batch" | "cluster" | "engine" | "cleanup" | "handoff" | "turn"
    var round: Int?
    var provider: String                  // UsageProvider.rawValue, see below
    var modelID: String                   // the model or engine that actually ran (displayModelName / engine id)
    var locality: String                  // "local" | "cloud"
    var requestedRole: String?            // ModelRole.rawValue ("agent", "meetingNotes", …) when a role chose it
    var requestedModel: String?           // what that role named; differs from modelID on a fallback
    var fallbackReason: String?           // UsageFallback.rawValue: "modelUnavailable" | "loadFailed" | "noKey"
                                          // | "consent" | "busy" | "roleUnanswerable" | "preferredOverride"
    var warm: Bool?                       // false when this pass paid a model load
    var loadMs: Int?
    var promptTokens: Int?
    var cachedTokens: Int?                // OpenRouter prompt cache, or llama reused prefix (P0-18)
    var completionTokens: Int?
    var reasoningTokens: Int?
    var countsEstimated: Bool?            // true when counts are characters / 4
    var ttftMs: Int?                      // first visible token; nil for engines and non-streamed passes
    var totalMs: Int                      // the pass itself, excluding tool execution and waiting for a person
    var tokensPerSec: Double?             // completionTokens / (totalMs − ttftMs), when both exist
    var finishReason: String?             // "stop" | "length" | "cancelled" | "error" | "timeout"
    var truncated: Bool?                  // true when finishReason == "length" or an engine hit its deadline
    var toolsProposed: [String]?          // canonical tool ids only, never arguments
    var toolsExecuted: [UsageToolRun]?    // {id, ok, ms, errorClass}
    var errorClass: String?               // UsageErrorClass.rawValue: "timeout" | "modelUnavailable" | "loadFailed"
                                          // | "contextTooSmall" | "inputTooLong" | "rateLimited" | "network"
                                          // | "parse" | "cutOff" | "cancelled" | "permission" | "other"
    var errorMessage: String?             // UsageLog.sanitise(_:), ≤ 160 characters
    var audioSeconds: Double?             // speech engines and speaker separation
    var realtimeFactor: Double?           // compute seconds / audio seconds
    var stages: [String: Double]?         // named sub-stage seconds (dictation split; P2-01 voice headline stages)
    var counts: [String: Int]?            // e.g. proposals, refusals, reconciledOut, windows, speakers, facts, reserved, budget
    // Correlation ids (all optional; they are how rows join to the other stores)
    var turnID: UUID?                     // one user turn (typed, voice) or one worker revision
    var conversationID: UUID?             // AgentSession.shared.sessionID
    var workID: UUID?; var revision: Int?
    var meetingID: UUID?                  // Meetings/<id>/meeting.json
    var dictationRunID: UUID?             // DictationRun.id in runs.jsonl
    var scheduleID: UUID?                 // routine
}
struct UsageToolRun: Codable, Sendable, Equatable { var id: String; var ok: Bool; var ms: Int; var errorClass: String? }
```
- `UsageFeature` (enum, `String` raw values): `agent.typed`, `agent.voice`, `agent.worker`, `agent.routine`,
  `agent.handoff`, `meeting.transcribe`, `meeting.diarize`, `meeting.notes.single`, `meeting.notes.map`,
  `meeting.notes.reduce`, `meeting.proposals`, `meeting.live`, `meeting.needle`, `dictation.asr`,
  `dictation.cleanup`, `memory.review`, `knowledge.ask`. A reader must tolerate an unknown value (a newer build).
- `UsageProvider`: `appleFM`, `llama`, `openrouter`, `openaiCompatible`, `codex`, `acp`, `needle`, `parakeet`,
  `appleSpeech`, `s1mini`, `rules`, `diarizer`. `locality` is `cloud` only for `openrouter` (and `codex`/`acp` when the
  harness runs a cloud model; record `cloud` for both unless the backend says otherwise).

**Privacy (every subtask):** a row never holds prompt, reply, reasoning, transcript or dictated text, tool arguments
or tool output, file names, email addresses, subjects or URLs. Tool ids are canonical ids from the registry.
`errorMessage` goes through `UsageLog.sanitise`: drop anything inside quotes, replace e-mail addresses, URLs, file
paths and digit runs of 6 or more with `<redacted>`, collapse whitespace, cap at 160 characters. The file is local
only: nothing uploads it, and no network call is made by this task. `UsageLog.shared` is a temp directory whenever
`SelfTest.isRunning`, exactly like `MetricsStore.shared` (`MetricsStore.swift:13-16`).

**Rotation:** `usage.jsonl` rotates to `usage.1.jsonl` (replacing any older `usage.1.jsonl`) when it passes 8 MB, so at
most two files and about 16 MB exist. At launch, on the writer queue and off the main actor, rows older than 90 days
are dropped from `usage.1.jsonl` (the only compaction; `usage.jsonl` is never rewritten while appending). Both numbers
are `static let`s on `UsageLog` so a test can pass tiny values. Sizes are estimates: at ~400 rows/day × ~650 bytes one
file holds about 30 days.

---

#### P0-20a — Usage log core, and the Agent, memory-review and Knowledge Ask passes

**Finding(s):** G N8; owner request. **Effort:** 1.5 days. **Depends on:** none (soft P0-14). **Unblocks:** P0-20b,
P0-20c, P0-20d, P0-20e, P2-01, P1-01 (report), P4-09.

**Why (what the user experiences today):** see the umbrella. Specifically for the Agent: nothing records which model
answered, and the typed `agent.transcript_to_first_token` span (`RealtimeAgent.swift:244`) carries no provider.

**Files you will change:**
- new `Support/Usage/UsageRecord.swift`: `UsageRecord`, `UsageToolRun`, `UsageFeature`, `UsageProvider`,
  `UsageErrorClass`, `UsageFallback`, and `UsageErrorClass.classify(_ error: Error) -> UsageErrorClass`.
- new `Support/Usage/UsageLog.swift`: `UsageLog` (writer, rotation, compaction, `load`, `clear`, `sanitise`).
- new `Support/Usage/ModelPassRecorder.swift`: `ModelPassRecorder` (the per-model-pass recorder, task-local).
- new `Support/Usage/UsageLogSelfTest.swift`: `--selftest-usage-log`, cases U1–U7 (P0-20e adds more).
- `Agent/RealtimeAgent.swift`: a per-turn `turnID` in `handle` (`:225`); `provider=… model=…` appended to the
  `replyTrace` note (`:244`); "Answered by <model>" in the audit reply detail; the `.localModel` stream (`:658-680`).
- `Agent/RealtimeAgent+ToolLoop.swift`: wrap the first pass (private `runModelTurn` @ `:372`, streams at `:434`,
  `:438`), every planner round (private `runPlannedToolLoop` @ `:811`, streams at `:908-912`), and record each tool
  run at `AgentToolExecutor.run` (`:1020`) into the round's `toolsExecuted`.
- `Formatting/LLM/LocalVoiceFrontend.swift`: wrap the route and answer calls (`streamSplitDecision` @ `:483`).
- `Agent/VoiceConversationCoordinator.swift`: a voice `turnID` next to the `firstTokenTrace` start (`:425-426`).
- `Memory/MemoryReviewer.swift`: `ProviderMemoryReviewModel` (`:322`) gains `usageFeature` (default
  `.memoryReview`) and wraps its `complete`; `review` (`:598`, model call `:609`) adds `counts` (proposed, saved,
  skipped, refused).
- `Agent/Schedules/ScheduledRunner.swift`: the two `ProviderMemoryReviewModel(…)` constructions (`:531`, `:533`) pass
  `usageFeature: .agentRoutine` and the schedule id.
- `Knowledge/KnowledgeAsk.swift`: the stream at `:140` wrapped as `knowledge.ask`.
- `Agent/Backend/ACPAgentBackend.swift` (`submit` @ `:57`) and `Agent/Backend/CodexComputerUse.swift`
  (`route` @ `:184`): one `agent.handoff` row per hand-off (provider `acp`/`codex`, `totalMs`, outcome, `errorClass`).
- Providers report counts through `ModelPassRecorder.current?.report(…)`:
  `Formatting/LLM/NotesModelRuntime.swift` (`streamWhileScheduled`, `completeWhileScheduled`; prompt, reused and
  generated counts, `warm`/`loadMs` from `loadIfNeeded`), `Formatting/LLM/OpenRouterLLMProvider.swift` (stream end
  `usage`, `complete`), `Formatting/LLM/FoundationModelLLMProvider.swift`, `Formatting/LLM/OpenAICompatibleLLMProvider.swift`.
- `NextNotesApp.swift`: register `--selftest-usage-log` in `runRequestedSelfTest`; `AGENTS.md` flag list;
  `Scripts/acceptance.sh` INTEGRATION tier.
- `Agent/RealtimeAgentToolLoopSelfTest.swift`: one case (below).

**Read for context (do not change):**
- `Support/MetricsStore.swift:12-60`: the harness temp-directory pattern and the append-under-lock pattern to copy.
- `LatencyCorrelation` (`Support/LatencyTrace.swift:118-133`): the task-local pattern `ModelPassRecorder` copies.
- the FoundationModels SDK interface: `SystemLanguageModel.tokenCount(for:)` is available from macOS 26.4.
- `Agent/AgentAnswerBudget.swift` (P0-05, done): `readerContextTokens(for:)`, whose value can go in `counts["window"]`.

**Current behaviour:**
- `LatencySpan` has `id, name, pipeline, startedAt, endedAt, durationSeconds, process, note, correlation`; no model.
- Llama rows carry the note `app_llm` (`model.first_token`), plus `prompt_tokens=N` on `model.prefill`
  (`NotesModelRuntime.swift`, grep `prompt_tokens=`). OpenRouter decodes `usage.completion_tokens` only in `complete`;
  streams drop `usage`. Apple FM reports nothing. `AgentAuditLog` reply entries carry the text only.
- Tool executions are counted into `completedToolIDs` (`ToolLoop`, grep `completedToolIDs.append`) and nowhere
  persistent with their duration or failure class.

**Target behaviour:**
1. Every model call made for an Agent turn writes exactly one `UsageRecord` to `usage.jsonl`: the typed first pass
   (`agent.typed`, pass `answer`), each planner round (`agent.typed` / `agent.worker`, pass `planner`, `round`), the
   voice frontend route and answer (`agent.voice`, `frontend-route` / `frontend-answer`), each voice-worker round
   (`agent.worker`), each routine pass (`agent.routine`, `scheduleID`), each memory-review pass (`memory.review`),
   each Knowledge Ask answer (`knowledge.ask`), and each hand-off (`agent.handoff`).
2. A planner round's row lists the canonical ids it proposed (`toolsProposed`) and, for each call that ran, one
   `UsageToolRun` with `ok`, `ms` (execution only) and `errorClass`. The row is written after the round's calls have
   run or been refused, so one row carries both; `totalMs` still covers only the model pass.
3. All passes of one user turn share one `turnID`; typed passes carry `conversationID`; worker passes carry
   `workID`/`revision`.
4. `requestedRole` / `requestedModel` come from `ModelRoleStore` when a role chose the provider; when the provider
   that ran differs, `fallbackReason` says why.
5. Counts: llama exact (prompt, reused, generated); OpenRouter from its final stream `usage` (P0-17 decodes it; until
   P0-17 lands, `completionTokens` from `complete` only, and `countsEstimated = true` on streams); Apple FM with
   `SystemLanguageModel.default.tokenCount(for:)` when `#available(macOS 26.4, *)`, otherwise characters / 4 with
   `countsEstimated = true`; an OpenAI-compatible server's `usage` when present.
6. The typed `agent.transcript_to_first_token` note contains `provider=<id> model=<name>`, and the audit reply entry
   carries `detail: "Answered by <name>"` (the audit log is internal, so ids may appear there).
7. Writes never block the caller: `UsageLog.record` enqueues on a serial utility queue.

**Steps:**
1. `UsageLog`:
   ```swift
   final class UsageLog: @unchecked Sendable {
       static let shared = UsageLog(directory: SelfTest.isRunning
           ? FileManager.default.temporaryDirectory
               .appendingPathComponent("NextNotesSelfTest-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
           : AppIdentity.applicationSupportDirectory)
       static let fileName = "usage.jsonl", rotatedName = "usage.1.jsonl"
       static let defaultMaxBytes = 8 * 1_024 * 1_024
       static let defaultMaxAgeDays = 90
       init(directory: URL, maxBytes: Int = defaultMaxBytes, maxAgeDays: Int = defaultMaxAgeDays,
            now: @escaping @Sendable () -> Date = Date.init)
       func record(_ row: UsageRecord)            // async on `queue`; rotates before an append that would pass maxBytes
       func flush()                               // queue.sync {} — tests and terminate only
       func load(since: Date? = nil) -> [UsageRecord]   // both files, oldest first; skips undecodable lines and v > 1
       func clear()                               // deletes both files (on the queue)
       func compact()                             // drops rows older than maxAgeDays from usage.1.jsonl; called once at init
       static func sanitise(_ message: String) -> String
   }
   ```
   Append with `FileHandle` seek-to-end as `MetricsStore.appendLocked` does (`MetricsStore.swift:84-106`). Flush on
   `NSApplication.willTerminateNotification`.
2. `ModelPassRecorder` (the name is kept from the original P0-20 so P0-17 step 4 and P0-18 need no edit):
   ```swift
   final class ModelPassRecorder: @unchecked Sendable {        // NSLock inside
       @TaskLocal static var current: ModelPassRecorder?
       init(feature: UsageFeature, pass: String, provider: any LLMProvider, round: Int? = nil,
            ids: UsageCorrelation, requestedRole: ModelRole? = nil, log: UsageLog = .shared)
       func noteFirstToken()                                    // first call wins
       func noteLoad(warm: Bool, ms: Int?)
       func report(promptTokens: Int?, cachedTokens: Int?, completionTokens: Int?,
                   reasoningTokens: Int?, finishReason: String?, estimated: Bool)
       func report(openRouter usage: OpenRouterUsage?)          // P0-17's struct; a no-op overload until it exists
       func proposed(_ toolIDs: [String]); func executed(_ run: UsageToolRun)
       func fail(_ error: Error)                                // errorClass + sanitised message
       func finish(reason: String)                              // writes one row once; later calls ignored
   }
   ```
   Call-site pattern, the same as `LatencyCorrelation`: an unstructured `Task { }` created inside
   `streamConversation` inherits the task-local, so a provider can report when its stream ends.
   ```swift
   let recorder = ModelPassRecorder(feature: .agentTyped, pass: "answer", provider: provider, ids: ids, requestedRole: .agent)
   let stream = await ModelPassRecorder.$current.withValue(recorder) { await provider.streamConversation(…) }
   for try await chunk in stream { recorder.noteFirstToken(); … }
   recorder.finish(reason: "stop")      // "cancelled" / "error" / "timeout" on those exits; "length" from P0-17's cutOff
   ```
3. `turnID`: `RealtimeAgent.handle` creates one UUID per call (`private(set) var currentTurnID`); the coordinator
   creates one per voice turn; the voice worker uses one per job revision.
4. Tool runs: in the planner's `execute` closure around `AgentToolExecutor.run` (`ToolLoop:1020`), time the call with
   `ContinuousClock` and call `recorder.executed(UsageToolRun(id: call.name, ok: …, ms: …, errorClass: …))` on each
   exit. For a write, `ms` excludes the time the approval card waited: record it only from the moment
   `AgentToolExecutor.run` returns control after approval (or measure the whole call and subtract the gate's wait if
   `PermissionGate` exposes it; say which in STATUS).
5. Providers report counts as in Target 5. Never block a stream on counting: count after the stream ends.
6. `RealtimeAgent`: append `provider=… model=…` to `replyTrace.end(note:)`; `AgentAuditLog.shared.record(kind: .reply, …)`
   gets `detail: "Answered by \(name)"`.
7. Register `--selftest-usage-log` (`UsageLogSelfTest.run() -> Bool`) next to `--selftest-metrics` in
   `NextNotesApp.runRequestedSelfTest`; add it to the AGENTS.md flag list and to `Scripts/acceptance.sh` INTEGRATION.

**Do not:**
- record prompt, reply, reasoning, transcript or dictated text, tool arguments or tool output, file names, addresses,
  subjects or URLs, anywhere in a row;
- write from a self-test to the real `usage.jsonl` (the harness store is temp; inject `UsageLog(directory:)` in tests;
  never bypass it);
- read `usage.jsonl` on the main actor or at launch (only compaction, on the writer queue);
- make a network call, or add any upload path;
- use `MainActor.assumeIsolated`;
- add a second "which model" field to `LatencySpan` (the original P0-20 design is superseded).

**Red-first self-test:**
- **New `--selftest-usage-log`** (`Support/Usage/UsageLogSelfTest.swift`), final marker
  `USAGE_LOG_OK: <n> cases` / `USAGE_LOG_FAILED: <n> problem(s)`, one `USAGE_LOG_WRONG: <case>: <reason>` line per
  failure, tier INTEGRATION. Every case uses `UsageLog(directory: <temp>/<case>)`.
  - **U1 round trip.** A row with every field filled writes and loads back field for field.
  - **U2 tolerance.** A line with an unknown key and missing optionals decodes; a line with `"v":2` is skipped; a
    corrupt line is skipped and the next line still loads.
  - **U3 rotation.** `maxBytes = 4_096`, write 40 rows of ~650 bytes: exactly two files exist, `usage.jsonl` holds the
    newest rows, `load()` returns rows in time order, and the oldest rows are gone.
  - **U4 age.** With `now` 100 days after half the rows' `ts`, `compact()` leaves only rows ≤ 90 days old.
  - **U5 clear.** `clear()` removes both files; `load()` is empty.
  - **U6 sanitiser.** `sanitise("Could not send \"Pricing Q3\" to marc@acme.com at https://x.y/z from /Users/s/a.txt
    ref 12345678")` contains none of `Pricing`, `marc@`, `https://`, `/Users/`, `12345678`, and is ≤ 160 characters.
  - **U7 isolation.** `UsageLog.shared.directory` is not `AppIdentity.applicationSupportDirectory` under the harness.
- **Extend `--selftest-toolloop-production`** (case **c**, replaces the original P0-20 case): give
  `ToolLoopTestProvider` `displayModelName = "Scripted Test Model"`. A typed turn that makes one planner round which
  calls one tool writes rows to `UsageLog.shared` (temp) with one `turnID`, `feature == "agent.typed"`,
  `provider == "llama"` (the test provider's id is `.appLLM`), `modelID == "Scripted Test Model"`, `totalMs > 0`,
  `ttftMs ≤ totalMs`, and the planner row's `toolsProposed == [<the tool>]` and `toolsExecuted.count == 1` with
  `ok == true`. While the typed first pass still exists (before P1-02), expect 2 rows (`answer`, `planner`); after
  P1-02, 1 row. The turn's `agent.transcript_to_first_token` note contains `model=Scripted Test Model`.
- **Confirm RED:** add the types, a `UsageLog` whose `record` does nothing, and a `ModelPassRecorder` whose `finish`
  writes nothing. U1, U3, U4, U5 and case c fail ("0 usage rows"). U2 and U6 fail until `load` and `sanitise` exist.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-usage-log
Scripts/run-selftest.sh --selftest-toolloop-production
Scripts/run-selftest.sh --selftest-metrics
Scripts/run-selftest.sh --selftest-memory-review
Scripts/run-selftest.sh --selftest-schedule
Scripts/run-selftest.sh --selftest-voice-conversation
Scripts/run-selftest.sh --selftest-voice-frontend        # _ABSENT is acceptable where it was in the baseline
Scripts/run-selftest.sh --selftest-openrouter-contract
Scripts/run-selftest.sh --selftest-store-isolation       # once P0-11 has landed
```
Owner smoke: type "Hi" in the Agent pane, then
`tail -2 ~/Library/Application\ Support/Next\ Notes/usage.jsonl`. The row names the Agent role's provider and model.

**Success threshold:**
- `USAGE_LOG_OK: 7 cases` and the toolloop-production case c pass (red first); `--selftest-metrics`,
  `--selftest-memory-review`, `--selftest-schedule` and `--selftest-voice-conversation` end as in the baseline
  (`TOOLLOOP_PRODUCTION` keeps its baseline reds that P1-03/P1-06 own; case c itself must pass).
- The owner's row has non-empty `feature`, `provider`, `modelID`, `locality`, `pass` and a numeric `totalMs`; on
  llama it carries prompt and completion counts.
- `grep -rn "ModelPassRecorder(" Sources/NextNotes` shows the first pass, the planner, the frontend, the worker, the
  routine/memory-review model, and Knowledge Ask; `grep -rn "agent.handoff\|agentHandoff" Sources/NextNotes` shows
  both hand-off sites.

**Risks & rollback:**
- One extra append per pass. It is queued off the caller; a crash can lose the last rows, which is acceptable for
  diagnostics.
- A row written for every Needle or dictation pass (P0-20b/c) is ~650 bytes; rotation bounds the total at ~16 MB.
- To roll back: remove the call-site wrappers; the file stops growing and nothing reads it at launch.

**Done when:**
- [ ] `usage.jsonl` rows for every Agent path, memory review, routines, Knowledge Ask and hand-offs.
- [ ] U1–U7 and case c green (red first).
- [ ] `--selftest-usage-log` registered in `NextNotesApp`, AGENTS.md and `Scripts/acceptance.sh` (INTEGRATION).
- [ ] The owner's smoke row is pasted into STATUS.
- [ ] Committed as `P0-20a: …`.

---

#### P0-20b — Usage rows for Meetings: transcription, speaker separation, notes, proposals, live proposals, Needle

**Finding(s):** owner request; H1 #25; H3 #3. **Effort:** 1 day. **Depends on:** P0-20a. **Unblocks:** P4-05, P4-10,
P0-20d, P0-20e, `roadmap/done/DICTATION-MEETINGS-LIMITS/`.

**Why (what the user experiences today):** six meetings on this Mac ended with no proposals and nothing says why
(H1 #25, H3 #3); a slow or failed notes pass leaves only an info log line (`NotesService.generate` logs
"notes for … tokens in …s", `Meetings/NotesService.swift:88-95`), which ages out.

**Files you will change:**
- `Meetings/ChunkedTranscriber.swift`: `transcribe(window:…)` (static, `:254`) reports each window to a new
  `MeetingTranscribeTally`; `flush()` (`:139`) writes the per-track row. `TranscriptionQueue.transcribe` (`:398`) reports
  its lane wait (`acquire(.realtimeASR)` at `:402`).
- new `Meetings/MeetingTranscribeTally.swift`: a small actor keyed by (meetingID, `AudioSource`).
- `Meetings/DiarizationService.swift`: `diarize(_:)` (`:91`) writes one `meeting.diarize` row on every exit.
- `Meetings/NotesGenerator.swift`: the single-pass `complete` (`:81`), each map `complete` (`:150`) and the reduce
  `complete` (`:181`) run inside a `ModelPassRecorder` (`meeting.notes.single` / `.map` / `.reduce`, `meetingID`).
- `Meetings/NotesService.swift`: `generate(for:segments:preferring:)` (`:43`) passes `requestedRole: .meetingNotes`
  (or `fallbackReason: "preferredOverride"` when `preferred` is set, `:53-58`); a "no provider" exit (`:60-69`) writes a
  row with `errorClass: "modelUnavailable"`.
- `Agent/MeetingAgent.swift`: `plan(…)` (`:194`, model call `:211`) wraps each round (`meeting.proposals` or
  `meeting.live`, `round`, `toolsProposed`); `fit(…)` (`:409`) failures write a row with `errorClass: "contextTooSmall"`
  and `counts["reserved"]`, `counts["budget"]`; `proposals(…)` (`:294`) adds `counts["proposed"]`, `counts["accepted"]`.
- `Agent/AgentService.swift`: `review(_:force:)` (`:197`) adds `counts["reconciledOut"]` (the `dropped` value) to the
  final row; `planLiveCandidatesIfNeeded` (`:596`, `liveProposals` call `:614`) does the same for `meeting.live`.
- `Agent/FunctionCalling/FunctionCallWatcher.swift`: `propose(_:window:)` (`:425`, `proposer.propose` `:449`) writes one
  `meeting.needle` row (provider `needle`, `totalMs`, `counts["calls"]`, `counts["carded"]`, `errorClass`).
- `Support/Usage/UsageLogSelfTest.swift`: cases M1–M5.

**Read for context (do not change):** `MeetingPipeline` (the order: transcript → diarization → notes → review);
`Meetings/MeetingNotesContextSelfTest.swift:407` (a scripted provider with `countTokens = text.count / 4 + 1` to reuse);
`AGENTS.md` "A meeting reaches Done minutes after you press Stop".

**Current behaviour:** no persistent per-pass record for any meeting stage. `ChunkedTranscriber.transcribe` logs
"<source> window Xs in Ys" at info level (`:276-281`) and nothing else; `MeetingAgent.plan` logs
`agent round N: K call(s)` at info level (`:218-222`); `AgentService.review` keeps `problems[id]` in memory only.

**Target behaviour:**
1. Per meeting and track, one `meeting.transcribe` row when the transcriber flushes: provider `parakeet`, `modelID`
   (the Parakeet model id the app logs; grep `ParakeetModels` for its version constant), `audioSeconds` (sum of
   transcribed windows), `totalMs` (sum of compute), `realtimeFactor`, `counts` `windows`, `silentSkipped`, `failed`,
   `stages["laneWait"]` (seconds waiting for `.realtimeASR`), `meetingID`, and `pass` = the `AudioSource` raw value
   (`microphone` / `system`).
2. One `meeting.diarize` row per diarization attempt: `audioSeconds`, `totalMs`, `counts["speakers"]`,
   `counts["runs"]`, `errorClass` on failure (`noAudio`, thrown errors via `UsageErrorClass.classify`), `warm: false`
   and `loadMs` when the diarizer models loaded in this pass.
3. Notes: one row per model call, as in Target 1 of P0-20a, with `meetingID`, `requestedRole: meetingNotes`,
   `counts["chunks"]`, `counts["facts"]` on the reduce row.
4. Proposals: one row per `MeetingAgent` round; the last round's row (or a zero-round row when `fit` threw) carries
   `counts` `proposed`, `accepted`, `reconciledOut`, `reserved`, `budget`, and `errorClass` when the pass failed. **A
   post-meeting pass that never reached the model still writes a row**, so "did it run?" always has an answer.
5. Needle: one `meeting.needle` row per `propose` call.

**Steps:**
1. `MeetingTranscribeTally` (actor): `note(meetingID:source:audioSeconds:computeSeconds:laneWait:outcome:)` and
   `drain(meetingID:source:) -> UsageRecord?`. `ChunkedTranscriber.transcribe` calls `note` on every exit (silent
   skip, success, failure); `flush()` calls `drain` and `UsageLog.shared.record`.
2. `TranscriptionQueue.transcribe`: measure the `acquire(.realtimeASR)` wait and return it with the result (add it
   to the tally via the caller; do not change the lane logic).
3. `DiarizationService.diarize`: build the row with a `defer`, so every `return false` path writes one.
4. `NotesGenerator`: wrap each `provider.complete` in `ModelPassRecorder.$current.withValue(…)`; pass the
   `meetingID` through `UsageCorrelation`.
5. `MeetingAgent.plan` and `fit`: as in Files; `fit` throwing must record before rethrowing.
6. `FunctionCallWatcher.propose`: time `proposer.propose`, count calls, record whether a card was presented.

**Do not:**
- record transcript text, speaker names, evidence quotes, proposal arguments or document titles;
- add a property to `Meeting` for this (the usage log is the store; `Meeting` fields need hand-written
  `decodeIfPresent` and are P4-10's business);
- block `ChunkedTranscriber.append` or the recording on a write (the tally is an actor; the write is queued);
- change any gate, round count or budget here (P4-05 and P4-10 read these rows first).

**Red-first self-test:** extend `--selftest-usage-log` (marker unchanged):
- **M1 single pass.** A scripted provider (window 32,768) and a 3-segment transcript through
  `NotesGenerator.notes(…)` write exactly one `meeting.notes.single` row with the fixture `meetingID`,
  `provider`, `completionTokens > 0` and `totalMs > 0`.
- **M2 map/reduce.** The same provider with `contextTokens = 1_024` and a 40-segment transcript writes N ≥ 2
  `meeting.notes.map` rows and one `meeting.notes.reduce` row, all with the same `meetingID`, and the reduce row has
  `counts["chunks"] == N`.
- **M3 no room.** `MeetingAgent.proposals(…)` with a scripted provider whose `contextTokens = 2_048` throws
  `contextTooSmall` and writes one `meeting.proposals` row with `errorClass == "contextTooSmall"` and
  `counts["reserved"]`, `counts["budget"]` present.
- **M4 transcribe tally.** Feed the tally three synthetic window outcomes (success 30 s/1.2 s, silent skip, failure)
  for one meeting and track; `drain` returns one row with `counts` `windows 3`, `silentSkipped 1`, `failed 1`,
  `audioSeconds 30`, and `realtimeFactor ≈ 0.04`.
- **M5 privacy.** Every row written by M1–M4 is scanned: no fixture transcript word of ≥ 5 letters appears in the
  encoded JSON.
- **Confirm RED:** add the tally and the call-site wrappers as no-ops; M1–M4 fail with "0 usage rows".

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-usage-log
Scripts/run-selftest.sh --selftest-notes-context
Scripts/run-selftest.sh --selftest-agent ~/Library/Caches/NextNotesBuild/agent-overhaul/fixture-meeting   # if the fixture dir exists; else record "not run"
Scripts/run-selftest.sh --selftest-function-calls
Scripts/run-selftest.sh --selftest-meeting-reconcile
Scripts/run-selftest.sh --selftest-stream
```

**Success threshold:** M1–M5 pass (red first); the regression flags end as in the baseline. Owner smoke after the
next real meeting: `grep -c '"feature":"meeting.' ~/Library/Application\ Support/Next\ Notes/usage.jsonl` ≥ 4
(two transcribe rows, one notes row, one proposals row), pasted into STATUS.

**Risks & rollback:** the tally holds a few numbers per active track; a crash mid-meeting loses that track's row.
Rollback: remove the wrappers.

**Done when:**
- [ ] Every meeting stage writes its row on every exit, including "never reached the model".
- [ ] M1–M5 green (red first).
- [ ] Owner smoke count pasted into STATUS.
- [ ] Committed as `P0-20b: …`.

---

#### P0-20c — Usage rows for Dictation: the speech engine, the cleanup pass, and the tail split, joined to `runs.jsonl`

**Finding(s):** owner request ("drain/transcribe/cleanup split already logged as 'dictation tail' — persist it").
**Effort:** 0.5 day. **Depends on:** P0-20a. **Unblocks:** P0-20d, P0-20e, `roadmap/done/DICTATION-MEETINGS-LIMITS/`.

**Why (what the user experiences today):** the split is logged at info level (`dictation tail · drain …`,
`Core/DictationController.swift:1073-1078`), which ages out within minutes (AGENTS.md), and recorded as `dictation.*`
spans in the 31-hour `metrics.jsonl` ring (`:957`, `:976-980`, `:1062-1072`, `:1104-1110`) with no link to the
dictation they belong to. `runs.jsonl` has one `processSeconds` per run and a `CleanupRecord`
(`Formatting/CleanupTrace.swift:186`) that says which cleanup engine ran and whether the guard accepted it, but no
timings per stage.

**Files you will change:**
- `Core/DictationController.swift`: in the tail task (`endDictation`, the `Task { @MainActor in` at `:938`),
  create `let runID = UUID()` before the drain; `recordRun` (`:1303-1321`) passes `id: runID` into `DictationRun`;
  after the cleanup split (`:1062-1072`) write one `dictation.asr` row and, when cleanup ran, one `dictation.cleanup`
  row, both with `dictationRunID = runID`. Add an injectable `usage: UsageLog = .shared` next to the `record:` seam
  (`:447`).
- `Support/Usage/UsageLogSelfTest.swift`: case D1 (pure row builder) and D2 (controller-level, see below).

**Read for context (do not change):** `DictationRun` (`Support/RunLog.swift:5`, `id` `:11`); `CleanupRecord`
(`engine`, `route`, `modelRan`, `sessionPrewarmed`, `guardVerdict`, `fallbackReason`, `chunks`); the existing
`--selftest-dictation` seams (`insert:`, `record:`) and AGENTS.md "A self-test must never call `RunLog.record`".

**Current behaviour:** see Why. `engineName` (`:358`, set at `:720`) is the speech engine's display name; the
key-down → capture span `keyDownToCaptureTrace` starts at `:711`.

**Target behaviour:**
1. Every dictation that reaches `recordRun` writes one `dictation.asr` row: `provider` (`parakeet` / `appleSpeech`),
   `modelID` (the engine id), `audioSeconds` (key held), `totalMs` (drain + transcribe), `stages` `drain`,
   `transcribe`, `names`, `cleanup`, `inject` (seconds, the same numbers the info line prints — never a second
   clock), `warm`/`loadMs` from the key-down → capture span when the engine was cold, `finishReason: "timeout"` and
   `truncated: true` when transcription hit its deadline, and `dictationRunID`.
2. When a cleanup pass ran, one `dictation.cleanup` row: `provider` from `CleanupRecord.engine` (`s1mini`, `appleFM`,
   `llama`, `rules`), `modelID`, `totalMs` (the cleanup stage), `finishReason` (`timeout` when `cleanupTimedOut`),
   `counts["chunks"]`, `warm` from `sessionPrewarmed`, `fallbackReason` from `CleanupRecord.fallbackReason` mapped to
   a `UsageFallback` class (never the free text), and `dictationRunID`.
3. `DictationRun.id` in `runs.jsonl` equals both rows' `dictationRunID`.
4. Compare mode writes rows with `pass: "compare"` per engine and no `dictationRunID` join guarantee (compare mode
   types nothing, AGENTS.md).

**Steps:**
1. `static func dictationRows(runID:engine:audioSeconds:drained:transcribedAt:narrowedAt:cleanedAt:injectSeconds:transcribed:cleanup:cleanupTimedOut:) -> [UsageRecord]`
   on an extension of `UsageRecord` (pure, testable).
2. Call it once after injection (so `inject` is known) and `usage.record` each row. Keep the existing
   `LatencyTrace.record` calls: `metrics.jsonl` stays the short-lived stage ring.
3. Pass `runID` into `recordRun` → `DictationRun(id: runID, …)`.

**Do not:**
- record the dictated text, the raw transcript, the target app's name or window title, or the cleanup's reasons text;
- add an unbounded await to the tail (the write is queued; AGENTS.md: every await in the tail has a deadline);
- call `RunLog.record` from a self-test (use the `record:` seam);
- time anything a second time; use the numbers the tail already has.

**Red-first self-test:**
- **D1 (in `--selftest-usage-log`).** `UsageRecord.dictationRows(…)` with fixed numbers returns two rows with the same
  `dictationRunID`, `stages` equal to the inputs (±0.001 s), and a `dictation.cleanup` `finishReason == "timeout"` when
  `cleanupTimedOut`.
- **D2 (extend `--selftest-dictation`, via-open in acceptance).** With its existing fake engine and the `record:` and
  `insert:` seams, plus `usage: UsageLog(directory: <temp>)`: one dictation writes exactly one `dictation.asr` row
  whose `dictationRunID` equals the `DictationRun.id` handed to `record:`, and whose `stages` keys are
  `drain`, `transcribe`, `names`, `cleanup`, `inject`. The marker stays `DICTATION_OK` / its existing failure lines.
- **Confirm RED:** add `dictationRows` returning `[]` and the `usage:` seam; D1 and D2 fail.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-usage-log
Scripts/run-selftest.sh --via-open --selftest-dictation     # TCC-sensitive; run once, never in a loop
Scripts/run-selftest.sh --selftest-cleanup-router
make test
```

**Success threshold:** D1 and D2 pass (red first); `DICTATION_OK` otherwise unchanged; `make test` passes. Owner smoke:
dictate once, then `tail -2 ~/Library/Application\ Support/Next\ Notes/usage.jsonl` shows `dictation.asr` (and
`dictation.cleanup` if cleanup is on) with the same `dictationRunID` as the newest `runs.jsonl` row's `id`.

**Risks & rollback:** none beyond one queued append per dictation. Rollback: remove the call.

**Done when:**
- [ ] Both rows written and joined to `runs.jsonl` by id.
- [ ] D1, D2 green (red first).
- [ ] Committed as `P0-20c: …`.

---

#### P0-20d — `--usage-report` and a Usage section in Settings ▸ Models

**Finding(s):** owner request. **Effort:** 1 day. **Depends on:** P0-20a (P0-20b and P0-20c make it complete).
**Unblocks:** P0-20e; every later model comparison (P1-01 baseline notes, P4-09, DICTATION-MEETINGS-LIMITS).

**Why (what the user experiences today):** there is no way to ask "how has the Agent's model been doing this week?"
except by grepping `metrics.jsonl`, which holds 31 hours.

**Files you will change:**
- new `Support/Usage/UsageSummary.swift`: the pure aggregation shared by the report and the view.
- new `Support/Usage/UsageReport.swift`: the `--usage-report` diagnostic.
- `NextNotesApp.swift`: in `applicationDidFinishLaunching`, next to `--notes-context-live` (`:212-214`), run
  `--usage-report` **before** `runRequestedSelfTest`, so `SelfTest.isRunning` stays false and the real
  `usage.jsonl` is read. It is a diagnostic, not a `--selftest-*` flag (the harness would read an empty temp store,
  the trap AGENTS.md documents for `--notes-context-live`).
- new `UI/Settings/UsageSection.swift`, shown in `UI/Settings/ModelsSettingsTab.swift` (the `Form` in `body`, after
  the installed-models sections).
- `UI/DesignSystem.swift`: tokens only if a new size is needed.

**Read for context (do not change):** `UI/Settings/MemoryDataControls.swift` (`DataControlsSection`, the pattern for
a destructive "clear" with confirmation); AGENTS.md "Design system" (no literal values, red only for recording,
status text in `DS.Color.success` / `.warning`); `--selftest-ui-strings` banned words.

**Current behaviour:** none.

**Target behaviour:**
1. `UsageSummary.compute(rows: [UsageRecord], since: Date) -> [UsageSummary.Row]`, one row per (feature, modelID):
   `n`, `ttftMs` p50/p90, `totalMs` p50/p90, `loadMs` p50 (cold passes only), `promptTokens` and `completionTokens`
   p50, `tokensPerSec` p50, error rate (rows with `errorClass` ÷ n), cut-off rate (`truncated`), fallback rate
   (`fallbackReason` present), tool success rate (Σ `toolsExecuted.ok` ÷ Σ `toolsExecuted`), and, for speech rows,
   `realtimeFactor` p50. Percentiles use nearest-rank on the non-nil values; a column with fewer than 3 values prints
   `-`.
2. `Scripts/run-selftest.sh --usage-report [--usage-days N] [--usage-feature <prefix>]` (defaults: 30 days, all
   features) prints `USAGE_REPORT_ROW feature=… model=… n=… ttft_p50=… ttft_p90=… total_p50=… total_p90=… load_p50=…
   prompt_p50=… completion_p50=… tps_p50=… error_rate=… cutoff_rate=… fallback_rate=… tool_ok_rate=… rtf_p50=…` per
   row, sorted by feature then n, then a final `USAGE_REPORT_OK rows=<n> files=<k> since=<date>`, or
   `USAGE_REPORT_EMPTY` when there are no rows (not a failure). `--selftest-out` captures it as for
   `--notes-context-live`.
3. **Settings ▸ Models ▸ "How your models have been doing"** (the last 7 days), three groups — Agent, Meetings,
   Dictation — one line per model: its name, how many times it ran, "first words after 1.2 s" (typical), "finished
   in 4.3 s" (typical), and "didn't work 2 of 40 times" only when above zero. A "Clear this history" button with a
   confirmation calls `UsageLog.shared.clear()`. The section loads rows off the main actor when it appears. It
   says nothing when there are no rows ("Nothing yet — this fills in as you use the app."). No developer words:
   never "token", "provider", "TTFT", "p90", "latency", "model pass", raw feature ids or schema keys.

**Steps:**
1. Write `UsageSummary` (pure; `Sendable` value types).
2. Write `UsageReport.run(arguments:) async -> [String]` that reads `UsageLog.shared.load(since:)` off the main actor
   and formats lines; wire it in `applicationDidFinishLaunching` with `writeSelfTest` for each line and
   `NSApp.terminate(nil)`, exactly as `runNotesContextLiveProbe` (`NextNotesApp.swift:2561`; grep `func runNotesContextLiveProbe`).
3. Write `UsageSection` with a `.task { rows = await Task.detached { UsageLog.shared.load(since:) }.value }`, group by
   feature prefix, map feature ids to plain group names in one table, format seconds with one decimal.
4. Add the section to `ModelsSettingsTab.body`.

**Do not:**
- make `--usage-report` a `--selftest-*` flag;
- read the file on the main actor;
- show developer words or raw ids in the section (`--selftest-ui-strings` must stay green);
- use literal colours, sizes or durations in the view; red is recording only;
- add an animating orb to Settings for this.

**Red-first self-test:** extend `--selftest-usage-log`:
- **R1 summary.** Twelve fixture rows for two (feature, model) pairs → two summary rows with exact n, p50 and p90
  (nearest-rank), error rate 1/6, tool ok rate 3/4, and `-` for a column with < 3 values.
- **R2 report format.** `UsageReport.lines(for:)` on the same fixture prints two `USAGE_REPORT_ROW` lines in the
  documented key order and ends `USAGE_REPORT_OK rows=12 files=1 since=…`; an empty fixture ends
  `USAGE_REPORT_EMPTY`.
- **R3 plain words.** The section's user-visible strings (exposed as `UsageSection.visibleStrings(for:)`) contain none
  of the banned words above; also run `--selftest-ui-strings`.
- **Confirm RED:** stubs returning `[]` fail R1 and R2.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-usage-log
Scripts/run-selftest.sh --selftest-ui-strings
Scripts/run-selftest.sh --selftest-settings
Scripts/run-selftest.sh --out /tmp/usage-report.txt --usage-report --usage-days 7
```

**Success threshold:** R1–R3 pass (red first); `--selftest-ui-strings` and `--selftest-settings` green; the owner runs
`--usage-report` on this Mac and pastes the rows into STATUS (after P0-20b/c have run for a day, at least one row per
feature group).

**Risks & rollback:** a 16 MB read when the section opens takes well under a second off the main actor (estimate);
the section shows only the last 7 days. Rollback: remove the section from `ModelsSettingsTab`; the report keeps
working.

**Done when:**
- [ ] `--usage-report` prints the table from the real file without the harness.
- [ ] The Settings section shows the three groups and clears on confirmation.
- [ ] R1–R3 green (red first); `--selftest-ui-strings` green.
- [ ] Committed as `P0-20d: …`.

---

#### P0-20e — `--selftest-usage-log` exit cases: end to end, privacy, isolation, registration

**Finding(s):** owner request. **Effort:** 0.5 day. **Depends on:** P0-20a–d. **Unblocks:** P0-12 (AGENTS.md
documents the log), the Phase 0 gate.

**Why (what the user experiences today):** each subtask tests its own rows; nothing yet proves that one run across all
three features leaves a complete, private, isolated log.

**Files you will change:** `Support/Usage/UsageLogSelfTest.swift` (cases E1–E4); `AGENTS.md` (one paragraph under
the self-test list: what `usage.jsonl` is, that it is local only, how to read it with `--usage-report`, and that
self-tests write it to a temp directory); `Scripts/acceptance.sh` (confirm the INTEGRATION entry from P0-20a).

**Read for context (do not change):** P0-11's `--selftest-store-isolation` (the before/after file check to extend).

**Current behaviour:** U1–U7, M1–M5, D1, R1–R3 exist.

**Target behaviour:** one flag answers "does every feature write a correct, private row, and never into the user's
file?"

**Steps:**
1. **E1 end to end.** In one isolated `UsageLog`: a scripted typed turn with one tool (P0-20a path), a scripted notes
   single pass (P0-20b), and `dictationRows` (P0-20c) → rows for `agent.typed`, `meeting.notes.single` and
   `dictation.asr`, each with its correlation id, and `UsageSummary.compute` returns one row per feature.
2. **E2 privacy scan.** Every row from E1 plus M1–M5 and D1, encoded, contains none of the fixture's prompt words,
   transcript words, tool argument values, e-mail addresses or file paths (a list of 12 sentinel strings planted in
   the fixtures).
3. **E3 isolation.** Record the size and modification date of the real
   `~/Library/Application Support/Next Notes/usage.jsonl` (or its absence) before the run; after the whole flag it is
   unchanged. Add the file to P0-11's `--selftest-store-isolation` list if P0-11 has landed.
4. **E4 schema lock.** The set of `UsageRecord` coding keys equals the documented list in this task (a static array
   in the test); adding a field without updating the roadmap and AGENTS.md fails.
5. AGENTS.md paragraph and flag list entry; acceptance entry `"selftest-usage-log|300"` in INTEGRATION.

**Do not:** weaken E2's sentinel list; special-case `SelfTest.isRunning` in production code beyond the existing
`UsageLog.shared` directory choice; print `_OK` when a feature's row is missing.

**Red-first self-test:** E1–E4 in `--selftest-usage-log`. **Confirm RED:** write E3 and E4 first; E4 fails until the
key list matches, and E1 fails if any subtask's call site is missing (run it before the last subtask is committed).

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-usage-log
Scripts/run-selftest.sh --selftest-store-isolation     # once P0-11 has landed
make acceptance TIER=core
```

**Success threshold:** `USAGE_LOG_OK: <n> cases` with n = 7 (a) + 5 (b) + 1 (c) + 3 (d) + 4 (e) = 20; the real
`usage.jsonl` unchanged by the run; `make acceptance TIER=core` no regression.

**Risks & rollback:** E4 makes schema changes deliberate; that is the point. Rollback: none needed (test only).

**Done when:**
- [ ] E1–E4 green; `USAGE_LOG_OK: 20 cases`.
- [ ] AGENTS.md paragraph and flag entry; acceptance entry present.
- [ ] Committed as `P0-20e: …`.

---

### P0-12 — Correct the stale facts in AGENTS.md and add the new traps

**Finding(s):** Decision document §6, F, G. **Effort:** 2–3 h. **Depends on:** P0-13, P0-14, and
P0-17–P0-20 (it documents them). Do this last in Phase 0. **Unblocks:** nothing.

**Why (what the user experiences today):** AGENTS.md is the first thing every agent reads, and
four statements in it are now false. Each false statement costs the next agent a wrong
diagnosis. B, for example, sent readers to "gws has no credentials" when it is signed in.

**Files you will change:** `AGENTS.md` only.
**Read for context (do not change):** the decision document §6, and F.

**Current behaviour (verified line numbers):**
1. `AGENTS.md:1237-1239`: "**Every Workspace write.** `gws auth status` reports no credentials,
   so no proposal has ever been approved…". gws **is** signed in (a refresh token, 21 scopes
   including Gmail, Calendar, Drive and Docs, per D §0). Writes are still unproven.
2. `AGENTS.md:401-410`: "In the realtime tool loop, an alias is checked against the allowlist
   before the registry resolves it … `RealtimeAgent+ToolLoop.swift:796`". The source now
   resolves first (`ToolLoop:960-967`: "Resolve first: a model may emit a registered alias…").
   A miss still abandons the turn with "The tool planner requested an unavailable tool".
3. `AGENTS.md:1292-1293`: "its background warmup must not acquire the same priority as the
   conversational frontend". This was violated at `NotesModelRuntime.swift:326` until P0-06.
   After P0-06 it is true again; add a pointer to `prewarmWorkClass`.
4. `AGENTS.md:1229-1232`: "every notes and agent run so far has gone through Apple Foundation
   Models instead". This is false: `metrics.jsonl` shows installed GGUFs loading for agent turns
   on 09-22 and 09-23.

**Target behaviour:** The four statements are corrected, and the new traps from this phase are
documented in the "Things that look like bugs" style: short, with the measured evidence.

**Steps:**
1. Rewrite item 1. gws is signed in on the development Mac, so reads run. No write proposal has
   been approved yet.
2. Rewrite item 2 to match the current order (resolve, then allowlist), and keep the "a miss
   abandons the turn" half until P1-04 changes it.
3. Update item 3 to point at `NotesModelRuntime.prewarmWorkClass` and `--selftest-voice-scheduling`.
4. Rewrite item 4. Installed GGUFs (Qwen3.5-4B, MiniCPM5-2B and others) answered agent turns on
   09-22 and 09-23. Gemma 4 E4B itself has never been downloaded.
5. Add the new traps:
   - **"A GGUF can be valid and still unopenable."** The architecture must be in
     `LlamaArchitectures.supported`, which is generated from the pinned llama.cpp tag by
     `Scripts/gen-llama-architectures.sh`. K2-Horizon (`k2-horizon`) was the example. The probe is
     vocab-only and never loads weights.
   - **"Provider resolution is read-only, and the switch is awaited."** Describe the 2026-09-23
     double-resolution bug in two sentences, and point at `--selftest-model-unopenable`.
   - **"`--selftest-llm-metal` used to prove nothing about the Agent."** It loaded S1-mini. It
     now has an agent-role leg.
   - **"The download verify decodes, and runs before the switch."** Name `NotesModelRuntime.trial`.
   - **"A reasoning model spends its answer allowance thinking."** OpenRouter ling-3.0 used 105 of
     112 completion tokens on reasoning and ended `finish_reason: length` (G O5). Point at
     `OpenRouterReasoningPolicy` and `--selftest-openrouter-contract` (P0-17).
   - **"The llama runtime reuses the prompt prefix; anything that changes the KV contents must
     reset `kvTokens`."** Name `PrefixReuse`, the reset points and `--selftest-llm-prefix-cache`
     (P0-18). Also correct the `voiceRoutingSystem` comment (`ToolLoop:492-493`), which is true only
     after P0-18.
   - **"Model calls use `PrivateURLSession`."** `URLSession.shared` wrote a full OpenRouter stream,
     reasoning included, into `~/Library/Caches/ai.pivotstudio.nextnotes/Cache.db` (G N4, P0-19).
   - **"`usage.jsonl` says which model or engine ran, and how it went."** One row per model or engine pass
     for the Agent, Meetings and Dictation (P0-20a–e), read with `--usage-report`; local only, rotated at 8 MB,
     temp under the harness. Read that before reverse-engineering from CFNetwork logs, as G had to. (H-audit
     2026-09-24: replaces the `agent.model_pass` wording.)
   - **"MiniCPM5's tool delimiters are control tokens."** `special = false` erased them (G N3,
     P0-04's `minicpm5` row).
6. Add `--selftest-model-unopenable`, `--selftest-chat-template`, `--selftest-store-isolation`,
   `--selftest-agent-answers`, `--selftest-llm-prefix-cache` and `--selftest-private-network` to the
   flag list, if the earlier tasks did not.

**Do not:** rewrite unrelated sections, or remove the history in existing entries (they record
measurements). Keep the house style: plain English and measured numbers.

**Red-first self-test:** none. This is documentation. The check is a grep:
```bash
! grep -n "reports no credentials" AGENTS.md
! grep -n "every\s*notes and agent run so far has gone through Apple Foundation" AGENTS.md
grep -n "selftest-model-unopenable" AGENTS.md && grep -n "selftest-chat-template" AGENTS.md
grep -n "LlamaArchitectures" AGENTS.md
grep -n "PrivateURLSession" AGENTS.md && grep -n "usage.jsonl" AGENTS.md && grep -n "selftest-llm-prefix-cache" AGENTS.md
```
Also run `Scripts/acceptance.sh --dry-run`. Its pre-flight fails if a listed flag is not in
`NextNotesApp.swift`.

**Verify:** the grep lines above, then `make acceptance --dry-run`.

**Success threshold:** every grep behaves as shown, and the dry run lists the new flags without
errors.

**Risks & rollback:** None. Revert to roll back.

**Done when:**
- [ ] The four facts are corrected.
- [ ] Four traps are added, plus the five from P0-04 (MiniCPM5) and P0-17–P0-20.
- [ ] The flag list is complete.
- [ ] Committed as `P0-12: …`.

---

### P0-16 — (Decide by evidence) Support `k2-horizon`

**Finding(s):** F R1 and R6. **Effort:** 1 h to decide (done below). The implementation would
be 1–2 days if upstream ever adds the architecture. **Depends on:** P0-13 (the list regenerates
from the tag). **Unblocks:** nothing.

**Why (what the user experiences today):** The owner downloaded K2-Horizon-4B (3.16 GB) and the
Agent role named it; every tool turn then failed with "The model could not be loaded." (F).
This task decides whether the app should learn to open that architecture.

**Current behaviour:** the linked llama.cpp b10621 has no `k2-horizon` architecture, so
`llama_model_load_from_file` returns nil (see Evidence below and P0-13).

**Target behaviour:** a recorded, dated decision in `STATUS.md`. No source change while the
decision is "won't do".

**Decision as of 2026-09-23: WON'T DO unless upstream llama.cpp adds `k2-horizon`.**

**Evidence** (checked 2026-09-23 ~22:15Z):
- b10621's `src/llama-arch.cpp` has no `k2-horizon` (148 rows; the closest are `kimi-linear`
  and `kimi-k3`, which are different models).
- Upstream **master** `src/llama-arch.cpp` (fetched from
  `raw.githubusercontent.com/ggml-org/llama.cpp/master/src/llama-arch.cpp`) has no `horizon`,
  and no `ifm` string either. The latest release tags on 2026-09-23 are `b11149` and `v0.5.0`.
- The upstream issue **#28361** "Eval bug: K2-Horizon models fail to load" (opened 2026-09-04)
  is **open**, with the error `unknown model architecture: 'k2-horizon'`.
- A comment quotes the model card: support exists only in the MBZUAI-IFM **fork**
  (`github.com/MBZUAI-IFM/llama.cpp`, branch `model/K2Horizon`, last commit 2026-09-17).
- No upstream pull request mentions K2-Horizon (GitHub search, `is:pr`).
- The model also needs its own pre-tokenizer (`tokenizer.ggml.pre = k2-horizon`, also unknown to
  b10621), a group-norm attention key, and an `<|ifm|im_start|>` template family (F §Evidence).

A fork build is out of scope. This repo links the **official** signed XCFramework
(`Package.swift:15-19`, `.binaryTarget(name: "LlamaFramework", url: ".../releases/download/b10621/llama-b10621-xcframework.zip", checksum: "ea50…")`).
Building, signing and shipping a fork's framework is a separate project with its own licence
and maintenance cost.

**Steps (now):** re-run the two commands under **Verify**; if the architecture is still absent,
write the decision line in `STATUS.md` and stop.

**Do not:** build or link a fork's framework; hand-edit `LlamaArchitectures.swift`; bump the
`LlamaFramework` tag as a side effect of any other task; delete P0-13's Case F assertion.

**If upstream adds it later**, this is the procedure. Record it as a new task when it happens.

1. Find the first release tag whose `src/llama-arch.cpp` contains the architecture:
   `curl -fsSL https://raw.githubusercontent.com/ggml-org/llama.cpp/<tag>/src/llama-arch.cpp | grep -n k2-horizon`.
2. Download `https://github.com/ggml-org/llama.cpp/releases/download/<tag>/llama-<tag>-xcframework.zip`.
   Compute the checksum with `swift package compute-checksum <zip>`, and update `Package.swift`'s
   URL and checksum.
3. Run `make build` (expect API drift; `llama.h` changes between tags). Then run
   `Scripts/gen-llama-architectures.sh` and commit the regenerated `LlamaArchitectures.swift`.
4. Add a `k2` family to P0-04's `ChatTemplate`: markers `<|ifm|im_start|>` and
   `<|ifm|im_end|>`, thinking `<ifm|think>`, tool calls `<ifm|tool_call>`. Read the exact
   template from the GGUF.
5. Re-run `--selftest-llm-metal`, `--selftest-chat-template`, `--selftest-model-unopenable`,
   `--selftest-cleanup-structure` (S1-mini on the new llama), `--selftest-function-calls`,
   `--selftest-embed` (embeddinggemma), and `make acceptance TIER=core`.
6. Update `THIRD-PARTY-NOTICES.md` if the llama.cpp licence text changed (MIT today).

**Files you will change (now):** none. Record the decision in `STATUS.md` ("won't do: upstream
lacks k2-horizon, issue #28361 open"), with the check date.

**Red-first self-test:** none now. P0-13's `--selftest-model-unopenable` Case F already pins
that `k2-horizon` is not supported. That assertion must be **updated, not deleted**, if the
dependency is ever bumped.

**Verify:** re-run the evidence commands when this task is revisited:
```bash
curl -fsSL https://raw.githubusercontent.com/ggml-org/llama.cpp/master/src/llama-arch.cpp | grep -n -i horizon || echo "still absent upstream"
curl -fsSL https://api.github.com/repos/ggml-org/llama.cpp/issues/28361 | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['state'])"
```

**Success threshold:** the decision is recorded with the date and evidence.

**Risks & rollback:** n/a.

**Done when:**
- [ ] The decision is recorded in `STATUS.md` (state `done`, evidence "upstream lacks k2-horizon; #28361 open", with the date).

---

### P0-21 — One default for the knowledge index, and the Agent's knowledge tools on by default

**Finding(s):** H1 #11, #12; H3 #1, #2 (H-audit 2026-09-23; the two audits found the same split independently).
**Effort:** 3 h. **Depends on:** none. **Unblocks:** P1-01 (cases K01–K03 and Y02 need the knowledge tools on a
fresh install), P1-03 (its manifest derives knowledge availability from these two switches), P1-17.

**Why (what the user experiences today):**
- Commit `5b16b2c` switched the knowledge index on by default, and AGENTS.md says so ("The knowledge index is on by
  default"). Only the struct changed. `KnowledgeIndexSettings.fromDefaults` says **on**; `Settings.knowledgeIndexEnabled`
  still says **off**. The indexer reads the struct, and everything a person or the Agent sees reads `Settings`.
- So on a fresh install the indexer quietly builds `knowledge.sqlite`, but the sidebar hides Search
  (`UI/Sidebar.swift:108`), the Search screen offers "Turn on the knowledge index"
  (`UI/Knowledge/KnowledgeSearchView.swift:48`, `:71`), the Settings toggle reads off
  (`UI/Settings/KnowledgeSection.swift:24`), and `KnowledgeToolGate.isAvailable` is false, so the planner and
  `MeetingAgent` are never shown `search_knowledge`, `expand_node` or `timeline`.
- Even with the index fixed, `knowledgeAgentToolsEnabled` defaults to false, so a fresh install answers "I cannot
  access past meetings" (B/T7) about the user's own indexed meetings. The tools are reads over the user's own data;
  cloud readers are already limited by `knowledgeGraphCloudConsent`, which stays off.
- Not visible on this Mac, where both keys were set to 1 by hand (H3 fact 2), which is why nothing caught it:
  `--selftest-index` pins only the struct's default (`KnowledgeIndexSelfTest.swift:251`).

**Files you will change:**
- `Knowledge/KnowledgeIndexer.swift`: `KnowledgeIndexSettings` (`:5-41`) gains
  `nonisolated static let defaultEnabled = true` and `static func fromDefaults(_ defaults: UserDefaults) -> KnowledgeIndexSettings`
  (the existing `fromDefaults` property forwards `.standard`); fix the stale "**Off by default**" comment on the indexer
  (`:131`).
- `Knowledge/KnowledgeTools.swift`: `KnowledgeToolGate` (`:18-41`) gains `nonisolated static let defaultEnabled = true`.
- `Support/Settings.swift`: `init` lines `:1078` (`knowledgeIndexEnabled … ?? false`) and `:1083`
  (`knowledgeAgentToolsEnabled … ?? false`) read the two constants through two new pure functions
  `nonisolated static func initialKnowledgeIndexEnabled(from: UserDefaults) -> Bool` and
  `initialKnowledgeAgentToolsEnabled(from:)`; fix the stale doc comment "Off by default." (`:705-706`).
- `Knowledge/KnowledgeIndexSelfTest.swift`: the cases below.

**Read for context (do not change):** `KnowledgeToolGate.isAvailable` / `mayRun` (`KnowledgeTools.swift:24-41`;
P1-17 changes the `lookThingsUp` term, not this task); `KnowledgeGraphScope` and `knowledgeGraphCloudConsent`
(unchanged: a cloud reader still sees only `search_knowledge` without graph consent); AGENTS.md "The knowledge index
is on by default, and a fixture that wants it off says so."

**Current behaviour:**
```swift
// Support/Settings.swift:1078, :1083
knowledgeIndexEnabled = defaults.object(forKey: Keys.knowledgeIndexEnabled) as? Bool ?? false
knowledgeAgentToolsEnabled = defaults.object(forKey: Keys.knowledgeAgentToolsEnabled) as? Bool ?? false
// Knowledge/KnowledgeIndexer.swift:34
enabled: defaults.object(forKey: enabledKey) as? Bool ?? true,
```

**Target behaviour:**
1. With the keys absent, `Settings.knowledgeIndexEnabled == KnowledgeIndexSettings.fromDefaults.enabled == true`,
   read from one constant.
2. With the key absent, `Settings.knowledgeAgentToolsEnabled == true`. It still has effect only while the index is on
   (`KnowledgeToolGate` requires both).
3. An explicit stored `false` stays `false` for either key (a person who switched it off keeps it off).
4. Cloud graph consent, the graph, dictation and routine indexing and the embedder keep their off defaults.

**Steps:**
1. Add the two constants and the `fromDefaults(_:)` overload.
2. Add the two pure `initial…(from:)` functions to `Settings` and call them from `init` with `defaults`.
3. Fix the two stale comments.
4. Search for any other `?? false` read of these keys: `grep -rn "knowledgeIndexEnabled\|knowledgeAgentToolsEnabled" Sources/NextNotes | grep "??"`;
   route each through the constants.

**Do not:**
- change the cloud graph consent, the graph switch or the embedder default (consent and measured reasons, AGENTS.md);
- write to `UserDefaults.standard` from the self-test: use a throwaway suite `UserDefaults(suiteName: "NextNotesSelfTest-\(pid)")`
  and `removePersistentDomain(forName:)` it afterwards;
- flip the harness's isolated index on: `--selftest-*` still passes `KnowledgeIndexSettings(enabled: false)` where a
  fixture wants it off (AGENTS.md).

**Red-first self-test:** extend `--selftest-index` (`KnowledgeIndexSelfTest.run`, marker `INDEX_OK` / `INDEX_FAILED`,
one `INDEX_WRONG:` line per failure):
- **a.** With an empty suite: `Settings.initialKnowledgeIndexEnabled(from: suite) == KnowledgeIndexSettings.fromDefaults(suite).enabled`
  and both are `true`.
- **b.** With an empty suite: `Settings.initialKnowledgeAgentToolsEnabled(from: suite) == true`.
- **c.** With both keys stored `false` in the suite: both functions return `false`.
- **d.** `KnowledgeToolGate.isAvailable(indexEnabled: true, toolsEnabled: Settings.initialKnowledgeAgentToolsEnabled(from: emptySuite), lookThingsUp: true) == true`.
- **Confirm RED:** add the two functions with today's `?? false` bodies; a, b and d fail.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-index
Scripts/run-selftest.sh --selftest-search
Scripts/run-selftest.sh --selftest-ask
Scripts/run-selftest.sh --selftest-settings
Scripts/run-selftest.sh --selftest-store-isolation     # once P0-11 has landed
```

**Success threshold:** cases a–d pass (red first); `--selftest-search`, `--selftest-ask` and `--selftest-settings` end
as in the baseline; `defaults read ai.pivotstudio.nextnotes knowledgeIndexEnabled` on this Mac is unchanged by the run.

**Risks & rollback:** existing installs where the key was never written now show Search and give the Agent the three
read tools. That is the documented product default. Rollback: set the two constants to `false`.

**Done when:**
- [ ] One constant per switch; both readers use it.
- [ ] Cases a–d green (red first); stale comments fixed.
- [ ] Committed as `P0-21: …`.

---

### P0-22 — Multi-step notices name the model that actually answers and promise no durations

**Finding(s):** H1 #13 (H-audit 2026-09-23). **Effort:** 3 h. **Depends on:** none (soft: P0-14, one provider per
turn). **Unblocks:** P4-09 (which later changes the consent this notice used to read).

**Why (what the user experiences today):**
- On this Mac (M, H1): `modelRoles.agent = cloud` (OpenRouter), `knowledgeGraphCloudConsent` unset. A typed
  "check my mail then summarise it" matches `MultiStepPlanRouting.likelyMultiStep` and routes `.localWithWarning`
  because the graph consent is off, so the reply starts "This needs a few steps, so **on this Mac it takes a few
  minutes**. I'll keep going here — or connect an online model to go faster." The plan then runs on OpenRouter.
- On a genuinely local model "a few minutes" contradicts the 18 s plan budget that ends the plan first
  (`ToolLoop` `runPlannedToolLoop`, `.seconds(18)`).
- The cloud notice says "Using X online — **slower**". The measured cloud model is the fastest path on this Mac:
  0.8 s to first byte, 250 tok/s (G).

**Files you will change:**
- `Agent/RealtimeAgent+ToolLoop.swift`: the public `runPlannedToolLoop(_:speech:voice:)` (grep
  `func runPlannedToolLoop(`; the notice block is the `let route = ModelRoleStore.multiStepRoute(…)` … `switch route`
  lines just before `let provider: any LLMProvider`): compute the notice **after** the provider is resolved.
- `Support/ModelRoles/ModelRoleStore.swift`: `MultiStepNotices` (`:809-829`, `slowWarningIfNeeded` `:813`,
  `cloudNotice` `:823`) replaced by one function; `ModelRoleStore.slowWarningIfNeeded` / `cloudSlowNotice` wrappers
  (`:843-845`) removed or forwarded.
- `Support/ModelRoles/ModelRoleSelfTest.swift`: `multiStepRoutesToCloud()` (`:48`) gains the notice table.

**Read for context (do not change):** `MultiStepPlanRouting.route` (`ModelRoleStore.swift:767-805`), which P4-09
re-bases on its own consent; `AgentModelRouting.provider(for:voice:)`; P0-14 (one provider per turn).

**Current behaviour:** the notice is chosen from `MultiStepPlanRouting.route(for:role:cloudReady:cloudConsent:)` with
`cloudConsent: Settings.shared.knowledgeGraphCloudConsent`, before and independently of the provider that is then
resolved by `AgentModelRouting.provider(for:voice:)`. Its two sentences:
```swift
"This needs a few steps, so on this Mac it takes a few minutes. " + "I'll keep going here — or connect an online model to go faster."
"Using \(name) online — slower, and it leaves this Mac. " + "I'll keep the steps on screen as I go."
```

**Target behaviour:**
1. The notice is a pure function of the provider that will actually answer:
   `MultiStepNotices.notice(providerID: LLMProviderID, modelName: String, likelyMultiStep: Bool, voice: Bool) -> String?`
   - `.openRouter` (any request, typed only): "Using \(modelName) online; this leaves your Mac." — **once per
     session**, whether or not the request is multi-step.
   - `.appLLM` / `.appleFoundation` / `.localServer` with `likelyMultiStep`: "This takes a few steps on this Mac." —
     once per session.
   - Anything else, or voice: `nil`. (Voice stays on this Mac today; the spoken path never carries this notice.)
2. No notice mentions minutes, seconds, "slower" or "faster".
3. The route function stays for P4-09, but the notice no longer reads `knowledgeGraphCloudConsent`.

**Steps:**
1. Replace `MultiStepNotices`' two functions with `notice(…)` and two `static var` "said this session" flags; reset
   both in `resetForTesting()` and when `AgentSession` rotates its `sessionID` (grep `endSession` in
   `RealtimeAgent.swift`).
2. In `runPlannedToolLoop`, move the notice computation below the `let provider` resolution and pass
   `provider.id`, `provider.displayModelName`, `ModelRoleStore.likelyMultiStep(requestForRanking)` and `voice`.
3. Delete the now-unused `cloudReady` / `cloudConsent` locals there if nothing else reads them.

**Do not:**
- promise a duration of any kind in a notice;
- put the Agent's name in the sentence (AGENTS.md: the name reaches prompts and replies only through
  `AgentGrounding`); the model's display name is fine;
- use developer words ("provider", "token", "OpenRouter" is a product name and allowed only because the picker shows
  it) — run `--selftest-ui-strings`;
- change routing or consent (P4-09 owns both).

**Red-first self-test:** extend `--selftest-model-roles` (`ModelRoleSelfTest`, marker `MODEL_ROLES_OK` /
`MODEL_ROLES_FAILED`):
- **a.** `notice(providerID: .openRouter, modelName: "Ling", likelyMultiStep: true, voice: false)` contains "Ling" and
  "online", and contains none of "minute", "slower", "faster".
- **b.** A second call in the same session returns `nil`.
- **c.** `notice(.appLLM, "Qwen3-4B", likelyMultiStep: true, voice: false) == "This takes a few steps on this Mac."`;
  with `likelyMultiStep: false` → `nil`.
- **d.** `voice: true` → `nil` for every provider.
- **Confirm RED:** add `notice` as a forwarder to today's `route`-based sentences; a, c fail on "slower"/"minutes".

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-model-roles
Scripts/run-selftest.sh --selftest-toolloop-production
Scripts/run-selftest.sh --selftest-ui-strings
```

**Success threshold:** cases a–d pass (red first); `--selftest-toolloop-production` shows no new failure beyond its
baseline reds. Owner smoke with the cloud Agent role: "check my mail then summarise it" starts "Using <model> online;
this leaves your Mac." and never says "minutes".

**Risks & rollback:** people on the cloud role now see one notice per session even for single-step requests. That is
the honest statement that their words leave the Mac. Rollback: revert.

**Done when:**
- [ ] The notice is derived from the answering provider; no duration words remain (`grep -n "few minutes\|slower" Sources/NextNotes/Support/ModelRoles/ModelRoleStore.swift` finds nothing).
- [ ] Cases a–d green (red first).
- [ ] Committed as `P0-22: …`.

---

### P0-23 — "That wasn't for you" ends the session and drops its turn

**Finding(s):** H2 V2 (H-audit 2026-09-23). **Effort:** 2 h. **Depends on:** none. **Unblocks:** P3-10 (the model-side
"not addressed to me" route builds on the same session-close path).

**Why (what the user experiences today):**
- The island's "That wasn't for you" button is telemetry only. The code says so: "Telemetry only — the card stays up
  until Done" (`UI/Island/IslandView.swift:436-446`, in the `.agentListening` case); the button calls `WakeWordTelemetry.shared.recordFalseAccept`
  and nothing else.
- Real session (H2, `agent-audit.jsonl`): at 23:59:19–23:59:24Z the user pressed it **six times in five seconds**
  (`wake.false reason=that-wasnt-for-you` ×6). The session kept listening and committed another turn ("Yeah.
  Yeah.") until Done at 23:59:27.
- The label promises the agent will stop treating the speech as addressed to it. The only control that does that
  today is Done.

**Files you will change:**
- `Activation/AgentCaptureController.swift`: `EndpointSource` (`:111-118`; lines in this file moved after P0-10, grep the symbol) gains `case disowned`; new
  `func disown() async`; `endSession(source:)` (`:358`) discards the in-flight turn for `.disowned` and shows its own
  closing line; a new static `disownSelfTestFailures()` beside `turnPolicySelfTestFailures()` (`:1948`).
- `UI/Island/IslandState.swift`: new `func disownAgentListen()` next to `endAgentListen()` (`:456`).
- `UI/Island/IslandView.swift`: the button (`:439`) calls `state.disownAgentListen()`; the "Telemetry only" comment is
  corrected.
- `NextNotesApp.swift`: add `disownSelfTestFailures()` to the `--selftest-voice-turns` block (grep
  `"--selftest-voice-turns"`).

**Read for context (do not change):** `VoiceConversationCoordinator.closeSession()` (`:244-257`; background objectives
keep their owners); `RealtimeAgent.discardVoiceInput()` (`Agent/RealtimeAgent.swift:67`); the discard branches in
`tick` (grep `RealtimeAgent.shared.discardVoiceInput()` in `AgentCaptureController.swift`);
`AgentCaptureController.overlappingBackchannelSelfTestFailures()` for the `beginSession(captureAudio: false)`,
`turnHandlerForTesting` and `simulateCumulativeSpeech` pattern.

**Current behaviour:**
```swift
// IslandView.swift:437-446
// The one place a wake that fired on the wrong speech can be disowned.
// Telemetry only — the card stays up until Done.
Button("That wasn\u{2019}t for you") {
    WakeWordTelemetry.shared.recordFalseAccept(
        keyword: WakeWordAudioMonitor.shared.lastDetection?.keyword ?? "unknown",
        reason: "that-wasnt-for-you")
}
```
`endSession(source:)` already closes the coordinator, clears the staged frontend turn, cancels `activeTurnTask`,
cancels a thinking response and stops audio, then shows `lastReply` (or "Stopped.") on the island (grep
`showAgentReply(source == .idle`).

**Target behaviour:**
1. The button records the telemetry once, then ends the session through `endSession(source: .disowned)`.
2. Nothing heard in this session after the press becomes a turn: the in-flight input is discarded
   (`RealtimeAgent.shared.discardVoiceInput()`, `LocalVoiceFrontend.shared.clearStagedTurn()`), a response still
   generating for the disowned turn is cancelled, and no user row is added to the conversation for it.
3. The island shows "Okay, I'll ignore that." instead of the last reply.
4. Background jobs keep running, exactly as on Done (the coordinator's `closeSession` already keeps them).
5. A repeated press while the session is already closed does nothing more than the first (telemetry is counted once
   per session).

**Steps:**
1. Add `case disowned` to `EndpointSource`.
2. `func disown() async`: `guard isSessionActive else { return }`; record the telemetry (the same call the button makes
   today); `await endSession(source: .disowned)`.
3. In `endSession(source:)`: when `source == .disowned`, call `RealtimeAgent.shared.discardVoiceInput()` and
   `RealtimeAgent.shared.cancel()` unconditionally (not only when `isThinking`), and choose
   `"Okay, I'll ignore that."` as the island line.
4. `IslandState.disownAgentListen()` → `Task { await AgentCaptureController.shared.disown() }`; the button calls it.
5. `disownSelfTestFailures()` as below; add it to `--selftest-voice-turns`.

**Do not:**
- cancel background work or the task list (only the conversation turn is disowned);
- add a deterministic suppression gate on transcript shape (AGENTS.md: on the conversational path a gate may only
  add); this is a person's explicit action, not a text rule;
- change the wake thresholds (AGENTS.md: the fix for false accepts is real-room recordings, not a lower bar);
- show red for this state (red means recording only), or use literal sizes in the island (DS tokens).

**Red-first self-test:** extend `--selftest-voice-turns` (marker `VOICE_TURNS_OK` / `VOICE_TURNS_FAILED`, one
`VOICE_TURNS_WRONG:` line per failure) with `disownSelfTestFailures()`:
- `await capture.endSession(source: .done)`; `await capture.beginSession(captureAudio: false)`; record turns through
  `turnHandlerForTesting`.
- `capture.simulateCumulativeSpeech("DJ Burger King is on the menu tonight")`, then `await capture.disown()`, then
  `capture.simulateCumulativeSpeech("Yeah. Yeah.")` and force a tick.
- Assert: `turns.isEmpty`; `capture.isSessionActive == false`; `capture.lastEndpoint == .disowned`;
  the island's current notice is `.agentReply("Okay, I'll ignore that.")` (`IslandState.showAgentReply` @ `UI/Island/IslandState.swift:395` pushes that kind; read it the way `--selftest-island` reads pushed notices).
- Call `disown()` again: no second telemetry increment (`WakeWordTelemetry.shared.falseAccepts`, `Activation/WakeWord/WakeWordTelemetry.swift:48`, unchanged).
- **Confirm RED:** add `disown()` with today's behaviour (telemetry only). The test fails: the session is still
  active and a turn is committed.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-voice-turns
Scripts/run-selftest.sh --selftest-island
Scripts/run-selftest.sh --selftest-voice-conversation
Scripts/run-selftest.sh --selftest-wake
Scripts/run-selftest.sh --selftest-ui-strings
```

**Success threshold:** the disown case passes (red first); `--selftest-island`, `--selftest-voice-conversation`,
`--selftest-wake` and `--selftest-ui-strings` end as in the baseline. Owner smoke: wake it, talk to someone else,
press the button once: the card closes within 1 s, says "Okay, I'll ignore that.", and nothing further is answered.

**Risks & rollback:** a person who pressed it by mistake has to wake the agent again. That is the cheaper error.
Rollback: point the button back at the telemetry call.

**Done when:**
- [ ] The button ends the session and drops the in-flight turn; background jobs survive.
- [ ] The case is green (red first).
- [ ] Committed as `P0-23: …`.
