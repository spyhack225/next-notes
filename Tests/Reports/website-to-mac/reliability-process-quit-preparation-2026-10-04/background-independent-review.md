# Independent Manager process-quit review

2026-10-04. **Verdict: HELD; source-only, uncompiled, original/fixed native unrun.** Frozen background-current manifest `b1d201e466385c52e88e6e20d9d2ebc4e0fdd5a83bba8030f2e5ffeb542d83ea` is unchanged. Nine current/context/patch/document/proposed-source pins independently match (zero mismatches), in addition to the manifest hash. Parent already owns replay and composite App; this reviewer did not repeat a broad replay or write any patch, canonical source, frozen file or runtime state.

## Confirmed candidate ordering blocker

The proposed `enqueueWorker` (`AgentTaskManager.swift.proposed:1322–1333`) returns immediately after processTerminationRequested, with no result delivered to callers. Three actual producers still commit and acknowledge positive continuation before that refusal:

| Actual current producer | Proposed source | Order still present in candidate |
|---|---|---|
| `approveCompatibilityCLI`, current981–996 | proposed1007–1022 | Commit queued/permissionApproved → insert exact compatibility token → enqueueWorker, which can refuse after quit. |
| `respondRestoredPermission`, current1137–1167 | proposed1163–1194 | Commit approved queued row → insert one-shot approval → enqueueWorker → return true. |
| `respondInput`, current1231–1245 | proposed1257–1271 | Commit supplied argument/queued row and remove input → enqueueWorker → return true. |

Under the candidate's already-set quit flag, a legal late continuation can therefore retain accepted queued work or dismiss its card while dispatch is refused. The existing synchronous MainActor path itself establishes the incorrect ordering in this proposal; no native late-callback case was executed. This is a producer-level source blocker, not merely a missing helper test. The primary acceptance decision must precede the actual transition/token/result at each positive continuation producer. Preserve the denied/cancelled path and existing PermissionGate cancellation/continuation behavior; this review does **not** assert a missing cancellation waiter. A gate only inside enqueueWorker cannot establish a truthful producer result.

## Retained-handle invariant still unqualified

The proposal keeps a cancelled local worker in running[id] and adds a per-owner token. That token prevents an old operation-body defer from deleting a newer slot. It does not retain the old Task when enqueueWorker overwrites running[id] (proposed1326–1333). Current releaseWorker1303–1314 already recognizes a queued explicit continuation with a successor handle; the candidate leaves that code unchanged.

A snapshot of running.values joins only handles present at capture. The candidate must not promise all predecessor return without a proven invariant or same-owner retirement. The actual admissibility of a same-ID successor while a predecessor remains inside backing is **unqualified**, not a reproduced duplicate execution/effect. Do not block every legitimate continuation or put a predecessor wait on the conversational path simply to hide this missing contract. Qualify the real overlapping predecessor/successor producer before selecting the minimal retirement correction.

## Scheduled preflight outside the snapshot

ScheduledRunner275–289 owns its real Task before Manager admission. runBody301–307 awaits model-state/cloud/Apple checks and model selection before recorder.begin at327–329. A quit during this period cannot capture that operation in Manager.running. Later Manager refusal does not prove the preflight returned. The frozen README correctly holds this separate owner; it is not repaired by this candidate.

## Conditional evidence required

Keep the copied Manager/App producer HELD. Parent composite App must not be mounted as complete background process-quit coverage while the continuation producer can queue without dispatch. Native original qualification requires the isolated actual primary Manager, real temporary-tool backing, real Cocoa first reply and first positive verdict, and the same exact task/receipt context. Exercise the actual continuation methods after quit admission closes, preserving queued/card/token state and truthful refusal; exercise real same-ID overlap separately if the source paths can qualify it. Missing overlap is INVALID/UNAVAILABLE rather than a manufactured original RED. Preserve every other owner verdict through drained AND finalReply, and use the same one-shot safetyDrain to finish actual original work before a second quit. Scheduled preflight, Capture/frontend and selected speech remain separate held owners.

Normal Done/Coordinator and Core bounded-wait behavior are outside this packet and unchanged by these reviewed hunks. Ordinary cancellation is not native return or effect outcome. No owner ledger, model/asset, OSLog, native process, compiler, parse, installation or index activity occurred in this review; no original/fixed runtime approval follows.

## Exact reviewed pins

- Current Manager: `8ebcd688cfa4b19d62a592ca5c12081f7e1df34225b1a6f45db167522eb6221a`.
- Current App: `bc01a27f48478a297d07a1d35669c313615cc7c182c0c6d113b4899e792a1b61`.
- Current ScheduledRunner context: `98f96a175ad86ebe305efc6b24767e73e5e3e4b3216a20b9170e5bcbeb28ff76`.
- Manager candidate patch: `72ca5ec238820bcf9384518337229936fef20473e801eba0aa036ef4fffb7eef`; proposed Manager: `5c46a379ae126d877b8aa592ab0d44d7d1b34b430540d7b0592fb698478df98b`.
- App candidate patch: `34f58951059af0d4d5ea878ae467e228453df2b63c20222f8676c7a429811b49`; proposed App: `42b1f228526fceb0a67c08de0d1b08ae164f503f2c52f16331a0e4ad201183e8`.
