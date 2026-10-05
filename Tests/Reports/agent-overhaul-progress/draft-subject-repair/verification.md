# Model-authored email subjects — 2026-10-05

Confirmed cause: the actual prompt planner emitted the retained M04 draft call without its required subject. ToolStepRunner routed that creative omission to execution/review instead of its existing planner repair opportunity. The native grammar was not the active path.

The runner now returns omitted/blank subjects to the same planner once, within its existing call, repair and time budgets. It composes no subject or recipient itself. Supplied subjects stay intact; repeated omissions stop plainly. Real review still requires one approval before the draft write.

Original production fixture: RED9 on app31638. Identical fixed regression: TOOLLOOP_PRODUCTION_OK on app47980. Cases cover the exact retained model output, empty/whitespace, prior repair, call cap, exact model-authored card contents, zero writes before approval, one approved backing call, missing-recipient refusal and joined work.

Related checks, once: TOOL_REVIEW_OK, TOOLLOOP_LIVE_GRADER_OK, ACP_CONFIRM_OK and STORE_ISOLATION_OK (21 files, 32 defaults unchanged). All five flags exited zero. Common RED also corrects the pre-existing truncated-call positive's second scripted response to include its required subject; original truncated input/assertions are unchanged in both builds.

Raw comparison, patches and logs: ~/Library/Caches/NextNotesBuild/integration/draft-subject-repair/. No evidence bundles added to the repository. This scripted external-model regression proves production routing/review, not live-model subject composition or a new quick score. The 9/10 quick and broader voice/owner gates remain open; no model/default promotion.
