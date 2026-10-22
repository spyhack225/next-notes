# Independent Notes-return prerequisite review

Verdict: CONDITIONAL SOURCE ACCEPTANCE only with additive static qualification stage. Frozen base manifest `2f136393d8374c7c1b27f9152122bc6ffe6e5101d08f10ed4b8706fc49aee302` remains unchanged. Required additive manifest `ba3d7345f53282c8e4223f87f7708935670d7f6d5c4ebc4edd34d38bc13e74d2` must be SAME COMMON for both Settings variants. No source lease, compilation, native qualification or cessation verdict follows.

## Confirmed source correction

Base NotesService.swift.proposed:91 uses unqualified static `sharedIfLoaded` from the instance method configureNativeNotesReturnObserver. The actual declaration is static weak; existing unqualified uses are in static methods. The additive patch `7834d46577c3c2b37d457b17543d34ad206a76e9949e5298943395a049a7367f` changes exactly that reference to `Self.sharedIfLoaded`. Its corrected postimage is `597791365eae696656b62c028dcded322f3af27674e0bb5919f48b573a435dc6`. No further confirmed declaration/signature mismatch was found by source inspection; Swift 6 type/actor/macro checking remains UNRUN.

## Actual owner and callback

The observer is an optional @ObservationIgnored, instance-local tuple on the existing MainActor NotesService, nil in production. Configuration requires exact native Notes-settings mode, successful immutable binding, notesActiveOff mode, exact admitted meeting UUID, no running task, open termination admission, no prior observer, a service other than the loaded shared instance, exact admitted canonical store root and an existing private meeting. It reads sharedIfLoaded without invoking the shared initializer. The store path accessor and meeting lookup use the already confined private store.

Actual summarize stores one existing Task in its map. The added callback is in that Task's existing defer, after watchdog.cancel, removal of the existing task-map entry and stoppedByWatchdog cleanup (base proposed:377–388). It clears its own optional observer before invoking it for the exact meeting, so callback consumption is one-shot. No new Task, map, timer, await, watchdog or model pass is added. This signal is completion of the final Task-body defer, not an independent proof of Task.value completion or native return.

## SAME trace and private quit disposition

The trace change adds one Bool ownedReturned and reads existing quitScheduled under the SAME NSLock. Existing recordDecode alone sets quitScheduled after a successful decode followed by a subsequent entered bracket. The return callback marks ownedReturned atomically with that scheduling observation.

When native quit was already scheduled, the callback returns without another quit request. Otherwise it marks input INVALID, sets SelfTest.failed and schedules the existing SelfTest.requestTermination route. The fixture installs this observer only after the private App tuple and native override are mounted, before backend initialization and summarize. A missing native qualification therefore does not trigger generic shared-owner setup and is never graded as a Settings producer regression or positive native PASS.

The actual SelfTest.requestTermination declaration in current NextNotesApp.swift:114 schedules RunLoop.main.perform(inModes: [.common]) and invokes NSApp.terminate(nil) under MainActor.assumeIsolated. It performs no status-based immediate exit and creates no Task. Called from summarize's final defer, it returns to that job before Cocoa enters the mounted private AppDelegate termination path. No awaited self-join is introduced inside the defer.

Both finalReply and willExit additionally require ownedReturned plus the existing zero owned-task check. This supplements, and must not replace, App's captured same Task.value join, runtime finishTermination, actual drained conjunction, producer native brackets and first/second actual Cocoa vote qualification. A task returning after native scheduling but before the first Cocoa callback remains INVALID through the existing first-overlap check. The no-native fallback can safely exit yet still has INVALID/failure disposition; its ordinary resumable-state positive assertions may fail without converting missing input to PASS.

## Pins, scope and required qualification

Independently verified nine base artifacts, four additive artifacts and three current source pins: zero mismatches. Base NotesService current c1577429, composed trace fc49cf34 and root-selected fixture281d7e56 are required exact preimages. Copy-only replay validates text application, not compilation or execution. Root combined composition must include all three prerequisite hunks plus the one-reference correction identically before the Settings producer FIXED hunk.

Original/fixed fresh processes must preserve exact Settings inputs and actually exercise explicit/on/off/nil constructor choices. Active Notes controls require a genuine observed native decode overlap, captured task join and returned bracket, veto, same safety continuation and safe second exit. Separately exercise actual early task return/no scheduling, rejection guards, late scheduling/first callback loss and one-shot behavior. These controls, ordinary compile/related flags, public copied-model digest/source identity and owner-store invariance remain UNRUN. Missing qualifying overlap or assets is INVALID/UNAVAILABLE, not native RED/PASS. No broader Manager, ASR or speech shutdown or whole-process cessation is established.

All canonical and frozen packets were left untouched; no compiler/parse/build/native/model/assets/defaults/owner-store operations were performed.
