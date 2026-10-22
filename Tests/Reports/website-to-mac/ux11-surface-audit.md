# UX-11 surface adoption audit — 2026-10-01

Read-only source audit during the root's serial install 8. No Swift edits, compilation,
native tests, or new captures were performed. This is an implementation proposal, not
visual or accessibility sign-off.

## Contract and current gap

AGENTS.md §Design system's 2026-10-01 owner decision supersedes its older native-colour
paragraphs: fixed light, one shared site palette, serif-italic headline accents, and site
glow treatments on every surface. Native control semantics, recording red, meter colours,
one live mark, Reduce Motion/Transparency, and latency requirements remain binding.
`site/DESIGN-SYSTEM.md` is normative; the roadmap forbids a second theme or per-surface
restyle. Existing source does not yet satisfy the whole-surface contract.

- `ThemeFixed.apply()` sets `NSApp.appearance = .aqua` at launch. This pins appearance;
  it does **not** replace the user's accent. Onboarding sets `.tint(primary)`, but the main
  window, Settings, island and HUD roots do not.
- `DS.Color.text/window/content/groupedFill/separator/selection/accent` still resolve to
  system colours. `DS.Theme.Palette` currently forms a parallel palette used mainly by
  onboarding. Existing consumers need aliases to the same palette, not local replacements.
- `GlassSurfaceModifier` still returns a `Material` under Reduce Transparency. The new
  `ThemeGlassModifier` repeats the renderer and supplies the required solid fallback only
  to its own callers. Existing review/work/HUD/floating-island surfaces remain on the old
  branch. `DS.Material.surfaceGlass/hudGlass` are still untinted `.regular`.
- `SectionHeading` and `AgentPaneHeader` remain plain sans headings. Only onboarding uses
  explicit `ThemeHeadline(lead:accent:)`. Applying a global serif font to all headings would
  lose the site's mixed-family rule and affect arbitrary meeting titles/status labels.
- Existing `OrbBackdrop` defaults still use `DS.Size.orbBackdrop` and
  `DS.Opacity.orbBackdrop`, not the site's new backdrop tokens. Existing fields already
  draw once and should remain static. Several section roots have neither backdrop nor
  field; adding a universal animated background would violate the live-mark budget.
- The coordinator observed orange `DS.Color.warning` paragraphs on white in the existing
  dictation-failed and missing-review diagnostic images. Source confirms warning resolves
  to `.systemOrange`. These images are inherited evidence, not a capture made by this audit.

## Small shared producer changes first

**One owner: `UI/DesignSystem.swift`, `UI/Components/GlassSurface.swift`,
`UI/Components/Theme/ThemeGlass.swift`, `UI/ThemeFixed.swift`.**

1. Make existing DS colour names consume `DS.Theme.Palette`: foreground for text,
   mutedForeground for secondary/placeholder, background for window, card for content,
   muted/secondary for grouped/user fills, theme border for separator, theme primary or
   defined theme selection for active controls. Keep muted text readable; do not preserve
   very faint tertiary system text by opacity alone. Change `DS.Color.accent` to the fixed
   theme control colour; use the site's teal only as its explicitly sparing accent.
   Status warning/success/info should use dark theme ink with their existing word/icon
   carrying meaning. Preserve record/meter instrumentation colours. Graph/speaker category
   colours are data encoding; review their contrast separately rather than removing their
   identity accidentally in a chrome migration.
2. Make `DS.Material.surfaceGlass` and `hudGlass` consume `DS.Theme.Glass.tinted`. In the
   **existing** GlassSurface producer, use `DS.Theme.Glass.solidFallback` for Reduce
   Transparency. Inventory the current `fallback:` arguments before changing the public
   signature; remove the unused material override only if there are no actual consumers.
   Make `.themeGlass`/`ThemeGlassCard` thin delegates to `.glassSurface`/`GlassCard`, or
   migrate callers and remove the duplicate adapter. One renderer owns this rule.
3. Theme the few material bypasses through the existing seam: `AgentInspector.swift:90`,
   `ComparisonView.swift:322`, and `Dictation/CommandModeStatus.swift:135`. Do not change
   `DS.Material.card` from Material to Color blindly: its typed consumers must be traced.
4. Aqua forcing must be combined with theme tint at each existing SwiftUI root/host.
   MainWindow tint covers its descendant controls and sheets; standalone Settings,
   onboarding, meeting-console, HUD, island and menu hosts need the same existing token.
   Do not create an accent preference, observer, or persisted theme setting. Native
   AppKit-owned menu/file-picker highlights may resist SwiftUI tint; test that explicitly
   rather than claiming Aqua controls the user's accent. Preserve focus rings/keyboard
   semantics. Fixed theme does not justify custom replacement controls.

## Reusable heading adoption

**One owner: `SectionHeading.swift`, `ThemeHeadline.swift`, `AgentPaneLayout.swift` and
headline type tokens in DS.** Add an optional explicit accent span to the existing heading
contract; caller supplies lead and accent as separate strings. Compose one accessible
`Text`, as ThemeHeadline already does. No splitting by last word, punctuation, localized
text, tool output, or meeting title. Preserve default plain heading for dynamic content.
Provide a compact pane scale through DS rather than using ThemeHeadline's 54-point section
default in every pane: Settings can be 340 points wide and meeting detail 360 points wide.
Do not impose website page gutters/section heights on an existing responsive native form.

Concrete static callers:

| Surface | Existing seam / explicit proposed headline spans | Ownership |
|---|---|---|
| Agent conversation | Existing heading/empty state: `One companion.` / `Across your life and work.`; body retains capability-honest starters | `AgentView.swift`, preserve pending/task/stream branches owned by Agent-overhaul |
| Activity | AgentPaneHeader: `Your requests.` / `What happened next.` | `ActivityView.swift`; freeze its heartbeat while idle and use the agent avatar for Agent work, rather than a constantly animated searching orb |
| Settings | SettingsPane header: tab supplies explicit heading/accent metadata; e.g. General `The keys` / `you hold`, Formatting `How your words` / `land`, Integrations `The apps` / `you reach` | `SettingsChrome.swift`, `SettingsWindow.swift`; preserve responsive grouped Form machinery |
| Meetings | Static before/after framing `Be present.` / `Keep your promises.`; console section headings may provide explicit short spans | `MeetingsView.swift`, `MeetingConsoleSheet.swift`; retain arbitrary saved meeting title as plain text in MeetingDetailView |
| Dictation | Static empty-state framing `Your words.` / `Ready where you need them.` | `DictationView.swift`; status/counter/error/retry text in DictationStatusBand stays literal state-driven sans |
| Island/HUD | No giant serif headline in narrow status chrome; consume shared ink/glass and compact type, keep exact state label/action stable | `IslandView.swift`, `HUDView.swift`, `CommandModeStatus.swift` |

The proposed wording is presentation copy, not evidence that every Agent/call/message
capability is shipped. The current Agent heading “Your Mac is the only agent you need”
also deserves replacement with the single-companion positioning.

## Decoration and animation budget

Use the existing `.dottedField` and a **still** `.orbBackdrop(.breathing,isAnimated:false)`
on idle section framing; central DS aliases carry the new ink/size/opacity. During actual
work, existing avatar/orb remains the single live mark. Do not add ambient clocks to lists,
Settings cards, or history rows. For the website beam treatment, overlay the existing
primary working card or composer with `ThemeBorderBeam(isAnimated:false)`/idle voice glow
first: the treatment can be present without a second animation clock. A live beam/glow
requires an explicit animation-budget handoff from the existing work mark; neither should
animate concurrently with it by default. Real playback-level wiring belongs to the existing
audio producer; do not invent speaking state, add an observation hop or audio channel.

The notch substrate is an unresolved contract conflict: newer rules say fixed-light on
every surface while older comments preserve black bezel/white ink. Do not quietly leave
the old exception. Minimal full-theme adoption aliases island substrate/ink to shared
light background/foreground and preserves notch geometry/camera gap; verify on a notched
Mac. Floating island inherits the shared glass fallback.

## Remaining API/spec issues and proof

- Glass blur/rim/fill numbers are not exposed by the native Glass API. Current tinted
  regular glass is a documented approximation; unused numeric rim tokens are not proof
  those values render. Keep native glass per the spec, no second CSS gradient renderer.
- Normative palette says no other hues, while §6 requires the colourful beam. New beam
  anchors are a guessed blue/violet/pink preset, not a demonstrated package match. Report
  this spec ambiguity; never interpret pink glow as recording or use it for status text.
- DS typography currently substitutes system sans/serif for Inter/Instrument Serif. Its
  comment asserts a licensing restriction, but this audit has not verified font licensing.
  Exact family distribution remains unresolved; do not claim visual identity is exact or
  request licensing payment based solely on that comment. Keep families centralized.
- Fixed headline sizes/tracking need wrapping and larger-text review. Appearance forcing
  does not establish accessibility contrast. The ring token and muted/tertiary text need
  rendered contrast checks, especially glass over another app.
- After the shared producer changes, root serial build and existing UI gates must run;
  render current Settings/experience/console sheets, then inspect small/large windows,
  alternate OS accent, Reduce Motion/Transparency, keyboard/VoiceOver, actual Agent review,
  meeting capture, dictation insertion and island/HUD. No screenshot, source audit, or
  passing helper substitutes for those live/latency gates.

Recommended coordination: one shared-foundation owner first; then three disjoint surface
owners (Agent/Activity, Meetings/Dictation, Settings/Island/HUD), with root retaining shared
DS/registry/serial build authority. All adopt the same producers; no surface owns a palette.
