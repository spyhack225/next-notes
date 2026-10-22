# Installed app17 focused checks

Date: 2026-10-01. Executable SHA-256:
`0ee52308a47c409b115d0a0050719a5476c08a9132cf336fe053b185b83cb85c`.
The separate runtime root owns serial compilation/installation/test execution. This archive copies its outputs; no native test was run by the UI root.

| Actual check | Result | Scope |
| --- | --- | --- |
| Dictation current | exit0, `DICTATION_OK: every hold came back to idle`,53.091s | Original actual-controller regression now passes, including the metrics-suspended stale-tail and positive existential lane-wait assertions; microphone capture real, transcription/insertion scripted |
| Usage log | exit0, `USAGE_LOG_OK: 26 cases`,1.275s | Isolated usage metadata/sanitizer contract |
| Store isolation | exit0, `STORE_ISOLATION_OK: 21 files and 31 defaults unchanged`,33.993s | Existing watched owner store/preference guard |
| Onboarding trace | exit1, `ONBOARDING_SHEET_FAILED: owner stores changed`,7.133s | Original strict diagnostic remains red; trace isolates native process registration change below |
| Worker original | exit1 | Separate runtime-owner prerequisite; not a UI success claim |

## Before/after dictation

Original app14 reports five targeted stale-tail/lane-wait failures plus two independent microphone/timing failures. App17 passes the unchanged original assertion set after the one post-metrics session check and actual protocol getter requirement. Its key-down→capture admission is89.162ms with a scripted1.5s engine start; this is not first visible listening, target text readback or general voice latency. The new actual delivery producer/consumer contract remains bounded as documented in `../ux08-delivery-contract.md`.

## Onboarding diagnostic cause

The first changed checkpoint is `welcome-not-allowed-standard/after-native-window`, before hosting the actual step. The sole recorded preference delta is `METAL_DEVICE_WRAPPER_TYPE`, absent→number in the registration and merged domains. No app/global persistent-domain difference was reported. Watched folder bytes/hash remain identical. The final original strict assertion still fails.

This is evidence of native window creation adding an in-process registration preference, counted by the diagnostic's full merged-default comparison. It is not evidence that an owner preference was durably written. No baseline was moved, no registration was warmed, no guard was narrowed and no captured content was scrubbed for this run. An evidence-based repair of the verifier's contract is still pending; no setup isolation fix is claimed here.

Standard glass capture readability, keyboard/VoiceOver, actual practice insertion, physical desktop yield and displayed latency remain open. Image creation and these fixture markers do not close the roadmap. No private Settings PNG is included.
