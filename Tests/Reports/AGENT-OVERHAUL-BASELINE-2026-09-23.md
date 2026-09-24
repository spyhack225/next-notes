# AGENT-OVERHAUL baseline — 2026-09-23

Captured per `roadmap/in-progress/AGENT-OVERHAUL/00-README.md` §7, on a freshly built and
installed copy of the tree at commit `5b16b2c70f5c8e1660765ecdd76a53e4b08cbff4`.

**The working tree had uncommitted changes** (74 modified files, including `AGENTS.md`,
`Makefile`, `Scripts/run-selftest.sh`, `Sources/NextNotes/Agent/RealtimeAgent+ToolLoop.swift`,
`Sources/NextNotes/Agent/VoiceConversationCoordinator.swift`,
`Sources/NextNotes/Formatting/LLM/NotesModelRuntime.swift` and the model-library files). The
baseline therefore describes the tree as it stands, not the commit alone.

Build: `make build` + `make install OPEN=0`, both clean.
Fixture: `say` + `afconvert` → `~/Library/Caches/NextNotesBuild/agent-overhaul/haiku16k.wav`
(LEI16@16000). Raw outputs: `~/Library/Caches/NextNotesBuild/agent-overhaul/baseline/`.

## Flag results

| Flag | Final line |
|---|---|
| `--selftest-model-roles` | `MODEL_ROLES_OK: fallback, routing, call paths, discovery and tool-call bridging verified` |
| `--selftest-model-fit` | `MODEL_FIT_OK` |
| `--selftest-llm-metal` | `LLM_METAL_OK: metal on, GPU runtime and CPU runtime both ran in one process, peak RSS 896 MB` |
| `--selftest-hf-search` | `HF_SEARCH_OK` |
| `--selftest-toolloop` | `TOOLLOOP_OK` |
| `--selftest-toolloop-production` | `TOOLLOOP_PRODUCTION_FAILED` |
| `--selftest-voice-scheduling` | `VOICE_SCHEDULING_OK` |
| `--selftest-concurrent-voice` | `CONCURRENT_VOICE_OK` |
| `--selftest-acp-confirm` | `ACP_CONFIRM_OK` |
| `--selftest-voice-delivery` | `VOICE_DELIVERY_OK` |
| `--selftest-voice-turn-routing` | `VOICE_TURN_ROUTING_OK` |
| `--selftest-voice-conversation` | `VOICE_CONVERSATION_OK` |
| `--selftest-persona` | `PERSONA_OK` |
| `--selftest-ui-strings` | `UI_STRINGS_OK` |
| `--selftest-tasks` | `TASKS_OK: submit, run and cancel hold` |
| `--selftest-scheduler` | `SCHEDULER_OK` |
| `--selftest-residency` | `RESIDENCY_OK` |
| `--selftest-memory` | `MEMORY_OK` |
| `--selftest-openrouter-contract` | `OPENROUTER_CONTRACT_OK` |
| `--selftest-metrics` | `METRICS_OK` |
| `--selftest-voice-pipeline <haiku16k.wav> --voice-feed-10ms` | `VOICE_PIPELINE_FAILED` |

Two failures, both expected and both the point of Phase 0:

- `--selftest-toolloop-production` fails with
  `TOOLLOOP_PRODUCTION_WRONG: conversation prompt still carries the full tool roster (3924 chars, persona 1003)`
  and `TOOLLOOP_PRODUCTION_WRONG: planner prompt too large in the live loop: 1521 tokens for 12 tools`.
  This is the live-bug family (P0-05, P1-03, P1-06).
- `--selftest-voice-pipeline` fails; Phase 2 owns the number.

`--selftest-llm-metal` is green **while the Agent role cannot answer** — it says
"Gemma 4 E4B is not downloaded (4.64 GB); running the GPU half on S1-mini instead." This is the
false-green the roadmap calls out: P0-02's agent-role leg is what makes it tell the truth.

## Voice pipeline numbers

| Measure | Value |
|---|---|
| `VOICE_MODEL_EOU_TO_ENDPOINT` | 0.0644 s |
| `VOICE_PIPELINE_ENDPOINT_TO_FIRST_AUDIO` | 2.164 s |

## Tests and acceptance

- `make test`: 30 tests in 2 suites passed (0.397 s) — dictionary and spoken-form vectors green.
- `make acceptance TIER=core`: `CORE 12/14 PASS`.
  - `FAIL core --selftest-wake-live`: `WAKE_LIVE_FAILED: 17/24 hits, 3/32 false at sens 0.6 —
    hit rate 0.71 under 0.8 at sensitivity 0.6; 3 false accepts over 2 at sensitivity 0.6`.
    Known red at the shipped sensitivity; the roadmap says it stays red.
  - `FAIL core --selftest-computer`: `COMPUTER_FAILED: inspect did not see the self-test OK
    button`. Known red on a locked screen.
- Logs: `~/Library/Caches/NextNotesBuild/acceptance/20260923-234130-12038/`.

## Machine state at capture

```
$ df -h /
/dev/disk3s1s1   228Gi    13Gi   3.3Gi    80%    484k   34M    1%   /

$ defaults read ai.pivotstudio.nextnotes | grep -E "modelRoles|modelLibrary"
"modelLibrary.activeAgentModelID" = "unsloth/Qwen3-4B-Instruct-2507-GGUF/Qwen3-4B-Instruct-2507-Q4_K_M.gguf";
"modelLibrary.postDownloadPolicy" = switchDeleteOld;
"modelRoles.agent" = "installed:unsloth/Qwen3-4B-Instruct-2507-GGUF/Qwen3-4B-Instruct-2507-Q4_K_M.gguf";
"modelRoles.coding" = "app:claude";
"modelRoles.computerUse" = "app:codex";
"modelRoles.meetingNotes" = builtin;
openRouterAgentModelID = "inclusionai/ling-3.0-flash-sante:free";

$ ls -la ~/Library/Application\ Support/Next\ Notes/Models/
embeddinggemma-300M-qat-Q4_0.gguf   277 MB
library.json
needle3-macos-arm64                 825 KB
needle3.cact                         35 MB
potion-retrieval-32M.safetensors    129 MB
potion-retrieval-32M.tokenizer.json 1.5 MB
s1-mini-q4_k_m.gguf                  484 MB
unsloth--Qwen3-4B-Instruct-2507-Q4_K_M.gguf  2.50 GB
```

`K2-Horizon-4B-Q4_K_M.gguf` (3.16 GB) is no longer present: the owner deleted it during
P0-01, before this snapshot. The three settings the owner authorised afterwards
(`modelRoles.meetingNotes = apple`, `modelRoles.computerUse = apple`,
`modelLibrary.postDownloadPolicy = downloadOnly`) are recorded in
`AGENT-OVERHAUL-P0-01-2026-09-23.md`.

## Notes for later gates

- `--selftest-toolloop-production` is red at baseline. A Phase 0 gate comparison must treat it
  as the thing Phase 0 fixes, not as a regression.
- `--selftest-wake-live` and `--selftest-computer` are red at baseline and stay red.
- Acceptance logs land per run under `~/Library/Caches/NextNotesBuild/acceptance/`.
