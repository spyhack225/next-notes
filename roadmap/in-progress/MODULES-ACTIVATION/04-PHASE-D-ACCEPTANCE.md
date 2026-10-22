# MODULES-ACTIVATION Phase D — acceptance (MOD-10)

---

## MOD-10 — `--selftest-modules` + acceptance tier

**Blocked on:** MOD-01 … MOD-09. **Effort:** 3–4 h.

**Why.** The matrix (3 modules × on/off × download offered or not × sidebar
row present or not) is exactly the kind of thing that silently drifts. One
flag pins it.

**What lands:**
* New runner (own file, e.g. `Support/ModuleSelfTest.swift`, registered in
  `NextNotesApp.runRequestedSelfTest` — registration batched by the
  orchestrator per 00-README §7):
  * pure `ModulePolicy` matrix: every flag combination maps to the right
    visible sections, onboarding steps, and download-offer set;
  * integration: toggle each module off with its models present → sidebar row
    gone, inactive sole-consumer download offer gone, exclusive unused bytes
    offered for deletion; shared files retained; toggle back on →
    row returns, stored sub-switches (`meetingsAutoRecord`,
    `knowledgeInclude*`) preserved;
  * no-download-when-off: `prepare*` while off changes no state and starts no
    task;
  * shared-artifact matrix: Agent A/notes B/cleanup MiniCPM remain independent;
    same exact file used by 2–3 modules is downloaded/counts once; disabling any
    one cannot delete/cancel it while another consumer or pending work needs it;
    different quantizations stay separate; dictation-only includes MiniCPM setup;
    Apple-only requires no file; scoped cloud consent never follows module sharing.
  * no-strand: scripted in-flight meeting + outstanding approval survive the
    toggle (drives the same seams MOD-05/MOD-06 used, no real recording).
  * Final line `MODULES_OK` / `MODULES_FAILED`. Never touches the owner's
    stores (harness suite) and never calls `RunLog.record`.
* `Scripts/acceptance.sh` — one `INTEGRATION` tier line (not CORE: modules are
  gating, not capture). `AGENTS.md` flag list +1 line (batched).
* `STATUS.md` in this folder closes the Phase D gate.

**Files you will change:**
- `Sources/NextNotes/Support/ModuleSelfTest.swift` — new
- `Sources/NextNotes/NextNotesApp.swift` — registration only
- `Scripts/acceptance.sh` — one tier line
- `AGENTS.md` — one flag line

**Do not:** change any gate logic to make the test pass; change the logic and
re-run.

**Verify.**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-modules 2>&1 | tail -3
make test
make acceptance TIER=integration
Scripts/run-selftest.sh --selftest-settings
Scripts/run-selftest.sh --selftest-ui-strings
```

**Done when:**
- [ ] `MODULES_OK`; red-first confirmed (each matrix row fails with the guard
  removed);
- [ ] acceptance + regressions green; `STATUS.md` MOD-10 + Phase D gate closed.
