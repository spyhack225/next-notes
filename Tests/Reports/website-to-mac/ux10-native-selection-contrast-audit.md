# Native selection foreground audit

2026-10-01. Read-only source inspection and opaque sRGB palette arithmetic.
No selected-row screenshot, source edit, compiler/native run, owner-store write,
settings change or status change. Current source is newer than installed app12;
neither this source audit nor older screenshots establish current selected pixels.

## Actual selection and foreground producers

| Surface | Existing selection producer | Inherits native foreground | Overrides native foreground with fixed palette |
|---|---|---|---|
| Sidebar | `Sidebar.List(selection: $selection)`; `SidebarSection` tags; hosted in MainWindow's NavigationSplitView | Actual section and Settings rows are plain SwiftUI `Label`. No `SidebarLabel` component exists in the inspected source. Neither label/title nor symbol sets foreground explicitly | None on selectable section rows. The nonselectable recording status is a different producer |
| Dictation | `DictationView.transcriptionList`; actual `Set<UUID>`, row tags; native inset List with alternating backgrounds | Main transcript body; hover Correct/Copy native controls | `TranscriptionRow` engine/time use `DS.Color.textSecondary`; process duration/edited pencil use `textTertiary`. Both now resolve to fixed `#666666`. CorrectionBadges explicitly colors old/new words, arrow and repetition count; its Corrected StatusChip explicitly uses DS accent |
| Saved/live MeetingRow | `MeetingsView.List(selection: $selection)`; `.live` / `.meeting(id)` tags; native sidebar List | Native row selection/focus/background remains the List's | Title explicitly uses fixed `DS.Color.text` (`#0a0a0a`) or provisional `textTertiary` (`#666666`). Date/duration explicitly use `#666666`; status/partial-capture StatusChip explicitly paints fixed status ink. Live RecordingIndicator has its own real recording semantics |
| Completed calendar UpcomingEventRow | The same List tags a retained completed event meeting with `.meeting(id)`; still-upcoming decision rows are selection-disabled | Event title | Video glyph, time, calendar name and status description explicitly use fixed `#666666`; armed status chip uses explicit status color |

`MainWindow` applies `.tint(DS.Color.accent)` where accent is theme primary
`#0a0a0a`. It does **not** apply a blanket fixed foreground to the whole shell.
`DS.Color.selection` names the same ink, but the inspected `UI/` tree has **no
consumer of that token**. Its comment that native alternate selected text will
remain readable is not evidence that explicit leaf colors adapt, or that SwiftUI
actually resolves the selected native background to that exact token.

Thus the confirmed source contract is an override at particular text/glyph/chip
producers, not an observed contrast failure. Native macOS selection can differ
with key-window/list focus and control style. A merely bound selection in an
offscreen inactive window cannot prove active selected appearance. Do not
preemptively recolor plain Sidebar Labels or the dictation body: those already
retain native foreground inheritance.

## Opaque palette arithmetic (narrow evidence)

Calculated from the exact DesignSystem sRGB channels using linearized relative
luminance and `(lighter + 0.05)/(darker + 0.05)`. Displayed ratios below are rounded
for reading; threshold decisions use full precision. Ordinary text requires
4.5:1; large text requires 3:1. Use underlying foreground/background values,
not anti-aliased glyph edges, for that calculation. These are the stated
[W3C contrast minimum rules](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html).

| Exact pair | Computed ratio | Bounded reading |
|---|---:|---|
| Ink `#0a0a0a` on background `#ffffff` | 19.798146 | Opaque text pair meets ordinary-text threshold |
| Ink `#0a0a0a` on card `#f7f7f7` | 18.480360 | Same |
| Muted `#666666` on background `#ffffff` | 5.741836 | Same |
| Muted `#666666` on card `#f7f7f7` | 5.359654 | Same |
| Muted `#666666` on secondary `#ebebeb` | 4.816416 | Same |
| Muted `#666666` on muted `#f0f0f0` | 5.038418 | Same |
| Primary foreground `#ffffff` on primary `#0a0a0a` | 19.798146 | Opaque filled-button text pair meets threshold |
| Secondary foreground `#404040` on secondary `#ebebeb` | 8.697290 | Opaque secondary pair meets threshold |
| Accent foreground `#ffffff` on accent `#41625c` | 6.717038 | Opaque accent pair meets threshold |
| Fixed muted `#666666` on hypothetical active selection `#0a0a0a` | **3.448051** | Would fail ordinary caption/timestamp text **if** those exact resolved colors are observed together |
| Fixed ink `#0a0a0a` on hypothetical active selection `#0a0a0a` | **1.000000** | Would be unreadable **if** the native renderer retains the explicit foreground on that background |

These ratios certify only the specified opaque pairs, not native selection,
glass/refraction, materials, disabled controls, control borders, focus rings,
opacity layers, busy backdrops, all font states or full app AA conformance.
The theme ring `#999999` computes 2.849028 against white and 2.659393 against
card; no `Palette.ring` consumer was found in inspected UI, so this is a dormant
token observation, not a rendered focus-ring failure.

## Bounded actual-row fixture proposal

Review-only recipe: `/tmp/nextnotes-native-selection-fixture-proposal.md`.
No source or executable fixture was applied or run.

- Reuse actual `Sidebar` under a native NavigationSplitView, actual
  `TranscriptionRow` under the exact inset/alternating native List, and actual
  `MeetingRow` under the exact sidebar-style native List. Use existing selection
  bindings and immutable placeholder models. Do not paint a synthetic black
  rectangle or copy a row body to manufacture the failure.
- Capture no selection, selected active/key/list-focused, and selected inactive.
  Verify the real window/activity/first-responder state; report refused activation
  as unavailable rather than labeling an inactive frame active. Retain exact
  packaged executable SHA and the native resolved background/foreground values.
- Dictation includes plain, edited and corrected rows. `AppliedCorrection` is
  public Codable but has no explicit public memberwise initializer in its module;
  decode sanitized placeholder fixture JSON to the real type rather than exposing
  a new production construction API just for this picture.
- Meeting includes user and provisional titles plus a terminal/status-chip case.
  Completed UpcomingEventRow is private: defer its extra capture until the owning
  file supplies a narrow actual-view factory/authorized visibility seam. A copied
  body is not production-row proof. Never invoke Record-now/calendar actions.
- Minimum content widths: Sidebar 200/230 pt, meeting 220/360 pt, dictation
  560/1000 pt. Use actual fixed Aqua/theme fonts/tint. Freeze decorative motion
  for this color diagnostic and preserve owner-store isolation.

If the selected original fails, repair the **specific foreground producer** using
native selected foreground semantics or the existing parent selection identity.
No second selection model/store, hover-derived selection, new timer, await or
approval is needed. Check the original selected state and its unselected/native
inactive variants after the repair. A global chip recolor needs all actual chip
consumers checked; fixing one list does not authorize making all badges white.

## Inspection source identities

| Source | SHA-256 |
|---|---|
| `UI/Sidebar.swift` | `fadac33ae9da4f608345ab40a1ad2ce68d11c57c244eba4f5773f5e43961d1aa` |
| `UI/Dictation/TranscriptionRow.swift` | `26821bb4c137d2203b7ce3385b3ad385c81cd9eb901ee153e94fad12ff6720d2` |
| `UI/Meetings/MeetingsView.swift` | `5b47d7374b6ab1ee4cdc185e6819306c317153450711408a7f30ed277d84ab23` |
| `UI/MainWindow.swift` | `5f65aea558ea800d47f62d6deb5a9085a0b8fec4790485b6846578dccbc01150` |
| `UI/DesignSystem.swift` | `b0335cf423f1366b13195bb530a3ad564a8667bfabb441a5bf35221f86a3de7c` |

Paths above are relative to `Sources/NextNotes/`. Parallel owners may subsequently
change them; these hashes anchor only this inspection. **Selected-native rendering
remains unverified; no product contrast bug is declared fixed or newly proven.**
