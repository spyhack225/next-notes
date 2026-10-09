# Catch-up round 2

This round reads BRIEF-ROUND2.md, ../RULES-2.md and the APPROVE WITH FIXES review.
All work stays in claude2/catchup-final. No install, push, merge into main, GUI opening,
owner-store seeding or foreign-process cleanup is authorized or performed.

## Producer and original reproduction

IslandState.refresh selected notice?.kind before liveKind, so a correct new voice
projection or pending approval was hidden by the earlier Catch-up notice. This is a
card-selection producer bug; the views were faithfully drawing its incorrect choice.

The new presentation fixture invokes actual announceCatchUpReady, applyVoiceProjection
and refresh/pendingSource with authored input. Ten reverse-order assertions cover ready
arrival, later listening/speaking/thinking, restoration after voice ends, and a later
approval. Original IslandState/player/font producers are byte-identical to 233b5dd8;
original-producer-invariance.json pins them. Only the presentation fixture was added.
The actual debug build succeeds (282.23s); Agent-panes exits 1 with four failures:
CATCH_UP_LATER_LIVE_FAILED and AGENT_PANES_FAILED: 4 problem(s).
All four failures are the later-live selection assertions; no existing assertion reports
failure. Raw output, exact source diff/hashes, binary hash/UUID and native PID are in red.

The fixed selector consults liveKind only for a Catch-up notice and selects it whenever
it is non-hidden. Other notice precedence remains unchanged. Notice retention/expiry
and playingID are separate; the existing playback-ID observer still reads notice.kind
while a live card is visible, so it can retire a held notice when that ID is released.
No player, microphone, scheduler, task or speech-synthesizer logic changes in this repair.
No store, queue, model pass, await, save or timer is added.

The actual reverse-order fixture uses finite ready notices; the indefinite Play notice
uses this same refresh selector irrespective of expiry. No physical Play/card interaction,
dictation capture or recording session is injected by this focused fixture. Related
Catch-up admission and pause/identity/preemption checks run in the final batch; they
are scripted backing evidence, not physical acoustic or live recording-display proof.

## Font and saved-file audio decision

The briefingTitle definition moves from CatchUpViews.swift into DS.Font in
DesignSystem.swift. font-move.txt verifies the exact unchanged expression,
SwiftUI.Font.system(.title3, design: .serif), and removal of the feature definition.

Saved-file playback is **not accepted for the one-channel rule**. This follows the
brief's permitted exact-gap/design route. See [AUDIO-GAP.md](AUDIO-GAP.md) and its
seven pinned source files for the text-only admission/session contracts, probe-only
WAV adapter, singleton renderer/reference callback ownership and missing rendered
file-position contract. No new independent path or token wrapper was introduced.
Existing AVAudioPlayer playback, one-second wake suppression and synchronous activity
pause remain mitigations. Their checks do not establish shared ownership, a rendered
reference, full-duplex acoustic safety or physical interruption timing. This requires
an owner decision and producer integration; the separate no-apple branch is also a
release dependency and is not changed here.

## Final native batch

The unchanged fixture passes with CATCH_UP_LATER_LIVE_OK and Agent-panes exit 0:
original four later-live failures become zero. Related CATCH_UP_PLAYBACK_OK retains all
45 actual start/admission/tick/resume checks with scripted file backing and paused ID;
CATCH_UP_WAKE_OK retains synchronous observed activity and real speech-call preemption.
Neither marker supplies the missing shared renderer/reference ownership.

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

Settings is not a clean process pass: it emits its OK and then exits 139 (SIGSEGV),
matching the prior combined batch. This round does not diagnose or repair that crash.
The final wrapper exits 1 honestly; all nine flags still ran. Store isolation's root
reports 21 files/0 defaults unchanged, while its nested browser loop reports 18 WRONG
lines and TOOLLOOP_PRODUCTION_FAILED. The two duplex turnPending divergence lines also
remain. inherited-diagnostics.json confirms exact line equality to the prior combined
logs. Catch-up retains TASK_PERSISTENCE_DIAGNOSTIC about a refused history save; its OK
is not general task-persistence proof. No introduced failure was found in these checks.

The final fixed candidate is the tested 233b5dd8 plus green/tested-source.diff; source
commits 4275c5b5 and fa3f0152 preserve exactly those source bytes. All 24 source hashes
match after testing and at cleanup. The same regression fixture hash matches both
native builds. Binary hash/UUID, final ad-hoc signature, macOS/power/thermal output,
PID/arguments/exits and raw stdout/stderr/separate diagnostics are retained. The final
build takes 137.96s; the original takes 282.23s. These debug development observations
are not product latency measurements or a speedup comparison. Models/backings are
scripted for the relevant contracts; no real-model or physical acoustic verdict follows.
Both heavy slots obey the shared FIFO/gates/claims; final verification uses one slot
for all nine flags, preceded by the required original RED slot.

cleanup.json retains removal of 27 completed-PID/creation-time-bound fixture folders,
two explicit run roots and the own scratch directory. Native logs and pins were copied
before cleanup; binaries are not retained. No foreign scratch/process, shared dependency
cache, installed app or canonical checkout was cleaned or modified.

Round 2 changes four source files: IslandState.swift, CatchUpPresentationSelfTest.swift,
CatchUpViews.swift and DesignSystem.swift, plus RESULT.md, PERFORMANCE-STANDARDS.md and
these reports. main-dirty-overlap.txt lists the seven full-branch canonical dirty-file
conflicts; IslandState.swift and DesignSystem.swift are the two round-2 overlaps. They
**will conflict with uncommitted work**; merge focused hunks while preserving other agents.

Physical Play/Pause/island controls, actual microphone/meeting display transitions,
rendered echo reference, echo tail/device timing, capture continuity, real-model action
and injection quality, owner-store migration, release performance and broader recovery
remain unverified. No quality gate, model/default, phase or release readiness is promoted.
Saved-file audio remains explicitly unaccepted, and no-apple integration remains separate.
Relay delivery does not establish that every recipient read the handoff.
