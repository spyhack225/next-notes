# Concrete off-source handoff

These files are proposals, not applied/compiled/native-tested:

- TaskACPPrimaryAdmissionSelfTest.swift.txt (new source candidate; existing worker flag callback count, no new flag)
- launch-peer.py.txt (embedded in candidate; owned temp SQL/marker only)
- AgentTaskManager.proposed.swift.txt (enumerated ownership seams)
- ACPAgentBackend.proposed.swift.txt (positive contract + existing validity/receipt-store forwarding)
- registration.patch (append after the existing629 cases; never replace their calls)
- source-pins.json and producer-copy-manifest.json (exact base and proposed bytes)

Review first. The original must contain only the same fixture/registration and needed harmless API scaffold, and the fixed must reuse identical fixture bytes. Counts/verdicts await real serial execution; no aggregate model verdict is inferred.

The fixture currently uses positive, rejected SQL start, primary state mismatch, exact attempt/owner mismatch and actual held cancellation, then real direct Session permission decline/late valid notification. Decline is explicitly a direct Session control: the real Manager acpFixture seam auto-approves permissions under SelfTest and cannot prove Manager nested permission decline/durability. No fake private handler or effect result is used.

Source-scoped producer review:

1. Normal typed protocol scope requires exact backend acp, source user/text/selftest, no schedule and nil compatibilityCommand/compatibilityCLI. Existing local predicate and local-only input/permission capture stay intact. Shared worker eligibility is enumerated only for start/write/cancel/release/terminal/validity/getter seams; ACP record callback has its own fenced branch and does not run local tool receipt/activity mutation.
2. Start commits queued predicate and attempt+1/currentPID/startDate/acpWorker/neverAuto before registry entry. Cancellation binds primary before cancelling/removing handle. Captured terminal callbacks and release cannot remove a different attempt/owner/start handle. No timer/new store/schema/heartbeat producer.
3. Compatibility handshake parking is fenced under the captured normal ACP attempt until parked. The waiting card then excludes compatibility effects from normal ACP worker eligibility. Approval still uses the existing explicit one-shot branch and is deliberately not given ACP validity/receipt authority. Existing --selftest-acp-confirm/routine authority controls must remain green. This does not implement compatibility lease/receipt fencing or prove its process safe; if root requires authority for that effect before applying the normal ACP slice, refuse it visibly or implement its separate exact guarded path with original evidence. Do not silently merge it into ownsWorkerAttempt.
4. ACPBackend requires positive captured context metadata and forwards that existing validity check/receipt writer through Orchestrator. Existing runtime checkpoint excludes the stale row before its fired receipt. Actor-await interval between that checkpoint and Process.run remains explicitly open; no atomic admission-to-OS-execution claim is made.
5. TaskDurability.hasTypedLocalAttemptRecord is reused only as its actual positive metadata recognizer, not as a runtimeClass execution grant. Its name/docs are now overly narrow if the proposal is accepted; root should adjust the documentation alongside reviewed integration without adding a new schema/property for the same fields.
6. Nested permission continuation, current-client/post-await guard, exact ACP prepared.id journal hooks/receiptID join, event-consumer shared-manager injection, unverified-result final receipt Bool admission, approval races, liveness and retry are OPEN. The unverified-result branch was not repaired in these copies.

Both complete producer copies must be rebased against root's frozen source pins before application. ACPSession is deliberately not copied or changed here because root owns its52/53 slot.
