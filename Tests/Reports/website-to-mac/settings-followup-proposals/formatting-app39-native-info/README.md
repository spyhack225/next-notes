**Application checkpoint:** reviewed two-file patch applied under runtime root's exact Source-only lease after original40 compile; immediately refrozen for fixed41. [source-application.json](source-application.json) records all pre/post hashes and whitespace checks. Compilation/native result remains pending; original39 consumer failures remain open. Historical off-source review below is retained.

# App39 native information/menu contract — two-file review

**UNAPPLIED, expanded source-only lease proposal.** Exact two-file scope: `FormattingSettingsTab.swift` and canonical `DesignSystem.swift` (one Size token). Sources, native/build/compiler/model execution and staging remain unchanged. Canonical Source is not edited by this worker; runtime root coordinates any expanded lease/application.

## Original confirmed output and geometry

[Actual app39 report](../../settings-app39/README.md) and [footer allocation findings](../../settings-app39/footer-allocation-findings.json) retain original images, guarded 15-profile identity, isolated native results and all-eight 560 footer observations. Standard 320/560 images were inspected. Exact original PNG/log hashes and Source baselines are pinned in manifest.json.

- Apps multiline footer is allocated 28pt and Screen names footer 40pt at both native stages across all four accessibility variants. Native generic hosting parents share those frames. Actual 560 Text now wraps inside those allocations but clips vertically. Thus the previous unlimited-line candidate did not repair the native footer height contract. No text or privacy failure is marked fixed.
- Compact native Menu projects only the first `File references` Text from its VStack label; actual selected style supplied in the second Text is missing. This is the real native label consumer contract, not missing stored state.
- Notion's short actual label admits a wide row at 320, while the longer header label admits compact mode. Actual checkbox columns have no visible definitions there. Separate intrinsic label tests caused inconsistent admission; no hidden measurement view is justified.
- One native scrolling List has positive 978/1024pt viewport and the same 15 profiles. That prior zero-height viewport correction is established separately. This candidate does not alter List selection, producer inputs or scrolling ownership.

## Smallest responsible-producer changes

1. Move unchanged Apps, Screen names and File notes from native Section.footer adapters into **actual content rows in their same existing Sections**. Each information row is nonselectable and keeps the same SettingsNote/full text with unlimited native lines and vertical intrinsic sizing. DS window background distinguishes explanatory text from control rows. No native height is copied into product code, no count-times-height or geometry writer/store is added, and no new scrolling surface is created. Keeping File's explanatory note on the same content contract prevents the shared footer adapter from truncating it at narrower widths; its words are unchanged.
2. Put the compact `File references` heading outside the native Menu. Its sole native Text label becomes the existing actual selected `PathReferenceStyle.displayName`. Wide symbol, Picker/binding/options/tags/help and visible compact/hidden wide indicator stay unchanged. Native direct selection remains the same existing callback.
3. Canonical owner proposal adds **DS.Size.formatAppLabelMinimum = 140**, consumed by both the real visible wide header and actual wide app label. This is a readable label-column **design choice to validate**, not a measured glyph width or hard pane breakpoint. Larger intrinsic labels keep their natural size. Both header/row fit tests therefore reserve an actual readable column; the original 320 Notion mismatch should choose compact while original 560 table should fit. No dummy hidden label, onGeometry callback, unrelated token or new layout abstraction appears.

Same store/settings/ForEach/profile tags/ids/callbacks, selection, section order, native checkbox/menu producers, sheets and all suffix code after `// MARK: - Path references` remain. Complete privacy wording is byte-identical. Global SettingsNote and other panes are untouched. This changes producer composition through the existing native seams; actual controls, accessibility, theme and timing remain acceptance obligations.

## Exact artifacts and hashes

Manifest records each baseline/proposed/patch SHA. `baseline/` and `proposed/` contain only the two copied files. `01-formatting-native-info-menu.patch` is the view-only component; `02-designsystem-label-floor.patch` is the canonical owner component. `native-info-and-label-floor.patch` combines both and must only be applied as the reviewed expanded lease.

Combined patch SHA: `74c21ae4b6f7cdc0230b2a70837cd79b1eb4bc753b395364fb1040b2801397ea`.

Actual Formatting baseline SHA `5cea7730e4467a966f81aa0923fb71c4231bf3d6046f758320c06bde59fa1f4b`; current DS baseline SHA `b0335cf423f1366b13195bb530a3ad564a8667bfabb441a5bf35221f86a3de7c`. Recheck these before root application. `git apply --no-index --check ../native-info-and-label-floor.patch` returned exit0 from the copied baseline directory only. No Source application, compiler or native proof was performed.

## Required serial commands after root approval/release

Root keeps original/candidate manifest, exact installed executable identity and source refreeze around the existing serial build. Use the same launcher and original width/input selections as app39, with a new safe output directory selected by runtime root. The following are a plan, **not executed here**:

```bash
make install OPEN=0
Scripts/run-selftest.sh --out "$NEXTNOTES_UI_REVIEW_DIR/settings.log" --selftest-settings --selftest-timeout 300
Scripts/run-selftest.sh --out "$NEXTNOTES_UI_REVIEW_DIR/ui-strings.log" --selftest-ui-strings --selftest-timeout 300
Scripts/run-selftest.sh --out "$NEXTNOTES_UI_REVIEW_DIR/isolation.log" --selftest-store-isolation --selftest-timeout 300
Scripts/run-selftest.sh --out "$NEXTNOTES_UI_REVIEW_DIR/capture-formatting320.log" --selftest-settings-sheet "$NEXTNOTES_UI_REVIEW_DIR/formatting320" --settings-pane formatting --width 320 --selftest-timeout 300
Scripts/run-selftest.sh --out "$NEXTNOTES_UI_REVIEW_DIR/capture-formatting560.log" --selftest-settings-sheet "$NEXTNOTES_UI_REVIEW_DIR/formatting560" --settings-pane formatting --width 560 --selftest-timeout 300
```

Each capture already covers all four independent RM/RT axes. Require existing constructor, persistent-write negative, awaited consumer and final owner invariance markers, zero failed assertions and unchanged installed executable during capture. Do not initialize or seed any owner store.

## Required consumer evidence, still open

- Compare original and candidate exact 15-profile inputs at 320 and 560. Positive viewport must persist; actual native information rows must allocate enough height for full text rather than retain 28/40pt footer caps. Inspect full privacy wording at 560 and reach later notes through original supported-height scrolling at 320; a tall screenshot or image count is not sufficient.
- Confirm `Plain words`, `@-paths` and `Backticked paths` appear as actual native Menu labels for the unchanged representative profiles. The heading remains visible outside the Menu and the native indicator remains. Verify actual Picker selection changes the same isolated store field and updates the label.
- Confirm every actual narrow profile including short-label Notion uses labeled compact controls consistently with its header. At 560 retain original native column layout for these same profiles; token140 can only be accepted after this real before/after layout evidence.
- Information rows must not enter selection or block controls; range/keyboard selection, first/last profile scrolling, toggles/Menu focus/help/VoiceOver, native row contrast and resize continuity remain real interaction gates. Preserve Reduce Motion, exact note copy, owner invariance and one scrolling surface.
- If native info rows still clip, trace their actual height producer before another candidate. No text trimming, copied frame constant, longer wait or success claim is admitted.

No task/phase/model promotion follows from applicability, capture guard markers or this proposal alone.
