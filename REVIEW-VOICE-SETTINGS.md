# Review: Voice settings and written-answer lines (claude2/voice-settings-ui, round2 shots)

**Verdict: APPROVE WITH FIXES.** Structure is right: two voices only, plain failure with Retry, text-only fallback, no Apple voice, no red. The fixes are copy and hierarchy.

## Findings

1. **P1, voice-kokoro-unavailable.png: version numbers, and a chosen tile that cannot speak.** "doesn't work on macOS 26.4 or 26.5 ... needs macOS 26.6 or later" appears three times (tile, body, footer). Kokoro keeps the blue chosen outline and "Heart" while unusable.
   - Warning: "Kokoro needs a newer version of macOS. Choose Pocket to hear replies."
   - Tile subtitle: "Needs a newer macOS". Drop the footer copy.

2. **P1, every image: the footer is one static sentence that is wrong in most states.** "Pocket downloads once, about 550 MB. Until a voice is ready, answers show as text." It names Pocket while Kokoro is selected, repeats the status line, and quotes a size. Show only "Pick a voice, then hear a sample." when ready, and nothing otherwise. Sizes are inconsistent too: "About 550 MB" vs "A small download". Use the same form for both, only where a download is about to start.

3. **P1, voice-text-only-lines.png.**
   - "Download a voice to hear replies." contradicts the auto-download on a fresh Mac. Suggested: "Your voice isn't on this Mac yet, so answers are in text. Voice settings".
   - The black notch box truncates: "...You can read the answer her…". If the real card does this, the point is lost. Suggested: "Voice is getting ready. Answer is here."
   - "Voice settings" is the same grey as the sentence and does not look like a link.
   - Confirm live that only one line shows at a time, it clears when the voice is ready, and it does not repeat per answer.

4. **P2, voice-failed.png and voice-kokoro-failed.png: wording is good, Retry is weak.** "Your voice couldn't start / Answers show as text for now" is right. Retry is a small grey pill, the same weight as secondary buttons. Make it the prominent button. The tile says "retry below" but Retry is beside the text: use "Couldn't start · tap Retry". Add the same warning glyph that the unavailable state has, so state is not text-only (orange, not red).

5. **P2, voice-preparing-progress.png: the bar claims more than is known.** It sits at about 40% with no label, and the report says the backend exposes no numeric progress. Use an indeterminate bar or none. Fill and track are both low-contrast grey. The tile ("Getting ready…") and the line ("Getting your voice ready…") say the same thing twice.

6. **P2, all images: nothing says how Pocket and Kokoro differ.** A parent cannot choose between two brand names. Add one plain phrase per tile, based on the real difference. "4 voices · tap to download" also implies the tile downloads, while a separate "Download voice" button exists. Two paths for one action.

7. **P2: tile selection is colour-only (blue outline).** Add a check mark, as the voice pills already have. These renders are dark, but AGENTS.md says the theme is fixed light. Confirm the blue and green are tokens and read well in light.

8. **P3: small grey text.** Tile subtitles and the sample hint (the greyed "Alba", "Kokoro · Heart") are about 13px grey on dark grey. Raise one step. Disabled "Hear a sample" is dimmed on purpose and always says why, which is good.

9. **P3, settings-models-560.png.** It shows the Models tab, not the Voice section, so I can't judge placement there. The Voice shots do fit four pills at about 560pt. If the section shares that page, the header orb plus a spinning "preparing" orb breaks the one-animating-orb rule. The tab's "word patterns", "brain" and the orange "Loaded, but agent turns use…" are pre-existing jargon and out of scope.

## Passed
Apple voice appears in none of the 11 images. No red anywhere (orange only for unavailable, green only as status text). No "engine", "TTS", "synthesis" or "latency" visible. Disabled controls always explain themselves. Nothing switches voice on its own.

## Cannot judge from stills
Animation and whether the dotted ring is the `shaping` orb moving, VoiceOver, real window width, Reduce Motion/Transparency, the live notch card width and truncation, and per-answer repetition.
