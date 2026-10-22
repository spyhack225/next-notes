# UX-03 / UX-04: Based on card proposal review

Status: static, off-source review of a mutable packet. No Source application, build,
installation, native interaction or task completion is established here.

Reviewed packet:
`Tests/Reports/agent-overhaul-closure/next-implementation-review/p6-02b-based-on-ui-review`.
Runtime root owns the producer review and serial compilation/native/index work. Two UI
reviews checked disjoint consumer and layout contracts without changing product Sources.

## Consumer contract

- Approval rows use the actual live PermissionRequest, joined to the live review by
  request ID and tool. The inline card additionally supplies its exact task ID. Missing
  or crossed requests omit source rows. Sources do not alter readiness, arguments,
  permission scope, standing grants, approve/deny or the question flow.
- All three working/result call sites pass AgentView's existing manager. Standalone
  cards default to no manager. Terminal projection follows the retained primary task's
  receipt IDs and matching task, attempt, process owner, prepared/intent IDs, task
  routing and frozen evidence. Untyped contextReferences are not a source fallback.
- The manager reads its injected receipt store or a weak observation of the same
  already-created singleton. The singleton initializer alone registers that observation;
  injected constructors do not. Projection uses cached load metadata and receipts,
  with no SQL, lstat, file/account read, await or receipt decode. The uninitialized
  production branch has source review only; the worker fixture cannot prove it natively.
- The shared section contains wrapped text labels, no action, focus state, clock or
  grant. Existing native glass, decision/field/accessibility focus, named artifact
  Open/Copy dispatch and the exact parked ThemeBorderBeam block are preserved.

No material blocker was found in these bounded static UI contracts.

## Copy recommendation

Terminal sources can truthfully come from an earlier read_email receipt even when the
later create_doc was denied, held or released. “Saved with this action” can imply that
the denied write occurred. Recommended wording: **“Saved source details.”** This names
the retained metadata without claiming execution or current source validity. Runtime
root received this recommendation before the packet freeze.

## Point-in-time pins and admission

The reviewed common/fixed UI snapshots were identical:

| File | Common/fixed SHA-256 |
| --- | --- |
| ToolReviewCard.swift.txt | `a7514e6e1ad52619a9b156744b8c556d0d9fa5e5e7db9c29bb51c5f40ee4b783` |
| AgentWorkingCard.swift.txt | `3de2f41d24dfb211821ee901aeabb06cf4f54b2b459fed84d9b4e90a5fdc8aa9` |
| AgentView.swift.txt | `f5f3f0a6f2d1ea832ccc236ec4d6fc165ffd9e3bbabb62e64b55b5d767fa2a1d` |

Common patch `3afed1ccb40480f9b2ca5a29311f30a65feea01d1762a3cedf1eba9a0eefc425`;
fixed-only producer patch `38aaaba3fface4435fd1e1199fe9b082aedaab59f3146ff51adfd530d3be639c`.
These are observations, not frozen admission or a mounting lease. During review, the
fixture changed to `087c809bd881e0a7cd82d56f8258d2b29fa21518804bda38a7bfb6af4ca2df63`
while its manifest still listed an earlier hash. README predictions changed to194/81
while source-pins still said188/75. Root was asked to freeze and regenerate the entire
packet before an exact release. Predicted original RED28 is not an actual verdict.

## Gates still open

The proposed conductor calls the exact functions used by SwiftUI but instantiates no
native cards. Native small-window layout, keyboard/focus, VoiceOver, Reduce Motion,
first displayed frame and large-history redraw latency remain unverified. ReceiptStore
is not Observable; receipt-only changes do not guarantee immediate invalidation. No
source rows appear after restart until normal work initializes the existing receipt
singleton. Historical rows and LAST load/write metadata establish neither CURRENT
source identity, completeness, action success, reconciliation nor safe retry. Permission,
privacy, latency, quality and broader owner-read contracts remain unchanged. UX-03 and
UX-04 remain in progress.

## Frozen amended packet and exact UI release

Final manifest `d98cdeeb412955f5b7213999fa0ad0a4308b87b39d41c2313155ae56f66036df`
was checked against all32 listed files with zero mismatches. The packet is frozen,
unmounted, uncompiled and unexecuted. Fixture
`e43c0cc00d5e1c6a7684d7af8d9e5d29cc2dd7bb14673b1e537f9bc410997d61`
and source-pins
`8add43d2e05988a4d8bc720094bd4f38ef5daa2d4408ea18167a0d502c15c1b6`
agree on194 predicted checks,113 retained/81 added, with28 predicted original
feature failures. None is a measured verdict.

The actual shared Text now consumes the pure retentionNote property, “Saved source
details,” only for nonempty retained rows. Common/fixed ToolReviewCard is now
`cebe6257971dfbdd22b6aa0a80201a2ba5b3b6ebec1c3fdadb142d9246771bc7`;
WorkingCard and AgentView remain the common hashes above. Common patch is now
`7d23b3eff97ea6b8b1dbd7c2495ba4b49c21d1d9032063aaf709d7fc0caf3b66`;
the fixed-only producer patch remains unchanged.

Read-only current UI preimages still match the packet baselines exactly:

| File | Current baseline SHA-256 |
| --- | --- |
| ToolReviewCard.swift | `74ac2aeb68d41c8c1ed277d7da32d274135963d813288d47e5e371bd856659c1` |
| AgentWorkingCard.swift | `b3702609bc26a48bd2aa68fe73c9cd98026cfcb94a29d0b5a9b6c8d97c3d7f39` |
| AgentView.swift | `7e7eed666368a2ea260548de5071b8bdae1243f1cc364c0b1fb6efbe2c29f7c2` |
| FailureCard.swift, unchanged | `034d35bf42a5d061ce58fadf7de13670db97918ed02d72ab44192944c78353d4` |

UI ownership releases only these exact baseline-to-common card/routing hunks to serial
root for its115/116 paired compiler slot, after its own lease/preimage checks. Root
coordinates AgentView and the other three producer owners; this is not a whole-snapshot
replacement or a broader UI/native lease. Any preimage drift or changed hunk requires
renewed review. No local Source mutation or compiler/native action occurred. All native
interaction, privacy, performance and roadmap completion limits above remain open.

## Actual staged original127 / fixed128 proof

[Independent paired review](../agent-overhaul-closure/next-implementation-review/p6-02b-based-on-ui-review/independent-review/native127-128/actual-verification-and-commit-scope.md)
records original127's exact28 missing-feature assertions, all functional controls intact,
and identical fixed128 `TASK_WORKER_ATTEMPT_OK: 1908 cases`. These are staged bundles,
not installed-app acceptance. The original failed marker counts assertions, not all
executed cases. The actual COMMON fixture was
`b17c935a369077b52c2299adadfcbdf6dcb29478059ddb40a052beb6281dd3eb`;
root's intervening common capture/truthfulness preparation preceded both paired runs.
The frozen preparation fixture above is not claimed to be the compiled fixture.

Only the two reviewed producer bodies differ across the1050-entry compiler manifests;
both310-file signed bundles remain invariant. The unchanged six modes cover actual
request edits, primary/receipt bindings, fresh SQL readers, source/privacy negatives,
denial and held/released effects. This establishes cached production-call-site row
projection, not normal nested dispatch/restoration or current effect completeness.

Both runs explicitly report `BASED_ON_NATIVE_CAPTURE_UNAVAILABLE: 32/32`. All64 actual
fixture PNGs are retained and transparent. The exact tinted-glass offscreen limitation
also reproduces with mounted synthetic Text/Button/TextField; removing glass tests a
different view. No native visual, accessibility, focus or displayed-frame pass follows.

The33 supported focused functional flags and dedicated reader40 privacy passed on
earlier fixed126, not as extra128 runs. Actual quick126 remains4/10 against9/10; CORE126
is21/22 with wake17/24 hits and3/32 false activations. Invalid earlier invocations and
bundle/source admission attempts remain retained. Later shutdown work is a separate
root-owned regression and does not promote this UX slice. UX-03/UX-04 remain in progress;
native interaction, unloaded-restart availability, receipt-only invalidation, latency,
permission/privacy and broader owner/full/quality gates remain open.
