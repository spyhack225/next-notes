# UX-11 final caller adoption checkpoint — 2026-10-01

## Implemented and frozen

The coordinator released a bounded source slot. The six approved caller/layout
files now consume existing theme components, with canonical API edits coordinated
separately. No canonical DS/ThemeHeadline/SectionHeading source was changed by this
worker. All six current inputs matched their reviewed hashes before applying the
narrow patches; original files are retained in
`/tmp/nextnotes-ui-final-theme/integration-before/`. The exact applied diff is
`integrated-owned.patch`; frozen hashes are `integration-frozen-hashes.json` there.

- Agent empty prompt retains “What can I help with?” with an explicit italic closing
  phrase. Activity says “Your companion’s activity,” using the shared optional accent.
- Settings supplies explicit static spans through its one heading producer; recomposed
  text matches all 12 original headings exactly. It uses compact `.pane` at the existing
  36pt H2 minimum, rather than the 54pt section default. Native Forms remain unchanged.
- Actual running work without inline approval or yielded state gets the existing
  border treatment. The composer gets the existing working bottom-edge treatment
  only while busy and neither approval gate is pending. Both treatments are **still**.
  The agent avatar retains the live clock; no extra/offscreen timer, audio level,
  speaking claim, waiting ceremony or controller behavior is introduced.
- Root-owned pending task sections, send/stop/approval handlers and history are unchanged.

## Verification and limits

`git apply --check` accepted the narrow patches before applying them;
`git diff --check` on all six files exited 0. A preparation assertion proved exact
recomposition of every current Settings heading. No compiler, build, native self-test,
render capture or latency measurement ran in this worker's source slot.

Required canonical APIs are `ThemeHeadline.Level.pane` and
`SectionHeading.accentLevel` (default `.section`); the canonical owner is integrating
those separately. Packaged compilation and the real Settings/Agent captures remain
required before accepting wrapping, band height, accessibility, font identity or
absence of clipped controls. Existing setup images and app9 leaves do not prove
these new caller changes.

Static edges port placement/color and consume real busy state. They do **not** prove
the website's moving border and work beam have been fully adopted. Animating either
requires an explicit handoff from the current live avatar plus verified viewport
admission and rendering/latency evidence; this checkpoint adds no duplicate clock.
The later canonical integration pins island substrate/ink to the owner-approved
white/black theme; notch and floating-display live acceptance remain open. No roadmap item is closed by this checkpoint.

## Canonical body type proposal (not applied here)

`/tmp/nextnotes-ui-final-theme/04-canonical-body-fonts.patch` proposes the shared DS.Font
body/title/callout/headline/etc. aliases consume registered Inter through
Typography.sans at native preferred text-style sizes, with relative SwiftUI text
styles. Computed aliases avoid permanently latching a fallback before launch font
registration. Rounded digit counters and monospaced timestamps retain their existing
metrics. SDK source inspection confirmed the used native text-style constants and
relative font API; compile, font identity, wrapping and accessibility scaling remain
gates. This is the canonical owner's proposal, not a worker-applied DS change.

## Canonical and root-host integration follow-up

Canonical six-file owner implemented compact pane headline support, configurable
SectionHeading accent level, fixed-white island aliases and MainActor-only font
registration. It explicitly handed DesignSystem back to the UI root for the
reviewed semantic Inter adapter. That adapter is now integrated: computed DS.Font
aliases resolve registered faces at existing native preferred text-style sizes,
with SwiftUI relative text styles; missing fonts retain native system styling.
Rounded counters and monospaced timestamps keep their original metrics.

Main window, Settings, island, HUD and meeting-console roots inherit DS.Font.body
for SwiftUI text that has no explicit font. All shared type helpers and font names
stay in DS. Native AppKit-controlled menus/control labels still need observed font
and tint verification. These source changes are not a packaged-render verdict.

Onboarding now has a concise single-companion welcome and the account/local-default
reassurance before identity choices, addressing the initial-viewport clipping
observed in app12. The original 28 images are retained. Its capture diagnostic now
separates Reduce Motion and Reduce Transparency (56 combinations) to investigate
the black standard viewport; production glass, ScrollView and runtime behavior
were not replaced to make offscreen images look correct.

All UI Swift and the canonical owner's six files are re-frozen for the next serial
build. Current hashes are in swift-freeze-2026-10-01.json. Full diff whitespace
check passed. No build, native diagnostic or UI interaction ran in this source slot.

## Installed checkpoint — 2026-10-02

The later packaged app13 passes the focused typography/onboarding, UI string, Settings, Agent pane and presentation checks. App19 additionally passes56 onboarding shell generation and the corrected durable-owner comparison, including an actual persistent-write negative; archived by `6dc9343`. This supersedes the earlier source-only status of those specific checks. Standard offscreen glass still captures black; readable Reduce Transparency samples are not a standard-composition verdict. Full Settings capture isolation, native layout/focus/VoiceOver, moving beam adoption and measured visible-feedback/voice latency remain open.
