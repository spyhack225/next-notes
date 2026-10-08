# Model bakeoff — 2026-10-08

Blocked before model launch. The required >=10 GiB free-disk floor is not met. A read-only relay admission probe additionally rejected load 155.49 (>40) and free disk 8.44056 GiB (<10); swap was 5.21100 GiB (<=8). The subsequent independent sample at 20:36:56 UTC recorded free 8.43995 GiB, load 186.444/85.059/37.345, swap 5336.06 MiB. These are actual refused conditions, not model failures or passes. No heavy job was attempted and no model-evaluation claim was taken. No other agent's files/processes or owner caches were deleted to create headroom.

Installed app: `/Applications/Next Notes.app`, 0.2.24 (build 1), executable SHA-256 `ed67302fae3c246bbfc377be77e954a0070f17b3b4c5771cfe5e1a04e0d628ad`; codesign CDHash `31a3eb8ef49a405296fb7c80eb888c391d05cb41`, full CodeDirectory digest `31a3eb8ef49a405296fb7c80eb888c391d05cb41590d6ecad8258c0a03b13ec9`, authority Next Notes Local Signing, signed October 7 at 16:14:02. Metadata inspection did not launch the app. Worktree revision `c6d850c696747ac1097208b6abc01edd7c7355ae` is not a claim that the installed app matches this source tree. Hardware Mac15,12 / 16 GiB, macOS 27.2 (26B5091g), AC power, battery 100%; pmset records no thermal/performance warning. The existing normal installed app PID29701 was left untouched; its ASR/voice residency was not inspected. No ASR-overlap or quiet-machine qualification follows.

| Requested model/runtime | Current quick x3 median [min,max] / per-case verdicts | Decode256 / prefill~512,~2048 | Cold load / peak RSS / run load+swap | Status |
|---|---|---|---|---|
| MiniCPM5-2B GGUF Q4_K_M control | Not measured | Not measured | Not measured | Admission blocked |
| Qwen3.5-4B Q4_K_M | Not measured | Not measured | Not measured | Admission blocked |
| Gemma 4 E4B Q4_K_M | Not measured | Not measured | Not measured | Admission blocked; additionally never load ~5 GB while swap >6 GiB |
| Qwen3-4B-Instruct-2507 Q4_K_M | Not measured | Not measured | Not measured | Admission blocked |
| Apple Foundation Models (`--model apple`) | Not measured | Not measured | Not measured | Admission blocked |
| MiniCPM5-2B MLX 4-bit vs matched GGUF, x3 each | Not applicable | Not measured | Not measured | Parked pending measurements; no speed/feasibility verdict |

The owner keeps MiniCPM5-2B as the default/local brain unless a clearly better model also meets decode >=20 tok/s on this Mac with speech recognition loaded (target25–30). MLX runtime switching requires >=25% faster decode at the same 4-bit class AND feasible grammar-constrained tool calls and prefix-KV reuse. None of these contracts is established by this blocked report. No default, sampler, planner, saved choice or runtime was changed.

Read BRIEF.md, ../RULES-2.md, the relevant AGENTS.md top sections (this revision has no separate “Reuse, integrate and clean up” heading), PERFORMANCE-STANDARDS.md, the canonical October8 status audit, Scripts/pinned-quick.py, its selftest, and Scripts/run-selftest.sh before considering launch. The fixed retained bakeoff clock is `2026-10-05T09:00:00-04:00`, America/New_York. The runner accepts no implicit fixture clock: it requires --fixture-now. Every scored run needs10 unique rows, complete rawRounds, exact model/clock, one nonfallback model receipt, one matching final marker and matching exit. No runner thresholds or tests were changed. Runner unit tests were read, not executed; no native flags ran, so no current native final marker exists.

Historical evidence only: `/Users/sergekadjo/Library/Caches/NextNotesBuild/quick/bakeoff-2026-10-05-minicpm/summary.json` reports5/5/5, median5 [5,5], with each run ending `TOOLLOOP_LIVE_FAILED: 5/10`. Each has C01,C04,M03,R02,N04 PASS; M04/K01 MISSED_TOOL; M05 UNGROUNDED; F03 WRONG_TOOL; A02 REFUSAL. Qwen3's sibling summary reports6/6/6, median6 [6,6], each ending `TOOLLOOP_LIVE_FAILED: 6/10`; C01,C04,M03,M05,R02,N04 PASS; M04/K01/F03 MISSED_TOOL; A02 UNGROUNDED. The current pinned scorer accepts those retained rows/logs when given inferred failure exit1; the actual historical process exits were not independently recovered. These are older artifacts and do not supersede the audit's later Mini10/10x3,9/10x3, full25/30 and23/30, owner9/10, or ASR-overlapped C1 median42.20tok/s over604s. None was rerun.

Qwen3.5's retained run1 contains10 verdict rows but lacks a final score marker, model receipt and aggregate summary. It is unscored: C01,M03,M04,K01,R02 PASS; C04/F03 MISSED_TOOL; M05/N04 UNGROUNDED; A02 FILLER. Do not convert five PASS rows into a qualified5/10 measurement. Full per-case/path evidence is in `evidence/historical-rows.json`; original `.md`, `.md.jsonl` and `.log` files remain in the three sibling bakeoff directories, unchanged. No new model raw reports exist.

All requested current quick repetitions, per-case current verdicts, throughput, cold loads, peak RSS and model-run swap/load samples are not measured because admission failed. No llama-bench was built; the worktree app dependency pins llama.cpp b10621 in Package.swift, but correspondence to the installed runtime was not established. No substitute throughput estimate is reported. `--selftest-llm-metal` was not launched or assumed to provide every requested metric. Apple app RSS would also not establish whole-machine hosted-inference memory.

The requested `/Users/sergekadjo/Library/Caches/NextNotesBuild/mlx-bench` did not exist. No venv, mlx-lm package or model was created/downloaded; no matched prompt benchmark or grammar/KV feasibility probe ran. There is no owned MLX artifact to delete and no switching rule met. The benchmark remains open, parked until a compliant window. No wt-scratch/bakeoff2 or test TMPDIR was created.

Executed read-only admission/identity commands (outside heavy.sh because none compiles, launches NextNotes, loads a model or runs a native selftest):

```sh
agent-relay gate --max-swap-gb 8 --max-load 40 --min-free-gb 10 --path .
sysctl vm.swapusage
sysctl -n hw.model hw.memsize
df -k .
pgrep -fl 'swift-frontend|swift-build|NextNotes|llama|mlx'
codesign -dv --verbose=4 '/Applications/Next Notes.app'
shasum -a 256 '/Applications/Next Notes.app/Contents/MacOS/NextNotes'
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' '/Applications/Next Notes.app/Contents/Info.plist'
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' '/Applications/Next Notes.app/Contents/Info.plist'
sw_vers
pmset -g therm
pmset -g batt
```

A Python read-only evidence extraction imported the existing scorer, read historical JSONL/logs, and recorded disk/load, swap, binary hash and git revision in `evidence/machine-and-binary.json` and `evidence/historical-rows.json`. No model was imported or executed. Signature and admission output are retained in `evidence/installed-signature.txt` and `evidence/admission.json`.

Relay join/start succeeded in the canonical project's relay using the command-position option `agent-relay join --project /Users/sergekadjo/Documents/Claude/Projects/speechify --as claude2-bakeoff2 --runner codex`. This selects relay metadata only; no canonical source was changed. Initial worktree-local registration could not reach the orchestrator; prefix-position --project is unsupported. Corrected start receipt cursor804 and meeting explicit-go request cursor805 succeeded. No explicit go has been received in the retained finish inbox; no message delivery is treated as approval. Relay showed no machine claims at20:36:23, but that does not cure disk/load refusal. For any resumed model run, recheck foreign heavy processes, acceptance coordination and resources, obtain the required `agent-relay claim --as claude2-bakeoff2 --scope machine model-evaluation` in this project, launch only through ../heavy.sh and release immediately after the run. Never run simultaneous model loads. No heavy-wrapper run commands are reported as executed because there were none.
