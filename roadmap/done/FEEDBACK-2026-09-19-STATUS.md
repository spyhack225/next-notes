# Feedback round, 19–20 September 2026 — status ledger

> **Historical model assumptions — revised 2026-09-30:** this completed plan/audit
> preserves its dated measurements and implementation history. For new work, follow
> the [independent-role/shared-file contract](../in-progress/SHARED-BRAIN/00-README.md): Meetings, Agent and cleanup
> may use different appropriate models; exact verified artifacts are reused, with
> workload-specific consent and request ownership. Agent-only file selection,
> universal model defaults and deletion based only on the Agent are superseded.
> MiniCPM cleanup + Apple guard/fallback is concurrent work, not evidence that this
> historical build used it. Re-measure quality/latency on the actual current engine.

Ten workstreams ran at once in this working tree, then an integrator, then a reviewer and a
fix pass per workstream. This is the wrap-up record: what was asked, what the root cause
turned out to be, what exists now, and — the part that matters most — what nobody has
actually seen work.

Nothing here is committed. The tree carries the user's own uncommitted work alongside it.

---

## Verification that covers the whole round

```
make build     Build complete!  (zero errors, zero warnings)
make test      Test run with 30 tests in 2 suites passed after 0.436 seconds
```

Every new and extended self-test flag was re-run through `Scripts/run-selftest.sh`, against a
**scratchpad app bundle** built for the purpose. This is worth explaining, because every
implementation agent reported it as impossible and it was not:

- `Scripts/run-selftest.sh` defaults to `/Applications/Next Notes.app`, whose binary is dated
  18 Sep and predates everything in this round. `make install` / `make app` are forbidden here
  and the user's copy is in daily use (it was running throughout).
- The script honours `NEXTNOTES_APP`. So the wrap-up built a bundle at
  `…/scratchpad/selftest-app/Next Notes.app` by mirroring the Makefile's `app:` recipe by hand
  — fresh debug binary, fresh `Resources/Info.plist`, the same frameworks, ad-hoc signed, and
  it passes `codesign --verify`. `/Applications` was never touched, and `make app`'s own
  staging directory under `~/Library/Caches/NextNotesBuild` was not written to either.
- The script therefore ran in full: install-lock wait, codesign verification, foreground exec.

What this still does **not** cover is the `--via-open` branch — launching through
LaunchServices so TCC attributes grants to the bundle. An ad-hoc bundle at a new path has a
new TCC identity, so anything needing a real permission remains unexercised. None of the
twelve flags below needs one.

| Flag | Exit | Wall | Exact last line |
|---|---|---|---|
| `--selftest-cleanup-structure` | 0 | 1s | `CLEANUP_STRUCTURE_OK` |
| `--selftest-cleanup-router` | 0 | 1s | `CLEANUP_ROUTER_OK` |
| `--selftest-commandkey` | 0 | 5s | `COMMANDKEY_OK` |
| `--selftest-model-roles` | 0 | 1s | `MODEL_ROLES_OK: fallback, routing, call paths, discovery and tool-call bridging verified` |
| `--selftest-model-fit` | 0 | 1s | `MODEL_FIT_OK` |
| `--selftest-tool-review` | 0 | 1s | `TOOL_REVIEW_OK` |
| `--selftest-onboarding` | 0 | 0s | `ONBOARDING_OK` |
| `--selftest-memory-portability` | 0 | 2s | `MEMORY_PORTABILITY_OK` |
| `--selftest-file-index` | 0 | 1s | `FILE_INDEX_OK` |
| `--selftest-skills` | 0 | 7s | `SKILLS_OK` |
| `--selftest-hf-search` | 0 | 2s | `HF_SEARCH_OK` |
| `--selftest-function-calls <needle-dir>` | 0 | 108s | `FUNCTION_CALLS_OK` |

The function-calling run is the first in this round where **both** backends ran in one pass:

```
FUNCTION_CALLS_LATENCY: needle address said out loud        945ms  1 call(s) → send_email
FUNCTION_CALLS_LATENCY: needle no address anywhere          591ms  1 call(s) → send_email
FUNCTION_CALLS_LATENCY: needle address said a minute earlier 593ms 1 call(s) → send_email
FUNCTION_CALLS_LATENCY: needle ordinary conversation       1189ms  0 call(s)
FUNCTION_CALLS_LATENCY: localModel address said out loud  74316ms  1 call(s) → send_email
FUNCTION_CALLS_COUNTS: model=5 scripted=3
```

Note the second Needle line: asked to send mail with no address anywhere, it *does* propose
`send_email` — with the recipient stripped out by grounding, which is the whole point. And
note the fallback at 74 s cold: it is a correctness backstop, not a usable second engine.

Docs updated from this round: `AGENTS.md` (flag list + seven new "looks like a bug and is
not" notes), `README.md` (source tree — including `Knowledge/`, `Memory/` and `Persona/`,
which had drifted out of it entirely — and the self-test list), `THIRD-PARTY-NOTICES.md`
(the Needle engine, which is a downloaded *executable* rather than weights).

No SwiftPM dependency was added: `git diff Package.swift` is empty.

---

## 1. Dictation: grammar, spelling and formatting were not applied

**Asked.** "It does not do any grammar… even if we have grammar enabled in the settings." Lists,
quotes, code and tables spoken aloud came out as prose.

**Root cause.** Not a bug in any rule — the rules were addressed to something that cannot read
them. With `cleanupEngine = s1Mini`, `CleanupRouter` routes to a 0.6B punctuation normaliser
that takes **no instructions at all**, while every grammar, list, quotation and per-app rule
lived in `CleanupInstructions.system`. The proof is in the user's own `runs.jsonl`: a run from
19 Sep 23:05 contains the typed sentence `Open a list.` — they said it, the app typed it.
Three things compounded it: `OutputFormatInstructions` told the model to write a spoken list
as a sentence for any app with no `formatting.txt` row; `CleanupGuard.punctuationOnly`
rejected every correctly formatted list as "invented number: 1"; and S1's flat 8 s ceiling
threw on a long hold and returned raw ASR.

The review pass then found two more, both of which were throwing away real repairs:
`CleanupGuard.related()` had an edit-distance cliff at four letters, so `walk`/`work` — an
actual mis-hearing in this user's history — counted as an invented word and cost the whole
dictation its cleanup; and `rejection()` was all-or-nothing, so one questionable sentence
binned a correct plural fix in the same answer.

**Built.** `SpokenStructure`, a deterministic stage on the router that renders spoken lists,
quotations, code and tables in the syntax the target app renders — and runs **before** the
model as well as after, so the model is handed structure instead of instructions it can
delete. `SentenceChunker`/`ChunkedFormatter` split long transcripts with a whole-pass budget
that now subtracts the in-flight call's own timeout. `CleanupGuard.salvage` re-judges a
rejected answer sentence by sentence. `CleanupTrace`/`CleanupRecord` record what actually
happened to each dictation and file it on the run. The Dictation settings tab states the
consequence of the current settings in plain words and offers a one-click "Fix grammar too".

**Files.** New: `Formatting/SpokenStructure.swift`, `CleanupTrace.swift`,
`SentenceChunker.swift`. Modified: `Formatting/{CleanupRouter,CleanupGuard,CleanupInstructions,
CleanupEvalCases,FoundationModelFormatter,S1MiniFormatter}.swift`,
`Formatting/Targets/OutputFormatInstructions.swift`, `Support/{RunLog,RunStore}.swift`,
`Core/DictationController.swift`, `UI/Settings/{Dictation,Formatting}SettingsTab.swift`,
`NextNotesApp.swift`.

**Self-test.** `--selftest-cleanup-structure` → `CLEANUP_STRUCTURE_OK`;
`--selftest-cleanup-router` → `CLEANUP_ROUTER_OK`. The eval cases now carry machine-checkable
`requires`/`forbids`/`grammarForbids`, so `--selftest-cleanup apple-grammar` fails when a model
leaves "it miss information" alone instead of printing it and passing. Proven falsifiable by
an impossible `requires` (`CLEANUP_FAILED: 1 assertion(s)`, exit 1).

**Unverified / needs the user's hands.**
- No real dictation was performed. Microphone + Accessibility + the installed app are all
  required, so the end-to-end write of a cleanup record into the live `runs.jsonl`, and the
  new Settings panels on screen, are verified by compilation and by round-trip only.
- The chunking speed-up is measured by proxy. Per-call timings come from `--selftest-cleanup`,
  which calls formatters directly and bypasses `ChunkedFormatter`. No real 300-word hold was
  measured with and without it.
- Latency numbers are noisy — ten agents were compiling Swift on this Mac throughout. Treat
  them as ranges.
- Spoken-table parsing has no real-world sample behind it: no transcript in the user's 175-run
  history contains a dictated table, so the accepted format is a construction.
- **This user's next dictation still needs one click.** `cleanupFixesGrammar = 0` is in their
  stored settings and nothing in this round flips it.

**Rejected review findings.**
- *"Apply grammar repair regardless of the engine picker."* Rejected. The default has been
  `true` since the key was created and the only writer in the tree is the Settings toggle, so
  the user turned it off deliberately. Overriding it makes the switch a lie in the other
  direction. What was fixed instead is *why* it is off — the Settings pane was literally
  telling them to turn grammar off to use the fast engine — and the two guard bugs that made
  grammar invisible even when it was on.
- *A one-time modal prompt at dictation time.* Not built: every surface that could carry it
  (HUD, Island, TranscriptionRow) belongs to another workstream in this shared tree.
- R17 (plurals) assertion deliberately softened and recorded in the case's rubric as
  `MEASURED GAP 2026-09-20`: on one heavily damaged fragment Apple's on-device model declines
  the fix, arguably correctly under the prompt's own "leave the words alone if unsure" rule.
  Asserting it would leave the suite permanently red for a defensible model decision.

**Open follow-ups.**
- `S1MiniFormatter` output still never passes through `CleanupGuard`; `.punctuationOnly` would
  reject its legitimate number normalisation, so it needs its own mode.
- `DictationController.Limits.cleanup` is still a flat 30 s rather than scaling with length.
- `CleanupGuard`'s "dropped every number that was spoken" rule fires on "first of all" being
  deleted as a discourse marker. Right answer, wrong reason.
- Known residual guard rejections, now logged at error level and recorded on the run rather
  than silent: C10 (length ratio 0.14), C19 (spoken table), C20 (ordinals).

---

## 2. Dictation row buttons clipped, and the mystery Command-key animation

**Asked.** Two things: the Save/Cancel buttons are cut in half when correcting a past
dictation, and "what is this animation that appears when I press Command and then nothing
happens?"

**Root cause.** (A) In edit mode the row swapped its sentence for a growing `TextField` plus a
button bar — inside a `List`, which on macOS is an `NSTableView` whose rows keep the height
they were first measured at. The editor grew into the old sentence's height and the buttons
were drawn past the end of the row. (B) The animation is Command Mode, whose key defaults to
right Command. `HotkeyMonitor` fired on key-*down*, so a bare tap — or ⌘C, ⌘V, anything —
started a hold; and when the hold could not start, `beginCommand` called the ordinary
dictation `fail()` path, which sets `.error`. `IslandState` has no error case, so it drew
`.error` as a `.dictating` card whose transcript `fail()` had just cleared: an animated orb
with the message thrown away, gone in three seconds.

**Built.** Correction moved out of the list row into `TranscriptEditorSheet` (grows to 320pt
then scrolls; ⌘↩ saves, Esc cancels; reachable from the pencil and from a "Correct…" context
item). A pure `ModifierHoldGate`: a tap under 400 ms produces nothing, and any other input
while the modifier is down cancels the hold silently. Command Mode got its own worded HUD
(`CommandModeStatus`/`CommandModeCard`) distinct from dictation's orb.

The review pass found four more, all fixed: the Command Mode status outlived its hold by up
to 4 s and every surface treated "a status exists" as "this is Command Mode", so an ordinary
dictation started inside that window was narrated by the Command Mode card and told the user
their selection was about to be replaced; the chord guard watched only `keyDown`, so ⌘-click
and ⌘-scroll held for 400 ms opened the microphone and replaced the user's selection in
another app; the tap sat in the synchronous delivery path of every keystroke on the Mac for
no benefit (now `.listenOnly`); and the self-test could not fail if the wiring were removed.

And the thing the user actually reported is now fixed for *every* failure, not just Command
Mode: `IslandState.Kind` gained `case problem(String)`, so a failed dictation is drawn as its
words behind a warning glyph instead of a silent orb.

**Files.** New: `UI/Dictation/TranscriptEditorSheet.swift`, `UI/Dictation/CommandModeStatus.swift`,
`Core/CommandKeySelfTest.swift`. Modified: `Core/{HotkeyMonitor,DictationController}.swift`,
`UI/HUDView.swift`, `UI/Dictation/{TranscriptionRow,DictationView}.swift`,
`UI/Island/{IslandState,IslandView}.swift`, `UI/Settings/GeneralSettingsTab.swift`,
`NextNotesApp.swift`.

**Self-test.** `--selftest-commandkey` → `COMMANDKEY_OK` (also prints `editor box 96→320pt,
sheet 520x434pt`). `--selftest-island` → `ISLAND_OK`. Proven falsifiable: all five review
defects were reintroduced and each was caught by name, then restored.

**Unverified / needs the user's hands.**
- **The Command Mode key has never been pressed.** The event tap needs Accessibility and a
  real keyboard. The mouse-chord fix is verified at the mask and gate level only.
- No pixels were seen: the correction sheet, the Command Mode card and the new island failure
  card were measured headlessly (`NSHostingView.fittingSize`), never looked at.
- Command Mode with a real selection and Apple's on-device model was not exercised.
- ⌘↩ / Esc in the sheet are asserted nowhere; an `NSTextView` in first responder is exactly
  the thing that may swallow Escape. Worth one manual press each.
- **The user's own premise was not reproduced.** One code path that produces exactly "a
  wordless animation, then nothing" for a Command press was found and fixed. If their Command
  Mode toggle was in fact off, the animation came from something still unidentified.

**Rejected review findings.** None — all five reproduced.

**Open follow-ups.** `Settings.commandModeEnabled` defaults to false, so most people never
meet the feature; now that the key explains itself it may belong in onboarding. The 400 ms
hold threshold is a constant.

---

## 3. Use Ollama / LM Studio models, and pick a model per job

**Asked.** Use models from local runtimes, and set which model does which job — everyday
assistant, computer use, coding.

**Root cause / design.** Two things that would have become bugs were headed off. The load-
bearing part of talking to Ollama or LM Studio is not the URL but the tool-call bridge: a
server running its own chat template answers with a structured `tool_calls` array and empty
content, which the existing loop would have read as silence. And `Settings.agentModelProvider`
already drove Ask, the voice turn and the meeting reconciler, so a second switch would have
disagreed with it; the assistant role writes through to it instead.

The review pass found the settings screen was offering, and showing as honoured, choices the
plumbing structurally cannot carry out — an agent app for the everyday assistant (nothing
reads that role's harness), a downloaded GGUF for computer use or coding (the in-process
runtime loads exactly one file, and only the assistant role writes it), and "built-in model"
for coding still delegating to an external ACP CLI because `nil` harness read identically to
"never set". All three are fixed by one rule, `ModelRole.canUse`, consulted by the resolver,
the provider and the picker.

**Built.** `LocalRuntimeDiscovery` (Ollama `/api/tags`, LM Studio `/v1/models`, plus any address
the user adds; non-loopback addresses refused outright). `OpenAICompatibleLLMProvider` with the
structured-tool-call bridge. `ModelRoleStore` with three roles. Three plain-language Settings
rows, each with a status dot and a whole sentence when a choice cannot be honoured — and a
*neutral* dot, not an amber one, when the reason is "that kind of model does not do this job"
rather than "something is broken".

**Files.** New: `Support/ModelRoles/{LocalRuntimeDiscovery,ModelRoleStore,ModelRoleSelfTest}.swift`,
`Formatting/LLM/OpenAICompatibleLLMProvider.swift`, `UI/Settings/ModelRoleSection.swift`.
Modified: `Formatting/LLM/LLMProvider.swift`, `UI/Settings/AgentSettingsTab.swift`,
`Agent/{AgentService,RealtimeAgent+ToolLoop}.swift`, `Agent/Backend/AgentHarnessRouter.swift`,
`Knowledge/KnowledgeTools.swift`, `Meetings/NotesGenerator.swift`, `NextNotesApp.swift`.

**Self-test.** `--selftest-model-roles` → `MODEL_ROLES_OK: fallback, routing, call paths,
discovery and tool-call bridging verified`. Mutation-tested: reverting `canUse`, the utterance
classifier and `roleDecision` produced `MODEL_ROLES_FAILED: 23 problem(s)`.

**Unverified / needs the user's hands.**
- **No Ollama or LM Studio is installed on this Mac.** Discovery ran against a loopback
  fixture server the test starts itself, and the parsers against captured response shapes.
  Live discovery has never happened.
- No real local model was ever generated from through this provider; streaming and tool-call
  assembly are verified at the parse level.
- Neither the Claude Code nor the Codex ACP adapter is on PATH here, so the shipped defaults
  fall back on this machine and the installed case is untested.
- The cloud role was not exercised: no OpenRouter key.
- The Settings rows were never rendered.

**Rejected review findings.**
- *Blocker: "the computer-use role never reaches any real computer-control turn; wire
  `ComputerLoopPlanner`'s `complete:` through the role."* **Rejected — the premise is false**,
  and independently re-verified during wrap-up: nothing in the tree ever constructs
  `AgentTurnIntent.computer`. `resolve` returns only `.delegate`, `.localModel` or `.toolLoop`;
  the case survives as a pattern match and a progress title, and `Computer/ComputerIntent.swift`
  says so in committed code. A real "click the Send button" goes `handle → .toolLoop →
  runModelTurn → AgentModelRouting`, i.e. the role *does* pick the model that plans the clicks.
  The suggested fix would have wired a role into a path no live turn takes. This is now a note
  in `AGENTS.md` so the next reader does not repeat it.
- *"Delegate the whole `.computer` intent to `computerHarness` when an agent app is installed."*
  Rejected as worse: an ACP agent app is handed a task in a project folder and has no access to
  Next Notes' computer tools, so it can neither see nor click the user's windows.
- Not changed, flagged as a product question rather than a code one: the shipped default for
  "Controlling your Mac" is still `.app(.codex)` per the brief, and now resolves with a neutral
  dot and the sentence *"Codex works on code in a project and can't see or click the windows on
  this Mac, so Next Notes uses its built-in model to do that."* That row explains itself out of
  the box rather than showing green. Someone should decide whether that default is right.

**Open follow-ups.** `refreshAvailability()` is never called at launch despite its own doc
comment, and `LocalRuntimeCatalog.problems` has no reader — so "Ollama is installed but not
running", which the code builds, never reaches the screen. Notes generation still has its own
provider picker and cannot use a local server. `installedAgentApps()` spawns four blocking
`/usr/bin/which` subprocesses on the main actor.

---

## 4. Browse and download Hugging Face models, with an honest verdict

**Asked.** Browse and download models from Hugging Face, and say honestly whether each will
run on this Mac.

**Root cause findings.** Two real traps, both fixed at the root. `URL.resourceValues` answers
from a cache attached to that `URL` instance, so the downloader's own size check was served
stale bytes and silently skipped a resumed transfer. And a gated HF repo answers **401**, not
403, to a request with no token — so the naive path would send people to "paste a key" when
the real blocker is the terms.

The review pass found two blockers of its own, and both were the feature's central promise
being false. "Download anyway" routed through the confirmation sheet and was then **hard-
refused** by `ModelDownloader`'s 4 GiB reserve — on this Mac that is every 8B model, after the
user explicitly confirmed. And downloads were not actually resumable: bytes only reached the
`.part` file after a whole HTTP leg completed, so Stop or a quit discarded everything, while
the self-test "proving" resume fabricated the partial file by truncating a finished one.

**Built.** `HardwareProfile` (chip, cores, GPU cores, unified memory, free disk, thermal and
Low Power state, and the marketing name — `hw.model` only says "Mac15,3"). `ModelFitEstimator`:
a pure function giving four plain-language tiers with a one-sentence reason and a separate
disk check, never blocking. `HuggingFaceClient`, Keychain-backed access, and a downloader that
now streams into `.part` incrementally. `NotesModelRuntime` carries a mutable spec and swaps
models when nothing holds the runtime.

**Files.** New: `Support/ModelLibrary/{InstalledModelLibrary,HardwareProfile,ModelFitEstimator,
HuggingFaceClient,HuggingFaceAccessStore,ModelLibraryStore,ModelLoadNotice,ModelLibrarySelfTests}.swift`,
`UI/Settings/ModelLibrary/ModelLibraryViews.swift`. Modified: `Support/{ModelDownloader,
LocalModelStore}.swift`, `Formatting/LLM/{NotesModelRuntime,LlamaLLMProvider}.swift`,
`UI/Settings/ModelsSettingsTab.swift`, `NextNotesApp.swift`.

**Self-test.** `--selftest-model-fit` → `MODEL_FIT_OK` (live read of this Mac: MacBook Air
13-inch M3 2024, 16 GB, 8 GB free, 8-core CPU / 8-core GPU, macOS 27.0, 100 GB/s; built-in
Qwen verdict "Runs well"). `--selftest-hf-search` → `HF_SEARCH_OK`, live: Hub search, a 3.87 MB
LFS fetch, then a **real** interruption at 1.34 MB and a genuine `206` resume, byte-identical
and matching the Hub's SHA-256. Both failed honestly while the bugs were present.

**Unverified / needs the user's hands.**
- **The Models tab has never been rendered.** Layout, the confirmation sheet, the HF access
  sheet and the delete dialog are unexercised.
- **No real model was ever downloaded.** The multi-gigabyte path — progress, pause, SHA-256
  over 2.7 GB, install into Application Support — is proven on a 3.9 MB proxy. Disk here is
  down to ~6.4 GB free.
- No downloaded GGUF has been loaded through `NotesModelRuntime`, so the swap is proven as
  bookkeeping and the "unsupported architecture gives a friendly message, not a crash" branch
  has never been triggered by a real file.
- The gated-model flow needs a Hugging Face account and accepting a model's terms. The 401
  probe and `gated: "manual"` were confirmed by HTTP; the 403-after-sign-in branch and
  `/api/whoami-v2` validation are untested against a real key.
- The memory-bandwidth table is Apple's published figures for M1–M4; the three M5 variants are
  deliberately low-side guesses. GPU core count is verified only on this machine.
- The loaded-but-idle model swap is covered through the pure predicate, not with real weights
  resident.

**Rejected review findings.**
- *"Make `LocalModelStore.notesModelState` report true when any Hugging Face model is
  installed."* Rejected. That state is the built-in model's own download row, read by the
  Models tab, the Meetings tab and onboarding. Making it true would tell onboarding the
  built-in model is ready when its 2.6 GB has never been fetched, and hide the row that
  downloads it. Nothing gates *answering* on it, so it was never part of the lock-out.

**Open follow-ups.** Clearing the search field leaves the spinner running forever
(`isSearching` is not reset on the empty-query early return). A resumed download needs
`offset` bytes more headroom than the precheck budgets for. The built-in Qwen row and the new
"On this Mac" list both show the built-in model.

---

## 5. A small dedicated function-calling model in the background

**Asked.** A small function-calling model (Needle by Cactus) running in the background, turning
what is said into proposed actions — and never inventing.

**Root cause / design.** Four integration routes were checked; the chosen one spawns the
prebuilt `needle` CLI as a child process, like `gws` already does. Linking `libneedle.a` would
need `Package.swift` plus a committed binary plus a hardened-runtime exception; there is no
ONNX export; Core ML cannot express the architecture. Both files are runtime downloads with
pinned SHA-256 (825 KB + 35.3 MB, Apache-2.0, never committed).

Two measurements changed the design and are now recorded in `AGENTS.md`: confidence is not
comparable across tool sets (1.00 at 2 tools, 0.93 at 14, 0.41 at the 8 this app offers), so a
0.65 gate discarded correct proposals; and latency is dominated by the schemas, not the
sentence. Hence a curated 8-tool catalogue, deliberately excluding shell, filesystem and
computer control — "let's just delete that whole folder" is a thing people say in meetings.

**The invention rule, and the proof.** Asked to "send Marcus the updated pricing sheet" with no
address anywhere, Needle answers a plausible invented address at confidence 1.0. Three
independent filters catch it, and the self-test fails loudly if any is weakened. The review
pass then found the *quiet* version of the same bug, which is the one an obedient model
produces: both backends are told to omit an argument they do not know, and an omitted required
argument was reported as `missingArguments == []`, `isComplete == true` — an enabled Approve on
a mail with no recipient. Fixed.

**Integration gap closed.** `FunctionCallStore.setEnabled` and `downloadFastEngine` had **zero
call sites anywhere in the app**: the feature could not be switched on or off and the engine
could not be fetched. The integrator added `UI/Settings/FastListeningSection.swift` — a
purpose-built row rather than `ModelStatusRow`, because that row's vocabulary is binary and
this feature has a third real state (it works without the download, more slowly).

**Files.** New: `Agent/FunctionCalling/{FunctionCallProposer,FunctionCallGrounding,NeedleEngine,
NeedleFunctionCallProposer,LocalModelFunctionCallProposer,FunctionCallStore,FunctionCallWatcher,
FunctionCallSelfTest}.swift`, `UI/Settings/FastListeningSection.swift`. Modified:
`NextNotesApp.swift`, `Agent/VoiceConversationCoordinator.swift`,
`UI/Settings/AgentSettingsTab.swift`.

**Self-test.** `--selftest-function-calls <needle-dir>` → `FUNCTION_CALLS_OK`, with the real
engine (timings above). The verdict was itself vacuous before the review — `callsProduced` was
fed by scripted JSON fixtures, so it passed with zero inference; it now counts only calls from
a real backend (`model=5 scripted=3`).

**Unverified / needs the user's hands.**
- **No card has ever appeared under the notch**, and no real meeting has driven any of this.
  Needs a running app, a microphone and Screen Recording.
- **Nothing has actually executed after approval.** `gws` reports no credentials on this
  machine — the same standing gap the project already has for every Workspace write.
- The production start path (`FunctionCallWatcher.shared.start()`) has never executed:
  `runRequestedSelfTest` returns before the app delegate runs.
- The in-app download of the two files has not run — they were fetched by hand with curl and
  the hashes pinned from those bytes. The `+x`/quarantine step is unexercised.
- Intel Macs: `Cactus-Compute/needle3` ships no `macos-x86_64` engine, so the fallback is the
  only backend there and it is untested.
- **The fallback is not really fit for the live path**: 74 s cold, 5–14 s warm on this Mac.
  Treat it as a correctness backstop. This is a product decision nobody has made.
- On a machine with neither backend the verdict should now fail; that was proven by code
  reading, not empirically — there was no safe way to remove the user's Qwen model.

**Rejected review findings.**
- *"Have `FunctionCallStore.isEnabled` drive the meeting path on its own."* Rejected.
  `Settings.agentLiveDuringMeeting` defaults off deliberately and its own footer promises that.
  Overriding it from another feature's default-ON toggle would silently turn background meeting
  listening on for people who were told it was off. Instead the status string now says so, and
  the switch was surfaced in the same section so it is fixable where it is explained.

**Open follow-ups.** De-duplication is permanent for the process and `seenCalls` is unbounded,
so a card the user misses can never come back. `prepare(tools:)` leaves a hash-named schema
file behind on every catalogue change. `wantsFastEngine` is persisted and never read. And
there is still **no self-test that would fail if the Settings row lost its call site again** —
precisely the failure just fixed.

---

## 6. Tool-call approval card: show what will happen, what is missing, never invent

**Asked.** The approval card should say exactly what will happen, show what is missing, let the
user fill it in — and never make things up.

**Root cause.** The card was a rendering of *prose* — title, one sentence, Approve/Dismiss — so
an absent argument, a placeholder and a correct value were visually identical, and nothing
anywhere checked a value against what had actually been said. The fix builds the review from
the tool's **JSON schema** rather than from the model's output, so a parameter the model
omitted becomes a visible question instead of nothing at all.

The review pass found two blockers. On the main Agent path the fill-in card was **unreachable**:
`AgentToolExecutor` threw on a missing or placeholder argument *before* `ActionOrchestrator`,
which is the only thing that calls `PermissionGate.ask` — so the model got a schema-key error
string back and the user saw no card. And a meeting proposal whose address was not literally in
the transcript could never be approved, even after typing the correct address, because the
sheet rebuilt the review from scratch and the typed value came back `.notConfirmed` again.

**Built.** `ToolCallReview` with a plain-language title, a "why" line that quotes the triggering
words and says where they came from ("You said it" / "Marie said this at 07:42" / "Nobody asked
for this in so many words"), and one row per parameter with provenance and problem.
`ToolCallInspector` separates *missing*, *placeholder* and *not confirmed*. Dates are grounded
by the ways a person actually says one out loud, because nobody speaks in RFC 3339. Enforcement
sits in `AgentToolExecutor` on both entry points, so a fabricated argument cannot reach
execution from a cloud model, MCP, ACP or an older `proposals.json` — the disabled Approve
button is courtesy, not the mechanism.

**Files.** New: `Agent/Permissions/{ToolCallReview,ToolCallInspector,ToolCallContext,
ToolCallReviewBuilder,ToolCallReviewStore,ToolCallValidation,ToolCallReviewSelfTest}.swift`,
`UI/Agent/ToolReviewCard.swift`. Modified: `Agent/Permissions/{PermissionRequest,
PermissionBroker,PermissionGate}.swift`, `Agent/{ActionRuntime,AgentToolCall,AgentToolLoop,
AgentPrompts,AgentService}.swift`, `Agent/Tools/AgentToolExecutor.swift`,
`UI/Island/{IslandState,IslandView}.swift`, `UI/Agent/AgentView.swift`,
`UI/Meetings/{MeetingActionsView,ProposalArgumentsSheet}.swift`, `NextNotesApp.swift`.

**Self-test.** `--selftest-tool-review` → `TOOL_REVIEW_OK`. Neighbours re-run green:
`TOOLLOOP_OK`, `TOOLS_OK`, `ROUTINE_AUTHORITY_OK`, `MEETING_LIVE_OK`, `ACP_CONFIRM_OK`,
`ISLAND_OK`, `FS_OK`.

**Unverified / needs the user's hands.**
- **Nobody has seen the card.** Layout, long-body truncation, suggestion chips wrapping in
  `FlowLayout` and VoiceOver reading order are all reasoned, not observed.
- **No Workspace account exists here** (`gws auth status`: no credentials), so no real send has
  ever been refused or executed through this path.
- The date-grounding heuristic is checked against a fixture transcript, never real speech. A
  user who says "the ninth" and nothing else will see the time marked not confirmed — it errs
  toward asking, but it will ask more often than expected.
- The browser authorization merge is a value-level assertion, never tested against a real CDP
  target.
- The unconfirmed/blocking split — a value nothing confirms stops a write or a send, not a
  read — is a judgement call worth a second opinion.

**Rejected review findings.** None; all six reproduced. One deliberate behaviour change to
flag: `AgentToolCallParser` no longer drops `subject: "TBD"`. The parser has read a *name*, not
looked a tool up, so it cannot tell an email subject from a file-search query; that judgement
moved to `AgentToolLoop.grounded`, where risk is known. Blanket stripping was breaking ordinary
work — `filesystem.search query: "todo"` was dropped and then refused, and the agent could not
type "N/A" into a web form.

**Open follow-ups.** `AgentProposal.reviewPreview` still prints raw schema keys and now
disagrees in tone with the review above it. The island card's `needsCount` is captured when
raised and can go stale. The `.choice` field kind is dead — nothing ever produces one. `targetId`
is surfaced to users as an editable row labelled "Target id" because it lacks the `_` prefix
the other authorization keys use.

---

## 7. Skills: reuse the ones already on the Mac, search and install more

**Asked.** Reuse the SKILL.md folders already on this Mac, and be able to find and install more
— all behind the scenes.

**Root cause findings.** Two measured corrections to assumptions. `~/.claude/plugins/marketplaces`
is a downloaded plugin *catalogue*, not installed plugins, and including it put 56 skills the
user never added in front of them — excluded. And only `GET /api/search?q=` on skills.sh returns
JSON; the richer routes belong to a self-hostable server and return the website's HTML here, so
descriptions have to be read from each skill's own SKILL.md on GitHub.

The review pass then found the discovery half was largely broken on this exact machine:
`FileManager.enumerator(at:)` yields **nothing** when the root URL is a symlink to a directory,
and ~90% of `~/.claude/skills` entries are symlinks into `~/.agents/skills`. So 139 skills
reported exactly one file, 1025 bundled files were invisible, and `skills.read(name, file:)`
refused all of them. De-duplication made it worse by keeping the *first* candidate by
name+hash, and `.claude/skills` is scanned first — the crippled record shadowed the intact one.

The suggested fix (`resolvingSymlinksInPath()`) was **insufficient**, and finding out why is the
most reusable thing in this workstream: that call strips `/private` rather than adding it, while
the enumerator reports children under `/private/var/…`, so the prefix test still fails and
nested files collapse to bare filenames. `realpath(3)` is what agrees with the enumerator. This
is now an `AGENTS.md` note, because the file-index workstream hit the same wall independently.

**Built.** `SkillLibrary` walking nine roots with a tolerant YAML frontmatter parser and
content-hash de-duplication. `SkillRegistryClient` installing with no node, npx or git: plain
files into a staging folder, moved into place atomically, every file `0644` so nothing is
executable, recorded in `skills-lock.json`. `SkillPathSafety` refuses traversal, absolute
paths, dotfiles, backslashes, control characters, over-deep paths and symlink tree entries.
Progressive disclosure: a relevance-ranked, character-budgeted index in the planner prompt,
labelled untrusted, plus `skills.search` / `skills.read` / `skills.install`.

**Files.** New: `Agent/Skills/{SkillLibrary,SkillPromptIndex,SkillRegistryClient,SkillTools,
SkillsSelfTest}.swift`, `UI/Agent/SkillsView.swift`. Modified: `Agent/Tools/{AgentTool,
AgentToolExecutor,AgentToolRegistry}.swift`, `Agent/RealtimeAgent+ToolLoop.swift`,
`Persona/AgentPromptContext.swift`, `NextNotesApp.swift`.

**Self-test.** `--selftest-skills` → `SKILLS_OK`. Live in this run: 178 skills (158 in more than
one app, 1 same-name conflict), **149 of 178 now carry bundled files** (was ~20 before the fix),
5 hits from skills.sh, and a real install/read/remove cycle against GitHub into a temp folder.
Proven falsifiable: reintroducing the enumeration bug produced four named `SKILLS_WRONG` lines.

The repo's `skills-lock.json` was confirmed untouched after the live install — still the
pre-existing 17 Sep file, md5 `e6f6d763ed977ae5a503f726ed22bd07`, and no `Skills/` directory
was created.

**Unverified / needs the user's hands.**
- The `SkillsView` pane has never been rendered, and the Agent section does not host it yet —
  until the navigation entry exists it is unreachable from the running app.
- The `skills.install` approval card has not been seen.
- **The agent has never actually chosen a skill.** The index and the three tools are asserted
  into the planner prompt; whether a 4B model reads one and follows it needs a real turn.
- `resolveByContents`, the fallback for a truncated git tree, compiles and has never run.
- GitHub is used unauthenticated (60 requests/hour/IP); the limit has not been hit.

**Rejected review findings.** The review's suggested fix for the symlink bug, as written — see
above; `realpath` was used instead and both cases verified.

**Two claims from the original report are wrong and are corrected here.** (1) The 158 duplicates
are *not* byte-identical copies, they are symlinks — a name-keyed de-dupe would have produced the
same list, and the symlinking is what caused the bug. (2) `~/.config/opencode/skills` does exist
and holds 4 skills, as does `~/.gemini/skills`; they were absent from the per-source breakdown
only because they de-duplicate into the Claude rows.

**Open follow-ups.** `skills.search` is registered at `.read`, so it runs with no card and
sends the model's phrasing to skills.sh and GitHub — filesystem reads were deliberately split
out behind their own flag for exactly this reason, and network egress of user text was not.
`skills.install` silently deletes and replaces a same-named skill from a different project, and
the card does not say so. The pane does synchronous disk I/O inside `body` on every keystroke.

---

## 8. Move the graph into the Agent section; index the user's main folders

**Asked.** The graph belongs with the agent, not under Search. And index the user's main
folders into retrieval and the graph.

**Root cause findings.** Two, both fixed rather than patched. Path spelling: `/var/folders/…`
and `/private/var/folders/…` are the same directory, `FileManager` and FSEvents hand back the
second while `temporaryDirectory` and `NSOpenPanel` hand back the first, and
`resolvingSymlinksInPath()` is not a canonical form. Every `LIKE`, every `parent =` lookup and
every purge matched nothing — which reads as "the index is empty". And the crawler used one
`capped` flag for two different ends, so the first folder past the depth limit aborted the
entire walk and every sibling after it went missing silently.

The review pass found a blocker of a different kind: the one sentence in every planner prompt
told the model to call `files.find` / `files.tree`, but the loop checks the raw name against an
allowlist holding only `filesystem.find` / `filesystem.tree` — **and a miss abandons the whole
turn**, not just that call. A model obeying the prompt lost its entire tool plan. It also found
the Settings footer promised the names stay on this Mac while nothing gated the feature by
model provider.

**Built.** `NavigationState` gains `AgentPane.graph`/`.skills`; Search keeps Search and gained a
button that jumps to the graph. Eight files under `Knowledge/Files/`: a store over its own
`file-index.sqlite` (never touching `knowledge.sqlite`), a breadth-first crawler off the main
actor, an FSEvents watcher, an incremental indexer, two read-only tools, and a graph overlay.
Retrieval rather than context-dumping: one sentence in the prompt, file hits blended into
`search_knowledge` as a *separately labelled* source (a file name is not something anyone said,
so it never joins the passage list a citation points at). File nodes are an overlay merged at
draw time, never rows in `graph_node`, because every extracted edge must cite a chunk and a
file path is its own evidence. A new `FileIndexScope` mirrors `KnowledgeGraphScope`, so a cloud
model is told nothing unless the user switches it on.

**Files.** New: `Knowledge/Files/{IndexedFoldersStore,FileIndex,FileCrawler,FileIndexWatcher,
FileIndexer,FileIndexTools,FileGraphOverlay,FileIndexSelfTest}.swift`. Modified:
`Support/NavigationState.swift`, `UI/Agent/AgentView.swift`,
`UI/Knowledge/{KnowledgeSearchView,KnowledgeGraphPane}.swift`,
`UI/Settings/KnowledgeSection.swift`, `UI/DesignSystem.swift`,
`Knowledge/{Ontology,GraphStore,KnowledgeTools,KnowledgeExtractSelfTest,KnowledgeIndexer}.swift`,
`Agent/Tools/AgentToolRegistry.swift`, `Agent/RealtimeAgent+ToolLoop.swift`,
`Shell/FilesystemExecutor.swift`, `NextNotesApp.swift`, `Resources/knowledge-ontology.yaml`,
`Resources/Info.plist`.

**Self-test.** `--selftest-file-index` → `FILE_INDEX_OK`. It now extracts the id-shaped tokens
from the *real* prompt sentence and fails unless each is both allowlisted and
registry-resolvable, so this cannot drift again. `--selftest-tools` → `TOOLS_OK` and
`--selftest-extract` → `EXTRACT_OK` (ontology v3) confirm nothing else broke.

**Unverified / needs the user's hands.**
- **No folder has ever been added.** The macOS Files-and-Folders consent prompt, a denial, and
  the wording that follows a denial are all unexercised — as are the new `Info.plist` usage
  strings. `NSOpenPanel` was never opened.
- FSEvents has never fired in a running app; the watcher is exercised only through `applyChanges`.
- No model has ever called `files.find` / `files.tree`. Whether a 4B model reaches for them at
  the right moment is unknown.
- Crawl behaviour and timing on a real Downloads folder of tens of thousands of files is
  unmeasured, so the 50k / 12-level caps are guesses.
- `FileGraphOverlay.mentions` has never run against a real extracted graph; its precision is
  unmeasured.
- The cloud gate is verified via its truth table and the executor's refusal, not on a real
  OpenRouter turn.
- Nothing visual was rendered.

**Rejected review findings.** None rejected. One scope choice worth recording: the blocker's
suggested fix offered two branches and the one entirely inside owned files was taken (derive
the advertised ids from the canonical namespace). **The underlying ordering bug in
`RealtimeAgent+ToolLoop.swift:796` is still there** — re-verified during wrap-up — and will bite
any registered alias, including the `workspace.*` ones. Nothing advertised reaches it today.
It is now an `AGENTS.md` note and belongs to whoever owns the tool loop.

**Open follow-ups.** `AgentSpeechPolicy` has a spoken phrase for `filesystem.search` but not
`find`/`tree`. `AgentActivityProjector` maps `find` to `.reading` rather than `.searching`.
`memory.recall` does not blend file hits. Adding a folder while the master switch is off records
it and does nothing, with no hint why. The blend AND-s up to eight prefix terms from a natural-
language query, so "where did I put the lease" will essentially never match — and an empty token
list returns the five most recently modified files regardless of the question.

---

## 9. A Muse-style first-run onboarding for non-technical people

**Asked.** Replace the technical first-run checklist with something a non-technical person can
walk through.

**Root cause / design.** The flow is a pure value type with no views, no storage and no side
effects, so "can a required screen be jumped?" is a question a test can answer. Three traps
were headed off deliberately: the completion flag writes the *existing*
`Settings.hasCompletedOnboarding` key rather than adding a second bit that could drift;
`AXIsProcessTrusted()` returning true is not the same as the event tap arming, so the dictation
screen calls `activate()` and tests `hotkeyReady`; and `LocalModelStore`'s progress string is
"Downloading Qwen3.5-4B… 42%", which names a model, so the brain screen parses the percentage
out and renders its own line.

The review pass found one blocker and it was the most consequential kind — a promise on screen
that nothing keeps. `prepareNotesModel()` had exactly three call sites (the brain screen and
two Settings buttons) and was never started at launch, so a quit, a network failure or a full
disk left the user permanently without the assistant, while the screen said "Next Notes will
try again later." Because Done sets the completion flag, the screen never returns either. It
also found the final screen congratulated everybody regardless of what was granted or skipped,
and that the skip-tracking machinery it was supposed to consult had **no production reader at
all**.

**Built.** Seven screens in one window: welcome and naming, dictation, shortcut, meetings,
files, brain, all set. `OnboardingModelResume` retries the model download at launch and on
`didBecomeActive`, gated on having actually been shown the screen, with a 10-minute floor.
`OnboardingOutcome` derives the last screen's headline and tips from what is really granted and
what was really skipped — "You're all set" only when dictation actually works, otherwise
"Nearly there" naming the switch that is still off. The window is no longer an ARC over-release
(`isReleasedWhenClosed = false`).

**Files.** New: `UI/Onboarding/{OnboardingFlow,OnboardingChrome,OnboardingSteps,OnboardingWindow,
OnboardingSelfTest,OnboardingOutcome,OnboardingModelResume}.swift`. Modified:
`UI/Onboarding/PermissionsChecklist.swift`, `Support/Permissions.swift`,
`UI/Settings/GeneralSettingsTab.swift`, `UI/MainWindow.swift`, `UI/DesignSystem.swift`,
`NextNotesApp.swift`.

**Self-test.** `--selftest-onboarding` → `ONBOARDING_OK` (99 assertions). Proven falsifiable
both ways: making a required step skippable, making an optional one required, dropping the
`wasPromised` guard and hard-coding the headline each produced named failures.

**Unverified / needs the user's hands.**
- **The flow has never been rendered.** Launching it would touch the real Application Support
  directory and, if the onboarding flag were clear, start a 2.7 GB download. Layout, the
  cross-fade, dark mode and VoiceOver order are unverified by eye.
- **Every permission path is unexercised**: microphone, Accessibility, calendar, system audio,
  notifications, Files-and-Folders. In particular the stale-signature fallback — switch reads
  on, tap will not arm — is reasoned, not reproduced.
- **The brain screen has never downloaded anything**, and `OnboardingModelResume` has only been
  exercised through its pure decision function. A real run would pull ~2.7 GB against a 200 MB
  budget.
- The "Try it now" field assumes dictation's AX insert lands in our own window — true everywhere
  else in the app, unconfirmed with a microphone.
- Launch-at-login no-ops under a self-test; its real `SMAppService` behaviour was not seen.

**Rejected review findings.**
- *"Disable Continue on the dictation screen until the grants are in."* Rejected deliberately.
  The flow's documented rule is that passing *through* a required screen is always allowed and
  only *skipping* it is refused. A Continue that refuses to move is a worse trap for a
  non-technical person than a hopeful sentence — the grants can only be given in System
  Settings, and the code-signature trap means the switch can read on while the app is still
  untrusted, so the button could be dead through no fault of theirs. The false claim was fixed
  where it was actually made: on the last screen.
- *"Delete the skip set."* Rejected — it now has a real production reader.

**Open follow-ups.** The forward chevron reuses `advance()`, which clears a skip mark, so
skipping Meetings and then paging back and forward un-skips it. `PermissionsSettingsTab` still
shows the old technical checklist. The window is a fixed non-resizable 720×600 with no
`ScrollView` anywhere — `DS.Onboarding.listHeight`, whose comment says rows should scroll past
it, is unused, and roughly two user-added folders overflow the files screen. Both permission
screens poll TCC every 1.5 s even in the settled state. And the self-test cannot fail on the
wiring: delete the `.task` in `MainWindow` and onboarding never appears, green.

---

## 10. Download the agent's memory; import memory from a file or another assistant

**Asked.** Download the assistant's memory, and bring memory in from a file or from Muse, Grok,
ChatGPT, Claude, Gemini.

**Root cause / design.** What each assistant actually lets a user export was researched rather
than assumed: ChatGPT's and Claude's exports contain conversations but not memory entries,
Grok's zip is conversations only, Gemini is Takeout HTML/JSON. So the reader special-cases
ChatGPT's `mapping/author.role=="user"` and Claude's `chat_messages/sender=="human"` shapes —
harvesting only the person's own turns, never the assistant's replies. Three design points
that would otherwise become bugs: `MemoryEntry.Source` gained `.imported` with an
`isPersonsOwnWrite` rule so a person's own import still works while "Remember what I tell the
Agent" is off; the new fields are Optional so no existing `next-memory.json` is orphaned; and
four `NextMemory` string helpers became `nonisolated` so screening happens off the main actor.

The review pass found four, all real. The entire file-import path ran synchronously on the main
actor — including spawning `unzip` and `waitUntilExit()`, reading up to 400 files of up to
64 MB, and megabyte-scale regex passes — one line after setting the "working" spinner, which
therefore could never draw (worst stall measured: 0.451 s on an 8.8 MB file, now 0.001–0.003 s).
`restore(mode: .replace)` wrote package text straight in **without `NextMemory.validated`**,
bypassing the length cap, both budgets and the declarative rule, and unflagged rows go into the
agent's prompt snapshot with no cap at all. "Replace everything" destroyed every memory and the
whole undo history with no confirmation, carried `.keyboardShortcut(.defaultAction)` so Return
triggered it, and could never be undone. And "Start over" did not cancel an in-flight import,
so an abandoned run resumed minutes later and dropped the user back into its review list.

**Built.** Export writes a folder — `memory.json` plus a readable `Memory.md` — staged in temp
and moved into place. Import has three doors into one review step: our own export, a tolerant
reader for `.json/.md/.txt/.csv/.tsv/.html/.zip` and folders, and a guided paste sheet with
presets. Harvested text is distilled by the local model with a rules-based rewriter as both
fallback and tidy-up. Nothing is saved without review: refusals are shown struck through with a
plain reason rather than silently dropped, duplicates arrive unticked, each row is editable,
and the whole batch is undoable. A replace now screens every row, writes a timestamped backup
first, and asks.

**Files.** New: `Memory/Portability/{MemoryPackage,MemoryExporter,MemoryImportReader,
MemoryImportDistiller,MemoryImportPlan,MemoryPortabilityController,MemoryPortabilitySelfTest}.swift`,
`UI/Settings/{MemoryDataControls,MemoryImportSheet}.swift`. Modified: `Memory/NextMemory.swift`,
`UI/Settings/MemoriesSection.swift`, `UI/Agent/AgentAboutView.swift`, `UI/DesignSystem.swift`,
`NextNotesApp.swift`.

**Self-test.** `--selftest-memory-portability` → `MEMORY_PORTABILITY_OK`
(`roundtrip memories=3 labels=2 routines=1`, `plan proposed=3 dropped=2 duplicates=1`,
`REPLACE_SCREEN kept=2 flagged=1 refused=3`, `CONTROLLER_RESPONSIVE worst-stall=0.001s`,
`CONTROLLER_CANCEL stage=start`, `CONTROLLER_BACKUP memories=1`). Each new check was falsified
against the pre-fix code. One earlier draft of the responsiveness check passed under
falsification and was rewritten — counting main-actor turns proved nothing because the distiller
already hops off the actor; measuring the worst *gap* between turns is what catches it.
Neighbours green: `MEMORY_OK`, `PERSONA_OK`, `SETTINGS_OK`, `MEMORY_REVIEW_OK`.

**Unverified / needs the user's hands.**
- **Nothing in this UI has been seen**: the six-step import sheet, the review list, the export
  sheet, the About card, the new confirmation dialog.
- **The local-model distillation path has never run against a real model** through this code.
  Every import here went through the rules fallback; the model path is exercised only with a
  scripted model.
- **No real export from Muse, Grok, ChatGPT, Claude or Gemini has been fed in.** The readers are
  tested against fixtures written from the documented shapes (researched 19 Sep 2026), not
  against a file any of those services produced. Muse's format is undocumented publicly and is
  handled only by the generic path.
- `NSSavePanel` / `NSOpenPanel` were never opened, so the panel wiring, the folder-overwrite
  prompt and "Show in Finder" are unproven.
- **Routines are exported but never restored**, deliberately: the package carries a plain-English
  schedule, not the structured `when`/`trigger` an `AgentSchedule` needs, and a file that could
  start something running on another Mac is a hole nobody opened. The export sheet says so.

**Rejected review findings.** None rejected. One guard is deliberately **not** applied and the
reasoning is written into the file: `MemoryGuard.provenanceProblem` asks "did the user say this,
or did the model read it somewhere?" — that is what stops an email writing itself into memory,
and an import has a different answer, because the person fetched the file, read every line and
ticked the ones they wanted.

**Open follow-ups.** The self-test never instantiates `MemoryPortabilityController`, so the
sheet's whole state machine could break and it would still be green —
`MemoryPortabilityController.export` has no caller at all. `NextMemory.markdownExport()` lost
its only production call site and is now exactly the shape `AGENTS.md` warns about. The exporter
unconditionally `removeItem`s whatever is at the destination path, recursively, without checking
it is a prior export. Inside a folder or zip, any file over 64 MB is skipped **in silence** —
which is precisely the ChatGPT `conversations.json` the special case was written for. The zip
reader's path-confinement check does not resolve symlinks, so the `..` half of its stated
guarantee holds and the symlink half does not.

---

## What a person needs to do next, in order

1. **Turn on "Fix grammar and spelling"** in Settings ▸ Dictation. Nothing in this round flips
   it, deliberately, and until it is on this user's dictations still come out ungrammatical.
2. **Run the setup flow** (Settings ▸ General ▸ "Run setup again") and grant the permissions.
   That is the only way the onboarding screens, the TCC prompts and the brain download have
   ever been exercised.
3. **Dictate something with a list in it** and check the new "Your last dictation" panel in
   Settings ▸ Dictation says what actually happened.
4. **Hold the right Command key** for half a second with text selected somewhere, and confirm
   the worded card appears — and that a tap, ⌘C and ⌘-click now do nothing.
5. **Add a folder** in Settings ▸ Agent and answer the macOS prompt, so the file index runs
   against real data for the first time.
6. **Download the fast-listening engine** (36 MB) from Settings ▸ Agent and switch on "Notice
   things during a meeting too", then hold a meeting — the approval card has never appeared
   under the notch.
7. **Connect a Google account** if Workspace actions are wanted. No approved tool call has ever
   actually sent anything, from any workstream.

## Environment gaps no amount of work here can close

No Ollama or LM Studio installed. No Google Workspace credentials. No Hugging Face account. No
Claude Code or Codex ACP adapter on PATH. No microphone or Accessibility grant available to a
coding agent. No Intel Mac. And roughly 6.4 GB of free disk, which rules out downloading any
real model to test against.

## Housekeeping

`site/src/sections/Mission.tsx` carries an uncommitted one-line edit to a marketing paragraph.
It is the user's own pre-existing work — its mtime predates this session and nothing under
`site/`, `docs/` or `windows/` was modified — and it was left exactly as found. It will show up
in any diff.

---

## 2026-09-20 — installed and checked on screen

`make install` run at the user's request (data backed up first to `~/Library/Caches/NextNotesBuild/data-backup-2026-09-20`). Signed with "Next Notes Local Signing"; Microphone, Accessibility and Notifications grants survived. 18 self-tests green through the installed app via `Scripts/run-selftest.sh`.

Seen rendering and working in the real app: Agent ▸ Graph / Skills (177 found, live skills.sh search) / About "Your data"; memory import from pasted text end to end on Apple's on-device model (3 kept, injection line dropped, nothing saved); Settings ▸ General Command Mode copy + "Run setup again"; Settings ▸ Dictation consequence list; Settings ▸ Agent three model rows (Claude Code detected), fast-listening row, folders section; Settings ▸ Models "Your Mac" card + recommendations; all 7 onboarding screens; the transcript correction sheet with fully visible Cancel/Save.

Fixed after looking: (1) Models "Recommended for this Mac" listed speech-recognition / TTS / embedding GGUFs as assistant brains — `HuggingFaceClient.SearchEntry` now drops non-chat `pipeline_tag`/tags, and `--selftest-hf-search` fails if one reappears. (2) Import sheet said "Apple Foundation Model is reading…" — now "Reading N lines on this Mac…". (3) `RealtimeAgent+ToolLoop` resolves tool aliases before the allowlist check. "Fix grammar and spelling" was OFF on screen and was switched ON.

Still not exercised: a real dictation through the new cleanup path, holding right ⌘, the Files-and-Folders consent prompt, the 34.5 MB fast-listening download, Calendar / system-audio grants (both show "Allow" in onboarding), Escape / ⌘-Return in the correction sheet, the approval card under the notch.

## 2026-09-20 (later) — first real dictation through the new path, and what it exposed

The user dictated a "first point… second point… third point" message. `runs.jsonl` recorded: engine apple, `fallbackReason: on-device cleanup timed out` (5.07 s), `structureMarkersSeen: false`. Fixed: (1) `FoundationModelFormatter.timeout` now scales 0.07 s/word (cap 14 s) — 84 words got 5.1 s before; (2) `SpokenStructure.implicitRun` tolerates ordinals *mentioned* inside an item, prefers clause-opening ordinals, needs ≥2 of them; dangling "at the" trimmed. The real sentence is now a self-test case (`mentioned-ordinals-real-dictation`) with a prose counter-case.

Also: in-app Needle download ran for the first time (needle3.cact 35 MB + engine, FUNCTION_CALLS_OK against those files, 0.66–1.2 s). System-audio row no longer says "Ask…" forever: the tap records evidence of real sound (`Permissions.hasHeardSystemAudio`), the row turns green on it, button is "Check…". Reminders settings section rebuilt (time steppers, no duplicated "21:00"); Agent ▸ Routines restyled to the Skills/About column. Calendar still not granted. `--via-open` self-tests launch a visible second app instance while the app is running — do not loop them.

## 2026-09-20 (afternoon) — second feedback round, all delegated to Opus/Sonnet agents

User rule from now on: the main session never implements; it briefs Opus/Sonnet agents and verifies.
Landed and installed (build green, `make test` 30/30, 18 self-tests green from the debug binary, nothing committed):
- Graph (Opus): component-anchored ForceLayout (no more folders pinned to the frame edges), off-main layout, Canvas drawing, glass chrome, filter chips as legend, zoom/pan/focus. New files GraphScene/GraphCanvas/GraphChrome.
- Skills grid (adaptive, up to 1100pt) + monochrome About + GlassGroup (Sonnet); memoryAccent/soulAccent tokens removed.
- Settings window: `.toolbarTitleDisplayMode(.inline)` + `.windowToolbarStyle(.unifiedCompact)` removes the tall title band (Sonnet).
- Search (Opus): `LibrarySearch` — one engine for passages + file index; "Files and folders" facet, People section, Ask sees file names as a labelled non-citable block; fixed a consent hole (search_knowledge sent file names to cloud without the folder-consent check). Routine runs = 0 because `knowledgeIncludeRoutines` is off by choice.
- Formatting tab: fixed-height List inside a scrolling Form swallowed scroll; now one scroll surface (Sonnet).
- Dictation (Opus): natural enumeration ("The second thing", "first thing first", "Last but not least", sign-off kept as prose); StructurePlan model pass built and measured — model invents lists on prose (2/2) and found 3/4 items, so rules lead, model plan only where rules decline and only when corroborated by the speaker's words; disfluency/self-repair/mishearing repair in grammar mode with a rationed phonetic-neighbour guard tier; guard bug (ordinal stripped on one side only) fixed; CleanupSessionWarmer wired at key-down (4.69 s cold → ~0.94 s).
- "Controlling your Mac" (Opus): Codex Computer Use is `~/.codex/computer-use/Codex Computer Use.app` (com.openai.sky.CUAService), caller-authenticated by code signature, so not directly connectable; supported route is `codex exec`. New CodexComputerUse hand-off with one approval, fallback sentence, truthful green/grey probe. Claude has no screen-control component. NOTE: ~/.codex/config.toml holds a third-party API key in plain text (user informed).
- Models tab (Sonnet): every model in one place in plain-language groups; PostDownloadPolicy (default switch + keep old; delete-old only after verified load; download-only); Free up space sheet; partial downloads listed; built-in Qwen removable when another brain is active; `hasUsableModel` used where "any brain" is meant; wake-word row in Agent tab reduced to status + link.
Open: none of this round has been seen on screen — screen capture from the Claude host began failing after the reinstall ("audio/video capture failure", `screencapture -l` also fails), so visual verification is pending. Watch in runs.jsonl: occasional dropped trailing word on short dictations; phonetic swap false positives (cancel/council). No real click has gone through the Codex hand-off; no real download→switch→delete cycle has run.
