# Next Notes site design system — normative spec

**Status: normative for the Mac app redesign (roadmap UX-11 and everything after it).**
Every value below is copied from the site's code (`src/index.css`, section files,
`components/`, `lib/`). If this document and the site's code ever disagree, follow this
document and report the mismatch to the coordinator — the code then gets fixed, not the spec.

**Fixed light theme is the target.** The `:root.light` values in `src/index.css` are the
palette below. The dark `:root` values are a previous reference theme and are **not**
targets for the app. The app forces light appearance app-wide (UX-11).

## 1. Palette (light — the target)

HSL triplets, exactly as in `src/index.css` `:root.light`:

| Token | Value | Used for |
|---|---|---|
| `background` | `0 0% 100%` | page substrate |
| `foreground` | `0 0% 4%` | ink |
| `card` | `0 0% 97%` | card fill |
| `card-foreground` | `0 0% 4%` | ink on cards |
| `primary` | `0 0% 4%` | filled buttons, active pills |
| `primary-foreground` | `0 0% 100%` | ink on filled elements |
| `secondary` | `0 0% 92%` | user message bubbles, muted fills |
| `secondary-foreground` | `0 0% 25%` | ink on secondary |
| `muted` | `0 0% 94%` | quiet fills |
| `muted-foreground` | `0 0% 40%` | secondary text, captions |
| `accent` | `170 20% 32%` | sparing highlights |
| `border` | `0 0% 86%` | hairlines (usually at 40–60% opacity) |
| `ring` | `0 0% 60%` | focus rings |
| `hero-subtitle` | `210 10% 20%` | hero sub-copy |
| `orb-ink` | `0 0% 4%` | the ONE orb ink (depth comes from radius + opacity, never hue) |

No other hues exist on the page. Status color does not exist on the site — the app keeps
its own rule (red means recording, meters are instrumentation) from AGENTS.md.

## 2. Type

- **Sans:** Inter 400/500/600/700 (`@fontsource/inter`). Everything except display headlines.
- **Serif:** Instrument Serif 400 + italic (`@fontsource/instrument-serif`). Headline accent
  words only, always italic, always inside an otherwise-sans headline
  (e.g. `Be present. *Keep your promises.*`).
- **Tracking scale:** display `-2px`, section `-1.5px`, headline `-1px`, eyebrow `3px`,
  caption `0.14em`. **Leading scale:** display `1.02`, section `1.05`.
- **Usage patterns:**
  - Eyebrow: 12px uppercase, eyebrow tracking, muted ink.
  - H1: 48→96px medium, display tracking/leading, one serif-italic span.
  - H2 (section): 36→72px, section tracking/leading, one serif-italic span.
  - Body: 18px muted, relaxed leading. Micro caps (card labels): 11px uppercase.
  - Buttons/pills: 14px medium, fully rounded.

## 3. Layout

- **Page gutters:** 24px → 32px → 64px → 112px across breakpoints. **Section rhythm:**
  112px → 160px vertical. **Content width:** 1280px max; prose capped at 672/576/512px.
- **Radii:** pills and buttons fully round; inner cards 16px; panels and hero card 24px.
- **Borders:** 1px theme border at 40–60% opacity between regions; cards carry their edge
  via the glass rim (§4), not via border strokes.
- **Primary button:** filled ink pill, `28px × 16px` padding, arrow icon, lifts 3px on hover.

## 4. Glass pane (`liquid-glass` in `src/index.css` — the one surface treatment)

- Fill black at 2% opacity, 4px backdrop blur, top/bottom inner highlight at 8%.
- Edge is a **rim-light gradient**, not a stroke: 1.4px masked border, full opacity at the
  top/bottom lips fading to transparent at 40–60% height, 20% strength with an 8% soft echo.
- **Swift mapping:** reproduce with the system glass material tuned to these values, never
  a CSS-style gradient stroke. Under Reduce Transparency: solid theme surfaces.

## 5. Orb

- Nine states with fixed meanings (table in AGENTS.md §Design system — authoritative,
  never invent a tenth). Dotted lattice, single theme ink, rAF canvas capped at 2x DPR.
- **Sizes:** ambient backdrops 560–640px at 20% opacity behind type; inline marks 22–72px
  beside the status line they belong to. Never scale a rendered orb — pass the size.
- **Still frame:** t=1.7s under Reduce Motion (reads as a diagram, not frozen motion).
- **Rules:** one animating orb per screen; decorative orbs large-and-slow; never animate
  off-screen or finished work. Orb states describe *app work*; the agent's character
  avatar (separate vocabulary) describes *agent* states.

## 6. Beam and voice glow (hero treatments)

- **Border beam** (`border-beam`): full-border glow riding the demo card —
  size `md`, `colorful`, strength `0.7`. Paused off-screen, while the demo is paused,
  and under Reduce Motion; follows the light/dark toggle (always light in the app).
- **Voice glow** (`voice-glow`): sound-reactive glow along the composer box's bottom
  edge — type `default`, strength `0.7`. Driven per-frame (no re-renders); shimmer while
  the demo "speaks", gathered traveling beam while it "works", idle otherwise.
- **Swift mapping:** same placement and timing (glow on the card border, voice glow on
  the composer, work-phase beam); implement with native canvas/layers, not the npm packages.

## 7. Motion

- Entrances: fade + 20px rise, 0.6s ease-out, staggered by ~0.1s down the page.
- Hero demo: three scenes (Catch-up, Office, Cases). Each plays to its end — typing at
  ~34ms/char (a storytelling device — never replay completed text per-character in the app,
  stream real chunks), choices appear only after the question is fully typed — and is then
  held ~3s before the next scene. It waits while hovered or keyboard-focused, while paused
  and while off-screen; under Reduce Motion it shows the finished scene and does not advance.
- Never animate text layout; never move an action button under the pointer; entrance
  reveals fire once. Under Reduce Motion: opacity only, orbs/avatars frozen still.

## 8. Components (file pointers — read before rebuilding any of these)

- `src/components/Orb.tsx` + `orbGeometry.ts` — the mark and its nine geometries.
- `src/components/StatusPill.tsx` — the honest status of one capability: **Available now**
  (filled ink), **In progress** (outline), **Coming soon** (dashed outline, muted ink), each
  with a matching dot so the shape says it as well as the word. One ink, no status hues.
  Two variants: `full` (default) is the pill used with the legend in the persona section and
  on How-it-works steps; `quiet` is small muted text with a dot, no outline, no capitals, for
  places where the dream should lead, such as the hero demo card. `AVAILABILITY_ORDER` and
  `AVAILABILITY_MEANING` drive the legend. A capability is never shown without one.
- `src/components/GetItOnMac.tsx` — the main action. A download button on Mac-sized screens
  (md and up); below that, a softer outlined "Get it on your Mac" that shares or copies the
  page link, with the line "Open this page on your Mac to download." No form, no email.
- `src/components/HeroStage.tsx` — ambient floating cards (16s loop, layout contract).
- `src/sections/Hero.tsx` — request → work → answer → approve → done carousel.
- `src/sections/WhatItDoes.tsx`, `HowItWorks.tsx`, `Mission.tsx`, `Privacy.tsx`,
  `CTA.tsx` — the four people, the four steps, the reveal, the belief, the close.
- `src/lib/personas.ts` — the ONE outcome headline per person, used on the list card, the
  detail panel and the hero demo's closing line.
- `src/lib/motion.ts` (one entrance, URLs), `src/lib/theme.ts` (fixed light, read by the
  orb and the beam).

## 9. System invariants (enforced on the site by lint — hold on the app by review)

No raw colors, no one-off values, no inline styles: every number lives in this system.
A value the system lacks is added to the system, never inlined in a view. In Swift terms:
every one of these lands in `DesignSystem.swift` as a token and views hold no literals
(the existing AGENTS.md rule, unchanged).

## 10. Animation libraries in use

| Library | Version / terms | Where it runs | Settings agents must keep |
|---|---|---|---|
| thinking-orbs (Jakub Antalik, MIT) | ported, not installed — `src/components/orbGeometry.ts` on the site, `OrbGeometry.swift` + vendored licence in the app | all nine orb states, both platforms (same formulas, constants, tempo) | state meanings from AGENTS.md; still frame t=1.7; DPR cap 2 |
| border-beam | 1.4.1, MIT, zero runtime deps | hero demo card border | size `md`, `colorful`, strength `0.7`; pause off-screen/paused/reduced-motion |
| voice-glow | 0.2.1, MIT, zero runtime deps | hero composer box bottom edge | type `default`, strength `0.7`; per-frame level (no re-renders); shimmer while speaking, traveling beam while working |
| framer-motion | 13.x, MIT | entrances, hero scene loop, typing choreography, layout transitions | `fadeUp` 0.6s ease-out stagger; `MotionConfig reducedMotion="user"` (opacity survives, movement goes) |

Swift mapping: reimplement the treatments with native canvas/layers — never the npm
packages. The two MIT libraries are logged in `THIRD-PARTY-NOTICES.md`.
