# UX-08 / UX-09 implementation and remaining proof

2026-10-01. Source work in the existing seven-screen onboarding, dictation pane and HUD. This is a bounded implementation report; UX-08/09 remain open until actual delivery events, packaged checks and live interaction evidence are complete.

## Confirmed causes

1. `OnboardingShortcutStep` produced success from **any nonempty manual TextField edit**. Its `onChange(of: trial)` set `didHearSomething = true`, and the screen claimed “That's it” without any dictation hold or insertion.
2. `OnboardingOutcome.closingTip` treated a calendar grant as automatic recording. It said “It starts when the meeting does” even when `Settings.meetingsAutoRecord` was off.
3. Successful `DictationController` insertion currently returns through `finishIdle`, clearing transcript and returning to idle. The actual injector outcome is not exposed as a presentation receipt; run history precedes insertion and therefore cannot prove delivery. This producer seam belongs to the coordinated dictation workstream and is **not yet edited by this task**.

## Changes

- Welcome introduces one familiar companion on the Mac, and starts with the concrete action of speaking words into another app. The existing name, avatar, native controls, seven steps and progress persistence remain the production flow.
- Removed the manual-edit success producer. `OnboardingPracticeReceipt` requires a new inserted receipt, a hold begun in the practice field and the delivered words actually present in that field. Old receipts, clipboard outcomes, empty outputs and insertions outside practice cannot earn success. **The helper is intentionally not connected to a nonexistent controller receipt yet.** The screen currently makes no unsupported success claim.
- All-set framing keeps the same named companion. Its meeting guidance reads the existing automatic-recording preference in `OnboardingOutcome.live`: Record when off, review/skip when on. A calendar grant no longer promises an effect.
- Onboarding shortcut, download status and all-set transitions obey Reduce Motion. Dictation list insertion obeys Reduce Motion. The HUD mounts its recording indicator only during actual capture; a hidden indicator cannot keep pulsing during finishing.

## Before / after evidence

Executed standalone Swift interpreter probes from **extracted real source**, without a SwiftPM app build or installation:

| Original input / contract | HEAD producer | Current source |
| --- | --- | --- |
| Manually typed practice text, no dictation delivery | exit 1, `ORIGINAL_MANUAL_INPUT_FALSE_SUCCESS` | exit 0, `PRACTICE_RECEIPT_OK: 8 checks` |
| Calendar granted; automatic recording off | exit 1, `ORIGINAL_CALENDAR_GRANT_FALSE_AUTORECORD` | exit 0, `CALENDAR_GUIDANCE_OK: automatic recording off asks for Record` |
| Automatic recording on | original unconditional promise | exit 0, `CALENDAR_GUIDANCE_OK: automatic recording on describes Skip` |

The receipt checks exercise the production consumer value type: no receipt/manual input, stale receipt, clipboard outcome, different field, hold begun elsewhere, empty insertion, field pending its actual update, and new inserted words present. `--selftest-onboarding` includes these same regressions. The interpreter proofs do **not** prove that a controller event reaches the screen.

`git diff --check` passes for the changed onboarding, dictation pane and HUD files. No packaged self-test was run by this worker; root owns serial builds and installation.

## Remaining gates

- Coordinate `Core/DictationController.swift` ownership, expose one ephemeral actual insertion/clipboard outcome through the existing observable controller, and wire the practice screen, dictation pane and compressed completion surface to that receipt. Never infer destination from frontmost app after an await or from history/usage. No added capture wait or second store.
- Drive the real controller with its existing injected engine/injector seam to prove inserted, copied, failed and canceled holds; verify the actual practice consumer. The latest successful receipt must not leak into the next hold or congratulate manual input.
- Run the packaged `--selftest-onboarding`, `--selftest-guided`, `--selftest-settings`, `--selftest-ui-strings`, `--selftest-dictation`, `--selftest-axreadback` and `--selftest-dictation-hygiene` flags through root's agreed serial workflow. Missing grants/models are not passes.
- Real insertion into the captured target, switching apps during the tail, recoverable failed insertion, first-feedback latency, resume-after-close, supported window sizes, VoiceOver, keyboard, Reduce Motion/Transparency and light/dark captures remain required. Source tests cannot close these gates.
