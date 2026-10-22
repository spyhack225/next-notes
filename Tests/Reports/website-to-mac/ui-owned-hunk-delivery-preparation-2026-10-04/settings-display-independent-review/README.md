# Independent Settings display hunk review

**Verdict:** Source-only conditional acceptance of the 42 selected display hunks. Root reconciliation and native activation remain held. This review grants no whole-file staging or current compiled/native result.

## Exact scope and identity

- Reviewed frozen `settings-display-boundaries/manifest.json` (`4fc90cf4af442d2b2137862b0a9cd804de484334f282b0fc77c0512203f2c5e1`). All 44 artifact pins, 42 selected relative hunk header/body hashes, eight evidence pins, four current source hashes, and four historical applied-source identities match. The 60 inventory hunks partition into 42 selected and 18 excluded.
- Selected ownership is FormattingSettingsTab 35, ComputerBrowserReadiness 3, AgentSettingsTab 3, DesignSystem 1 (`formatAppLabelMinimum = 140`). ComputerBrowserReadiness-01 is excluded because it changes the SettingsSheet health-probe behavior. Seventeen other DesignSystem hunks belong to the separate foundation packet. ModelsSettingsTab is absent; its existing preview-task token work belongs to the foreign 1787 packet alone.
- The Formatting and DesignSystem current text hashes match the retained app41 applied-source archive; ComputerBrowserReadiness and AgentSettingsTab match the app36 source-application record. These are provenance checks, not a new native run.

## Consumer boundaries

- Formatting replaces the outer `Form` plus inner fixed-height, scrolling `List` with one native `List(selection: $selection)` under the existing `ScrollViewReader`. The same single-row ID is scrolled on selection; the only changed animation respects Reduce Motion. Nonprofile header, control, explanation, file and screen-name rows disable list selection. Profile rows retain `ForEach(store.profiles)`, bundle-ID `.tag`/`.id`, capability and path callbacks, and add/default/frontmost/editor/picker/reveal actions.
- OutputProfileRow moves the same capability `Binding(get:contains,set:onToggle)` into a shared helper rendered by wide and compact layouts. The same native `Menu` and `Picker` keep `PathReferenceStyle.allCases`, the same style tags, and `onPathReference`; the compact trigger displays the selected style name. Section notes are moved from footers to visible, nonselectable rows without changing their text.
- ReadinessRow extracts title/status/action into `ViewThatFits` branches while preserving `Button(actionTitle, action: action)` and busy/status inputs. The three AgentSettings hunks restyle the existing “Manage in Models” button label without changing its action. DesignSystem adds a width constant used by the formatting header and row only.
- No selected hunk adds a store, wait, debounce, second scroll container, settings option, permission gate or runtime callback. This is a finite hunk-level reading, not native click, VoiceOver, binding execution, or compiled Swift proof. In particular, `ViewThatFits` layout and selection/focus behavior need the owning native UI gate.

## Release boundary

Root must reconcile these hunks against its current source and other accepted foundation pieces. The inventory intentionally excludes `ComputerBrowserReadiness-01`, the 17 other DesignSystem hunks, SettingsSheet/constructor/health effect work, ModelsSettingsTab token1787, and Agent runtime changes. The current archive match cannot authorize applying a whole mixed file. Historical app36/app41 evidence does not establish a fresh native pass for this assembled selection.
