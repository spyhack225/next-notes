# P6-06o candidate: actual post-Gate primary authority

2026-10-02 read-only source audit while root owns P6-06n original76/fixed77.
No source/build/app/peer/native/index/model/account or owner-payload operation was
performed. No existing evidence or another child's fixture was changed. This is a
concrete source hypothesis and fixture contract, not reproduced/fixed evidence.

## First unchecked producer decision

Current `ACPSession.handleIncoming` revalidates the captured normal typed context in
its existing policy MainActor hop before relaying a permission. It then awaits Broker
and, for an ask, actual Gate. After Gate returns, it checks only
promptCancellationRequested and returns the offered allow for a true Bool. The exact
captured primary can become held after a valid decision commit but before Gate's
await returns. P6-06n's request/decision transaction admission cannot prove later
Session authority; this is a different timing boundary.

Actual pins (recheck as root edits progress):

- `Agent/Backend/ACPAgentBackend.swift:370–426`: normal typed backend captures the
  existing TaskJournalContext and creates one new ACPSession per task, passes context
  to start, and owns prompt cancellation/close. No replacement Session is needed.
- `Agent/Backend/ACPSession.swift:141–157`: bound identity and existing policy-hop
  primary check are the original entry admission.
- same file `:181–203`: Broker await, Gate's TaskLocal-bound ask await, cancellation
  check, and selected permission return are the suspect post-wait producer.
- `Agent/Permissions/PermissionGate.swift` ask/respond: root n admission commits the
  actual request/decision before presentation/resumption. Its real once response and
  actual pending review are required controls, not substitutes for Session proof.
- `Agent/Tasks/AgentTaskManager.swift` init/holdInterruptedTasks/journalContext: a
  fresh isolated Manager commits recovering against the same task store; the original
  live captured context's isStillValid sees that primary mismatch.
- `Agent/Backend/JSONRPCStdioClient.swift:257–266`: the original incoming-handler Task
  awaits the actual Session result and sends that result to the same owned peer.

## Minimal same-input owned-peer original/fixed case

Reuse n's common real Manager -> ACPBackend -> Runtime -> Session -> Broker -> Gate
wiring, safe temporary task/receipt stores, config.json sibling, exact attempt1/current
PID/fired receipt and primary toolStarted/receipt join. Use two modes, `accepted` and
`post-approval-held`, with the same objective, no-effect peer, offered option IDs,
original context and ordinary once decision. Freeze n first; keep o's case bytes
identical for its own original/fixed builds. No Task.cancel or Session.cancel/close
may occur before the wire verdict.

1. Peer proves exact entry and current primary join, waits for the existing pre-request
   fixture release, then sends one matched session/request_permission. Assert actual
   pending ready review and one admitted attempt1 request fact.
2. On MainActor call actual `gate.respond(id: request.id, approved: true, duration: .once)`.
   Assert true, removed card and one admitted approval fact. In held mode, **before
   any await**, construct a fresh Manager using the same isolated SQL/export/receipt
   backing. Assert its hold committed, primary is recovering, no new worker started,
   original handle remains uncancelled and old isStillValid is false. Snapshot the
   held primary/journal after these real transitions.
3. Only then yield/wait for the peer's wire-result barrier. Gate.ask's continuation
   must resume on MainActor after the fixture's synchronous respond/hold work. This
   makes the timing intervention deterministic without a private handler call, fake
   context, new Session hook, sleep or polling policy in product code.
4. Accepted wire must be offered selected allow; held wire must be offered selected
   reject. Both preserve the true earlier approval event: authority was valid when
   that decision committed, so erasing or relabelling it would be incorrect. Root's
   original should emit allow in held mode; record the actual assertion failure.
5. Before releasing the peer's existing result barrier, held primary/journal must stay
   identical, receipt/attempt join exact, no cancel message/effect/duplicate prompt,
   no grant change, and no final task delivery may overtake observation.
6. Release the same harmless peer result; verify accepted result/receipt/task delivery
   unchanged. Held primary must remain held and no successful task announcement may
   occur. Existing completion admission should refuse the stale original context;
   old memory can remain running after rejected terminal task writes. Do not require
   held mode to complete successfully or invent a replacement worker. Fresh actual
   readers must preserve the held/terminal record and replay nothing.

The other agent owns the executable o fixture. Bound diagnostics, exact-trigger-free
cleanup, peer errors, primary/journal snapshots, owner isolation and targeted peer
cleanup remain required. A timeout, absent admitted approval, cancellation before
wire, missing fired/current join or peer error invalidates the case rather than
counting as the desired original RED.

## Smallest producer repair shape

Keep the existing Gate await and capture its immutable context. Execute the current
TaskLocal operation on MainActor, so approved permission checks the same live primary
immediately after Gate.ask resumes, before its Bool is handed back to Session:

```swift
let context = taskContext
let approved = await TaskEventJournal.$current.withValue(context) { @MainActor in
    let approved = await PermissionGate.shared.ask(request)
    guard approved else { return false }
    guard let context else { return true }
    return context.isStillValid?() == true
}
guard !promptCancellationRequested else { return Self.cancelledPermissionResult }
return Self.selectedPermissionResult(approved ? allow : reject)
```

This proposal reuses the existing await and adds one primary validity probe only for
approved bound results. It supplies no extra save/store/queue/timer/retry, and bare
Session nil-context behavior remains accepted. Ordinary decline stays the offered
reject; real prompt cancellation stays the existing cancelled result. Root must
compile/review the actor closure and confirm the same actual case before committing.
Recheck current n code and preserve its refusal/no-token/card-retention semantics.

## Current-client/epoch scope verdict

The case changes no client, Session ID, prompt instance or close state. It measures
post-Gate **primary** validity only. Reopening/replacing a Session is not used by the
normal backend, which constructs a fresh one for each task. Do not introduce a session
ledger/generation abstraction to close an unmeasured lifecycle label.

There are separate source concerns: start's callbacks capture self but no immutable
client identity; start can overwrite client/state if called again; cancel/close read
the mutable client after a MainActor hop; handleNotification admits established-ID
frames without current-client/closed-state checks; prompt resets one shared cancellation
Bool. Those require their own actual API-flow reproduction if pursued. The current
normal Manager path and o fixture do not prove Session replacement, post-close tail
admission, repeated-prompt isolation, or wire writes after transport closure.

The proposed primary probe also is not an atomic SQL-to-wire fence: after the MainActor
check the Session/transport actor handoff can still occur before the wire write. The
post-Broker existing-grant allow branch is likewise not measured by this Gate-only
case; standing grants remain separate. Preserve these limits rather than adding more
awaits or a new epoch owner without an original measured failure.

No external effect, process health/cessation, complete invocation/client authority,
crash/power-loss proof, reconciliation/recovery/retry, compatibility/voice/scheduled/
remote authority, IM-16, model/default promotion or aggregate quality closure follows.
