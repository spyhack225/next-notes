# Floor and model bake-off reports

`Scripts/model-bench.py` (run it as `make bench-models BENCH_ARGS='…'`) writes one
`<date>-bakeoff.md` and `<date>-bakeoff.jsonl` here per run, plus a `<date>-bakeoff-logs/`
folder with each self-test's raw output. It makes PL-02 (candidate bake-off) a command
instead of a manual sequence. Nothing in it is a new harness: every number comes from an
existing `--selftest-*` flag.

```bash
make bench-models BENCH_ARGS='--dry-run'                 # the plan and exact commands, runs nothing
make bench-models BENCH_ARGS='--quick'                   # every installed candidate, every role
make bench-models BENCH_ARGS='--full --models minicpm,qwen3,gemma,apple'
Scripts/model-bench.py --quick --roles agent,cleanup --models minicpm --report-dir /tmp/bench
```

| Option | Meaning |
|---|---|
| `--models a,b` | Library id, display name, file name or fragment, `apple`, `s1-mini`. Default: every installed candidate plus Apple. |
| `--roles agent,cleanup,notes,speed` | Default all four. |
| `--quick` / `--full` | Quick: agent `--quick`, speed C1 for 10 fixed 256-token runs. Full: whole agent suite, plus C0 and a 10 minute sustained window. |
| `--dry-run` | Print the plan, commands, guardrails and read-only preflight; write nothing, start nothing. |
| `--report-dir` | Default `Tests/Reports/floor`. |
| `--allow-contended` | Run although the relay gate refused or other heavy work is visible. Every row becomes a diagnostic and cannot pass. |
| `--app`, `$NEXTNOTES_APP` | Which bundle to drive (default `/Applications/Next Notes.app`). |
| `--hash` | SHA-256 each selected model file that has no recorded digest. Off by default (reads GBs). |

**What it does per candidate and role.** One self-test at a time through
`Scripts/run-selftest.sh`: agent `--selftest-toolloop-live --model <id>`; cleanup
`--selftest-cleanup app-llm-compare --compare-only <name>` (Apple: `apple-grammar`,
S1-mini: `s1`); notes `--selftest-notes <wav> --notes-model <id>`; speed
`--selftest-llm-metal --floor --floor-model <id> --floor-asr <wav>`. While each runs it
samples the app's physical footprint once a second (`proc_pid_rusage`, not the slow
`footprint` tool) and system swap.

**What it will not do.** It does not write a role choice, the library selection or any
owner store: it records the `modelRoles.*`, `modelLibrary.*` and `cleanupEngine` defaults
and the `library.json` hash before and after every run and stops the matrix, exit 4, if
anything differs. It refuses to start unless `agent-relay gate` is ok, no build or
self-test is visible, and it holds a machine `heavy` claim (released on every exit path).

**Verdicts.** `pass` (every gated guardrail measured and met), `fail`, `incomplete`
(timeout, absent model, interrupted run, or a gated guardrail that nothing measured; never
turned into a score), `diagnostic-pass/fail` (contended), `gap` (the self-tests cannot
take this input yet), `recorded` (C0 reference row), `not_applicable`. Edit numbers in
`shared/model-guardrails.json`; `gated: false` turns a rule into information.

**Known gaps** (recorded in every report, nothing here edits Swift): warm first token
under a full voice turn (C2) is not produced by `--floor`; notes are checked for structure
and speed only (no SB-07 rubric); the cleanup comparison knows four hard-coded file
names; Apple has no decode tok/s probe; peak footprint covers the self-test process only.
