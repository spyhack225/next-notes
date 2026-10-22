Now turn this into a proper macOS application.

Not a menu bar utility. A real app: dock icon, app menu, a standard resizable window,
a Settings window on Cmd+comma, and a double-clickable .app I can keep in
Applications. Drop LSUIElement.

Keep a menu bar item as well, for status and the hotkey while I'm working in another
app - but it is secondary now, not the whole interface.

The main window holds:
- Past transcriptions, searchable, with copy on each one.
- The live level meter while recording.
- Start and stop.
- A Dictionary.

Settings holds the hotkey and the model.

THE DICTIONARY

A place I can teach it words it keeps getting wrong - names, jargon, product names,
the people I work with. Add, edit, delete, and search. It should persist and be
editable as a plain file as well as in the UI.

Two entry types:

1. A word or phrase I want it to know. "Anthropic", "Vercel", "Supabase".
2. A correction pair - when you hear X, write Y. "cloud code" becomes "Claude Code".

Implement both mechanisms, because one alone is not enough:

First, bias the engine before it transcribes. Pass my dictionary words to the
speech engine as context so it leans toward producing them - whatever the engine
supports for this. Keep the list short when you pass it; long context makes these
models drift and invent text on quiet audio.

Second, run a correction pass on the text afterward. Whole-word, case-insensitive,
longest match first. This is the guaranteed path - biasing is a nudge, not a
promise, and it will not catch everything.

The correction pass must handle words the model glues together. If I add "Claude
Code" it has to catch "CloudCode" and "Cloud-Code", not just the spaced version.
Match on optional whitespace or hyphen between the parts.

Be careful not to corrupt real words. A correction for "Claude Code" must never
touch "Cloudflare" or the ordinary word "cloud". Require the full pattern, and show
me a warning in the UI if an entry I add looks like it would match something common.

In the transcription history, show me when a correction fired and what it changed,
so I can tell whether the dictionary is doing anything.

Before you write any of it, define a design system and write it down as tokens I
can point at later - color, type scale, spacing, corner radius, border, shadow,
motion. Every view pulls from those tokens. No one-off values in the components.

The direction is 1980s tape recorder. Portable field recorders and cassette decks -
Sony TC-D5, Marantz PMD, Nakamichi, Braun. What that means concretely:

Brushed aluminum and matte plastic surfaces. A muted palette - warm greys, off-black,
cream, silver. One accent only: the red of a record light. Amber or green for level
indicators.

Physical controls. Buttons that look pressed rather than tinted. Real depth, hard
edges, visible seams between panels.

Silkscreen-style labels. Small, uppercase, tightly tracked, in a neutral grotesque.
Segmented or monospaced numerals for counters and timings.

The recording indicator is a VU meter with a needle, not a progress bar. Level and
waveform read as analog instrumentation.

Restraint over decoration. This should look like equipment, not like a theme.

Do not use neon, vaporwave, synthwave, purple-and-pink gradients, glowing text,
chrome lettering, or grid horizons. That whole aesthetic is overused and it is not
what I am asking for. This is the sober, industrial side of the eighties.

Show me the design tokens first and let me approve them before you build the views.

The engine stays exactly as it is. This is the interface layer only.
