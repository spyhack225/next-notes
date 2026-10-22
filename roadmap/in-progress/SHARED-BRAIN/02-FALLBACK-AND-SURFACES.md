# SHARED-BRAIN — per-role fallback and surfaces (SB-04…06)

The 2026-09-30 independent-role decision replaces `prepareSharedBrain` and the
three-row picker proposal. Keep existing preparation entry points where possible.
SB tasks own shared artifact resolution; Modules tasks add activation/accounting guards.

## SB-04 — Reuse before download; fallback scoped to the workload

**Blocked on:** SB-01…03.

**What lands:**

* Pure policy over requesting workload, compatible assignment/recommendation,
  verified artifact availability, bytes still missing, disk reserve and Apple readiness.
  An unrelated runnable model is not proof the workload is ready.
* Exact suitable installed artifact → reuse, zero bytes. Existing same-artifact
  download → join its existing progress/cancellation ownership. Otherwise offer the
  missing artifact if it fits with the existing reserve. Full disk + Apple available
  → use Apple for this workload without altering sibling assignments; no Apple →
  honest space/setup problem with short-by math and no doomed download attempt.
* Integrate existing `LocalModelStore.prepareNotesModel` and module setup/cleanup
  entry points with the resolver. Do not rename everything to `prepareSharedBrain`.
  A readiness state means this role can answer, not that any GGUF is installed.
* Keep stored user choices; unavailable choices fall back at resolution and name it.
  Never silently overwrite Agent because notes fell back. Cleanup's Apple policy stays
  OpenCode's existing guard/fallback, not a new second model pass here.
* Existing trial/probe/verification precede any switch or replacement. Shared-file
  consumers and in-flight work prevent deletion through module disable/replacement.

**Files:** catalog policy (pure), `Support/LocalModelStore.swift`, existing library
resolve/download paths, `NextNotesApp.swift` download diagnostic only if needed.
**Red-first:** exact installed/partial shared fetch; unrelated model not accepted;
full disk → Apple with no fetch; no Apple → honest failure; fallback changes no
other role; file needed by cleanup/other enabled module is retained.
**Verify:** build/install/test; model roles, model-unopenable, cleanup router;
SB-08's injected policy fixtures. STATUS records actual fallback behavior.

## SB-05 — Onboarding and resume reflect enabled roles and missing files

**Blocked on:** SB-04. **Coordinate:** MOD-08 (screen routing and module flags).

* The existing `brain` step identifier can stay for decoding/order. Its content
  offers preparation for enabled modules' independent needs, including MiniCPM
  cleanup when selected. Dictation-only may need cleanup weights; do not skip this
  screen just because Meetings and Assistant are off. Apple-only/ready cases need
  no download; the screen may show ready state or be skipped under MOD-08 policy.
* Show additional bytes from the union of missing exact artifacts, not a fixed
  Gemma/Qwen size or the sum of repeated per-role references. An existing MiniCPM
  copy covers every compatible enabled consumer.
* Resume retains the requesting workload, checks activation/readiness again, and
  only resumes setup the person initiated. Turning one consumer off does not cancel
  another's fetch or pending job. No setup/download from SelfTest.isRunning.
* Plain copy: "Already on this Mac", "Also used for Dictation", "Using Apple's
  built-in intelligence for now." No promise that every module works if only one
  role has a valid fallback. No auto-download on toggle or when space later appears.

**Files:** `UI/Onboarding/OnboardingSteps.swift`, `OnboardingModelResume.swift`,
existing onboarding self-test. MOD-08 owns flow/outcome routing.
**Verify:** build/install; `--selftest-onboarding`, `--selftest-ui-strings`;
fixtures for dictation-only, notes-only, Agent-only, shared/different artifacts,
full disk and disabling one of two consumers. STATUS updated.

## SB-06 — Independent model controls; shared file shown once

**Blocked on:** SB-02…04. **Sequence:** before MOD-09 on Models UI.

* Keep four existing role rows: Agent, meetingNotes, computerUse, coding. Cleanup
  stays in Dictation's existing cleanup setting; no mandatory advanced picker or
  fifth duplicate assignment store. Do not hide the meeting-notes choice.
* Models tab lists each physical artifact once with its consumer modules/roles,
  incremental download bytes and actual provider. Copy: "Each feature uses a model
  suited to its work. Downloads are shared when they use the same model."
* Keep existing Hugging Face search/recommendations, runnable file picker, verified
  resume, probe/trial/switch and space manager. Role assignment must target the
  chosen workload; the existing Agent button must not mutate meetingNotes/cleanup.
* Preserve independent notes/Agent OpenRouter pickers and consent. Reset/setup is
  scoped to the selected role and does not reset sibling choices.
* Meeting prewarm reads meetingNotes, not Agent. MiniCPM cleanup presence can use
  any verified exact matching library path, not only the pinned default basename.

**Files:** `UI/Settings/ModelRoleSection.swift`, `ModelsSettingsTab.swift`,
`OpenRouterModelSelection.swift` where needed, notes prewarm reader;
cleanup settings resolver coordinated with OpenCode.
**Verify:** build/install; settings/UI strings/onboarding/model roles;
`--settings-sheet` by eye at the documented widths. STATUS updated.
