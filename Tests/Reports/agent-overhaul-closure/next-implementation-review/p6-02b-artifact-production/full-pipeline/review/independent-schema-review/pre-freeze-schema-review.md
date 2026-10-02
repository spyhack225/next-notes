# Independent artifact encoding schema review

The schema 4 proposal keeps the existing store and transaction owner. Versions 1/2/3 validate and read with literal encoding 0; reading does not add the new column or advance user_version. installPendingInteractions now accepts old 3, adds the column in the already-owned write/import transaction, and returns the resulting version from its existing PRAGMA. Common validation extends the existing artifact probe; schema 4 does not add an artifact table_info query.

The fixed diagnostic-v1 refusal is necessary: an unmarked version 1 intentionally remains 1 and reads literal 0, so accepting a typed metadata write there would silently lose it on reread. The same existing return value now rejects nonlegacy records before rows/events. Authorized import upgrades 1→2→4 first and remains eligible. Genuine old 1/2/3 fixture source now physically removes absent columns/authority, rather than only downstamping user_version.

One migration edge remains pending in the reviewed mutable candidate. A pre-version4 file can contain an arbitrary extra column named encoding_version because knownschema validation tolerates extra columns. Reading correctly ignores it, but migration currently adopts it byname. A nonzero old value causes fixed samepath legacy UPSERT to reset historical kind/title instead of preserving them. All retained rows are rewritten; the concern is narrower metadata erasure or adoption, not unrewritten rows. This is a source-level scenario, not a reproduced owner bug.

Require neutral integer 0 values before adopting an existing column during old-schema migration, or refuse unchanged. A migration-only metadata query would need explicit justification; do not add a schema 4 query. Preserve actual isolated collision refusal/sourcebytes/version/authority/kinds, plus downstamped 0 and repeated diagnostic 0 controls. No blanket column-name refusal that breaks recognized neutral diagnostic snapshots.

Before completion, run the identical common schema/fixtures against both producer versions and retain existing authority/import/repair/recovery/source-admission tests. The single Authority hardcoded 3 assertion may use TaskStoreSchema.version with identical strict semantics and count. Record actual counts and reject stale 108/131 preparation totals as native evidence. Read-only schema behavior and transaction rollback are not power-loss durability or owner migration proof.

This report is additive and pre-freeze. Source, native, build, model, index and owner-store actions were not performed by this reviewer.
