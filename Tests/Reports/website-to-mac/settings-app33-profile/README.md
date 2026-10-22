# App33 original Formatting layout failure — 2026-10-02

Executable SHA256 `adc7f6d9848d5ef0355dc989167133a723a77824d52738e1d4e405d2f4b1e8b7`, checked before and after each invocation. Packaged SettingsSheet observation producer SHA `2f85f3911ec7fa0cbf867ad8eb03b257a79656e52ebd02515a7e739af402af39`. Root released exactly Formatting320/560 across four independent accessibility variants, then reclaimed the native slot for fixed runtime build34.

Both invocations return exit0, four PNGs each, actual constructor and persistent-write negative guard markers, awaited-consumer evidence and final existing owner/store invariant marker. The scalar observation is present at the existing after-layout and after-cache checkpoints for all variants: eight observations per width. No Source/build/install/model/CUA action occurred. Original missing-row images, logs, summary, source provenance and artifact hashes are retained here.

## First observed broken layout contract

| Measurement | 320 pt | 560 pt |
| --- | ---: | ---: |
| Actual shared profiles / known defaults |15 /15|15 /15|
| Native outline-table rows |15|15|
| Table content height |380 pt|380 pt|
| Inner List scroll/clip viewport height |0 pt|0 pt|
| Native geometric visible rows |0|0|
| Existing materialized row views |0|0|

These values persist at both existing checkpoints and across all four variants. The table is attached, not hidden, alpha1, and has nonzero content geometry. Its wrapping native view, inner NSScrollView and clip viewport have zero height. The outer pane has nonzero scroll geometry and other sections draw. `geometry-findings.json` checks the unchanged original numeric case independently of the successful capture-generation marker.

Known exact store contents reach ForEach and the native table's15 rows; missing data is not this failure. The first observed incorrect layout value is the profile List's allocated viewport height. The production view nests a native selection List with disabled scrolling and no finite height inside a spanning VStack in the custom Form's outer ScrollView. Its comment assumes disabling scrolling makes the List hug full content; the actual backing does not meet that contract in these captures.

This confirms the original offscreen component failure, not an on-screen shell/accessibility verdict. No callback settlement is invented; no sleep, reload, extra layout or activation was used. No product fix is claimed. A proposed producer repair must preserve native selection and a single scrolling surface. Do not turn the380pt estimated native content height into a fixed product frame or derive one from count × estimated row height: row views have not materialized, and custom profiles/text sizing may differ.

## Next original/current evidence

Replay these same inputs, widths, independent variants and guard checks after the reviewed producer correction. Require nonzero allocated viewport/visible row geometry and actual readable profile rows, with unchanged exact data. A single outer selectable List may include additional section/control rows, so native total row count need not remain15; profile content must remain the same. Preserve supported-height scrolling, native selection, controls, context menus, edit/Add/Remove behavior, keyboard/VoiceOver and theme. Native live review still needs the existing app approval. The diagnostic itself fixes no product behavior and promotes no UX gate.
