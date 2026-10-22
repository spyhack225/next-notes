# Eight-model ASR application integration — 22 October 2026

The optimized combined app compiles/links and its signed candidate passes the native ASR Settings, stream and dictation-segmentation checks. Actual app model latency checks remain pending the coordinated machine handoff.

The Dictation language setting uses Automatic → Phonon for English and Automatic → Voz for Multi. Existing explicit Apple/Parakeet choices survive migration; manual model overrides are offered for all eight measured models. Phonon is English only. Multi’s default supports25 European languages; comparative French numbers are labelled as French evidence, not multilingual accuracy.

The existing ParakeetEngine owns capture input, pause segmentation, bounded live tails, committed prefixes, key-up coverage, scheduling and transcript delivery for every alternative. NativeASRBackend supplies only recognition. Existing meetings retain their Parakeet provider. Telemetry names the actual model and provider. A session retains its backend across selection changes; only the most recently selected alternative remains cached when inactive sessions release.

Cold preparation is explicit and visible. The earlier successful Phonon5s native load took66.684s, exceeding the controller’s existing45s startup bound. The current factory uses Apple while a selected alternative is not ready, preserves the requested selection, and changes to it on the next hold after preparation completes. No startup timeout is extended. Settings discloses the temporary Apple path and offers retry. Preparation remains owned through cancellation/join and through the existing quit drain.

ASRModelStore owns one preparation task, rejects a different simultaneous candidate, coalesces the same choice and does not release ownership on cancel before cleanup joins. Preflight checks all missing files and Phonon’s compiled copy, retaining the existing4GiB production reserve. Files use the existing size/SHA downloader. Exact filenames, pinned revisions, hashes and sizes are generated from shared/asr-artifacts.json. The selected model alone downloads; no eight-model prefetch or comparison-mode expansion occurs. Existing two-engine Compare mode is explicitly labelled Apple/Parakeet.

Shared/asr-models.json retains measured first-word/finalization/model-size and100×(1−WER) observations from the prior runtime suite. Scripts/generate_asr_catalog.py produces native metadata; the website reads the same evidence. Word accuracy is explicitly one separate136-word English /151-word French authored recording, not population accuracy. Qwen’s prior Python-MLX timing is not relabelled as the new Swift app path; actual application timing is a separate check. The eight safe public runtime summary records are reviewed/approved following the owner’s request. Release owns final catalog render, site build/deployment and publication audit; no independent push here.

## Verification so far

- All pinned downloadable file paths/sizes match official revision metadata; no weights downloaded for this check (`artifact-preflight.json`). SDK source only: local240KiB Phonon library with Apache LICENSE/NOTICE, pinned Voz SDK revision, existing MLXAudioSTT target. Attribution included.
- Native dependency targets PhononCoreML, Voz and MLXAudioSTT pass. Initial default SwiftBuild attempt hit the known Metal compiler-backend failure; corrected diagnostic uses the project’s native backend. Initial failures are retained, not hidden.
- Whole-module typecheck initially found one missing async marker in our compilation call plus two peer TTS WIP errors. Corrected combined source then passes61s. Final small readiness/quit edits parse; the full candidate build must compile them before native acceptance.
- Website TypeScript and lint pass. Two public-catalog evidence/asset tests pass. Native `--selftest-asr-settings` exercises actual factory choices and the actual store’s cancellation/serialized source boundary without reading owner preferences/models.
- `--selftest-asr-live` exercises the real app factory, segmented engine, scheduler and transcript consumer with20ms paced authored PCM. Each candidate is a separate app process; warm full/first shapes precede three timed English/French holds (Phonon English only). It excludes physical microphone, visible UI, cleanup, insertion and concurrent voice acceptance.
- Computer Use’s initial Next Notes access timed out(-10005). No visual Settings or physical microphone verdict follows.
- Seven exact unused current SwiftBuild intermediate/planning directories were retired after all jobs joined. `obsolete-swiftbuild-cleanup.json` retains paths/allocated bytes and unchanged current native binary hash. out/Products, legacy binaries and the current native dependency cache are preserved. Release separately owns old-root cleanup.

## Candidate commands

Use the release owner’s exact optimized/signed combined candidate. No competing build/model job:

```
<app-executable> --selftest-asr-settings
python3 -B Tools/asr_app_compare.py --app <app-executable> --output <new-report-directory>
```

The parent holds the existing serial lock, uses one candidate at a time, checks1.5GiB actual free disk and a600s diagnostic deadline, joins its child and removes only PID-identified owned failure roots. Each successful app check unloads the alternative, drains its calls and deletes its temporary root before exit. The app diagnostic alone uses a1GiB download reserve under its own temporary root; ordinary preparation keeps4GiB. Record failures and resources honestly; do not accept a missing native result or call paced replay physical capture evidence.

Diagnostic parent refinement after the source checkpoint: actual failure leaves an HTTP file under the old inherited temporary directory; the unchanged model-free fixture fails original and passes fixed. The parent now supplies an owned TMPDIR, saves/join/cleans interruptions, and removes only its PID-marked model roots. Native app source and the candidate build inputs are unchanged. Parent-derived short-excerpt WER is written separately from untouched native JSON, using the prior shared references. Local website preview has eight rows and a working French selector with readable layout (`website-preview.json`); publication is still the release owner’s action.

The signed candidate's existing Usage D2 case fails two assertions: its injected non-Apple engine is labelled Apple instead of the legacy Parakeet identity. The producer correction shares the existing currentEngineChoice helper: concrete Apple/Parakeet engines retain their actual identities, an injected unknown engine retains the old identity, and an outcome before any engine exists retains the configured selection. Original failure is retained in the release candidate's usage-log.log. Commits10fef9db/af77cb3a await the same native regression on the rebuilt candidate; no passing verdict is inferred from source inspection.

The parent now reuses Scripts/model-bench.py's Mach physical-footprint/RSS/swap sampler and the prior serial ASR context collector for per-model power, thermal, load, disk and process observations. All14 ASR harness tests pass. Owned disposable SDK source extraction/probes were removed after checking for open users (temporary-source-cleanup.json); vendored sources/pins and owner caches remain.

## Signed application results — completed

All8 candidates pass45 timed holds (three per supported language), on locally signed optimized0.2.24 build800, executable SHA256 `32a35bfcf9220dbdc87734466ccd63b9df1dc0a5e2488d1541b7e08a4207c8ed`. The five developer-cache SDK resource bundles were hidden throughout, proving packaged resources work for the actual model consumers. Original Usage D2 fails2 assertions; repaired same native flag passes0, with ASR Settings/stream/dictation-segmentation green. Later release metadata-isolation changes are separate and require their own checks.

| Model | English first / final ms | French first / final ms | Download + cold preparation s |
|---|---:|---:|---:|
| Parakeet v3 (cached FluidAudio) | 507.7 / 66.3 | 494.4 / 83.0 | 22.5 |
| Whistle | 425.6 / 9.2 | 417.3 / 38.3 | 1.4 |
| Parakeet Redux (CoreML) | 590.9 / 133.8 | 582.7 / 151.8 | 13.9 |
| Parakeet Ultra (CoreML) | 468.7 / 71.5 | 481.4 / 81.6 | 23.3 |
| Phonon-2 (CoreML) | 424.1 / 5.3 | English only | 222.9 |
| Qwen3-ASR 0.6B (4-bit MLX) | 541.9 / 230.1 | 560.7 / 328.1 | 10.6 |
| Qwen3-ASR 1.7B (4-bit MLX) | 636.6 / 643.8 | 677.2 / 986.6 | 16.5 |
| Voz (CoreML CLI) | 447.6 / 28.0 | 450.3 / 57.8 | 17.5 |

Medians of three warm trials; raw min/max, exact final texts, literal WER and parent-scored fixture hashes are retained in native/. First provisional text can change. Preparation includes download/compilation/load and excludes subsequent explicit shape warmups; Phonon223s is a cold setup observation, not a warm latency.

Phonon is fastest in English on this short app fixture. Whistle is fastest in French on raw latency. The owner-requested Multi default remains Voz. Current Whistle French final wording matches Voz: both have only the same literal numeral-formatting edits in this short hold. The earlier separate151-word runtime fixture scored Voz88.1% versus Whistle80.1%; that earlier quality measurement must not be relabelled as current full-app quality. Qwen1.7B led that longer French fixture at96.0%, with greater latency/storage. No broad-corpus accuracy grade follows from these authored fixtures.

All8 parent rows confirm child exit0/join, temporary model deletion and HTTP temporary deletion. No app-* or app-http-* roots remain; 6.1GiB free at handoff. The existing owner v3 cache is reused and never removed. All newly saved process inventories retain PID/CPU/RSS only: macOS comm can contain process-set arguments, so title columns were removed before staging and the shared collector now requests no command column.

Physical microphone/display, Settings clicks, cleanup/insertion and simultaneous ASR+voice remain outside these replay tests. Native Settings access was unavailable earlier; no physical dictation claim is made. The public comparison uses these app timings and labels the separate earlier accuracy fixture. Eight reviewed signed-app public manifests are registered separately from the prior runtime records.

App-process footprint was sampled once per second across preparation and replay: Qwen0.6B peaked1.68GB, Qwen1.7B2.80GB (decimal). These exclude Apple/ANE compiler service peaks and do not measure whole-machine model memory. Existing swap was roughly9–10.6GB; the large Qwen case added about492MB. The figures are pressure-context observations, not pristine or concurrent-voice qualification.

Settings metadata refresh2b11cd3d changes constants and one footer string only: both Settings and the website now use shared/asr-app-latency.json for actual signed-app first/final medians. Earlier shared/asr-models.json retains the separate longer-fixture accuracy and artifact sizes. Generator joins those sources without changing Swift APIs/types or ASR behavior. All8 public medians equal native raw trial medians; final targeted metadata compilation is release-owned.
