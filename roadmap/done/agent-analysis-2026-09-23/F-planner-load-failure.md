# F — "The tool planner failed: The model could not be loaded." (2026-09-23 17:49 local)

> **Historical model assumptions — revised 2026-09-30:** this completed plan/audit
> preserves its dated measurements and implementation history. For new work, follow
> the [independent-role/shared-file contract](../../in-progress/SHARED-BRAIN/00-README.md): Meetings, Agent and cleanup
> may use different appropriate models; exact verified artifacts are reused, with
> workload-specific consent and request ownership. Agent-only file selection,
> universal model defaults and deletion based only on the Agent are superseded.
> MiniCPM cleanup + Apple guard/fallback is concurrent work, not evidence that this
> historical build used it. Re-measure quality/latency on the actual current engine.

Read-only diagnosis. Local time is EDT (UTC-4): 21:49Z = 17:49.

## TL;DR

- **K2-Horizon cannot be opened by the llama.cpp this app links.** The file is complete and valid
  (GGUF v3, 3,156,598,144 bytes, and the computed tensor end equals the file size exactly). But its
  `general.architecture` is **`k2-horizon`**, and the linked llama.cpp **b10621** has no such
  architecture: the string "horizon" does not appear anywhere in
  `/Applications/Next Notes.app/Contents/Frameworks/llama.framework/Versions/A/llama`. Its
  architecture table has `kimi-k2`, `qwen3`, `gemma4` and others, but not this one.
  `llama_model_load_from_file` returns null in about 0.1 s.
- **"Hi" and "Who are you?" were answered by Apple Foundation Models, not by K2.** The routing
  reached Apple FM only by accident, through a race.
- **"What can you do?"**: Apple FM answered the first pass with `<use_tools/>`. The **tool planner
  then resolved the provider a second time**. On that second resolution the runtime's spec had
  caught up to K2, so it chose the app's own llama model (`.appLLM`). The load failed, the runtime
  reverted to the built-in Gemma 4 E4B, and Gemma is not on disk. The load then threw
  `LlamaError.modelLoadFailed`, whose text is "The model could not be loaded."
- **The Agent role, `modelRoles.agent = installed:IFM/K2-Horizon-3.7B-GGUF/K2-Horizon-4B-Q4_K_M.gguf`,
  puts K2 back on every turn.** Every revert is therefore undone one turn later, and the load fails
  again. The unified log shows the "wouldn't open … went back to Gemma" notice 4 times in 34 s.

## Evidence

**State on disk and in settings.** `~/Library/Application Support/Next Notes/`, `defaults read ai.pivotstudio.nextnotes`:

| Item | Value |
|---|---|
| `Models/` | `IFM--K2-Horizon-4B-Q4_K_M.gguf` (3.16 GB), `s1-mini`, `embeddinggemma`, `needle3`, `potion`. **No Gemma 4 E4B weights and no `mtp-` file.** |
| `Models/library.json` | one entry: K2 (`displayName "K2-Horizon-3.7B"`, `parameterBillions 5.06`, Q4_K_M) |
| `modelRoles.agent` | `installed:IFM/K2-Horizon-3.7B-GGUF/K2-Horizon-4B-Q4_K_M.gguf` |
| `modelRoles.meetingNotes` | `builtin`, which resolves to `.appLLM`; Gemma is absent, so notes also fall through to Apple FM |
| `modelLibrary.activeAgentModelID` | `built-in/gemma-4-e4b`. This is the value left by the last revert, and it disagrees with the role. |
| `modelLibrary.postDownloadPolicy` | `switchDeleteOld`. Nothing was deleted this time, because `decide()` keeps the old model when the load fails. |
| Free disk at 17:49:13 (CacheDelete log) | 4.65 GB |

**GGUF header.** Parsed with a python3 stdlib reader (`scratchpad/gguf.py`):

- `general.architecture = k2-horizon`, `general.name = Checkpoint_0010000`, `size_label 5.1B`
- `k2-horizon.context_length = 524288`, 36 blocks, embedding 2560, 32 heads / 8 KV heads, `rope.freq_base 1e7`
- Two custom keys: `attention.group_norm_groups = 2` and `tokenizer.ggml.pre = k2-horizon`. The pre-tokenizer is also unknown to b10621.
- `file_type 15` (Q4_K_M). Tensors: Q4_K ×217, Q6_K ×37, F32 ×73. Vocab 250,624.
- `tokenizer.chat_template` is a 43 KB jinja template built on `<|ifm|im_start|>` / `<|ifm|im_end|>` and `<ifm|think>`. It is **not** ChatML.
- It is not a draft, MTP or auxiliary file. It is a full model, and `isAuxiliaryGGUF` correctly ignores it.
- Memory fit and disk space play no part:
  - The failure takes 0.1 s, before any mmap.
  - A 3.2 GB Q4_K_M fits a 16 GB M3.
  - No KV cache or file is created.

**`metrics.jsonl`.** `model.load` entries, all `note: "app_llm failed"`:

| Time (Z) | Duration | Trigger |
|---|---|---|
| 21:47:24 | 0.001 s | Post-download verification, `ModelLibraryStore.applyPostDownloadPolicy`, which calls `prepare()` |
| 21:49:14 | 0.12 s | Prewarm while typing "Hi" (`AgentView.swift:98`, `.onChange(of: draft)`) |
| 21:49:34 | 0.12 s | Prewarm while typing "Who are you?" |
| 21:49:42 | 0.12 s | Prewarm while typing "What can you do?" |
| 21:49:48 | 0.10 s | The tool planner, followed by `agent.tool_call_to_result` 0.13 s `model-tools` |

`agent.transcript_to_first_token` records:
- "Hi": 6.9 s, `note: model` (a cold Apple FM start)
- "Who are you?": 2.2 s, `note: model`
- "What can you do?": 2.4 s, `note: no-token`

**Unified log** (`subsystem == ai.pivotstudio.nextnotes`, then `process == NextNotes`):

- 17:49:14.824, 17:49:34.780, 17:49:42.797 and 17:49:48.674 each log:
  `model library: K2-Horizon-3.7B wouldn't open on this Mac, so Next Notes went back to Gemma 4 E4B.`
- 17:49:19.311 (the "Hi" turn): `ModelBundle: Creating … com.apple.fm.language.instruct_3b.fm_api_generic`, then Apple FM execute requests. So **Apple FM answered "Hi"**.
- 17:49:37.816 ("Who are you?"): Apple FM session and streaming request.
- 17:49:46.336 ("What can you do?"): Apple FM session for the first pass. It returned `<use_tools/>`. The planner's load then failed at 17:49:48.

**Conversation store** (`agent-conversation.json`, session 07D36A96): "Hi" → "Hello."; "Who are you?" →
"I am Will. …"; "What can you do?" → "The tool planner failed: The model could not be loaded."
(`contextKind: tools`). `agent-audit.jsonl` has the same rows at 21:49:19–48Z.

## Timeline

1. **17:47:24.** The K2 download finishes. The post-download policy sets `activeAgentModelID = K2` and calls `prepare()`.
   - `openNative` fails, so `revertToBuiltIn` runs. Gemma is absent, so the load throws `.modelLoadFailed` (NotesModelRuntime.swift:1204–1214).
   - `decide()` receives `loadSucceeded = false`, restores the previous id and deletes nothing.
2. The user answers the Models tab's "Use for agent turns" prompt (`ModelsSettingsTab.swift:340`).
   - This sets `modelRoles.agent = installed:K2`.
   - **Nothing checks that the file actually opened.**
3. **17:49:14.** Typing triggers a prewarm, which reaches `.appLLM` with spec = K2. The load fails, the runtime reverts, and `activeAgentModelID` is set to `built-in`.
4. **17:49:19, "Hi".**
   - `runModelTurn` calls `AgentModelRouting.provider`, then `ModelRoleStore.provider(for: .agent)` (ModelRoleStore.swift:569–579).
   - That code sets `activeAgentModelID = K2`. The `didSet` then calls `adoptInRuntime()`, which is a **fire-and-forget `Task`** (InstalledModelLibrary.swift:96–131).
   - It then calls `LLMProviders.resolve(.appLLM)` immediately. `LlamaLLMProvider.unavailableReason` (LlamaLLMProvider.swift:33–41) reads `NotesModelRuntime.activeSpec()` before that Task has run, so it still sees the reverted Gemma spec. Gemma is not downloaded, so the provider reports itself unavailable.
   - `resolve` moves on to `.appleFoundation` (LLMProvider.swift:263–278). **Apple FM answers.**
5. **17:49:34.** A prewarm while typing: the spec is K2 by now, so this is another failed load and another revert.
6. **17:49:37, "Who are you?".** The same race happens again, and Apple FM answers again.
7. **17:49:42.** A prewarm, and another failed load and revert.
8. **17:49:46, "What can you do?".**
   - The first pass hits the same race. Apple FM answers `<use_tools/>`.
   - `runPlannedToolLoop` **resolves the provider a second time** (RealtimeAgent+ToolLoop.swift:774).
   - By now the adoption Task has run, so the spec is K2. K2 is "downloaded", so `.appLLM` counts as available.
   - The stream calls `loadIfNeeded`. `openNative` returns nil, and `revertToBuiltIn` runs.
   - `spec.isDownloaded` is false for Gemma, so `opened` stays nil and the load throws `.modelLoadFailed`. The runtime is also `markWedged` (NotesModelRuntime.swift:1136).
   - The call returns `.failure(.message("The model could not be loaded."))`, which produces `"The tool planner failed: " + message` (RealtimeAgent+ToolLoop.swift:929).

## Why "Hi" worked while the planner failed

Nothing about "Hi" was correct: a race rescued it. Each turn resolves the provider twice, once
for the first pass and once for the planner. The Agent role writes K2 back into the library on
each resolution. The runtime only adopts that change asynchronously.

- **First resolution:** it reads the stale reverted spec (Gemma, not on disk). `.appLLM` looks
  unavailable, so `resolve` falls through to Apple FM.
- **Second resolution:** it sees K2 as present. `.appLLM` looks available, so it loads, and the
  load fails.

Plain answers stay in the first pass, so they worked. Any request that needs tools goes to the
planner, so every one of them fails. The persona answer ("I am Will. I am an autonomous alter ego
living in your Mac.") is Apple FM repeating the first line of the user's `persona.md` ("You are
Will, Serge's autonomous alter ego living in his Mac."). K2 generated nothing all day.

## Root causes (file:line)

1. **R1: unsupported architecture, with no check before download or before role selection.**
   - `HuggingFaceModelDetails.architecture` is fetched, and its doc comment says "Used to warn
     before a download that llama.cpp may refuse" (HuggingFaceClient.swift:83–84). **Nothing reads
     it.** `grep '\.architecture\b'` finds only the assignment at :264. This is another finished
     feature with no call site.
   - `ModelsSettingsTab.swift:340` commits the Agent role to a file that the post-download check
     had just failed to open.
2. **R2: the role re-asserts a file that is known not to open** (ModelRoleStore.swift:569–579).
   - `provider(for:)` writes `activeAgentModelID = id` on every call.
   - `revertToBuiltIn` (NotesModelRuntime.swift:230–237) moves only the library selection, not
     the role, so every revert is undone on the next turn.
   - `InstalledModelLibrary.usableModels` (:161) filters out auxiliary heads but has no concept of
     a file that could not be opened.
3. **R3: the fire-and-forget adoption makes provider resolution non-deterministic**
   (InstalledModelLibrary.swift:96–131 together with ModelRoleStore.swift:576–579).
   - `resolve` reads `activeSpec()` before the `Task { useInstalledModel }` has run.
   - This is why the first pass and the planner disagree within a single turn.
4. **R4: the planner resolves the provider again instead of reusing the turn's provider.**
   - `runModelTurn` resolves at :353, and `runPlannedToolLoop` resolves again at :774.
   - Neither handles `.modelLoadFailed` by falling back to another provider.
5. **R5: the fallback reports "went back to Gemma 4 E4B" when Gemma is not on disk, and throws the
   wrong error** (NotesModelRuntime.swift:1203–1214).
   - When the built-in model is absent after a revert, the load throws `.modelLoadFailed` instead
     of `.modelMissing`. As a result, `loadIfNeeded` marks the runtime **wedged** (:1136) instead
     of unloaded.
   - The notice text (`ModelLoadNotice.couldNotOpen`, `fallback: NotesModels.spec.displayName`) is
     false on this Mac.
   - That notice appears only in Models settings (`ModelsSettingsTab.swift:19`), never in the Agent pane.
6. **R6 (latent): the prompt template is fixed to ChatML** (NotesModelRuntime.swift:1030–1042,
   `<|im_start|>…<think>\n\n</think>`).
   - Even a llama.cpp that knew `k2-horizon` would get K2's turn tokens wrong: K2 expects
     `<|ifm|im_start|>` and `<ifm|think>`.
   - This matches the Qwen-template finding in D-quality.md. LlamaHelpers special-token decoding
     was never reached today, because no llama inference ran.

Ruled out as causes:
- **Disk:** 4.65 GB free, and the failure happens before mmap.
- **ModelFitEstimator:** `--selftest-model-fit` passes, and a 3.2 GB Q4_K_M fits.
- **Truncated download:** the size matches the tensor end exactly.
- **MTP head:** the MTP file is gone and K2 is not auxiliary.
- **Metal:** `--selftest-llm-metal` passed, with Metal on and 43 tok/s on S1-mini. It also printed
  "Gemma 4 E4B is not downloaded", which confirms Gemma is absent.

## Fixes

**What the user can do in the app now** (each step works on its own; do both):
1. In Settings ▸ Models, change **Agent role** to **Apple Intelligence**, or to the OpenRouter
   model if one is configured. Both passes then resolve to the same provider. Do **not** use
   "Restore default model": it starts a 4.98 GB Gemma download, and this Mac has only 4.6–6.6 GB
   free while the downloader keeps a 4 GB reserve.
2. **Delete K2-Horizon** in Models settings. This app's llama.cpp build cannot open it, and
   deleting it frees 3.16 GB. After that, `provider(for:)` finds no library entry
   (`model(withID:) == nil`), so the role falls through to the built-in model, and from there to
   Apple FM.

**Code changes:**
1. **Pre-flight the architecture (R1).**
   - At `InstalledModelLibrary.add` and before download, read `general.architecture` from the
     GGUF header. Then do a real probe: `llama_model_load_from_file` with
     `params.vocab_only = true`, which fails in milliseconds on an unknown architecture or
     pre-tokenizer.
   - Mark the entry `isUnsupported` and leave it out of `usableModels`.
   - Wire `HuggingFaceModelDetails.architecture` into a warning before download.
   - Offer "Use for agent turns" only after the post-download load actually succeeded
     (ModelsSettingsTab.swift:340).
2. **Stop re-asserting a file that failed to open (R2).** On an `openNative` failure, record the
   id as unopenable (in memory, or persisted with the llama build number). Then:
   - `ModelRoleStore.provider(for:)` treats such a file like a missing one: `builtInProvider`, and
     from there `resolve`, which reaches Apple FM when Gemma is absent.
   - The role row shows "can't open on this Mac" instead of a green dot.
3. **Make adoption synchronous for the call path (R3).** In the `.installedModel` branch, run
   `await NotesModelRuntime.shared.useInstalledModel(model)` before `LLMProviders.resolve`, rather
   than relying on the `didSet` Task.
4. **Resolve one provider per turn (R4).**
   - Pass the provider that `runModelTurn` chose into `runPlannedToolLoop`, instead of resolving
     again at :774.
   - If a stream fails with `LlamaError.modelLoadFailed` or `.modelMissing`, re-resolve once with
     `.appLLM` excluded before reporting the planner failure.
5. **Correct the load outcome (R5).**
   - After `revertToBuiltIn`, if `!spec.isDownloaded`, throw `.modelMissing`, which leaves the
     runtime retryable instead of wedged.
   - Word the notice after the provider that will actually answer ("… so answers come from Apple
     Intelligence").
   - Show `ModelLoadNotice` in the Agent pane.
6. **Use the model's own template for downloaded models (R6).** Use
   `llama_model_chat_template` / `llama_chat_apply_template`, or refuse models whose template is
   not ChatML-compatible. This belongs with the D-quality fix.

## Red-first self-test

**Why the existing test is green:** `--selftest-model-roles` passed today (`MODEL_ROLES_OK`)
while the live app was broken. The harness short-circuits exactly the step that breaks here:
`InstalledModelLibrary.adoptInRuntime` (:128) and `NotesModelRuntime.adoptSavedSelectionIfNeeded`
(:205) are both skipped under `SelfTest.isRunning`, and no fixture GGUF is unloadable.

**Proposed test:** add `--selftest-model-unopenable`, or a case in `--selftest-model-roles`. It
prints `MODEL_UNOPENABLE_OK` or `MODEL_UNOPENABLE_FAILED`.

**Fixture:** write a GGUF of about 200 bytes to a temp dir. It has magic `GGUF`, v3, 0 tensors, and
`general.architecture = "nn-selftest-unknown"` plus a minimal tokenizer key.

**Setup:**
- Register the fixture in an isolated `InstalledModelLibrary(manifestURL:)`.
- Set the Agent role to `.installedModel(id)`.
- Keep the built-in model absent.
- Enable a runtime-adoption seam for the test, so the real adoption path runs.

**Assertions (each fails today):**
1. `NotesModelRuntime.prepare()` throws `.modelMissing`, not `.modelLoadFailed`, and
   `ModelRuntimeManager` does not report `.notes` as wedged.
2. Resolve twice in a row: call `AgentModelRouting.provider(for: "What can you do?", voice: false)`
   twice. **Both calls return the same `id`, and it is not `.appLLM`.** Today the first returns
   `.appleFoundation` and the second `.appLLM`.
3. After the failed load, `ModelRoleStore.provider(for: .agent)` no longer writes the fixture id
   into `activeAgentModelID`.
4. Drive a planner turn with a stub first pass that returns `<use_tools/>`. The reply must not
   contain "The tool planner failed:". It may be the honest "selected model is unavailable" when
   Apple FM is absent.
5. `InstalledModelLibrary.usableModels` excludes the fixture, and the header pre-flight reports
   `nn-selftest-unknown` as unsupported **before** any `llama_model_load_from_file` call with
   full weights.

## Secondary UI observations (screenshot)

1. **Large empty area above the messages.** This comes from
   `.defaultScrollAnchor(.bottom)` on the conversation `ScrollView`/`LazyVStack`
   (UI/Agent/AgentView.swift:180–235). With a short conversation, the content is pinned to the
   bottom, and the "Conversation" label floats partway down the pane. This is the intended chat
   idiom, not a logic bug, but it looks broken with 3 exchanges. Fix: pin to the top when the
   content is shorter than the viewport, or push the content down with a top `Spacer` so the
   label stays at the top. Cosmetic.
2. **The placeholder "Ask Next…" is hardcoded** at UI/Agent/AgentView.swift:493
   (`TextField("Ask Next…", …)`). **This is a bug.** The name in `agent-identity.json`
   (`displayName: "Will"`) should reach this field, the same way the onboarding strings do with
   `"Ask \(assistantName)…"` (Onboarding/OnboardingOutcome.swift:116, 129). It also goes against
   AGENTS.md's rule that the user names the Agent.
3. **The tone of the "Who are you?" answer** is not a code bug. Apple FM, the model that actually
   answered, copied the first line of `persona.md` almost word for word, including the awkward
   "living in your Mac". The user wrote "Will" in that file, which is allowed. The real bug is
   that the Models tab says K2 is in charge while Apple FM is answering (R2/R3/R5).
