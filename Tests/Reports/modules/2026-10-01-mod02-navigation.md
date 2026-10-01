# MOD-02 navigation producers — 2026-10-01

Disabled modules no longer remain selected through a restored preference, a
requested destination, a Sidebar binding or a direct navigation helper. The
navigation producer normalizes the destination through the existing
`ModulePolicy` and persists the actual landing. Search also requires an enabled
Meetings/Assistant module and the knowledge-index choice; an old Search selection
does not bypass that contract.

## Confirmed cause and source change

`NavigationState` restored and assigned sections without consulting module choices.
Its direct helper assignments and the Sidebar binding bypassed `show(_:)`, so a
guard in that method alone would leave other producers emitting disabled sections.
Sidebar exposed the disabled rows, and MainWindow constructed their detail views.
The original Comparison migration also left the retired stored value in place,
despite its comment promising a one-time migration.

Changes use the existing navigation state and policy:

- `NavigationState.selectedSection` is a normalized computed setter over its one
  observable section field. Every helper and binding uses it. Restore uses the
  same policy and the existing `navigation.section` key.
- `MainWindow` switches on the synchronously resolved destination before creating
  a detail view. Its module/index change callback reconciles and persists the
  live selection. While Settings is open, it stays open and the saved destination
  is repaired for the next launch.
- Sidebar uses the same section matrix and filters recording status, label,
  elapsed time and orb state by the enabled capture module.
- Settings remains accessible with all modules off. Comparison opens its Settings
  pane once and saves the first enabled fallback for the next launch.
- Disabled Agent/Meeting helper requests do not stage a new pending memory or
  transcript-detail request.
- Self-tests' shared navigation uses the existing `SelfTestHarnessDefaults` suite;
  otherwise the new restore migration could change the owner's navigation key.
  The real app retains standard defaults. Module/model choices are unchanged.

No runtime capture/scheduler/Agent gate, Modules screen, store, queue, download or
model change is included. MOD-03 and later tasks remain separate.

## Reproducible producer verification

```sh
python3 Tests/Reports/modules/run-mod02-driver.py --baseline
python3 Tests/Reports/modules/run-mod02-driver.py
python3 Tests/Reports/modules/run-mod02-driver.py --omit-normalization
```

Markers and exit statuses:

```text
MOD02_DRIVER_FAILED: 538/1184                   # original decisions, exit 1
MOD02_DRIVER_OK: 1340 checks; actual NavigationState; 8 combinations
MOD02_DRIVER_FAILED: 342/1340                   # setter mutation, exit 1
```

The baseline replays the committed `450dbaa` NavigationState, adding only a
constructor/storage injection seam in a temporary compiler file. Its actual
restore, setter and helper behavior remains unchanged. The fixed run compiles
the complete current production NavigationState with its real Observation macro,
the unchanged production policy, and exact Sidebar computed properties. Small
Settings, SettingsTab, capture and self-test collaborators let the producer run
without an app, microphone, model, grants or owner-store writes.

All eight module combinations and both index choices exercise restored/default/
invalid/raw destinations, `show`, direct binding assignment, every public routing
helper, persisted landings and legacy Settings/Comparison. Live changes verify
immediate detail resolution before reconciliation, repaired persistence and
Settings staying accessible. The actual Sidebar properties cover idle/listening/
finishing plus overlapping meeting/dictation states. The shared self-test route
writes its unique harness suite and leaves standard navigation defaults unchanged.
Source-wiring checks pin the MainWindow resolved detail switch and all four choices
in its reconciliation callback; these checks do not substitute for app rendering.

The normalization mutation alters only a temporary compiled navigation file. It
keeps restoration fixed but bypasses the real setter's destination normalization,
making direct requests/bindings fail. An ordinary run remains green afterward.

An early candidate assigned `selectedSection` inside its own Observation-backed
observer and recursed. The complete Observation fixture caught that crash; the
final single-field computed producer avoids the re-entry. No crashed candidate
was installed or counted as passing evidence.

`git diff --check` passes for owned source and driver/report paths.

## Remaining integration and visual evidence

Root coordinates the full app build/install and installed Settings, Agent panes,
UI strings, regression and isolation checks. No app build or live model benchmark
was launched by this worker. The isolated driver proves the producers and
consumer selector; the live SwiftUI change callback and rendered row/detail
behavior still need root integration and visual review. MOD-02 remains in progress
until those required checks and the scoped commit. No new self-test flag is added.

## Root installed integration

Serial full app build/install succeeded. Installed Settings (12 panes), Agent
panes, UI strings and store isolation passed; the latter confirms 18 files and
23 defaults unchanged. All nine P3 voice flags passed and core acceptance was
17/18, with only the unchanged wake failure.
[Installed Settings output](../voice-production/2026-10-01-p3-01/after-settings.txt).
Source is integrated and ready for the scoped commit. The required by-eye
module row/detail and live SwiftUI callback review remains open; MOD-02 stays
in progress for that evidence, without claiming the Modules screen exists.
