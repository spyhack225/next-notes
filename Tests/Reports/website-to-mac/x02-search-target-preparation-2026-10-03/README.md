# X02 search source identity — source-only preparation

**No code patch, compiler or native run.** This packet identifies the producer and navigation contracts needed before preparing the next X02 change. It does not change the frozen [history-cap candidate](../x02-history-preparation-2026-10-03/README.md) or its [temporary-root add-on](../x02-history-preparation-2026-10-03/isolation-current/README.md). All canonical source, worktree, build, model, index, owner-read, install and quit holds remain in force.

## Findings and proposed sequence

1. `KnowledgeIndexer.conversationSession` drops the persisted message UUID. Chunking aggregates a question and plain replies into one passage. Preserve the actual user UUID as a **turn anchor** through the existing index, hit and saved citation; do not describe it as an exact assistant-reply origin.
2. Search and citation callers drop source identity and open an untargeted chat. Carry the actual source/turn/passage identity through the existing navigation seam, with a one-shot repeatable focus and strict unavailable handling. A timestamp, similar text, ordinal or recycled SQLite ID cannot identify the original message.
3. Additive metadata adoption must retain indexed-only older passages. Keep nullable legacy metadata, preserve generation behavior for nil fields and prevent migration refusal from triggering destructive index repair. Existing backfill deliberately skips previously indexed conversations; do not replace a complete older source with its partial retained raw tail.
4. Qualify actual source-generation/identity checks before routing. Exact retained turns can target their existing row IDs; older indexed passages require an explicit passage consumer. Missing, stale, duplicate or deleted sources must not open an unrelated live conversation. A source fingerprint is not a global database identity.

The bounded display-cap candidate remains independently testable. The source-identity work has coupled persistence, codec and real caller requirements; this audit does not introduce unused production metadata or call a navigation helper a completed user flow.

## Evidence and required tests

- [Producer contract](producer-contract.md): first identity loss, same-index metadata, non-destructive legacy adoption, backfill and actual temporary Session → Indexer → Store → Search → Citation acceptance.
- [Navigation contract](navigation-contract.md): real targeted/general callers, exact versus derived passage policies, repeat focus, stale descriptors and isolated constructor requirements.
- [Independent review notes](review-notes.md): actual setter/reset focus invalidation, production click-handler coverage and deletion/recreation limits.
- `audited-source-pins.json` pins the finite producer audit. Navigation source pins are included in its report; recheck all current preimages before implementation.

Extend the existing isolated index and typed-route tests. The same original/fixed inputs must cover saved citation round trips, >40 rows, fresh readers, duplicate text/time, legacy indexed-only sources, replacement/deletion/reused IDs and general/disabled navigation. Production caller participation is mandatory. Full AgentView construction, actual source jump, stable scroll, correction, keyboard and VoiceOver remain separate native gates.

All identity, migration, caller and native outcomes remain **UNRUN**. Runtime root owns implementation admission, serial qualification and roadmap closure.
