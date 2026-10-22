# Verification, full duplex and release acceptance

This is the required evidence plan, not a test-results report. All new native checks
are **UNRUN**. [Performance standards](../../../PERFORMANCE-STANDARDS.md) and actual
AGENT-OVERHAUL task contracts control; no historical pass is inherited by this roadmap.

## Test entry and evidence discipline

Use existing isolated manager/store/runtime construction. Extend maintained flags when
the scenario belongs there; add a focused `--selftest-…` flag only for a new durable
conversation contract. Register through `NextNotesApp.runRequestedSelfTest` and the
release acceptance catalogue with owner-safe temporary paths. Proposed names below
must be checked for collisions; they are not claims that flags already exist.

Every producer fix retains actual original input, first broken contract and unchanged
original/fixed assertions, plus the real consuming route. Capture source/build pins,
registration, dependency substitutions, process exits, output, attempt/effect counts,
latency and privacy verdicts. A helper serialization pass is insufficient evidence for
real task dispatch, playback, UI, power loss or external delivery.

| Contract | Proposed focused verification | Required real consumer |
|---|---|---|
| Retention/migration | `--selftest-agent-conversation-store` | Actual facade, SQL authority and separate fresh reader |
| Chat routing | `--selftest-agent-conversation-routing` | Typed/voice manager result, task card and selected pane |
| Request deduplication | `--selftest-agent-submission` | Actual accepted input → admitted backend/tool entry |
| Checkpoint/restart | Extend task recovery/restoration/worker-attempt suites | Real successor reads exact checkpoint/results through backend |
| Context continuity | Extend memory/context tests; focused conversation-compaction flag if needed | Actual prompt builder and bounded original-history retrieval |
| Deletion and rollback | Extend isolation/history repair and conversation-store suite | Index/review/export writers and fresh compatible reader |
| Duplex under storage load | Extend voice-duplex-work/concurrent-voice/latency and Island tests | Actual capture/model/playback owners with physical output separately |

## Failure and crash matrix

Each numbered case requires deterministic component proof plus real process-boundary
proof where indicated. Use throw/kill injection only in owned temporary fixtures.

1. Exit before input commit: no accepted request or work. Exit after commit/before
   dispatch: exactly one saved submission; qualified policy determines held/resumable.
2. Retry same request before/after restart: same result/task/question, no second backend.
   Same ID/different payload fails; intentional identical new request dispatches once.
3. Import crash before/after marker: exact original retained; no half-import or duplicate
   entries. Include array, intentional empty object, malformed, unknown version and legacy
   sessionless rows. Already missing old content remains explicitly unavailable.
4. Task snapshot save, task journal compaction and schema upgrade: conversation history
   and valid links survive. Deleted/foreign/replaced database, WAL-visible history,
   concurrent writer, disk full and export failure retain current authority rules.
5. During model streaming: saved partial remains interrupted; no invented complete/heard
   answer. The same submission cannot acquire two active successors. No repeated historical
   speech after restart; a new user request can use the retained context.
6. Before tool admission: refused commit means zero backing entry. After backing entry
   but before result/receipt commit: unknown outcome, never assumed safe to repeat.
7. Verified tool result before checkpoint: reconcile existing receipt/result reference;
   no duplicate read/write based on transcript text. Changed source versions invalidate
   stale result reuse. Exact timestamp/attempt precision survives round-trip.
8. External email/calendar/file mutation after effect but before local completion: missing
   terminal record does not trigger resend/insert/rewrite. Verified matching evidence
   resolves; mismatches/unavailable evidence remain unknown. No real-account writes for
   a fixture. Account-specific acceptance is separately authorized and labelled.
9. Waiting for input/permission: restore exact card once; stale/edited/cancelled/cross-chat
   answer cannot dispatch or consume approval. Restart never restores a live token.
10. Switch/new/idle/Done while worker completes: original chat receives result, selected
    chat and speaker do not acquire it. Closing capture does not destroy background work.
11. Stop-task racing completion/revision: current primary owner wins; stale callbacks
    cannot write, create cards, speak or start effects. Process cancellation is not
    recorded as verified effect cessation without evidence.
12. Summary running while new turns arrive: commit only the covered prefix/digest; keep
    new tail. Restart at summary boundaries preserves originals and context continuity.
13. Delete during model/index/review/summary work: no resurrection through late callbacks,
    catch-up or restart. Check all content-bearing stores/exports and separately document
    retained minimal effect evidence and backup/WAL erasure limits.
14. Page a large archive with index disabled, missing drive/account/model, system clock
    movement or pressure: history remains available, ordering stable, settings intact.
15. Downgrade/forward-repair after new writes: exact retained history/receipts/task links
    survive; incompatible older readers are blocked rather than pointed at stale JSON.

Use actual child-process exits and fresh-reader processes for durable admission and
recovery. A fresh Swift object in one process is narrower evidence. Process termination
does not prove power-loss durability; state the filesystem/synchronization assumptions
and keep physical power-loss acceptance separate if unperformed.

## Full-duplex workload and measurements

Reference machine: 16 GB / 256 GB M2–M3 MacBook Air with ASR and voice running. Record
exact hardware/macOS, optimized build/signature, model artifact, power/thermal state,
settings, concurrent work and sample coverage. An M3 observation is not an M2 verdict.

Run a fixed baseline and changed build on identical bounded fixtures: empty history,
120 retained legacy messages, then 1,000 and 10,000 durable entries with realistic tool
result sizes and many archived chats. These are test sizes, not production limits.
Separately test one oversized tool result and long active discussions. If saturation
appears earlier, retain that failure rather than shrinking the workload silently.

During archive append/page/compaction and background task activity, continuously feed
the real capture route, stream model output, play audio and exercise barge-in. Include
new/switch/Done, task correction, pending approval and a meeting-saving scenario where
coordinated. Verify actual audio/frame/lag counters; no generic hub backlog inference.

Measure accepted input → first text, speech end → first audible PCM, barge-in → output
stop, task admission/receipt cost, SQL wait/commit, MainActor stalls, UI paging response,
decode throughput after first token, dropped frames, transcript lag and pending write
backlog. Retain Mach footprint and RSS separately, system swap/compression, disk growth,
WAL/checkpoint cost and active working-set sizes. No model warm-up/summary runs in an
audio callback; no SQL lock held during inference, rendering or playback.

Existing acceptance remains: ≥20 tokens/s decode floor (25–30 target), warm voice first
audio 0.9s target, applicable 100ms stall/5ms receipt contracts where prescribed, and all
current quality/privacy/permission checks. These are required targets, **not achieved
baseline measurements**. Quantify baseline/fixed sample counts/distributions and retain
inherited failures; a quieter rerun cannot erase a failure. Relative non-regression
alone cannot close an already failing absolute target. Set any missing archive-specific
numeric budget from DS-00 measurements before implementation acceptance.

Pass requires microphone/model/speaker overlap and correct real consumer ownership,
not just fast SQL or generated text. Controlled native playback receipts prove their
stated token/consumer path; actual audible output and physical UI need separate evidence.
No universal memory ceiling or arbitrary free-memory diagnostic gate is introduced.

## Related regressions and semantic acceptance

Discover current flags from source and acceptance catalogue before selecting runs.
Relevant existing groups include task durability/authority/recovery/restoration/history
repair/worker-attempt, receipt persistence/tool review, production tool loop, model
context/memory, usage attribution, owner isolation, voice delivery/turn routing/duplex,
playback ledger/session reducer/scheduling, concurrent voice, Island/presentation,
persona and UI strings. Run affected groups per slice; whole-scope release runs the
required parent quick/full/owner evaluations. Never treat a missing model/grant as PASS.

Semantic cases must retain dates, names with evidence, explicit corrections, source
identity, untrusted-tool boundaries, pending questions and uncertain action outcomes.
Check long-discussion recall against original committed text, not against the summary
being graded. No fabricated permission, completed task, heard clause or external effect.
All four persona flows must be usable without terminal/config/model-ID instructions.

## Rollout and recovery

1. **Isolated only:** temporary stores, exact crash fixtures, original/fixed checks.
   No owner history import, defaults changes, model downloads or installed-app swap.
2. **History slice:** enable new history authority only in a qualified candidate; preserve
   current conservative recovery. Native migration rollback/forward repair and original
   transcript retention must pass before owner data is admitted.
3. **Owner migration:** coordinate a quiet migration/installation window through existing
   app lifecycle and owner authorization. Retain private source witness and authoritative
   backup; verify fresh-reader parity. Do not rewrite a running owner store externally.
4. **Checkpoint slice:** add truthful interrupted/pending state; preserve held defaults.
5. **Recovery categories:** enable individually after actual crash/native/semantic proof.
   An internal capability rollout switch uses existing settings machinery and is not a
   new user-facing setup panel. Turning recovery off preserves histories and receipts.
6. **Release:** record exact scope, remaining contracts and parent verdicts. Remove only
   obsolete owned artifacts after integration and usefulness checks; report bytes freed.

A failed migration leaves the original intact and blocks affected task dispatch without
an empty-history success. A post-migration defect keeps SQL authority and new writes
intact while using forward repair or a verified compatible export. No rollback to stale
JSON, blind restore over newer data, or automatic uncertain-effect retry.

## Required report and coordination

Each accepted milestone report includes: task ID/status, scoped source and build pins,
baseline/fixed inputs, first broken producer, actual changed seam, consumer proof,
process-crash boundaries, privacy/isolation, measured costs, inherited/unavailable
verdicts, remaining contracts, integration and cleanup receipts. New reports go in the
existing tracked `Tests/Reports/durable-agent-sessions/` directory when work begins.

Before heavy work consult agent-relay agents/claims, active processes and live owner
capture. Agree a machine window; do not contend with ASR/TTS/meeting checks. Share exact
scope and meaningful findings with all project agents using the existing relay. Retain
the receipt and acknowledgement limits. Do not broadcast owner content, account labels,
credentials, transcript fragments or private file paths. Persist performance findings
through PERFORMANCE-STANDARDS or its linked reports; no measured claim lives only in chat.
