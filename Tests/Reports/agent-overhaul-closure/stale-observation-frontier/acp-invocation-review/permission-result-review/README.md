# Verified root integration — original69/fixed70

Actual original69 RED3; unchanged new fixture fixed70 permission22/origin68/worker764 and all20 focused flags PASS. See [actual proof](native-verification/verification.md). The off-source preparation below remains historical, with no implied native verdict for its uncompiled sketch. Root producer and expectation upgrade provenance are archived separately.

---

# ACP permission result audit — off-source only

2026-10-02. No Sources, registry/index, roadmap, builder, installed app, peer/native/model/account/grant or tool changed or ran. Public official documentation was browsed. The peer was syntax-checked without execution; Swift fixture and producer sketch remain uncompiled. Root is independently implementing typed ACP attempt ownership; any future Session lease must be coordinated with that producer work.

## Confirmed source contract gap

The [official v1 permission contract](https://agentclientprotocol.com/protocol/v1/tool-calls#requesting-permission) and [v1 schema](https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/main/schema/v1/schema.json) require a nested result outcome: selected plus an offered option ID for a human allow/decline, or cancelled when a pending request is cancelled with the prompt. Current ACPSession returns a top-level optionId for every decision. JSONRPCStdioClient.onIncoming is restricted to async [String:String], so that existing API cannot represent the required nested object.

Source-wide search found ACPSession as the only onIncoming caller; the only reply invocation is the transport's same incoming-dispatch Task. MCP shares this transport but does not install an incoming handler. The existing outbound request paramsJSON overload already uses actor-serialized Sendable Data, then deserializes it inside the transport to construct the JSON-RPC envelope. Apply that exact seam to callback result JSON rather than introduce a JSON value abstraction, parallel handler, model pass or second transport.

`response-seam-proposal.swift.txt` sketches replacement async Data result, reply(id:resultJSON:), and local nested Foundation encoding. Keep all existing stream/frame/EOF/notification/pending locks and timers unchanged. This is an API proposal, not an applied repair or end-to-end claim. Root must rebase it against current Session ownership changes.

## Cancellation is not human rejection

PermissionGate.ask returns Bool false for human decline, caller cancellation and cancelPending. It removes the denied/cancelled review, so there is no retained semantic result to reconstruct. The transport's incoming handler runs in its own Task; checking Task.isCancelled does not observe Session.cancel or the backend's prompt task cancellation.

A bounded Session-owned turn-cancellation signal is therefore actually needed for the correct response branch. Set it before the existing cancel MainActor hop releases Gate waiters, reset at the actual next prompt entry, refuse authorization for valid late permission after cancellation, and recheck after broker/Gate awaits before returning selected. A single Boolean suits the observed production route (one new Session and one prompt per backend invocation); it does NOT claim arbitrary concurrent prompts, close/reuse or durable attempt fencing. If root's active invocation work already owns a precise cancellation signal, reuse it instead of adding a competing field. Do not widen PermissionGate's generic Bool API merely for this protocol caller.

## Original-compatible actual owned peer regression

`ACPSessionPermissionResultSelfTest.swift.txt`: @MainActor originalCases(root:URL, check:(Bool,String)->Void) async throws. The actual Session starts its owned peer under a canonical unique temporary child, performs the real handshake and prompt, receives a matched permission, then uses the existing real Gate once. Modes: allow (.once, no standing grant), decline, and actual Session.cancel while the permission is pending. Nothing executes: the peer advertises a fixture toolCallId but has no tool implementation or external effect. Actual returned prompt text/cancel error and exact JSON-RPC result bytes are checked.

The peer writes the received result verbatim to an owned acknowledgement file. It completes the SAME prompt even on the original malformed flat result, so an artificial peer timeout cannot replace the wire-shape failure. Cancel mode handles either order of cancel and permission response, waits for both, then emits the actual cancelled stopReason. Original cleanup closes/joins exactly once; owner store/default hash invariance is checked.

Static fixture count: 22 assertions. Original prediction: 3 nested-outcome failures (one per mode); actual original errors/inputs must be measured before implementation. Fixture SHA `76186b7cdafc8ab7f4ab1c934c3df847a6e452b0c3f32c58a0a518c50ce525a4`. Extracted `permission-result-peer.py.txt` is the exact embedded peer, not a substitute. Python syntax-only PASS, no peer invocation. No test lowers the production prompt/request timeout or grants a real tool action.

## Explicit legacy fixture contract upgrades

The origin68 fixture now contains one flat-wire assertion executed in six modes: wire == [optionId:reject-once]. A correct nested producer necessarily invalidates that characterization. Preserve its committed/source archive and original52/fixed53 evidence. After measuring the new permission-result ORIGINAL failure, make an explicitly documented assertion-only upgrade to nested selected/reject-once for those six existing cases; all wrong/missing/blank/numeric IDs, reply/activity/gate observations, immediate-new and outside/after-prompt inputs remain exact. This is a response-contract expectation upgrade, not weakening the origin-admission regression or discarding it.

The EOF fixture9c4 has no permission response-shape assertion and requires no input change for nested results. Existing AgentStdioFixtures ACP peer currently accepts any permission response, and its tool_call/permission toolCall omit schema-required toolCallId. Its positive success therefore does not prove response schema conformance. The new peer supplies toolCallId and enforces the exact result; do not silently repair or replace old original inputs in this slice. A full legacy fixture conformance upgrade is separate and must be labelled.

## Additional independent open defects

Current Session invents allow-once/reject-once fallback IDs when offered options are missing or cannot be decoded. A selected outcome must not invent an unoffered choice. This audit does not implement or verify malformed-options handling; it needs explicit boundary evidence and an honest invalid-request response, not a fabricated human cancellation.

Official session/cancel is a notification; current Session sends a request and awaits its response. Current peers answer that nonstandard request, masking possible 20-second delay with a notification-only real adapter. This is source-confirmed protocol mismatch, not yet an actual runtime failure here. If corrected separately, origin68's use of cancel-response as a delivery barrier will need an explicit harness upgrade to wait for observed owned events; changing production timing or adding a new gate is not the remedy. This nested-response sketch leaves cancel transport unchanged and makes no full protocol compliance claim.

## Future root-owned acceptance

Register the new call inside existing ACP do using the existing unique temp root/check adapter; no dispatcher/startup change. Root must first freeze current producers, install original and record actual three predicted shape failures across 22 assertions with full source/binary/bundle/raw-wire evidence. Then review Data seam, exact cancellation signal and documented legacy assertion upgrade, install fixed with EXACT same NEW fixture, and run full ACP identity/EOF/permission controls plus MCP, confirmation, current worker count, task-harness reader40, store isolation and production tool loop. Capture actual peer cleanup separately. Stop on introduced positive or ownership regressions; do not fix a grader or remove a scenario.

No result here proves exact attempt/process/client authority, heartbeat/health/staleness, external effect stop or success, receipt reconciliation, automatic retry/recovery, real provider/model/account integration or IM-16 hosting. Parent Phase6 and model gates remain open.
