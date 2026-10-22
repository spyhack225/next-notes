# Formatting profile capture — native layout observation proposal

2026-10-02. **Applied under a SettingsSheet-only Source lease; uncompiled and unrun.** The runtime root accepted the final geometry review and exact baseline hashes, then authorized direct diagnostic integration for its next app32 build. Source application and refreeze hashes are recorded in source-application.json. No product List/layout behavior, build, install, native/model run, owner input or Git staging changed. This observation is not a product fix. Earlier preparation details below describe the off-source proposal stage.

## Original failing cases and provenance

App29 executable SHA256 `c7e6468913226d281684ed2fa1fdbfe03a1b218882b4e1d0aa868266602b0eee` generates isolated Formatting320 and Formatting560 captures with known fixture profiles verified before/after. The [app29 report](../../settings-app29/README.md) records absent visible profile rows in both widths. The corresponding standard artifacts and logs remain in settings-app29/formatting320 and settings-app29/formatting560. This investigation uses the source, report and numeric/marker logs; it has not performed additional visual inspection or native execution.

The app29 capture had the four existing font/tint modifiers supplied. Its `SETTINGS_SHEET_FIXTURE_OK` proves its fixed guard contract, not visible profile rows. A capture passing the exact canonical store check can still fail the visual requirement. Retain the original artifacts and verdict distinction.

## Actual producer/consumer trace

| Boundary | Actual current source contract | What is established / still missing |
| --- | --- | --- |
| OutputProfileStore.fileURL / init | Exact diagnostic path checked before read; absent file seeds OutputProfileDefaults.all; existing file parses/sorts; watcher/frontmost effects refused | Safe known source. Diagnostic verifies canonical exact profiles, not only count |
| SettingsSheet.writeFixture | Writes known full defaults through actual file seam; checks actual shared parsed profiles and effect state before and after panes | Known profiles remain in store throughout the capture. No owner history is needed |
| FormattingSettingsTab state | `@State private var store = OutputProfileStore.shared`; profileList branches on actual store.profiles.isEmpty | Same shared producer, no copied list or alternate fixture table |
| profileList | Nonempty branch creates actual selection List with ForEach(store.profiles), native OutputProfileRow callbacks, tag/id; inset style, alternating backgrounds, scrollDisabled(true), no explicit height | Source declares actual rows. It does not establish their native allocated height/materialization |
| SettingsPane / custom Form style | Formatting Apps marks settingsSectionSpans; SettingsFormBody's outer ScrollView extracts section into SettingsSpanningSection's VStack, whose subviews frame maxWidth only | List is now embedded in a spanning VStack inside the outer scroll surface, rather than a native scrolling Form row. Disabled list scrolling does not by itself prove intrinsic full content height |
| SettingsSheet.renderFixture | Actual pane factory with corrected font/tint; offscreen NSPanel + NSHostingView; existing panel/host layout then cacheDisplay | Actual backing and PNG generated. Complete SwiftUI .task/onAppear/native presentation delivery and visible native row geometry were not measured |

**Hypothesis:** a greedy native List without a finite content-height allocation inside the spanning VStack may receive zero/near-zero height. The source comment that every row lays out at full height is a claim to measure, not evidence. Alternatives are empty native data despite populated SwiftUI input, delayed row materialization, or rows outside the cached bounds/behind clipping. Neither the first broken producer contract nor a live product defect is established yet. No height, row fallback or fixedSize product patch is proposed.

## Smallest accepted observation seam

Only existing SettingsSheet.swift is proposed. `renderFixture` gains one optional function argument `observeProfileLayout: Bool = false`. The actual call passes true for `.formatting`; the helper additionally requires the existing exact self-test. Live render, product List, selection, tags, native controls and scrolling are untouched.

Two observations use the **existing** render checkpoints:2 after current layout,3 after current cacheDisplay. No extra layout, drawing, reload, fitting-size/intrinsic-size query, run-loop spin, sleep, scrolling, window ordering or activation is introduced. No .task/.onAppear drain or completion is claimed. The nested AppKit visitor is explicitly MainActor; source copies remain uncompiled.

Records contain fixed field labels and numbers/null only:

- Node preorder index/parent/depth, numeric public AppKit family, child count, frame/bounds, host-coordinate bounds/visible rectangle and intersection with captured root bounds.
- Hidden/hidden-ancestor/alpha, window attachment and current needs-layout/needs-display bits. No class names, identifiers, text, AX labels, account fields or profile contents.
- NSTableView/NSOutlineView actual row/column counts, existing row views queried with makeIfNecessary:false, geometric visible row count, selected-row count, first/last row rectangles.
- NSCollectionView section/item counts and active/loaded/unloaded/intersecting native item counts. View geometry is read only when isViewLoaded is already true, avoiding a lazy view load. Loaded bounds are converted into collection coordinates before intersecting collection.visibleRect; no potentially different parent-frame coordinates are mixed. Its native section/item counts might represent another container; they do not identify the profile list by themselves.
- NSScrollView document frame/visible rectangle, clip bounds and scroller flags. Scroll offsets are observed, never changed.
- Summary store/default counts, total nodes/family counts, window attachment/visibility/key bits. Existing exact canonical profile equality remains the stronger input check.

Family code:0 other NSView (including root hosting view),1 scroll,2 clip,3 outline table,4 table,5 collection,6 table row,7 control. Coordinates are points. A null coordinate means nonfinite/empty intersection sentinel; do not treat it as a pass. Numeric node indices only identify a single observation tree, not persistent view identity across stages.

## Interpretation and limits

| Observation | Bounded inference |
| --- | --- |
| Nonzero source count, candidate native table/collection count matching source, bounds/clip height zero at stages2/3 | Supports collapsed allocated native list geometry. Locate its ancestor chain; it is not yet a live shell reproduction |
| Nonzero source count, all candidate table/collection row/item counts zero | Supports absent native backing data at that instant. Public hierarchy alone may not reveal SwiftUI's actual List backend, so no identified candidate means UNAVAILABLE, not zero profiles |
| Native rows/items nonzero, geometry nonzero, existing/active rows absent before cache and appear after cache | Supports materialization during existing draw checkpoint; not proof of full callback settlement |
| Existing rows/items present, capture intersection zero or outside root, ancestor clip collapsed/hidden | Supports clipping/viewport placement; preserve original scroll/selection behavior when tracing responsible layout producer |
| Nonzero candidate backing, materialized rows and intersecting visible geometry yet PNG still lacks rows | Observation leaves drawing/caching/material/lifecycle open; do not patch product height based on this |
| Window-visible bit zero | Expected offscreen state, not independent proof of why rows disappear |

[Apple's visibleRect contract](https://developer.apple.com/documentation/appkit/nsview/visiblerect) describes ancestor clipping and hidden views but excludes overlapping windows and does not require attachment to a window. Thus geometric visibility is not on-screen or pixel visibility. [rows(in:)](https://developer.apple.com/documentation/appkit/nstableview/rows(in:)) reports geometric row ranges, including an empty result for an empty rectangle. [rowView(atRow:makeIfNecessary:)](https://developer.apple.com/documentation/appkit/nstableview/rowview(atrow:makeifnecessary:)) with false permits nil when no existing visible row view is available; this proposal never requests row creation. [cacheDisplay](https://developer.apple.com/documentation/appkit/nsview/cachedisplay(in:to:)) draws the view subtree into the existing bitmap. These APIs establish narrow observable facts, not a SwiftUI lifecycle guarantee.

Local installed SDK NSView/NSTableView/NSCollectionView headers confirmed these public declarations. Sources and relevant header hashes are pinned in manifest.json. No private AppKit API or reflection is used.

## Prerequisites and specific failing-case plan — root serial owner only

1. Finish runtime30/31 and obtain an explicit SettingsSheet-only source lease. Recheck manifest's actual before hashes. Integrate only this observation patch; other candidates remain independently owned. Existing exact path/default/provider/startup isolation and owner invariance are mandatory.
2. Root owns build/install/provenance and related Settings/UI-string/isolation checks. Observation must not change the existing exact-store, durable-default/file and constructor guards or image matrix. Do not run a private live --settings-sheet to investigate this failure.
3. Replay the **original** Formatting320 and Formatting560 cases on a pinned binary using the existing --selftest-settings-sheet flag and --settings-pane formatting. Keep the4 independent standard/motion/transparency variants, original captured height, layout/draw order, List data, selection and scroll position. Exact launch examples are in plan.md. Root can start320, then560 when bounded capture/source guards pass. No default24/full144 expansion is needed.
4. Require unchanged known profile equality and effect guards, expected constructor/consumer markers and owner invariance. Record the2 numeric stages and original PNGs. No new observation marker says OK; missing candidate families/data are explicitly unavailable. Check numeric-only log payloads and no owner fields/contents.
5. Compare corresponding stage2/3 native candidate row/item counts and clip geometry across widths/axes. Do not infer an exact profile table solely from total hierarchy rows: native Form may contain its own collections. Source count equality plus matching candidate count/ancestry supports attribution but does not prove it. If no identifiable native backend exists, report that limitation; seek a separately reviewed temporary representable/geometry seam instead of inventing a result.
6. Preserve original missing-row artifacts. If a responsible layout producer is confirmed, repair that producer separately through the existing seam; reproduce the original visual failure before and after, verify row selection/keyboard/scroll in actual supported-height shell and preserve one pane scrolling surface. This observation proposal itself resolves no product failure.

No model runs, owner store seeds, native execution, staging or commits were performed by this subagent. Pixel, live focus/VoiceOver/selection/scroll and latency acceptance remain open.
