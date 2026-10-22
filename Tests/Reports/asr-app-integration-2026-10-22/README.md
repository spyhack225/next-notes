# Eight-model ASR application integration — 22 October 2026

Source checkpoint; optimized combined build, native model-free flag and actual app latency checks are pending.

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
