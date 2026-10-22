# UX-04 review of the off-source P6 typed-result proposal

Reviewed the source-complete package at `Tests/Reports/agent-overhaul-closure/next-implementation-review/p6-02b-artifact-production/full-pipeline/` with two disjoint reviewers. This is source review only: no application, staging, compiler, native interaction or owner-store access. The common fixture's108 count is preparation arithmetic, not a verdict.

## Reviewed identity and retained UI contract

- WorkingCard baseline: `90130118f5d69acdded1e72d423cfa0877d740385bbe69119f17d0e8ae0dfb2d`.
- Common original/fixed card: `9218f7e1c236f5aa3ca1dce9e753a498602870a1584763bbfb6006283ee6fed0`.
- Seven-file producer delta: `1e689d78e556828bc3f1cd6c9df17069cb8d974b8f05f1c62123773d8f50dd85`.
- Common fixture: `8446ced166839d4fbe0bea45ef8753b8cba806e4721848cd43f3d42968be4a89`.

The common card preserves the parked beam overlay and native terminal/failure/retry controls. Its row dispatcher binds task ID, ordinal and exact descriptor, recomputes the destination, checks local file existence and preserves exact Copy values. Producer metadata flows through the existing canonical collection; the compatibility string API does not add another list. Approved document metadata is emitted only after actual ID/title/body readback. Failed receipt/journal/terminal admission remains distinct from a created result; this package does not join owner receipts into the card or populate previously empty failed ACP artifacts.

Common card routing replaces the former bulk callback before both versions. The planned comparison measures typed semantics and action dispatch, **not** the original baseline's bulk-open behavior. Physical SwiftUI clicks, clipboard, NSWorkspace, keyboard, focus and VoiceOver remain unverified.

## Findings in the initial proposal — resolved by the amendment below

1. **Distinguish copied document values.** The real verified document produces an ID and URL with the same title. Both visible rows and `Copy <title>` accessibility labels are identical, although the values differ. Use a visible plain distinction and specific Copy label derived from the explicit producer kind; add assertions using those real rows to the same common fixture before both builds. Copy failure wording must not promise Copy still works when that is the operation that failed.
2. **Use the same marker classification in reader and writer.** The proposed SQL `NOT LIKE 'artifact-v1:%'` is ASCII case-insensitive; Swift `hasPrefix` is case-sensitive. Historical `ARTIFACT-V1:retained-kind` is neutral when read, then loses its kind/title on a same-path save. The original writer retained them. Amend the responsible write condition and add uppercase/mixed-case original/current persistence controls before freezing the fixture.
3. **Resolve historical marker collisions.** The old reader accepted arbitrary kind/title text as noncanonical. A pre-existing exact `artifact-v1:documentCreated` now becomes creation metadata, and an old arbitrary `artifact-v2:...` becomes invalid. The witness header verifies identity/generation, not the semantic origin of that row. An explicit compatibility contract and actual historical collision fixture, or producer-owned disambiguation through the existing seam, is required. The current broad claim that arbitrary historical metadata stays neutral is unsupported for these inputs.

Remaining codec/order/duplicate-preserving setters and metadata-aware import-prefix checks revealed no further defect in this review. That is not runtime verification. URL credentials, remote file authority and same-task forged destinations need explicit controls before being claimed tested. Mixed-kind references from repeated operations and nested voice ownership are not established by the single-tool native fixture.

## Initial next-proof request

Return an amended freeze manifest and exact common/fixed hunks. The UI owner can then coordinate the original common card mount with runtime root. Root retains serial build/native/index ownership: run the actual original with all functional/input/permission/cleanup controls, preserve the red, change only the responsible fixed producers, and repeat identical common cases plus existing strict storage/authority/receipt/isolation tests. Do not amend those gates to fit the proposal. No Source lease or UX-04 completion follows from this review.

## Amended static review and exact common card release

Final amended manifest SHA256 `8c172d6d228611b59288f03143ab36ab97f164a9384651a12c399a3fbddd1652` supersedes the initial package above. Common WorkingCard original/fixed snapshots are identical, SHA256 `b3702609bc26a48bd2aa68fe73c9cd98026cfcb94a29d0b5a9b6c8d97c3d7f39`; the actual current Source still matches baseline `90130118…`. The parked overlay block is exact. The common fixture is now `ac7003c84143ca448a9d881fb92d29277cd6781f1f78af0d8cadcedc31881580`, with135 predicted checks, not executed checks.

Two disjoint reviewers found no remaining material static blocker in this amended scope. Schema4 adds one `encoding_version` column in the existing artifact row and snapshot/import transaction. Old encoding0 metadata remains neutral regardless of case/prefix and retains kind/title on unchanged paths; owned encoding1 supplies explicit semantic interpretation. Genuine schemas1–3 read without upgrade, and unsupported/preexisting nonneutral encoding refuses without historical rewrite. The common fixture includes actual old-schema collisions, rollback, exact retained values and future/noninteger encodings. Authority's sole expectation edit replaces literal3 with the declared schema version; strict predicates/counts remain unchanged. Column-declaration and empty-column refusal branches still lack execution evidence.

Real document rows now distinguish Reference/Link roles and Copy reference/Copy link, including VoiceOver labels and exact copied values. Copy failure wording is truthful. Forged destination, credential-bearing URL and remote-file authority controls are present in the common fixture. Existing task binding, destination recomputation and parked overlay survive.

The UI owner released **only** the exact baseline-to-common WorkingCard hunk to runtime root for coordinated mounting after its106 gates. Root must recheck the preimage at mount; drift requires a renewed pin/review. This is not a local Source edit or an approval of physical interaction. All other Source, registration, build, native and index scopes remain runtime-root brokered. Actual original/fixed fixtures, compilation, storage migration/large-history latency, clipboard/Open/VoiceOver and UX-04 completion remain unverified. The common bulk callback removal still cannot be counted as an original/fixed measurement.

## Actual bounded implementation — original107 / fixed108

Runtime root committed **`2725895`**. [Actual verification](../agent-overhaul-closure/next-implementation-review/p6-02b-artifact-production/full-pipeline/native-verification/verification.md) retains original107's23 feature-only assertion failures and identical fixed108 `TASK_WORKER_ATTEMPT_OK: 1487 cases`; all23 focused functional flags pass. No original executed-case total is inferred from a failed assertion marker or preparation arithmetic. Only seven producer files differ across the1049-entry compiler manifests. The common WorkingCard remains `b3702609…`; the foreign parked beam is preserved and unstaged.

Before both compilers, the common SQL fixture changed `NEW.status` to the real `NEW.state`, and one projector EOF blank was removed. The final common fixture is `1c537503…`; the earlier unmounted package is historical. Neither correction changed a scenario or assertion after the original native result. Exact full pins and retained compiler/native logs are in the runtime report.

This establishes real Manager/backend/executor/orchestrator/Workspace-runner/primary-export semantics with an injected external CLI and named Open/Copy dispatcher with recorded backing, including legacy collision/migration controls. It establishes no physical SwiftUI/clipboard/NSWorkspace/focus/VoiceOver or owner migration. The common bulk-callback removal remains outside the measured original/fixed delta. Parent mail/Based-on/privacy consumers and complete receipt reconciliation remain open.

Required quick108 remains4/10 against9/10; CORE20/22 retains wake and a computer takeover-pause failure. The unchanged standalone computer follow-up passes but does not erase that failure or identify its cause. Direct voice identity from106, missing latency input and all broader release gates remain open. UX-04 is still in progress.
