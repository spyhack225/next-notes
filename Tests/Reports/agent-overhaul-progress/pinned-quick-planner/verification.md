# Explicit planner pin in the existing quick runner — 2026-10-06

Scripts/pinned-quick.py now accepts optional --planner prompt|native, forwards it unchanged on each existing process and records it in the same summary. Omitting it preserves current planner selection. Model pin, fixture clock, sampler, three-run minimum, identity/admission and grading checks are unchanged. No parallel runner/grader or model/default change.

Existing pinned-quick-selftest.py retains all sixteen predicates and reuses its transport helper for three additional regressions: both explicit modes across three launched argv sequences, unchanged default absence, and invalid mode rejected before machine/launch. Against the original runner, the explicit-mode subcases fail twice. The same persisted suite passes nineteen tests after the six-line runner fix; below-bar7/10 remains a true failure in the transport fixture. Syntax/scoped whitespace PASS; disposable fake fixtures are removed.

Raw RED/GREEN and exact patch remain outside iCloud at ~/Library/Caches/NextNotesBuild/integration/pinned-quick-planner/. This verifies CLI command transport, not native model quality, ASR/voice floor, or default promotion. No application source changes/rebuild are needed for this runner-only slice.
