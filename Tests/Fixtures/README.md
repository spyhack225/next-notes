# Fixtures

`meeting-2min.wav` — 2:10 of synthetic meeting speech, 16 kHz mono 16-bit, two `say`
voices alternating with 0.8 s pauses between turns. The pauses matter: `ChunkedTranscriber`
cuts a window at the first gap of ≥600 ms after 30 s, so a fixture of continuous speech
would only ever exercise the 60 s hard cut.

It is speech rather than silence because the whole point is to measure transcription, and
it is generated rather than recorded so nobody's voice is committed to the repository.

Regenerate with `say` + `afconvert` — write the turns to `s1.txt`…`s5.txt`, then:

```bash
for i in 1 2 3 4 5; do
  v=Samantha; [ $((i % 2)) -eq 0 ] && v=Daniel
  say -v $v -f s$i.txt -o p$i.aiff
  afconvert -f WAVE -d LEI16@16000 -c 1 p$i.aiff p$i.wav
done
```

and concatenate the parts with 0.8 s of silence between them.

Used by `Speechify --selftest-transcribe Tests/Fixtures/meeting-2min.wav`.
