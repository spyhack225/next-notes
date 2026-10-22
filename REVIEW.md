# Combined Catch-up review

Verdict: **APPROVE WITH FIXES**.

Reviewed `233b5dd8`, its merge `eaafc732`, both parents (`63a7e471` audio and `c0d37462` UI), and base `c6d850c`. The merge preserves both parents' intended changes. The permission footer is accurate about existing grants. The retained checks support the reported bounded results. Audio ownership remains unresolved, Apple's built-in voice is reachable, and the playback notice can hide a live card that starts later. These prevent an unconditional approval of the feature.

Read BRIEF.md, ../RULES-2.md, both predecessor REVIEW.md files, ../catchup-final/RESULT.md, committed RESULT.md and report README, relevant source and retained evidence. This reviewer folder has no AGENTS.md; I read the subject branch's rules, including the optimization, producer-fix, existing-owner and design sections. The exact heading “Reuse, integrate and clean up” is absent there. No build, self-test, app, model or GUI was started. No owner store was read. Only this review was written; relay notices are explicitly requested coordination.

## Findings

1. **P1 — Saved-file playback still starts outside the shared audio owner.** `Sources/NextNotes/UI/CatchUp/CatchUpLibrary.swift:332`, `:362`, `:385`.

   CatchUpPlayer constructs AVAudioPlayer and calls play directly, without an OutputScheduler token or the shared output/reference path. Library and island share this player, but sharing one file player does not make it the app's one audio channel. This was introduced by the UI parent and survives the merge; it is not a conflict-resolution loss. The admission checks, synchronous activity observation, speech preemption and wake-detection suppression improve the earlier failures. File PCM still supplies no echo reference, and the one-second suppression tail has no physical acoustic proof. AGENTS.md:1152–1160 forbids an independent audio-start path; OutputScheduler does exist in this revision under Agent/Duplex, despite the older rules paragraph describing it as planned.

   Integrate file playback through the existing audio owner with admission, interruption and reference ownership, or leave saved-file playback explicitly unaccepted until that work lands. Do not describe the current mitigations as satisfying the one-channel rule or acoustic safety. This remains the unresolved part of audio finding 2 and UI finding 3.

2. **P1 — Catch-up can reach Apple's banned built-in voice.** `Sources/NextNotes/Agent/Schedules/AgentScheduler.swift:1432`, `Sources/NextNotes/Agent/Duplex/OutputScheduler.swift:184`, `Sources/NextNotes/Agent/Speech/AgentSpeechSynthesizer.swift:329`, `:646`.

   A spoken scheduled catch-up enters speakSessionless, the ordinary audio session and speech synthesizer. prepareForStream selects systemBacking for the default engine and for Pocket when it is not ready. Pocket/Kokoro failures can also select systemBacking in fallbackCurrentClause. systemBacking is AVSpeechBacking, which uses AVSpeechSynthesizer. An ordinary reply after accepting a catch-up has the same reachable fallback. Thus this head does not meet the owner's app-wide ban. This is inherited shared speech behavior, not a new Apple renderer in the merge: LongFormRenderer's saved-file synthesis uses Pocket/Kokoro or refuses, with no Apple offline fallback.

   The no-apple branch is to be integrated separately. Treat that integration and verification of these scheduled/accepted-reply routes as a release dependency; this review does not claim it has already happened.

3. **P2 — A retained Catch-up notice can cover a live state that begins afterward.** `Sources/NextNotes/UI/Island/IslandState.swift:642`, `:652`, `:743`; `RESULT.md:28`.

   announceCatchUpReady correctly refuses an existing notice or non-hidden live state. After Play, however, toggleCatchUp pushes the notice with an infinite lifetime. Pausing preserves playingID, and followCatchUpPlayback watches only that ID. refresh always chooses notice before liveKind. If dictation or meeting recording begins after Play, the audio pauses but the paused Catch-up notice can remain above the live recording/readout indefinitely. Voice projections also retain this notice; applyVoiceProjection only retires an old agentReply notice on a new session. The finite ready notice has the same ordering issue for its remaining lifetime. Some legacy showAgentListening/showAgentWork calls clear notices, but they do not establish priority for all live producers.

   Give live states priority over this convenience notice through the existing island state producer, or retire the Catch-up notice when a live state begins. Preserve paused playback identity separately from which card is visible. Add the reverse-order case: show Catch-up first, then publish live activity. The existing presentation check covers live-first admission only. RESULT.md's “Live cards retain priority” is too broad until this is repaired. UI finding 4 is fixed at arrival, but not throughout the notice's lifetime.

4. **P3 — The title font token is still defined in the feature view.** `Sources/NextNotes/UI/CatchUp/CatchUpViews.swift:3`.

   DS.Font.briefingTitle is a system text-style serif font, used through DS, but its definition still sits in CatchUpViews rather than DesignSystem.swift. This is the explicitly deferred UI finding 8. Move it into the shared font block when integrating the canonical design work, preserving the intended style or its approved replacement. Other inspected Catch-up view styling uses DS tokens; no added red status or literal colour/size breach was found.

## Parent retention and prior findings

The conflict resolution is sound. CatchUpViews:333 retains hasVerbPhrase and library.acceptOffer(entry); :338 retains Reply opening the conversation without submitting a yes; :341 retains No thanks and its closing hint; :336 and :345 retain the audio parent's shared standing-permission explanation. No parent feature was silently discarded in that row.

The merge differs from the audio parent in exactly five source files: presentation tests, Settings, CatchUpViews, IslandState and IslandView. Those differences carry the UI fixes and the additional footer assertion. Audio acceptance, wake/speech mitigation, permission and provenance producers/tests are unchanged from the audio head. Against the UI parent, the source changes carry those audio repairs plus the combined offer/permission wording. Island files, Routines, Reminders and AgentPaneSelfTest retain the UI parent's contents. The evidence commit changes no Sources files. I found no silent loss in non-conflicted source files.

| Earlier finding | Status at the merge |
| --- | --- |
| Audio 1: clipped/compacted antecedent | Repaired within the declared bounded contract. CatchUpAcceptance keeps the closing offer, whole selected supporting sentences and an omission notice. It travels on the accepting row and typed work, and both history consumers reserve room for it. Small-reader, actual compaction, asynchronous handleLive/typedWorker/localOnce checks remain. Omitted details and real-model action accuracy remain unproved. |
| Audio 2: wake/interruption | New didSpot suppression, synchronous observed activity pause and actual speak/enqueue/resume preemption remain. Scripted callback/backing checks pass in retained logs. Shared audio/reference ownership and physical timing remain open (finding 1 above). |
| Audio 3: universal fresh approval claim | Shared copy and planner rule now acknowledge standing grants. The production-policy covering-grant check retains effects=1, new_card=false. The no-grant approval fixture still retains refused/denied zero effects and approved one effect. |
| Audio 4: quoted mail provenance | Both history forms label tagged background rows as untrusted; the acceptance reference is also labelled. Malicious quoted mail reaches actual planner assembly under a scripted provider. Real-model resistance to injection is not established or claimed. |
| UI 1: never-ending preparing label/orb | CatchUpClock supplies explicit timeline dates and one common now to cards. Preparing ends at the window even if entries are unchanged. Source/value checks and expired-card preview remain; physical redraw was not observed here. |
| UI 2: yes without context | Context is recorded before opening/submitting; bound acceptance repairs the later budget/compaction gap as above. |
| UI 3: ungated player, missing island Pause | Admission and interruption mitigations retained. Shared Play/Pause/Resume controls and ID-bound notice retained. One-channel breach remains (finding 1). |
| UI 4: ready notice hides existing live/question card | Arrival guard and live-first/armed-question checks retained. Later-live ordering remains (finding 3). |
| UI 5: false “on your Mac” footer | Removed from Settings. The template's old restatement still contains that claim, but the searched source callers are self-tests only; no production use was found. Cloud routing remains possible, so no global locality promise is established. |
| UI 6: master-switch side effects/error copy | Explicit “Turn on Reminders and set it up” explains other reminders; create no longer flips the master switch. Busy text discloses immediate reads; failure gives retry/Models guidance. The master switch remains on after explicit approval even if creating the catch-up fails; current copy says the catch-up was left off, not that nothing changed. |
| UI 7: preparing orb vocabulary | .shaping retained. |
| UI 8: title token location | Still deferred (finding 4). Default time now reads CatchUpTemplate.defaultTime. |
| UI 9: returned-trigger empty state | isSetUp uses enabled Catch-up existence separately from nextRunAt. |
| UI 10: non-offer Yes/permanent “Not now” | Reply submits nothing; No thanks accurately closes the persisted offer. |
| UI 11: launch/large-history cost | Still unmeasured. Task scanning and first file duration reads remain on MainActor. No speed claim is supported. |
| UI 12: duplicate delivery | Still a replay convenience, not new content; no extra automatic file playback found. |
| UI 13: coverage gaps | Island/commandkey were run in retained final evidence; clock/admission/control and handoff checks added. Physical island controls, materials, expiry redraw and full production task admission remain unverified. |

No new sequential await was added to capture/dictation/voice input by these repairs. Accepted offers reuse the normal turn, TaskBridge/work and AgentSession; no second task/context store was added. Wake microphone capture is not stopped by the new detection guard. Plain consumer copy, still empty-state orbs, one animated preparing card in the list and Reduce Motion handling remain. A full physical screen with every concurrent state was not inspected.

## Permission footer and evidence honesty

Settings says “Catch-ups only read” and then qualifies accepted suggestions with “I'll ask before making changes unless you've already allowed that action.” The routine ceiling is get_agenda/search_knowledge/search_email. Acceptance starts a normal requested turn, not a new permission grant. A send without a covering grant requires normal approval; PermissionBroker:51 checks covering grants before making a card. Consequently the new footer is more accurate than an unconditional promise of a fresh yes. It makes no promise that every account read ignores existing access/consent settings.

Retained exits/heavy log show one build exit 0 and **eight of nine requested flags exit 0**. Settings prints SETTINGS_OK and then the wrapper records signal 11 / exit 139. The build log says 266.91 seconds. The wrapper's zero exit deliberately tolerates this documented Settings failure; it is not a ninth clean pass. Earlier UI RESULT also reports the same exit behavior, but I did not independently validate its claimed unrelated binaries or diagnose the crash.

I independently compared all 23 committed source bytes against tested-sources.sha256: all match. No source changed between eaafc732 and 233b5dd8. The 18 browser WRONG lines plus TOOLLOOP_PRODUCTION_FAILED match the audio parent's backing-store-isolation log byte for byte; the two duplex divergence lines match its backing-duplex log. Their respective SHA-256 values are `64b2868ac87151e4197a1da5cecdbafc2a02c68e171b1e6880d1069990930716` and `9ab3baa9baa277b4879609463bab91fd0f5a43f6343d87b4723e90c4c6e12898`. They remain failures/diagnostics despite the root isolation/duplex exits. The caught task-persistence diagnostic in catch-up.log is also retained; no owner migration or general persistence success follows from CATCH_UP_OK.

I viewed all four retained PNGs and verified their local blobs match the committed images. Dimensions and visible text agree with RESULT: readable narrow/wide stacks, expired words-only card, Reply/No thanks question, corrected two-line Settings footer. Wide is a stack preview, not adaptive-grid evidence. Play's glyph, glass and prominent fills are absent from these offscreen renders. They do not prove sound, live button contrast or playback states. Apart from the live-priority sentence in finding 3, RESULT and README accurately limit their claims.

No secret or raw owner mail/calendar/meeting payload was found in the inspected newly committed Catch-up reports, logs, fixtures or images. The content is authored fixtures; local username, build paths, process IDs and machine metadata are retained. Targeted common credential/email scans found no matching real-account addresses or credentials. This is a bounded inspection, not a certificate covering arbitrary binary metadata, every historical repository report or the owner's stores.

## Could not verify

No native checks were rerun, and removed binaries cannot be independently tied to execution here beyond the retained hashes/logs. Physical audio, echo behavior, device changes, wake tail timing, capture continuity, real-model action/injection behavior, full task admission/recovery, owner-store migration, large-history latency, glass/contrast/accessibility/keyboard behavior and onscreen adaptive layout remain unverified. The separately planned no-apple integration and canonical dirty-source integration are outside this head. Findings 1–3 need resolution or explicit bounded integration treatment before claiming the feature satisfies the owner contracts; finding 4 remains the small agreed design follow-up.
