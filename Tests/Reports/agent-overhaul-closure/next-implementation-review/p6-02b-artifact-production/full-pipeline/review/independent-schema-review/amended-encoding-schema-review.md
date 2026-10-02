# Amended independent artifact schema review

No concrete blocker remains in the reviewed off-source schema candidate. Common schema and Authority fixture bytes match between original and fixed snapshots. The Authority change is only the existing current-version assertion from hardcoded 3 to TaskStoreSchema.version; strict behavior and count stay the same.

Versions 1, 2 and 3 still read without installing the marker or advancing schema. Migration accepts old 3 and happens inside the existing transaction. Schema 4 validates the marker through the existing child LIMIT 0 query, and adds no normal schema-4 metadata query.

The old-column ownership edge is now fenced. During migration only, an existing marker column must declare INTEGER NOT NULL DEFAULT 0 and contain only integer 0 values. The existing metadata query checks declaration; one additional migration-only COUNT checks values. An arbitrary old marker value is not producer ownership. The new isolated old-3 controls cover integer 1 and historical text: reads remain neutral, writes refuse without changing DB/export/WAL/schema/kind/title/marker.

Diagnostic unmarked v1 remains version 1 and legacy-only. The fixed writer uses the returned existing version to reject typed metadata before row/event writes, preventing silent loss on a literal-0 reread. Authorized import upgrades through 2 to 4 first. Genuine old-1/2/3 fixtures now physically remove the absent columns and authority table as appropriate; rollback and accepted neutral upgrade controls remain exact.

The worker reports 135 static common checks; this review does not assert a native count or pass. Regenerate the stale preparation manifest and preserve identical common schema/Authority/fixtures before both native versions. Existing authority, import, repair, recovery, store and worker regressions remain required.

The declaration/empty-column refusal is reviewed in source; the new native fixture source currently targets value mismatch on an INTEGER declaration. The extra COUNT is limited to migration with an already-present old marker, although diagnostic v1 can repeat it. No latency, power-loss durability, owner migration, older-binary compatibility, UI, effect/retry/liveness or phase-completion claim follows. This agent made no Source, native, build, model, index or owner-store actions.
