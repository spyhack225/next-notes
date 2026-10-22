# UX-11 foundation / UX-09 onboarding adoption — 2026-10-01

## Status

Implementation checkpoint, **not release sign-off**. The 2026-10-01 owner decision in
`AGENTS.md` §Design system and `site/DESIGN-SYSTEM.md` is the reference: fixed light
appearance, black ink on white, sans headlines with one italic serif accent, dotted
orb backdrops and glass. Onboarding is the first adoption slice.

The coordinator owns the shared `DS.Theme`, `ThemeFixed` and theme components. This
worker changed only `OnboardingChrome.swift`, `OnboardingWindow.swift` and the visual
parts of `OnboardingSteps.swift`. No controller, permission, model, identity store,
registry, task or audio producer was changed here.

## Adopted on the seven real setup screens

- All seven headlines consume `ThemeHeadline.Level.onboarding`: existing theme H2
  minimum (36pt), sans lead plus serif italic phrase, shared ink/tracking/leading.
  Welcome names one familiar companion on this Mac; final setup still branches on
  the actual `OnboardingOutcome.canDictate` value. It does not announce delivery.
- White substrate, theme foreground/muted/subtitle ink, and native filled ink capsule
  buttons consume the established palette. Permission checks, warning text and
  verified practice success retain their status meanings.
- Grant, shortcut, folder and final-summary cards use the same `themeGlass` adapter.
  The adapter's existing Reduce Transparency branch draws a solid theme card.
- The dotted backdrop is explicitly above the substrate, with theme size/opacity/ink,
  and still. The old modifier was attached behind a view that itself painted an
  opaque window fill, so source composition placed the orb behind that fill. The
  new composition makes its place unambiguous; an actual rendered comparison is
  still required before calling the visual defect verified fixed.
- The explanation and cards scroll in the existing 720×600 setup shell. Primary and
  Skip actions stay outside that scroll, with progress dots and navigation in their
  existing positions. This allows the larger headline and longer permission hints
  to fit without moving Continue as content changes.
- Grant and progress-dot layout transitions now honor Reduce Motion. Step reveals
  use the shared theme entrance token with the existing Reduce Motion guard.

## Runtime boundaries preserved

The seven-step switch, progress persistence, back/forward admission, Skip,
permission requests and refresh loops, model-download lifecycle, hotkey choices,
identity generation/saving, folder selection, Escape and Done behavior remain.
There is no new timer, wait, artificial typing, automatic conversation, synthetic
receipt or delivery promise. The separate delivery owner still owns the actual
practice receipt hookup.

The still backdrop avoids a second live clock alongside the welcome avatar or the
real practice-stage mark. Existing permission rows can each display a breathing
orb while waiting; simultaneous waiting rows still need the global one-live-mark
review. This checkpoint does not prove that every screen's animation budget is met.

## Verification performed

- Inspected the actual current theme, seven-step call sites, outcome producer and
  native window composition before edits.
- Reviewed the resulting source diff for behavior changes and token call sites.
- `git diff --check` for the three owned files: exit 0.
- No compiler, build or native self-test was run by this worker. The separate
  AGENT-OVERHAUL coordinator holds the serial compiler/install/test slot.

Source review is not proof of rendered layout, VoiceOver, key focus or appearance.
No roadmap item is marked done by this report.

## Frozen inputs for the integrated build

| File (under Sources/NextNotes/UI/Onboarding) | SHA-256 |
|---|---|
| OnboardingChrome.swift | `006d0c7fa65cc586f2b350d0c6d04b8d7c8be8d887786e0c9587af2b2699bb25` |
| OnboardingWindow.swift | `5a610676a9b70c99353fb8f3f172cb29d500f62c611abe7a71ba7355f909c659` |
| OnboardingSteps.swift | `80c52bbdc43f52d5f811c028e7cf7137d53899be09a77022719a8ff05b944d6f` |

These hashes pin this visual adoption checkpoint. The delivery owner may later
change Steps through its separately coordinated production receipt handoff.

## Required acceptance next

1. Serial packaged build; `--selftest-onboarding`, `--selftest-guided`,
   `--selftest-settings`, `--selftest-ui-strings`, and the UX-01 foundation flag list.
2. Capture and inspect all seven screens at 720×600, including denied grants,
   stale-typing guidance, longest folder list, missing space and interrupted model
   setup. Check Continue/Skip, progress dots, scroll access and navigation.
3. Keyboard and VoiceOver pass: title reads as one phrase, cards announce actual
   grant values, permission controls and practice field are reachable, and focus
   survives the OS permission round trip. Resume setup after closing it.
4. Inspect reduced motion/transparency and increased contrast, with the Mac set to
   dark appearance while the app stays fixed light. Confirm shared appearance
   registration also reaches setup and sheets; local token adoption alone does not
   prove the application-wide forced-light contract.
5. Verify one real practice insertion through its actual delivery producer; verify
   copied/failed/manual/outside-field input never produces a success badge.
6. Review foundation font fidelity: current shared theme uses system sans and
   system serif, not the site's exact Inter/Instrument Serif glyphs. This is an
   explicit visual limitation, not evidence of an exact font port. No new font or
   license conclusion was introduced by this worker.
7. Live feedback, canvas and latency measurements remain the UX-10 gate.

## Integrated compiler corrections

Build6 reproduced two source contract failures: the headline referenced a missing direct foreground token and nested `Type` conflicted with Swift metatype syntax. The palette consumer now uses `Palette.foreground`; the typography namespace and its actual consumers use `Typography`. The duplicate `Theme.Glass` declarations were merged without changing values.

Build7 reached the border beam and failed because SwiftUI `Angle` has no `turns` constructor. The actual gradient producer now converts turns to radians (`turns × 2π`), preserving the complete sweep and parked position. The original logs are `/tmp/nextnotes-agent-closure-install-6.log` and `...-7.log`; the corrected integrated build remains pending. No tests or compile ran in this UI worker. Frozen source hashes are in `swift-freeze-2026-10-01.json`.

## Prepared full onboarding capture (not integrated)

2026-10-01 follow-up: `/tmp/OnboardingSheet.swift` and
`/tmp/nextnotes-onboarding-sheet-proposal/bounded-seam.patch` are prepared for the
coordinator's review after the serial freeze is released. No Sources files were
modified and no compiler was run for this preparation.

Rendering live steps under SelfTest alone is unsafe: Dictation/AllSet refresh can
arm the hotkey; Meetings/Brain `.task` run refresh/poll loops; practice takes focus.
One optional immutable diagnostic environment input, refused outside SelfTest,
selects the seven actual step views and suppresses those effects while feeding
placeholder consumer inputs. Production state/effect producers remain unchanged.
The proposed renderer uses the actual `OnboardingFlowView` full shell, native
window/titlebar geometry, footer and navigation at 720×600. It prepares 28 captures
(all seven × allowed/not-allowed × standard/reduced motion/transparency), checks
watched owner stores, all preferences and the owner folder-list file, refuses
Application Support output, and never orders a window, grants permission or records.

See `/tmp/nextnotes-onboarding-sheet-proposal/REVIEW.md` for safety boundaries,
registration and caveats. Integration, compile and image inspection remain pending;
the proposed diagnostic is no evidence of a rendered pass yet.

## Integrated diagnostic checkpoint (supersedes prepared-only status)

The coordinator released the three-file source slot after the delivery worker
froze. The diagnostic is now `UI/Onboarding/OnboardingSheet.swift`; bounded fixture
hunks were applied to the current Steps/Window sources, preserving the new hold-ID
receipt observers, calendar post-grant beat and static labelled approval example.
Explicit fixtures do not register/remove hold callbacks, consume receipts or take
practice focus. The calendar beat is hidden only for diagnostic fixtures so no
owner event can appear in output. Outside SelfTest the environment accessor returns
nil, so all production paths retain their behavior.

Static inspection confirmed `OnboardingStep` and `OnboardingOutcome` are Sendable,
all used step constructors and controller properties exist, CalendarService's
initializer starts no polling, and model preparation remains invoked only by the
existing effect paths. The diagnostic uses the actual seven-step switch; no
alternate onboarding layout or persisted fixture model was introduced.

Current frozen inputs (supersede the earlier per-file hashes):

| File under UI/Onboarding | SHA-256 |
|---|---|
| OnboardingSheet.swift | `aa58b41198c7a6bf20bc8124e215b838dce756b484270ef9fde42c99ee17f5bf` |
| OnboardingSteps.swift | `908eb854730c6a309eb02c76c9314ea650822f8a6c4d64af0c7cb06bb44ac41b` |
| OnboardingWindow.swift | `d987ad3c293a093dc5295949d78ca3e0726921b80e519298c5bab00bee4da477` |

`git diff --check` for the integrated files exited 0. No compiler/build/native flag
ran in this worker slot. Root-owned registration is prepared in
`/tmp/nextnotes-onboarding-sheet-registration.txt`, matching current
`runRequestedSelfTest() -> Bool` conventions and requiring an explicit output path.
`ONBOARDING_SHEET_OK` remains an image-write/isolation verdict, not a visual,
keyboard, scroll, VoiceOver or live first-success pass. The packaged build and all
28 rendered images still need verification.

## App10 freeze checkpoint (supersedes earlier pending-build and font fallback notes)

App9 packaged build and all eight focused UI checks passed, with 72 isolated leaf
images written. That binary predates the current shared palette, actual bundled
font registration and full onboarding diagnostic. Its dark-environment captures
are not evidence of the current fixed-light contract.

The current source packages six Latin-subset Inter/Instrument Serif TTF faces and
both original OFL notices. Makefile copies the single ThemeFonts bundle directory.
ThemeFixed registers once before windows, checks each actual resolved PostScript
identity and reports failures rather than silently claiming a system fallback is
the requested face. Repeated diagnostic apply calls retain that first result.
Canonical ThemeFixed hash: bc2ec60e10a9015d6211cf62ad1b8b4d1542861f4cbeac94320eb5230cc518c0.
The launch-only registration cache is explicitly nonisolated(unsafe); registration
has no conversational await, timer, actor hop or per-view font installation.

All UI sources are frozen for the separately coordinated app10 build. Its existing
onboarding flag and new onboarding-sheet registration now require all six packaged
font files, both OFL files, exact resolved font identities and no registration
failures before an OK marker. Results are pending.

The app10 sheet diagnostic forces Aqua after both requested OS appearances. This
checks a process-local forcing contract, not the owner's actual OS dark setting.
No owner appearance setting is changed. Manual native menus, file-picker tint,
VoiceOver, keyboard focus and actual physical insertion remain unverified.

Readonly full-theme audit also found concrete implementation work remaining:
SectionHeading's optional accent has no callers outside onboarding; beam and voice
glow components have no production consumers; the island substrate still uses
black/white bezel-continuity aliases. These are open adoption tasks, not merely
missing screenshots. A small follow-up proposal is being prepared outside Sources
while the serial build freeze is held.

App10 first compile reproduced an actual SDK binding failure in ThemeFixed: the C constant `kCTFontManagerErrorAlreadyRegistered` is imported as the typed Swift case `CTFontManagerError.alreadyRegistered.rawValue`. Corrected only that producer expression against the installed SDK header. Refrozen hash: ed20b010ce895d678f24180e32a39a9f1cd867a7c16cbf24297616c965ab7bb4. Original red: /tmp/nextnotes-agent-closure-install-10.log. Coordinated rebuild remains pending.
