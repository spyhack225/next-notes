# Next Notes iMessage Remote Access — review log

Written 2026-09-25. This is the audit the folder was built from, what was checked, and what is
open.

---

## 1. What this replaced, and the six substantive changes

The predecessor was `roadmap/todo/NextNotes_iMessage_Integration_Roadmap.md`, 1,796 lines of prose
roadmap. It was **deleted** and replaced by this folder. Five changes are substantive rather than
organisational:

### 1.1 The vocabulary was wrong, and the fold fixed it

The predecessor was written on 2026-09-23, before the multi-agent roadmap was audited. It assumed
an `InteractionAgent`, an `AgentResultBus` results travel on, a durable `AgentJob`, an
`AgentResultDeliveryPolicy`, and `spawn_agent`. On 2026-09-25 that multi-agent roadmap was audited
against the code and **rejected four of its own proposed types** because this app already has better
ones — see `AGENT-OVERHAUL/REVIEW-LOG.md` §6.2.

So the predecessor was simultaneously **too new and too old**: it described an architecture that had
been proposed and then partly rejected, in the same week. The replacements are in `00-README` §4
and §5, and the two sibling roadmaps were corrected in the same pass.

### 1.2 `attributedBody` is now a task, not a footnote

The predecessor's Phase 0 field list included `message.attributedBody` and then never mentioned it
again — through a decoder design, a message model, a watcher and eleven phases. For an iMessage
rather than an SMS, `text` is routinely NULL and the body is an undocumented **typedstream**. A
decoder that reads only `text` passes every developer's own SMS test and returns empty for every
real message.

That is now **IM-05**, the highest-risk task in the roadmap, with six test cases and a fixture set
whose two most important members are "a real iMessage with `text` NULL" and "a non-text balloon".
The predecessor's fixture list had neither.

### 1.3 The loop ledger gates **memory**, not only dispatch

The predecessor stated two things without connecting them. §13 established that a `from-me` row
must be matched against an outbound ledger before it is a command. §38 then said a user-written
iMessage is "trusted user words" for memory.

In this codebase "trusted user words" is `MemoryProvenance.TrustedSource.userSaidToAgent` at
**confidence 0.9** (`Memory/MemoryGuard.swift:8`), with `MemoryGuard` refusing to let
`readToolOutputThisTurn` text through. So a `from-me` row classified as the user *before* the
ledger match makes **every message Next Notes sent** into a 0.9-confidence memory of something the
user said, and every result delivery into a durable fact.

`AgentSession.recordUser(_:source:)` (`Agent/RealtimeAgent.swift:1208`) is the single path into
memory, and the ledger match now gates it. IM-08 makes the ordering explicit and
`--selftest-imessage-loop` asserts **zero new memory rows and zero new session rows** after 100
sends. The predecessor's test list would have passed while memory was still poisoned.

### 1.4 Sending to a self-conversation needs Contacts, and the predecessor did not say so

The send API takes an `IMessageChat`, and the natural thing to put in it is the `chat.guid` the
database gave you. **That is not an addressable target.** A direct `chat.guid` is shaped like
`iMessage;-;+15551234567`, and the address is the user's own number — not in `Settings`, not in the
app. A group's is `iMessage;+;<opaque id>` and needs `chat_handle_join` → `handle`.

So sending needs the **Contacts framework**, which this app has never linked (`CNContact` appears
nowhere in the tree). That is why G2 is a gate, why IM-02 exists, and why `Phone-Calls` shares it.
The predecessor's §4 diagram showed `Messages.app → Apple Events` with nothing in between, which is
the exact gap.

### 1.5 "Text me when that's done" is not a new enum

The predecessor specified `AgentResultDeliveryPolicy { currentTransport, iMessage, localOnly,
notification, bestAvailable }`. AGENT-OVERHAUL already has two enums that answer this:
`AgentDeliveryMode { context, respond, interrupt }` and `TaskDelivery` with eight states.

"Text me when that's done" is therefore a `TaskDelivery.pending` whose presenter is Messages rather
than speech. Adding a fifth mode would have been a second policy object next to a working one, and
the consequence was concrete: the predecessor's own D9/D13-equivalent rules ("queue a result rather
than interrupt voice", "show it and keep it pending") had to be **restated** in a new enum instead
of inherited. IM-16 now inherits them, and the wake behaviour is a batching question, not a new mode.

### 1.6 The folder is a roadmap *folder*, in `todo/`

See `00-README` §2. The predecessor was a single file in `todo/`, which is fine for a plan and wrong
for work with a ledger, a workflow, a flag table and a gate.

---

## 2. What was checked

- **Every type the predecessor named was grepped for.** `InteractionAgent`, `InteractionRoute`,
  `AgentOrchestrator`, `spawn_agent`, `ExecutionAgent`, `AgentResultBus`, `AgentJob`,
  `AgentResultDeliveryPolicy`, `MemoryTier`, `MemoryLineage` — **zero occurrences in `Sources/` or
  `windows/`**. `chat.db` 0 hits; `NSAppleScript` / `NSAppleEventDescriptor` / `NSAppleEventManager` /
  `AEDesc` 0 hits; `CNContact` 0 hits; `osascript` 1 hit, on `Shell/ShellExecutor.swift:7`'s
  `privilegedPrefixes` denylist.
- **Every anchor this folder cites was re-verified by grep on 2026-09-25** against `78cebc9`:
  `RealtimeAgent.handle` `:258`; `AgentUtteranceSource` `:4-8`; `AgentSession.recordUser` `:1204`;
  `WisprReader`'s `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI` `:72`; `ActionAuthority` `:20-30` and its
  `scheduledPrefix` `:32-58`; `ActionIntent` `:97`; `ActionReceipt` `:285`; `ActionReceiptStore`
  `:329`; `verifyResult` `:638`; `PermissionBroker.authorize` `:13`; `PermissionPolicy.allowsAutomatically`
  `PermissionPolicy.swift:114`; `AgentRisk` `AgentModels.swift:10`; `FunctionCallRelevance.consequentialIDs`
  `:177` (**`private static let`**, so nothing outside that file can read it); `SelfTestStoreGuard.fileNames`
  `:24` with 13 entries; `SelfTest.isRunning` `NextNotesApp.swift:85`; `MemoryProvenance`
  `Memory/MemoryGuard.swift:8`; `MemoryEntry` `Memory/NextMemory.swift:39`; `MemorySnapshotCache` `:1215`;
  the `next-memory.json` write `:1181-1193`; the `version-1 → 2` migration `:1150-1165`;
  `SettingsTab` `UI/Settings/SettingsWindow.swift:93`; `SelfTestStoreGuard`; the six section views
  inside `AgentSettingsTab`; the files in `Knowledge/Files/` including `FileIndexWatcher` and
  `FileIndex`; `NextNotesApp.runRequestedSelfTest` `:479`.
- **The `realpath` requirement was checked against two existing implementations**, not assumed:
  `FileIndexStore.canonical` and `SkillScanner.canonicalPath` exist because
  `URL.resolvingSymlinksInPath()` strips `/private` while `FileManager.enumerator` reports it, so a
  prefix test between the two matches nothing and every lookup silently returns empty.
- **The unanswerable-grant pattern was checked against the one precedent in the tree.**
  `Support/Permissions.swift` has four rows and no FDA, and its system-audio row documents the honest
  approach for a grant with no read API: *"one non-silent buffer is proof the grant exists, and it is
  the only proof there is."* IM-04 copies it.
- **The `AgentTask` decode pattern** (`Agent/Tasks/AgentTask.swift:115`, a hand-written `init(from:)`
  with `decodeIfPresent`) and the `MeetingModels` rule are both present, so the settings-file
  requirement in IM-07 has a precedent rather than being a new rule.
- **The obstruction to Phase 1 running in parallel was checked.** Phase 1's file list touches nothing
  outside `Sources/NextNotes/IMessage/` plus the three registry files, and the live workstreams own
  `Agent/RealtimeAgent.swift`, `Agent/ActionRuntime.swift`, `Meetings/`, `Support/Usage/` and
  `Core/DictationController.swift` — which is why routing (IM-11) is in Phase 2, not Phase 1.

---

## 3. Known open issues, carried into the tasks

1. **The decoder is version-specific and nobody knows how version-specific.** `attributedBody`'s
   typedstream layout differs across macOS releases. The task sets a version gate and a *capability*
   rather than an exception, and the `undecodable messages` metric is the canary — but the real fix
   is re-running IM-01 per supported macOS version as a release gate, and that is a release
   responsibility nobody owns yet.
2. **Group chats are decoded but not pairable.** IM-02's report answers whether a group *can* be
   addressed. If it can, that is a new decision with a new approval story — a group approval is
   "did I mean to send this to all of them?", which is a different question from a self-chat's.
3. **`MessagesCapabilities` covers column presence, not value semantics.** A column can exist and
   carry something unexpected. `cache_has_attachments` is the one this roadmap knows least about.
4. **The settling race's window is a guess.** 8 retries / 2 s is inherited from the predecessor and
   has not been measured. IM-06 should measure it on a real attach-heavy conversation and record the
   number, or say it is still a guess.
5. **`localIdentity` resolution depends on IM-02's outcome and may need a user-facing confirmation.**
   If neither `CNContactStore`'s `me` relation nor an Apple Event query works, the fallback is the
   user typing their own address during pairing — which is a worse experience and must be honest
   about being a fallback.
6. **The privacy assertion covers the paired-chat filter, not the File System.** Full Disk Access
   grants the *process* everything. `--selftest-imessage-privacy` proves the application layer narrows
   it; it cannot prove nothing else in the app reads `chat.db`. That is a process-level claim and it
   is only as good as the code review.
7. **A backlog drain is a flood risk that the tests only partly cover.** IM-16 asserts batching, but
   the batch size and window come from AO's `AgentDeliveryTiming` constants, which were measured for
   voice, not for a text transport arriving from a sleeping Mac.
8. **Two roadmaps share four tasks** — IM-02, IM-03, IM-12, IM-13 with `Phone-Calls`. There is no
   shared code location for them; `Phone-Calls` depends on the *iMessage folder's* outcomes. If
   someone reorganises one folder, the other breaks silently. The ledger rows in both folders say so.
