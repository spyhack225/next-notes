# Formatting profile viewport — one native List candidate

**UNAPPLIED source-only review.** Sources, build/compiler, native/model execution and staging are untouched. This is a proposed one-file correction to the measured producer contract, layered on the existing responsive/text-action proposed copy. It does not claim native success or roadmap closure.

## Original failure and confirmed producer contract

The runtime root's app33 observer measured the actual isolated Formatting pane at 320 and 560 in standard, Reduce Motion, Reduce Transparency and combined variants, at stages 2 and 3. Each of the two original logs has eight native-table observations. All 16 show `rows=15`, `existingRows=0`, `visibleRows=0`; declared store count matches the 15 guarded default profiles. The native table document has 380pt content, but its enclosing inner NSScrollView documentVisible and NSClipView viewport have zero height. At 320 the outer custom Form scroll surface has a nonzero viewport while its spanning-section List child is allocated zero. The same inner zero contract repeats at 560. This evidence separates missing data from missing native viewport allocation.

Original logs (retained in place; hashes in manifest.json):

- `/var/folders/ht/g5rsvv5x27124qp6wn2sg27w0000gn/T/nextnotes-settings-app33-profile-rkudyras/capture-formatting320.log`
- `/var/folders/ht/g5rsvv5x27124qp6wn2sg27w0000gn/T/nextnotes-settings-app33-profile-rkudyras/capture-formatting560.log`

Actual source trace: `SettingsPane` supplies `SettingsFormStyle`; `FormattingSettingsTab.body` creates a Form; Apps marks `settingsSectionSpans`; `SettingsFormBody` adds an outer ScrollView; `SettingsSpanningSection` places the disabled inner selection List in a VStack. That List owns 15 declared native rows but has no public intrinsic-height contract requiring it to expand to its document height. The old source comment assumed `scrollDisabled(true)` plus no fixed height would make every native row occupy the outer Form. The native measurement disproves that assumption. This candidate corrects the owning content producer rather than measuring a height and pushing it back into a downstream frame.

## Proposed existing seam

Formatting alone changes its outer Form/inner List pair into **one root `List(selection: $selection)`**. Apps, Screen names and File remain the existing Sections. Profile `ForEach` is flattened directly into Apps; its actual capability/path callbacks, `.tag(profile.bundleID)` and `.id(profile.bundleID)` remain. `ScrollViewReader` and selection change behavior target that same native List. No competing content ScrollView, synthesized row model, height formula, observer store or introspection writer is added.

Apple documents a List binding to a Set for multiple selection and Sections with dynamic ForEach rows; Mac keyboard/mouse supports multiple selection. This supports the public container choice, not a claim that this uncompiled candidate passes native behavior. [Apple List documentation](https://developer.apple.com/documentation/swiftui/list)

Only nonprofile header/empty/control rows and the Screen names/File sections use `.selectionDisabled(true)`. Apps itself is not disabled, so profile selection stays admitted. This API controls row selection separately from the native buttons/toggles' actions. [Apple selectionDisabled documentation](https://developer.apple.com/documentation/swiftui/view/selectiondisabled(_:))

The actual pane header and inherited `.font(DS.Font.body)` / `.tint(DS.Color.accent)` callsites remain unchanged. Existing native inset/alternating-list treatment moves to the single root. Scroll background is hidden so the existing DS window substrate supplies fixed light; DS groupedFill supplies row surfaces. No new numeric appearance values appear. [Apple scrollContentBackground documentation](https://developer.apple.com/documentation/swiftui/view/scrollcontentbackground(_:))

The existing single-selection `proxy.scrollTo` seam now honors the public Reduce Motion environment with `withAnimation(reduceMotion ? nil : DS.Motion.standard)`. No delay, debounce or new animation clock is added.

## Scope and preservation

Only `Sources/NextNotes/UI/Settings/FormattingSettingsTab.swift` is proposed here.

- Base includes previously reviewed HEADER/FILE/CONTROL native responsive alternatives and explicit themed Reveal text-action proposal. Those changes are retained in the same proposal; no old List-row responsive fallback is reintroduced.
- Same store, settings, selection, sheets, file actions, add/remove/frontmost behavior, help, disabled conditions, error/remediation callbacks and profile bindings. No event owner or runtime read/permission changes.
- Full code from `// MARK: - Row` onward is byte-for-byte unchanged against the merged proposal: profile capability checkbox/path menu producers and all editor/AppPicker code stay intact. The current baseline has no profile context-menu or double-click edit handler to relocate; no new workflow is invented. Existing sheet editors and native menus are preserved.
- Empty-state fixed `formatListHeight` is removed with the inner List; the actual empty-state view uses its native row layout. No fixed height or count-times-row-height appears in the content candidate.
- No SettingsChrome, SettingsSheet, canonical DS, controller or owner-store changes.

**Review tradeoff:** Formatting's former custom Form spanning card plus adaptive compact-section card grid is replaced here by a single native sectional column. Color/font/header identity is retained through existing tokens, but exact card grouping, wide layout, selected-row highlight and native control alignment must be reviewed. Other Settings panes still use their custom Form. This is the smallest public single-scroll selection seam found that eliminates the measured zero-viewport producer without fabricating height. A `.fixedSize` or timeout workaround would still depend on the disproven inner native List sizing assumption.

## Artifacts and applicability

- `source-baseline/.../FormattingSettingsTab.swift`: current untouched Source; SHA `c750e16bd51c4f8f40875d2122b3a89d57dfe3a02f40cd2a08ec7f0c4eb64d69`.
- `merged-baseline/.../FormattingSettingsTab.swift`: existing combined responsive/actions proposed copy; SHA `f0707e87b664f979e7d60f3cfb36b6f182266f5a5932de1aa2a1402d855ac856`.
- `proposed/.../FormattingSettingsTab.swift`: one-List candidate; SHA `dbf3a77207f535b35ed69e7d02bbc5415765f4dd61af4465c90ce582ff0f1b54`.
- `one-list-after-responsive-actions.patch`: apply only after the merged proposal, SHA `afcd6f3b0a915b6a189d22586e69a7b39bbd4162e686bf637bd75c82b4fa1d45`.
- `formatting-combined-current-source.patch`: entire Formatting proposal from current Source, SHA `db18bb5bbdf06f96a5371302010286277eaae3618e86392ee3a994cf87fbc86c`.

Both `git apply --no-index --check` commands returned exit0 in their corresponding copied baseline directories. Neither was applied to production Sources. Compilation, native state delivery, hit testing and capture remain unrun. The runtime root may use the proposed Formatting copy in the eventual existing Computer/Formatting/Agent three-view review; this package does not overwrite that root-owned package.

## Original/current acceptance required

1. Reconfirm exact Source/merged hashes, review the sectional-layout tradeoff, and compile through the serial build owner after release. No native layout claim follows from patch applicability.
2. Repeat the original actual app33 isolated producer inputs at 320 and 560, all four RM/RT axes and original stages. Keep store count/ids and owner isolation invariant. Confirm the root native List's allocated documentVisible/clip height is positive and profile rows are actually instantiated/visible. A table now also includes nonprofile section rows, so raw total table-row count is not the same as 15 profile identities; require exact 15 profile producer identities and observe them without fitting or changing input data.
3. Preserve original/current Sources, executables, logs and PNG hashes. Confirm actual first/last profile content and native toggle/path-menu controls render. The unchanged row layout may expose independent narrow-column wrapping that app33's zero viewport hid; investigate that actual producer if observed, without claiming this patch resolved it.
4. At actual supported-height shell, scroll from first profile to last and to Screen names/File actions. Verify one scrolling surface, click/shift/cmd selection, arrow keys/Page Down, remove selected/add app, retained focus/selection, native help, path menus and VoiceOver. Header/empty/control/Screen names/File row clicks must not become profile selection or disable their own controls.
5. Verify Remove receives only profile bundle IDs; programmatic selection after AppPicker/frontmost add still reaches the correct row and review/edit sheets retain actual bindings. Exercise harmless isolated store actions before owner actions. No native interaction was attempted here.
6. Verify Reduce Motion leaves the same selection/scroll result with no animated scroll; normal motion uses the established token. Check actual fixed-light theme and wide layout/selection highlight rather than accepting a screenshot generation marker. Private owner content must never be loaded or sanitized downstream.

Until the original production-consumer trace and native interaction pass, the Formatting rendering bug and UX acceptance remain open.
