# Installed verification — original61 RED3 / fixed62 worker701

The runtime fix and identical actual fixture are now verified through installed builds. All20 focused flags pass. See [verification.md](verification.md), actual compiler manifests, binary identities and raw logs. The preparation-only notes below and in CURRENT-FIXTURE/TERMINAL-GUARD-REVIEW are retained historical handoff, not the current execution verdict. Parent Phase6/recovery/IM-16 and aggregate gates remain open.

# ACP unverified terminal receipt audit — preparation only

Date: 2026-10-02. Scope: source inspection and an off-source regression proposal. No
Sources, index, build, installed bundle, native process, model, account, or owner payload
was changed/read by this audit. No original failure or fixed verdict has been run.
Root owns implementation, installation, and before/after execution.

**Current handoff supersedes the historical scaffold/attempt assumptions below:**
root's integrated app60 now routes the existing receipt context and binds normal typed
ACP to attempt1/current process ownership. See [current fixture handoff](CURRENT-FIXTURE.md)
and `TaskACPUnverifiedReceiptSelfTest.swift`. No routing scaffold is needed for the
next original terminal-save reproduction. The original audit below is retained as
the earlier source observation, not the current implementation contract.

The candidate is at `Sources/NextNotes/Agent/ActionRuntime.swift:737–749`: after a
successful backing with no independently verified effect, `allowUnverifiedResult`
sets result/artifacts/verification/completedAt, discards `receiptStore.record`'s Bool,
and returns the result. The verified terminal branch at approximately line 757
already admits its existing terminal save before returning (P6-06d). This is a
source-confirmed unchecked decision; its product failure remains **unreproduced**.

## Production path and first prerequisites

| Producer/consumer | Source pin | Relevant contract |
|---|---|---|
| Manager temporary-store seam | `Agent/Tasks/AgentTaskManager.swift:39` | Inject real task store and optional existing receipt store. |
| Manager primary submit/start | same file `:197`, `:635–690` | `submit` persists first; actual registry dispatch executes under the manager's TaskJournalContext. |
| Context receipt injection | same file `:879–984`; `Tasks/Durable/TaskEventJournal.swift:32–44` | Existing context carries receiptStore; ACP has attempt zero and no local validity/lease binding. |
| ACP fixture entry | `Agent/Backend/ACPAgentBackend.swift:131–139` | `acpFixture` launches the supplied owned Python peer through the actual receipt/session path; no installed CLI or model selection. |
| ACP receipt producer | same file `:469–521` | `execute` sets allowUnverifiedResult true; currently omits receiptStore. |
| Session/transport/backing | same file `:353–421`; `Agent/Backend/ACPSession.swift:27–81` | Real initialize/new/prompt JSON-RPC and streamed message accumulation. |
| Verification | `Agent/ActionRuntime.swift:879–887` | `mcp.acp_session` requires result.verification; a successful protocol reply alone is deliberately unverified. |
| Writer refusal/rollback | same file `:411–429`, `:442–459` | Changed/nonregular source returns false and restores committed receipt memory. |
| Manager terminal/result consumer | `Agent/Tasks/AgentTaskManager.swift:691–717`, `:781–803`, `:849–877`, `:1025–1045` | Returned outcome becomes completed SQL history/jobCompleted/result announcement; thrown error becomes failed history/jobFailed/error announcement. |

**Required API-only original-proof scaffold:** route the already existing optional
TaskJournalContext receiptStore to ACP's existing `execute` argument, only when
context.taskID equals the submitted task.id, with the normal `.shared` fallback.
Use the same expression already exercised at `Agent/Tools/AgentToolExecutor.swift:216`:

```swift
receiptStore: (TaskEventJournal.current?.taskID == task.id
    ? TaskEventJournal.current?.receiptStore : nil) ?? .shared,
```

Do not silently call the untouched original an on-disk regression: in SelfTest,
the ACP omission currently chooses `.shared`, whose receipts are intentionally
empty/memory-only (`ActionRuntime.swift:375–390`, `:412`). The scaffold supplies no
new state, save, query, await, retry, timer, attempt authority, or receipt schema.
It must exist unchanged in both original and fixed builds. Pin its diff/hash and
freeze the actual fixture before running original RED. Repairing the terminal Bool
must be the subsequent, isolated producer change.

The existing `Settings.shared` reader uses SelfTestHarnessDefaults, not owner
UserDefaults (`Support/Settings.swift:1148`). PermissionGrantStore begins empty and
does not save owner grants under SelfTest (`Permissions/PermissionBroker.swift:138–165`).
ACP handoff usage goes to the per-process temporary usage sink (`Support/Usage/UsageLog.swift:19`).
These source contracts still require the root's normal isolation evidence; unchanged
owner bytes are not by themselves proof of no owner reads.

## Smallest unchanged actual fixture

Use two cases: `accepted` and `terminal-write-rejected`. For each, create one fresh
resolved child of the system temporary directory. Reject unsafe roots, symlinks
escaping that root, and any Application Support component before constructing stores.
Use the existing real stores, not substitute helpers:

```swift
let sql = TaskStore(root: directory)
let export = directory.appendingPathComponent("agent-tasks.json")
let store = AgentTaskStore(fileURL: export, mirror: sql)
guard store.allowsHarnessPersistence else { /* fail before work */ }
let receipts = ActionReceiptStore(fileURL: directory.appendingPathComponent("action-receipts.json"))
let manager = AgentTaskManager(store: store, receiptStore: receipts)
manager.backendEntryForTesting = { captured = TaskEventJournal.current }
manager.backendExitForTesting = { exited += 1 }
manager.announcementForTesting = { announcements.append($0) }
let task = manager.submit(objective: "Owned ACP receipt fixture: no tools",
    arguments: ["acpFixture": script.path], backend: .acp, source: "selftest")
```

Give the task no project reference. ACP's fixture entry does not pass a checkout
directory anyway, so checkout verification is nil and no repo or owner workspace
is scanned. The attached owned peer proposal reads only its sibling config and the
explicit temporary receipt file. Configure mode, a unique reply marker, and expected
objective before submitting. It uses only initialize, session/new and session/prompt.
It sends a matched agent_message_chunk and end_turn, with no activity or permission
updates. This preserves the real accumulated result without activating ACP's
subscription callback at `ACPAgentBackend.swift:365–384`, which currently looks up
AgentTaskManager.shared. Testing that global event-routing issue is separate work.

At actual prompt consumption, the peer must see exactly one admitted fired receipt
for the unique fixture objective, save a byte-identical snapshot, and count the actual
protocol calls. In the refusal case it moves that exact file to retained-fired.json
and creates an empty directory at the original receipt path **before** sending the
successful reply. Both unverified-stage and terminal record attempts will refuse;
this is intentional deterministic source rejection, not a race claiming to reject
only the final I/O syscall. The current terminal record still demonstrably returns
false and must not authorize successful result delivery.

Wait through Task.yield within a bounded harness deadline for the actual manager's
terminal status and backend-exit hook. Do not add a production timer or sleep.
Failure/timeout must remain a failed fixture and use owned-peer cleanup; never
replace the scenario by calling ActionOrchestrator directly or manufacturing an
AgentTaskOutcome. Parent handles installed-process timeout/cleanup through the
existing wrapper and can preserve the case directory for inspection.

## Assertions and evidence to retain

Common assertions must establish one initialize/new/prompt, one backend start/exit,
the exact original objective, TaskJournalContext.taskID equal to manager task ID,
context.receiptStore identical to the injected object, and the prompt-boundary receipt
with matching taskID/toolID/prepared action routing. Decode ISO-8601 receipt bytes
using the actual receipt schema or a fresh ActionReceiptStore over the snapshot.

ACP is unbound today. Assert/record attempt zero, nil taskAttempt/taskLeaseOwner and
no durable receipt-ID join rather than pretending this is P6-06c local authority.
The peer session ID is a protocol artifact, not proof that an external effect occurred.

| Observation | Accepted control | Refused original regression, expected after repair |
|---|---|---|
| Actual protocol reply | Marker streamed once | Same marker streamed once; no invented tool result |
| Terminal receipt | couldNotVerify; exact result, session artifact, completedAt and unverified verification persisted | Memory and retained file preserve exact original fired receipt; refused path remains empty directory |
| Manager memory and fresh SQL | completed; marker/result and protocol artifact present | failed; result nil; no completed result/artifact delivery |
| Journal | jobCompleted present | jobFailed present; jobCompleted absent |
| Actual announcement callback | Marker delivered; artifact announcement exercised | Marker and artifact announcement absent; exact persistence failure delivered |
| Failure sentence | none | `The action ran, but its result could not be saved. Check it before trying again.` |
| Fresh manager + fresh receipt reader | Same terminal row, no dispatch | Same failed row, no dispatch; retained evidence unchanged |

On the scaffolded original, predict the refused case instead completes and announces
the marker while the committed receipt remains fired. Capture the actual verdict and
failed assertion names; predictions in this audit are not results. Keep the exact
fixture bytes and scaffold identical for root's original/fixed builds.

The smallest proposed repair is guarding the existing `receiptStore.record(receipt)`
at the allowUnverifiedResult terminal branch and throwing the existing P6-06d
action-ran/result-not-saved failure on false. Preserve couldNotVerify status so the
catch does not append a false failed-action receipt. Add no save or retry. The first
actual RED may identify an additional producer bug; investigate instead of weakening
the fixture.

## Existing weaker compatibility path — separate control

`ACPCompatibilityCLIBackend.submit(_:explicitApproval:)` (`:75–145`) is a distinct
one-shot launch path, not ACP and not an automatic fallback. It checks scheduled
source and explicitApproval, constructs `mcp.acp_compatibility_cli`, and calls the same
orchestrator with allowUnverifiedResult true (`:130`). It also currently omits context
receiptStore. Manager's `approveCompatibilityCLI` (`:336–351`) commits queued state
before minting one token; actual dispatch consumes it at `:681–683`. `request(for:)`
checks frozen command/directory (`ACPCompatibilityCLIBackend.swift:42–63`).

The existing `--selftest-acp-confirm` uses `runGuardSelfTest` (`ACPConfirmation.swift:273`):
this is explicitly a pure no-process guard control, not disk terminal persistence or
an actual compatibility launch proof. Preserve that flag and report it honestly.

A separate optional actual control can use a safely seeded temporary parked task
with a frozen executable/command/directory owned by the fixture, pass through the
actual manager approval method, and verify only one launch/token consumption. It
needs its own unchanged receipt-routing scaffold and a harmless owned executable
that damages only its temporary receipt source after fired. Do not expand the ACP
original case into this route or let compatibility run without explicit approval.

## Required root execution and limits

Root should run the installed original/fixed ACP flag through Scripts/run-selftest.sh,
the relevant receipt runtime/worker/task durability/restoration/history and dedicated
privacy flags, existing ACP/MCP/confirmation and production tool-loop checks, and
owner isolation. Use make install OPEN=0 only under root ownership. Record actual
case counts/verdicts, exact source/bundle identity, preserved fixture bytes and any
unavailable checks. A source review, Python syntax check or helper result is not
end-to-end proof.

This bounded proposal establishes no durable ACP attempt/client binding, post-await
validity, nested permission outcome conformance, liveness, process death, external
effect outcome, reconciliation, crash/power-loss durability, recovery, retry, IM-16,
model quality gain, default promotion or broader Agent readiness. Parent Phase 6
contracts and aggregate quality gates stay open.
