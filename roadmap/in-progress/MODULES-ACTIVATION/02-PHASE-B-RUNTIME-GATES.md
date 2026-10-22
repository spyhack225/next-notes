# MODULES-ACTIVATION Phase B — runtime gates (MOD-04 … MOD-07)

Parallel once MOD-01 lands. Each task owns disjoint files. No task strands
in-flight work: a meeting recording, a download, or an approval outlives the
toggle that was flipped mid-flight.

---

## MOD-04 — Dictation runtime gate (hotkey, HUD, island)

**Blocked on:** MOD-01. **Effort:** 2–3 h.

**Why.** The push-to-talk key must do nothing harmful when Dictation is off —
and say what to do next instead of sitting silent.

**What lands:**
* `Core/DictationController.swift` (`beginDictation`) — early return when
  `moduleDictationEnabled == false`. No state change, no engine start, no
  `RunLog.record` (self-test rule: the seam stays `{ _ in }`).
* HUD + island dictation card: "Dictation is off." + "Turn on" button
  (`selectedSettingsTab = .modules`). No orb animation for work not running
  (design-system rule).
* `GeneralSettingsTab` (PTT key row): keeps the key preference; adds the same
  sentence under it when off. Preference is kept so re-enabling just works.

**Files you will change:**
- `Sources/NextNotes/Core/DictationController.swift`
- `Sources/NextNotes/UI/Dictation/*` (HUD row), `Sources/NextNotes/UI/Island/*`
  (dictation card), `Sources/NextNotes/UI/Settings/GeneralSettingsTab.swift`

**Do not:** delete the key binding, change `withBoundedWait` deadlines, change
`session` guards.

**Verify.**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --via-open --selftest-dictation 2>&1 | tail -3
```

**Done when:**
- [ ] key press while off = one plain sentence, no recording, no history row;
- [ ] `DICTATION_OK` when on; `STATUS.md` MOD-04 updated.

---

## MOD-05 — Meetings runtime gate (scheduler, call detector, no strand)

**Blocked on:** MOD-01. **Effort:** 3–4 h.

**Why.** An armed meeting must never start recording for a module the user
turned off — but a recording already running must finish (deleting it
mid-flight is the data-loss failure this feature can least afford).

**What lands:**
* `Meetings/MeetingScheduler.swift` tick — first line: `guard
  moduleMeetingsEnabled else { return }`. Armed rows stay armed, never start.
  `missedReason` never writes "another meeting was being recorded" for a
  meeting suppressed by the toggle (same honesty rule as M-11's own-session
  exemption).
* `Meetings/CallPolicy.swift` + detector subscription — no call question, no
  auto-record while off. Thresholds (`onThreshold`/`offThreshold`) unchanged.
* `Meetings/MeetingSession.swift` + `MeetingPipeline` — a session already
  `.recording`/`.transcribing`/`.diarizing`/`.summarizing` runs to `.done`
  even if the toggle flips mid-meeting. `releaseAudioWhenDue` unchanged.
* Island + menu-bar Record item hidden while off.

**Files you will change:**
- `Sources/NextNotes/Meetings/MeetingScheduler.swift`
- `Sources/NextNotes/Meetings/CallPolicy.swift` (gate only, no threshold change)
- `Sources/NextNotes/Meetings/MeetingSession.swift`
- `Sources/NextNotes/UI/Island/*`, menu-bar item

**Read for context:** `Meetings/MeetingStore.swift` (`resumeAction` table),
AGENT-OVERHAUL P4-01 if live (owns the "Now" block in the scheduler —
coordinate, do not fork).

**Do not:** change the overrun grace, the 72 h audio window (M-10), or repair.

**Verify.**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-calls 2>&1 | tail -3
Scripts/run-selftest.sh --selftest-meeting-resume 2>&1 | tail -3
```

**Done when:**
- [ ] scheduler never starts while off; in-flight meeting still reaches done;
- [ ] both self-tests green; `STATUS.md` MOD-05 updated.

---

## MOD-06 — Assistant runtime gate (empty states, wake, routines pause)

**Blocked on:** MOD-01. **Effort:** 2–3 h.

**Why.** The Assistant already has a master switch; this wires the surfaces
around it so "off" reads as a stage, not as breakage.

**What lands:**
* `UI/Agent/AgentView.swift` — off state uses `OrbUnavailableView`
  (`breathing`, cause = not-on, not mood) with "Turn on in Modules."
* `Agent/AgentService.swift:143` — `isReady` unchanged
  (`agentEnabled && gwsSignedIn`); no second gate beside it.
* Wake word (`Activation/WakeWord/WakeWordAudioMonitor.sync`) + live-meeting
  agent (`agentLiveDuringMeeting`) forced idle while off (existing `sync()`
  pattern, no new monitor).
* Routines/schedules: off pauses delivery with reason ("Assistant is off"),
  keeps registrations. Nothing unregisters from macOS silently — re-enabling
  resumes.
* Tool-approval cards outstanding while the toggle flips: they stay answerable
  (a question asked must stay answerable).

**Files you will change:**
- `Sources/NextNotes/UI/Agent/AgentView.swift`
- `Sources/NextNotes/Activation/WakeWord/WakeWordAudioMonitor.swift` (gate only)
- Routines/schedule pause point (the file that owns delivery, not a new one)

**Do not:** change `AgentRisk` grading, auto-run-reads default, or the
proposal store (`proposals.json`).

**Verify.**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-toolloop-live --quick 2>&1 | tail -3
```

**Done when:**
- [ ] off = plain empty state + paused routines, no orphaned approvals;
- [ ] quick eval green when on; `STATUS.md` MOD-06 updated.

---

## MOD-07 — Knowledge index per-module forcing

**Blocked on:** MOD-01. **Effort:** 1–2 h.

**Why.** The index is on by default and must not file content from a module
the user turned off.

**What lands:**
* Forced (not stored): `knowledgeIncludeDictation` reads `false` when
  dictation off; `knowledgeIncludeConversations` reads `false` when agent off.
  Switches keep their stored values so re-enabling restores them.
* Search row visibility follows MOD-02. Graph/overlay code untouched
  (memories draw at view time; no row is written or deleted by this task).

**Files you will change:**
- The file that owns `KnowledgeIndexSettings.fromDefaults` + the two readers
  (`Knowledge/*`, `Support/Settings.swift` — grep `knowledgeInclude`).

**Do not:** change the graph ontology, chunker, embedder choice, or
`deleteAll()` semantics.

**Verify.**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-index 2>&1 | tail -3
Scripts/run-selftest.sh --selftest-search 2>&1 | tail -3
```

**Done when:**
- [ ] index never ingests from a disabled module; stored switches preserved;
- [ ] both self-tests green; `STATUS.md` MOD-07 updated.
