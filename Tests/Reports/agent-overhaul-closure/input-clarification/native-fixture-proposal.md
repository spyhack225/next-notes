# Actual native input consumer fixture — unapplied

No Swift source in this proposal has been applied or compiled. Root owns registry, builds and native operation. The bounded production scope is only typed local `filesystem.read` / `path`.

The existing `AgentView` has no injected task-manager initializer. Its conversation displays the real waiting row through `taskRow` -> `inputCard`. Reuse that complete view and its current `chooseInputFile` / `submitInputAnswer`; do not construct a duplicate card or call a fake panel completion.

## Small existing seams

1. Replace only the task manager's default `@State` initializer with explicit `init()` supplying `.shared`, plus a harness-only `init(inputFixtureManager:)` supplying that manager. A read-only manager getter must require `SelfTest.isRunning && store.allowsHarnessPersistence` before accepting the fixture manager. This keeps owner persistence out of the new constructor.
2. Track whether this view was explicitly injected as a private immutable Bool. For that instance only, skip the two existing NotesModelRuntime prewarm callbacks. Normal view behavior is unchanged; the fixture must not load or run a model merely to display a file question.
3. Use `NSHostingView(rootView: AgentView(inputFixtureManager: fresh))` in its own titled native window. Supply `.defaultAppStorage(SelfTestHarnessDefaults.store)` after checking the existing harness defaults API. Temporarily select the existing Conversation navigation state and restore it afterward; do not persist navigation, draft or inspector changes to owner defaults.
4. A new `@MainActor` self-test helper needs `SelfTest.isRunning`, an empty permission gate, injected temp stores, before/after owner store/default guards, saved/restored Executor final-effect hooks and no model. Root adds the requested flag to its existing registry.

## Exact real interaction sequence

- Create `chosen-note.txt` under one explicitly isolated `NextNotesTaskInputNative-UUID` directory, with distinctive fixture content. Restrict the existing final fire hook to the exact `filesystem.read` plus `arguments == ["path": chosenFile.path]`; anything else fails before touching a backing. Allowed fire invokes real `FilesystemExecutor.run`, increments one effect counter and checks the exact result. Never use `fakeForTesting`, which bypasses pre-effect validation.
- Submit the actual incomplete task with the original manager; await its committed input request. Reopen a fresh manager on the same actual primary store. Require exact retained request identity/tool/key, no backend start, no permission token or card. Host this fresh manager's actual AgentView.
- Print `TASK_INPUT_NATIVE_CANCEL_READY` with only the fixture window title. Root CUA verifies the visible question is “Which file?”, Choose file and Cancel are present, and no raw-path editor or Continue exists. Root presses Choose file, then cancels the actual native panel. The fixture observes a real visible NSOpenPanel appearing and disappearing; it must not synthesize a callback. Require the exact waiting row/payload remain, zero backend starts and zero effects. Root retains the actual visual/native evidence separately.
- Add a primary SQL BEFORE UPDATE rejection trigger. Print `TASK_INPUT_NATIVE_REJECT_READY` and the safe temporary fixture chooser location (this diagnostic is isolated, not usage telemetry). Root opens Choose file again and selects `chosen-note.txt` in the native panel. The callback must directly attempt admission: no second Continue. Wait for `.sqlFailed`, exact same SQL/memory waiting row, zero backend start/effects. Root CUA verifies friendly `chosen-note.txt`, the plain saved-choice failure and Try again remain; raw absolute path and Continue remain absent.
- After verifying the rejection, the fixture drops its SQL trigger and prints `TASK_INPUT_NATIVE_RETRY_READY`. Root presses actual Try again. Await exactly one accepted queued transition/backend start and real temporary read completion. Require no input payload/card, one effect with exact file/arguments/content, and a fresh terminal manager sees the complete canonical primary state without dispatch.
- Restore the previous hooks, temporary navigation state and gate, close only the fixture window and stores, delete only the fixture directory, and require owner guard diff empty. Print one final `TASK_INPUT_NATIVE_OK` / `TASK_INPUT_NATIVE_FAILED` marker. An unattended timeout, missing window/panel or missing CUA effect is FAILED, never OK.

Stage waits may use a small bounded harness-only polling delay; never add a wait to the production callback. Root can observe a retained stage journal in the fixture directory if launch output is buffered. Do not add a queue, production state store, stage controls in the user's card, fake panel action or extra user confirmation.

## Claims and limits

The copied and installed producer tests remain separate. The native fixture would close the actual file-card chooser/cancel/rejected-save/direct-retry consumer evidence only. It proves neither ACP/remote questions nor directory/text clarification, attempts/leases/receipts, retry recovery or IM-16. A screenshot alone cannot prove one effect; the fixture's restricted real backing counter and final primary state supply that evidence.
