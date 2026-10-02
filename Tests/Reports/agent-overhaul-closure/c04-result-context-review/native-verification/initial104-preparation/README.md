# C04 retained-result admission prerequisite

Status: off-source proposal and common actual-loop fixture prepared; not compiled or run. No production fix or native C04 quality claim. The installed app103 quick report remains **2/10**, including **C04 UNGROUNDED**. Its intermediate round2 raw response and complete final prompt were not retained, so the specific branch and causal attribution for that native run remain unproved.

The source emits each successful result as `<tool> returned:\n<body>`. The ordinary planner calls `AgentToolLoop.userMessage`, which folds all but the last two entries before the existing token counter runs. A real refusal or unsupported-claim correction shares that array. With mail → correction → calendar, the mailbox body becomes just `search_email returned:` even when the full prompt would fit. `ToolResultBudget.firstLine` therefore cannot supply the summary its older comment describes for wrapped results. Raw tool output remains in `AgentSession`; the first broken contract is result admission into the next ordinary planner prompt.

The common scaffold adds a default-true `foldOlderResults` parameter and passes `false` from the existing measured `fittedPrompt`. Original ignores the new parameter, preserving original producer behavior. Fixed changes only the selection of carried entries in `AgentToolLoop.userMessage`. The planner then measures full admitted results; its existing over-room branches still remove earlier conversation, explicitly fold `keepFull: 1`, and cap to400. Per-tool caps, system instructions, visible output reservations, budgets, tool execution, permission routing, streaming and cancellation are unchanged. This adds no await, timer, model pass, queue or store.

Generic/scheduled callers and `finalAnswerRound` retain default eager folding. That answer-only path has no equivalent fitting loop; disabling folding there blindly could overflow. Result loss under genuine context pressure and the broader answer-only policy remain open. This bounded change does not guarantee model grounding, improve the aggregate grader by definition, promote a model, or complete an Agent phase.

## Common original/fixed fixture

`C04ResultContextSelfTest.swift.txt` is a new isolated self-test conductor, proposed at `Sources/NextNotes/Agent/C04ResultContextSelfTest.swift`. It calls actual `RealtimeAgent.handle(source:.text)` → existing planner/backend → `ToolStepRunner` → actual `AgentToolExecutor.fakeForTesting` seam → **unchanged `LiveEvalFixtures.run`** → wrapped result admission → actual streamed provider consumer. No helper-only prompt call substitutes for this chain. The fake refuses every unexpected tool before backing; both allowed tools must be reads. The real permission/call-validation path remains present, read consent is pinned through the existing test override, and unattended writes stay denied.

Exact C04 utterance, mailbox senders/content and calendar data are reused. The mandatory `--c04-fixture-now <ISO8601>` argument supplies one timestamp retained and reused across both runs for fixture-relative message ages and tomorrow; no selection of owner data or model occurs. The fixture records full synthetic final prompts, actual read arguments, regular planner round counts, raw retained session output, guard notes and budget arguments. It restores all changed test hooks with defer. Harness mode isolates conversation/audit/memory/usage storage; root should also run the existing owner-isolation flag for the mounted binaries. The conductor itself does not snapshot/decode/seed owner payloads.

There are **six modes ×12 checks =72**:

- No correction at8192: both read bodies remain (original positive control).
- Real calendar refusal and real unsupported `get_agenda` claim at8192 and32768: both guard branches append their existing note; mailbox body must remain when counted prompt fits.
- Same claim/read inputs with scripted tokenizer pressure at8192: the original overflow policy may fold mail; calendar and budget constraints must still hold.

The provider is scripted through the existing test-provider seam. Its tokenizer returns2000 for fit controls; pressure returns the declared window only when both bodies occur, forcing the unchanged actual fitting loop to fold. This is structural prompt-consumer proof, **not native tokenization or native model quality evidence**. The scripted final reply is fixed, so its delivery assertion checks unchanged routing rather than a model's ability to use evidence. The substantive target is exact full mailbox-body receipt by the actual provider.

Predicted original target failures: four fit-mode C07 mailbox-body assertions. This prediction is not an executed verdict. Any other failure is a control failure to investigate before applying the fixed producer. Do not omit a failed control or replace the original scenario.

## Root handoff

1. Check source pins and disjoint ownership: `AgentToolLoop.swift`, the ordinary `fittedPrompt` hunk in `RealtimeAgent+ToolLoop.swift`, new conductor and registry. Root owns all application and serial builds.
2. Mount `common-original` plus the identical conductor/registration for original. Archive native stdout/log, installed binary, source/bundle pins and all actual assertions.
3. Only after a valid original failure, mount `fixed-proposal/AgentToolLoop.swift.txt`; keep common runtime argument, fixture, registration and inputs identical. Run the same flag, then existing production tool-loop, live-grader/budget, permissions and isolation regressions as appropriate.
4. Run exact native quick C04 and required aggregate gates through the existing harness. Preserve actual native verdicts; original103 grounding is unresolved until real evidence verifies it. No grader/output sanitizer or prompt tuning is proposed.

Suggested dedicated flag: `--selftest-c04-result-context`; root registration propagates the returned marker to `SelfTest.failed` and the existing `writeSelfTest`/`NSApp.terminate(nil)` lifecycle. No Source was applied by this worker.

Registry integration is now supplied as the exact current-source `registry.patch.txt` plus full original/common `NextNotesApp.swift.txt` snapshots. The branch returns `true`, preserves `SelfTest.failed` marker propagation and uses the existing termination lifecycle. `SelfTest.requested` recognizes any non-harness `--selftest…` flag; `--c04-fixture-now` is not a test flag and requires no startup classifier change. Capture a current ISO8601 timestamp once, retain it in the executed input manifest, and pass that identical value after `--c04-fixture-now` for both runs. The local date must still match the existing device clock for tomorrow; do not rewrite production date grounding to fit the test.
