# P6-05i common bridge independent review

2026-10-02. Static review of the exact common-bridge.patch.txt and the five currently
applied source files, plus ROOT-IMPLEMENTATION-PLAN.md and current-runtime-frontier
README.md. No source/runtime/build/native/index/model/account/owner-payload operation
or other fixture edit was performed. Getter is intentionally nil in the original
scaffold. This is not a compiled or installed verdict.

**No concrete ownership, lifetime, admission or execution-order defect found.**
Proceed to root's same-fixture original/fixed proof with the bounded contracts below.

| File | Review finding |
|---|---|
| ACPAgentBackend.swift | Moves the same unique Session construction into the existing MainActor fire immediately after accepted toolStarted. Construction launches no process; attachment adds no await. That exact Session is passed into the existing private runSession. Subscribe/start/prompt/unsubscribe/close and cancellation/error paths remain in their previous order. No second Session or protocol path is created. |
| TaskEventJournal.swift | Optional MainActor Sendable callback defaults nil, carries only the transient Session reference and persists nothing. It neither changes record admission nor supplies execution authority. Existing unbound/local/compatibility initializers keep nil behavior. |
| AgentTaskManager.swift | Callback exists only for normal typed ACP and weak-captures Manager. workerBinding checks live uncancelled handle and current memory state/attempt/owner/start; callback matches captured attempt/owner/start and requires an empty weak slot. It cannot overwrite a nonnil reference or a successor binding. Same RunningWorker map holds a weak concrete actor reference, not a second runtime owner/registry. |
| Same Manager getter | Strongly promotes the weak actual Session for the duration of the actor sample. Rechecks both exact worker binding and object identity afterward, so a released/cancelled/replaced binding returns nil. It writes no SQL/receipt/progress/LAST cache and does not call the execution-validity closure. A primary held by another Manager can therefore coexist with the original live child, as intended. |
| ACPSession.swift | Actor-isolated getter delegates only to current optional client. Nil client is unavailable. Historical initialized/sessionID fields never supply runtime state. No lifecycle/cancellation/permission behavior changes. |
| JSONRPCStdioClient.swift | Original getter remains nil. Planned fixed getter should acquire the existing state lock and sample the same retained Process processIdentifier/isRunning plus existing closed/sawOutputEOF/pending.count. No PID lookup, kill probe, blocking wait, process launch or transport request belongs here. |

Weak storage does not extend the Session for the whole worker lifetime. The real
backend's local Session/async parameter remains its owner through explicit cleanup;
the diagnostic local strong promotion is needed to sample safely. It does not stop
close from setting client nil. After runSession closes/releases, nil is expected and
cannot prove process exit. A queued successor preserves the existing releaseWorker
rules and starts with an empty new slot; stale captured callbacks cannot match it.

The bridge changes no permission, primary admission, receipt/journal/progress save,
tool-start/completion ordering, dispatch or retry decision. Compatibility remains
excluded by normal typed ACP ownership. No new foreground await is added to fire.
The diagnostic's one actor hop occurs only when its caller requests a sample. Fixed
sample holds the existing lock only for metadata reads; it must not take writeLock,
wait for EOF/termination, emit a frame or acquire compute/model resources.

Foundation's Process state changes independently of the transport lock: the sample
is not an atomic OS/transport lifecycle lease and can become obsolete immediately.
Process PID is the owned child PID, distinct from task leaseOwner/app PID. A closed
transport with a running process is valid during EOF/close; pending count is outgoing
RPC continuations, not incoming permission Tasks, active tools or external effects.
EOF is output-stream evidence; close's terminate call does not join or prove death.

## Required actual evidence

- Live silent **actual Manager** consumer must read its same attached Session after
  one real initialize/new/prompt and current primary receipt/tool-start join. PID
  must equal the owned peer's os.getpid, not leaseOwner. Open/running/pending=1 is a
  bounded metadata control, not responsiveness or health.
- Repeat samples while the peer is held and compare actual primary rows, journal,
  export, receipt bytes, choices and existing cached diagnostics before/after. No
  probe may stamp heartbeat/lastProgress or start another worker/compute pass.
- Fresh-primary-held case must retain the exact current owned child sample while
  separately proving original execution validity false and primary held. Do not
  promote worker-map presence or runtime facts into primary authority.
- Samples before attachment, after same-worker cancellation/release and after client
  close must be unavailable where no current binding/client exists. That is unknown,
  not stopped. Source has the post-hop identity guard; an early-nil test alone does
  not establish independent mutation sensitivity of that guard across every actor
  schedule. Report the actual bounded race controls, not exhaustive coverage.
- Valid reply/cleanup must retain original task/result/receipt/permission behavior
  and exactly one owned protocol invocation. Parent's existing20 flags and isolation
  must report their real verdicts against fixed source/bundle.
- Supplementary **same owned Process** standalone EOF-while-alive and actual exit
  controls are appropriate: Manager unwind may already have released its Session.
  Do not add a product delay to force that transient. If the fixture ignores SIGTERM,
  it must have a bounded escape and targeted exact owned-peer cleanup. A nil Session
  client after close cannot satisfy an assertion claiming observed Process death.

Original nil-getter missing-feature failures are distinct from invalid fixture
conditions: absent prompt marker, malformed response, unsafe root, PID mismatch,
failed join, peer error/timeout or leaked owned process are control failures and must
be investigated. Keep common bridge and actual fixture identical in original/fixed;
fixed difference must remain only the exact transport getter implementation.

No process/session health, complete in-flight/effect coverage, descendants' cessation,
stale classification, current receipt quality, SQL-to-process atomicity, session
reattachment, crash/power-loss proof, reconciliation/recovery/retry, compatibility/
remote/voice/scheduled authority, IM-16 or aggregate Agent quality closure follows.

Exact fixed getter proposal reviewed: `proposed-JSONRPCStdioClient.swift.txt`
SHA256 `8b0461e34fce7cc04885bf679cf030c83d5fd41d6060dd80a6dff9d0810765de`
differs from current original transport source SHA256
`7427289b63a229125544edb3ffd939a614249ebd8d7be969e500b8eda4e92fb3`
only in `currentRuntimeObservation` and its comments. It constructs one value inside
the existing `lock.withLock`, using the same retained Process's `processIdentifier`
and `isRunning` plus existing `closed`, `sawOutputEOF` and `pending.count`.
No concrete defect found in this delta. It adds no lookup by PID, termination-status
read, wait/join, clock, write lock, primary query, save, timer or new process owner.
The transport fields are protected together; Foundation/OS process state remains a
sample and can change independently. The brief existing-lock read does not add an
execution-path await. This static review supplies no measured latency or installed
original/fixed verdict; the actual Manager consumer and supplementary EOF/exit
controls above remain necessary.
