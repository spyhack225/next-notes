# ACP origin admission: actual verification

2026-10-02. Root executed all builds and native tests. This child reviewed archived evidence and wrote this report only. No child Sources, index, build or native action occurred during this task.

## Confirmed cause and original failure

ACPSession consumed session/update text/activity and incoming permissions without comparing params.sessionId to the actual session/new result. Thus invalidly scoped peer messages became the current task's reply, activity and permission callbacks. The shared transport already preserved complete paramsJSON; the missing comparison belonged in the two Session handlers.

Installed original52 used Session SHA `861bcfa619e51ffc285194f528da5c2bd94849ad64483044c03423f85bb87551` and fixture SHA `18b7069f924db55278217a25e9c4fbd86506e4dd402a6db345c825968b0a533d`. Actual `--selftest-acp` exited 1, `ACP_FAILED: 20 rule(s) wrong`, with `ACP_ORIGIN_CHECKS: 68`. Each wrong/missing/blank/numeric ID mode failed five real consumer assertions: prompt return included foreign text; permission Gate callback admitted; permissionRelayed attributed; foreign activity published; permission callback published. All positive matched, immediate-new, outside-prompt and late controls passed.

These are actual failures, replacing the earlier historical planning prediction. The real existing Gate only recorded and declined owned fixture requests; nothing was approved, granted or executed. Peers and acknowledgements lived under a unique canonical temporary root.

Original52 installed binary SHA `2d57a43afedb9fbe01b6ac7ede86df7fa90b96ab03992c675cea1ea85741dee3`. Source drift[] and same-installed-binary were recorded. An earlier registration diagnostic compile error is preserved as `build52-registration-compile-error.log`; root corrected only its print call before actual original52. It is not native failure evidence and did not replace fixture inputs.

## Producer repair and unchanged fixed fixture

Fixed Session SHA `bf134965208a9bfa1893c6769f4bbcfc37b146b0a93db673b8be64a4e5e76152` requires the exact established nonempty String session identity. Notifications refuse before reply/activity mutation. Incoming permission first selects its offered decline, then refuses mismatched identity before permissionRelayed, publication, harness approval or broker/Gate callbacks. No prompt-active gate, model/Manager/transport change, reply clearing, production await, timer, queue or buffer was added.

Installed fixed53 uses EXACTLY the original fixture SHA above. First actual ACP exited 0, `ACP_OK: initialize, session, subscribe and permission relay hold`, `ACP_ORIGIN_CHECKS: 68`. The original twenty failures are gone; matched permission still reaches the Gate once and is declined. Matched immediate-new, outside-prompt and late updates remain observable. Existing EOF/close/cancel, final whitespace/notification ordering and valid permission/cancellation checks in the same flag remain green.

Fixed53 installed binary SHA `54d9eedc4b1e9f65771f274d87418bb1112e48b50965b5dab03cf95b1152063c`. The original ACP record is preserved in `app53-origin-checks.json`, separate from subsequent related-check records. Full source drift[], binary equality and bundle invariance are recorded.

## Related actual installed acceptance

| Gate | Actual outcome |
| --- | --- |
| mcp | Exit 0; `MCP_OK: initialize, session, list and call hold` |
| acp-confirm | Exit 0; `ACP_CONFIRM_OK` |
| task-worker-attempt | Exit 0; `TASK_WORKER_ATTEMPT_OK: 629 cases` |
| task-harness-read | Exit 0; `TASK_HARNESS_READ_OK: 40 cases` |
| store-isolation | Exit 0; `STORE_ISOLATION_OK: 21 files and 32 defaults unchanged` |
| toolloop-production | Exit 0; `TOOLLOOP_PRODUCTION_OK` |

Each listed native record also reports source drift[] and same installed binary=true; the root driver verifies whole-bundle equality. Raw app logs/stdout and compiler logs are retained. Five additional full unchanged53 ACP runs all exited0 with origin68, ACP_OK and unchanged Sources/binary/bundle; each raw stdout/log and per-run record is retained in app53-repeated-acp-checks.json. Targeted post-run inventory found zero recognized owned fixture peers or self-test app invocations; this is cleanup evidence, not global process liveness.

## Immediate-new scheduling boundary

Source scheduling concern: the transport detaches a response into a Task, then schedules subsequent notifications through another Task. Start sets sessionID after its request await resumes. A legitimate immediate notification could hypothetically run first and meet a nil-ID guard. No such dropped positive update was observed in original52 or any of the six fixed53 runs. The exact fixture packs new-session result and valid update into ONE stdout write; the existing cancel response provides a notification-tail delivery barrier. There is no inserted sleep or private-handler bypass.

The five further unchanged full ACP runs all passed this boundary. Repeated passes provide empirical coverage, not proof of all actor schedules or general nil-binding lifecycle correctness. Preserve any first failure and investigate the responsible ordering seam; never remove this positive scenario, buffer unauthenticated frames, adopt an ID from the notification or add a fixed delay to make it pass.

## Open protocol and durable-binding contracts

The [official v1 schema](https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/main/schema/v1/schema.json) requires String session IDs. [Session setup](https://agentclientprotocol.com/protocol/v1/session-setup) establishes conversation identity in session/new. [Update lifecycle](https://agentclientprotocol.com/protocol/v1/prompt-turn) permits updates outside active prompts, which is why this repair has no prompt-active rejection.

[Official permission responses](https://agentclientprotocol.com/protocol/v1/tool-calls#requesting-permission) use nested outcome. Current Session/transport replies flat optionId, and this fixture records that existing shape without full v1 conformance claims. Old positive fixtures omit required toolCallId; the new peer includes it without replacing the old regression. Those separate response/fixture conformance gaps remain open.

This proves bounded conversation-scoped attribution only. It supplies no exact SQL attempt/process/client ownership, old/closed-client exclusion, revalidation after broker/Gate suspension, health/stale/no-effect inference, fired-receipt reconciliation, safe automatic recovery/retry or IM-16 hosting. No real provider/cloud/model/account/network/tool integration was exercised. Parent Phase6 and aggregate quality gates remain open.
