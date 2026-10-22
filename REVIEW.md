# Review: Catch-up screens, branch `claude2/catchup-ui2` (head e18b09a9, base c6d850c)

Reviewer: review-ui (read-only; nothing built or run). Subject files: `UI/CatchUp/*` (5 new), hooks in Island, Routines, Reminders, `AgentPaneSelfTest`. 57c51f69 ignored as instructed. I read the new files in full, the diffs of every existing file, and the producers they lean on (`IslandState.push/refresh`, `AgentScheduler` delivery, `ScheduleToolExecutor.create`, `CatchUpTemplate`, `ActivationController`, `AgentTaskManager.foldArtifacts`). I did not read `PERFORMANCE-STANDARDS.md` end to end; nothing here touches capture, ASR or models, but finding 3 is a voice/dictation-adjacent concern that deserves a look against it.

## Verdict: APPROVE WITH FIXES

The structure is right: no new store, entries derived from the existing task list, closing offer is plain text handed to an ordinary turn, copy is clean, no `scaleEffect`, no literal sizes or colours. But there are two correctness bugs I can show from source (1, 2) and one rule breach against AGENTS.md "one channel that starts audio" (3). Fix 1-4 before merge; 5-6 are copy/side-effect corrections that are cheap; the rest can follow.

---

## Findings (most serious first)

### 1. HIGH - "Getting the audio ready" and its animated orb never stop
`CatchUpLibrary.swift:149` `if next != entries { entries = next }`, `:198-212` (`scheduleExpiry`), `CatchUpViews.swift:51-53` and `:149-155`.

`isPreparingAudio(now:)` is a function of the clock (`CatchUpModel.swift:34`), but the only thing that makes SwiftUI re-read it is a change to an `@Observable` property. After 15 minutes `scheduleExpiry` calls `reload(announce:false, force:true)`, which rebuilds the same entries, finds `next == entries`, assigns nothing, and so invalidates nothing. A card whose audio never arrived (voice not set up, render failed: both are logged and silent, `CatchUpTemplate.swift:344-348`) keeps saying "Getting the audio ready" with a turning `composing` orb until something unrelated redraws the pane. That is exactly the "orb on a clock over work that is not running" the vocabulary section forbids, and it defeats the stated purpose of `audioWaitWindow`. The self-test cannot see it (it calls `isPreparingAudio` directly with a fresh `Date()`, `CatchUpPresentationSelfTest.swift:152-158`).

Fix: add `private(set) var clockRevision = 0` to the library, bump it in the expiry task, and read it in `CatchUpPaneSection.preparingID` and `CatchUpCard.statusLine`. Add a self-test case: inject `now`, advance past the window, assert the revision changed.

### 2. HIGH - The closing button says "yes" to a conversation that never heard the question
`CatchUpLibrary.swift:14-24` (`LiveCatchUpOfferActing`), `CatchUpModel.swift:186-190`.

`acceptOffer` sends "Yes, go ahead and send the reminders." as a typed turn. The catch-up was written by `ScheduledRunner`, which runs with "No conversation" (`ScheduledRunner.swift:7`), and it is delivered by `LiveScheduleDelivery` (`AgentScheduler.swift:1425-1436`), which posts a notification, `showAgentReply` and `speakSessionless`, and never calls `AgentSession.recordAssistant`. The only callers of `recordAssistant` are the realtime turn, `AgentTaskManager.announce/announceArtifacts` (`:2389, :2406`) and the local-once path. So by source the Agent's conversation has no antecedent for "the reminders" (and the fallback `yesText` quotes the question but not the catch-up it came from). The button then asks a model with no context to act on "the reminders", which invites an invented referent. The approval card still stops any send, so this is a quality failure, not a safety one, but it makes the one new action in this feature unreliable. I could not run it; I could not rule out that the planner pulls recent task results by some other route.

Fix at the producer: before `say`, record the catch-up into the session with the existing seam, `AgentSession.shared.recordAssistant(entry.text, contextKind: AgentSession.backgroundTaskContextKind)` (that tag is what keeps memory review and compaction from treating it as the Agent's own words). Put it inside `LiveCatchUpOfferActing.say` (give the seam the entry, not only the string) so the Recorder in the self-test can assert both calls happen, in order.

### 3. HIGH/MEDIUM - A second, ungated audio-start path
`CatchUpLibrary.swift:252-342` (`CatchUpPlayer`), `IslandState.swift` `playCatchUp`.

AGENTS.md: "one channel that starts audio ... Do not add an independent path that starts audio." `CatchUpPlayer` is a private `AVAudioPlayer` outside `OutputScheduler` / `RealtimeAudioSession`. I found no existing file-playback API to reuse (`LongFormRenderer` explicitly has none), so a player is needed; the problem is that it does not yield:
- `play()` (`:279-295`) starts immediately; the only yield check runs in the 250 ms tick (`:331`) and only reads `ActivationController.mode`. Pressing Play (or the island Play) while the Agent is listening starts audio into an open microphone, up to 250 ms, before the first pause.
- It never looks at dictation, a recording meeting (the system-audio tap will transcribe the briefing as "Others"), a call, or an `OutputScheduler`/`RealtimeAudioSession` reply in progress (those do not necessarily set `mode`). Two voices can overlap.
- It bypasses the playback reference the echo canceller uses (AGENTS "Echo suppression ... requires the real producer"), so the always-on wake-word monitor and the agent mic get the briefing with no reference. Unverified on a device; this is from source.
- From the island, Play gives the person no way to stop it: the card is cleared (`clearNotice()`) and the only Pause is in Agent -> Reminders.

Fix, smallest first: (a) check the same predicate in `play()` as in `tick()` and extend it with dictation active, meeting recording, and output speaking (read-only state reads, no await); refuse with one plain sentence ("I'll play it when you're done talking"). (b) Pause on dictation key-down / meeting start by extending the existing tick's check, not by adding hooks to the dictation path. (c) Let the island card turn into "Playing - Pause" after Play instead of vanishing. Do not route it through `OutputScheduler.enqueue` (that is text-to-speech); the owner should decide whether a file-playback entry on the existing audio owner is wanted. Flag this in the commit message as AGENTS requires ("when a task really needs a new layer, say why").

### 4. MEDIUM - The ready notice can hide a live card or an open question
`IslandState.swift:710` (`let next = notice?.kind ?? liveKind()`), `:912-915` (`push` overwrites unconditionally), new `announceCatchUpReady`.

A notice beats every live kind (listening, dictating, pending approval, recording) and replaces any earlier notice, including `meetingArmed` ("Record this meeting?") and `agentProposal`. `notesReady` has the same shape, but it follows a user-visible event; the catch-up ready fires at a random moment minutes after delivery. For 8 s it can replace the dictation card while someone is dictating, or the recording strip, and it draws with `demandsAttention` (the island expands with the bouncy animation, `IslandView.swift:30`). The canonical uncommitted work makes the dictation card the live readout ("is it hearing me") and opens it on words, so the collision gets worse after integration. Focus is not stolen (panel is `canBecomeKey == false`, `IslandPanel.swift:82`), so that part of the brief is satisfied.

Fix: in `announceCatchUpReady`, drop (do not queue, do not await) when `liveKind()` is anything but `.hidden`, or when `notice` is a `meetingArmed`/`agentProposal`/`callQuestion`. The Library card is still there and the text was already delivered, so a dropped ready card loses nothing. `onReady` must also stay out of any voice or dictation await: it does (synchronous `push`).

### 5. MEDIUM - "Made on your Mac" is a privacy claim the code does not back
`CatchUpSettingsSection.swift:65`.

The catch-up model is `.auto` (`CatchUpTemplate.swift:model`), and `auto` routes to OpenRouter when it is configured (`ScheduledRunner.swift:50-52`). The routine reads mail, calendar and notes. Where cloud is configured, that content goes to a cloud model (consent gating for the reads is separate and I did not trace it for this routine). The sentence should not say "on your Mac". Suggested: "Made from your calendar, notes and mail. I only read; anything I would send waits for your yes." If the owner wants a locality promise, derive it from the resolved reader rather than hard-coding it.

### 6. MEDIUM - Turning a switch on has two undisclosed effects, and the failure sentence can be false
`CatchUpSettingsSection.swift:105-115, 160`; `ScheduleTools.swift:156-170`.
- `create` runs a real test pass immediately (`scheduler.testRun`): reads the calendar, notes and mail and runs a model. The UI does say "The first one can take a minute", which is honest about time but not that it runs now (and that mail is read now).
- `create()` silently sets `settings.agentSchedulesEnabled = true` (`:106-108`). That is the master Reminders switch: every other routine the person has paused-by-master starts running. The section handles the reverse case with an explicit "Turn on" button (`:41-53`); the create path should do the same instead of flipping it. If the flip stays, the busy note must say it.
- If the test pass fails, the scheduler removes the new schedule and throws; the person sees "Nothing was changed" (`:160`) even though the master switch is now on. Either restore it on failure or reword.
- The error path gives no reason and no next click (AGENTS: "the reason and the exact next click"). A failed first run is most likely "no model/voice ready" or "mail not connected"; map `ScheduleError.invalid` messages to one plain sentence, or at least keep the scheduler's already-plain text.
- I could not check whether `scheduler.isEnabled` flips synchronously with `settings.agentSchedulesEnabled`; if not, `run` throws `notAvailable` on the first switch-on.

### 7. MEDIUM-LOW - Orb state for "audio being made"
`CatchUpViews.swift:151`. Vocabulary: `composing` = "the model is writing prose"; the prose is already written and delivered. Rendering speech is closest to `shaping` ("something being fetched and assembled out of nothing"), not `composing`. The table says to use the nearest row; `composing` is not the nearest. Switch to `.shaping` or have the owner decide explicitly and record it in AGENTS. Everything else is right: ready is a still `breathing` (`isAnimated: preparing && animatesOrb`), only the first preparing card animates, Reduce Motion is handled inside `ThinkingOrb` (`:44, :60`), the empty state orb is still, no `scaleEffect` (and the self-test scans for it, `:223`). Screen-level count: Reminders already has an animated `breathing` orb in `RoutinesView.emptyState` (`:318`, default `isAnimated`). That shows only with zero routines, in which case a catch-up card cannot normally be preparing, so I count it as one animating orb in practice; flag only because the author's own RESULT.md relies on that pane "already carrying one".

### 8. LOW - `DS.Font.briefingTitle` defined in a feature file
`CatchUpViews.swift:3-8`. AGENTS: "DesignSystem.swift defines every ... token; if a component needs one, add the token." Acceptable as a temporary because `DesignSystem.swift` has 493 changed lines in the canonical tree, but only on these terms: it is `.title3` serif (a system text style, so Dynamic Type works), used in exactly one place, and the integrator moves it into the `DS.Font` block as a separate follow-up commit once the canonical work lands (UX-11 may replace it with the theme's display font). Leaving it in a view file permanently is not acceptable. Other literal scan: no sizes, colours, fonts or durations outside `DS.*` in the five files, with these remaining non-token numbers that are policy rather than style: `15 * 60`, `18 * 60 * 60`, `visibleCount = 3`, `headlineLimit = 72`, `.milliseconds(250)` tick, and `ScheduleLocalTime(hour: 6, minute: 0)` at `CatchUpSettingsSection.swift:18` (duplicates `CatchUpTemplate.defaultTime = "06:00"`; parse that instead).

### 9. LOW - Empty card says "Set up catch-ups" when one is set up
`CatchUpViews.swift:67, 80-82`. `nextOne` reads `nextRunAt` over enabled catch-ups; a "when I'm back" trigger has no scheduled time, so with only that switch on the card says nothing is set up and shows the setup link. (I believe triggers leave `nextRunAt` nil; not verified.) Use "any enabled catch-up exists" for the button and `nextRunAt` only for the "first one will be ready" sentence.

### 10. LOW - Offer parsing: a non-offer becomes a "Yes, do that" button; "Not now" is permanent
`CatchUpModel.swift:188-190`, `CatchUpLibrary.swift:230-235`. "Anything else on your mind?" yields a prominent "Yes, do that" that sends 'Yes, please. You asked: "Anything else on your mind?"'. Without a parsed verb phrase show the question as text and no primary button (or one neutral "Reply" that opens the conversation without sending). "Not now" writes the id to the handled list forever and the question never returns, while the label promises "later". Reword to "No thanks", or do not persist it for the session. Safety on the approval path (the brief's point 4) is fine, see below.

### 11. LOW - Cost not measured
`CatchUpLibrary.swift:186-196, 116-152`. `track()` re-runs on every change to `AgentTaskManager.tasks` (many a minute while the Agent works, their own comment), each time filtering the whole task history on the main actor plus `ScheduleStore.shared.schedules` and a title `Set`. Cheap per call, but the history size is unbounded and AGENTS has no large-history latency proof. The `Look` equality guard saves the file work, not the O(n) scan. Also `IslandState.start` (`NextNotesApp.swift:630`) now constructs `AgentTaskManager.shared` (synchronous `store.load()` plus `holdInterruptedTasks()`, `AgentTaskManager.swift:109-124`) about 100 lines earlier than the existing first use (`:735`). I could not measure either; the integrator should confirm launch time on a large history. `refresh()` on every `onAppear` also opens `AVAudioFile` on the main thread for each not-yet-measured file (cached after the first).

### 12. LOW - Already-delivered text, delivered again
The scheduler already shows the text on the island (`showAgentReply`) and, when the person is present, speaks it (`AgentScheduler.swift:1425-1436`, `speak` rule `:841-856`). The ready card then arrives minutes later offering to play the same words. It is a convenience, but say so in the commit: for the weekday-morning catch-up it is a replay offer, not news. Not a defect.

### 13. LOW - Test coverage gaps
`CatchUpPresentationSelfTest` never exercises `LiveCatchUpOfferActing`, the island wiring (`start` is skipped under `SelfTest.isRunning`, `IslandState.swift:466-469`, so `onReady -> announceCatchUpReady -> push` has no test at all), or the expiry redraw (finding 1). The "nothing auto-plays" checks are text scans (`uses.count == 1`), which pass whether or not the call is reachable on a path nobody wrote yet. `--selftest-island` was not run and is not in the author's results; it very likely has a per-Kind table.

---

## Checks asked for in the brief

**1. Tokens.** Clean except finding 8. No literal colours, sizes or fonts in the new views; `DS.Space/Size/Radius/Color/Font/Motion` throughout. Every number outside `DS` is policy (listed in finding 8).

**2. Orbs.** One animating orb per card list (first preparing card only); idle `breathing` is still; Reduce Motion handled by `ThinkingOrb`; `isAnimated: false` on the empty card; no `scaleEffect`. Problems: finding 1 (animates past the end of the work) and finding 7 (state choice).

**3. Copy.** I read every string in the five files. No "routine", "podcast", "artifact", tool id or schema key. Plain and spoken: "Your catch-ups", "Getting the audio ready", "Ready to listen", "Read it", "Hide the words", "Show earlier ones", "Catch me up when I'm back", "Reminders are turned off, so no catch-ups will arrive." Corrections: finding 5 (false locality), 6 (reason and next step), 10 ("Not now"). Accessibility: Play/Pause and island Play have labels ("Play \(title)", "Play your catch-up"); the progress bar has a spoken value; the bullet glyph is hidden; the card is a `.contain` element with a header title. Missing: the island's "Later" and the card's "Not now" rely on their titles (fine); no hint/label on "Show earlier ones" beyond the title (fine); the island card is not keyboard-reachable, as for every island card (non-key panel), unchanged. Reduce Transparency is delegated to `GlassCard`; I did not open `GlassSurface` to confirm. `.accessibilityLabel` on the card container plus the title `Text` marked as header may announce the title twice.

**4. Closing offer, approval and "Not now".** Verified in code: the only effect of the button is `closeOffer` (a `UserDefaults` write plus a counter bump) then `offers.say(text)` -> `NavigationState.showConversation()` + `RealtimeAgent.shared.handleLive(text, source: .text)` (`CatchUpLibrary.swift:19-24, 239-243`). Nothing here sends, creates or fires a tool, and I found no other call to an executor, gate, scheduler or Workspace runner in the catch-up files. A send therefore waits for the normal approval card as AGENTS requires. "Not now" -> `closeOffer` only; `Recorder.said.isEmpty` is asserted. Caveats: (i) it is an ordinary turn, so read-only tools may run on their own, as for any typed message; (ii) "go ahead and" in the text is persuasion to a model, not an approval, and the gate does not read it; (iii) the offer text comes from a model that read other people's mail, so a hostile email can steer what the button says. The 44-character and "you/I/me" limits help, and the approval card is the guard; this is the reason finding 10 matters (do not make the label look more authoritative than the question). I could not run a turn to see what the planner does with the text (finding 2).

**5. Island ready card.** Fires once per catch-up per process (in-memory `withAudio`, seeded silently at launch; I found one narrow race: `refresh()` from the pane calls `reload(announce:false)` which folds new audio into `withAudio` without announcing, so a pane `onAppear` landing between the artifact commit and the observation hop would swallow the card; very narrow, unconfirmed). Never auto-plays: the only `play` call is the Play button (`IslandState.swift` single `CatchUpPlayer` use, asserted). Does not take focus (panel cannot become key). No await on a voice or dictation path: `announceCatchUpReady` is a synchronous `push`. It does not use the single audio channel (finding 3), and it can replace live cards (finding 4).

**6. Hunks in existing files.**

| File | Hunks | Additive/small? | Conflicts with uncommitted work? |
|---|---|---|---|
| `UI/Island/IslandState.swift` (+30/-1) | Kind case (3 lines); `name` switch (+1); `identity` (+1); `demandsAttention` (one existing line edited to add `.catchUpReady`); `orb` (+2); `title` (+1); `start` (+6, **inside `start(dictation:)`**, not `init` as RESULT.md says); `announceCatchUpReady` (+6); `playCatchUp` (+9) | Yes, apart from the one edited line | Yes (in `MAIN-DIRTY-SOURCES.txt`). Canonical hunks sit at `~122` (`dictating` case), `~224` (identity), `251-256` (`+5` after `.problem: true`), `~284` (orb `.dictating`), `~367` (title), `705+`. The author's `demandsAttention` edit is two lines from canonical's insert, so expect one textual conflict there; the others should apply. |
| `UI/Island/IslandView.swift` (+14) | Text case for the notice (+5, near line 433); buttons case (+9, near 547) | Yes | In the dirty list, but canonical hunks are at ~391-402 and ~597; no overlap, 30+ lines apart. |
| `UI/Settings/RemindersSection.swift` | `body` now emits `CatchUpSettingsSection()` then `remindersSection` (+7) | Yes | Not in the dirty list. |
| `UI/Agent/RoutinesView.swift` | `+CatchUpPaneSection()` (1 line) | Yes | Not in the dirty list. |
| `UI/Agent/AgentPaneSelfTest.swift` | 3 file names in the copy-scan list; `failures += CatchUpPresentationSelfTest.run()` | Yes | Not in the dirty list (it has no entry in the canonical diff I read). |
| `Agent/Tasks/AgentTaskStore.swift` | the 57c51f69 prerequisite | ignored | |

Integrator merge plan for the two conflicting files: do not cherry-pick whole commits 4d4583c8 onto the dirty tree. Once the canonical Island work is committed, rebase/cherry-pick 4d4583c8 on top and resolve by hand: the `demandsAttention` line becomes the union of the two lists (keep canonical's new `.dictating(...)` line and add `.catchUpReady` to the author's list). Apply the finding-4 guard in the same hunk. Re-run `--selftest-island` and `--selftest-commandkey` after the merge: the canonical `.dictating` case gained a fourth associated value and the island self-test may carry a Kind table; the author never ran it. Also check `takesClicks` (canonical): `catchUpReady` returns true, which is what its buttons need.

**7. What I could not verify from source.**
- Anything visual: glass, button fills, the round Play button, the island card, serif title rendering, light/dark and Reduce Transparency fallbacks. The author could not either.
- That `GlassCard` draws a solid fallback under Reduce Transparency (I did not open it).
- Real audio: whether the player pauses in time, overlaps a spoken reply, leaks into the mic or the wake word monitor, or interferes with a recording meeting.
- What the planner does with "Yes, go ahead and ..." and whether the model finds the catch-up some other way (finding 2).
- Whether `scheduler.isEnabled` follows the master switch synchronously (finding 6).
- Whether a `.trigger` schedule has `nextRunAt` (finding 9).
- That `foldArtifacts` after the render reliably reaches `track()` before another reload (the race in check 5).
- Launch cost and per-change cost on a large history (finding 11).
- VoiceOver output and keyboard order on the new controls; `--selftest-island`; `--selftest-onboarding`; `--selftest-settings` exits 139 after its OK marker in the author's runs (the author says it is inherited; I did not check).
- Whether the audio file is guaranteed to be an `.m4a`/`.wav` that `AVAudioPlayer` opens (the allow-list in `audioFile(of:)` assumes it).

---

## Concrete fix list for the author
1. Add a clock revision bumped by `scheduleExpiry`, read by the card and the pane; add the self-test case (finding 1).
2. Record the catch-up into `AgentSession` with `backgroundTaskContextKind` before the "yes" turn; give `CatchUpOfferActing.say` the entry; assert order in the Recorder (finding 2).
3. Make `CatchUpPlayer.play()` and `tick()` share one predicate that also covers dictation, a recording meeting and output speaking; give the island card a Pause after Play; decide with the owner whether a file-playback entry on the audio owner is wanted (finding 3).
4. Guard `announceCatchUpReady` against live cards and unanswered notices (finding 4).
5. Fix the footer sentence; show "Turn on" instead of silently flipping the master switch, or disclose it; reword the failure sentence (findings 5, 6).
6. Switch the preparing orb to `.shaping` or get a recorded decision (finding 7).
7. Move `briefingTitle` into `DS.Font` at integration, as its own commit (finding 8).
8. Findings 9-13 as follow-ups.
