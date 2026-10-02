# Verified bounded P6-05h prerequisite — installed71/72

Original71 RED13 missing-metadata assertions → unchanged fixture fixed72 worker794 and all20 focused flags PASS. Historical load snapshot/LAST write comparison only; no new I/O or retry authority. See [actual verification](verification.md), [native results](native-results.json) and original/fixed source manifests. Root's diagnostic-only proposal amendment is archived separately. The original off-source handoff below is retained as historical preparation, not current status.

---

# P6-05h proposed receipt source observation prerequisite

Status: OFF-SOURCE, UNCOMPILED/UNEXECUTED. Root alone owns Sources, integration, original/fixed native runs and roadmap edits. This is a missing-feature prerequisite, not evidence that the already-correct changed-source writer is unsafe.

P6-05g is already occupied by ACP origin admission in current STATUS/Phase6. P6-05h is next free across STATUS, Phase6 and00README as of this handoff. No shared registry was changed.

## Existing actual seam

ActionReceiptStore.load already computes source missing/unreadable/fully decoded/partially decoded plus kept/unreadable row counts through its current read/decode/fingerprint checks. Those facts are private and receipt(for:) alone cannot distinguish absent ID from unsafe source. save already compares the current file metadata against its retained fingerprint; mismatch refuses the write without erasing new bytes, but loadedSafely can remain true because it describes the historical decoded snapshot. The store caps500 on record; load can retain more than500. Neither a parseable retained source nor a missing ID proves full effect history or verified-not-started.

The proposed producer retains those existing load facts and LAST existing pre-write fingerprint comparison as one optional value in the same ActionReceiptStore. The getter returns that value without I/O, row scanning or mutation. An external edit does not silently refresh the getter. The next actual existing save comparison records mismatch/unavailable/matched; that fact remains historical and is not a current-file/CAS guarantee. Even matched before a failed post-write refresh proves nothing about accepted terminal persistence.

## Exact artifact contract

ActionReceiptSourceObservation.swift.txt contains enums and a metadata-only value: loadQuality, loadedRowCount, optional unreadableRowCount and lastWriteSourceCheck. No prompt/reply/path/receipt payload/file fingerprint/error text is exposed. No full-history/healthy/not-fired/retry classification is added.

original-scaffold-ActionRuntime.swift.txt adds ONLY nil sourceObservation getter to the unchanged current writer. The shared types/new fixture register on original and fixed. Missing metadata may fail original feature assertions; existing admission/rollback/result/retained-byte assertions must remain green.

proposed-ActionRuntime.swift.txt stores metadata at existing constructor/load returns and caches the single already-performed pre-write comparison. Original decode/data reads/fingerprint count/Bool write admission/retention/effect/error-routing logic remains unchanged. Existing runtime add() failure consumes the SAME cache for debug metadata. It logs only enum raw values; no new observer/callback or user copy. No extra save/stat/read/scan/await/store/queue/timer/model pass. Actual terminal-read refusal flows through this add() diagnostic.

## Exact actual regression

TaskReceiptQualitySelfTest.originalCases(root:input:text:check:) runs two modes using real safe temporary TaskStore/AgentTaskStore/ActionReceiptStore, actual Manager->LocalBackend->Executor->Runtime and the SAME FilesystemExecutor original backing.

A real primer read creates one completed receipt before constructing the observed writer. No invented receipt or owner seed is used. The observed writer actually loads that readable one-row snapshot. Target read then reaches real saved fired ownership and exact task receipt join; fresh pre-backing reader sees two genuine rows. In both modes writer's loadedRowCount remains historical1 while fresh reader reports2; own successful writes never rewrite load history.

Accepted mode requires existing completed task/receipt/result delivery plus matched write comparison and separate fresh readable snapshot. Changed-source mode appends one genuinely undecodable row after the real read and before terminal save. Cached getter still reports its LAST matched fact until the real runtime save executes. That save remains correctly refused, preserves exact new source bytes and fired memory, reports original result-not-saved failure/no task success, and records mismatch. Fresh reader retains the two real rows while reporting partial source/unreadable1, never empty-as-no-effects. A fresh actual Manager consumes the same terminal history and receipt store without replay; cache changes no task state. Existing owner invariance check remains.

Normal count30: accepted13 + changed16 + owner1. No conditional cleanup assertion sites enlarge that prediction. Each mode performs one real primer read and exactly one target read. Static target count is not total real read count. Timeout/invalid backing is harness failure, not source-quality evidence. Source includes no nonoptional result==nil: optional AgentTask result uses nil; optional receipt's nonoptional result uses isEmpty. Throwing Data read occurs before nonthrowing check predicate, avoiding prior try/autoclosure fixture failures.

registration.json appends exactly one call after the current ACP completion fixture. No prior worker assertion/input/peer is changed. Predicted extension30 is not a native verdict; root's installed actual counts are authoritative. The identical NEW fixture must remain frozen original/fixed.

## Reach and acceptance

Required before a completion claim: nil-scaffold original missing-feature failure with all existing functional checks intact; same fixture fixed green, existing worker764 plus related focused checks/privacy40/owner invariance, and source/binary/bundle evidence. Root owns verification. This proves admitted actual receipt producer metadata and actual failure consumer, not arbitrary malformed/unavailable branch mutation sensitivity, >500 retention runtime stress, concurrent CAS, complete task receipt coverage, live provider/owner data or power-loss safety.

Parent P6-05 four-question provenance/collector remains open: process/session liveness, complete tool in-flight coverage and current/full receipt quality are not supplied by historical caches. No stale verdict, state transition, health, automatic recovery/retry or IM-16 authority follows. Runtime/window classification and held recovery remain their own contracts; fixed model gates unchanged.
