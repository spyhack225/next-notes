# Re-review R3: Voice settings (round3 shots, 8 of 11 viewed in full)

**Verdict: APPROVE WITH FIXES.** Nearly all round-2 findings are resolved. Remaining items are small copy and one design call.

## Earlier findings

1. **Kokoro unavailable (P1): FIXED** (voice-kokoro-unavailable.png). No version numbers. Tile reads "Needs a newer macOS", tile is dimmed and not outlined, no Heart, and the warning is "Kokoro needs a newer version of macOS. Choose Pocket to hear replies." Orange glyph, not red. Grep: "macOS 26" appears nowhere in the new copy.
2. **Static footer with size (P1): FIXED.** voice-ready.png shows only "Pick a voice, then hear a sample." No footer elsewhere, no MB or GB in the Voice section (settings-models-voice-560.png). The "34.5 MB" in that shot is the pre-existing Needle row.
3. **Text-only lines (P1): MOSTLY FIXED** (voice-text-only-lines.png). "Voice settings" is now blue, so it reads as a link. The notch box is complete: "Voice is getting ready. Answer is here." The "Download a voice" contradiction is gone. Still open, see N1 below.
4. **Weak Retry (P2): PARTLY.** The tile now says "Couldn't start · tap Retry" and the row has an orange glyph (voice-failed.png, voice-kokoro-failed.png). But Retry is still a small grey pill, the same weight as "Download voice". Make it the prominent (tinted) button.
5. **Invented ~40% progress (P2): FIXED, with a new nit.** voice-preparing.png has no fake bar. It shows "The first time takes a few minutes. You can keep using Next Notes." That is honest.
6. **Pocket vs Kokoro difference (P2): PARTLY.** "4 voices to choose from" vs "One voice: Heart" is a real difference a person can understand. The tile's "not on this Mac yet" no longer implies a download, and only one Download voice button remains. Neither tile says how they sound, but I accept this.
7. **Colour-only selection (P2): FIXED.** A check mark sits on the chosen tile. The theme is light in every shot. The blue outline and orange text read well.
8. **Small grey text (P3): PARTLY.** The tile subtitles are still mid-grey on light grey. It passes, but is close to the limit.
9. **Real Models page and one animating orb (P3): FIXED.** settings-models-voice-560.png shows the real page. The header glyph is a still triangle, and only the Voice section has a spinner.

## New problems

- **N1 (P2): "Voice settings" in the written-answer lines.** It is a hint, not a menu path. Use "Open voice settings". "Retry in Voice settings" is awkward; use "Try again in voice settings".
- **N2 (P2): voice-preparing.png.** The spinner sits alone on its own row, below the text, with a large empty gap. Place it left of "Getting your voice ready…" and drop the dotted circle, which is a second indicator. In the real page the header orb (still) plus this spinner is fine. Both indicators together are one too many.
- **N3 (P3): "Not on this Mac yet" appears three times at once** (Pocket tile, Kokoro tile, status row, in voice-needs-download.png). Remove it from the tile of the voice that is not selected. Use "4 voices to choose from" and "One voice: Heart".
- **N4 (P3): Kokoro tile in voice-kokoro-failed.png.** The tile says "One voice: Heart · not on this Mac yet", which is wrong, because a failure is different from not downloaded. It should say "Couldn't start · tap Retry" on that tile too. (The Pocket failed tile does; check that Kokoro's does.)
- **N5 (P3): "Technical details"** disclosure inside the section on the Models page (pre-existing page convention). Confirm that nothing in it names an engine or a file.

## Passed
No Apple voice. No red. Voice never switches itself. Failed voice shows plain Retry and says answers are in text. No jargon or sizes in Voice copy.

## Cannot judge from stills
Real notch truncation, the "only one line at a time" rule and per-answer repetition, VoiceOver, animation.
