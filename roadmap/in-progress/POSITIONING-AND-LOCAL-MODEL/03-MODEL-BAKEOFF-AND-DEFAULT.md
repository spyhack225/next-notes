# Model bake-off, the silent default, and the augmented winner (PL-02…PL-04)

Read `00-README.md` §4 and `02-FLOOR-BENCHMARK.md` first. SHARED-BRAIN SB-07 owns the
per-role recommendation; these tasks produce its evidence and then improve the winner.
AGENT-OVERHAUL owns the Agent quality bar; nothing here lowers it.

---

## PL-02 — Candidate bake-off on the floor machine

**Goal.** One table, on the floor machine, that says for each candidate and each role
(Agent, Dictation cleanup, Meeting notes) whether it passes speed, memory, disk and quality —
measured through the real code paths, not a separate inference script.

**Current state (verified 2026-10-04).**
- Candidates in code: `modelCompareCandidates` in `Sources/NextNotes/NextNotesApp.swift`
  lists MiniCPM5-2B (found by substring, its file is pinned nowhere), Qwen3-4B-Instruct-2507,
  Qwen3.5-4B and Gemma 4 E4B. All four files are on the owner's Mac. No code model is named
  anywhere in `Sources/` or the roadmaps.
- Agent evidence so far is the P1-31a paired diagnostic on this same Mac under shared load:
  ordinary fixed quick Qwen3-4B 5/10, MiniCPM5-2B 2/10, Gemma 4 E4B 5/10, Qwen3.5-4B 2/10;
  full Qwen3-4B 17/30 (`Tests/Reports/toolloop-live/2026-09-30-p1-31-investigation.md`).
  It recorded quality and per-turn timing, not decode tok/s under ASR load.
- Cleanup evidence: `Tests/Reports/MODEL-COMPARE-CLEANUP-2026-09-30.md` (MiniCPM 3/42 at
  0.59 s, Qwen3-4B 8/42, Qwen3.5-4B 11/42, Apple 0/42 at 3.03 s).
- Today's silent default for Agent and Meeting notes is `.builtIn`
  (`ModelRoleStore.defaultChoice`), which resolves to `NotesModels.spec` — Gemma 4 E4B,
  4.98 GB — the one candidate the app's own estimator predicts will miss the floor.

**Work.**
1. Name the code-model candidate in STATUS with a one-line reason and its exact artifact
   (repository, file, quantization, SHA-256). It must fit the 3.0 GB proposed artifact budget
   or be recorded as out of budget before any run. Fetch it through the existing library
   and downloader only, never by hand into the Models folder.
2. For every candidate run, on a clean floor run (02 §1): PL-01's `LLM_FLOOR` C0/C1 lines and
   one 10-minute sustained C1 run; `--selftest-toolloop-live --model <id> --quick`, then two
   full runs for any candidate whose quick result is within reach of the bar; PL-05's
   persona sets in the same process; `--selftest-cleanup app-llm-compare`; `--selftest-notes`
   on SB-07's meeting corpus once it exists; `--selftest-voice-latency` for C2 with the
   candidate on the Agent role.
3. Include Apple Foundation Models as the zero-download row in every quality table, and
   keep Needle-first as its own arm owned by AGENT-OVERHAUL P1-31 — the bake-off reports it,
   never decides it.
4. Write `Tests/Reports/floor/<date>-bakeoff.md`: one row per candidate × role with artifact
   identity, build, planner path (`--planner` if forced), command lines, conditions, every
   metric in 02 §3 and a pass/fail per threshold. Unavailable or timed-out runs are
   *incomplete*, never scores.

**Acceptance evidence.** The report exists with at least four GGUF candidates plus Apple on
all applicable roles, every row from a clean run (or labelled contended and excluded from
verdicts), and its conclusion states either the winner per role or "no candidate passes"
with the gap. SB-07's STATUS cites it. Owner's history, settings and Models folder are
unchanged except for an explicitly approved candidate download (`--selftest-store-isolation`
passes).

**Must not.** Change any corpus, grader, quick subset or threshold between candidates; run
two self-tests at once; pick a winner from C0 numbers; let a strong cleanup or notes score
stand in for a failed Agent gate; add model-specific provider branches to win a row.

## PL-03 — Pin the winner as the silent default

**Goal.** A fresh install gets the winning artifact with no choice shown: one plain progress
state, a size that fits a 256 GB Mac, and the same file reused by every role it passed.

**Depends on.** PL-02 naming a winner for at least one role; SHARED-BRAIN SB-01 (catalog and
verified identity), SB-04 (workload-local reuse and fallback) and SB-05 (onboarding resume);
MODULES-ACTIVATION MOD-08/MOD-09 for module-aware setup.

**Current state.** `.builtIn` means `NotesModels.spec` and `InstalledModelLibrary.builtInID`
(`Sources/NextNotes/Support/ModelRoles/ModelRoleStore.swift`, `Sources/NextNotes/Formatting/LLM/NotesModels.swift`).
`OnboardingBrainStep` (`Sources/NextNotes/UI/Onboarding/OnboardingSteps.swift`) downloads that
spec and checks room against `ModelDownloader.minimumFreeBytesAfterDownload` (4 GiB). The
Models tab and `ModelRoleSection` already offer choices; they stay as the advanced view.
Cleanup's MiniCPM choice and the owner's explicit `activeAgentModelID` switch are recorded in
`AGENTS.md` and must be preserved.

**Work.**
1. Express the winner as SB-01 catalog recommendation data per role (not a new store), with
   exact repository, file, quantization, bytes and SHA-256 — the same pinning standard
   `NotesModels.spec` already meets.
2. Point unset choices at it. Explicit stored choices, including the owner's, stay as they
   are; a person who never chose gets the recommendation.
3. Onboarding and resume fetch the union of enabled modules' artifacts (MOD-08/09) in one
   plain progress state, with no model name, size picker or file format on screen, and with
   Apple as the honest no-download fallback while bytes arrive (SB-04).
4. Disk: the default-path total meets 02 §4. If the winner for notes differs from the Agent
   winner, prefer the shared artifact when its notes score passes SB-07; a second resident
   model needs P3-07 floor evidence.

**Acceptance evidence.** Fresh-profile runs on the floor machine: granted, offline mid-download,
low disk (below artifact + reserve) and resume after quit each reach a working answer or one
plain next step; `--selftest-onboarding`, `--selftest-model-roles`, `--selftest-ui-strings`
and SB-08's `--selftest-shared-brain` (when it exists) pass; a before/after disk listing shows
the default-path total within budget; the owner's explicit choices are byte-identical after
upgrade.

**Must not.** Show a model picker, model name, file size choice or terminal step on the
default path; rewrite an explicit choice; add a download queue; delete a file another enabled
consumer, pending job or lease needs; ship a recommendation PL-02 did not support.

## PL-04 — Make the winner beat the stock model

**Goal.** The shipped model scores higher, answers faster, or both, than the same open weights
used stock — on the same floor benchmark and the same corpora.

**Depends on.** PL-02's winner and a recorded stock baseline for it.

**Current state (verified).** The levers exist but are unused or off:
- Native tool calling: GBNF grammar for the on-device runtime (`GBNFGrammar.swift`,
  `Agent/Planner/LlamaGrammarPlanner.swift`), off by default (`Settings.agentNativeToolCalling`)
  until three full runs score at least as well; `--planner native|prompt` forces a path for one
  eval process; `--selftest-native-tools` is currently red at 4/5 grammar-valid rounds
  (roadmap README).
- Prefix cache: `PrefixReuse.swift`, measured 2.10 s → 0.33 s prefill.
- Quantization: only Q4_K_M files are on disk; `ModelFitEstimator.quantizationPreferenceRank`
  already ranks quantizations.
- Speculative decoding: the pinned llama.cpp header (b10621) exposes
  `LLAMA_CONTEXT_TYPE_MTP` and `load_mtp`; the app treats MTP heads only as files to skip
  (`ModelFitEstimator.isAuxiliaryGGUF`, `NotesModelRuntime.trial`). No draft path exists.
- LoRA: the same header exposes `llama_adapter_lora_init` and `llama_set_adapters_lora`; the
  app calls neither.

**Work — one experiment at a time, each with its own report under `Tests/Reports/floor/`.**
1. **Prompting** within AGENT-OVERHAUL's rules (P4-03; one identity; no prompt-only fix for a
   producer bug). Rejected experiments stay recorded, as P1-31b's did.
2. **Native tools**: run the three full runs the flag's own rule requires on the winner and
   Apple; flip the default only if they pass.
3. **Quantization sweep** of the winner's own weights (for example Q4_0, IQ4_NL, Q4_K_M,
   Q5_K_M), each verified through the existing library trial; keep the smallest that holds
   quality and the fastest that holds the floor.
4. **Speculative decoding**: if the winner publishes an MTP head or a small same-tokenizer
   draft, implement drafting inside the existing `NotesModelRuntime` (no second runtime), keep
   the prefix-cache reset rules, and measure decode under C1/C2. Keep it only if p10 decode
   rises and no output changes under greedy decoding.
5. **LoRA fine-tune**: train an adapter on synthetic, privacy-safe data shaped like PL-05's
   persona tasks and the canonical tool calls (never the owner's mail, meetings or memory),
   load it through the existing runtime, verify bytes like any artifact, and evaluate on
   held-out cases only — never on the cases it was trained on. Training happens off the
   product path; the app only loads a verified adapter file.
6. Re-run the full floor and quality set on the combined result before it becomes the default.

**Acceptance evidence.** For each kept change: before/after reports on the same build family,
same corpora, same thresholds, showing improvement and no regression in any gated row; a
held-out split for any fine-tune; `--selftest-llm-prefix-cache`, `--selftest-chat-template`,
`--selftest-native-tools`, `--selftest-model-unopenable` and `--selftest-toolloop-live-grader`
pass. "Beats stock" is claimed only when the full Agent run beats the stock run of the same
weights on two consecutive runs.

**Must not.** Train on, upload or log any personal data; evaluate on training cases; edit
the frozen thirty, quick subset or grader; add a second runtime, model store or download
queue; leave a KV-changing path without resetting `kvTokens`; keep a change that wins speed by
losing quality.
