# Catch-up final round 2

Producer repair: `4275c5b5`. Font move: `fa3f0152`.
Saved-file playback is **not accepted for the one-channel rule**; this uses the brief's
explicit gap/report option. OutputScheduler and RealtimeAudioSession admit text only;
the existing PCM renderer's generation/callback owner and probe-only WAV adapter do not
supply a production file transport or rendered resume position. A token around the same
AVAudioPlayer would leave the failure intact. The exact seven-source investigation and
recommended extension of the existing audio owner are in
[the audio decision](Tests/Reports/catchup-final/round2/AUDIO-GAP.md). An owner decision
and separate no-apple integration remain release dependencies. No speech code changed.

IslandState.refresh was the confirmed producer: it selected an earlier Catch-up notice
before consulting new live state. On unchanged 233b5dd8, the actual presentation fixture
fails four assertions for later listening, speaking, thinking and approval; Agent-panes
exits 1 with `CATCH_UP_LATER_LIVE_FAILED` / `AGENT_PANES_FAILED: 4 problem(s)`.
The same byte-identical fixture passes after the selector repair, with
`CATCH_UP_LATER_LIVE_OK` and Agent-panes exit 0. Other notice precedence is unchanged.
Catch-up notice retention/expiry and paused playingID remain independent of visibility;
no new store, queue, model pass, await, save or timer was added. The ready-notice fixture
uses finite notices; the indefinite Play path uses the same repaired selector. Physical
Play, dictation and recording display interaction are not established by this replay.

DS.Font.briefingTitle now lives inside DesignSystem.swift's font block with its exact
original title3 serif expression. `FONT_TOKEN_MOVE_OK` records the unchanged style.
The previous broad live-priority sentence is corrected below.

One original RED heavy slot builds in 282.23s and runs Agent-panes; one final FIFO slot
builds in 137.96s and runs all nine prescribed flags. These are debug development times,
not product latency claims. Full original/fixed logs, environment, ad-hoc final signature,
binary/source hashes and exact fixture invariance are retained in
[the round-2 report](Tests/Reports/catchup-final/round2/README.md).

| Flag | Exit | Exact root marker |
| --- | --- | --- |
| `--selftest-catch-up` | 0 | `CATCH_UP_OK` |
| `--selftest-agent-panes` | 0 | `AGENT_PANES_OK: 3 panes, unique titles, Reminders and Goals say what they are, layout on the shared scaffold` |
| `--selftest-ui-strings` | 0 | `UI_STRINGS_OK` |
| `--selftest-island` | 0 | `ISLAND_OK: 2 display(s), notched, placement notch, state machine behaves` |
| `--selftest-commandkey` | 0 | `COMMANDKEY_OK` |
| `--selftest-voice-conversation` | 0 | `VOICE_CONVERSATION_OK` |
| `--selftest-duplex` | 0 | `DUPLEX_OK` |
| `--selftest-settings` | 139 | `SETTINGS_OK: 12 pane(s), Formatting listed, headings contain U+0020, each form built, profile captured, auto-send policy, every pane fits the narrowest host` |
| `--selftest-store-isolation` | 0 | `STORE_ISOLATION_OK: 21 files and 0 defaults unchanged` |

Eight flags exit 0. Settings emits its OK then inherited SIGSEGV139; it is not a clean
pass, and the final wrapper exits 1. Isolation's nested browser loop still has 18 WRONG
lines/TOOLLOOP_PRODUCTION_FAILED, and duplex still has two turnPending diagnostics; all
those diagnostic lines match the prior combined evidence exactly. The retained Catch-up
history-save refusal is not generalized as task persistence success. No introduced
failure was found within the requested checks. All 24 tested source hashes still match.

Own scratch, two run roots and 27 completed-PID fixture folders are removed, with evidence
in cleanup.json. No install, push, GUI opening, main merge, foreign cleanup or owner-store
seeding occurred. Round 2 changes four source files plus this result, performance reference
and reports. IslandState.swift and DesignSystem.swift **will conflict with uncommitted
work**; the exhaustive seven full-branch conflicts are listed in the historical section
below and round2/main-dirty-overlap.txt. Native physical/acoustic, model quality, release
performance and broader task/recovery contracts remain open; no gate/default is promoted.

---

# Catch-up final integration

Merge commit: `eaafc732a676ac3ea96bc407c3aba60b59b3f0a8` on `claude2/catchup-final`.
Parents: audio `63a7e4718c718b47feb84527d6113ba3266cdd9a`, UI `c0d3746236719dfa994abecd47918754f26d0c08`.
Evidence commit: the final branch commit titled `Retain combined Catch-up native proof and integration handoff`.
Only this worktree and its authorized scratch/temporary fixtures were changed. No installation, push, or merge into main.

## Resolution and producer contract

The only conflicted file was `Sources/NextNotes/UI/CatchUp/CatchUpViews.swift`, in
the closing-question documentation and button row. Both parent histories and
three-dot diffs were read and are retained in [the report](Tests/Reports/catchup-final/README.md).
The row retains the UI's verb-phrase guard: a real offer uses `library.acceptOffer(entry)`;
an ordinary closing question uses Reply to open the conversation, with no Yes button.
No thanks closes the offer. The accessibility hint and visible explanation reuse the
audio branch's standing-grant wording. No second action or conversation path was added.

The automatic merge also retains the explicit view-layer clock, the 15-minute preparing
window's end, shaping orb, empty-state copy for returned schedules, master Reminders
switch explanation, and the ready notice's refusal to replace a live or unanswered card.

The real `CatchUpPlayer` is in `CatchUpLibrary.swift`. `playingID: String?` remains set
while paused; `isPlaying: Bool` distinguishes Pause from Resume; `problem: String?` is
plain copy. Library and island controls call the same toggle, and no view owns or calls
AVAudioPlayer. The Library shows the sentence beside its play area without disabling
Play. The island's toggle holds its notice indefinitely while its task ID is current;
pause retains that ID, and the observation removes the notice when that ID is released.
A live state or unanswered question takes priority over a Catch-up notice, including one
held indefinitely for playback. The notice remains separate from the player's paused
identity and can reappear when the live state ends; Close can dismiss the notice.
Round 2's original/fixed presentation evidence below establishes the later-arrival repair.

Accepted offers still call `CatchUpLibrary.acceptOffer` → `LiveCatchUpOfferActing.say(_:for:)`,
which records the background context before opening/submitting one ordinary turn and
passes the existing `CatchUpAcceptance` into handleLive/typed work and prompt consumers.
Normal permission behavior, including covering standing grants, remains unchanged.

One additional producer mismatch was confirmed in the UI parent's Settings footer: it
promised a fresh yes for every send. The smallest repair reuses
`CatchUpOffer.permissionExplanation` and distinguishes the read-only catch-up from an
accepted suggestion. The identical focused source predicate returns
`SETTINGS_PERMISSION_COPY_ORIGINAL_FAILED` for `c0d37462` and
`SETTINGS_PERMISSION_COPY_FIXED_OK` for the merged file. This is copy correctness;
the original/fixed native permission-policy evidence remains in the audio parent report.
The actual Agent-panes source consumer additionally pins this footer contract.
No pre-fix full app was built for this copy repair; the merge began with conflict markers.

## Native verification

One normal FIFO61 slot used `RELAY_ID=claude2-catchup-final ../heavy.sh`.
Queued at 04:30:51 UTC; admitted 04:55:53 UTC after preceding jobs and a brief unchanged
disk gate hold. The debug build completed in 266.91 seconds, exit 0; the wrapper exited 0.
This duration is a development build observation, not an app latency measurement.
macOS/power/thermal output, tested source revision, all 23 changed-source hashes,
binary hash/UUID, raw stdout/stderr and available separate diagnostics are retained.
All 23 source hashes match after testing; no product code changed afterward.

| Requested flag | Exit | Exact root marker |
| --- | --- | --- |
| `--selftest-catch-up` | 0 | `CATCH_UP_OK` |
| `--selftest-agent-panes` | 0 | `AGENT_PANES_OK: 3 panes, unique titles, Reminders and Goals say what they are, layout on the shared scaffold` |
| `--selftest-ui-strings` | 0 | `UI_STRINGS_OK` |
| `--selftest-island` | 0 | `ISLAND_OK: 2 display(s), notched, placement notch, state machine behaves` |
| `--selftest-commandkey` | 0 | `COMMANDKEY_OK` |
| `--selftest-voice-conversation` | 0 | `VOICE_CONVERSATION_OK` |
| `--selftest-duplex` | 0 | `DUPLEX_OK` |
| `--selftest-settings` | 139 (SIGSEGV) | `SETTINGS_OK: 12 pane(s), Formatting listed, headings contain U+0020, each form built, profile captured, auto-send policy, every pane fits the narrowest host` |
| `--selftest-store-isolation` | 0 | `STORE_ISOLATION_OK: 21 files and 0 defaults unchanged` |

Settings is **not a clean process pass**: its checks print the marker, then it hits the
known inherited exit SIGSEGV (signal 11). The crash remains open and was not repaired.
Store isolation's root reports 21 files and 0 defaults unchanged, but its embedded
browser tool-loop still emits 18 `TOOLLOOP_PRODUCTION_WRONG` diagnostics and
`TOOLLOOP_PRODUCTION_FAILED`. Those 18 lines match the audio parent's retained native
log exactly. The two `VOICE_SESSION_DIVERGENCE` turnPending diagnostics (timer and
inputWithdrawn) also match the audio parent exactly; the duplex root exits 0.
[The comparison](Tests/Reports/catchup-final/inherited-diagnostics.txt) retains these
narrow inherited verdicts. None is relabelled as repaired or promoted.

Catch-up additionally retains `CATCH_UP_APPROVAL_OK`, `CATCH_UP_HANDOFF_CHECKS 12`,
`CATCH_UP_HANDOFF_OK`, `CATCH_UP_PLAYBACK_CHECKS 45`, `CATCH_UP_PLAYBACK_OK`,
`CATCH_UP_ACCEPTANCE_OK`, `CATCH_UP_WAKE_OK`, `CATCH_UP_PERMISSION_OK`,
`CATCH_UP_PROVENANCE_OK`, `CATCH_UP_SPEECH_BACKING speak=3 resume=1 overlaps=0`, and
`CATCH_UP_STANDING_GRANT effects=1 new_card=false`. These exercise the existing real
producer/consumer seams with isolated history, scripted model/backing and substituted
file transport; they do not establish physical playback or real-model accuracy.
The merged screen source scan passes without changing any existing scan marker or
weakening a test. Only the additional footer permission assertion was added.

## Preview inspection

All four PNGs were rendered in the same Agent-panes run with
`--catch-up-preview-dir <unique folder under TMPDIR>`, then inspected with view_image.
They are retained in [previews](Tests/Reports/catchup-final/previews).

- [Narrow cards](Tests/Reports/catchup-final/previews/catch-up-cards-narrow.png), 680×1712 pixels: four vertical cards show preparing, the expired text-only state, ready-to-listen with duration, and an older text-only entry. The long headline and permission sentence wrap; all text remains readable without clipping. The newest offer shows Send the reminders and No thanks, with Read it links.
- [Wide cards](Tests/Reports/catchup-final/previews/catch-up-cards-wide.png), 1520×1596 pixels: the same four cards remain a single preview stack, with less wrapping and more horizontal whitespace. This preview is not a rendering of the pane's adaptive grid.
- [Plain question](Tests/Reports/catchup-final/previews/catch-up-card-plain-question.png), 680×560 pixels: Anything else on your mind? is followed by Reply and No thanks, with no Yes button. The shared permission explanation and Read it are visible.
- [Settings](Tests/Reports/catchup-final/previews/catch-up-settings.png), 1120×840 pixels: both switches are off, Time shows 6:00 AM, and the complete corrected footer wraps onto two lines. No footer clipping is visible.

These offscreen images omit glass and prominent-button fills. In the listening card
there is space for Play to the left of the inset title, but its glyph is not visibly
drawn. They establish text/layout visibility only, not the final onscreen material,
button contrast, physical interaction or paused/playing appearance. Those control
states are covered by native player/value/source checks rather than these idle PNGs.

## Cleanup

The own scratch path, explicit temporary preview/log folder and 26 fixture folders
bound to the nine exited self-test PIDs were removed after source invariance checks.
Preview images and logs were copied into the report before cleanup. The PID roots are
bound to the sequential flag-log creation intervals within the exclusive native slot;
exact paths/intervals and exit checks are retained in
[cleanup.json](Tests/Reports/catchup-final/cleanup.json). No foreign process, scratch,
shared dependency cache, installed app, owner store or canonical source was changed.

## Files and canonical uncommitted conflicts

This merge changes CatchUpViews.swift, CatchUpSettingsSection.swift,
CatchUpPresentationSelfTest.swift, IslandState.swift and IslandView.swift relative to the
audio parent. The round-1 combined source list relative to `c6d850c` is retained in
[combined-source-files.txt](Tests/Reports/catchup-final/combined-source-files.txt);
round 2 adds DesignSystem.swift in [the current list](Tests/Reports/catchup-final/round2/combined-source-files.txt).

Every intersection with `../MAIN-DIRTY-SOURCES.txt` is below. All seven **will conflict
with uncommitted work**; use focused hunks rather than replacing canonical files.

| File | Merge advice |
| --- | --- |
| `Sources/NextNotes/Agent/RealtimeAgent+ToolLoop.swift` | Carry the optional acceptance through handleLive, ACP local-once and both history consumers; keep canonical tool-loop changes and the standing-grant planner wording. |
| `Sources/NextNotes/Agent/RealtimeAgent.swift` | Merge optional acceptance into handle/control and AgentSession row/Codable/history APIs, keeping the canonical conversation/task changes and untrusted provenance in both history forms. |
| `Sources/NextNotes/Agent/Tasks/AgentTaskStore.swift` | `recoveredReadHistory` is a copied prerequisite already present identically in canonical source; deduplicate it and preserve canonical authority/recovery work. |
| `Sources/NextNotes/Agent/Tasks/TaskBridge.swift` | Thread optional acceptance through typed controls/routing and the existing work value without replacing newer canonical worker/authority logic. |
| `Sources/NextNotes/UI/Island/IslandState.swift` | Add the Catch-up kind, guarded ready notice, and ID-bound playback notice observation while preserving canonical live priority and state/ownership changes. |
| `Sources/NextNotes/UI/Island/IslandView.swift` | Add the Catch-up line/buttons switch cases using the helpers; preserve canonical layout and other live-card controls. |
| `Sources/NextNotes/UI/DesignSystem.swift` | Round 2 moves the unchanged briefingTitle expression into DS.Font; merge this single token into the canonical font block. |

The list is exhaustive for the combined branch against the supplied dirty-file list.
No canonical file was edited, built, staged, checked out or committed.

## Remaining contracts

Debug scripted/isolated checks establish neither real-model action accuracy nor
optimized latency, full acoustic echo-reference safety, device interruption latency,
physical UI interaction, capture continuity, owner-store migration or broader recovery.
The saved-file player's one-second wake suppression and synchronous pause remain
mitigations; file PCM remains outside the echo reference. Neither parent quality gates
nor model/default/readiness claims are promoted by this merge. The inherited audio
parent RESULT is preserved under the report; the UI parent has no tracked RESULT.md.
Relay broadcasts are delivery, not evidence every agent read or agreed.
