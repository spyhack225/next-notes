# Phase 0 — the three gates

Tasks `IM-01`…`IM-03`. **None of these is code, and none can be done by an agent.** Each needs a
human, a device, or both. They are first because the answers change the design of Phase 1.

**This phase does not exit by passing a self-test.** It exits when the three reports exist and the
gate row in `STATUS.md` closes. Do not begin IM-04 until it does.

---

## 1. Why a spike is mandatory rather than cautious

`~/Library/Messages/chat.db` is Apple's, is undocumented, is protected by Full Disk Access, and
changes between macOS releases. This app may read it and must never write it. Two properties of it
make guessing wrong in ways that matter:

1. **A message sent from the user's own iPhone is `is_from_me` on some accounts and not on others.**
   The predecessor roadmap assumed `from-me` and built IM-07's whole pairing filter on it. If that
   assumption is wrong, pairing never fires and the feature is silently dead.
2. **For an iMessage (not SMS), `message.text` is routinely NULL** and the body lives in
   `attributedBody`, an undocumented typedstream. A decoder that reads only `text` appears to work
   on a developer's own SMS test and returns empty for every real message. This is IM-05, and the
   spike is what tells it what to decode.

The third gate exists because of a measured, local fact: **ad-hoc signing changes the code
signature every build, so TCC grants are invalidated by every `make install`.** The Messages
Automation grant is one of those. A feature whose send path needs a grant that dies on every
rebuild is a feature that will read as "works on my machine" and fail on the user's.

---

## 2. IM-01 — Self-flow spike: what an iPhone self-message actually is

**Goal:** answer, with rows from a real database rather than with an assumption:

> When the user sends an iMessage to themselves from their iPhone, what exactly appears in
> `chat.db` on the Mac — and is that row distinguishable from one the Mac sent?

**Effort:** 1 day. **Depends on:** none. **Unblocks:** IM-07, IM-08.

**What you need:** the owner, an iPhone signed into the same Apple Account, Messages.app signed in
on the Mac, and Full Disk Access granted to Next Notes. A copy of `chat.db` from the owner's Mac
is enough; **it does not need to be this project's Mac**, and a sanitised copy is better — see
IM-05's fixtures.

### Steps

1. Open the database read-only. Use `sqlite3 file:`…?immutable=1` on a **copy**, never the live
   file: `chat.db` is being written by Messages while you look at it, and the WAL means a naive
   read can show a half-committed transaction.

   ```bash
   mkdir -p /tmp/imspike && cd /tmp/imspike
   cp ~/Library/Messages/chat.db* . 2>/dev/null
   sqlite3 chat.db "PRAGMA journal_mode; PRAGMA user_version; SELECT count(*) FROM message;"
   ```

2. Record `sw_vers -productVersion` and the macOS build. **The report is per-macOS-version** and
   IM-05's decoder target depends on it. It goes in the report header and in `STATUS.md`'s
   baseline.

3. Run the twelve experiments in §2.1. For each one, record the ROWID, the columns in §2.2, and
   the **wall-clock delay** between the iPhone send and the row appearing — that number is the
   feature's end-to-end latency and it belongs in the report, not in a guess.

4. Answer the three questions in §2.3 explicitly. A report that does not answer them is not done.

### 2.1 The twelve experiments

1. Send a self-message **from the iPhone**. ← the canonical case
2. Send a self-message **from the Mac's Messages UI**.
3. Let Next Notes send a self-message by Apple Events (this needs G2/G3 first, so do it second or
   substitute a hand-written AppleScript from Terminal and note the difference).
4. Send an image from the iPhone.
5. Send a **voice message** from the iPhone.
6. Send a reply to an earlier self-message (a threaded reply).
7. Add a reaction.
8. Edit a message.
9. Unsend a message.
10. **Send a message from another person into a group** — the predecessor's list has no such
    experiment, and without it there is no evidence for IM-07's "is it the paired chat?" filter.
11. Send a message with an **Apple-app effect** (an animated/expressive bubble) to see what
    `payload_data` and `balloon_bundle_id` look like on this macOS.
12. Send from the iPhone, then **sleep the Mac, send two more, and wake it** — record whether the
    rows arrive together and in ROWID order, and whether the WAL or the main file took them.

### 2.2 The columns that matter

```text
message.ROWID                    message.guid                 message.text
message.attributedBody           message.payload_data         message.is_from_me
message.handle_id                message.service              message.account
message.date                     message.date_delivered       message.date_read
message.associated_message_guid  message.thread_originator_guid
message.thread_originator_part   message.cache_has_attachments
message.balloon_bundle_id        message.is_sent              message.error

chat.guid            chat.chat_identifier            chat.display_name
handle.id            handle.service                  handle.uncanonicalized_id
attachment.guid      attachment.filename              attachment.uti
attachment.mime_type attachment.transfer_state        attachment.is_sticker
```

and the joins: `chat_message_join`, `message_attachment_join`, `chat_handle_join`.

**Four of these were missing from the predecessor's list and each matters:** `payload_data` and
`balloon_bundle_id` (IM-05's non-text path), `is_sent` (IM-10's delivery state), `error`, and
`handle.uncanonicalized_id` (IM-09's send target).

### 2.3 The three questions the report must answer

**Q1 — the filter.** For experiment 1, is `is_from_me` **1** or **0**? And if it is `0`, what is
`handle.uncanonicalized_id` — the user's own number? Because then IM-07's rule is *"a row in the
paired chat, newer than the watermark, whose handle is the user's own"*, not *"a `from-me` row"*.

**Q2 — the decoder.** For each of experiments 1, 4, 5 and 11, record: was `text` NULL? was
`attributedBody` present? what did the first 64 bytes look like? was `payload_data` present and
what was `balloon_bundle_id`? **This is IM-05's specification.** Copy the bytes into a fixture
rather than describing them.

**Q2 is now the highest-value thing you can capture, and `TYPEDSTREAM-NOTES.md` says what to
capture — read it first.** Three things matter, in this order:

1. **One real `attributedBody` for a message whose exact text you already know**, with the first 16
   bytes and the macOS version written on the same line. Type it from the phone as
   `FIXTURE-SENTENCE alpha bravo charlie` — placeholder words in a known order remove the
   sanitisation problem from the most delicate artefact in the whole roadmap, and the sentence is
   still the expected decode.
2. **Whether the string length inside the stream is bytes or characters.** Every published sample is
   ASCII, so only a message containing an accented or non-Latin character settles it, and the
   decoder's length handling depends on the answer.
3. **Whether the header is still `04` / system `1000` on this macOS.** That pair is the version
   gate's default and it is currently **unmeasured** — it was never observable from a machine
   without the Messages grant.

**Do not go hunting for a row with both `text` and `attributedBody` populated.** One known-text blob
is enough for `both-paths`, and asking for a hybrid row adds a step that may not exist. The 14th
case IM-05 wants (both columns set, to pin that `text` takes precedence) is best-effort — say so if
you cannot find one, rather than spending the spike on it.

**Q3 — the delay.** Experiment 12: does a row appear within the sync window, and does one row
appear per message or do several arrive together after wake? This sets whether IM-16 needs a
per-message or per-backlog drain.

### 2.4 Deliverable

```text
Tests/Reports/imessage-self-flow.md
```

including: the macOS version · the twelve rows, SQL not prose · event timing · **how self-authored
messages are distinguished** · the `attributedBody`/`payload_data` shapes · attachment join timing ·
`chat.guid` values for a self-chat, a DM and a group · edge cases.

**Sanitise it.** Replace phone numbers, email addresses and names with stable placeholders before
committing — `Tests/Reports/` is tracked. A report containing the owner's real contacts is a privacy
incident in a public repository.

### 2.5 Verify

No build. There is nothing to run. The exit is the report existing and answering Q1–Q3.

### **Do not**

- Do not write to `chat.db`, its WAL, or the `-shm` file. Work on a copy.
- Do not enable "Keep Messages" on any account, and do not change the retention setting.
- Do not commit unsanitised rows. Placeholders like `+1555…0194` and `REDACTED-HANDLE-1`.
- Do not delete a message from the Mac that has not synced to the iPhone, to "clean up" — the
  deletion propagates.

### **Done when**

- [ ] The report exists, is committed, and is sanitised.
- [ ] Q1, Q2 and Q3 are answered explicitly, not implied.
- [ ] The `STATUS.md` gate row G1 says `done` with the macOS version recorded.
- [ ] If Q1's answer is "`is_from_me = 0`", IM-07's task text has been amended to say so, in its
      own file, with the amendment recorded in `STATUS.md`.

---

## 3. IM-02 — Send-path spike: how is a chat addressed here

**Goal:** answer, before any send code exists:

> `IMessageChat` holds a `chat.guid`. Apple Events do not take a `chat.guid`. How is a
> self-conversation addressed, and does it work at all on this macOS?

**Effort:** half a day. **Depends on:** none. **Unblocks:** IM-09, and `Phone-Calls` PH-09.

### Why this is a gate and not a task

The predecessor roadmap's send API is `sendText(_ text: String, to chat: IMessageChat)`, and
`IMessageChat` naturally holds the thing the database gives you. **That is the wrong target.** A
`chat.guid` for a direct conversation is shaped like `iMessage;-;+15551234567` — service, `-` for
person-to-person, then the address — and the address is **the user's own number**, which is not in
`Settings` and not in the app. For a group the GUID is `iMessage;+;<opaque id>`, which needs
`chat_handle_join` → `handle.uncanonicalized_id` to produce anything addressable.

**So sending to a self-conversation requires the Contacts framework**, which the app has never
linked. That is why G2 exists, and it is why `Phone-Calls` shares it.

### Steps

1. From Terminal, find the self-conversation's `chat.guid` in the copied database, and read its
   `chat_handle_join` → `handle` rows. Record the `uncanonicalized_id`.
2. In Messages' AppleScript dictionary, find the **target class** and the **send verb's parameter
   list** on this macOS. **Do not assume the names.** The class was renamed at least once when
   group chats landed, and the send verb's parameters are the thing most likely to differ from any
   predecessor's assumption. Record the exact dictionary terms you find and where you found them
   (`sdef /System/Applications/Messages.app` is the source of truth).
3. Try a send by hand — `osascript` from Terminal is fine *here*, because this is a human
   diagnostic, not the app. Use the self-conversation and a nonsense body. Confirm the row lands in
   the database and note the GUID shape it was written with.
4. Then, critically: **determine how the app gets the user's own address.** Three candidates:
   `CNContactStore` with the `me` relation; `NSAppleEventDescriptor` asking Messages directly; or a
   user-typed confirmation during pairing. Record which ones work and which do not, and pick one.
5. Confirm what the Automation prompt looks like on this macOS and what the TCC service is.

### Deliverable

```text
Tests/Reports/imessage-send-path.md
```

including: the exact AppleScript dictionary terms and their source · the resolved `IMessageChat`
field set, including the AE-target field · the chosen method for the user's own address and why ·
the Automation prompt copy · whether a **group** can be addressed, and if so how (this decides
whether V1 stays self-conversation-only).

### **Do not**

- Do not send a real message to a real person during the spike. Self-conversation only.
- Do not build the send path here. This produces a report, not a sender.
- Do not assume `buddy` or `chat` is the right class name on this macOS. Verify it.

### **Done when**

- [ ] The report names the dictionary terms actually present, with `sdef` as the citation.
- [ ] A send to the self-conversation worked from the terminal and the row was observed.
- [ ] The method for the user's own address is chosen and recorded.
- [ ] Group addressability is answered, so `00-README` §3's G2 and IM-09's scope are settled.

---

## 4. IM-03 — The grants ledger

**Goal:** establish, once, what the user must grant, which of those grants this app can ask for,
and what happens to them on the next build. This task produces a checklist and a recommendation,
not code — the code lands in IM-04 and IM-09.

**Effort:** half a day. **Depends on:** none. **Unblocks:** IM-04, IM-09.

### The grants

| Grant | Needed for | Can the app ask? | How it is proven |
|---|---|---|---|
| **Full Disk Access** | reading `chat.db` and `Attachments/` | **No.** There is no programmatic request; the OS shows a pane and the user toggles it | **probe:** open the database and read one row. `MessagesDatabaseHealth` is that probe (IM-04) |
| **Automation → Messages** | every send (IM-09) | Yes, by attempting the first Apple Event. The prompt is per-target TCC | **evidence:** a send that produces a `chat.db` row. Failure is "no prompt / error", never silence |
| Notifications (optional) | a background result card when no session is open | Yes | `UNUserNotificationCenter` |
| Accessibility | already required by the app for dictation; **not** needed by this feature | n/a | `AXIsProcessTrusted()` |

**Full Disk Access is a grant with no read API, and this app already knows the honest way to
handle one.** `Support/Permissions.swift` documents the system-audio case: *"a tap without the
grant succeeds and delivers zeroed samples, so one non-silent buffer is proof the grant exists, and
it is the only proof there is."* FDA works the same way and IM-04 copies that pattern. **Do not add
a `hasFullDiskAccess` that queries something.**

### The signing question, which is the actual finding here

TCC stores a **code-signing requirement** per entry. An ad-hoc signature is a hash of the binary, so
the designated requirement reads `cdhash H"…"` and **changes with every compile**. The symptom lies
twice over: the permission toggle still reads as on, and **toggling it off and on does not repair
it**, because what is stale is the stored requirement, not the switch.

**The Messages Automation grant is in exactly that class.** So:

1. Determine whether the project has a stable certificate. `make signing-cert` ends it: with one,
   the requirement becomes `identifier "ai.pivotstudio.nextnotes" and certificate leaf = H"…"`,
   **identical across rebuilds**. Verify with `codesign -d -r-` before and after a build.
2. If the owner has no certificate, **say so in the report as a release blocker for this feature**
   and record it in `STATUS.md`. This is the same item AGENT-OVERHAUL and `Phone-Calls` need, so it
   is one piece of work for three roadmaps.
3. Record the repair path: `tccutil reset <service> ai.pivotstudio.nextnotes`, never without the
   bundle id, and note that it is the **owner's** call, not the agent's.

### Deliverable

```text
Tests/Reports/imessage-grants.md
```

plus, in `STATUS.md`: the gate row G3 closed, and a line in "Decisions and deviations" recording
whether a signing certificate exists.

**Also record the consumer copy for each prompt**, because it is part of the deliverable and IM-17
will use it verbatim:

> Next Notes needs Full Disk Access to read the iMessage conversation you choose for remote access.
> Messages are processed on this Mac.

> Next Notes wants to control Messages.

Neither may mention SQLite, `chat.db`, the WAL or an attachment path (`00-README` §11).

### **Do not**

- Do not run `tccutil reset` yourself. It is the owner's call, and a bare `tccutil reset
  Accessibility` wipes every app on the machine.
- Do not add a permissions row before the probe exists. `Permissions` gains `hasMessagesAccess` in
  IM-04, driven by `MessagesDatabaseHealth`, and not before.
- Do not promise a user-visible readiness check for anything the OS will not report. "Check this
  setting" is the honest rendering; a green tick the app cannot verify is a lie with a checkmark.

### **Done when**

- [ ] The report lists every grant, whether the app can ask, and how each is proven.
- [ ] The signing question is answered and the owner has been told the answer.
- [ ] The two consumer strings exist verbatim, with no developer words.
- [ ] Gate row G3 says `done`.

---

## 5. Phase 0 exit

All three reports committed, sanitised, answering their questions. The `STATUS.md` gate row
closed. **The folder moves to `roadmap/in-progress/` at that point** — it is a one-line change and
`00-README` §2 says so.

No self-test is added in this phase. That is not a gap: there is no code to test, and a probe that
reports green about a question nobody asked is the failure mode this roadmap is most exposed to.
