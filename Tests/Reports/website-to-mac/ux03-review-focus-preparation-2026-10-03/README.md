# UX-03 review focus: bounded preparation — 2026-10-03

**OFF-SOURCE, UNRUN.** This package supplies current Source snapshots/pins and one relative candidate; it does not establish a product bug, native keyboard/VoiceOver success, root approval, or roadmap closure. Only files beneath this package were written. Canonical Sources, index, build, native apps, model and owner stores were untouched. Root release and coordinated ownership are required before any application or execution.

## Source-backed hypotheses and exact producer path

`PermissionGate.ask` queues live entries (69–70). Its existing `restore` accepts an exact supplied review plus an owner callback (91–100). `present` sets pending, begins the review and raises the existing Island card (103–122); `pendingReview` reads the keyed Store (154–156). `respond` clears pending (216), then synchronously `advance()` (249 →159–162) presents the next entry before returning. SwiftUI may therefore observe A→B without a rendered nil gap.

`AgentView` draws a standalone pending card at317; `permissionCard` (442–466) supplies the new review/request to the same structural child. `AgentWorkingCard` uses the same child under a stable task when `inlineReview` changes (64–66,79–102). Neither current caller keys that child by the request/review ID. `ToolReviewCard` owns question, partial answer, expanded field and focus states (27–35), and initializes focus only on appearance (60–67). **Hypothesis:** an actual coalesced A→B update can retain local question/focus state and omit B's appearance focus. Native lifecycle observation must reproduce the original behavior; an onAppear source gap alone is not proof of a visible failure.

For an explicit one-question submission, `answer` writes the same Store (213–216), clears text, then moves to the next blocker (217–221). When the final blocker is resolved, the question disappears without an explicit decision-focus assignment. Direct field submission runs `focusNextBlocker` (275–280), which clears focus when no other blocker exists. **Hypothesis:** the decision is not reliably focused after that explicit action. Native fallback can still move focus; its actual result must be observed before calling this a product bug.

`ToolCallReviewStore.update` publishes only after its existing persistence handler accepts (174–178). The candidate checks the actual resulting `live.isReadyToRun`; it does not assume the edit was accepted. `PermissionGate.respond` still refuses unresolved reviews (180–190), rejected restored owner decisions (192–199) and rejected bound decision admission (201–207). Native Return/default-action behavior and all approval callbacks are unchanged. Moving focus never supplies a token or runs an action.

## Candidate scope and lifecycle choice

`candidate.patch` modifies exactly three existing UI files:

- `AgentView.swift`: key the actual standalone card by `request.id`.
- `AgentWorkingCard.swift`: key the actual inline card by `inlineReview.id`.
- `ToolReviewCard.swift`: after explicit successful final answer or field submission, focus the existing decision only when the resulting live review is ready. No focus reassignment occurs on each character edit.

A new request changes the keyed native child identity; existing card-local State/FocusState is recreated and the existing appearance handler applies to B. A stable request ID keeps the same card during ordinary edits, expanding text, streaming background work and persistence updates. The containing window/hosting view stays mounted. This is a candidate lifecycle contract, not a promise about native frame timing, announcement counts or compositor behavior.

An `onChange(review.id)` alternative would preserve the native accessibility element identity and manually clear every local question/expansion/focus state. Setting `focusedReview` true when already true does not establish a fresh announcement; false→true in one update may coalesce. It must not be described as guaranteed reannouncement. Keying `.id(review.id)` only inside the owning card's body would reset descendants but does not establish a reset of the outer card's own State storage. The selected caller identity boundary owns that storage. No new wrapper/model/store/queue/await/timer or forced announcement is proposed.

Keyed replacement could change focus restoration or announce twice depending on native accessibility delivery. Those are acceptance risks to observe, not reasons to fabricate a timing gap. There is no new animation or forced false→true accessibility-focus sequence.

## COMMON mounted original/candidate fixture outline — NOT IMPLEMENTED

Keep one actual application window/hosting root mounted across every transition. Do not reconstruct it between A and B and do not mirror card logic into a test view. Exercise BOTH actual consumer routes: standalone `AgentView.permissionCard`, then same-task `AgentWorkingCard` under the existing task identity. Different-task rows alone do not reproduce the reuse hypothesis.

Existing seams: `--selftest-tool-review` exercises real Store edits/Gate refusal (ToolCallReviewSelfTest359–388); `--selftest-agent-presentation` suspends an actual typed stream, verifies stable commit/Stop and owner invariance (25–79). `ExperienceSheet` mounts actual ready/missing cards with no-op actions (95–97), but offscreen image creation does not establish keyboard/AX interaction. Gate and Store have private constructors and no independent UI-owned constructor seam. A helper-only focus enum test cannot replace mounted original-flow evidence.

A bounded root-reviewed conductor can use actual `PermissionGate.restore` with complete placeholder `ToolCallReview` values and temporary task IDs, avoiding `ToolCallContextBuilder.current`'s live context fallback. The same restored decision/edit callbacks may count exact accepted/refused decisions and payloads without submitting a worker or writing anywhere. Restored decisions produce no standing grant. This uses existing Gate/Store owners; no second approval system is introduced.

**Required admission review before implementation:** exact diagnostic flag plus SelfTest; private process with the established isolated shared task/audit/default roots; pending=nil/queuedCount=0 before mount; explicit supplied reviews; no live voice/task/session attachment; source/binary and existing owner-store guards. `present` also raises `IslandState.shared`, logs audit metadata and reads `VoiceConversationCoordinator.shared` (111–122); `respond` dismisses Island/logs/sends VoiceSession events. Their actual constructors/paths and the mounted Agent consumers' shared dependencies must be qualified by the serial owner before declaring this fixture safe. No current constructor bypass or broad reset of a live owner's Gate is authorized. `resetForRestartTesting` exists (275–287) but its SelfTest guard alone does not justify clearing unrelated waiters. If admission cannot be established, hold the mounted fixture rather than substitute a fake helper or seed owner history.

COMMON cases must be identical before/candidate:

1. Show missing-field A, activate Tell me instead, type a partial answer, retain its question/expansion; queue B for the same consumer. Dismiss A through the real control/Gate, then observe B without remounting the host. Pin exact A/B IDs and values. Inspect native focused UI element and the accessibility event stream; B must not show A's draft/question, and its current header/decision-or-question focus must be discoverable. Include ready→missing, missing→ready and same field-name replacement; no fabricated nil-render step.
2. On a single missing-field card, submit an explicit valid last answer through its actual question TextField and Use this control. Observe native first responder and focused enabled decision. Repeat direct field Return submission. Missing/placeholder input and a refused existing edit-persistence callback must remain blocked; no focus handoff may manufacture readiness.
3. Activate Return only after native focus has settled on that decision. Require exactly one real `Gate.respond`/restored-owner admission with the exact edited payload, no second decision, no standing grant and no worker/tool/backing. A refused decision keeps the actual pending card. Another Return after removal must not resolve an unrelated request through stale state. Record actual default-button/native focus behavior; do not infer it from a Bool.
4. Record B's VoiceOver announcement count/content and keyboard focus independently. Exactly one useful new-review announcement is the acceptance target, not a predicted result of an `.id` or focus property. Check header/content access and no unwanted scroll jump at the original supported shell and larger size, including Reduce Motion. Preserve the same original flow and sanitized inputs for candidate; failure to reproduce original means hypothesis remains open.
5. Dismiss/cancel only fixture IDs, remove only fixture reviews, retain existing grant/default/store invariance and callback counts. No proof of consequential effect/backing is asserted by callback-only admission.

This package adds no self-test flag, runtime fixture, accessor or announcement hook. Counts, timing and original/candidate verdicts are unavailable. Root owns the implementation/release, relevant existing tool-review/ACP/island/UI-string checks and native keyboard/VoiceOver slot.

## Streamed answer boundary remains unchanged

RealtimeAgent publishes cumulative snapshots with one ID (45–53), and finish commits that same ID (852–879). AgentView changes the combined accessibility label with cumulative text (566–570); its chunk and final-row observers handle scroll (349–359). Native accessibility defaults may notify changes. No silence, per-token reading or duplicate-final announcement is proven here. Actual VoiceOver original-flow observation through the existing suspended stream fixture is prerequisite to any announcement fix. This candidate implements no final-answer notification, buffer, clock or focus theft.

## Pins and review limits

`pins.json` records current canonical SHA256, baseline copies, proposed hashes and candidate patch SHA. Baseline/proposed snapshots are review artifacts only; never overwrite whole canonical files from them. Recheck current preimages immediately before root applies relative hunks, since concurrent owners can change Source. Static copy apply-check is not Swift typecheck or native acceptance. UX-02/03/10 and physical/latency/motion gates remain open.
