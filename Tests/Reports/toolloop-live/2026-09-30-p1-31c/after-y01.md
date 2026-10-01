# Tool loop live eval — 2026-10-01 02:37:58 +0000

- Model: `appLLM` "Qwen3-4B-Instruct-2507" ctx=32768 role=`installed:unsloth/Qwen3-4B-Instruct-2507-GGUF/Qwen3-4B-Instruct-2507-Q4_K_M.gguf`
- Mode: only; pass bar 1/1; elapsed 8.8s
- Needle first: no
- Artifact: `unsloth/Qwen3-4B-Instruct-2507-GGUF/Qwen3-4B-Instruct-2507-Q4_K_M.gguf`; `/Users/sergekadjo/Library/Application Support/Next Notes/Models/unsloth--Qwen3-4B-Instruct-2507-Q4_K_M.gguf`; 2497281120 bytes
- Timing: per turn, first fixture result and completed reply; not first token or audio. One-time base-model warm-up excluded; Needle schema startup included. See JSONL.
- First verified fixture result: n=1, p50=1.618s, p95=1.618s
- Completed reply: n=1, p50=8.236s, p95=8.236s
- Whole case: n=1, p50=8.236s, p95=8.236s
- App peak RSS: 2938454016 bytes; excludes the Needle child.
- Classes: error=0 timeout=0 leak=0 refusal=0 wrong_tool=0 fabricated=0 missed_tool=0 ungrounded=0 filler=0 pass=1

| Case | Verdict | Seconds | Turns | Tools | Reply |
|---|---|---|---|---|---|
| Y01 | PASS | 8.2 | 1 | memory.remember(kind=profile,text=The user's brother's name is Cyril) | Saved: The user's brother's name is Cyril. |

## Non-PASS detail

## Model passes

- Y01: agent.typed/explicit-memory-save rules direct-intent prompt=0 completion=0 reasoning=0 ttft=0ms total=3ms finish=stop proposed=memory.remember executed=memory.remember
