# Wake-word live fixture set (`--selftest-wake-live`)

The committed re-run of the threshold grid in `WakeWordTuning.swift`'s header: the
same question the one-off synth runs answered (can the spotter hear "Hey Will", and
what does it falsely hear?), asked against a corpus that lives in the repo.

## Inventory

- `hits/` — 24 clips of the phrase **"Hey Will"**: 8 voices × 3 speech rates
  (150/190/230 wpm, the header recipe), half bare and half with a request after the
  phrase ("Hey Will, open Chrome", …). Voices cover General American (Samantha),
  UK (Daniel), Australian (Karen), Irish (Moira), South African (Tessa), Indian
  (Rishi) and French-accented English (Jacques, Thomas reading English text).
- `near-miss/` — 32 adversarial negatives at 190 wpm, rotating 6 voices. The first
  three are the seeds named in the tuning header, verbatim: "hey Bill can you check
  the numbers", "I will send you the file", "hey we need to talk about the budget".
  The other 29 are minimal pairs and sound-alikes grown from them (hey Bill/Jill/Phil,
  I/we/they will, hey we/when/where/well, hey win, wheel/hail/bill/build/fill…).
- `manifest.json` — the phrase plus every file with its text, voice and rate.
  Emitted by `generate.sh` from the same arrays that render the audio, so the two
  cannot drift. The runner (`WakeWordLiveSelfTest`) reads it, not the directory.

All clips are synth (`say` + `afconvert`), 16 kHz mono 16-bit WAV — the same shape
as `Tests/Fixtures/meeting-2min.wav` — so no real voice is committed. Real rooms are
covered without committing them: drop microphone captures of the phrase into
`~/Library/Application Support/Next Notes/WakeWord/LiveFixtures/*.wav` and the
self-test spots those too, reported as `WAKE_MIC m/M` (informational, never in the
verdict, never committed).

## Regenerate

```bash
Tests/Fixtures/wake/generate.sh
```

which is, per clip:

```bash
say -v Samantha -r 150 "Hey Will" -o /tmp/clip.aiff
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/clip.aiff hits/hit-01-samantha-150.wav
```

Rooms are deliberately *not* simulated (no artificial reverb): synth covers
voices/rates, the `LiveFixtures` overlay covers rooms.

## Verdict (evaluated at the shipped default, sensitivity 0.6)

- `WAKE_HIT n/N` / `WAKE_HIT_RATE x` — fails under 0.8 (D7 needs ≥16/20).
- `WAKE_FALSE n/N` — fails over 2, the header's measured cost of the default on
  these 32 negatives.
- `WAKE_VARIANT "<rule>": n` — per-pronunciation attribution from the diagnostic
  keywords file: which accent variants the hits matched.
- The 0.0 and 1.0 grid columns print as `WAKE_LIVE_GRID` diagnostics.

## D7 manual tally (production, off-device)

Say the phrase 20 times across a day, in three rooms (pass: ≥16/20 wake, ≤1 false
accept in 8 hours ambient), then:

```bash
S="$HOME/Library/Application Support/Next Notes"
grep -c '"kind":"wake"' "$S/agent-audit.jsonl"        # fires
grep -c '"kind":"wakeMiss"' "$S/agent-audit.jsonl"    # calibrator-measured misses
grep -c '"kind":"wakeFalse"' "$S/agent-audit.jsonl"   # "That wasn't for you" reports
grep -c 'wake\.miss' "$S/metrics.jsonl"
cat "$S/WakeWord/calibration-history.jsonl"           # attempts with peakLevel/elapsed
```
