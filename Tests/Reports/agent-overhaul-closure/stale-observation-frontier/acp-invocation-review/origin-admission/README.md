# ACP session origin admission — verified bounded repair

See [actual original52/fixed53 verification](verification.md): original RED20/68, fixed six serial ACP runs green, six related flags green. Parent durable ACP/recovery/IM-16 and model gates remain open.

# ACP session origin admission — off-source preparation

2026-10-02. No Sources, index, roadmap, builder, installed app, ACP/MCP/native/model/account/grant or peer was changed or run by this preparation. Only public protocol documentation was read online. Python peer syntax was checked without execution; Swift fixture is inspection-only.

## First broken attribution contract

`ACPSession.handleNotification` consumes flattened session/update text/activity without verifying the original params.sessionId. `handleIncoming` marks permissionRelayed and publishes permission activity before checking its session scope; its existing broker/gate path can review a wrong conversation under the current task. `JSONRPCStdioClient.flat` already retains paramsJSON, and actual start retains the exact session/new result, so no transport metadata replacement is needed.

`proposed-ACPSession.swift.txt` adds the exact established nonempty String comparison to both existing handlers. Incoming permission first parses existing options to select the offered rejection, then rejects a missing/blank/nonstring/mismatched ID before permissionRelayed, publication, explicit harness approval or actual broker/gate. Notification rejects before reply accumulation or activity publication. No prompt-active check, Manager/model/global reply clearing, timer, queue or await is added. Existing suffix-method handling remains unchanged and is not claimed fully conformant.

Original source SHA `861bcfa619e51ffc285194f528da5c2bd94849ad64483044c03423f85bb87551`; proposed source SHA `bf134965208a9bfa1893c6769f4bbcfc37b146b0a93db673b8be64a4e5e76152`. This minimal proposal has an unresolved ordering caveat below; it is not ready to claim verified lifecycle correctness.

## Actual-session original-compatible fixture

API: `@MainActor ACPSessionOriginSelfTest.originalCases(root: URL, check: (Bool, String) -> Void) async throws`. Event capture uses the existing public subscribe callback. There is no existing injected permission handler in ACPSession; adding one solely for this fixture would expand the production API unnecessarily. Instead the fixture reuses the same real PermissionGate seam as the existing ACP flag, records only its own pending callbacks and declines them. It never approves, creates a standing grant or invokes a tool/effect. PermissionGrantStore's SelfTest constructor supplies empty grants, and `.privileged` never runs automatically regardless of saved settings.

The owned peer is written only under a unique canonical temporary root. Six modes: wrong, missing, blank, numeric session ID; matched positive; matched immediate-new scheduling control. The peer records the exact permission response into its own acknowledgement file. Wrong-scope activity and message chunks are checked through actual subscribed events and returned prompt text; wrong permissions must not reach broker/gate, permissionRelayed or published permission callbacks. The positive permission must reach the existing gate once and be declined. Both before-prompt and after-prompt valid updates are emitted through the same actual session/transport, using the existing cancel RPC solely as a delivery barrier. This is not a claim that a cancelled effect stopped; no effect exists in this peer.

Static inspection counts 68 assertions: six sets of eleven, one immediate-new positive, one owner-invariance check. Original prediction is five failures for each of the four invalid modes (20 total), not an actual runtime result. Existing ACP timeout stays90 seconds; a two-second harness observer closes and joins the SAME owned client on failure. Default flags, stream/whitespace/EOF/cancel and valid existing permission inputs must remain unchanged.

Fixture SHA `18b7069f924db55278217a25e9c4fbd86506e4dd402a6db345c825968b0a533d`. `session-origin-peer.py.txt` is the extracted exact peer for review, not a separately substituted runtime. `registration-proposal.txt` adds one call inside the existing ACP do, immediately after its EOF fixture, reusing the same unique temporary root and existing name/Bool check adapter. It changes no dispatcher or startup path.

## Immediate session/new ordering must be measured

Source fact: current shared transport detaches a response into a Task, resumes its request continuation there, then schedules subsequent notifications through another Task. `ACPSession.start` establishes sessionID only after the request await resumes. Actor admission order between that resumed start and a subsequent notification is not guaranteed by the source. Thus a legitimate notification sent just after a session/new response can potentially reach the new guard while sessionID is still nil and be discarded. This is a scheduling hypothesis, not a measured original user failure.

The immediate-new mode emits the valid session/new response and its valid update in one stdout write. After start, an existing cancel response supplies the notification-tail barrier, and subscribed events must contain that immediate update. Original and proposed producers must run this exact control. A single pass cannot exhaust scheduling permutations; record repeated actual results if needed and never turn unknown pre-establishment handling into a broad lifecycle claim. Do not hide a failure by removing the control, adding a fixed sleep/await, assuming prompt-active, buffering unauthenticated frames or adopting a session ID from a notification. Any confirmed scheduling failure needs the responsible ordering seam investigated before this guard is accepted; that would require root's additional reviewed ownership scope.

## Root-brokered acceptance proposal

1. Archive original source pins and unchanged fixture, then register/build/install only under root's future lease. Current source/build/native ownership has not been granted here.
2. Run the actual ACP flag with original Session. Preserve all inputs and raw actual failures/exit; the predicted20 is never a substitute for measurement. Check the immediate-new control is actually exercised, valid outside/after activity survives, and all owned peers are cleaned up.
3. Only after root review apply the guard, build fixed with EXACT same fixture, and compare actual producer/consumer observations. Investigate any new positive-control failure rather than weakening it.
4. Preserve installed ACP/MCP/ACP-confirm, worker629 (current audit parent baseline, recheck then), dedicated task-harness-read40, store-isolation and root's relevant prescribed gates. No cloud/provider/model/default, actual tool, owner task or account is required. Complete manifests, raw logs/exits and owned process cleanup remain mandatory.

## Protocol references and explicit limits

The [official v1 schema](https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/main/schema/v1/schema.json) requires sessionId as a String for session updates and permission requests. [Session setup](https://agentclientprotocol.com/protocol/v1/session-setup) assigns conversation identity in the new-session result. [Prompt/update lifecycle](https://agentclientprotocol.com/protocol/v1/prompt-turn) allows updates outside an active prompt and expects final tool updates after cancellation to remain observable. These support an identity check, not a prompt-active blanket discard.

The [official permission response](https://agentclientprotocol.com/protocol/v1/tool-calls#requesting-permission) uses a nested outcome. Current transport/session sends flat optionId; the fixture deliberately records that existing shape and does not claim full v1 conformance. Old toolCall fixtures omit required toolCallId; this new peer includes it, but does not alter old original regression inputs. These separate producer gaps remain open.

This preparation repairs scoped attribution only if proven. It supplies no exact SQL task/attempt/client/process ownership, same-client exclusion after close/reuse, recheck after broker/gate suspension, heartbeat/health/no-effect inference, terminal receipt reconciliation, auto-retry/recovery or IM-16 hosting. Those frontiers and the aggregate model-quality gate stay open.
