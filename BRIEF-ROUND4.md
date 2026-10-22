# voice-settings-ui round 4 (Codex) — final small copy/layout pass. Read ../RULES-2.md and ../review-ui/REVIEW-VOICE-SETTINGS-R3.md. Own worktree only; heavy.sh for the single build/preview slot; no install/push/merge. Keep all recovery/epoch wiring untouched.
Apply the four remaining findings with the review's wording (improve only if clearer, no jargon):
1 (P2) written-answer links: "Voice settings" -> "Open voice settings"; "Retry in Voice settings" -> "Try again in voice settings".
2 (P2) preparing state: one spinner inline, left of "Getting your voice ready…"; remove the stray second indicator and the lonely row/gap. (Still one animating orb/spinner per screen.)
3 (P3) voice-needs-download: show "not on this Mac yet" once (status row), not on both tiles; the unselected voice's tile shows nothing extra.
4 (P3) voice-kokoro-failed: the unselected Pocket tile must not claim "not on this Mac yet" when Pocket is simply not the failed one; only say what is true for that voice.
Also (from R3 'partly'): make Retry the primary/prominent button (bordered prominent style, accent) so it is clearly the next action; if the offscreen render cannot show active prominence, say so — do not fake paint.
Update the source copy check (RED then GREEN for the changed strings), run ONE heavy.sh slot: build, --selftest-voice-settings (the flag you used), --selftest-ui-strings, --selftest-settings (-11 inherited if it recurs), --voice-settings-preview; inspect the PNGs. RESULT.md round-4 section, delete scratch, relay one line to claude-positioning.
