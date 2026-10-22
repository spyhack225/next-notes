# Local model bake-off — 2026-10-05

Agent: bakeoff. Measurements in progress; this report will be replaced with the complete results.

Machine: Apple M3, 16 GiB RAM, 8 CPU cores. Installed app only for quality tests. The installed binary's initial SHA-256 is `1950a33b907599843f579d24ee98c4a53dcb1bc9e3215e17bdea0829a19b3619`.

## Completed quality measurements

| Candidate | Quick scores | Median | Range | Tool-loop peak RSS |
| --- | --- | --- | --- | --- |
| MiniCPM5-2B Q4_K_M | 5, 5, 5 /10 | 5/10 | 5–5/10 | 1841–1850 MiB |

All three MiniCPM runs: C01 PASS; C04 PASS; M03 PASS; M04 MISSED_TOOL; M05 UNGROUNDED; K01 MISSED_TOOL; R02 PASS; F03 WRONG_TOOL; A02 REFUSAL; N04 PASS.

Raw reports: `/Users/sergekadjo/Library/Caches/NextNotesBuild/quick/bakeoff-2026-10-05-minicpm/` (summary.json, run1–3.md, run1–3.md.jsonl, run1–3.log). Fixture clock: `2026-10-05T09:00:00-04:00`; timezone America/New_York; resolved context 32768.

The other four quality candidates are queued individually behind the shared heavy lock. The b10621 llama-bench target has built in scratch; idle throughput tests remain queued. No ASR-loaded floor result is available.

## Constraints and deviations

MLX is blocked: `~/Library/Caches/NextNotesBuild/mlx-bench` does not exist, and the direct user instruction prohibits installation. No MLX environment or weights have been installed or downloaded.

The optional llama-cli build unexpectedly invoked npm ci for its UI dependency in scratch (1053 packages). The build tree was terminated and its UI dependency directory removed. llama-bench had completed before that optional target began. No app installation occurred. The scratch tree will be deleted at the end; shared npm cache was not cleared.

A Homebrew llama-bench --version capability probe initialized Metal kernels before rejecting the argument; the probe was outside the gate and loaded no model. It provides no scored measurement. Every app/model measurement and the scratch build uses lockf plus gate.sh.

No source edits or model-choice changes. This folder is not a git worktree; commits are unavailable.
