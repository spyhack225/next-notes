# MODULES-ACTIVATION Phase C — onboarding + models (MOD-08, MOD-09)

---

## MOD-08 — Onboarding modules picker + conditional flow

**Blocked on:** MOD-01 for routing; SB-04/SB-05 for final model offers/resume.
**Effort:** re-estimate after artifact requirements integration.

**Why.** First run must not download ~5 GB for a module the user never wanted.
The picker is the one screen that prevents that.

**What lands:**
* `UI/Onboarding/OnboardingFlow.swift` — new step `modules` between `welcome`
  and `dictation`. `OnboardingStep.allCases` declaration order stays the run
  order (self-test pins it). New step is **required**; all-off is refused with
  "Pick at least one so there is something to set up."
* New `OnboardingModulesStep` in `UI/Onboarding/OnboardingSteps.swift` — 3
  toggle cards (Dictation / Meetings / Assistant), each one benefit line +
  one cost line from enabled requirements and verified installed artifacts
  ("Already on this Mac" / missing size / Apple no-download path). Shared files
  contribute once to the combined setup total; per-card numbers are not additive. Writes `moduleDictationEnabled`,
  `moduleMeetingsEnabled`, `agentEnabled` on Continue (not on toggle, so
  quitting halfway keeps prior values).
* `OnboardingFlow.advance()` skips screens whose module is off:
  dictation-off skips `dictation`+`shortcut`; meetings-off skips `meetings`;
  agent-off skips `files` (it feeds `IndexedFoldersStore`, agent-only);
  `brain` is the existing model-setup step ID, not proof of one universal model.
  Show it when an enabled workload needs an initiated model setup/download offer;
  Dictation-only with MiniCPM selected is included. Ready/Apple-only choices can
  skip the download offer; no inactive module gets one. `isOptional` unchanged.
* `OnboardingOutcome.swift` (`AllSet`): tips filtered by enabled modules;
  never claims setup for a skipped module. `OnboardingModelResume.swift`:
  resume only setup the person initiated for a workload still enabled. Check all
  consumers of a shared fetch before cancelling it; one module-off cannot strand
  another. Recompute missing-artifact union/readiness rather than a global brain bit.
* `--selftest-onboarding` order assertion updated (8 steps) + cases:
  all-off refused, dictation-off skips shortcut, dictation-only MiniCPM offer,
  Apple-only no download, shared artifact counted once, distinct role offers,
  resume does not start a new download for a disabled sole consumer or cancel
  a fetch still needed by another enabled consumer.

**Files you will change:**
- `Sources/NextNotes/UI/Onboarding/OnboardingFlow.swift`
- `Sources/NextNotes/UI/Onboarding/OnboardingSteps.swift`
- `Sources/NextNotes/UI/Onboarding/OnboardingOutcome.swift`
- `Sources/NextNotes/UI/Onboarding/OnboardingModelResume.swift`
- `Sources/NextNotes/UI/Onboarding/OnboardingSelfTest.swift`

**Read for context:** `Support/LocalModelStore.swift` (brain states),
`Formatting/LLM/SharedModelCatalog.swift` and verified library resolution
(lands in SB-01; use generic setup sentences until available, not fixed universal
sizes). SB-04/SB-05 own per-workload fallback and resume policy.

**Do not:** auto-download on toggle, change grant rows, rename existing steps.

**Verify.**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-onboarding 2>&1 | tail -3
Scripts/run-selftest.sh --selftest-ui-strings 2>&1 | tail -3
```

**Done when:**
- [ ] picker persists 3 flags; conditional skips hold in both directions;
- [ ] all-off refused; resume respects the flags;
- [ ] self-tests green; `STATUS.md` MOD-08 updated.

---

## MOD-09 — Models tab regroup + no-download-when-off + delete-on-disable

**Blocked on:** MOD-01, SB-01…04, SB-06 (lands second on shared files).
**Effort:** re-estimate consumer-accounting and deletion fixture work.

**Why.** Only enabled workloads offer their missing files. Disabling a module
can free exclusive unused files; it cannot free bytes another consumer still needs.

**What lands:**
* `UI/Settings/ModelsSettingsTab.swift` — group by enabled workloads without
  duplicate physical file rows. A shared artifact has consumer labels (for example
  "Used for Dictation and Meetings"). Inactive-only unused files may show
  "Not in use — Delete X GB"; shared/pending/leased files remain protected.
  No download offer for an inactive sole consumer. Explicit library removal still
  uses verified trial, fallback repair and actual runtime ownership checks.
* `Support/LocalModelStore.swift` — preparation from an off module starts no
  new task or state change. Keep workload entry points (`prepareNotesModel` etc.)
  and use SB-04's shared artifact resolver; no `prepareSharedBrain` rename.
  An enabled consumer may use the same file while another module is off. Disabling
  a consumer cannot cancel another's fetch or an already committed background job.
* MOD-03's Keep/Delete action derives removable files from existing role/cleanup
  assignments, enabled flags, download owners, pending/durable jobs, runtime leases
  and fallback needs. Delete only the exclusive unused subset through the existing
  library; recheck at mutation. Do not rely on today's Agent-only canRemove rule.
  Preserve its protection and extend it across consumers in SB-02/SB-04. An active
  model or in-flight job never loses its file; no automatic destructive repair.
* `ModelSpaceManagerSheet` shows distinct total physical bytes, shared bytes and
  exclusive reclaimable bytes. Per-module totals must not sum duplicate artifacts.
  No extra persisted reference-count/store/queue.

**Files you will change:**
- `Sources/NextNotes/UI/Settings/ModelsSettingsTab.swift`
- `Sources/NextNotes/Support/LocalModelStore.swift` (guards only)
- `Sources/NextNotes/UI/Settings/ModelSpaceManagerSheet.swift`

**Do not:** change download verification, SHA pinning, `minimumFreeBytes`
policy, or the catalog itself (SB-01 owns it).

**Verify.**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-model-roles 2>&1 | tail -3
# by eye: --settings-sheet, disabled group collapsed with delete row
```

**Done when:**
- [ ] disabled sole consumer = no new download offer; only exclusive unused files
  offered for deletion, with truthful bytes; shared/pending/leased files retained;
- [ ] guards hold under rapid toggle; `STATUS.md` MOD-09 updated.
