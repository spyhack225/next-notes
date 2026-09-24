# P0-01 — model state repair on the development Mac

Date: 2026-09-23. Executor: the owner performed the model actions; the executor recorded them,
applied the three settings the owner authorised in writing, and verified from a terminal.

## Before

Read on 2026-09-23 at 23:39 local, before the writes:

```
"modelRoles.agent" = "installed:unsloth/Qwen3-4B-Instruct-2507-GGUF/Qwen3-4B-Instruct-2507-Q4_K_M.gguf";
"modelRoles.meetingNotes" = builtin;
"modelRoles.computerUse" = "app:codex";
"modelLibrary.activeAgentModelID" = "unsloth/Qwen3-4B-Instruct-2507-GGUF/Qwen3-4B-Instruct-2507-Q4_K_M.gguf";
"modelLibrary.postDownloadPolicy" = switchDeleteOld;
openRouterAgentModelID = "inclusionai/ling-3.0-flash-sante:free";
```

`Models/` held no `k2-horizon` file and did hold
`unsloth--Qwen3-4B-Instruct-2507-Q4_K_M.gguf` (2,497,281,120 bytes). The owner had already
deleted K2-Horizon and installed rank 1, and the Agent role already pointed at it.

`Scripts/run-selftest.sh --selftest-llm-metal` before any Phase 0 change:

```
note: Gemma 4 E4B is not downloaded (4.64 GB); running the GPU half on S1-mini instead.
LLM_METAL_OK: metal on, GPU runtime and CPU runtime both ran in one process, peak RSS 896 MB
```

This is the false-green Phase 0 removes: it proves Metal, not that the Agent role's model can
answer. The agent-role leg (`LLM_METAL_AGENT_ROLE`) is P0-02's addition.

## What changed

Owner actions, confirmed by terminal read:

| Item | Before | After |
|---|---|---|
| `modelRoles.agent` | `installed:unsloth/Qwen3-4B-Instruct-2507-GGUF/Qwen3-4B-Instruct-2507-Q4_K_M.gguf` | unchanged (already correct) |
| `modelRoles.meetingNotes` | `builtin` | `apple` |
| `modelRoles.computerUse` | `app:codex` | `apple` |
| `modelLibrary.postDownloadPolicy` | `switchDeleteOld` | `downloadOnly` |
| `Models/K2-Horizon-4B-Q4_K_M.gguf` | 3.16 GB present | deleted (owner, via the app) |
| `Models/unsloth--Qwen3-4B-Instruct-2507-Q4_K_M.gguf` | absent | 2.50 GB installed |

The three settings were applied with `defaults write ai.pivotstudio.nextnotes …` while Next
Notes was not running, under the owner's explicit written authorisation (P0-01 steps 1–2). The
app was not running at the time, so nothing overwrote them.

Reasons, from P0-01 step 1b: Codex is out of quota until 2026-09-26 15:43 and every "open …"
cost 9 s and showed a raw error (P1-12 fixes it); `switchDeleteOld` would delete the model that
now answers (P0-02 changes the policy logic); meeting notes stay on Apple's model until P0-04's
chat-template work lands, because MiniCPM5's tool delimiters are control tokens (G N3).

## After — verification

```
$ defaults read ai.pivotstudio.nextnotes | grep -E "modelRoles|modelLibrary|openRouterAgentModelID"
"modelLibrary.activeAgentModelID" = "unsloth/Qwen3-4B-Instruct-2507-GGUF/Qwen3-4B-Instruct-2507-Q4_K_M.gguf";
"modelLibrary.postDownloadPolicy" = downloadOnly;
"modelRoles.agent" = "installed:unsloth/Qwen3-4B-Instruct-2507-GGUF/Qwen3-4B-Instruct-2507-Q4_K_M.gguf";
"modelRoles.coding" = "app:claude";
"modelRoles.computerUse" = apple;
"modelRoles.meetingNotes" = apple;
openRouterAgentModelID = "inclusionai/ling-3.0-flash-sante:free";

$ ls -la ~/Library/Application\ Support/Next\ Notes/Models/ | grep -i qwen
unsloth--Qwen3-4B-Instruct-2507-Q4_K_M.gguf  2497281120 bytes

$ df -h /
/dev/disk3s1s1   228Gi    13Gi   3.3Gi    80%
```

## Done-when checklist (P0-01)

- [x] The Agent role and the meeting-notes role are on a model that answers — Agent on Qwen3-4B
      (rank 1), meeting notes on Apple's built-in intelligence.
- [x] "Controlling your Mac" is off Codex; the typed Agent is not on a reasoning OpenRouter
      model (the Agent role is local, so `openRouterAgentModelID` does not apply until P4-09).
- [x] The post-download policy is `downloadOnly`.
- [x] K2-Horizon is deleted.
- [x] Qwen3-4B-Instruct-2507 Q4_K_M is installed.
- [x] The Agent role points at Qwen.
- [x] This report is committed, and `STATUS.md` records the before and after lines.

## Pending, by design

- `LLM_METAL_AGENT_ROLE: Qwen3-4B-Instruct-2507 generated N token(s)` requires P0-02's
  agent-role leg.
- `--selftest-agent-answers` (P0-14b) is the Phase 0 exit harness and does not exist yet.

Both are the next tasks on the Phase 0 chain (P0-13 → P0-14 → P0-03 → P0-02).
