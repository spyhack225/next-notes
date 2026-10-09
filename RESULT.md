# voice-settings-ui round 3

Own branch `claude2/voice-settings-ui`; producer/UI commit **`98f9205a`**. The final documentation commit retains the native results, screenshots and integration limits. No install, push or merge into main. Round-two results and cumulative conflict guidance are retained below.

## Cause and changes

The Voice UI itself produced repeated unsupported-version/size copy, a footer regardless of state, a selected unsupported tile and an authored 40% preview. The shared availability message also told people to download while startup already owns automatic preparation. These producers now provide per-state plain copy, a ready-only footer, a checkmark for supported selection, one unsupported warning without a selected outline or Heart row, and indeterminate unknown progress. The backend exposes four Pocket choices and one Kokoro voice; tiles state that bounded difference. Small explanatory text uses callout size.

Failure shows an orange warning and Retry beside it, using native prominent style plus explicit accent tint. The live notch line uses a compact wrapping component and a blue Voice settings button; pane links are blue and destination copy appears once. State changes claim the notch note once and ready clears its existing claim. The native test invokes this same seam. Preparation's orb is still; the page header is already still. Previews explicitly pin SwiftUI light plus AppKit aqua and include the real Models form, scrolled to Speaking back, at 560pt.

Selection still saves immediately, captures the request epoch and enters only `prepareSelectedVoice()` for selection/Retry. Preview still requires live availability.ready. There is no Apple voice tile/catalog/preview and no direct preparation, automatic voice switch or old-answer replay. No turn-path wait, model pass/store or audio-owner change was added.

## Original/fixed checks and single guarded slot

Identical source fixture: original `514fcfc7` exits 1 / **`VOICE_SETTINGS_REVIEW_FAILED: 20`**; fixed exits 0 / **`VOICE_SETTINGS_REVIEW_OK`**. Original/current hashes are retained. Nine round-two wiring contracts still pass **`VOICE_SETTINGS_WIRING_OK`**. Original native UI was not rebuilt.

One normal heavy.sh FIFO slot builds successfully: `Build complete! (265.24 sec)`. All 844 Sources files match the built pins. Compiler duration is not product latency. Full inputs, binary/source hashes, logs, original/fixed fixture and PNGs are in [round-three evidence](Tests/Reports/voice-settings-ui/round3/README.md).

| Check | Process exit | Exact final root marker |
| --- | --- | --- |
| `webrtc-build` | 0 | `NO_FINAL_MARKER` |
| `build` | 0 | `NO_FINAL_MARKER` |
| `voice-settings` | 0 | `VOICE_SETTINGS_OK` |
| `ui-strings` | 0 | `UI_STRINGS_OK` |
| `settings` | -11 | `SETTINGS_OK: 12 pane(s), Formatting listed, headings contain U+0020, each form built, profile captured, auto-send policy, every pane fits the narrowest host` |
| `preview` | 0 | `VOICE_SETTINGS_PREVIEW_OK /Users/sergekadjo/Library/Caches/NextNotesBuild/wt/voice-settings-ui/Tests/Reports/voice-settings-ui/round3/shots` |

Wrapper exits 1 for the **Settings failed process**: its assertions print the exact OK marker above and it then crashes with -11, as inherited from round two and peer reports. It is not a pass and its crash cause is unassigned. Voice Settings, UI strings and previews exit 0. The Voice Settings fixture retains actual selection/Retry recovery/epoch coverage and adds per-state text/once-per-state clearing plus production lint negatives for macOS version/MB/GB. Hardware/model boundaries remain substituted.

## Inspected PNGs and limits

All 11 PNGs were inspected. Light backgrounds, supported-selection checks, unsupported Kokoro without selected styling/Heart, ready-only footer, honest preparation, blue settings links and complete compact notch wording are confirmed in the offscreen images. The real 560pt Models page shows its header and whole Voice section with native margins/form style. No Apple voice or file size is displayed in that section. See [visual inspection](Tests/Reports/voice-settings-ui/round3/visual-review.json).

Native inactive offscreen panels still draw prominent buttons gray, including Retry. Its source now explicitly uses the accent-tinted primary style; **active-window color/prominence is unverified** because opening the GUI is prohibited. Live notch/pane mounted behavior, click-through, VoiceOver, Reduce Motion/Transparency toggles, physical speech, real download/offline recovery and performance/full-duplex remain unverified. No default, aggregate quality, phase or broader acceptance is promoted.

## Files, conflicts and cleanup

Seven round-three sources: `Agent/Speech/AgentVoiceAvailability.swift`; `UI/Components/VoiceTextOnlyNote.swift`; `UI/Settings/ModelsSettingsTab.swift`; `UI/Settings/VoiceSettingsSection.swift`; `UI/Settings/VoiceSettingsPreview.swift`; `UI/Settings/VoiceSettingsSelfTest.swift`; `UI/UIStringsLint.swift`. Evidence is under `Tests/Reports/voice-settings-ui/round3/`; PERFORMANCE-STANDARDS gets an append-only reference.

`ModelsSettingsTab.swift` **will conflict with uncommitted work**, per MAIN-DIRTY-SOURCES.txt. Preserve canonical OutputScheduler/preview/onAppear edits when applying the diagnostic-only availability override. Round-two cumulative conflicts below still apply. The availability-message file is owned by the no-apple voice branch; this round changes copy only, so preserve any later producer repairs while reconciling it.

Own scratch and the private test TMPDIR are deleted (`cleanup.json`); own relay scratch is also deleted. Foreign files, processes, claims, shared scratch, owner data and supplied briefs/transcripts are preserved. Final scope/verdicts are relayed to claude-positioning and the project; sending is not reading proof.

---

# voice-settings-ui round 2

Own branch: `claude2/voice-settings-ui`. Rebased the three UI commits from `d52ebaca` onto `8097108a561f3039cfdda395c81741df86fbe59e`, with no conflicts. No install, push or merge into main.

## Commits

- `9dc96031` -> `df7159dc`: Pocket/Kokoro Voice section and live availability.
- `0a2d82ff` -> `4c116de7`: written-answer lines in the pane and notch card.
- `4730148b` -> `3fa4196e`: offscreen voice-state previews.
- `e07867fb`: current-request selection/Retry wiring, actual callback regression and retained round-two evidence.
- Final report commit updates this file and the shared performance reference only.

## Cause and change

The legacy Settings consumer at `8097108a` uses model readiness for selection/preview and prepares models directly. A cached-ready playback failure is a speech-owner latch, so that consumer cannot recover it by checking readiness or entering the model alone. The first UI commit already changes this to live availability and `prepareSelectedVoice()`.

This round closes the remaining UI contracts: the failed state says **Retry**; selection writes immediately through `Settings.agentVoiceEngine`, which owns the selection epoch; selection and Retry capture `selectedVoiceRequest` at the click and refuse a replaced request before entering `prepareSelectedVoice()`. Explicit owner entry runs even for cached readiness, clearing failure and advancing recovery identity. Opening Settings no longer calls Pocket/Kokoro preparation directly; normal startup owns automatic preparation. The backend's failure, preparation, file-synthesis and receipt semantics are unchanged. No Apple voice tile, catalogue or preview remains in the Voice section.

The preview now draws both voices' four availability states, possible progress and selected unsupported Kokoro. Its flag enters isolated SelfTest preferences, and the authored selection never changes the saved choice.

## Original/fixed proof

The same nine-contract source fixture reads the original consumer at `8097108a`: exit 1, `VOICE_SETTINGS_WIRING_FAILED: 8`. The rebased first-round UI at `3fa4196e` fails four: exit 1, `VOICE_SETTINGS_WIRING_FAILED: 4`. Current wiring passes: exit 0, `VOICE_SETTINGS_WIRING_OK`. Exact source hashes are retained in the three logs. This RED is source evidence, as permitted by the brief; the original native UI was not rebuilt.

New `--selftest-voice-settings` exits 0 with `VOICE_SETTINGS_OK`. It invokes the actual Section callbacks, isolated Settings writer, speech failure owner, preparation owners and file consumer. Both engines recover a cached-ready playback failure without replay; Pocket -> Kokoro -> Pocket invalidates older selection/Retry Tasks; unsupported selection is refused. Cold load failure -> preparing -> ready goes through the actual Pocket/Kokoro preparation tasks and admits the actual file consumer. Hardware PCM, native initialize/warm and file PCM generation are substituted; no model downloads or real speech are claimed.

## One guarded build and native batch

One normal `heavy.sh` FIFO slot, `RELAY_ID=claude2-voice-settings-ui`; no resource override. Debug build exits 0, `Build complete! (260.63 sec)`. This is compiler time, not product latency. Sixteen of eighteen self-test processes pass, and the preview passes. Wrapper exits 1 for the two failed processes. Full logs, exact arguments, binary/source pins and exits are in [round-two evidence](Tests/Reports/voice-settings-ui/round2/README.md). All 844 built source files match the committed product sources.

| Check | Process exit | Exact final root marker |
| --- | --- | --- |
| `webrtc-build` | 0 | `NO_FINAL_MARKER` |
| `build` | 0 | `NO_FINAL_MARKER` |
| `voice-settings` | 0 | `VOICE_SETTINGS_OK` |
| `settings` | -11 | `SETTINGS_OK: 12 pane(s), Formatting listed, headings contain U+0020, each form built, profile captured, auto-send policy, every pane fits the narrowest host` |
| `ui-strings` | 0 | `UI_STRINGS_OK` |
| `tts` | 0 | `TTS_OK` |
| `tts-stream` | 0 | `TTS_TOKEN_STREAM_OK` |
| `voice-policy-review` | 0 | `VOICE_POLICY_REVIEW_OK` |
| `voice-conversation` | 0 | `VOICE_CONVERSATION_OK` |
| `voice-delivery` | 0 | `VOICE_DELIVERY_OK` |
| `voice-scheduling` | 0 | `VOICE_SCHEDULING_OK` |
| `duplex` | 0 | `DUPLEX_OK` |
| `concurrent-voice` | 0 | `CONCURRENT_VOICE_OK` |
| `voice-turn-routing` | 0 | `VOICE_TURN_ROUTING_OK` |
| `voice-playback-projection` | 0 | `VOICE_PLAYBACK_PROJECTION_OK: 33 checks` |
| `voice-playback-resume-receipt` | 0 | `VOICE_PLAYBACK_RESUME_RECEIPT_OK: 48 checks` |
| `catch-up` | 0 | `CATCH_UP_OK` |
| `agent-panes` | 0 | `AGENT_PANES_OK: 3 panes, unique titles, Reminders and Goals say what they are, layout on the shared scaffold` |
| `island` | 1 | `ISLAND_FAILED: 13 rule(s) wrong` |
| `store-isolation` | 0 | `STORE_ISOLATION_OK: 21 files and 0 defaults unchanged` |
| `preview` | 0 | `VOICE_SETTINGS_PREVIEW_OK /Users/sergekadjo/Library/Caches/NextNotesBuild/wt/voice-settings-ui/Tests/Reports/voice-settings-ui/round2/shots` |

Source census: exit 0, `VOICE_SINK_SOURCE_OK`, forbidden 0 / bounded exceptions 27 / files 912. Source whitespace check passes; raw compiler logs and the retained patch contain whitespace reported by a whole-report whitespace check and are preserved verbatim.

## Failed and inherited scopes

- **Settings:** prints the assertion marker above, then SIGSEGV/exit `-11`. Retained as the inherited, unassigned failure requested by the brief. It is a failed process, not a pass; no crash-cause claim or UI baseline rebuild.
- **Additional Island check:** `ISLAND_FAILED: 13 rule(s) wrong`. Its actual fixture installs `RecordingSpeechBacking`, which has no resume-receipt protocol. The inherited `IslandOwnership.isEnabled` and `VoiceSession` require that capability for owned projection; the fixture still expects it, and its endpoint guard rejects before a visible panel or the older view checks. Those owners, fixture, state source and `runIslandSelfTest` body match `8097108a` exactly. [Source attribution](Tests/Reports/voice-settings-ui/round2/island-inheritance.json) is retained and sent to the no-apple owner; no native baseline was rebuilt and no receipt gate or test was weakened.
- Voice delivery's 13 reducer divergences, duplex's 2, and store isolation's 18 embedded browser failures plus `TOOLLOOP_PRODUCTION_FAILED` remain open. All six normalized diagnostic comparisons equal no-apple round-four logs after removing generated identifiers. The outer root passes do not erase these narrower failures.

## Visual inspection and limits

All 11 PNGs in `round2/shots` were inspected: both engines' ready/preparing/download/failed states, Pocket progress, unsupported selected Kokoro and written-answer lines. Voice forms are legible; failed forms show Retry and dim the sample with plain reasons. Unsupported Kokoro is dimmed and offers Pocket. The black authored text-only box still truncates its preparing sentence; it is not the real Island card. The pane lines are legible. Progress is authored because the backend exposes no numeric download progress today.

Unverified: actual download/offline recovery, physical voice quality, mounted click-through, live pane/notch lines, VoiceOver, Reduce Motion/Transparency toggles and animated orb. No latency, full-duplex, model/default, phase or aggregate quality gate is promoted.

## Files and integration conflicts

Source delta over `8097108a`: `NextNotesApp.swift`; `UI/Agent/AgentView.swift`; `UI/Components/VoiceTextOnlyNote.swift`; `UI/Island/IslandView.swift`; `UI/Settings/ModelsSettingsTab.swift`; `UI/Settings/SettingsSheet.swift`; `UI/Settings/VoiceSettingsSection.swift`; `UI/Settings/VoiceSettingsPreview.swift`; `UI/Settings/VoiceSettingsSelfTest.swift`. Reports live under `Tests/Reports/voice-settings-ui/`; this report and the performance reference are documentation only.

Per `MAIN-DIRTY-SOURCES.txt`, these **will conflict with uncommitted work** and need manual reconciliation:

- `ModelsSettingsTab.swift`: preserve canonical OutputScheduler preview and unrelated onAppear changes; retain this section, live preview guard and removal of direct voice preparation.
- `AgentView.swift` / `IslandView.swift`: preserve other pane/card changes and the single shared written-answer line.
- `NextNotesApp.swift`: preserve other dispatch/startup/isolation changes alongside the preview hook, its isolated classification and the new self-test route.
- `SettingsSheet.swift`: render is internal for the preview; preserve canonical layout changes.

Append-only performance evidence must preserve other agents' paragraphs. ACK/Mini integration and broader native acceptance remain the integrator's work; these checks do not authorize them.

## Cleanup

Own `wt-scratch/voice-settings-ui` and the entire private test TMPDIR were deleted; `cleanup.json` confirms both absent. Shared `wt-scratch/voice`, peer files/processes/claims and staged changes were untouched. The supplied untracked brief and runner transcript remain. Final relay message reports the real failures and evidence to `claude-positioning`.
