# UX-08 / UX-09 actual delivery contract

2026-10-01. Initial source review, followed by explicitly coordinated producer ownership release and narrow implementation below. No compiler or native self-test run by this worker.

## Existing producer and consumer

- `DictationController.beginDictation(intent:)` captures the origin app synchronously at key-down and mints `holdID` for the existing run/usage identity. Retry mints a new identity in `retryLastFailedHold()` and captures its new origin at the retry click.
- `runTail` records the cleaned, corrected, file-tagged `output` before insertion. This deliberately preserves recoverable text, and is not evidence of delivery.
- The same tail awaits the existing injected `insert` seam or `TextInjector.insert(output, returningTo:origin, whileCurrent:)`, checks its session, and switches on the injector's actual `Outcome`. Inserted and copied-by-choice call `finishIdle`; could-not-return calls the existing recoverable clipboard error; superseded returns without ending another hold.
- `finishIdle(result:)` sends the existing `DictationHoldOutcome` through `reportOutcome` before clearing transcript/origin/capture. Its metric is deliberately text-free and only reaches an injected or usage-log sink. It already has the correct identity and result, but is not an observable delivery presentation event. Do not add transcript, target or clipboard contents to that metric or to `usage.jsonl`.
- `OnboardingPracticeReceipt` exists but is unconnected. The actual shortcut view currently cannot certify either inserted or copied text. It removed the original producer that certified any nonempty manually typed TextField edit.
- `DictationStatusBand` reads real recording state and capture but idle currently says Ready; it has no delivery result. A completed history row cannot supply the missing result because it precedes injection.

## Smallest proposed integration

Keep the controller as the sole producer, reuse its `holdID`, and add one ephemeral observable `latestDelivery` value. No journal, queue, disk row, model pass, timer or awaited operation is needed.

Suggested value: `Delivery { id: UUID; text: String; kind: Kind }`, where Kind distinguishes insertion from clipboard-by-choice. Only the actual inserted/copied branches may publish it; empty/command/compare/cancel/failed/superseded holds never publish an inserted success. Publish in the existing successful finish seam with the tail's actual final output, immediately before idle cleanup. Clear it at the start of every accepted ordinary hold and retry. Use the existing hold identity rather than minting a second delivery ID. A could-not-return result continues to use the existing explicit error that says the text is on the clipboard; it must not be promoted to an insertion success.

Practice provenance must be sampled **synchronously at the accepted hold's beginning**, including retry. A SwiftUI `onChange(of: controller.state)` runs after a view update and cannot establish what had focus at key-down. The smallest seam is one optional main-actor presentation callback, called with the hold ID immediately after minting it, before any async work. The practice view registers a callback only while mounted; that callback records the actual current practice FocusState with that ID. Lifecycle clearing must only clear the view's own registration, and release captured view state on disappearance. This callback must neither gate capture nor change where injection goes.

Tighten the existing consumer to record `beganHold(id:inPracticeField:)` and require `delivery.id == beganHoldID`; its current boolean alone does not correlate a receipt with the focused hold. Feed it from both actual receipt changes and actual field changes, since either SwiftUI observation may arrive first. A field change is only a chance to consume the already-existing, matching inserted receipt; it cannot create success. A receipt from before mount, copied text, mismatched hold, empty output and a hold begun elsewhere remain rejected. Store nothing beyond this existing practice view state.

Presentation consumers: OnboardingShortcutStep, DictationView/DictationStatusBand, then existing compressed HUD/island completion surface if it already has an appropriate lifetime. Use concrete words such as “Text inserted” or “Copied to clipboard.” Do not add a fixed dismissal delay or a second completion state machine merely to display a success. The next accepted hold clears completion naturally.

## Exact edit ownership proposal

1. Coordinated Core owner: `Core/DictationController.swift` only — ephemeral value, synchronous accepted-hold presentation callback, clearing at both hold starts, and success publication through actual outcome/finish seam. Preserve existing injection, capture, retry and metrics paths.
2. Onboarding owner: `UI/Onboarding/OnboardingSteps.swift` — receipt/hold-ID correlation, lifecycle registration, actual observation hookup. `OnboardingSelfTest.swift` must describe its pure consumer proof honestly until the actual controller test is green.
3. UI owner: `UI/Dictation/DictationView.swift` and `DictationStatusBand.swift` — read the controller's receipt when idle; no history-based inference.
4. Registry owner: augment the existing real-controller dictation fixture or register a separate focused delivery flag. No worker may edit the registry concurrently.

## Actual producer test requirements

The existing `--selftest-dictation` constructs actual controllers with a scripted `SelfTestEngine`, `insert`, `record: { _ in }`, and an outcome sink. It uses the real shared capture hub and microphone, so its current fixture is not permission-free. Its delayed-insertion case already proves a canceled old insertion cannot end a new recording. Extend this actual path, replacing only insertion and history effects:

| Actual injector result / event | Required production observation |
| --- | --- |
| Inserted output | One receipt; same ID as the actual outcome sink/run; exact final output; practice succeeds only for that hold and observed field words |
| Copied-by-choice | Clipboard kind; no practice success |
| Could-not-return | Existing clipboard-recovery error; no inserted receipt |
| Superseded or canceled delayed insertion | No old receipt, no clearing of the newer hold, no practice success |
| Next accepted hold / retry | Old receipt clears; new hold identity and synchronously sampled focus |
| Manual typing, no actual hold | No receipt and no practice success |
| Practice focus changes during tail | Hold provenance retains its beginning; do not read focus late |
| Receipt first / field update first | Same final consumer verdict; no invented typing or timer |

Keep all record/usage effects isolated and run the owner-store guard. The existing ordinary controller hold must reach actual capture and insertion; a helper returning fabricated delivery is not production proof. Required related checks remain dictation, onboarding, dictation hygiene, AX readback and user-visible strings. Live insertion/switch-away behavior and feedback latency still require the unlocked Mac and grants.

## Source risks to preserve and check

The tail has an existing session check immediately after injection, then later awaits `engine?.startLaneWait` before switching on `outcome`. A new receipt must never be published after a session change during that await. Recheck session immediately before the switch (and test the actual suspended producer); the exact old cancellation case should stay unchanged. This is a source hypothesis until the suspended branch is exercised, not a verified fix.

`TextInjector` verifies Accessibility writes by observing movement, but its pasteboard fallback reports `.inserted` after posting paste and its existing delivery wait; it does not read back the target's text. Consequently this receipt proves the injector's actual result, not independent destination readback for arbitrary apps. The practice badge adds the actual field observation. Keep broader “words landed” claims bounded until real target readback is verified. Repairing that external delivery verification, if required, belongs to the injection producer owner and must preserve the app's latency contract.

## Verification status

Original manual-edit and calendar-autorecord regression evidence is in `ux08-09-close.md`. Existing consumer helper checks are not an actual controller-to-view proof. This report has no new green test claim and does not close UX-08 or UX-09.

## Implemented after source release

- `DictationController.latestDelivery` is one ephemeral observable value with existing hold identity, exact final nonempty text and inserted/copied kind. It is published from the actual injector result immediately after the existing same-session guard, **before** the existing asynchronous usage metric read, rather than during later idle cleanup. This boundary prevents a late metric hop from attributing a new receipt to a superseded hold. It adds no await and makes no claim to fix the existing post-metric cleanup hypothesis.
- Both accepted hold and retry clear the prior receipt. A single optional owner-scoped synchronous hold observer captures practice FocusState and field text at accepted beginning. Replacement observers cannot be cleared by an older disappearing view. No observer gates capture or injection.
- The actual practice view observes receipt and field changes, requiring same hold ID, focus at beginning, changed field text and the exact output present. Manual text without an actual receipt remains insufficient. Lifecycle disappearance clears the view's observer. Pure onboarding cases now additionally cover a mismatched hold and words already present before the hold.
- The actual dictation status band reads the receipt while idle: Text inserted or Copied to clipboard. It does not inspect history, guess a target app or add a dismissal timer. Existing capture/error/finishing states keep priority.
- No registry or compressed HUD/island source was edited. The existing post-metric cleanup risk and arbitrary pasteboard readback limits remain open as described above.

`git diff --check` passes for all five assigned Swift files. Compiled/native verdicts and rendered first-success interaction remain pending. `ux08-dictation-fixture.swift.txt` contains an exact proposed root-owned extension of the existing real-controller flag and its original delayed-insertion cancellation case. It must be compiled and run before accepting the delivery contract.

Source freeze SHA-256:

| File | SHA-256 |
| --- | --- |
| Core/DictationController.swift | `5a4796949255c8a61d2313147a0bf1399a9d35f10edaab3643a9367a9695376a` |
| UI/Onboarding/OnboardingSteps.swift | `271981d86c0812963dac1f5583f927a0d8c7992e9f5880e01ccb1cfed8b18b65` |
| UI/Onboarding/OnboardingSelfTest.swift | `7de35b6649bdd5fdcd22ccc426d7bac86944fbf1876bd51f28dc62705cefdddc` |
| UI/Dictation/DictationView.swift | `8c749a0edb0d63b4be7bb128b3655e7fe5c81c376a90b58b41846f9a7e85813f` |
| UI/Dictation/DictationStatusBand.swift | `30b4cc460ea4c597ef88340930db89b602e3320701b089582ac92a54ef363412` |

## Roadmap closure execution checklist — current app9 audit

Read-only audit requested by the coordinator. No source, STATUS, build or native test changed/run during this audit. Some earlier reports still say pending despite newer native logs; use the exact build's evidence and keep physical gates distinct.

### Observed installed app9 evidence

- `/tmp/nextnotes-agent-closure-install-9.log`: `Build complete! (33.47 sec)`.
- `/tmp/nextnotes-agent-closure-ui-9/`: `AGENT_PRESENTATION_OK: actual typed stream, stable commit, Stop, isolation`, `AGENT_PANES_OK`, `AVATAR_OK`, `ISLAND_OK`, `ONBOARDING_OK`, `SETTINGS_OK`, `TOOL_REVIEW_OK`, `UI_STRINGS_OK`. These markers cover the corresponding fixture contracts on app9.
- `/tmp/nextnotes-agent-closure-core-9/`: `DICTATION_OK: every hold came back to idle`, `MEETING_BUS_OK`, `MEETING_LIVE_OK: cadence, cards and the authority split hold`, `DUPLEX_OK`; the core summary is 21/22, with inherited `WAKE_LIVE_FAILED: 17/24 hits, 3/32 false`.
- `/tmp/nextnotes-agent-closure-experience-9.log`: `EXPERIENCE_SHEET_OK: 72 isolated layout images; /tmp/sheets/experience-app9`. There are 72 image files. Image creation/isolation is verified; all-image visual review is not established by that marker.
- The archived `installed-cdp-2026-10-01.log` reports all actual Chromium action assertions PASS, including once-only uncertain delivery, stale-node refusal and two human-input checks. It is earlier browser-compat evidence, not the app9 full desktop or newest-source gate.

App9 predates the new delivery producer/consumer and integrated OnboardingSheet. Its dictation/onboarding successes must not certify those later edits. Older reports' seven-state visual review is not a review of all app9 fixed-theme images. The earlier bare-binary missing-avatar result is superseded by app9's packaged `AVATAR_OK`, not by source inspection.

### Exact remaining checks by slice

| Slice | Remaining acceptance beyond existing evidence | Can run without physical audio or owner data? |
| --- | --- | --- |
| UX-02 | Inspect actual request-first/stable composer/long work/real partial row; select and Copy text during chunks; scroll back and use Latest answer; Stop; one VoiceOver announcement rather than every token; second typed turn follows the owning P3-11 contract. Measure first visible feedback. | Scripted actual presentation self-test is already app9 green and can rerun isolated. An isolated interaction harness can safely check controls, but cannot prove the actual pane's scroll/VoiceOver/live frames unless it renders the actual production flow. |
| UX-03 | Keyboard/VoiceOver Tab, Return, Escape, edit/missing-field focus, immediate decision acknowledgement, pane/island same pending identity, no duplicate approval or moving focused buttons. Rerun ACP confirmation on the final binary. | Tool-review/ACP fixture gates and placeholder review controls are safe. ExperiencePreview currently retains the old inset stress arrangement: it is useful for leaf controls, not proof of the production card's relocated thread layout. |
| UX-04 | Complete/fail/cancel/deny terminal cards visible; generated result links/actions actually open/copy; navigate away/back preserves result; send-risk Retry still cannot bypass approval. | Runtime/task/permission fixture gates and isolated temp-file results are safe. Rendered task-state and navigation proof still needed. No owner send or retry is necessary. |
| UX-05 | Measure key-down→visible listening, work→island text, approval→acknowledgement versus UX-00; preserve real microphone/speaker/model overlap; inspect floating non-notched treatment if a display is available. Speaking stage requires the existing P3-09 producer, not a fabricated UI state. | Island/avatar/state fixtures are safe; scripted duplex is app9 green. Neither proves physical duplex, displayed latency or a second display. |
| UX-06 | Actual desktop window/AX/thumbnail updates; no-grant useful summary; real human touch yields before the next event; pending review stays available; verify current final computer/yield/vision flags. | Headless local Chrome and grant-free publisher fixtures are safe with isolated pages. The combined yield flag's OK summary can explicitly say live half not run; do not count it as unlocked desktop proof. Actual desktop events require the unlocked Mac, grant and an isolated test window. |
| UX-07 | Before/Record/Skip, live recording versus finishing, actual two audio tracks, provisional/committed transcript, finished decisions/draft follow-up; scrollback persists; no sent claim before one approval. Capture sanitised meeting flow at 900×600 including 360pt detail extreme. Rerun console/reconcile/finals with explicit fixture path. | Meeting fixture flags and console/shell diagnostic are safe. Real/sanitised microphone + system-tap capture is still required for the physical flow. New proactive brief/wrap facts remain P4-04/P4-05-owned. |
| UX-08 | Compile and run the prepared actual controller receipt cases on the new binary; preserve original delayed-insertion cancellation test; actual target readback/switch-away delivery, recoverable failure and key-down→listening measurement. Compressed completion remains to review. | Pure onboarding/receipt consumer and hygiene gates are safe. Existing actual dictation fixture uses genuine mic capture; AX readback fails without grant and inspects current apps, so use a safe harness target. Neither should be called permission-free. |
| UX-09 | Render and inspect all seven themed screens/allowed-denied cases at 720×600; navigation/footer/skip and longest content; resume after close; one actual practice insertion, copied/failed/manual/outside-field rejection; real calendar beat stays triple-gated. Keyboard/VoiceOver and OS grant round-trip focus. | New 28-image OnboardingSheet is designed to suppress permission/hotkey/model/calendar effects and watch owner state; run only registered harness after build. Existing pure onboarding/guided/settings/string gates are safe. Actual first success and OS round trips still need live grants. |
| UX-10 | Full 900×600 shell, Settings floor, larger window, high contrast/larger text/keyboard focus, fixed-light contrast, all changed states under Reduce Motion/Transparency; no extra offscreen clocks; measured main-actor/voice gates and input feedback deltas. | Latest 72 leaf images, 28 onboarding images, settings/avatar sheets and isolated keyboard/VoiceOver review can cover bounded visual/control checks safely. They do not substitute for full shell, dynamic flow or load profiling. |

### Safest next serial execution order

1. Freeze integrated sources including the receipt fixture and OnboardingSheet registration; build/package through the serial owner. Record executable identity so later markers cannot inherit app9's broader claim.
2. Run the model-free, isolated named gates first: agent-presentation, agent-panes, tool-review, acp-confirm, orb, avatar, island, onboarding, guided, settings, ui-strings, dictation-hygiene, relevant task/runtime/permission checks, meeting-console/live/reconcile/finals (explicit `Tests/Fixtures` path), computer-vision and the grant-free yield assertions. Use harness/store guards; archive exact markers including absent/unverified cases. Agent-answers may require the installed model and is not the same class as a model-free presentation fixture.
3. Produce current experience/onboarding/settings/avatar sheets into fresh temporary directories and inspect them. Full image review should cover long error/title/content, missing-field controls, primary action visibility and fixed theme under reduced settings. Test app fixed light while the OS is dark; the updated roadmap no longer requests a separate app dark design.
4. Use isolated review controls for keyboard/VoiceOver, then actual sanitised production shell at 900×600 and larger. A preview's example approval does not exercise the irreversible action boundary; that boundary is proven by the permission/runtime fixture, while the actual pane's acknowledgement/focus still needs observation.
5. With an unlocked Mac and grants, run the original dictation capture/insertion/cancel flow and real desktop yield in a safe harness window; then one sanitised meeting capture and physical duplex observation. Capture failures such as ScreenCaptureKit −3811 remain missing evidence, even if AX text inspection works.
6. Re-measure UX-00 input-to-feedback and main-actor stalls plus the prescribed Agent Phase 2 voice latency flow. The recorded earlier voice median first audio 4.776s and 156ms maximum stall, missing usage joins and duplicate fifth commit remain failures until their original real flow reruns. The inherited quick score 3/10 versus the unchanged 9/10 bar and wake red are not presentation completion evidence and must remain visible.

No slice above is closed by this checklist. Global UX-11 surface adoption/font/forced-appearance sign-off and the missing UX-00 timing baseline also block whole-roadmap closure independently of UX-02–UX-10's bounded fixtures.

## Installed app12 verification

Pinned binary SHA-256: `a35a883bee7666030975ee28960ca62cf958c9a158be71978b8254f2490b488c`. The serial root integrated the prepared new receipt regression into the existing actual-controller dictation flag. Its prescribed `open -n` launch passed `DICTATION_OK: every hold came back to idle`, including the receipt, canceled pending insertion and successor-hold cases. The direct-launch attempt failed on microphone permission before valid capture; that environment failure is retained and is not evidence of a producer regression.

The same packaged app passed `ONBOARDING_OK`, including manual typing, old/clipboard/outside-field receipts, mismatched holds, already-present words, empty text, delayed field observation and actual inserted-field success. These cases validate the pure consumer contract plus the separately tested actual controller producer; they do not prove a physical first-run user inserted text into the rendered field.

Measured key-down to **capture admission** was 0.0902889967 s in the fixture with a delayed 1.5 s engine start. It is not key-down to first visible listening and does not close the unchanged visible-feedback or voice latency gate. Logs are archived in `app12/`; current theme-only source changes are later than this pinned binary.

## Confirmed stale-tail regression (original installed app14)

The new actual-controller regression reproduced five targeted assertions before any Core fence change: the old metrics-suspended tail cleared successor capture/state, filed the successor outcome early, lost the scripted positive lane-wait metric, and broke usage/hold/receipt attribution. Logs are retained in `app14-original/`. The same original run also had two independent hardware/timing failures (282ms capture admission and a silent short-hold tap); those remain reported and are not claimed fixed by the proposed fence.

Confirmed producer contracts: completion resumes after the existing asynchronous engine metrics read without checking the captured session again; the Actor protocol also omitted the lane-wait getter requirement, selecting its zero-valued extension instead of the conformer's getter. Root owns the minimal protocol requirement and has explicit handoff for exactly the Core generation check after metrics/before outcome mutation. Both fixes await installed after-verification. No UI sanitizer, retry, timeout extension or new state layer is proposed.

## Installed app17 original regression after producer repair

Pinned executable SHA-256: `0ee52308a47c409b115d0a0050719a5476c08a9132cf336fe053b185b83cb85c`. The serial root's original actual-controller flag now passes `DICTATION_OK: every hold came back to idle` (exit0,53.091s), including all five targeted stale-tail/lane-wait assertions. The two independent microphone/timing failures from app14 also pass in this run; no separate hardware producer repair is asserted.

Confirmed repaired producers: Core checks its captured session immediately after the existing metrics read/usage attribution and before finishing/failing; the Actor protocol now requires `startLaneWait`, dispatching the conformer's getter through the real existential. The unchanged original red fixture and current output are archived under `app14-original/` and `app17/`. The same app passes usage26 and watched-store21file/31default checks.

Measured capture admission89.162ms remains a different endpoint from visible listening. Transcription and insertion remain scripted; this result does not establish arbitrary real target readback, physical key handling or rendered onboarding first success. Broader UX-08/09 gates stay open.
