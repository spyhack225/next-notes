# Voice Settings round 4

Producer/presentation commit `6e374bb4`, original `09b686d1`. Own branch only.

The same updated source fixture fails five contracts on the original and passes on the fixed code: `VOICE_SETTINGS_REVIEW_FAILED: 5` -> `VOICE_SETTINGS_REVIEW_OK`. Original UI was not rebuilt. The existing nine selection/recovery wiring contracts remain `VOICE_SETTINGS_WIRING_OK`.

Availability messages and their pane/notch links now say “Open voice settings” or “Try again in voice settings”. The Voice section draws a small spinner immediately left of the preparation title, removes the dotted orb and empty spinner row, and reports missing download only in the status row. Unselected tiles describe their choices and retain only known ready/preparing state. Selected failure still says “Couldn't start · tap Retry”, including Kokoro. Retry already had native `.borderedProminent` and accent tint in round three; those are retained, without painting a diagnostic approximation. Actual window prominence requires native observation.

Four product files changed: `Agent/Speech/AgentVoiceAvailability.swift`, `UI/Components/VoiceTextOnlyNote.swift`, `UI/Settings/VoiceSettingsSection.swift`, `UI/Settings/VoiceSettingsSelfTest.swift`. The latter changes only expected copy. Selection, recovery, preparation owners and epoch wiring are untouched. These four files are absent from the provided canonical dirty-source list; cumulative earlier UI conflicts still apply. Reconcile availability copy with later no-apple owner changes.

R3 N5 cannot be confirmed: the pre-existing optional disclosure in ModelsSettingsTab passes `Kokoro-82M (FluidAudio)` / `Pocket TTS (FluidAudio)` to Text(modelID). It names a model/provider; no file path is passed there. This is retained, outside the four requested changes.

Native evidence and visual verdicts follow after the one normal FIFO slot. `run-batch.py` retains full logs, exact root markers/exits and binary/source hashes and deletes only assigned scratch and its private TMPDIR. No install, GUI opening, push or main merge. No product-performance/default/quality/phase promotion.

One normal heavy.sh FIFO slot: WebRTC and debug build exit 0, `Build complete! (277.33 sec)`; compiler duration is not product latency. Wrapper exit **1**, because Settings prints its OK marker then exits **-11** again. This is the inherited failed process, with no crash-cause claim. Voice Settings/UI strings/preview exit 0. All 844 built Sources pins match current source; no product source changed after build.

| Check | Process exit | Exact final root marker |
| --- | --- | --- |
| `webrtc-build` | 0 | `NO_FINAL_MARKER` |
| `build` | 0 | `NO_FINAL_MARKER` |
| `voice-settings` | 0 | `VOICE_SETTINGS_OK` |
| `ui-strings` | 0 | `UI_STRINGS_OK` |
| `settings` | -11 | `SETTINGS_OK: 12 pane(s), Formatting listed, headings contain U+0020, each form built, profile captured, auto-send policy, every pane fits the narrowest host` |
| `preview` | 0 | `VOICE_SETTINGS_PREVIEW_OK /Users/sergekadjo/Library/Caches/NextNotesBuild/wt/voice-settings-ui/Tests/Reports/voice-settings-ui/round4/shots` |

All eleven PNGs inspected. Four requested copy/layout findings are visually corrected; both preparation states and the real Models page show one inline spinner. Inactive native Retry remains gray despite `.borderedProminent` plus accent tint. **Active prominence is unverified**, and no diagnostic paint was added. Actual animation/click-through, live notch truncation, VoiceOver/accessibility toggles, real downloads/offline recovery, physical speech and release/full-duplex performance are unverified. The existing native fixture substitutes hardware/model synthesis boundaries, exercises actual selection/retry owners, and passes its original recovery/epoch cases plus changed copy assertions.

Assigned scratch and private TMPDIR are deleted; see cleanup.json. Foreign files/processes/claims, shared scratch and owner stores were preserved. No install, push, main merge, model/default/quality/phase promotion. Four round-four product files do not overlap MAIN-DIRTY-SOURCES.txt; prior cumulative conflicts in ModelsSettingsTab, AgentView, IslandView, NextNotesApp and SettingsSheet remain “will conflict with uncommitted work”. The availability-copy file must be reconciled with the no-apple owner's later changes. N5's pre-existing model/provider disclosure remains as described above, for the integrator/owner to decide.
