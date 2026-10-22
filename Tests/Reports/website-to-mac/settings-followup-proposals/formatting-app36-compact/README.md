# App36 Formatting: readable compact rows and complete footers

**UNAPPLIED source-only proposal.** Only `FormattingSettingsTab.swift` is represented. Production Sources, builds/compiler, native/model execution and staging remain frozen. The baseline is the actual app36 one-List Source, not an old nested-List copy. Copies, exact diff and hashes are included. No current native success is claimed.

## Original actual evidence

Inspected these unchanged app36 standard PNGs, whose hashes are pinned in manifest.json:

- `/var/folders/ht/g5rsvv5x27124qp6wn2sg27w0000gn/T/nextnotes-settings-app36-p7_axwna/formatting320/settings-formatting-320-standard.png`
- `/var/folders/ht/g5rsvv5x27124qp6wn2sg27w0000gn/T/nextnotes-settings-app36-p7_axwna/formatting560/settings-formatting-560-standard.png`

At 320, Chrome and Windsurf split across lines, and bundle identifiers are squeezed into a tiny leading column while the five capability checkboxes and one fixed-width path column consume the row. At 560, names/columns fit. Actual runtime-root probes confirm the repaired one-List viewport is nonzero at both widths, with the same 15 profiles and 25 materialized native section/content rows. That original zero-viewport repair is separate from this now-visible row-layout failure.

At 560 the Apps explanation and both Screen names footer notes are rendered as single-line ellipses. The full privacy exclusions are still in the Source but absent from the image. Header/file actions fit and Reveal is black; this proposal keeps their actual behavior.

## Confirmed row producer and minimal seam

`OutputProfileRow.body` emits one HStack: app heading/details, flexible spacer, five label-hidden native checkboxes with DS fixed column widths, and the path Menu with the sixth fixed column. It offers no native alternative when its true labels and those control columns do not fit. App36's newly positive viewport exposes that contract directly.

The candidate reuses the same row type and native controls, with `ViewThatFits(in: .horizontal)`:

- Wide choice: the same single-row app label, five existing hidden-label checkbox columns and path symbol Menu. Intrinsic label/control sizes decide whether it fits; no hard width threshold or minimum-label-width token is invented.
- Compact choice: full-row app heading and original Plain prose/bundle detail, then the same five native checkboxes with their existing capability names visible. A two-flexible-column LazyVGrid is a row layout, not a scrolling surface; it supplies three control lines without fixed height/count-to-height math. The sixth native Menu displays `File references` and the actual current choice. Its original Picker options, binding, selection tags, menu style/help and callbacks are unchanged. Compact text Menu uses the native visible indicator while the wide symbol Menu keeps its hidden indicator, through the existing public modifier. [Apple menuIndicator documentation](https://developer.apple.com/documentation/swiftui/view/menuindicator(_:))
- Checkbox producer is extracted into a private property function inside the existing row so both layout alternatives use the exact same Binding. No new type, store, event layer, workflow, timer or animation is created.
- Header keeps the six symbol definitions/tooltips/accessibility names when its meaningful `App and formatting` label and columns fit. Narrow fallback shows that readable caption alone because compact row controls are individually labeled. This is a small visible caption change to keep the header meaningful; native fit must be checked at 320/560.

App label spacing uses DS.Space.xxs rather than the old inline zero. All added layout spacing/fonts use current DS; two flexible GridItems express layout structure. Existing profile ForEach, .tag/.id, selection, owner callbacks, sheets, one-List scroll/Reduce Motion behavior and every declaration after `// MARK: - Path references` are unchanged. Capability/path values come from the same profile; no simulated state is introduced. Current native accessibility labels remain on controls, with visible compact labels added; no accessibility grouping conceals interactive children.

## Footer producer boundary and limited conclusion

`SettingsNote` contains the unchanged full Text, caption font and `.fixedSize(horizontal: false, vertical: true)`, but sets no explicit unlimited line contract. Formatting now places it in native List Section footers. Before this placement its explanatory/privacy text wrapped; app36's actual native List footer output is single-line. This locates the changed producer boundary at Formatting's footer composition. Native List footer inheritance of a finite line limit is a plausible cause, **not an observed environment value**. No claim is made that global SettingsNote itself is defective.

The smallest candidate sets `.lineLimit(nil)` and `.fixedSize(horizontal: false, vertical: true)` on the existing Apps footer and existing Screen names footer VStack only. All prose, including password fields, number-only fields, browser address bars, banking/finance exclusions and local-only assurances, is byte-preserved. Global SettingsNote, Section styles and other panes are untouched. The file footer is unchanged. The original 560 failure must be repeated to confirm this local producer contract actually yields complete native text; if ellipses remain, trace the native footer adapter rather than trim the copy or claim success.

## Hashes / verification

- Actual Source baseline SHA: `dbf3a77207f535b35ed69e7d02bbc5415765f4dd61af4465c90ce582ff0f1b54`.
- Proposed Source SHA: `5cea7730e4467a966f81aa0923fb71c4231bf3d6046f758320c06bde59fa1f4b`.
- `compact-rows-and-footers.patch` SHA: `516f91201e67a8fb31e449cb8f42933b56f9fbcb6f206fa42b0ffbfbd3a16f94`.

`git apply --no-index --check ../compact-rows-and-footers.patch` returned exit0 from the baseline **copy** directory. Nothing was applied to Sources. Preparation asserted byte-identical profile ForEach callbacks/tags/ids and unchanged full path-reference/editor suffix. Patch applicability is not compilation, native layout proof or owner interaction evidence.

## Required original/current acceptance

1. Runtime root reviews and integrates only this one-file candidate after release, rechecks the exact actual baseline, and runs the serial compile gate. Use the unchanged isolated 15-profile producer inputs from app36 and preserve full Source/executable/log/PNG hashes.
2. Capture 320 and 560 at all four independent RM/RT axes. At 320 confirm intact Chrome/Windsurf headings, readable full-width identifiers (natural line wrapping allowed), five labeled capabilities and labeled current file-reference Menu. At 560 confirm the established single-row table still fits; very long labels may legitimately use the native fallback at either width. Do not shorten app names/ids or fixed-width controls to force a pass.
3. Confirm the original one-List viewport stays positive. Compact rows naturally take more height and native List may virtualize more offscreen rows; total materialized count need not remain 25. Prove exact 15 profile identities and actual first/last profile through native scrolling, not a count/height formula or a demand to materialize invisible rows.
4. At 560 and after scrolling at 320, confirm the *entire* Apps explanation and both complete Screen names notes wrap with no ellipsis, including privacy exclusions. Original/current rendered comparison is required. If native adapter still forces a single line, record that first broken contract and investigate there; downstream copy trimming is not an acceptable correction.
5. At supported-height shell, test scrolling, click/shift/cmd and keyboard selection, resize continuity, focus and VoiceOver for each real checkbox and Menu. Change one harmless isolated capability/path setting and verify the same actual store field changes, the row updates and retained native selection remains; verify cancel/outside click preserves values. Do not treat a helper Binding inspection as actual native control proof.
6. Preserve header/file actions, theme colors/typography, one scrolling surface, original Reduce Motion scroll result and owner-store isolation. Physical owner dictation/meeting/cross-app gates remain separate and open.

Until original native row/footer failures pass and interaction is exercised, this is a reviewable candidate, not a verified fix or roadmap completion.
