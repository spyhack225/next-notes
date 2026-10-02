# Verified root integration — original67/fixed68

Actual original67 RED4; unchanged fixed68 worker764 and all20 focused flags PASS. See [verification](verification.md), actual raw logs/manifests/checks and original-fixed-source-difference.json. The handoff below is historical preparation; anticipated64/65/66 numbers and UNCOMPILED status there do not describe the actual root67/68 runs.

---

# ACP completion primary admission — off-source handoff

Status: UNCOMPILED / UNEXECUTED. Root owns integration and original65/fixed66 verification. Anticipated baseline is root64's reviewed startup receipt join, not an assertion that build64 passed.

## First broken producer contract

Original ACPAgentBackend.runSessionWithReceipt fire returns a real ACP outcome to ActionOrchestrator without TaskEventJournal.toolCompleted. Shared runtime retains its receipt; ACP then unconditionally constructs .completed outcome. A toolCompleted primary INSERT failure cannot prevent task success because ACP never attempts that write or observes its admission. This is source-confirmed missing capability; the same real fixture must reproduce it before claiming a native failure.

## Proposed producer

ACPAgentBackend only: capture the admitted start context; defer toolCompleted with exact prepared.id, tool id and backingReturned Bool; set backingReturned only immediately before returning the actual AgentToolResult. Preserve all existing runSession/workspace/permission behavior. Capture the admission Bool through the existing shared runtime call and guard afterward. No added await, timer, query, store, registry or schema. This adds the required completion transaction through the same Manager journalContext path already used by Local Executor.

When completion admission rejects after real return, shared runtime is still allowed to retain its .couldNotVerify receipt containing the real reply/session. The post-runtime guard then reports existing task-history-save failure plus 'Check the result before trying again.' Manager must settle failed with no result/artifact/success delivery. This is not proof of externally confirmed changes, no effects, healthy session, complete backing cessation, or permission to retry.

### Catch precedence review

The proposed catch mirrors AgentToolExecutor lines285–298: if fire's completion admission rejected and shared runtime also throws, retain runtime handling first, then expose missing primary completion authority. Otherwise preserve the original thrown error unchanged. Before fire/start admission, the Bool remains true and the original error keeps precedence. A failed start does not enter the defer. With an admitted start, a throwing/cancelled/handshake backing runs defer with succeeded=false; failed completion must not silently become a compatibility/retry route. No catch inside fire converts completion loss into .failed receipt: the error is raised after shared runtime has finished recording its actual evidence.

The supplied bounded fixture tests actual successful reply with accepted/rejected completion only. Throwing backing plus completion rejection, handshake plus rejection, concurrent cancellation and simultaneous terminal receipt writer failure are not claimed native proofs; relevant existing root regressions must remain green and those future original flows need their own unchanged evidence. No broader completion/recovery readiness claim.

## Actual original-compatible fixture

TaskACPReceiptCompletionSelfTest.swift.txt uses the same byte-identical owned peer, objective and response as the startup fixture. Both modes must actually initialize/new/prompt once and retain a real saved fired startup snapshot. The only rejected-mode intervention is a BEFORE INSERT toolCompleted trigger installed through the real backend-entry seam after committed ACP attempt. Startup join and toolStarted controls must remain green.

Both modes pin exact taskID, positive attempt/current process owner, prepared/action UUID/intent/tool/routing/objective, actual peer startup primary receipt link, terminal memory/SQL/fresh Manager receipt link and exact retained returned .couldNotVerify receipt. Accepted mode requires exactly one mcp.acp_session:returned event, original reply/artifact and job success delivery. Rejected mode requires rolled-back completion event, failed task/no result/artifacts, existing history-save diagnostic and no reply/artifact/job-success delivery; the returned receipt remains retained. Fresh actual Manager must consume those same histories without launching again. No invented receipts, fake backend, synthetic context, direct helper-only completion proof, owner payload or live grant.

Normal assertions: 33 = accepted16 + rejected17. Two exceptional cleanup assertion call sites only execute on timeout/error. Peer/protocol/snapshot invalidity throws a harness error; it cannot masquerade as a feature regression. Counts/verdict are predictions until root's installed actual run. Fixtures must be frozen unchanged original/fixed.

Artifacts: anticipated64-ACPAgentBackend.swift.txt (current62 plus approved startup hook), proposed-ACPAgentBackend.swift.txt, producer-proposal.patch, registration.json (append after startup fixture), owned-start-peer.py.txt. No Source/index/build/native/model changes by this review agent. Existing startup/unverified/primary fixture predicates need no completion expectation weakening.

P6-05/P6-06 aggregate contracts, latency/quality gates, complete session activity/nested permission/current-client provenance, compatibility/scheduled/remote/voice authority, recovery/retry and IM-16 remain open.
