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

Used by `NextNotes --selftest-transcribe Tests/Fixtures/meeting-2min.wav`.

## memory-review.json

Labelled Agent sessions for the background memory review (`MemoryReviewer`). Each case has
the core memory it starts with, the session's turns (a `source` of `meeting` or a
`contextKind` marks rows the review must not read), the answer a scripted fake model gives
(`scripted`, written to include the mistakes a small model makes: one-off requests,
environment failures, facts from the Agent's own replies, commands, calls to tools other than
memory), and the expected outcome: `expect.saves` are the only acceptable new entries, and
nothing in `expect.absent` may remain.
The `inject-forget-*` cases have text the user did not write ask for a forget; a removed
memory there counts as a wrong write.

```bash
NextNotes --selftest-memory-review                          # scripted model; passes at precision >= 0.9
NextNotes --selftest-memory-review --model local            # on-device model, same labels (needs the download)
NextNotes --selftest-memory-review --model cloud            # OpenRouter, same labels (needs a key)
NextNotes --selftest-memory-review --fixtures path/to.json  # another labelled set
```

The sessions are written by hand; no real conversation is committed.

## knowledge-gold.json

The retrieval gold set scaffold for hybrid search (Phase B). A small library — twelve
meetings' notes and two Agent conversations — and fifty questions, each naming the one passage
that answers it by its source key and a phrase the passage contains (chunk ids change with
every rebuild, so they are never used). `kind` is `lexical` (the question shares the answer's
words), `paraphrase` (it mostly does not) or `conversation`.

`--selftest-search` indexes the library in a temporary directory, embeds it with the fake
embedder, and prints recall@10 and MRR for BM25, cosine and the fused ranking, overall and by
kind. The fake maps a handful of paraphrases onto shared features by hand, so these numbers
test the pipeline — RRF, filters, recency — and say nothing about a real model. Comparing
potion with EmbeddingGemma needs the same format written against a real library, and the
models downloaded; both are pending.

```bash
NextNotes --selftest-search                              # fixture set, fake embedder
NextNotes --selftest-search --gold path/to/other.json    # another labelled set
```

The questions and notes are written by hand; no real meeting is committed.
