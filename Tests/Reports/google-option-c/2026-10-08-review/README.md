# Google review repair, first native batch

Reviewed source: `ddf30b7b7a04addb0491a0837bd4316ca6ef96c9`. This is retained V1 evidence;
the final candidate and additive Calendar cache regression are in
[the V2 report](../2026-10-08-review-withdrawal/README.md).

One normal-gate FIFO `heavy.sh` slot ran review RED, fixed seven flags, three
producer mutations, and restored seven flags. `Tests/GoogleReviewChecks.sh` is
the runner. `slot-metadata.json`, source/binary SHA files, raw build/native logs,
fixture hashes and replay/mutation patches retain provenance. Native RED is a
producer replay retaining the new fixture signatures and gates, not untouched HEAD.

The six-finding RED exits 1 / `GOOGLE_CONNECT_FAILED`: 68 failed assertions,
including R1 39, R2 6, R3 5, R4 5, R5 2, R6 10, plus legacy-route adoption.
Fixed and restored Google each pass 315 assertion lines / `GOOGLE_CONNECT_OK`.
All seven native root exits are zero in both batches. `verdict.json` retains counts.
Revocation, unpinned backing and mailbox mutations exit 1, with their required
specific assertions (6 / 1 / 7 failures respectively), then restore successfully.
Fixture hashes are unchanged. Wrapper exits zero / `GOOGLE_REVIEW_BATCH_OK`.

Store isolation reports 21 files and **0 defaults** unchanged. Its nested browser
production flag still emits `TOOLLOOP_PRODUCTION_FAILED` with 18 WRONG lines in
both fixed/restored output; that inherited gate is open. No installed preference,
real Google, visible UI, release packaging or performance acceptance is claimed.

The V1 candidate missed clearing already-cached Calendar entries after a later
successful replacement declined Calendar. V2 reproduces that first-repair defect
with seeded real CalendarService caches before repairing the same consumer.
