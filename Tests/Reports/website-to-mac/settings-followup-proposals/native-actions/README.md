# Native text actions — off-source candidate

## Original and responsible producer

The packaged app29 captures include the production SettingsWindow font/tint inheritance, and the two actual action labels still render blue: Formatting's Reveal formatting.txt and Agent's Manage in Models. Their production declarations both select `.buttonStyle(.link)`. `DS.Color.accent` resolves to the fixed theme's primary ink; the capture omission is repaired and cannot by itself explain the remaining blue.

This is a confirmed offscreen component observation. The framework's private link drawing implementation and actual on-screen shell behavior are not inspected here. Do not claim an on-screen product fix or that every link style universally ignores tint. Apple documents platform/style/context differences in [tint behavior](https://developer.apple.com/documentation/swiftui/view/tint(_:)).

## Smallest proposed local adaptation

The two existing SwiftUI Buttons keep their exact action closures, wording, font/help modifiers and surrounding layout. Their labels become explicit underlined Text using the existing theme ink, and the existing native `.plain` primitive style replaces `.link`. The underline retains an action affordance when color no longer distinguishes the label. No custom ButtonStyle, gesture handler, hover clock, color literal, focus store, permission, delay or behavior layer is introduced.

Apple describes [LinkButtonStyle](https://developer.apple.com/documentation/swiftui/linkbuttonstyle) as an imitation of links and [PlainButtonStyle](https://developer.apple.com/documentation/swiftui/plainbuttonstyle) as leaving idle content undecorated while allowing control state effects. That supports testing an explicit label with an existing Button style; it does not prove keyboard, pointer or VoiceOver parity. The repository already uses native plain Buttons with explicit DS foregrounds in MemoryDataControls.

`native-actions-current-source.patch` is against current frozen Sources. Formatting's responsive candidate also moves the Reveal button into a helper: apply only after reviewing a merged off-source preview, never by forcing this patch over a changed file. AgentSettingsTab is the second file; no other `.link` use is changed speculatively. The proposal remains unapplied.

## Required original/current proof

1. Preserve app29 originals and use the same actual pane/input/width/independent accessibility axes for the proposed capture. The complete action label must become theme ink and remain readable at320/560. Generation alone does not pass this check.
2. Inspect both normal and disabled/focused/pressed behavior where applicable. Keep each control a Button, with one activation and its original accessible name. No onTapGesture substitute is permitted.
3. In the granted native fixture slot, verify Tab/Shift-Tab traversal, visible focus, Space/Return activation and one VoiceOver announcement through restricted action effects. Model navigation changes only the existing navigation selection; a reveal effect must be constrained to the harmless temporary fixture file. No owner file is revealed for a test.
4. Check hover/pointer affordance and text selection in nearby notes. If plain style loses the original control behavior, reject this candidate rather than adding unmeasured focus/gesture patches.
5. Keep original store guards and relevant Settings/UI-string gates. Actual on-screen review still needs the existing per-app CUA permission; this proposal does not bypass it.

## Verification performed

Source trace, Apple primary documentation, SDK signature checks, exact hashes and `git apply --check` only. No Source modification, compilation, native run, staging or product success claim. `hashes.json` pins the two original/proposed files and patch.
