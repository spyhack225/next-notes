# X02 independent producer and navigation review supplement

2026-10-03. **SOURCE-ONLY REVIEW; UNCOMPILED, UNRUN.** The frozen producer/navigation contracts are retained unchanged. Only this additive note is authored. No canonical/worktree changes, compiler, native host, owner preference/store, index execution, model or asset activity occurred.

## Frozen inputs and review decision

- `producer-contract.md`: SHA256 `2934292ba934011e8287cf5ce149b418bbd4d815739f2a47f06ddfb564a55d85`.
- `audited-source-pins.json`: SHA256 `d4277104014e4de4ade8d517da3a467d458b0b4b28836e4bdacc4b5599963320`; all twelve listed source hashes match at this review.
- `navigation-contract.md`: SHA256 `b536c7dc2852b8141e5f7cf6f36d31f00a1e75b3d3dcdc33dad12638577ab507`.

The two contracts align on optional actual user-message UUID as a turn anchor, source/session identity, current passage generation, strict nil legacy behavior and refusal to jump to unrelated retained history. No material contradiction was found in the audited producer call sites. Conditional approval is for the documented bounded contract only, pending the supplemental lifecycle and identity limits below. No implementation or native release follows.

The frozen navigation contract and producer audit both pin the current RealtimeAgent source at `c80b884e56ed12cb6fd1fa1bcb7a46cf387d44bc3db8dd6798944ee7a4627635`; both match this review. Recheck current source before implementing. The frozen contracts remain unchanged.

## Pending focus must cover the actual setters

`AgentPaneSwitcher.swift:45` assigns `navigation.agentPane` directly. `MainWindow.swift:18` supplies `$navigation.selectedSection` to Sidebar. `NavigationState.swift:85–100` owns that section setter; `agentPane` at 161 is currently a plain observable property. Therefore clearing only inside parameterless `showConversation()` would leave routes that bypass it.

The proposed pending focus must be one-shot and reset through these actual existing producer seams: section selection/normalization, pane changes, parameterless conversation actions, consumed/refused targets and new-conversation/forget boundaries. The same actual Session reset path must invalidate a pending raw target; a cap trim or replaced session must fail exact row resolution. Do not let a stale token replay after remount or a later new turn.

A targeted route should select/normalize Agent and Conversation first, verify the destination is admitted, then publish its fresh target/token. Publishing first would allow those same setters to erase the new request. Repeating a target needs a fresh token while preserving source identity. No focus property should persist in preferences, create a queue, override a rejected module, or restore a deleted transcript.

## Caller proof requires a shared production route or host

`KnowledgeSearchView.open` and `AskView.open` are private methods on views whose state initializes shared NavigationState; Agent's citation action also uses its actual view-held navigation. Constructing a private NavigationState and calling its method is a navigation-producer test, not evidence that those private click paths forward the descriptor correctly.

Before a pure conductor claims caller coverage, extract the smallest route producer used by those actual actions and exercise that same function with the private navigation. Alternatively, qualify and activate the actual hosted consumer. Do not use a fixture-only mirror of the switch. Keep standalone navigation/projector evidence labeled narrowly until this production call-site join exists. This supplement proposes no full AgentView host or eager global construction.

## Generation validates a snapshot, not a deletion epoch

`KnowledgeStore.generation(of:)` deterministically fingerprints the source chunks. Its current-row kind/source/generation/chunk/origin tuple protects against changed payload and ordinary stale row IDs. It does not distinguish deleting then recreating an identical source payload with the same origin UUIDs. SQLite row IDs may also be reused after deletion. No global database epoch, deletion-history identity, cryptographic guarantee or freshness claim is supplied by that tuple.

Keep actual source/session and exact retained user UUID/role/uniqueness controls, plus the existing conversation forget watermark and removal/refusal paths. Test deletion followed by identical recreation separately from changed-generation replacement. A retained raw row after a knowledge-forget action must not bypass the current source/deletion contract. If the existing watermark cannot distinguish the requested case safely, keep that case open; do not silently reauthorize an old citation or add a new ledger to assert success.

Legacy missing origin or generation remains unqualified for an exact saved jump. The indexed passage and raw retained user row are distinct destinations. A turn anchor must not be described as the generated assistant text's origin or a task/approval receipt.

## Producer migration and actual hook feasibility

The producer identifies the correct first UUID loss at `KnowledgeIndexer.conversationSession` and the correct turn aggregation in `Chunker.conversation`. Carrying optional metadata through the existing chunk row and SELECT/codec is coherent; include nonnil origin metadata in the existing generation decision so an unchanged-text update does not skip persistence. Preserve nil/non-conversation generation compatibility.

`KnowledgeStore.openLocked` at 202–210 catches opening errors and deletes derived files before retry. A nullable migration refusal must bypass that destructive repair branch. The proposed non-destructive migration gate is necessary, not already implemented or verified. Existing backfill at `KnowledgeIndexer.swift:498–510` skips indexed conversations to avoid replacing older-only passages with a truncated raw tail; retain that behavior and do not force enrichment from partial rows.

`KnowledgeIndexSelfTest.swift:178–243` is a feasible existing actual hook seam: it constructs an injected temporary Session with explicit clock/idle, temporary memory, connects `indexer.connect(session:memory:)`, ends sessions, drains the actual index and exercises New conversation, Forget and watermark backfill. The hook at `KnowledgeIndexer.swift:309–313` forwards the real ReviewRequest into the actual conversion producer. Extending that flow can verify UUID/generation through actual Store/Search/Citation and a shared route producer. It cannot prove a scroll, visible passage, private click callback, process relaunch or zero owner reads merely by existing as source.

Required original/fixed controls remain: complete legacy schema preservation and failed-migration retention; question/reply search sharing the same user-turn anchor; duplicate text/equal timestamps but distinct UUIDs; current tuple after replacement; deleted and identically recreated source; absent retained row; wrong session/role/duplicate UUID; legacy nil descriptors; repeated click; direct setter/reset focus invalidation; disabled module; unchanged unrelated sources and no extra passage-body persistence. Fixture admission and owner-constructor privacy must be qualified before any actual run. No predicted failure/count is an executed verdict.

## Current supplemental source pins

| File | SHA256 |
| --- | --- |
| `Sources/NextNotes/Support/NavigationState.swift` | `9a9c583ae8c6b4e229f3d3d99dc009c5149e28ce5f28fa774f0c6eef457118b6` |
| `Sources/NextNotes/UI/Agent/AgentPaneSwitcher.swift` | `273a3d0289a806115cfbbd3750636ce3e4e1d7f03b12c16983323f2f7678b7e7` |
| `Sources/NextNotes/UI/MainWindow.swift` | `5f65aea558ea800d47f62d6deb5a9085a0b8fec4790485b6846578dccbc01150` |
| `Sources/NextNotes/Agent/RealtimeAgent.swift` | `c80b884e56ed12cb6fd1fa1bcb7a46cf387d44bc3db8dd6798944ee7a4627635` |
| `Sources/NextNotes/Knowledge/KnowledgeIndexSelfTest.swift` | `ab570f39aedb518e1ba631a06e26a01b0d040f7fbdeb30187674c09ef9e71e4f` |
| `Sources/NextNotes/Knowledge/KnowledgeIndexer.swift` | `f29ba6d9b1fbba357479920ab7a8795a82f76ae46de7a98c6a67656ca45816b3` |
| `Sources/NextNotes/Knowledge/KnowledgeStore.swift` | `9398c8653ae555dd423ecfac0a86ef0791c76a199de1570b673c3b624e3f29df` |
| `Sources/NextNotes/UI/Knowledge/KnowledgeSearchView.swift` | `79c9b4ea85e66ec78cc90542419ca4c554c012db1e6cab023766316365f286e8` |
| `Sources/NextNotes/UI/Knowledge/AskView.swift` | `64af9a08a0509ad8c351c43ad620b0c94d5b09cc0c55fa7f1a510adc434e93f4` |

## Review metadata correction

The previous supplemental note SHA256 `fb375eed20966c23adaafdf03c282abb53f09d3c1d459fbe32c5e4219a65007a` incorrectly described the navigation contract's RealtimeAgent pin as historical. Parent checked the frozen source-pin table; this note now states the matching current pin. No frozen contract or source changed.
