# Last exact worker tool boundary — original50 / fixed51

The existing task journal can retain an unmatched start after backing already
returned/threw when its completion save fails. It cannot answer whether that
exact backing is still executing. This bounded feature observes the actual
boundary in the same admitted in-process worker handle; it adds no new store,
query, save, await, timer, persisted field or permission policy.

## Actual source and consumer

The existing Executor defer now passes the same prepared receipt UUID through
the existing transient completion draft. Persisted journal format is unchanged:
loaded drafts still have nil receiptID; durable receipt links remain in the task.
Manager stamps entry only AFTER existing primary tool-start admission, and stamps
return/throw BEFORE the existing completion save. Its failed save can no longer
make this cache imply that the same backing has not returned. The same RunningWorker
value holds this metadata, bound to captured task/attempt/process/start, exact tool
and receipt UUID. Hot stamps and the actual debug consumer use direct map accesses;
no additional task-array scan is introduced. Getter uses existing defensive binding
and opens no SQL or receipt store.

The production debug path reads the just-cached metadata. Actual temporary fixtures
drive Manager → LocalBackend → Executor → Orchestrator → FilesystemExecutor. They
hold the original read after real receipt/tool-start admission, then perform that
same read once. Existing native store boundary and announcement consumers see the
return/throw cache before completion commit and after genuine rejection. No helper
replaces the real backing; fakeForTesting remains nil.

## Original and unchanged fixed verification

- Original installed50: **15 missing-feature assertions fail**, prior531 functional
  checks remain green. The API-only scaffold returns nil and ignores the newly
  accepted completion UUID; it leaves actual original persistence/dispatch unchanged.
  This is missing-feature evidence, not a fabricated pre-existing product bug.
- Fixed installed51: **worker629 PASS**. Same byte-identical fixture adds98 checks;
  original/fixed manifests differ only in Manager and Journal implementation.
  Types and Executor pass-through are identical in scaffold and fixed builds.
- Actual cases cover held entry, normal return, return/throw with SQL completion
  rejection, simultaneous completion/terminal rejection, cancellation with entered
  backing still completing, missing input/current successor, refused start with zero
  backing, waiting/exited handles, stale context and exact UUID/tool negatives.
- Repeated getters add zero existing-open callbacks and leave primary/journal/export/
  receipts/owner bytes unchanged. Runtime receipt outcomes, failure/delivery semantics
  and persisted journal shape retain their original assertions.
- All19 installed flags exit0: worker629, all14 related durable/functional/safety
  checks, dedicated privacy40 and ACP/MCP/confirmation. Source/binary invariance passes.

`fixed51-checks.json` and raw logs contain actual markers. Earlier static arithmetic
predicted97/628; actual input-successor has16 checks, yielding98/629. Predictions
are not substituted for measured counts. A failed initial preparation misread the
review JSON shape and triggered an unadmitted repeat package before any fixture
source changed; its log is retained separately and supplies no original proof.
Zero-context proposals required exact pinned source plus Git --unidiff-zero; actual
standard-context original/producer patches and baseline/scaffold/fixed source copies
are retained for review. Build50/51 are the admitted actual native fixture binaries.

## Limits

This is the LAST exact boundary, not complete per-worker active-call coverage.
Nested/concurrent starts can replace it; a returned latest UUID cannot prove every
other backing stopped. Entry admission is not an externally verified effect or
health. Return/throw is that backing's boundary, not a consequential outcome.
Nil includes queued/waiting/cancelled/exited/replaced/unknown; cancellation can leave
already-entered backing active. No retry or recovery authority follows.

Full process/session liveness, complete backing coverage, outcome reconciliation,
crash/power-loss, recovery/retry, other owners, native interaction and IM-16 stay
open. No model/default was promoted and the quick/full/owner/latency gates remain
unchanged; historical app13 quickFAILED3/10 is not an app51 model verdict.
Full workspace manifests pin separately owned dirty UI/model foundations; they
are not a clean-checkout or physical UI acceptance claim.
