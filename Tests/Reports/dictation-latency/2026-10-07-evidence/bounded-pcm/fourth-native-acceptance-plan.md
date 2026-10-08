# Fourth release: native dictation acceptance

Status: prepared; not run. Compiler/source freeze and native-resource ownership remain with meeting-performance-20261007. Never run these commands during its compiler or model window.

## Admission and scope

After explicit relay handoff, claim the existing exclusive native inference resource and check the applicable resource gate. The owner app stays running and unchanged. Confirm no owner capture is active; do not infer safety solely from a resource gate. If the gate refuses, retain the native verdict as pending; do not silently lower its thresholds. Verify both exact bundles with strict codesign and executable SHA before launching. Serialize launches; join each complete process before the next. Check source pins before/after.

Original: /Users/sergekadjo/Library/Caches/NextNotesBuild/install-68784/Next Notes.app (executable SHA cff85f47c0ab9ddbabe3b413e872d091a2191e79d7b26bda3842da938c97aa53).
Fixed: exact fourth signed bundle returned by build owner, not guessed from a cache directory.

## Same original/fixed full finishing path

For EACH bundle, execute the following three commands with NEXTNOTES_APP set to that exact bundle. Use a distinct absolute output directory per bundle. Commands are templates: ${OUT} and ${APP} must be supplied explicitly.

```bash
NEXTNOTES_APP="$APP" Scripts/run-selftest.sh --via-open --out "$OUT/short.log" \
  --selftest-dictation-segments /Users/sergekadjo/Library/Caches/NextNotesBuild/dictation-followup-20261007/short.wav \
  --dictation-polish miniCPM --dictation-polish-warm \
  --dictation-polish-output "$OUT/short-final" --selftest-timeout 180

NEXTNOTES_APP="$APP" Scripts/run-selftest.sh --via-open --out "$OUT/long.log" \
  --selftest-dictation-segments /Users/sergekadjo/Library/Caches/NextNotesBuild/dictation-followup-20261007/long.wav \
  --dictation-polish miniCPM --dictation-polish-warm \
  --dictation-gold /Users/sergekadjo/Library/Caches/NextNotesBuild/dictation-latency-20261007/en-dialogue-double-gold.txt \
  --dictation-polish-output "$OUT/long-final" --selftest-timeout 420

NEXTNOTES_APP="$APP" Scripts/run-selftest.sh --via-open --out "$OUT/quiet-final.log" \
  --selftest-dictation-segments /Users/sergekadjo/Library/Caches/NextNotesBuild/dictation-bounded-pcm-20261008/quiet-final-clause.wav \
  --dictation-polish miniCPM --dictation-polish-warm \
  --dictation-gold /Users/sergekadjo/Library/Caches/NextNotesBuild/dictation-bounded-pcm-20261008/quiet-final-whole-gold.txt \
  --dictation-polish-output "$OUT/quiet-final" --selftest-timeout 300
```

Each polishing test already feeds the COMPLETE WAV through the real engine/controller at real-time pace and runs twice in the same process. Record startup separately: first-word latency starts after engine.start returns. Keep grammar, layout and semantic cleanup enabled. Inspect actual raw and final independent WER, final texts, live words at release, ASR final, finishing publication, final ready, heads answered and layout verdict. POLISH_OK only establishes nonempty functional completion; it does not establish the 2s target, accuracy, physical paint or external insertion.

## Fixed full-buffer acoustic control

Run the fixed bundle WITHOUT --dictation-polish:

```bash
NEXTNOTES_APP="$APP" Scripts/run-selftest.sh --via-open --out "$OUT/quiet-complete-audio.log" \
  --selftest-dictation-segments /Users/sergekadjo/Library/Caches/NextNotesBuild/dictation-bounded-pcm-20261008/quiet-final-clause.wav \
  --dictation-complete-audio \
  --dictation-gold /Users/sergekadjo/Library/Caches/NextNotesBuild/dictation-bounded-pcm-20261008/quiet-final-whole-gold.txt \
  --selftest-timeout 300
```

This new mode submits the entire file to an independent real AsrManager reference, then real-time engine replays with complete-file and complete-file+300ms endings. If reference recognizes quiet words but streamed final omits them, investigate the first incorrect segmenter/key-up decision. Do not attribute loss to the model without this control.

Do NOT use --selftest-transcribe as this control: it routes through meeting ChunkedTranscriber.containsSpeech at the same RMS floor and can skip the quiet input. The old default segment replay also trims its reference and streamed audio using that floor. The whole-file gold and WAV must remain untrimmed.

## Fixture and proof limits

Public en-dialogue fixture only. All original samples/words remain; the last 2.4s of originally above-floor speech is attenuated below 0.01 frame RMS (maximum 0.009000379). Recipe and exact hashes are retained. Quiet-alone crop is available but has no independently aligned word gold; never grade it against the whole script.

The existing substituted-boundary 18 cases prove exact per-pass Float arrays, chunk streams, key-up plans and bounded successful-commit retention. Native tests prove the actual consumer path, complete-file acoustic reference and recorded WER/timings. They do not prove actual per-pass native byte identity, total footprint reduction, microphone/paint/AX behavior or concurrent ASR+voice throughput. The 16GB M3 reference floor still needs its own prescribed live proof.
