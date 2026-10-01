# P4-07a memory provenance: isolated producer evidence

Date: 2026-10-01. Scope: the complete persisted-provenance prerequisite recipe in
`roadmap/in-progress/AGENT-OVERHAUL/05-PHASE-4-PROACTIVE.md` P4-07a. This is source implementation plus isolated proof, **not task or phase closure**. Required installed and model gates remain pending below.

## Confirmed producer failures and changes

The original `MemoryToolExecutor.run` passed only session/channel/label to the real
`NextMemory.remember` and `update` writers. The writers produced no persisted provenance
record. Source occurrence time and gate origin were lost; correction history retained its
single-parent link but no recorded provenance. The frozen original regression calls the
actual tool catalogue, guarded executor, full writer, real JSON file, and fresh reader.
All four channels lacked descriptors; correction descriptor/history assertions failed.

A separate original case seeded a structurally valid version-999 file containing future
metadata, opened it with the actual reader, and performed a real manual write. The original
reader accepted any version and the writer rewrote it as version 2, deleting future
metadata. The producer now refuses unsupported integer versions, retains the file byte for
byte, and fences all persistence plus activity refresh. It does not invent a migration.

The new descriptor contains only origin, trusted channel, optional source label,
occurrence time, session id, confidence and known correction parent id. `MemoryProvenance`
itself remains a non-Codable live gate with raw utterances and untrusted text. Its two origin
values are Codable for the descriptor; this does not make the gate persistable or change
`requiredAuthority`. `MemoryGuard.lineage` copies the metadata after existing checks. Both
actual MemoryTools write sites pass it through the existing store seam. The update producer
binds the last correction record to the known replaced entry when not already populated.

`MemoryEntry` decodes every old/new field with `decodeIfPresent`; the previously required
id/kind/text/source/createdAt still throw if absent. Optional fields remain nil; missing
updatedAt uses recorded createdAt. It does not invent identity, content, provenance, or a
creation date for damaged rows. Records explicitly decode the date and both known enums;
unfamiliar or invalid descriptors fail decoding rather than becoming user testimony.

Stored files now use version 3. The additive version-2 migration preserves all old rows,
superseded rows and activity, logs success/failure, and writes no lineage for old rows.
Version-1 bare activity arrays migrate directly to version 3. Atomic replacement and
0600 permissions remain in the same writer. No store, queue, model pass or approval was added.

## Retained verification

- `original-red.log`: the original production sources at commit
  `5de382acfc779c019f558bd30f924373d2a1b38c` compiled and executed the frozen regression;
  final `MEMORY_LINEAGE_DRIVER_FAILED: 16 assertion(s)` (exit 1). The original legacy
  snapshot, existing metadata, privacy and manual/legacy reopen assertions passed.
- `green.log`: complete current NextMemory, MemoryGuard, MemoryTools, MemoryPackage and
  MemoryLineage sources compiled with Swift 6 and executed the expanded regression;
  final `MEMORY_LINEAGE_DRIVER_OK` (exit 0).
- Both print `MEMORY_LINEAGE_LEGACY_SNAPSHOT_BYTES=115`; comparison is exact UTF-8 bytes,
  not a count-only or subset assertion. The golden is:

```text
profile: ["The user prefers short answers.","The user drinks tea."]
notes: ["Standup notes go to the team folder."]
```

The driver copies whole actual producer files to a fresh temporary directory. External
model/runtime/UI/graph/persona collaborators are isolated stubs; graph, dictionary, meeting
and owner-task reads trap if attempted. None was touched. It uses the actual AgentPromptPath
budget declaration and actual tool catalogue/executor. Its confirmation-copy stub does not
prove spoken/UI wording; the original tool-path self-test retains that coverage. All files
are temporary; `SelfTest.isRunning` is true. No owner data, app process, model, grant, account,
network or full build was used. The compiler slot was coordinated with the parent.

The initial regression is preserved as `original-regression.swift`; `--original` selects
that frozen test so later strict-decoder additions cannot interrupt the original failure
scenario. The default driver extracts `MemorySelfTest.lineageFailures` directly from the
current self-test. Existing self-test cases are retained, with the expected persisted
migration version updated from 2 to 3 and one added lineage group. There is no new app flag
or second MEMORY marker.

```bash
python3 Tests/Reports/agent-overhaul-closure/memory-provenance/run-provenance-driver.py --original
python3 Tests/Reports/agent-overhaul-closure/memory-provenance/run-provenance-driver.py
```

These commands compile; coordinate the shared compiler slot before rerunning. The driver
wrapper was updated after retained runs to select the frozen original regression; no
producer behavior changed after green (MemoryTools whitespace only).

## Requirement ledger

| Contract | Isolated evidence | Installed/gate status |
| --- | --- | --- |
| Two own-file Codable/Sendable/Equatable types; explicit date/enum decoding | Added MemoryLineage.swift; complete-source compile; rich metadata and sparse record round trips; bad date/origin/channel/confidence rejection | App build pending |
| Optional lineage; hand-written all-field decoder | Minimal old row preserves nil metadata and defaults updatedAt; required-field removal rejects; rich all-old/all-new metadata round trip | Full existing memory test pending |
| Version-2 profile/note/superseded/three-activity fixture preserved | 3 active, 1 superseded, 3 activity/use counts; 115-byte snapshot exact; fresh reader retains values | Installed memory and persona pending |
| Version 3 additive migration, legacy lineage unknown | Actual migration writes v3; all four legacy rows omit lineage; manual write remains unknown | Installed memory pending |
| Both actual checked write sites propagate descriptors | Real catalogue/executor remember for four channels; real update/fresh read records replaced id and preserves old descriptor | Full runtime/approval path pending |
| Four trusted channels/confidences | Real writer stores 0.9 / 0.8 / 0.7 / 0.5 and corresponding channel, origin, date, label and session | Installed memory-review pending |
| Source contents never persisted | Actual file omits distinct source/untrusted canaries plus userText/untrustedText keys | Store-isolation and review pending |
| Empty consolidation state until consolidation | New checked writer records have [] absorbed ids and no run id; manual/legacy nil lineage | Consolidation not implemented here |
| Existing fast metadata and budgets/snapshot/ordering unchanged | origin/confidence/sourceLabel retained; 2400/4000/300 unchanged; exact snapshot golden unchanged; no prompt-share edit | CORE/persona/quick pending |
| Lineage never grants authority | Actual tool write with nil live gate is refused on a store containing recorded lineage; file unchanged; permission code untouched | Permission/runtime regressions pending |
| Unsupported future schema cannot be silently downgraded | Original real manual write loses future metadata; current writer throws storage error and bytes remain exact | Installed memory pending |

## Required remaining task acceptance, unchanged

Root owns the serial shared app build/installation, registry/docs/roadmaps and permission
runtime. Run the exact P4-07a recipe against the rebuilt binary:

```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-memory
Scripts/run-selftest.sh --selftest-memory-review
Scripts/run-selftest.sh --selftest-store-isolation
Scripts/run-selftest.sh --selftest-persona
make acceptance TIER=core
Scripts/run-selftest.sh --selftest-toolloop-live --quick --report <isolated-report-path>
```

The fixed Phase-4 quick gate retains its 9/10 bar and fixed selection. The task may have
independent source evidence while an inherited aggregate gate stays open; missing model
or installed evidence is never a pass. Phase completion still requires prescribed full
runs and other phase contracts. Root must update STATUS and AGENTS to name the descriptor
and explicitly say source utterances/untrusted text never enter the file.

## Boundaries and open work

- No downgrade/forward-compatibility claim. Unsupported versions are retained rather than read.
- Existing unknown/corrupt row handling still moves an unreadable file aside; this task did
  not redesign malformed-data repair or claim a product repair UI.
- Existing memory portability exports already omit other provenance metadata; it does not
  preserve the new lineage either. Fixing import/export lineage and consolidation are separate
  open contracts, not evidence for full roadmap closure.
- Historical raw source text is intentionally unavailable from the descriptor. It grants no
  new source-read, remote-write or retry permission.
- This source evidence does not close P4-07, P4-11 or the consolidation roadmap.

## Frozen artifacts

| File | SHA-256 |
| --- | --- |
| `Sources/NextNotes/Memory/NextMemory.swift` | `0c991423c81c69b28cd17cda7373642a84b0eef7a52000bfed7a2d767710089a` |
| `Sources/NextNotes/Memory/MemoryGuard.swift` | `b15887498d5943c4c847b0eb56577fa9516979483bfd03b38f1e0962cc812c71` |
| `Sources/NextNotes/Memory/MemoryTools.swift` | `a1533ec02c46d1c5ed3b57b998d0e817c639005fee1b87c2aad1ca8f6be4e510` |
| `Sources/NextNotes/Memory/MemorySelfTest.swift` | `9a7aefc644b6d6d2663eacea92ce926b8d81e8cf61af25be2de5b7d78a2a227e` |
| `Sources/NextNotes/Memory/Consolidation/MemoryLineage.swift` | `041379d0aaae85641d7d90e1079eed972f238993009192ea8bbdc42f4528f788` |
| `Tests/Reports/agent-overhaul-closure/memory-provenance/run-provenance-driver.py` | `6767b536545ecc7d9f7e1f9f807459f0c550a30385ee23824366c6ec84f83583` |
| `Tests/Reports/agent-overhaul-closure/memory-provenance/original-regression.swift` | `8d9e449f1774eab13c8999a419a289c62438a9339bda3fd314329207c17314c6` |
| `Tests/Reports/agent-overhaul-closure/memory-provenance/original-red.log` | `9e2d7e129af2c048c6d3090a6288a79f5abb98516c027fe4ea750a7f837e6342` |
| `Tests/Reports/agent-overhaul-closure/memory-provenance/green.log` | `2f41d2d7979eacae96ad0a2a7b14ed8e5c0676ff79cdf2a75449a0eeb2626e50` |
