# Offline voice-turn benchmark scorer

This tool scores **supplied** traces for latency, protected pauses, final-word retention,
unexpected output, missing stages and sample counts. It opens no microphone, loads no
model, downloads nothing and makes no native performance claim. Native trace collection
is VTD-06 in the [implementation plan](../01-IMPLEMENTATION.md).
The actual offline positive/negative controls are recorded in [verification](VERIFICATION.md).

From the repository root:

```sh
python3 roadmap/in-progress/VOICE-TURN-DETECTION/benchmark/score.py --self-test
python3 roadmap/in-progress/VOICE-TURN-DETECTION/benchmark/score.py \
  --trace /absolute/path/to/run.json --out /absolute/path/to/score.json
```

`cases.json` is a recipe/coverage manifest. It contains **no recordings or measured ground
truth**. Materialize and annotate each recording before native runs; every native trial
must name its actual WAV SHA-256. Read [the benchmark protocol](../02-BENCHMARKS.md) for
corpus sizes, holdout splits, repeated-trial counts and physical output requirements.

## Input format

Minimal authored example (one trial is deliberately insufficient for latency acceptance):

```json
{
  "schema": "nextnotes.turn-trace.v1",
  "run_id": "example-only",
  "evidence": "authored",
  "clock": "monotonic",
  "trials": [{
    "trial_id": "pause-900-001",
    "case_id": "pause-900",
    "phase": "warm",
    "asr": "apple-plus-parakeet-eou",
    "tts": "pocket",
    "condition": "clean",
    "language": "en",
    "status": "measured",
    "tail_retained": true,
    "pacing_p95_error_ms": 0,
    "ground_truth": {
      "speech_end_ms": 4000,
      "protected_intervals_ms": [[1200, 4000]]
    },
    "events": [
      {"name": "commit", "at_ms": 4300},
      {"name": "first_audible", "at_ms": 4650}
    ]
  }]
}
```

All times are milliseconds from a common capture origin. A protected interval covers
the thinking pause **and remaining speech until allowed completion**, preventing an
answer after resumption from escaping the pause gate. Native labels come from inspected
sample annotations mapped to host time, never the detector under test.

- `evidence`: `authored`, `native_replay` or `physical`; `clock`: `monotonic` or `sample`.
- Trial phases: `warm`, `cold_capture`, `cold_process`, `reopen`, `pressure`.
- Trial status: `measured`, `failed`, `absent`, `unsupported`. Non-measured trials remain
  failures for the requested cell; unsupported combinations are separately excluded only
  by the predeclared shipping capability matrix, not retroactively by the scorer.
- Events: `commit`, `first_audible`, `duck`, `pause`, `stop`, `effect`. Identity/provenance
  accompanies the full native export and requires integration review; this scorer does
  not prove a supplied timestamp came from a real renderer.
- `tail_retained` is mandatory true for a successful speech case. Derive it from reviewed
  final-word/span coverage, not a blanket true in the collector.
- Interruption trials also require `ground_truth.near_onset_ms`. Noise/echo-only cases
  must have no output changes. Silence cases still include an empty protected array.
- Native/physical trials require lowercase 64-character `audio_sha256`.
- Monotonic replay requires `pacing_p95_error_ms`; physical microphone trials have no
  artificial replay pacing requirement. Phase/resource provenance lives in
  the full native run report and is not certified by arithmetic validation.

## Output and limits

Output groups by case, phase, ASR, TTS, condition and language. Each group includes all
attempts, measured count, median/p90/p95/max, missing counts via failures and named gates.
Missing values stay null; negative latency remains a failure. No sample means no pass.
Warm and cold output are not pooled. The minimum is 30 measured trials per group.

`trace_subset_passed` refers only to supplied cells. `required_cases_missing` must be
empty for manifest coverage, but still does not prove all phases/providers were tested.
`wall_latency_evidence_eligible` is false for authored/sample-time traces. Even true only
means the declared evidence/clock type is eligible for review. It does not authenticate it.
`product_promotion` is always `not_evaluated`: held-out statistics, provider/route coverage,
resource/physical evidence and current application acceptance remain separate gates.

Exit 0: supplied cells pass scorer gates and all required case IDs are present.
Exit 1: scored failure/missing/insufficient
trials. Exit 2: invalid input or failed scorer self-check. Native absence is never success.
Self-tests deliberately use authored data and a two-trial miniature manifest; that small
manifest must never be used to promote the real pipeline.
