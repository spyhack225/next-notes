# X02 conversation search and navigation contract

2026-10-03. **READ-ONLY SOURCE AUDIT; IMPLEMENTATION, COMPILER AND NATIVE QUALIFICATION UNRUN.** This new report is the only authored artifact. No canonical source, existing frozen packet, worktree, owner preference/store, index, model, asset, installed application or staging operation was used. The bounded history-cap packet remains separate. This is a finite identity/navigation proposal pending runtime-root review, not an integration lease.

## Source pins

These are current source preimages, not compiled postimages. Recheck them before any relative implementation hunks.

| File | SHA256 |
| --- | --- |
| `Sources/NextNotes/Support/NavigationState.swift` | `9a9c583ae8c6b4e229f3d3d99dc009c5149e28ce5f28fa774f0c6eef457118b6` |
| `Sources/NextNotes/UI/Knowledge/KnowledgeSearchView.swift` | `79c9b4ea85e66ec78cc90542419ca4c554c012db1e6cab023766316365f286e8` |
| `Sources/NextNotes/UI/Knowledge/AskView.swift` | `64af9a08a0509ad8c351c43ad620b0c94d5b09cc0c55fa7f1a510adc434e93f4` |
| `Sources/NextNotes/UI/Agent/AgentView.swift` | `e16690c46235dfe28d69d03351928e4f4b3f2746472bb35815e9976b3c63fc85` |
| `Sources/NextNotes/Knowledge/KnowledgeAsk.swift` | `1dc54b5de32922fc2db414e7175ae9a3603e3c54bfdc7bdef9ebb35bc0114f2b` |
| `Sources/NextNotes/Knowledge/KnowledgeSearch.swift` | `d6bdaadfbd7b78d3dad7a262a2d33eb19e8861a4612570702291f756f64236ce` |
| `Sources/NextNotes/Knowledge/KnowledgeStore.swift` | `9398c8653ae555dd423ecfac0a86ef0791c76a199de1570b673c3b624e3f29df` |
| `Sources/NextNotes/Knowledge/KnowledgeIndexer.swift` | `f29ba6d9b1fbba357479920ab7a8795a82f76ae46de7a98c6a67656ca45816b3` |
| `Sources/NextNotes/Knowledge/Chunker.swift` | `0fff156e791b0a4647869d2ec5d5074e5cc646f1e52a6dda094aeea8a57f51b1` |
| `Sources/NextNotes/UI/Meetings/MeetingConsoleAskSection.swift` | `f1a5923748fbb6870c2fb9a5c4fda81adf7049c2ddfc60f01b7f4be1609d3b00` |
| `Sources/NextNotes/UI/Agent/IdeasView.swift` | `79649f94e5607f5882c11f47a9c78d7ab08899cbfd2603dce505e7ebda66cc90` |
| `Sources/NextNotes/UI/Agent/RoutinesView.swift` | `4d911a436c66c1a01c868289054690c7af6f200c112381330e72425253a47abd` |
| `Sources/NextNotes/Agent/RealtimeAgent.swift` | `c80b884e56ed12cb6fd1fa1bcb7a46cf387d44bc3db8dd6798944ee7a4627635` |

## First lost contracts and all conversation callers

1. `KnowledgeAsk.swift:61–70`: `KnowledgeCitation.target` retains meeting UUID/time but returns a bare `.conversation`, discarding the citation's existing source ID and chunk ID. The saved citation codec at 42–57 retains those IDs and time, but no generation, ordinal, message UUID or passage body. Decoding intentionally restores empty `text`.
2. `KnowledgeSearchView.swift:293–294`: a real conversation hit becomes parameterless `navigation.showConversation()`. `AskView.swift:428–429` and `AgentView.swift:514` do the same for citation targets. All three are source-targeted routes and must pass the actual producer identity.
3. `NavigationState.swift:292–296` selects Agent/Conversation only. Its existing `TranscriptFocus` at 265–289 demonstrates a transient optional target plus a fresh token for a repeated identical request. The constructor at 189 requires explicit private defaults and explicit module/index closures in an isolated conductor; its default closures access shared Settings.
4. Existing parameterless routes are intentional current-chat actions: `MeetingConsoleAskSection.swift:247` opens the full current thread; `IdeasView.swift:69`, `RoutinesView.swift:84` and `:328` open chat before an explicit new request. Keep these parameterless and clear any old conversation focus. They must not replay an earlier source selection.

The producer cannot supply an exact retained-message jump today. `KnowledgeIndexer.swift:858–862` converts messages without their UUIDs. `Chunker.swift:214–250` groups a user question and plain assistant replies; it excludes meeting-sourced user rows and non-nil-context assistant rows. A chunk is derived evidence, not a complete raw transcript, assistant origin, approval or task receipt.

## Minimum producer and navigation proposal

Use the existing rows, chunk table, hit/citation descriptors and NavigationState. Add no ledger, index copy, queue, timer or model pass.

- Preserve an **optional user-message UUID** when converting an actual session row; preserve the actual user UUID when its turn group is chunked. This is a **turn anchor**, not an assistant origin. Thread that optional metadata through the existing chunk persistence/read and citation codec only after its producer contract is approved. Legacy missing metadata remains nil. Do not infer it from wording, timestamp, ordinal or the current session.
- A change in persisted anchor metadata must participate in the existing chunk generation/idempotency contract. Otherwise `KnowledgeStore.replace` can return unchanged while the new metadata has never been written. Review that producer explicitly rather than repairing a click consumer.
- Carry the actual existing source generation from the same chunk SELECT through `KnowledgeHit` → `KnowledgeCitation` → conversation destination. `KnowledgeSearch.swift:169–184` already resolves IDs with source/kind filters; its columns currently omit `c.generation`. The chunk already stores generation, so no second read or new generation store is needed. Saved legacy citations decode missing generation to nil.
- Replace the bare conversation citation target with the approved source/passage identity. Keep a nil-default, nonpersistent focus value on NavigationState, with a fresh repeat token. The three targeted callers must pass it; parameterless callers clear it. A rejected/disabled Agent route must not retain a pending focus for later unrelated navigation.
- A targeted selection must choose its actual destination before a later default latest-scroll can replace it. Use the existing timeline identity (`message-<UUID>`) and scroll seam for an admitted retained anchor. The actual scroll producer, lifecycle ordering and focus consumption still require a hosted regression; this report proposes no speculative geometry changes.

Source/chunk IDs alone are insufficient permanent identity. `KnowledgeStore.swift:280` uses INTEGER PRIMARY KEY without AUTOINCREMENT. `replace` at 347–387 inserts a new generation before removing old rows; `deleteSource` at 399 can remove the source. SQLite permits reuse of deleted row IDs. Thus a stale saved citation cannot trust a later row solely because its ID/source pair matches. [SQLite's primary documentation](https://www.sqlite.org/autoinc.html) supports the reuse contract. No actual index-reuse run occurred here; this is a source-backed boundary requirement. The existing generation fingerprint at 496 is the available snapshot discriminator, not a claim of global database identity or cryptographic uniqueness.

## Exact resolution and refusal rules

| Target/state | Allowed behavior |
| --- | --- |
| Unique retained user UUID with matching source/session and admitted passage generation | Jump to the existing retained user row as a turn anchor; never label it the cited assistant's exact origin. |
| Same UUID in another session, wrong role, or more than one retained row carrying it | Refuse exact jump. Do not take the first match. |
| No retained anchor but the exact source/kind/chunk/generation still resolves | Show the existing indexed passage as a labeled derived passage; do not restore it into live conversation history. A passage-view consumer is currently absent and remains an implementation gate. |
| Legacy nil UUID | No exact retained-row jump. A separately qualified indexed-passage route may still be possible with sufficient passage identity. |
| Legacy nil generation, deleted source, changed generation, missing row or conflicting descriptor | No exact saved-passage claim or guessed replacement. Show an explicit unavailable/stale state. |
| General parameterless chat action | Open current chat with no source focus. |

Do not fall back to the newest conversation, closest timestamp, matching text, another chunk ordinal or another source when identity fails. Repeated click tokens must re-request the same admitted destination without changing identity. A focus value must not silently persist across new-conversation/reset, an unrelated pane route, or a refused module route. Do not reconstruct deleted raw history from indexed passages or rewrite old receipts during correction.

## Actual isolated conductor and acceptance gates

**Producer/nav/projection (source implementation not yet prepared):**

1. Create a canonical UUID temporary root with the existing isolation admission. Inject a private UserDefaults suite plus explicit module/index closures into NavigationState; construct actual AgentSession with a temporary file, explicit fake clock/idle value and no-op memory callback. Never initialize AgentSession.shared merely to check its file URL.
2. Append more than forty synthetic rows through actual Session methods, persist and reopen. Pass its actual ReviewRequest through `KnowledgeIndexer.conversationSession`, `Chunker.conversation`, actual isolated KnowledgeStore replacement, fresh store/search readers and real search/citation construction. Use existing explicit KnowledgeIndexer store/source/environment constructors if needed, not shared index/owner backfill.
3. Exercise the same producer routing functions used by Search, Ask and Agent chips, then the same focus projector consumed by AgentView. A fixture-only helper never called by production is insufficient. Compare exact retained user UUID/session/role, passage identity and the existing timeline target. Do not mount AgentView for this bounded value/persistence proof.
4. Encode/decode the saved citation before routing. Test nil legacy fields, wrong source/role, duplicate retained UUIDs, no retained anchor, repeated identical click, general chat clearing focus and disabled Agent. Record original failure before fixed success using unchanged inputs and fixture.
5. Replace/delete/recreate the actual isolated source and re-query the saved descriptor. Qualify an actual recycled-ID case before grading that control; changed generation must refuse the old exact destination. Preserve unrelated sources and demonstrate that an available older passage never mutates current Session history. Check owner invariance using the existing guard; it cannot by itself prove zero owner reads.

**Native consumer (still separate):** after private constructor/descendant admission, host the actual pane/passage view, activate actual search/citation controls and record the intended row/passage and viewport. Repeat the same target, remount, new conversation and disabled-module cases. Test target arrival while streaming and while reading older content, Latest update, selection, keyboard and VoiceOver with reduced motion. No source projection assertion, offscreen image or clean exit substitutes for actual jump/focus proof. Full AgentView host, visible passage consumer and original/fixed native outcomes remain open.

The identity producer, exact destination policy and constructor gates must be reviewed before any candidate patch. Runtime root owns all canonical changes, compiler/build/native admission and the original/fixed verdicts.
