# PL-01 thermal admission

The floor benchmark requires a nominal thermal state at the start and records heating during sustain. The report previously labelled a nominal-start/fair-end run CONTENDED solely because of its final temperature. The actual floor predicates now share a small qualifier that retains start admission and leaves end heating as recorded data. Power, pressure, ASR, token counts, sampling and other rejection conditions are unchanged.

Original recorded input: Mini9c5db1b/9f757ad5,602.11s C1,92 native256 rows,122 successful ASR, nominal→fair; raw status CONTENDED/thermal-end remains retained. Existing metrics regression: original METRICS_RED1 → fixed METRICS_OK; focused voice preparation, capture, duplex and store isolation also pass. Native Apple frontend has the same two inherited routing reds, recorded separately. No new native performance measurement or whole-floor/default acceptance is claimed.

Bulk original source/patches/recording and root qualification: ~/Library/Caches/NextNotesBuild/integration/pl01-thermal-admission/. Sustained threshold remains proposed; C2 and complete same-build/resource/quality acceptance stay open.

Exact fixed binary `e431b7e2129a85889e48c2072de75333d010467130bc6e2642c5ed9ee73d4e7b`; original/fixed logs in ~/Library/Caches/NextNotesBuild/integration/early-voice-and-floor-thermal/. The metrics-only original recheck confirms the final FAILED marker after correcting mixed buffered/direct stdout ordering. All temp roots were removed after join; no unchanged native sustain was rerun.
