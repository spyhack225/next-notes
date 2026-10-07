# Shared optimized dictation verification — 7 October 2026

## Candidate and scope

Installed/shared `install-30744/Next Notes.app`, SHA256 `ed67302fae3c246bbfc377be77e954a0070f17b3b4c5771cfe5e1a04e0d628ad`, includes the seven producer repairs and commit35559e4. The meeting investigation's source-invariant final candidate passes actual cleanup-router/structure checks. This task made no new source edit, build or installation during verification; normal owner PID31982 remains running.

Three sequential native processes feed100ms packets at real audio time through actual Parakeet and the complete controller/router, twice per process. Grammar/structure remain enabled, busy-route skipping is disabled and budgets are unchanged. Dictionary processing remains. Screen context/history/usage and insertion are isolated. The rendering profile has plain path-reference style and empty context: **these audio cases do not exercise file tagging**, which has separate actual-router and2,183CPU comparison evidence. First text is measured from feeding, not acoustic onset. Text ready is the isolated insertion boundary, not external field delivery. Owner stores/microphone/destination are untouched.

## Current complete-path measurements

| Fixture | Round | Startup before feeding | First text | ASR final after release | Text ready after release | Layout |
|---|---:|---:|---:|---:|---:|---|
|8s, no explicit cleanup preload|1|21,488ms|519ms|63ms|647ms|not requested|
|same process|2|0ms|490ms|59ms|577ms|not requested|
|8s, cleanup preloaded|1|1,124ms|536ms|104ms|128ms|not requested|
|same process|2|0ms|492ms|101ms|116ms|not requested|
|121s, cleanup preloaded|1|330ms|645ms|22ms|6,204ms|6s timeout|
|same process|2|0ms|480ms|46ms|6,317ms|6s timeout|

Separate cleanup preparation takes14.870s short and4.941s long. Those fresh-process loads are not a paired cold-load comparison. The unpreloaded process uses Apple fallback while MiniCPM is not resident. Every round has live text at release and reaches isolated insertion. Long selected/answered heads are30/30 with no prefix fallback; completion boxes may contain formatter fallbacks, so they do not prove30accepted semantic repairs.

Long tail generation records365/370ms and1,297reused prompt tokens. The32retained native cleanup records show0.34–0.74s generation, median0.39s, all with1,297cached tokens and zero rounded admission wait. Logs principally cover the second round, not complete per-hold generation. Generation wall time is not decode-only ASR+voice throughput-floor evidence. Long raw/final strictWER both remain5.1% against the independent repository script on both rounds. This repeated public dialogue is not polishing/layout quality acceptance or paired owner/Wispr accuracy.

## Remaining bottleneck and verdict

The real layout request starts after release against the complete rule-cleaned transcript. Semantic cleanup overlaps it, but the router waits its nominal six-second budget and then rejects the plan for timeout. Both actual traces reproduce this. Recognition22–46ms and tail generation365–370ms cannot explain the six-second readiness delay; layout dominates this fixture's release path.

**Universal2s fails on both long rounds.** Functional OK means finishing completed. Earlier14.96/40.89s loaded-host observations are not clean causal controls; no end-to-end speedup ratio is claimed. Short readiness is much better in these current cases. Cold startup and native layout quality remain open.

Moving layout into speech time needs exact final-tail coverage, cross-boundary lists/code/quotes, announcement evidence, semantic remapping and cancellation. Appending unseen tails as prose or shortening a wait does not prove those features preserved. Prior compact schema trials failed the unchanged quality corpus and remain reverted. Full schema, validator and deadlines remain. A held-layout cancellation propagation test is another source hypothesis; no defect/fix is claimed without its failing original fixture.

## Related checks and lifecycle

The same bundle passes `DICTATION_OK`, `DICTATION_HYGIENE_OK` and `CAPTURE_OK`; the capture verdict is retained from actual tool stdout because that flag does not write `--selftest-out`. Dictation's injected1.5s startup retains39,801 of approximately40,000pre-roll frames and reports74ms key-down-to-capture. This is not physical cold microphone/ASR acceptance. Hygiene exercises isolated history/retention and private clipboard restoration. The new maintained dictionary assertions pass in the actual-source CPU driver; their package-runner gate remains unrun.

Tests use one staged process at a time under agent-relay `development-heavy`, now released; all owned diagnostics joined. No compiler overlaps replay. Owner applications remain; baseline swap is about6GB and load2–3. The explicit native-test coarse gate uses8GB minimum free disk for small outputs, with no build/download. Free disk spans about10GB after cleanup and9.5GB during replay. This is not a pristine host or quiet paired control. No product duplex gate is added.

Only superseded owned75337/21823bundles were retired after path/process/hash checks:356,634,624allocated bytes. Completed CPU probes (1,152,904logical bytes) were removed with drivers/results/hashes retained. Measured15518reproduction, shared30744and the meeting investigation's repaired rollback remain. Models, recordings, owner stores and foreign caches are untouched.

Evidence: [results](2026-10-07-evidence/shared-release/results.json), [source/binary/fixture pins](2026-10-07-evidence/shared-release/manifest.json), [long replay](2026-10-07-evidence/shared-release/long-warm.log), [retained app timing](2026-10-07-evidence/shared-release/long-app-runtime.log). The [meantime report](2026-10-07-meantime.md) records the integrated CPU improvements.
