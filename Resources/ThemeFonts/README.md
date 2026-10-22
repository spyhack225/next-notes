# App theme fonts

Inter and Instrument Serif from the existing Fontsource 5.3.0 packages. The six local Latin WOFF TrueType fonts were unwrapped to TTF using installed FontTools: `TTFont(input); font.flavor = None; font.save(output)`. Glyph outlines, character maps and PostScript names are unchanged. No network fetch or app-time conversion is required.

`manifest.json` records the source and output SHA-256 hashes. Exact copyright and OFL 1.1 texts accompany the fonts. The app registers them for its own process; no file is installed in the user’s Fonts folder. Latin-subset coverage uses system fallback for other scripts.
