# Dictation evidence, 2026-10-07

`baseline-stats.json` and `wispr-stats.json` contain numeric/enum/count summaries from read-only owner histories. They contain no dictated text. Historical runs are unmatched and stage definitions differ.

Original logs use the pre-task **dirty working tree**, not Git HEAD. `task-changes.patch` records this task's 13 source/build files relative to those captured originals; it excludes other agents' pre-existing changes. Source snapshots and disposable build logs are retained under `~/Library/Caches/NextNotesBuild/dictation-latency-20261007/original-source`. `source-sha256.json` pins the final touched source. Changes are retained uncommitted in canonical main; the existing index is untouched.

Original failing regressions:

- `original-router.log`: whitespace equivalence, word boundary, sequential head/tail.
- `original-capture.log`: actual delivery worker loses accepted packets at Stop.
- `apple-deadline-original.log`: actual formatter waits past its caller deadline.
- `timing-original.log`: actual controller clears the release timestamp before measurement.
- `island.log`: hidden native panel still intercepts mouse events.
- `tagging-isolated-original.log`: actual finishing path skips context for file tags with cleanup off.
- `late-producer-original.log`: actual incremental producer completes polishing that final router discards.
- `repeated-prefix-original.log`: actual incremental producer runs rules twice for an unchanged prefix.

`ready-checks.json` records ten focused functional flags on the completed debug bundle. `ready-dictation.log` exercises native microphone/controller behavior. `dictionary-tests-summary.log` retains the 30-test / 137-case result. Router model fixtures use the real production router/formatter with controlled responses; they establish the caller contract, not native model cancellation.

Replay uses `Tests/Fixtures/meetings/en-dialogue.wav` at real-time pace through the real ParakeetEngine. The independent script is `Tests/Fixtures/meetings/scripts/en-dialogue.txt`, with leading speaker labels (`A: ` / `B: `) removed. WER lowercases and removes punctuation; spoken numbers versus rendered numbers can count as lexical differences. Whole-buffer disagreement is a separate metric and is not an accuracy oracle. Doubled-length input is that WAV's PCM concatenated twice and the same independent script repeated twice; it tests scaling, not a second speech corpus. No owner recording is used.

Reproduction (set `NEXTNOTES_APP` to the report's signed staged bundle):

```sh
make app CONFIG=release
Scripts/run-selftest.sh --selftest-cleanup-router
Scripts/run-selftest.sh --selftest-capture
Scripts/run-selftest.sh --via-open --selftest-dictation
Scripts/run-selftest.sh --selftest-dictation-segments Tests/Fixtures/meetings/en-dialogue.wav --dictation-gold /path/to/label-stripped-script.txt
Scripts/run-selftest.sh --selftest-cleanup minicpm
make test
```

`minicpm-quality.log` preserves the real three-assertion quality failure. `original-isolation.log` and `isolation.log` show the same unrelated browser/tool-loop failure with 21 files / 33 defaults unchanged. Missing or interrupted verdicts are not passes. Final optimized results and cleanup accounting are in the accompanying audit.
