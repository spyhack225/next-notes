# Model bakeoff — 2026-10-08

Stopped after three hours without explicit go from `meeting-performance-20261007`. No model, native selftest, benchmark, build or heavy-wrapper command launched. This is an unmeasured result, not a model failure or pass.

The resumed request succeeded at 2026-10-08 21:10:53 UTC (relay cursor838, message `168abe66-6dd3-4e40-a5c0-e5a1a5e9bceb`). Eighteen successful inbox polls were retained at ten-minute intervals, from21:20:53 through2026-10-09 00:10:53 UTC. None contains a new message from the acceptance-window holder after the request. The read-only monitor then ended with `NO_GO_TIMEOUT_3H`. The earlier broadcast saying other agents could seek independent gates was not treated as the fresh explicit go required by this resumed instruction. Message persistence does not prove reading.

| Model/runtime | Current quick x3 median [min,max], case verdicts | Decode256 / prefill~512,~2048 | Cold load / peak RSS / run load+swap | Why not measured |
|---|---|---|---|---|
| Qwen3.5-4B Q4_K_M | Not measured | Not measured | Not measured | First priority; explicit go never arrived |
| Apple Foundation Models (`apple`) | Not measured | Not measured | Not measured | First priority; explicit go never arrived |
| Qwen3-4B-Instruct-2507 Q4_K_M | Not measured | Not measured | Not measured | Lower priority; explicit go never arrived |
| Gemma4 E4B Q4_K_M | Not measured | Not measured | Not measured | Lower priority; explicit go never arrived; finish swap also exceeds6GiB large-model limit |
| MiniCPM5-2B GGUF control | Not rerun | Not measured | Not measured | Retained owner evidence preserved; explicit go never arrived |
| MiniCPM5-2B MLX4-bit vs GGUF, x3 each | Not applicable | Not measured | Not measured | Parked; no go or preceding measurements; continuous >=12GiB disk condition not established |

Installed app at both start and finish: `/Applications/Next Notes.app`, version0.2.24(build1), executable SHA256 `ed67302fae3c246bbfc377be77e954a0070f17b3b4c5771cfe5e1a04e0d628ad`. Codesign CDHash `31a3eb8ef49a405296fb7c80eb888c391d05cb41`, authority `Next Notes Local Signing`; full start/finish signature output is retained. The worktree's sources are not claimed to match the installed binary. No saved choice, default, owner store or installed bundle was changed. No ASR/voice overlap, quiet-machine or thermal performance qualification follows from metadata inspection.

Resumed start disk sample:16185808KiB available (about15.44GiB), swap5532.06MiB. Finish sample at00:11:05 UTC: free12.754GiB, load3.660/4.491/5.326, swap6793.06MiB (6.634GiB). These are waiting-window samples, not model-run samples or an admission pass. No current heavy gate was invoked because explicit go was absent. The previous disk/load refusal and report remain at commit7799ba8 and `RESULT-previous.md`; their8.44GiB/155.49 figures are historical, not the resumed start conditions. Peers reported intervening disk pressure; that is peer evidence, not our continuous disk trace. No foreign cache or process was altered to create headroom.

Read before considering runs: BRIEF.md, updated ../RULES-2.md, AGENTS.md top contracts, PERFORMANCE-STANDARDS.md, canonical October8 status audit, Scripts/pinned-quick.py and its complete selftest, Scripts/run-selftest.sh, and heavy.sh v2. No runner, threshold, grader, source or fixture changed. No unit/native selftest was executed; no native final marker exists. The intended fixed clock remains `2026-10-05T09:00:00-04:00`, timezoneAmerica/New_York. Qwen3.5's exact retained pin is `unsloth/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf`. A scored run must have10 unique case rows with rawRounds, exact model/clock, nonfallback model receipt, consistent final marker and exit. On resumption, run Qwen3.5/Apple quickx3 first, separately claimed and serialized through ../heavy.sh, then throughput/memory, then MLX only with maintained >=12GiB disk. Exit75 means held/not run and requires retry, never a pass; no such wrapper exit occurred here.

Raw coordination paths: `evidence/resumed/wait-result.json` lists all18 inbox paths and request/start IDs; `evidence/resumed/relay-start.json`, `relay-finish.json`, and `installed-signature{,-finish}.txt` retain board and signature snapshots. No new model raw reports exist. Historical case rows remain in `evidence/historical-rows.json` and original reports under `/Users/sergekadjo/Library/Caches/NextNotesBuild/quick/bakeoff-2026-10-05-{minicpm,qwen3,qwen35}`. Older Mini5/5/5 and Qwen3 6/6/6 failures are historical; Qwen3.5's incomplete run is unscored. None was rerun. Preserve the later audit's Mini10/10x3 then9/10x3, full25/30 and23/30, owner9/10 and ASR-overlapped C1 median42.20tok/s over604s as evidence for those particular artifacts, not today's measurement.

Exact executed coordination commands (all use shared relay metadata only):

```sh
agent-relay join --as claude2-bakeoff2 --runner codex --project /Users/sergekadjo/Documents/Claude/Projects/speechify
agent-relay send --as claude2-bakeoff2 --to claude-positioning --project /Users/sergekadjo/Documents/Claude/Projects/speechify --message 'bakeoff2 resumed: requesting explicit meeting acceptance go; measurements only via heavy.sh v2, Qwen3.5 and Apple quick x3 first.'
agent-relay send --as claude2-bakeoff2 --to meeting-performance-20261007 --project /Users/sergekadjo/Documents/Claude/Projects/speechify --message 'Please give explicit go for bakeoff2 model measurements when your native acceptance window permits. Disk cleared to 15 GB. Will use heavy.sh v2 plus per-run machine model-evaluation claim, one model at a time; Qwen3.5 and Apple quick x3 first. Waiting up to 3 hours, inbox every 10 minutes; no native run before explicit go.'
agent-relay inbox --as claude2-bakeoff2 --unread --project /Users/sergekadjo/Documents/Claude/Projects/speechify
agent-relay agents --active --project /Users/sergekadjo/Documents/Claude/Projects/speechify
codesign -dv --verbose=4 '/Applications/Next Notes.app'
shasum -a 256 '/Applications/Next Notes.app/Contents/MacOS/NextNotes'
sysctl vm.swapusage
df -k .
```

Initial worktree-local sends could not find recipients; both messages then succeeded with the explicit shared project above. No claim was acquired. The monitor called only inbox, saving JSON; waits were divided into <=60s intervals. Read-only Python also retained binary hash/version, disk/load/swap and asserted no fresh acceptance-holder messages in the18 polls.

No llama-bench was built. Package.swift pins llama.cpp b10621, but correspondence with the installed runtime is unverified. The basic Metal coexistence test does not provide the entire requested per-model benchmark. No MLX venv/model was created or downloaded, so there is no owned MLX artifact to delete. No wt-scratch/bakeoff2 or native-test TMPDIR was created. MLX remains **parked**: >=25% faster same4-bit decode, grammar-constrained tool calls and prefix-KV reuse were not evaluated. Mini remains the owner's default; no model/default/runtime promotion follows. Decode>=20tok/s with ASR loaded (target25–30), quality and broader acceptance contracts remain unchanged.

Changed files: this report and evidence/resumed/ only, plus ignored local RESULT.md. No canonical edits, install, push, merge or source conflicts. The next measurement attempt needs a fresh explicit acceptance-window go and actual resource/claim admission; disk availability alone is insufficient.
