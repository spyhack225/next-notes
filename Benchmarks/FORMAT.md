# Saving a benchmark result

`Benchmarks/runs/<unique-id>.json` is the registration format ([JSON Schema v1](schema.json)). One file per independently interpretable run/model/configuration. The generator consumes every manifest automatically; a file does not need a separate hand-edited index entry.

1. Coordinate expensive work through agent-relay. Use the existing runner and model cache; never run a second benchmark to obtain catalog metadata.
2. Save original results in the producer's existing report directory, or `Benchmarks/artifacts/<run-id>/` for a new suite. Preserve raw samples, exact model/build/fixture pins and original/fixed verdicts. Keep owner payloads private. Existing report links remain valid.
3. Copy [the template](templates/run.json), fill it from actual evidence and assign a unique dated ID. Unknown fields stay explicitly unknown; missing timing is not zero. `metrics[].samples: null` means the original sample count is unknown. An aggregate of unknown size must not be labelled a single-trial run.
4. Register with `python3 Scripts/benchmarks.py add /path/to/manifest.json`. This refuses an existing ID, validates sources and refreshes the index. Alternatively save the unique file directly in `runs/` and run `python3 Scripts/benchmarks.py render`. Concurrent agents own separate files. Do not rewrite someone else's run.
5. Commit the run, original report and generated catalog together. `npm run build` in `site/` refreshes the catalog and public summaries before building the tracked `docs/` website. The existing site deploy flow builds first. Registration alone does not publish a site or install the app.

`python3 Scripts/benchmarks.py check` validates all registered runs, source paths and generated outputs. CI performs the same check; failures are not silently skipped. `python3 Scripts/benchmarks.py audit` separately refreshes the pinned inventory of all local/remote Git refs and worktrees; this is read-only and never launches models or builds. The build inventory records file membership, so an active agent appending a log does not invalidate a site build. File sizes/hashes are retained in the separately dated audit. Audit archives are gzip JSON to avoid duplicating megabytes of historical path metadata. Inspect with Python's `gzip.open`.

## Required meaning

- `category`: asr, dictation, meetings, agent, voice, tts, workflows, models or other.
- `status`: measured (scope measured), partial (incomplete scope/open acceptance), failed (actual tested failure), blocked (attempt refused or unavailable), unrun (no accepted measurements). These statuses do not promote models or complete roadmaps.
- `scope` and `summary`: the concrete claim. Separate runtime, scripted/component, production-path and physical-device evidence.
- `environment`: machine/OS/RAM, power/thermal state, workload, cold/warm conditions and missing observations. Reference acceptance requires ASR and voice on the 16 GB M2–M3 Air; a quiet M3 run does not qualify that workload or the M2.
- `provenance`: exact commit/source/model/fixture hashes, binary signature/build, runner command, grader, output paths and any substitutions. Legacy imports point to the original report when pins are not recoverable. Current dirty HEAD alone is insufficient provenance.
- `metrics`: numeric value, unit, precise start/end `boundary`, `samples` and `aggregation`. Explicitly identify preparation, first generated PCM, audible output, speech-end→answer, final inserted text, decode throughput, RSS versus physical footprint. Preserve per-trial raw results as source evidence. Targets belong in limitations/standards, never measured metrics.
- `limitations`: remaining gates, missing settings/pins, errors, partial source coverage, unavailable devices, grading limitations and differences that prevent a comparison.
- `sources`: existing repository-relative files, not URLs or paths outside the repository. Private external sources can be described in the private original report without copying their payloads here. Renaming reports requires repairing these links.
- `publication`: false by default. Set `approved: true` only after reviewing **every public field** (title, dates, category/status, scope, summary, environment, metrics, limitations) for privacy and claim accuracy. Record the reviewer and date. The build projects this allowlist; it never exports source payloads, inventory, provenance or branch/worktree metadata. Approval is a content review record, not a user-facing product confirmation.

All reviewed results, including failures and partial runs, may appear publicly. Do not manufacture a leaderboard by sorting incomparable workloads or suppressing failing cases. New historical imports are explicitly dated; they do not replace later evidence.

## Active producers (22 October 2026)

- ASR: `Tests/Reports/asr-candidates-2026-10-22/comparison.json`, eight runtime rows. Imported as eight records. New paced live-latency work is separate; whole-file throughput must never be relabelled live latency.
- TTS: `Tools/tts_compare.py` saves `<output>/summary.json` and per-engine JSON (`nextnotes.tts-first-pcm.v1` nested measurement). Generated-PCM timings are separate from audible output. Register each accepted engine result after save/exit/owned cleanup; include failed/blocked engines too. The preparing entry remains unrun until native evidence exists.
- Legacy Swift `bench/`: remains the actual independent harness. It is linked, not replaced or moved. New recordings can contain private speech; they require review before any public summary.

There is no background catalog watcher, model download, second usage ledger or benchmark scheduler in the application. App Settings opens the same published results in an on-demand sheet, with a browser option. Only developer registration/build commands scan the repository.
