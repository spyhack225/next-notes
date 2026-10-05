# Reminder/speaker grading — 2026-10-05

Cause: R02 graded book words without checking actual daily22:00 recurrence; K03 accepted Serge in place of canonical Sarah. The existing grader now parses R02 through the native schedule parser and checks reminder/daily22:00 semantics. Its bounded complete-budget-statement check compares the named speaker with Sarah, including unseen names; it does not rewrite product output or claim general entailment.

Exact retained original calls/replies plus valid controls fail11 originally and pass unchanged after the grader fix. A first fixed attempt captured across two sentences; narrowing the name capture to a sentence boundary keeps the original multi-statement control green. Production loop, full capability, schedule, persona and owner isolation pass. All authored temporary roots are removed after joins.

Earlier quick raw9/9/9 is not a valid9/10 gate: all3 R02 calls omitted repeat and created once. Product reminder recurrence, full K03 model attribution and aggregate/model/default gates remain open until native original flows pass. The stricter weekly-days proposal was withheld because it broke prior R01 date qualification; no parser-boundary change is shipped here.

Bulk logs/original cases/source proposals: ~/Library/Caches/NextNotesBuild/integration/agent-visible-completion/, k03-speaker-attribution-grader/, and quick/minicpm-e3ef6e1-quiet-20261005/.
