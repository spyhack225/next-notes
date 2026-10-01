# UX06 cross-app context — 2026-10-01

## Scope and confirmed cause

The previous working card polled `ScreenshotStore` by a global key. That vision handoff is last-write-wins and consume-on-read, with no task or step identity and no observable update. Consequently, two tasks could show the newest task’s window under the first task’s status, and consuming a screenshot for vision could remove the UI’s image without an observable update.

Before changing the source, a standalone Swift probe executed the exact `ScreenshotStore` implementation extracted from `ScreenCapture.swift`. It published A-window and then B-window through `computer.screenshot` and asserted that task A still read A-window. Actual result: exit **1**, `UX06_BEFORE_FAILED: task A reads B-window after task B captures through the production ScreenshotStore`. This is the original overlap, not a weaker substitute. The probe did not capture, upload, persist or read owner pixels.

## Implementation

- The existing in-memory `AgentStep` carries a small preview (thumbnail, public window summary, human-yield flag). No parallel task store, screenshot dictionary, durable image, queue or timer was introduced.
- The final permitted tool backing is entered with `AgentWorkPresentationScope.binding`, synchronously capturing the **explicit task and exact current step**. The external integration owner added the TaskLocal wrapper to `AgentToolExecutor` at the existing `perform` call.
- Actual focused-window, browser AX and CDP screenshot producers call `ComputerToolExecutor.publishCapture`. This preserves the original vision handoff and independently publishes only the small thumbnail to that exact unfinished step.
- Actual `inspect_ui`, browser AX snapshot and CDP snapshot report the observed app/window/page title. The working card does not parse arbitrary model text or expose raw accessibility IDs.
- A new step, finish or reset releases the preview, including its pixels. Nil/unbound identities, late captures from older steps and already completed steps cannot attach themselves to a current task.
- `HumanInputWatch.mayPostAnotherEvent` publishes its actual refusal to that task’s step. A yielded card says the person has the Mac and releases its obsolete screenshot. The avatar uses the current task’s state, never another run’s global avatar fallback.
- The card shows actual window context with system fonts, existing DS sizes/colors, text selection and a Reduce Motion-aware transition. No fake click movie or typewriter was added.
- No Carry on button was invented: `HumanInputWatch.carryOn()` clears a flag but owns no suspended-task continuation. The existing pause sentence no longer claims an absent button; the card asks for the next instruction.

## Verification status

`git diff --check` passed for this source slice. Build/install are owned serially by the coordinating root and have not been run by this worker.

The existing `--selftest-computer-yield` now adds **13** grant-free assertions through the actual capture publisher, actual working-card selector and actual computer backing’s refused click. They cover both tasks sharing the original vision key, consuming that vision capture, unbound capture, old image release, late same-task capture, real human-yield propagation, independent task state, finished-task rejection and reset. This is **pending the root’s compiled run**; source presence is not a passing verdict. The focused click is refused before a posted event and does not touch the owner’s desktop.

Required root checks: `--selftest-computer-yield`, `--selftest-computer-vision`, `--selftest-tool-review`, `--selftest-island`, `--selftest-agent-panes`, `--selftest-ui-strings`, plus existing computer/CDP action checks as applicable.

## Open acceptance

An unlocked-Mac manual run remains required: actual screenshot/AX updates; system appearance and Reduce Motion; a real keyboard/mouse touch yielding before the next posted event; an approval staying available; and a no-screenshot-grant summary remaining useful. The grant-free publisher fixture does not establish Screen Recording permission, desktop behavior or captured first-pixel latency.

This slice does not complete UX06’s prescribed live gate or establish a safely resumable task. Those remain explicit acceptance items.

## Related CDP audit for separate producer owner

In `BrowserCDPClient.act`, the first `body` performs the click and returns an acknowledgement. If the expected changed page cannot be observed, the `!state.verified && expectation != nil && retryAllowed` branch discards a fresh snapshot and invokes the same `body(id, socket)` again. The retry does not compare the new node to the original, revalidate the page destination, or check human yield. A delayed page, unavailable observation or re-render can therefore repeat an acknowledged effect or click a different element at the reused numeric index. **A first-body exception does not retry in this function**; the source hazard here is acknowledgement followed by an unverified observation.

Separately, `BrowserExecutor.run`’s CDP branches enter `BrowserCDPClient.run` directly. The CDP implementation does not arm or consult `HumanInputWatch`, while the AX fallback does. Task-bound yield display cannot prove CDP yield when that backing never produces a yield event.

The audit does not change retry policy or claim a reproduced live effect. A separate coordinated owner should reproduce this through the actual CDP client over an isolated page: a button increments an irreversible counter, acknowledges, and leaves the requested postcondition absent/delayed; original behavior must show a duplicate count. The corrected producer must leave count one and report uncertainty. A second fixture should change the element at that index after the first acknowledgement and prove no second element is clicked. Preserve explicit authority, final target validity and human yield; do not mask this by changing the grader or result text. BrowserCDPClient is frozen by this worker after the preview-only changes.
