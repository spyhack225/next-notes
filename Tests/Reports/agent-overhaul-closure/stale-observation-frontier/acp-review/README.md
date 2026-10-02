# Shared stdio EOF verification

The original shared `JSONRPCStdioClient` ignored stdout EOF, retaining an already-consumed ACP prompt until its unchanged 90-second timeout or explicit close. Both ACP and stdio MCP use that producer. This repair changes its terminal transition, without changing timeouts or adding retries, polling, a queue, or a second process.

## Original installed evidence

Root-brokered `make install OPEN=0` produced installed app48, compiler exit 0, binary SHA256 `8534d0135baaabb6b0f809af29cec41472bf3472fdaa5462c72138a6ce475128`. Original transport SHA256 `8265b2b878bc41e1125ffd838a764f4a94d064b6ec513eafad021be0c472bda5` was unchanged.

Actual `--selftest-acp` exited 1 in 5.699 seconds with exactly one failure: `ACP terminal: consumed prompt/peer EOF stayed pending until timeout or external close`. Its same owned session was then explicitly closed and prompt joined; the original failure was not replaced. Existing final streamed reply/whitespace, cancellation and permission fixtures supplied no other failure. Raw evidence is under `app48-original`; complete source/bundle invariance held.

The revised fixture SHA256 `9c4ef38bd0f0e5eca27d6c2bae4d53d7af27f4982d84438c98c82f11e2fd1c23` differs from prepared `5b39…` only in the expected EOF error text, approved before original48. Inputs, two-second harness observation, actual ACP timeout and all other verdicts are identical. Both copies are retained. The exact same revised fixture is required for fixed49.

## Producer change and fixed installed acceptance

Fixed producer SHA256 `762605da303a9080a4ec8f0449fb67feb02156ed19c9f3733dac477e9db0f201`. The existing state lock and pending table now arbitrate EOF, response, timeout and close once. EOF drains only after already-started output reads have parsed/detached their frames; valid responses still await the existing notification tail, preserving last streamed chunks before end_turn. Closed clients refuse new pending insertion. The actual error is plain: “The connection ended before a reply arrived.” It makes no process-death or effect claim.

`build49-source-manifest.json` differs from 48 only in this transport. Source whitespace verification passed. Root-brokered installed49 compiler exit 0 (23.01 seconds), binary SHA256 `df4d109026d8c734eee1e7c90f75eb5f60d8a950a2ff12060ae69c669c07d035`.

The exact same fixture with 20 added assertions fixture passes through actual ACP/session/shared transport/temp-peer paths. Prescribed installed gates all exited 0:

| Gate | Actual marker | Seconds |
| --- | --- | --- |
| ACP | `ACP_OK` | 1.885 |
| MCP | `MCP_OK` | 0.313 |
| ACP confirmation | `ACP_CONFIRM_OK` | 0.270 |
| Worker | `TASK_WORKER_ATTEMPT_OK: 531 cases` | 1.920 |
| Owner isolation | `STORE_ISOLATION_OK: 21 files and 32 defaults unchanged`; `TOOLLOOP_PRODUCTION_OK` | 33.403 |

`app49-fixed` records raw logs/stdout and actual command exits. Source and installed bundle before/after manifests match exactly. Root's read-only post48/post49 inventories find zero recognized remaining owned apps/fixture peers; no PID kill was performed. The full serial slot was returned before any subsequent main metadata source work.

## Execution boundaries

Build44/45 never executed. First child48 compile was sandbox-denied before source compilation; `build48-sandbox-denied.log` is not build evidence. Root subsequently brokered build48 and all native execution unrestricted. No child escalation/native/install command succeeded. Read-only child process inventory was also denied; root separately recorded `post48-owned-process-inventory.json` and `post49-owned-process-inventory.json`.

The task-harness reader privacy repair `e6e5790` was independently verified before protocol native execution. This protocol work supplies no actual cloud/provider/model/account/network integration. Fixtures use owned temporary Python peers and existing permission fixture answers only.

This is transport responsiveness and exactly-once continuation evidence, not exact ACP attempt ownership, healthy/stale process inference, effect reconciliation, safe automatic retry/recovery, or IM-16 hosting. Inherited stdout descriptors, malformed framing and stderr backpressure remain separate gaps.


## Retained ACP handshake metadata

`ACPSession.close` intentionally retains historical `sessionID`/`didInitialize`: the backend captures them for artifacts and initialization-vs-later-failure classification. `prompt` requires a current client; closed sessions refuse. Current production callers create fresh sessions. Settings executable resolution is not active session health, so resetting these fields would not repair the confirmed EOF failure.

## Archive and selective registration

See `staging-recipe.md` and `registration-HEAD-e6e5790.patch` for the exact seven registration lines against committed HEAD, excluding foreign App hunks. `producer-only.patch` pins the shared transport change. The child did not stage or commit. Source/native slot is released; further main work belongs to root.
