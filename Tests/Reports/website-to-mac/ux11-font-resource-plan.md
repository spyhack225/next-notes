# UX-11 actual font reuse — local preparation, 2026-10-01

No Sources, Makefile, Package.swift, or repo resource files changed; no Swift compiler,
native font registration test, or dependency download ran. Existing local FontTools
converted six local WOFF files to temporary TTFs. This plan supersedes the unsupported
DS comment that Instrument Serif cannot ship because there is no licensed app font.

## Evidence

- Both `site/node_modules/@fontsource/inter/LICENSE` and
  `site/node_modules/@fontsource/instrument-serif/LICENSE` contain SIL OFL 1.1, including
  the copyright and bundling/embedding/redistribution terms. Both installed packages are
  version 5.3.0. `THIRD-PARTY-NOTICES.md` already identifies these fonts under OFL.
  No extra font purchase is indicated by these local files. Preserve their exact licence
  texts; this is resource provenance, not legal advice.
- No TTF/OTF is currently tracked in the repo. Local web assets are WOFF/WOFF2. The WOFF
  files hold TrueType outlines (`sfntVersion = 0x00010000`, `glyf` table). Using the WOFF
  container directly in CoreText has **not** been verified. The smallest reliable proposal
  avoids that uncertainty: unwrap local WOFF to TTF once and commit the resulting resources.
- `/opt/anaconda3/bin/fonttools` and its Python module already exist. No Brotli dependency
  is required because the input is WOFF, not WOFF2. Conversion is `TTFont(input)`,
  `font.flavor = None`, `font.save(output)`. No glyph/name/outline editing or font merge.
- The six temporary TTFs total 343,860 bytes. FontTools reread each output; cmap and
  PostScript name match its input. English headline text, curly apostrophe/em dash and
  accented examples `café naïve résumé` are covered. These are Latin subsets: this is
  **not** a full-script coverage claim. System glyph fallback remains necessary.

Prepared directory:
`/var/folders/ht/g5rsvv5x27124qp6wn2sg27w0000gn/T/nextnotes-theme-fonts-rvpins5u`
contains six TTFs, exact `inter-OFL.txt`/`instrument-serif-OFL.txt`, and `manifest.json`
with input/output hashes. Parent can copy these after the source freeze is released.

| Local input under `site/node_modules/@fontsource/<family>/files/` | Proposed resource | Exact PostScript name |
|---|---|---|
| `inter/inter-latin-400-normal.woff` | `Resources/ThemeFonts/Inter-Regular.ttf` | `Inter-Regular` |
| `inter/inter-latin-500-normal.woff` | `Resources/ThemeFonts/Inter-Medium.ttf` | `Inter-Medium` |
| `inter/inter-latin-600-normal.woff` | `Resources/ThemeFonts/Inter-SemiBold.ttf` | `Inter-SemiBold` |
| `inter/inter-latin-700-normal.woff` | `Resources/ThemeFonts/Inter-Bold.ttf` | `Inter-Bold` |
| `instrument-serif/instrument-serif-latin-400-normal.woff` | `Resources/ThemeFonts/InstrumentSerif-Regular.ttf` | `InstrumentSerif-Regular` |
| `instrument-serif/instrument-serif-latin-400-italic.woff` | `Resources/ThemeFonts/InstrumentSerif-Italic.ttf` | `InstrumentSerif-Italic` |

Put exact package licence texts in that resource directory. Add a short provenance file
with package versions, source names, conversion command and manifest; note format
conversion and Latin-subset coverage. Update the app font entry in THIRD-PARTY-NOTICES,
without reducing OFL terms to the existing inaccurate shorthand “do not rename them.”

## Small integration through current seams

1. **Makefile, existing app resource-copy stanza:** copy `Resources/ThemeFonts` to
   `Contents/Resources/ThemeFonts`, next to NotionAvatar/MeetingEditor. This automatically
   carries fonts, exact licence and provenance through app/install/release/dmg and signing.
   No new build dependency or per-build conversion. `Package.swift` currently does not
   package executable resources; introducing a SwiftPM resource bundle/Bundle.module
   solely for these six fonts would add a second resource path unnecessarily.
2. **`UI/ThemeFixed.swift`:** at the existing one-time launch theme setup, before windows
   appear, register each bundled TTF through `CTFontManagerRegisterFontsForURL` with
   `.process` scope. Fonts are app-local, never installed in the user's Fonts folder.
   Registration is synchronous launch work (~344 KB), not on a conversational/voice path.
   Handle registration failure visibly in diagnostics and retain the existing system
   fallback; do not silently call a missing custom face an exact-font pass. A duplicate
   registration is acceptable only if the expected face is actually available.
3. **`UI/DesignSystem.swift` only:** centralize exact PostScript names and map `.regular`,
   `.medium`, `.semibold`, `.bold` to the four Inter files. Typography helpers use
   `Font.custom` with semantic `relativeTo:` styles where appropriate. Add an explicit
   serif-italic helper using `InstrumentSerif-Italic`; avoid relying on `.italic()` to
   synthesize a face. Existing `ThemeHeadline` consumes that helper. Body sizes/semantic
   text style behavior remain separate from the large website display sizes.
4. **Bare self-test binaries:** lack the Makefile .app resources. Either tests explicitly
   pass the repo font directory through an existing diagnostic seam, or they report fonts
   absent. Do not search arbitrary working directories in production or pretend a bare
   source test proves font bundling. Installed app font tests should use Bundle.main.

Required proof after root releases the compiler slot: packaged resources/licences exist;
native registration succeeds; CTFont reports the exact six PostScript names rather than
fallback; actual headline renders use real InstrumentSerif-Italic; four Inter weights
remain distinct; Latin coverage/fallback and larger-text wrapping are legible in Settings,
Agent and onboarding. Keep registration errors and resource absence testable. No native
font or rendered-output pass is claimed by this preparation.
