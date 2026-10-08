# Bounded dictation PCM proposal — not applied or verified

Current Parakeet keeps all resampled16kHz PCM in its `samples` array until release, despite frozen successful segments. The hold's existing audio counter separately owns accepted audio for retry/history. Proposed existing-array seam: retain only uncommitted PCM plus any required ASR backlog, track absolute `sampleOffset`, and discard a prefix only after its actual segment model pass succeeds. The last incomplete scan frame and hard-cut rewind must remain covered. No audio counter/raw retry truncation, extra store/queue, new model pass or audio feature change.

Pure first proof: same exact segmenter with absolute offsets over trimmed committed prefixes must reproduce every cut/end-of-speech offset and every audio slice handed to the model on tone/noise/silence/hard-cut/quiet fixtures. Then actual Parakeet producer must use absolute `sampleCount` at every finish/minimum/schedule/pass/log call site; existing short padding, empty/quiet tail, in-flight stale pass, failed segment and key-up fallback coverage must stay intact. Native original/fixed complete replay and independent WER/slice coverage are required before any performance claim. Peak retained samples are ASR buffer evidence, not total process/owner recording memory.

This is an unverified cache-only prototype. It is not in canonical Sources or a release candidate. It does not address the confirmed6-second layout delay, and does not establish the owner8-second native stall cause.


## Adjacent accuracy gap, not repaired by PCM retention

`DictationSegmentsSelfTest.replay` derives `lastWord` from the same0.01 frame RMS gate and truncates **both** its full-buffer reference and real-time inputs at that offset. It therefore cannot detect intelligible quiet speech after the last above-threshold frame. The polishing controller replay does feed the complete file. A native quiet-after-commit check must use an untrimmed reference and input, or an independent explicit acoustic ending, then compare actual recognized words. A low-amplitude tone alone cannot establish speech loss. No native quiet-speech verdict is claimed.

The cache-only actual-engine fixture includes ordinary short padding, all quiet, pauses, a hard-cut rewind with non-frame-aligned feed sizes,121s segmented audio, a failed first model pass, quiet audio after a successful commit, an in-flight held segment with overlapping final tail and its failed-segment fallback. Native model/scheduler/converter boundaries are explicitly substituted; real AV buffers and all original engine control/slicing logic are used. This remains uncompiled while the peer owns the machine build claim.


## Separate committed-text proposal — not applied or verified

The existing `committedTexts` array is joined twice for each partial publication although its prefix changes only at a successful segment. The adjacent cache-only candidate replaces that array with its joined string plus the existing segment count; it does not keep a second copy/store or alter cuts/model calls. Exact original/candidate stream and final parity is required with empty, whitespace-only, accented/decomposed Unicode, emoji and CJK boundary outputs as well as normal hash outputs. Unicode/empty outputs are deliberately scripted external-model substitutes, not an accuracy claim. Failed segment, overlap, empty-success segment ownership and session reset remain covered. This candidate is not canonical and has no measured native speed benefit.
