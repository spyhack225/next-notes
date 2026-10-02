# Authoritative corrected receipt observation verification

Independent read-only review of root's actual installed reports. This worker ran
no builds/native/model checks and modified no runtime source during this review.
Historical preparation, original88/unchanged89 fixture and producer snapshots are
preserved; these authoritative runs use the same corrected common50-case fixture.

Original90 reports `TASK_WORKER_ATTEMPT_FAILED: 149 assertions`. Exactly35 raw
receipt wrong labels remain, all missing CURRENT getter metadata; the earlier
functional source-preservation assertion is absent. Root's check report records no
source drift and the same installed binary; before/after bundle manifests compare
equal. Its actual raw trace preserves accepted target completion and changed-source
task failure with exactly one target read per mode.

Actual precision cause is now confirmed at the SAME real fired backing entry:

| Mode | Cached startedAt | Decoded startedAt | Event timestamp mismatches | Memory equals decoded | Existing ISO8601 roundtrip equals decoded |
| --- | --- | --- | --- | --- | --- |
| accepted | 1790969448.0915918 | 1790969448.0 | 5 | false | true |
| source-changed | 1790969448.137487 | 1790969448.0 | 5 | false | true |

The source-changed retention trace independently reports exact changed bytes
preserved=true, cached receipt equals captured memory=true, persisted receipt equals
captured decoded row=true. The original compound cross-representation assertion
was wrong; no receipt writer bug follows. Cached CURRENT timestamp assertions now
use captured cache timestamps, while fresh disk rows retain exact decoded equality.
No tolerance, field removal, producer encoding or easier input was introduced.

The actual build90 and build91 source manifests both pin corrected fixture SHA256
`eea50f769637d7aa841aa508f9f38d47262f6e5b67d16b11da052681e4dbdae1`.
Producer90 is original nil SHA256
`5a5fa7d7950884d8319df2520aad449cb98ac3857dcb94fe4511dcbfdfda23b2`;
producer91 is fixed getter SHA256
`759d84650b1cadd0d873c56ee7357f2db9d892a42a102000c5ef5e041cdb3546`.
Thus the producer delta remains only the CURRENT method body/comments and the
common fixture, original backing/read/source mutation and all50 checks are equal.

Fixed91 reports `TASK_WORKER_ATTEMPT_OK: 1352 cases` with no wrong labels. All20
actual focused check records have exit0, no source drift and the same installed
binary; before/after bundle manifests compare equal. The build manifest retains1040
source entries. The identical receipt50 cases pass: accepted actual read completes
with CURRENT matchingSource, completed bound receipt and fresh readable load2;
changed source reports CURRENT changed, no current cached rows, original task failure,
and fresh matching partial load2/unreadable1 with retained fired metadata. Exact
changed bytes, captured cache and captured decoded receipt are all preserved.
Existing missing/nonregular/identity-edit/binding/link/privacy boundaries pass too.

Actual fixed91 precision controls repeat the cause: accepted cached startedAt
1790969571.703024 and changed cached1790969571.760343 decode to1790969571.0;
both have five event timestamp mismatches, direct equality false and canonical
ISO8601 equality true. The changed precision line is interleaved by the worker
success marker in raw stdout; the retained segments preserve the complete values.
Source preservation and original backing/scenario controls pass with the same
time-domain correction mounted in both90/91, independently of the getter delta.

Root's actual isolation flag reports21 files and32 defaults unchanged, and dedicated
task reader privacy40 passes. This is bounded CURRENT receipt-source evidence through
the existing store/runtime and actual Manager integration. No effect completeness/
no-effect, health, concurrent CAS, recovery/retry, broad stale or aggregate Agent
claim follows. Root owns the combined P6-05k scope and commit across its three producers.

Raw evidence is in sibling `heartbeat-integration-review`:
`app90-task-worker-attempt.stdout`, `app90-checks.json`, before/after bundle manifests,
and `build90-source-manifest.json`/`build91-source-manifest.json`. Exact reviewed raw
stdout SHA256 is `e5a0c0fadf4255da513b4a54fe4e06ef8448fe811080a400cd849193dd6147b2`.
Fixed raw stdout SHA256 is
`c44c6cf3371fbc466cb72e46c39ea22b5ec8b964ebc36f0feea27cc93f74333a`;
its actual20 verdicts are in `app91-checks.json` alongside raw flag logs.
