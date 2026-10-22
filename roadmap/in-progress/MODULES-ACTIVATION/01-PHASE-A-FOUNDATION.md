# MODULES-ACTIVATION Phase A — foundation (MOD-01 … MOD-03)

Read `00-README.md` first. Paths are relative to `Sources/NextNotes/` unless
they start with a repo-root folder. Line numbers drift — **grep the symbol**
and trust that over the number.

---

## MOD-01 — Module source of truth: two keys + pure `ModulePolicy`

**Blocked on:** nothing. **Effort:** 2–3 h. **Unblocks:** everything.

**Why.** Dictation and Meetings have no master switch; only the Assistant does
(`Settings.swift:789 agentEnabled`). Every later task reads the decision from
one place so two switches can never disagree.

**What lands:** two new `Settings` keys + one pure policy with no store.

* `Support/Settings.swift` — add `moduleDictationEnabled` (default `true`)
  and `moduleMeetingsEnabled` (default `true`), same shape as `agentEnabled`
  (`didSet` writes `Keys.*`). Reuse `agentEnabled` for the Assistant; add no
  third key for it. Absent key = default (existing users unchanged).
* New file `Support/ModulePolicy.swift` — pure, no `Settings.shared` import:
  `enum AppModule { dictation, meetings, assistant }`,
  `isEnabled(_:dictation:meetings:assistant:) -> Bool`,
  `visibleSections(for:)`, `onboardingSteps(for:)` sketch (MOD-08 refines),
  `firstEnabledSection(...)` fallback order
  `dictation > meetings > agent > dictionary`.
* `Support/Settings.swift` gets one convenience reader
  `isModuleEnabled(_:) -> Bool` used by production; tests drive the pure type.

**Files you will change:**
- `Sources/NextNotes/Support/Settings.swift` — two keys + reader (`Keys`
  struct @ ~:1173, init defaults @ ~:1329).
- `Sources/NextNotes/Support/ModulePolicy.swift` — new, pure.

**Read for context (do not change):** `Support/NavigationState.swift:15`
(`SidebarSection`), `UI/Sidebar.swift:105` (`visibleSections`),
`Agent/AgentService.swift:143` (`isReady`).

**Steps.**
1. Add the keys, defaults, and `Keys.*` strings. No UI yet.
2. Add the pure policy with the fallback order above.
3. Add cases to `--selftest-settings` catalog? No — MOD-10 owns the new flag.
   This task is verified by `make test` + a throwaway driver, not a new flag.

**Do not:** add UI, touch onboarding, add a second store, rename `agentEnabled`,
change any default for existing users.

**Verify.**
```bash
make build && make install OPEN=0
make test
Scripts/run-selftest.sh --selftest-settings 2>&1 | tail -3
```

**Done when:**
- [x] two keys persist and read back; absent = `true`/`true`;
- [x] pure policy has a unit-style driver (self-test in MOD-10 reuses it);
- [x] `STATUS.md` MOD-01 row updated.

---

Implementation evidence: `450dbaa`; [MOD-01 report](../../../Tests/Reports/modules/2026-09-30-mod01-foundation.md). All eight combinations and actual persistence reader pass; integrated Settings/UI strings and 30 correction tests pass. Later navigation and runtime tasks remain open.

## MOD-02 — Sidebar filtering + `NavigationState` fallback

**Blocked on:** MOD-01. **Effort:** 2 h.

**Why.** A module that is off must have no row, and quitting while looking at a
row that later disappears must not reopen to an empty detail.

**What lands:**

* `UI/Sidebar.swift:105` — `visibleSections` also filters:
  `dictation iff moduleDictationEnabled`, `meetings iff moduleMeetingsEnabled`,
  `agent/graph/portrait/ideas/goals/reminders/skills iff agentEnabled`,
  `search iff knowledgeIndexEnabled && (meetings || agent)`,
  `dictionary` always. Keep `comparison`/`settings` exclusions as-is.
* `Support/NavigationState.swift` — init migration + `show(_:)` redirect: if
  the restored/requested section belongs to a disabled module, land on
  `ModulePolicy.firstEnabledSection(...)`. Persist the landing, not the ask.
* `UI/MainWindow.swift:54` — detail `switch` never instantiates a disabled
  module's view (so `MeetingsView`/`AgentView` side effects don't run).
* Live row (`Sidebar.swift:76`): dictation-off hides `listening`, meetings-off
  hides `weaving`.

Open product call (kept, not decided here): `Reminders` hides with the
Assistant. If the owner wants it standalone, it is one line in
`visibleSections` + a MOD-10 case.

**Files you will change:**
- `Sources/NextNotes/UI/Sidebar.swift`
- `Sources/NextNotes/Support/NavigationState.swift`
- `Sources/NextNotes/UI/MainWindow.swift`

**Do not:** change detail views themselves, change persistence keys, hide
`dictionary` or `settings`.

**Verify.**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-settings 2>&1 | tail -3
# by eye: turn off Meetings in Settings (MOD-03) or via defaults, relaunch, row gone
```

**Done when:**
- [ ] disabled module has no row; live row follows the same rule;
- [ ] relaunch into a disabled section lands on the first enabled one;
- [ ] `STATUS.md` MOD-02 row updated.

---

## MOD-03 — Modules Settings tab + per-tab disabled banners

**Blocked on:** MOD-01. **Effort:** 3–4 h. **Owner of shared files:** this task
owns the Modules tab; SB-06 owns independent-role/shared-file copy in the Models tab.

**Why.** One screen that says what is on, what it costs in disk, and where to
finish setup — in words a non-engineer would say out loud.

**What lands:**

* `UI/Settings/SettingsWindow.swift:93` — new first case `modules`
  ("Modules", heading "What Next Notes does", orb `.breathing`, icon
  `squareshape.split.2x2`). Add to `allCases` order + `requiredPanes`.
* New `UI/Settings/ModulesSettingsTab.swift` — 3 cards (Dictation / Meetings /
  Assistant). Each: toggle, one-line benefit, storage line ("Already on this Mac" / missing download size from the catalog
  and verified library, counted once across shared consumers; before that seam
  lands use generic setup copy rather than a made-up fixed size), "What's included" expander (model rows reuse `ModelStatusRow`),
  "Set up" deep link to the module's tab. Disable asks once about deleting
  exclusive unused files (Keep / Delete); shared files stay and say which enabled
  features need them. Pending work/leases/fallbacks also retain their files. Derive
  consumers from existing settings/library/work; enable never auto-downloads.
* Banners (no removal): `DictationSettingsTab`, `FormattingSettingsTab` dim
  when dictation off; `MeetingsSettingsTab`, `CalendarSettingsTab` when
  meetings off; `AgentSettingsTab`, `WorkspaceSettingsTab`,
  `ComputerBrowserReadiness`, `IntegrationsSettingsTab` when agent off. One
  shared `ModuleDisabledBanner(module:)` view, copy:
  "Dictation is off. Turn it on in Modules." + button that sets
  `selectedSettingsTab = .modules`.
* `WorkspaceSettingsTab.swift:134` toggle stays bound to `agentEnabled` (same
  bit, two doors).

**Files you will change:**
- `Sources/NextNotes/UI/Settings/SettingsWindow.swift`
- `Sources/NextNotes/UI/Settings/ModulesSettingsTab.swift` — new
- `Sources/NextNotes/UI/Settings/*SettingsTab.swift` — banner lines only

**Read for context:** `UI/Settings/SettingsChrome.swift` (`SettingsPane`
floor), `UI/Settings/ModelsSettingsTab.swift:256` (rows to reuse).

**Do not:** regroup the Models tab (MOD-09), change download code, name model
files in headlines.

**Verify.**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-settings 2>&1 | tail -3
Scripts/run-selftest.sh --selftest-ui-strings 2>&1 | tail -3
```

**Done when:**
- [ ] Modules is the first tab; all 3 toggles work and persist;
- [ ] disabled module's tabs show the banner and dim, nothing else moves;
- [ ] `--selftest-settings` + `--selftest-ui-strings` green;
- [ ] `STATUS.md` MOD-03 row updated.
