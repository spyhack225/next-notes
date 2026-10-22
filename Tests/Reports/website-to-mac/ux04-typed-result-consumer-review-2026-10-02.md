# UX-04 typed result consumer review

Read-only source review, 2026-10-02. No Source, index, build, native diagnostic or owner-store access. Runtime root owns the future P6 producer proposal; this report supplies its UI contract. No installed regression or live interaction is claimed.

## Current source and mismatch

`AgentWorkingCard.swift` SHA256 `90130118f5d69acdded1e72d423cfa0877d740385bbe69119f17d0e8ae0dfb2d` accepts `task.artifacts: [String]`. Its failed-task branch supplies an Open closure for any nonempty array. `FailureCard.forTask` creates “Open what I made” from that condition. The closure opens only parsed HTTP/HTTPS values. A failed task with only a path, document ID or receipt text therefore gets an action whose implementation opens nothing. This is a confirmed source branch mismatch; the original installed action still needs reproduction before claiming the product bug fixed.

Successful terminal rows show “What I made” for every artifact. The actual `AgentArtifactLedger` also captures opened URLs, document IDs and receipt summaries, so creation is not established by array membership. Non-HTTP values are selectable text, without a dedicated Copy button. Open currently opens all HTTP/HTTPS entries together.

`LocalAgentBackend` folds tool `reference` and `link` into the same string array. Nested capture uses the existing task-keyed ledger with trimming and deduplication. SQL already has kind/title columns: current saves use neutral defaults for new legacy values, preserve metadata for unchanged ordinal/path, and reset it when that path changes. The reader selects those columns but reconstructs string artifacts. UI inference cannot repair the lost producer semantics.

## Contract for the owning producer proposal

- Pass explicit result kind/title/provenance through the existing tool, task, ledger and store seams. Maintain one canonical collection. Preserve legacy contents, order and established deduplication; unknown legacy values remain selectable/copyable text. Preserve explicit HTTP/HTTPS links without inventing file or document authority.
- Label creation only when the producer establishes creation. A result link, read reference or receipt does not establish successful execution or resolve an uncertain ACP outcome.
- Build Open/Copy affordances from the same committed task/result identity. No enabled no-op Open, opaque session ID opener, arbitrary-scheme opener or blind multi-open. A local-file action requires an explicit producer kind and current valid target; missing/deleted targets need a useful outcome.
- Preserve the parked beam overlay and existing task-bound preview selector, retry-risk gate, permission/effect certainty and native terminal controls. The UI consumes typed facts; it adds no second ledger, parser pretending to recover missing provenance, or execution approval.

## Required original/current cases

| Fixture input | Required assertion |
|---|---|
| Failed task with only a path or document ID | Reproduce original no-op Open; current offers only executable named actions or usable Copy |
| HTTP link, absolute path, file URL, document ID and receipt text | Each retains its producer kind and truthful label; unsupported values do not become arbitrary open targets |
| Duplicate reference/link and legacy JSON/SQLite rows | Preserve canonical contents/order and established deduplication across persistence |
| Two tasks with different results | A's displayed action cannot open/copy B's result |
| Deleted file, malformed URL, unsupported scheme | No successful-open claim or empty action |
| Rejected primary completion; ACP uncertain result/receipt | No completed/created success inferred from a retained link |
| Keyboard and VoiceOver | Each action has a named target, visible focus and correct invocation; no mouse-only route |

The existing Agent pane tests do not prove these action semantics. Root must retain the original failure, apply coordinated exact producer/UI hunks, repeat that flow and required task/permission/isolation tests, then obtain native interaction evidence. Live accessibility and the broader UX-04 release gate remain open.
