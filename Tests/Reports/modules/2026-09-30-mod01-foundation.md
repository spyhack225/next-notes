# MOD-01 module foundation — 2026-09-30

The module-choice producer now lives in the existing `Settings`: Dictation and
Meetings use new persisted keys, both defaulting to `true` when absent. Assistant
continues to use `agentEnabled`, default `false`. No existing preference, model
choice, file, download queue or runtime gate changed.

`Settings.initialModuleEnabled` is the reader used by the actual production
initializer. `Settings.isModuleEnabled` delegates its cached choices to the pure
`ModulePolicy`. The policy has no store or singleton access; it defines the
section matrix, Dictation → Meetings → Agent → Dictionary fallback, and an
initial routing sketch over the existing onboarding steps. Dictation-only keeps
the model-setup step because cleanup may need a local model. MOD-08 still owns
the picker and actual model offers/resume; this task starts no download.

## Focused verification

Run from the repo root:

```sh
python3 Tests/Reports/modules/run-mod01-driver.py
```

Result:

```text
MOD01_DRIVER_OK: 8 combinations; absent defaults; persisted choices; production reader
```

The driver compiles the unchanged production `ModulePolicy.swift`, the actual
`SidebarSection` and `OnboardingStep` declarations, and the exact module
properties, persistence observers, reader and convenience function extracted
from `Settings.swift`. It removes unrelated app dependencies and injects a unique
temporary defaults suite into the reduced Settings constructor. It asserts that
the actual app initializer calls the same tested reader for all three choices.
No owner preferences or model stores are read or written.

Checks cover all eight enabled combinations, absent-key defaults, explicit
true/false persistence and reopening, Assistant's existing key, both knowledge
index states, Dictionary availability, Settings/Comparison exclusion, navigation
fallback order and the setup sketch. No second Assistant key is created.

Mutation proof:

```sh
python3 Tests/Reports/modules/run-mod01-driver.py --omit-dictation-write
```

Only the temporary compiler fixture's Dictation persistence observer is disabled.
It compiles, then exits 1 with `MOD01_DRIVER_FAILED: 17`, including
`MOD01_DRIVER_WRONG: Dictation read-back 0`. Restoring the ordinary driver produces
the OK marker above. App source is never mutated by this check.

`git diff --check` passes for the owned source and driver/report paths.

## Integrated verification

Root completed the integrated app build and installation with the normal
Makefile prerequisites and a temporary serial recipe (`--jobs 1`). `make test`
passed 30 tests in two suites. Installed checks returned `SETTINGS_OK` (12 panes)
and `UI_STRINGS_OK`. [Dictionary output](../toolloop-live/2026-09-30-p1-31c/dictionary-tests.txt),
[Settings output](../toolloop-live/2026-09-30-p1-31c/integrated-settings.txt),
[UI strings output](../toolloop-live/2026-09-30-p1-31c/integrated-ui-strings.txt).
No simultaneous application builds or model benchmarks were launched by workers.

MOD-01's foundation is complete. The reduced driver is focused producer evidence,
not proof of a working Modules screen or runtime gates. MOD-02 through MOD-10 and
the Phase A sidebar gate remain open. The shared Settings file also contains
concurrent iMessage work; the module commit stages only its own hunks.
