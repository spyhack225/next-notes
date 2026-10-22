# Original capture and background shutdown ownership

Status: source-only audit, no canonical edit, fixture, compiler or native run. Pins in `capture-background-pins.json` describe the inspected revision; the main runtime owner is still editing Agent code, so recheck them before implementation. This audit does not reproduce the original SIGSEGV or predict an executed regression result.

## Actual current callers

| Boundary | Source evidence | Contract established by source |
| --- | --- | --- |
| Cocoa quit | NextNotesApp.swift:9635–9746 | Captures Notes/final/diarization/model parents; begins closing selected shared native admission inside its asynchronous task; awaits those owners; real `drained` plus diagnostic veto governs final reply. No capture/coordinator/task-manager shutdown caller is present in this method. |
| Final process notification | NextNotesApp.swift:9749–9766 | Calls `controller.deactivate()` only after async quit admission. The synchronous notification cannot await. This is dictation's controller, not the Agent capture/session owner. |
| Dictation cancel | DictationController.swift:2187–2224 | Invalidates the session, stops capture, cancels/drops feed and consumer handles, and starts an unretained Task to finish the captured engine/release its lane. The unchanged direct33 candidate separately addresses owned dictation retirement; its no-audio fixture does not prove healthy final insertion. |
| Normal voice Done | AgentCaptureController.swift:396–432 | Closes conversation/input/output, cancels the frontend turn, then bounds engine stop. Background work intentionally keeps its owners. Routine Done is not a process-shutdown drain. |
| Voice engine stop | AgentCaptureController.swift:961–992 | Unsubscribes capture; cancels/drops native decoder, VAD/feed-related handles; the captured feed and engine are awaited through existing bounded waits. Default-false helper can return before cancelled work completes. This protects conversational latency; it is not proof of native cessation. |
| Conversation close | VoiceConversationCoordinator.swift:352–369 | Cancels response preparation and response Task, clears foreground barriers; explicitly retains background objectives. `resetForTesting` additionally cancels their existing rows, so reset is not the production Done caller. |
| Explicit background cancellation | AgentTaskManager.swift:848–866 | Cancels exact existing worker/objective; retains the same cancelled operation until actual return, independent of durable save success. Stored cancelled status or a cancel request is not an actual-return receipt. No general termination API is present in this inspected Manager revision. |
| Shared foreground agent cancel | RealtimeAgent.swift:603–637 | Closes ordinary conversation and cancels the selected model task; it is not an aggregate native-owner join and is not called by the inspected App quit method. |

## Missing acceptance evidence

The first visible source contract gap is the App quit boundary's absence of capture/background worker admission and actual-return participation. Existing Notes/ASR/Pocket owners may still cover some underlying native calls; that does not establish all held decoder, model, tool, or external-worker outcomes. A cancellation field, successful history write, conversation closed event, or fixture reset cannot stand in for native return and final Cocoa reply.

Before a producer change, reproduce the actual quit with an admitted active capture/decoder or background operation held at its real entry/return seam. Observe the real AppDelegate proposal and final callback, unchanged owner identity, no new admission after quit begins, and exact backing/native completion. Separate cancellation from effect outcome: an already-entered consequential action may have run. Refused persistence must neither manufacture success nor authorize a repeat. Preserve the same ledger/worker and the existing foreground/default-false bounded wait; do not add a second worker map, serial microphone gate or routine Done join.

No new test or product fix is proposed here. Runtime root owns serial qualification and any implementation. Reuse the existing native-termination isolation/first-reply/final-veto/safety-drain seams, but prove their production call sites and original failure before accepting a same-fixture fixed result. Record model/account/permission/environment unavailability as unrun. SIGTERM is explicitly outside the inspected Cocoa drain contract. Physical capture, final typed delivery, full-duplex cessation/latency, external effect receipts, and all-owner safe/fast quit remain open.

## Concurrent source drift at handoff

Parent’s final pin check observed VoiceConversationCoordinator changing from `123b55ca…` to `1dd5edbd…` during the runtime owner’s active work. The inspected current closeSession is at354, adds a `lastStatusGate = nil` reset and still explicitly retains background objectives; cancel/reset moved to1174/1181. The original pin remains retained rather than silently repinned. These changed bytes invalidate exact-source admission from this audit; recheck current call sites at any later implementation. No new runtime or shutdown result is inferred.
