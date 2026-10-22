# MODULES-ACTIVATION status ledger

The only progress record for this roadmap. Update it after every task, following
`00-README.md` §6.

| State | Meaning |
|---|---|
| `todo` | Not started. |
| `in progress` | Claimed and being implemented; verification and commit remain. |
| `red` | The self-test is written and confirmed failing on the old code. |
| `green` | The gate passed and the regressions are unchanged. |
| `done` | Committed. |
| `blocked` | See the notes at the bottom. |

Dates are `YYYY-MM-DD`. Evidence is the verdict line plus measured numbers.
The commit is a short hash.

## Ledger

| ID | Title | Blocked on | State | Date | Evidence | Commit |
|---|---|---|---|---|---|---|
| MOD-01 | Module source of truth: two keys + pure `ModulePolicy` | nothing | done | 2026-09-30 | `MOD01_DRIVER_OK`: 8 combinations; mutation fails 17 assertions. Integrated build/install, 30 dictionary/spoken-form tests, `SETTINGS_OK`, `UI_STRINGS_OK`. [Report](../../../Tests/Reports/modules/2026-09-30-mod01-foundation.md). No UI/runtime gates yet | `450dbaa` |
| MOD-02 | Sidebar filtering + `NavigationState` fallback | MOD-01 | in progress | 2026-10-01 | Implemented/integrated: actual baseline failed 538/1,184 checks; fixed source passed 1,340 checks; mutation failed 342/1,340. Settings, panes, UI strings and store isolation passed. Core passed 17/18 with the unchanged wake failure. By-eye row, detail and live callback evidence remains open; task stays in progress. [Report](../../../Tests/Reports/modules/2026-10-01-mod02-navigation.md). | `7dc1b0c` |
| MOD-03 | Modules Settings tab + per-tab disabled banners | MOD-01 | todo | | | |
| MOD-04 | Dictation runtime gate (hotkey, HUD, island) | MOD-01 | todo | | | |
| MOD-05 | Meetings runtime gate (scheduler, call detector, no strand) | MOD-01 | todo | | | |
| MOD-06 | Assistant runtime gate (empty states, wake, routines pause) | MOD-01 | todo | | | |
| MOD-07 | Knowledge index per-module forcing | MOD-01 | todo | | | |
| MOD-08 | Onboarding modules picker + workload-aware setup/resume | MOD-01; SB-04/SB-05 for model integration | todo | | | |
| MOD-09 | Shared-file totals + enabled-consumer download/deletion policy | MOD-01, SB-01…04, SB-06 | todo | | | |
| MOD-10 | `--selftest-modules` + acceptance tier | MOD-01…MOD-09 | todo | | | |

## Phase gates

| Phase | Gate |
|---|---|
| A — foundation (MOD-01…03) | `make test`, `--selftest-settings`, `--selftest-ui-strings` green; toggling a module hides its sidebar row immediately |
| B — runtime (MOD-04…07) | `--selftest-dictation`, `--selftest-calls`, `--selftest-toolloop-live --quick` green; no stranded meeting/download/approval |
| C — onboarding+models (MOD-08…09) | `--selftest-onboarding`, `--settings-sheet` reviewed by eye; disabled sole consumer offers no download; shared files/requests survive; dictation-only MiniCPM setup and distinct totals |
| D — acceptance (MOD-10) | `MODULES_OK`; `make acceptance TIER=core` unchanged vs baseline |

## BLOCKED notes

```
### <ID> — blocked <YYYY-MM-DD>
Tried: …
Failing line: `<NAME>_FAILED: …`
Missing: <owner use | model | grant | network | owner decision | another agent's uncommitted work>
Next step when unblocked: …
```

## Decisions and deviations

- 2026-09-30: Owner requested parallel execution of ready todo work. Folder moved
  to `roadmap/in-progress/`; MOD-01 alone is claimed. No UI/runtime/model task
  starts merely because the folder moved. Root coordinates builds and installation.

Record each on one line: date, task, what you changed relative to the task text, and why.

- 2026-09-30: Owner approved independent workload models and exact-artifact reuse.
  Notes no longer follow Agent; cleanup default/Apple guard-fallback is concurrent
  OpenCode work. MOD-08/MOD-09 dependencies and shared deletion/accounting gates
  revised. All implementation task states remain unchanged.

MOD-01 integrated and committed as `450dbaa`. MOD-02…10 and the Phase A sidebar gate remain open. The foundation adds no working Modules screen or runtime activation; concurrent iMessage hunks in Settings were excluded from the commit.

- 2026-10-01: MOD-02 claimed after committed MOD-01. Worker owns Sidebar,
  NavigationState and MainWindow; root alone owns builds/install and shared app
  registrations. MOD-03/runtime/model work remains pending, and foreign dirty
  iMessage/dictation files are preserved.
