# Actual-source boundary repair; corrected root probes now pass

The first baseline/fixed executions both compiled and then failed eight longform assertions. Their original stdout/compile/compare/guard verdicts remain unchanged in the public legacy-parity report directory. Evidence33 passed only in fixed; it did not prove default longform correctness.

The confirmed primary cause is the shared MeetingNotesBrief stub: it omitted the actual prompt labels. For the unchanged original 1,400-character memory + 1,400-character decisions fixture, the stub brief measures 704 tokens under the exact fixture counter; the real producer text measures 734. Twelve original map chunks with the real brief produce combined facts+brief of 2,561 tokens against the 2,560-token budget, forcing the original collapse/drop path. The incorrect stub fit inside the budget. The counter stub also lacked real h:mm:ss formatting; correcting it alone still gives twelve chunks and does not resolve collapse coverage.

Stubs now embed the exact pure MeetingNotesBrief source, exact actual TimeInterval.counterText and exact transcript plainText extension. Both baseline and fixed share these identical boundaries. The original supplied ninety-minute transcript, 4,096-token window, original provider, original brief and original assertions remain intact. No smaller transcript/window or weaker original drop assertion is used.

The agent-added no-context case had an independent invalid assumption: with the same twelve chunks and no brief, the facts occupy 2,559 tokens and never need collapse. This failed attempt is retained in the prior stage/logs. The new separator assertion now augments the unchanged original stubborn+brief case, exercising the same NotesGenerator assembly seam and requiring a separate paragraph. The actual private no-context `_None.__Part..._` marker remains the original product failure evidence; this generic case does not claim to reproduce every aspect of that owner output.

The common parity probe dropped case now uses the exact original stubborn+bigBrief input. Its comparator requires positive collapse/drop in both results, original single-newline warning versus fixed three-newline warning, then exact equality of prompts/tokenization inputs/budgets/typed results/other text. The source fix remains the same two-newline assembly insertion. The initial failed probes are not relabeled as passes.

Compile/run only after root's coordinated heavy window ends. The corrected default opt-in patch and optional after-opt-in comprehensive prompt patch are separate. fixed-comprehensive and actual-source-comprehensive contain the same corrected fixture boundaries. No compiler/model call or canonical source write occurred in this staging step; all runtime and native acceptance remains pending.

Corrected cache stage: `/Users/sergekadjo/Library/Caches/NextNotesBuild/meeting-notes-optin-boundary-q46cenqz`. Its source-only plan and manifest are retained there.

## Root-executed corrected verification

The root subsequently compiled and executed baseline, fixed and comprehensive probes. Baseline fails only the new separator assertion. Fixed and comprehensive pass the unchanged original longform/drop checks plus separator and 33 evidence checks; both exact legacy comparisons and SelfTest-false explicit-option guard pass. The original drop input produces 12 chunks, two collapses and one drop. See corrected/summary.json and the retained logs. This verifies the source-level assembly/legacy contract with boundary stubs; native semantic quality remains open.
