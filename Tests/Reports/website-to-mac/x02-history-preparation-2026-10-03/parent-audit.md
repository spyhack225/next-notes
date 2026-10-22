# X02 production-call-site audit and remaining acceptance

Status: source audit and proposed regression preparation only. No compiler, native, model, index, owner-store or canonical source action occurred here. The real Swift original/fixed regression is UNRUN. This packet cannot close X02 or native website-to-Mac acceptance.

## First broken contract and bounded candidate

`AgentView.timeline` calls `AgentView.presentedMessages(session.messages, responding: agent.respondingMessage)`. The latter takes `messages.suffix(40)` even though `AgentSession` retains and persists up to 120 rows. At 41 committed rows, the supplied first retained row is therefore omitted by the production presentation function. Removing that projection limit preserves the existing history, row IDs and streaming draft de-duplication; no second store, model context expansion or new await is needed. `LazyVStack` remains the real consumer. This is source-confirmed logic, not an executed original/fixed production verdict.

The 120-row persistence bound and model working-history compaction remain intentional existing contracts. Showing all retained rows does not promise an unlimited raw transcript. New-conversation indexing and older indexed passages are separate paths. The actual timeline still bounds action events at 40 and notices at ten; neither is solved by removing the message cap.

## Current scroll behavior and unverified hypotheses

The current view already calls `followLatest` only while `isReadingLatest` is true. Stream growth follows without repeated animation; new message, audit and activity updates otherwise set `hasNewerUpdates`, offering Latest update. The old unconditional-scroll finding is not an accurate description of this current implementation.

Native observations are still required for: content size changes retaining the same visible row; geometry and phase callback ordering; the Boolean bottom test and content insets; passive shrink re-enabling following; remounting while the existing onAppear task yields; task/review/thinking/composer-inset size changes; and behavior under reduced motion. No speculative geometry fix belongs in the bounded cap repair. Excluding `.tracking` from actual scrolling alone is not a demonstrated bug: Apple's [interacting documentation](https://developer.apple.com/documentation/swiftui/scrollphase/interacting) distinguishes tracking before movement from actual scrolling.

## Search, source linking and correction remain incomplete

- `KnowledgeSearchView.open(KnowledgeHit)` routes conversation hits to parameterless `NavigationState.showConversation()`. `AskView` and `AgentView.openKnowledgeCitation` do the same. The navigation method selects a pane, with no source or row target.
- A search hit already carries source ID, ordinal, chunk ID and occurred-at metadata. `KnowledgeIndexer.conversationSession` removes message UUIDs when converting session rows; `Chunker.conversation` aggregates a user question with plain assistant replies. Tool-backed rows, routine suggestions and meeting-sourced user rows are deliberately excluded. Such a chunk is not an exact task/approval receipt or a raw complete conversation.
- The real message row displays words, remembered-fact strings and citation chips. It exposes no edit/delete operation for a committed conversation row. Existing memory editing must be traced separately; correcting a fact is not the same operation as rewriting historical words or a receipt. The current remembered-fact feedback contains display strings, so it must not be treated as an exact memory-entry identity join.

Continue through existing source and navigation IDs. Qualify exact retained-row navigation separately from an older indexed-passage viewer; never silently send an indexed source to an unrelated live conversation or reconstruct deleted raw history from a derived chunk. A new ledger or copy of the index is unnecessary.

## Required same-host native conductor

Before construction, qualify an isolated actual AgentView entry. Its current property defaults access shared NavigationState, Session, RealtimeAgent, TaskManager, audit, permission/ACP gates, identity, activity, roles and notices; its body task and draft observer call NotesModelRuntime.prewarm. That producer already returns under SelfTest before model availability or load unless an explicit prewarm probe is installed; the caller alone is not evidence of model loading. Other constructor and descendant reads still need qualification. A custom initializer that overwrites eager defaults is not evidence of isolation. Either reuse a qualified existing seam or prepare the smallest actual consumer injection with no eager owner initialization, preserving ordinary initialization. Private gate constructors and descendants' shared reads must be audited before mounting. Do not mount a replica and call it the real pane.

Once serial ownership admits that conductor:

1. Create more than forty messages through the real isolated session, persist, release the first object and reopen the same temporary file. Preserve exact first-row identity, order, sources and metadata. Root must qualify original omission before the same fixed case.
2. Host the real pane once; reach an early row, preserve its ID and viewport-relative position, append a message and audit event, grow the live answer and change actual task/review content. Trace callbacks and scroll offsets. Assert no pull-away when reading older content and a visible Latest update control; activate the real control and verify the latest target.
3. Repeat while following bottom, across pane remount and with reduced motion. A first onAppear or a source projection count is not compositor/scroll/VoiceOver proof.
4. Use two real temporary meeting sources and one isolated persisted task. Relaunch readers, search exact marker passages with the actual index/search producer, activate the actual result/citation action and verify the intended source/position. Current conversation routing is expected to fail the exact-jump contract, independently of the cap.
5. Exercise the existing fact correction/removal producer, reindex where required, and check later actual answer context excludes the old fact and uses the corrected provenance. Keep historical receipts and unrelated conversations intact. If a required correction/navigation producer is absent, retain that feature as open rather than inventing successful test controls.

The serial runtime root owns admission, original/fixed builds, native runs, owner isolation and related tests. All native scroll, relaunch-as-process, search/jump, correction and linked-work gates above remain open.
