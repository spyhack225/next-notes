Prepared only. Do not run until root coordinates a model-free compiler slot; canonical Sources/Resources remain frozen. All commands operate on this owned cache. No app build, model, audio capture or owner store.

```
cd /Users/sergekadjo/Library/Caches/NextNotesBuild/meeting-pause-candidate-pfjr7kps/component
swiftc -swift-version 6 -parse-as-library ProductionDependencies.swift FluidResultTypes.swift Log.swift ExternalSinks.swift MeetingPauseBoundarySelfTest.swift Main.swift ChunkedTranscriber.original.swift -o original
swiftc -swift-version 6 -parse-as-library ProductionDependencies.swift FluidResultTypes.swift Log.swift ExternalSinks.swift MeetingPauseBoundarySelfTest.swift Main.swift ChunkedTranscriber.fixed.swift -o fixed
./original --selftest-meeting-quiet-input --meeting-quiet-pause-boundaries --meeting-quiet-conservative-admission > original.log 2>&1
./fixed --selftest-meeting-quiet-input --meeting-quiet-pause-boundaries --meeting-quiet-conservative-admission --meeting-quiet-pause-experiment > fixed.log 2>&1
```

Record each exit separately: original is intended to exit1 with preserved failing checks; fixed is intended to exit0. No result is yet observed. Preserve full stdout/stderr and compiler diagnostics, exact source and executable hashes. Do not stop an original/fixed comparison merely because the expected original fails.

Original source uses the complete canonical ChunkedTranscriber actor plus ONLY the same guarded diagnostic append accessor. Fixed has that same accessor plus the explicit pause-candidate patch. The component flags and conservative-admission scope are identical for both; only fixed adds the explicit pause flag. The actual production quiet/default admission remains unchanged. This does not silently adopt either experiment.

Actual actor proof covers appended chunks, real nextCut, nominal queue boundaries before drain/merge, hardmax burst, static/live parity, actual flush/merge/drain and injected ASR segment consumer. Seven generic controls are reused unchanged plus all six pinned public session WAVs, with one burst,16k and319sample packets. The invariant <30s fixture sizes avoid shedding. Direct waveform decoder reads signedPCM16/32768 and pins original files; it does not prove byte parity with AVFoundation conversion. The existing actual native Session is still required for that domain and true spoken words.

External substitutions: native queue must throw if accidentally reached; all tests inject a recorder/marker ASR at the existing seam. Usage/tally/latency persistence sinks are no-ops. SelfTest guard reads component argv, not the app parser. Actual OSLog definitions use a separate component bundle namespace. Production window constants/RMS/transcript types and FluidAudio result/word timing helpers are exact source slices. No token timing quality, native ASR lane/cold preparation, owner save/fresh-reader or actual concurrent workload proof follows from this model-free component.

Digital-zero/DC/noise classification is explicitly signal-forwarding observation. DC/noise forwarded by the separate conservative-admission experiment do not become demonstrated speech. Only real native negative controls can establish no hallucinated words. Generic transport marker text is never a gold-word acceptance.
