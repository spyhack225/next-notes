# Offline scorer verification — 22 October 2026

Scope: standard-library Python arithmetic/input validation only. No microphone, model,
app binary, audio recording, build, download or native inference was used.

Executed:

```sh
/usr/bin/python3 roadmap/in-progress/VOICE-TURN-DETECTION/benchmark/score.py --self-test
```

Result: `TURN_SCORER_OK authored_checks=21; no model/audio/native latency measured`.
Authored controls cover a passing protected-pause trace; early commit; missing audible
stage; missing final words; duplicate commits; excessive audible latency; absent native
trial; invalid pacing; effect before commitment; nonfinite time; empty run; absent case;
insufficient n; sample-time evidence labelling; native recording identity; physical
microphone pacing distinction; and passing/failing real-duck timing arithmetic.

A separate CLI check materialized **31 cases x 30 authored traces** in an owned temporary
directory. A complete passing authored set exited 0; a missing-tail mutation exited 1;
omitting all `pause-900` trials exited 1 with that case named; malformed time exited 2.
The exported report explicitly remained `product_promotion: not_evaluated` and declared
authored data ineligible as wall-latency evidence. All temporary traces/reports were removed.

Additional checks: Python AST parsed; `cases.json` parsed with 31 unique recipe IDs;
local Markdown link targets checked. These validate tooling and document navigation,
not native Smart Turn accuracy, physical echo, engine integration, resources or latency.

Native baseline/candidate collection, materialized audio hashes/annotations, held-out
statistics, ASR/TTS combinations and reference-machine/route/soak acceptance remain todo.
