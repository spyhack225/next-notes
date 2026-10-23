# Serial audible TTS continuation — 23 October 2026

Owner requested obsolete build cleanup, all five physical speaker comparisons one model
at a time, durable results/deletion before next, website results and the fastest qualified
voice as default. Default/install are unchanged while the comparison is incomplete.

## Completed cleanup

`cleanup-obsolete.json` retains per-file hashes for nine20October installer stages
superseded by installed809 and the removed-worktree compiler ModuleCache. Only those
exact idle paths were removed. Three obsolete Xcode app dSYMs were archived, archive
integrity and every file hash verified, then uncompressed originals removed. Existing
old executables/runtime resources, current native scratch, installed809, rollback and
useful f8a214a3 diagnostic bundle remain. Immediate free-space observation increased
1,538,908,160bytes (1.43GiB); this is not exclusive APFS physical attribution or all OS
recovery. No owner app was closed, no recording/history/model cache was swept.

## Saved physical results

All five attempted serially at hardware output60%, input51%, source gain0.75, native
48k mono observer, immediate500ms baseline and unchanged4x/.001RMS/.75-correlation/
two10ms onset gates. The f8a214a3 diagnostic uses the retained25-token Qwen candidate;
ordinary installed809 still uses the original decoder. `serial-source-pins.json` and
`serial-command.json` pin the exact source/binary/workload. The reference is paced
cached Parakeet-v3 decoding, not new selected dictation-ASR/EOU/full-turn acceptance.

| Voice | Warm qualified | Accepted acoustic median / p95 | Retained result |
|---|---:|---|---|
| Phonon |30/30|264.393 /322.068ms|`serial-speaker/phonon.json`|
| Pocket/Alba |30/30|293.466 /369.349ms|`serial-speaker/pocket.json`|
| Kokoro |0 attempted|Admission refused: insufficient headroom|`serial-speaker/kokoro.json`|
| macOS |0 completed|Live disk guard during reference warmup|`serial-speaker/apple.json`|
| Qwen3-TTS |0 attempted|Admission refused: insufficient headroom|`serial-speaker/qwen.json`|

Every result is saved and each native/reference child joined and model root deleted
before the next. Those original receipts did not yet cover external compiler output;
that discovered gap is documented below. All first-after-preparation samples remain
separate from the30 varied warm requests. No survivor-only median or fastest-five
claim is made. The old23October38% cohort remains independently retained; Apple there
completed30/30 at159.863/186.975ms, Qwen27/30 had no accepted median. Different output
levels/observer cohorts are not pooled into a new ranking.

`serial-volume-after.json` confirms original built-in output12.5% was restored.
Before continuation, the default route changed to AirPods input101/output95. The60%
built-in comparison cannot be continued on that different route. A fresh attempt
refused before model download because that output exposes stereo channel controls
rather than the built-in master-volume property. No device/volume change was made.
Permission to temporarily restore built-in input/output, then return AirPods/levels,
is pending; hardware testing/default promotion are paused at that boundary.

## External compiler artifact producer and mitigation

Disk pressure exposed a second, confirmed artifact-lifetime gap: Core ML's diagnostic
per-executable compiler cache is outside TMPDIR and the benchmark root. Four abandoned
`runtime-probe/com.apple.e5rt.e5bundlecache` bundles total1,783,771,984logical bytes;
one embeds PID98720 and was created during the failed Apple reference window
(timestamp/exclusive-window attribution; the old wrapper did not retain its workerPID). The pinned Phonon compiler
also left ten53MB `flow-c414-t48*.mlmodelc` outputs in system temporary storage, including
one dated00:32:09 that matches this cohort's Phonon preparation. The root-only cleanup
could therefore report success while compiler artifacts survived. These external
SDK/CoreML producers are not repaired here; the smallest owned diagnostic boundary
mitigation now closes their observable artifact lifetime. This does not explain all
VM/swap pressure or claim the entire Qwen disk problem solved.

`compiler-artifact-cleanup.json` inventories/hashes the idle diagnostic compiler
artifacts before deleting them. Existing production caches/model weights remain.
Observed free-space gain1,615,106,048bytes is not claimed as exclusive physical bytes;
OS pressure recovery continues independently.

`Tools/tts_asr_workload.py` snapshots compiler bundles in the diagnostic executable's
cache namespace while holding the existing ASR serial lock. After child exit and a
durable result/receipt, it deletes only newly created bundles, preserves existing
ones and verifies deletion. The parent requires `compilerCacheDeleted` in addition
to join, snapshot deletion and owner-artifact preservation before another TTS model.
`Tools/tts_compare.py` similarly snapshots only the pinned Phonon temporary-name
pattern and removes newly created compiled models after result save/child join.
A save failure retains evidence and prevents another model; no production capture,
playback, scheduling or download reserve changed.

Original native failure is retained in the failed Apple reference and the abandoned
compiler bundle's inventory/timestamp; old workerPID binding was not retained. Fixed native cancellation reproduces the allocation
boundary: `reference-cache-native/result.json` observes an actual newly created
`.tmp.8141_...bundle`, interrupts its own wrapper during compilation, joins the native
child, saves diagnostics and confirms no new compiler bundles remain. All23 existing
ASR model-file hashes are unchanged. This is native artifact-lifetime proof, not a
voice timing or output-quality verdict. The same actual-process external-cache fixture fails once against original2da9a25e and
passes against the fixed wrapper (`reference-original-fixed.json`); the original
workload lifecycle test is preserved and strengthened. All18 model-free runner controls pass in
`runner-tests.log`, including existing-cache preservation, rejected cache redirection,
external Phonon temporary cleanup and sequential save/join/remove behavior.

## Remaining default contract and voice-turn coordination

The VOICE-TURN-DETECTION agent acknowledged the physical measurement window and
kept builds/inference deferred; it now performs only tiny disjoint source compilation.
It confirmed existing `--selftest-voice-pipeline` checks Apple ASR + local Parakeet
EOU/frontend/native playback acknowledgement, not the new dictation ASR pairs or
physical microphone onset. Existing Apple timeline/resume-owner tests cover actual
buffer/token consumers; the full new SmartTurn roadmap need not finish before a
bounded TTS decision. A completed common-route five-voice cohort and focused winner
consumer/suspend/cancel/quality smoke remain required before choosing the default.
The original owner92-key preference hash witness is `preferences-before.json`;
Pocket/Alba remains selected. No additional TTS model is currently loaded.
