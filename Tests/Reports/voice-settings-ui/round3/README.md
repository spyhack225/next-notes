# Voice Settings round-three review evidence

Producer change: `98f9205a`, from round-two `514fcfc7`, own branch `claude2/voice-settings-ui`.

The UI previously generated repeated version/size copy and an always-visible footer, marked unsupported Kokoro selected, and authored 40% preparation without backend progress. The availability-message producer also requested a download while startup already owns automatic preparation. The section, shared message producer, and actual pane/notch line now express the live state directly. Existing Settings preference/request-epoch/recovery ownership is retained.

`check-review.py 514fcfc7` exits 1 / `VOICE_SETTINGS_REVIEW_FAILED: 20`; the identical fixture on current sources exits 0 / `VOICE_SETTINGS_REVIEW_OK`. Both logs retain hashes of the six actual sources checked. These are source/UI-state contracts, not an original native UI rebuild. The nine-contract round-two wiring fixture still reports `VOICE_SETTINGS_WIRING_OK`.

Native checks and PNG inspection are recorded below after the single normal `heavy.sh` slot. The runner owns only `wt-scratch/voice-settings-ui` and a private test TMPDIR, uses no gate override, and never installs or opens a visible window. `run-batch.py`, `slot.log`, `checks.json`, complete logs and `build-pin.json` retain the batch inputs and result. `integration.json` names the dirty canonical file conflict.

## Guarded native results

One normal FIFO slot, no override. `Build complete! (265.24 sec)`; compiler time is not product latency. Wrapper exit 1 because the Settings process exits -11 after its OK assertion marker. All 844 source pins match the current committed Sources tree. macOS 27.2 (26B5091g), debug binary and source pins retained in `build-pin.json`; no installed app was changed.

| Check | Process exit | Exact final root marker |
| --- | --- | --- |
| `webrtc-build` | 0 | `NO_FINAL_MARKER` |
| `build` | 0 | `NO_FINAL_MARKER` |
| `voice-settings` | 0 | `VOICE_SETTINGS_OK` |
| `ui-strings` | 0 | `UI_STRINGS_OK` |
| `settings` | -11 | `SETTINGS_OK: 12 pane(s), Formatting listed, headings contain U+0020, each form built, profile captured, auto-send policy, every pane fits the narrowest host` |
| `preview` | 0 | `VOICE_SETTINGS_PREVIEW_OK /Users/sergekadjo/Library/Caches/NextNotesBuild/wt/voice-settings-ui/Tests/Reports/voice-settings-ui/round3/shots` |

The Voice Settings flag retains all round-two actual button/epoch/recovery checks and adds per-state message assertions, the actual ledger observation/claim seam and three production lint injection negatives (macOS version, MB, GB). The UI-string root runs the added literal check on the real section. The fixture substitutes native voice readiness/load/PCM boundaries, as in round two. This does not establish physical playback, real download/offline recovery or mounted view interaction.

## Visual inspection

All 11 PNGs were personally inspected through the image viewer. All are light. Both supported tiles show checkmarks when selected. Unsupported Kokoro has no selection outline/checkmark/Heart row, and shows one warning without version numbers. Ready-only footers have no sizes. Preparation is indeterminate when progress is unknown; no fabricated progress preview remains. Both orb sites have `isAnimated: false`. The black card now uses the same compact component as the real notch line; its whole sentence and blue settings button are visible, and the pane lines wrap. The new real Models page render is 560pt wide and shows its header and entire Voice section with native margins and form style.

Retry is beside the orange warning with a disabled sample. Its source uses native `borderedProminent` and an explicit accent tint. The inactive offscreen hosting panels render native buttons gray, including Retry and ready sample controls. Active-window visual prominence/color remains unverified; no GUI is opened to override the brief. `visual-review.json` retains each image hash/dimensions and these limits. Other Models-page jargon/sizes are unchanged and outside the Voice section.

The source/UI-state original was not rebuilt. Live pane/notch behavior, click-through, VoiceOver, accessibility toggles, real voice quality/download/offline recovery and release performance/full-duplex are unverified. No default, quality gate or phase is promoted.

## Integration and cleanup

Round-three sources: shared `AgentVoiceAvailability`, `VoiceTextOnlyNote`, `ModelsSettingsTab`, `VoiceSettingsSection`, `VoiceSettingsPreview`, `VoiceSettingsSelfTest`, `UIStringsLint`. `ModelsSettingsTab` **will conflict with uncommitted work** per the supplied dirty-file list; reconcile its tiny diagnostic-only availability override with canonical preview/scheduler/onAppear edits. Preserve all round-two conflict guidance in root RESULT.

`cleanup.json` confirms our scratch and private test TMPDIR absent. The only extra own relay scratch JSON was deleted. Supplied briefs/transcripts, foreign worktrees, shared scratch, processes/claims and owner stores were preserved. No install, push or main merge.
