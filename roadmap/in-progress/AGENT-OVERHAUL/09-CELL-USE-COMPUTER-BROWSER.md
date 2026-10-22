# Computer and browser action validity — lessons from cell-use

**Planned 2026-09-30; implementation reconciled 2026-10-03.** This is a focused extension of Agent computer/browser use, not a
phone-control project. Task state belongs in `STATUS.md` (CU-01…CU-05). The completed
`roadmap/done/COMPUTER-BROWSER-USE-2026-09-22.md` remains the baseline, not a task to
re-run. Read `AGENTS.md`, this roadmap, and the current `BUILD-ORDER.md` before implementation.

## Outcome

When Next Notes acts on a Mac window or browser page, the action still targets the
control it observed and the person authorized. If the target changed or the first
action may already have happened, it stops with an honest result and a fresh way
forward. An ordinary stable click must remain as fast as it is today. Reads remain
automatic, the existing approval gate owns consequential writes, and the person's
input continues to interrupt computer control immediately.

No `cell-use` package, iPhone transport, second agent loop, task ledger, tool
manifest, screenshot store, approval gate, usage log, or mandatory model pass is
part of this work. `AgentToolLoop`, `AgentToolExecutor`, `PermissionBroker`,
`HumanInputWatch` and `ScreenshotStore` keep their current ownership. TaskBridge is
still planned by P3-03; it is not an existing production type in this audit.
Prefer a small check at the existing executor seam over a general action framework.

## Evidence, and what actually transfers

Reference: [cell-use at `61871a1`](https://github.com/Raynan00/cell-use/tree/61871a1df2ffe9850c13b599318b6c4e4292daee), inspected on 2026-09-30.
The root `swift test` ran locally: 26 `CellUseTests` cases plus six tunnel tests passed.
The native `Runtime` package and a physical iPhone were **not** exercised here.
The upstream demos use scripted agents; they do not prove autonomous task quality.

| Upstream implementation | Useful rule here | Limit of the reference |
|---|---|---|
| `Sources/CellUse/PhoneActionRunner.swift`: `runID`, `observationID`, one consumed decision, `commandID`, bounded states and deadlines | Bind one action to the observation and target that produced it; discard a late or duplicate result | Its token proves *which frame* the model answered, not that the same app/control still occupies the pixels |
| `Runtime/Sources/CellUseRuntime/CellUseRuntime.swift`: one session stream, main-actor runner, fresh-frame/readiness checks before delivery | Check target identity and readiness immediately before acting, using our PID/window or CDP tab/page identity | Upstream checks orientation, dimensions and frame age, but not foreground app or intended control identity |
| `Sources/CellUse/PhoneInputDelivery.swift`: validate before side effects, check between events, release input on interruption, never replay a partial gesture/string | Preserve `HumanInputWatch`'s per-event check and classify uncertain delivery separately from verified effect | Its 60 ms per-character sleep and runner's three-second initial/one-second post-input waits are unacceptable on our turn path |
| Upstream runner tests: wrong run/frame, duplicate decision, timeout, partial input failure | Add adversarial fixtures that prove our refusals can go red | A transport acknowledgement is not proof that a target app changed |

Our stronger starting point: Accessibility IDs include a capture generation;
`BrowserCDPClient` pins a target ID and authorized URL and compares a saved node with
a current node; `ComputerToolExecutor` can inspect the actual window after an
action; `HumanInputWatch` yields on a person's next input event. Keep semantic
element actions ahead of screenshots and pixels.

## Historical baseline and current gaps

The first two failure descriptions below are the September30 baseline, **not
current code**. The committed `8888474` repair makes VerifyRetry deliver the action
once and CDP resolve the observed backendNodeID, validate and act in one
Runtime.callFunctionOn, then consume the snapshot without uncertain replay.
CU-02/CU-03 are in progress with that bounded implementation, not unstarted.

Retained [baseline](../../../Tests/Reports/computer-use/2026-10-01-cu02/baseline-output.txt)
has10 actual client failures; the first [fixed report](../../../Tests/Reports/computer-use/2026-10-01-cu02/fixed-output.txt)
still has one early human-yield failure. Later [installed CDP output](../../../Tests/Reports/website-to-mac/installed-cdp-2026-10-01.log)
records CDP_OK and all11 action assertions passing. That later output is existing
evidence, not a fresh current run or complete live AX/coordinate/consent exit.
CU-01 lacks the full native AX/coordinate baseline; CU-04 still has a real captured-
pixel/target provenance gap; CU-05 live behavior and same-pair guard-overhead
acceptance remain open. See [the completion checklist](REMAINING-WORK.md#computer-product-journeys-and-optional-cloud).

1. **Historical uncertain click retries; now repaired at the producer.** Before the repair, `BrowserCDPClient.act` checked a cached DOM node,
   clicks, polls for the expected result, then may call the click body again with
   the same numeric ID. Its intervening `snapshotExpression` read does not compare
   the target again. A reordered page can make that ID refer to another control.
   `ComputerToolExecutor.clickElement` captures a new AX generation after the
   first attempt, but `VerifyRetry.run` calls its closure with the old ID. That
   second attempt is unlikely to do what the comment promises. Both paths also
   risk repeating a toggle or submit when the first effect was merely slow to show.
2. **Historical browser observation-to-action gap; atomic CDP action now implemented.** Previously the CDP node comparison and the actual click were
   separate page evaluations. A DOM change between them can retarget the numbered
   element. The AX path checks the frontmost PID, but should also account for a
   changed focused window within the same process where the old element reference
   may still exist.
3. **Pixel target provenance.** `computer.screenshot` parks an image under one
   memory-only key. A later `computer.click(x,y)` maps the fraction onto the focused
   window *at click time*; it does not prove that this is the window captured for
   the model. `browser.screenshot:<targetId>` must not silently become a click on
   whichever Mac window is now frontmost. A screenshot-derived coordinate needs
   a bound target and geometry, or an honest request for a fresh observation.
4. **Receipt vocabulary.** A posted event, accepted CDP command, observed field
   value, and verified postcondition are different facts. Keep using the existing
   `AgentToolResult.summary` and `verification` fields; do not claim success from
   command acceptance alone or create a second action journal.

## Build order

### CU-01 — Prove the failures and measure the stable path

**Depends on:** none. **Files to inspect:** `Computer/BrowserCDPClient.swift`,
`BrowserToolExecutor.swift`, `ComputerToolExecutor.swift`, `AccessibilitySnapshot.swift`,
`ScreenCapture.swift`, `Agent/Backend/VisionHandoff.swift`, existing computer/CDP
self-test harnesses. **Change first:** fixture assertions in existing self-tests;
no production code in this task.

- Extend `--selftest-cdp`'s owned Chrome fixture with a page that reorders two
  controls after the first click while the expected text is delayed. Assert one
  posted click at most, and never a click on the new occupant of the old number.
- Extend an owned AX harness case so the first click is accepted but not verified;
  record whether the old ID is used after reinspection. Capture the actual red
  marker, or document an environment block if an unlocked/TCC run is required.
- Add grant-free coordinate cases to the existing `--selftest-click-coordinate`
  or `--selftest-computer-vision` harness: focus/window or geometry changes after
  capture must reject the point; a same-window stable case must still act.
- Record warm stable-click and snapshot-to-click latency before edits (p50/p95,
  same harness and machine, no cloud model). Keep raw output in a dated
  `Tests/Reports/` file. A fixture must fail on the present behavior; a test that
  merely restates a helper function is not evidence.

**Exit:** a dated red baseline names the wrong-target/repeat case and the current
latency. No fixture reads private user content or writes outside its owned window/page.

### CU-02 — End uncertain clicks honestly

**Depends on:** CU-01. **Files:** `Computer/BrowserCDPClient.swift`,
`Computer/ComputerToolExecutor.swift`, `Computer/ScreenCapture.swift` only if
`VerifyRetry` needs narrowing, and their existing self-tests.

- After an action was submitted, an absent postcondition is **unverified**.
  Stop automatic click replay in CDP and AX. Observe the result through the
  existing bounded post-action reads and return the observed state and a plain next step.
  The Agent may take a *new* observation and decide a new action; it must not
  receive a result that implies the first click was safely undone or never sent.
- Keep the existing risk/approval checks and do not use a second confirmation.
  Audit `VerifyRetry` callers so removing click replay does not accidentally
  change unrelated operations; do not weaken the no-repeat rule for sends.
- Verify slow navigation, toggles, double submission, and a first click whose
  acknowledgement is lost. The fixture should prove one actual action, a truthful
  unverified result, and no hidden retry.

**Exit:** `--selftest-cdp` and the AX fixture pass on a stable page/window and
refuse a duplicate on uncertain outcome. Existing tool-loop and approval tests
remain green.

### CU-03 — Tie a browser action to the same DOM control

**Depends on:** CU-02. **Files:** `Computer/BrowserCDPClient.swift` and its fixture.

- Keep the authorized tab ID and URL pin. For element actions, compare the saved
  target with the control that will receive the action **in the same browser
  evaluation**. The present read-then-separate-click leaves a race. First measure
  whether a CDP node identity or a page-local handle can be used without changing
  the site; a matching label/index alone is insufficient when two controls look
  alike. If exact identity is unavailable, stop and request a new snapshot.
- Apply the same target check to `fill`/`select`; preflight secure fields before
  input and preserve the existing value readback. A navigation or target switch
  invalidates the pending element action.
- Test reorder between observation and action, duplicate labels, target-tab
  switch, navigation, and a stable control. Only the stable control receives an
  action; a stale control produces a plain explanation.

**Exit:** the fixture proves the exact intended control was acted on once. No
extra round trip or fixed wait is added to the stable path unless measured and
justified in the report.

### CU-04 — Bind pixel coordinates to their capture

**Depends on:** CU-01; can follow CU-02 independently of CU-03. **Files:**
`Computer/ScreenCapture.swift`, `Computer/ComputerToolExecutor.swift`,
`Computer/BrowserCDPClient.swift` or `BrowserToolExecutor.swift` only for a pixel
fallback they actually own, `Agent/Backend/VisionHandoff.swift`, existing vision
and coordinate self-tests.

- Attach minimal, in-memory provenance to the *existing* parked image: capture
  time, backend, PID and window identity or CDP target, and image/window geometry.
  Carry it through the existing vision handoff with the target coordinate. Do not
  persist screenshots or introduce a parallel store.
- Immediately before a coordinate click, check that the same target and geometry
  are still current and that the person has not taken control. A changed focus,
  window, tab, size, or expired capture gives a fresh-observation response.
  Determine the age bound from measured vision turnaround; do not insert a sleep.
- Never apply a coordinate from a CDP tab screenshot to an unrelated frontmost
  Mac window. If the browser pixel path cannot identify the same tab/window at
  action time, decline that action until a safe path exists.
- Test same-size app/window switches, resize, stale frame, target-tab switch,
  consent denial, and unchanged-target success. The tests must inspect the
  delivered target, not just the parser's coordinate grammar.

**Exit:** every screenshot-derived click either addresses its captured target or
reports that the view changed; image bytes remain memory-only and under the
current consent policy.

### CU-05 — Prove responsiveness and one source of truth

**Depends on:** CU-02…CU-04. **Files:** existing self-tests and a dated
`Tests/Reports/` note; production files only for measured regressions.

- Run `--selftest-cdp`, `--selftest-browser`, `--selftest-click-coordinate`,
  `--selftest-computer-vision`, `--selftest-computer-actions` via `--via-open`
  on an unlocked session where required, `--selftest-computer-yield` (grant-free
  and live halves), `--selftest-tool-review`, `--selftest-toolloop-production`,
  `--selftest-ui-strings`, `make test`, and `make build`. Keep the honest
  locked-screen/unavailable-tool verdicts separate from a pass.
- Repeat the CU-01 latency sample. Stable click p95 should add no fixed delay
  and at most 10 ms of guard work; if it exceeds that, inspect the actual cost
  and simplify before declaring done. No new model pass, approval card, spinner,
  or main-actor wait may be introduced on the user's action path.
- Confirm a person taking the Mac interrupts a multi-event action before the
  next event. Confirm an uncertain action is described as uncertain in the Agent
  working/result surface, using the current activity and permission machinery.

**Exit:** the red cases turn green, stable actions remain responsive, and a
manual foreground check confirms that the agent yields and reports truthfully.
Record the report path and exact final markers in `STATUS.md`; do not mark a
live check done when the machine was locked or the grant was absent.

## Scope decision after the gates

Cell-use's portable state machine is a useful specification for **action
validity**, not a dependency or a replacement for the existing Agent loop. If
the five tasks leave one truly repeated rule in several executors, extract one
small pure validator then; do not pre-create a general runner. Phone control,
DeviceHub, the embedded tunnel, and an iOS app are outside this roadmap.
