# IM-08 — design: what a turn **is**, and what the ledger is allowed to remember

**Written 2026-09-26.** `02-PHASE-1-P0-SLICE.md` §5 is the task. This file is its design, and §5 now
points here. Read it before implementing IM-08; the trust rule the task states is wrong for this
chat, and the correction is in §1 and §2 rather than left implicit.

**Nothing here has been built and nothing has been run.** No `make build`, no self-test, no install,
no build lock. Two other workstreams are building this tree; this file is prose and code fences.
Treat the tree as possibly broken.

## 0. What already exists, and is not to be replaced

| Piece | Where | What it already decides |
|---|---|---|
| the envelope and the one stored fact | `IMessage/Database/MessagesDecoder.swift:162` (`IMessageEnvelope`), `:562` (`MessageBody`) | that direction is **not** here, that the body is four cases, and that `text`/`decodeState` are derived so a new string field is a compile error |
| which column answered | `MessagesDecoder.swift:690` (`MessageBodySource`) | five sources, one state — and it exists so a voice note's *source* and its *class* cannot disagree |
| the two copies of one self-message | `TYPEDSTREAM-NOTES.md`, *A self-message is TWO rows* | rows `55189`/`55190`, same 202-byte body, **opposite `is_from_me`** |
| an effect, measured | `TYPEDSTREAM-NOTES.md`, *IM-05c* | `U+FFFC` and nothing else, 237 of 314 bytes unread, `balloon_bundle_id` NULL |
| a voice note, half-measured | `TYPEDSTREAM-NOTES.md`, *IM-05d* | two signals, **both landing in `.notText`**; the real row shape is still blocked |
| a third party's content in a real body | `TYPEDSTREAM-NOTES.md`, *the stream is an attribute graph* | a link URL, a detected-entity list, a bundle id, a `__kMSHSMessage` offer |
| the de-duplication mechanisms | `Watcher/MessagesWatermark.swift` | row id **and** a bounded guid cache, and why a row id is not an identity |
| who the chat has in it | `MessagesQueries.swift:62` (`ChatRow.participants`), `:353` | `handle.uncanonicalized_id` per chat, read through a correlated subquery |
| which handle sent a row | `MessagesQueries.swift:192` (`MessageRow.handleID`) | the handle **row id**, projected; nothing resolves it yet |
| the memory gate and its weight | `Memory/MemoryGuard.swift:8` (`MemoryProvenance`), `:37` | `userSaidToAgent` is **0.9**, `requiredAuthority` is `.user`, and `untrustedText` is never a source |
| the one memory-only path | `Agent/RealtimeAgent.swift:1127` (`recordUser(_:source:)`) | the call IM-08's classification is the gate on |
| the risk ladder | `Agent/AgentModels.swift:10` (`AgentRisk`) | `observe` → `read` → `modify` → `write` → `send` → `purchase` → `destructive` → `privileged` |
| the tool authority answer | `Agent/AgentCapabilityManifest.swift` (`AgentCapabilityManifest`) | **present, not planned** — see §4.3 |
| the store template | `Knowledge/KnowledgeStore.swift:89` | a root URL in `init`, `0o600`, WAL, and the shape a ledger store copies |

**`RemoteIdentity`, `RemoteIdentityStore`, `IMessageConfiguration`, `SelfChannel`,
`IMessageOutboundStore`, `OutboundMessageLedger` and `IMessageBridge` do not exist.** They are
IM-07's and IM-08's, and every reference below is to something this design asks for.

---

## 1. The classification table

### 1.1 One function, and exactly four inputs

The whole classifier is one pure function, and the parameter list is the design:

```swift
enum IMessageClass: String, Equatable, Sendable {
    case userCommand           // the user's own words, in the paired conversation
    case userSentSomethingElse // from the user, and the body carried no words
    case couldNotRead          // this Mac could not read the body
    case nothingToRead         // the row carries no body at all
    case fromSomebodyElse      // in the paired conversation, not from the user, and not from us
    case ownEcho               // Next Notes' own message, recognised by the ledger
}

struct IMessageClassification: Equatable, Sendable {
    var messageClass: IMessageClass
    /// Whether the sender's own words carry a link. §4.2 — a fact about the text, and the
    /// only thing in a remote turn that is an action waiting to happen.
    var carriesLink: Bool
    /// Why the direction was reached, as a closed vocabulary. Never an address.
    var directionEvidence: DirectionEvidence
}

enum DirectionEvidence: String, Equatable, Sendable {
    case thisMac        // the column says this Mac sent it
    case localNumber    // the row's sender resolved to the paired number
    case foreignNumber  // it resolved, and it is somebody else's
    case unresolved     // it could not be resolved at all
}

enum EchoVerdict: Equatable, Sendable {
    case ownEcho
    case notOurEcho
    case ambiguous      // two pending rows match — §1.3's tiebreak
}

enum ResolvedSender: Equatable, Sendable {
    case thisMac
    case localNumber
    case foreignNumber
    case unresolved
}

enum IMessageClassifier {
    static func classify(body: MessageBody,
                         isFromMe: Bool,
                         sender: ResolvedSender,
                         echo: EchoVerdict) -> IMessageClassification
}
```

**`IMessageEnvelope` is not a parameter, and that is the load-bearing decision.** Everything the
class needs is `MessageBody`, the column, the resolved sender and the ledger. So `rowID`, `guid`,
`date`, `service`, `attachments` and every field a future task adds to the envelope **cannot
change a class**, because there is nowhere to pass them. This is the same enforcement as
`MessageBody` having no empty-string case and `OutputToken`'s initializer being `fileprivate` to its
file: a rule that is only true if you try to break it.

It also settles the voice-note question structurally. `MessageBodySource` — `.textColumn`,
`.attributedBody`, `.payloadData`, `.isAudioMessage`, `.noColumn` — **never reaches the classifier.**
So whether a voice note is recognised by the walk's `U+FFFC` rule or by `is_audio_message`, the
class is `.userSentSomethingElse` on both, and the same voice note cannot be a turn on one release
and a sentence on another. The real row shape is still unmeasured
(`voice-note-row-shape-from-a-real-message`, blocked) and **that measurement can no longer change
IM-08**: it can change IM-15's *handling*, which reads the source and the attachment, and nothing
else.

### 1.2 The table

| # | `MessageBody` | the column | the ledger | the sender | **class** | the assistant may say, on the remote side |
|---|---|---|---|---|---|---|
| 1 | `.text` | any | matched, unambiguous | any | `.ownEcho` | **nothing** — by construction |
| 2 | `.notText` | any | matched, unambiguous | any | `.ownEcho` | **nothing** — our own photo coming back |
| 3 | `.text` | `true` | not matched | — | `.userCommand` | the agent's own reply, `Next · …` (IM-13's format) |
| 4 | `.text` | `false` | not matched | `localNumber` | `.userCommand` | the agent's own reply |
| 5 | `.text` | `false` | not matched | `unresolved` | `.fromSomebodyElse` | **nothing** |
| 6 | `.text` | `false` | not matched | `foreignNumber` | `.fromSomebodyElse` | **nothing** |
| 7 | `.text` | either | not matched | `thisMac` (only reachable with `true`) | `.userCommand` | the agent's own reply |
| 8 | `.notText` | either | not matched | the user | `.userSentSomethingElse` | `sentSomethingElse`, §1.5 — one sentence, and it names no kind of thing, because the class cannot know which arrived |
| 9 | `.notText` | either | not matched | not the user | `.fromSomebodyElse` | **nothing** |
| 10 | `.unreadable(…)` | any | any | any | `.couldNotRead` | **nothing** |
| 11 | `.absent` | any | any | any | `.nothingToRead` | **nothing** |
| 12 | `.unreadable` / `.absent` | — | matched | — | **unreachable** | we send text, and a text send comes back as `.text` or `.notText`; a matched row with no readable body is not a thing this app produces |

**Why six classes and not a 3 × 4 product.** The product is three directions by four body states.
Twelve cells collapse to six, and the collapse rule is one sentence:

> **The only two things that change what the app does are: is this row the user's, and is there a
> sentence in it. Every other cell is a refusal, and a refusal behaves the same whoever sent it.**

So the refusals are deliberately **direction-free** — `.couldNotRead` and `.nothingToRead` do not
carry a sender — because nothing is done about them either way and a person is told one thing
locally in both cases. A cell per refusal would be twelve cases to keep in agreement and no
behaviour to show for it.

**Reconciling the two vocabularies, once.** The roadmap has a direction vocabulary
(`00-README` §13: `.user` / `.otherParticipant` / `.nextNotes`) and a body vocabulary
(`MessageBody`: `.text` / `.unreadable` / `.notText` / `.absent`), and the task's own diagram uses
a third spelling (`.nextNotes` and `.user`, with no `.otherParticipant` at all). **There is one set
of names now, and it is `IMessageClass`.** Each old name has exactly one home:

| old name | home | what happened to it |
|---|---|---|
| `.user` | `.userCommand` **or** `.userSentSomethingElse` | split by whether there is a sentence, because the two do different things |
| `.otherParticipant` | `.fromSomebodyElse` | kept, and it is reachable — see §2 |
| `.nextNotes` | `.ownEcho` | kept |
| `.text` | whichever class the sender and the ledger give it | it stops being a class of its own |
| `.notText` | `.userSentSomethingElse` **or** `.fromSomebodyElse` **or** `.ownEcho` | it was a *body* state, and body state plus direction is the table above |
| `.unreadable` | `.couldNotRead` | the `MessageDecodeFailure` reason **stays on the envelope** for the canary and the report; folding it into the class is what keeps one vocabulary, and the fold costs the report nothing because the report reads the envelope |
| `.absent` | `.nothingToRead` | as above |

**One thing is deliberately dropped, and it is not a name.** `.notText`'s `bundleID` becomes an
**internal value**: it feeds a count and it can never become a string. `AgentActivityProjector.isPublic`
already holds the rule that a raw identifier appears nowhere; a bundle id is the same kind of thing
(`com.apple.*`), and a person shown one learns nothing they can act on. A case asserts that no
sentence in `IMessageClassifierCopy` contains one.

### 1.3 The order, and the four disagreements

Evaluation is top to bottom, and each row says what it beats and why.

1. **The ledger, first and alone.** A matched, unambiguous echo is `.ownEcho` whatever the body is.
   It goes first because it is the only signal about **this app's own behaviour** rather than about
   the database, and the only failure that is both silent and self-amplifying: an echo answered
   becomes a loop, and the loop is what ends the feature. Every other signal is about a row this
   process did not write.
2. **The refusals, before the direction.** `.unreadable` and `.absent` cannot tell us who sent the
   row, so asking would be asking a question the inputs cannot answer. And the answer is the same
   either way (§1.2), so the direction is not consulted.
3. **The sender, for a row with words in it.** `isFromMe == true` means this Mac sent it; not being
   in the ledger, the user typed it here, so it is `.userCommand`. `isFromMe == false` needs the
   resolved handle.

**Four places two signals could disagree, and which wins:**

| disagreement | winner | why |
|---|---|---|
| the ledger says echo, the column says `false` | **the ledger** | a row can be our echo with `is_from_me = false` — the measurement is that the two copies of one self-message carry opposite values, so the column cannot be a veto on anything |
| two pending rows match one row (the phase file's ambiguity) | **"it is a command"** | the task's own reason, kept: treating a real request as our own echo loses it silently, and treating our own echo as a command is a no-op the breaker counts. This default only ever moves a row **toward** the user side, never away |
| `MessageBodySource` (`.isAudioMessage`) vs. `MessageBody` (`.notText`) | **the body** | the source is not a parameter (§1.1). This is the voice note's whole answer |
| the column says `true`, the resolved handle says somebody else | **the column** | on this Mac a row dated from this Mac came from this Mac, and the handle on an outgoing row is a *recipient*. A future release that made the two disagree would be a bug in the reader, not a reason to prefer the weaker signal — and the case is written so a change here reddens |

`DirectionEvidence` records which of the four produced the direction, so `--imessage-report` can
say **"3 messages were from a number Next Notes could not check against yours"** without ever
holding an address.

### 1.4 The refused cases are designed, not assumed

Four of the six classes are refusals. None of them is an error, and each has a place where a person
finds out — **on the Mac, never on the phone**:

| class | on the remote side | on the Mac | what is counted |
|---|---|---|---|
| `.ownEcho` | nothing — it is silence by design | nothing | `echoMatched` |
| `.fromSomebodyElse` | **nothing.** A stranger learns nothing about the conversation | **one** card, §1.5, deduplicated so forty rows are one card | `refused` |
| `.couldNotRead` | **nothing** | **nothing new here.** IM-17's canary owns this sentence and its notification — one sentence saying one thing, not two | `unreadable`, and the canary's three cases only |
| `.nothingToRead` | nothing | **nothing, ever** | `noBody` |

The principle, in one line: **a refusal says nothing at all on the remote side and everything on the
local side.** A reply to a row we could not identify who wrote is a message to a stranger that
reveals there is an assistant on this number, and "I couldn't read your message" is worse still —
it tells them to try again. The person who owns the Mac is the one who can act on it, and they are
in front of it.

**`.fromSomebodyElse` and silence: the argument.** A stranger's row saying *"send Marcus the pricing
sheet"* produces no turn, no memory, no reply, and one card. Not a refusal reply, because a refusal
is an answer and an answer confirms the channel exists. This is the same rule as the agent's
refusal card, which shows the full message *because* the person asked; there is no person here who
asked.

### 1.5 The copy register

Every sentence is a `static let` on one type, `IMessageClassifierCopy`, held by the sheet, the card
and the self-test so they cannot drift. **These are the user-visible strings, and they are the ones
checked for the eleven words this feature must avoid** (`TCC`, `grant`, `attributedBody`,
`typedstream`, `payload_data`, `database`, `sqlite`, `watermark`, `probe`, `signature`, a raw tool
id) — `--selftest-ui-strings` will not catch any of them, per `IM-17-DESIGN.md` §7.12.

| constant | text | where |
|---|---|---|
| `sentSomethingElse` | *"I can tell something arrived, but there are no words with it, so I don't know what to do about it. Send me a message and I'll pick it up."* | the remote reply for `.userSentSomethingElse` |
| `notFromYou` | *"That message wasn't from you."* | the card headline for `.fromSomebodyElse` |
| `notFromYouDetail` | *"Nothing was done with it. Next Notes only answers messages sent from the number you set up."* | the card's second line |
| `senderUnresolved` | *"A message in your conversation was from a number Next Notes couldn't check against yours, so nothing was done with it."* | the card for `DirectionEvidence.unresolved` — a different sentence because the cause is different and this one is a defect to fix |
| `linkNotFollowed` | *"I can see the link, but I don't follow links sent from a phone. Tell me what you're after and I'll look for it."* | the remote reply when a link-only turn produced no answer |
| `pausedReplying` | *"Next Notes paused replying in case it was talking to itself. Your next message starts it again."* | the island card for the breaker |
| `conversationGainedAPerson` | *"Your Messages conversation now has 2 people in it. Next Notes still only answers messages sent from you."* | `--imessage-report` only, **not a card** — nothing is actionable and a card per event is noise |

**No sentence here apologises and none alarms.** `sentSomethingElse` says what arrived, what is
missing and the next click, in that order. `notFromYou` names the fact and the absence of action.
`pausedReplying` says what happened and what restarts it.

**One sentence is deliberately not written here.** IM-08 adds no sentence for `.couldNotRead`,
because `IM-17-DESIGN.md` §4.3 already wrote the one that exists — *"Next Notes can't read your
messages / Your messages are still in Messages and nothing was lost…"* — and a second sentence
saying the same thing in different words is the drift `IMessageConsentCopy` exists to prevent.

---

## 2. The pairing rule

### 2.1 Two questions, and the task's diagram collapsed them

The task's order is:

```text
row arrives → ledger match ──► matched   → direction = .nextNotes → never record, never answer
                    │ not matched
                    ▼
              direction = .user
                    ▼
       AgentSession.recordUser(_:source:)   ← the only path into memory
```

**Read that as one question — "is this row ours or the user's?" — and it is the wrong shape.** It
is two questions, they have different inputs, and the diagram has no place to put the answer
`.otherParticipant`, which the glossary has carried since the folder was written.

| | question | input | decided by | when |
|---|---|---|---|---|
| **A** | *is this row our own echo?* | the ledger, and nothing else | the match | every row |
| **B** | *is this chat the self channel?* | the chat's participants, once | the pairing act | once, then frozen |
| **C** | *is this row from the user?* | the column and the row's sender | `classify` | every row with words in it |

A is a **row** question about this app. B is a **chat** question about the user's account. C is a
**row** question about a handle. The task's diagram answers C with A, which is why it has nowhere to
put somebody else.

### 2.2 The rule

**B — the self channel.** Frozen at the pairing act and never re-derived:

```swift
enum SelfChatMembership: Equatable, Sendable {
    case selfChannel
    case notSelfChannel
    case cannotTell          // the participants join is absent on this database
}

/// Pure. `participants` is `ChatRow.participants`; `local` is IM-07's
/// `RemoteIdentityStore.localIdentity` through IM-02's canonical form.
static func membership(participants: [String], local: RemoteIdentity?) -> SelfChatMembership
```

`cannotTell` is fail-closed: without the participants join the app cannot answer "is this chat only
you", and a chat it cannot check is not a chat it will treat as a command channel. That is a
degradation, and it is visible in `--imessage-report` as a state, not a sentence.

**The rule uses `participants` and nothing else.** It does not look at `chat.chat_identifier`, whose
format for a self conversation on this Mac is unmeasured, and it does not look at `display_name`:
a person can rename a self conversation to anything, and a name is not an identity. **Chosen, and
the reason is that both alternatives are guesses about an unmeasured format**, and a pairing rule
built on a guess is a rule that can be wrong in a way nobody notices until it is exploited.

**C — direction.** `IMessageClassifier.sender(isFromMe:handleAddress:local:)`:

| the column | the row's sender resolves to | `ResolvedSender` | why |
|---|---|---|---|
| `is_from_me = true` | (not consulted) | `.thisMac` | this Mac sent it, and if the ledger does not claim it the user typed it here |
| `is_from_me = false` | the paired number | `.localNumber` | **the user, from their phone or another Mac** — a feature, not an edge case |
| `is_from_me = false` | a different number | `.foreignNumber` | somebody else, in a thread addressed to the user's own number |
| `is_from_me = false` | nothing, or no local identity, or no participants join | `.unresolved` | **fail closed** |

**Why `unresolved` fails closed, when the task's ambiguity rule fails open.** They are opposite
defaults and both are right, because they answer different questions. A *ledger* ambiguity is
"we might be looking at our own message or at the user's"; answering as the user costs a wasted turn
that the breaker counts. A *sender* ambiguity is "we might be looking at a stranger's message or the
user's"; answering as the user executes a remote command from an unidentified sender, and there is
no breaker on that. **Fail toward the recoverable error in both cases** — the user's own command is
re-sent in a second and a stranger's message is not executed at all.

**`message.handle_id` is resolved by a statement IM-08 adds**, and the resolution is one pure
function over one row: `SELECT uncanonicalized_id FROM handle WHERE ROWID = ?`. `MessageRow.handleID`
is already projected; nothing in the tree resolves it. The name goes in `MessagesQueries.swift` and
nowhere else, per that file's own rule, and it needs no capability because `handle.ROWID` is present
in every schema this has seen — the join's presence is already `MessagesQueries.participantsPresent`.

### 2.3 Three failure modes, one line each

**(a) A group that once contained only you.** Membership was decided once and is never re-derived, so
a chat that later gains a handle stays paired and keeps working; the gained handle is a **number in
`--imessage-report`** and nothing else, because C is a row-level question and a second participant
cannot make a stranger's row look like the user's.

**(b) A chat that gained a second handle.** The same answer, and this is the case that proves it: the
*only* reason a gained handle matters is the promise in the consent copy ("The conversation — the
one where both sides are you"), so it is a **copy** correction and not a security boundary. A
feature that revoked pairing because somebody joined a conversation would be revoking on an event the
person neither caused nor can see, and the stranger's rows are refused by C either way.

**(c) A row arriving before the chat row does.** Held inside **IM-06's existing per-message settle
budget** (8 × 250 ms) — no new deadline, no new queue — and on expiry it is classified by the
fail-closed branch, counted as `notPaired`, the watermark advances, and **nothing is said on either
side**: the person loses that one command, and a `message` row with no `chat` row is a database
mid-restore rather than a person, which is why a count and not a card is the right response.

### 2.4 What is logged

**Counts, states and durations. Never an address, never a handle, never a chat identifier.** The
per-row facts that reach `usage.jsonl` are the six `IMessageCount` cases that already exist
(`IM-17-DESIGN.md` §3.2: `detected` · `accepted` · `refused` · `unreadable` · `notText` · `noBody` ·
`notPaired` · `echoMatched` · `loopSuppressed` · `discardedAttributes`), and **IM-08 adds none**:

| class | the existing count |
|---|---|
| `.userCommand` | `accepted` |
| `.userSentSomethingElse` | `notText` |
| `.couldNotRead` | `unreadable` |
| `.nothingToRead` | `noBody` |
| `.fromSomebodyElse` | `refused` |
| `.ownEcho` | `echoMatched` |

The `IMessageBridge` writes **one** `imessage.event` row per inbound row, through `IMessageUsage`,
which is IM-17d's single writer — so there is no second place a class could be recorded and no
second vocabulary to keep in step.

---

## 3. The outbound ledger

### 3.1 What it is for, and what it is not for

One sentence: **it exists so that a row carrying text this app sent is recognised as that row and no
other.** Everything else about a message lives somewhere else.

| it is | it is not |
|---|---|
| a matching store, read on the inbound path | a history of conversations |
| local, never synced, never exported, never printed | a source of anything a reply or a memory says |
| keyed by digest, so it holds no text | a task ledger — `TaskBridge` (AO P6) owns task state, and if IM-16 lands this file does **not** gain a status column |
| six scalars per row (§3.2) | a place for the classification — the class is a count in `usage.jsonl` (§2.4) |

**Why SQLite and not JSON** is the task's own reason and it stands: a uniqueness constraint on a
pending row, an append-only history, a mutable matched identifier, and a verification state a crash
can leave half-written. That is relational. `KnowledgeStore` is the template — `init(directory:)`,
`0o600`, WAL — and `IMessageOutboundStore` copies it and adds a root plus `isolated()`.

**The ledger holds no row about a person.** A store that recorded *"somebody else wrote to you"* would
be a store of somebody else's words by adjacency, even with no words in it. That is why §2.4 puts
the classification in `usage.jsonl` and the ledger holds only the outbound side.

### 3.2 The permitted fields, as an allowlist

An allowlist, not a denylist, for the reason the decoder's is one: **a denylist is a bet on the
current release.** The measured graph held eight named attributes plus a nested object whose shape
nobody here knows, and a macOS update adds a ninth. A list of things not to store is a list of
things somebody thought of; a closed row type is a list of everything there is. Adding a field to
`PendingOutboundMessage` is then a deliberate act somebody has to justify, and it is visible in the
diff.

```swift
struct PendingOutboundMessage: Equatable, Sendable {
    /// Ours. The correlation id IM-10 and IM-11 carry.
    var id: Int64 = 0
    /// Ours. `chatGUID → conversationID` (IM-11's mapper), so a reply goes back to the
    /// conversation rather than to a string.
    var conversationID: String = ""
    /// Apple's. The join key, and the only reason this store is chat-scoped.
    var chatGUID: String = ""
    /// A digest of the bytes that were sent. **Never the text.** See §3.3.
    var textDigest: Data = Data()
    /// A digest per attachment that was sent. **Never a file name.**
    var attachmentDigests: [Data] = []
    /// Apple's epoch, nanoseconds.
    var dispatchedAt: Int64 = 0
    /// Set when the row that carries our text is found. `nil` while pending.
    var matchedRowID: Int64?
    /// Apple's. Set at the same moment, for IM-10's receipt.
    var matchedMessageGUID: String?
    /// Not a `String` pair, and not four booleans: a pending row that expires and a
    /// pending row that landed are different facts and the store has to be able to say
    /// which.
    var state: OutboundState = .pending
}

enum OutboundState: String, Equatable, Sendable {
    case pending      // persisted, not yet observed
    case landed       // our row was found and identified
    case expired      // it never landed, and the window closed
    case abandoned    // a local act gave up on it
}
```

**That is the whole of it. Nine fields, and every one is a number, a digest, an id this app minted,
or a closed enum.** There is no `String?` that is free text, so there is nothing for a caller to
put a sentence in.

**Why Apple's ids are here and not in `usage.jsonl`.** Both stores are local and neither leaves the
Mac. They are different because of who reads them. `usage.jsonl` is a **rotating log a person and a
report read**, so it holds no Apple identifier and no digest — `IM-17-DESIGN.md` §3.2, "app-generated
ids yes, Apple's ids no", and this file does not reopen it. `imessage-outbound.sqlite` is a
**working store that exists in order to compare two digests**, so the chat it belongs to and the
row it matched are its reason to exist. `--imessage-report` reads the ledger and prints
`paired chat`, never a GUID.

**The digest is plain SHA-256, and a keyed HMAC was considered and rejected.** A key beside the
digests in the same file does not protect a copy of that file, and a key in the Keychain adds a
second store, a second failure and a second thing to migrate for an attacker who would need the
file in the first place. The exposure that is real is a *backup* of the app's support directory,
and that is Apple's backup of data the app wrote on purpose.

### 3.3 What may never be in it

Each of these with the reason, because each is a plausible-looking "harmless" field:

- **The text that was sent, or the text that came back.** The store is not a transcript and a
  transcript here is a second copy of a conversation nobody asked to keep.
- **A file name.** `report.pdf` is not a path, so `sanitise` would not catch it, and a name carries
  a person's project, a client and a date.
- **An address, a handle, a display name.** One number is a count. `conversationGainedAPerson`
  says "2 people" and never who.
- **A bundle id, a link, a body byte, a detected entity, a third party's offer.** None of them
  reaches this process: the decoder's return type (§1.1, and `IM-17-DESIGN.md` §2.3) means there is
  nothing to write.
- **An error sentence.** A failure is an `OutboundState` and a count. A localised description of a
  send failure is prose about the user's own machine, and prose is what survives every sanitiser.
- **A task status, a tool name, an approval state.** `TaskBridge`, `AgentRisk` and
  `ActionReceiptStore` own those. This store grows a `status` column the day somebody wants a second
  source of truth about a job.

**Retention, and why it is not optional.** A `landed` or `expired` row is deleted after
`retentionDays = 7` — longer than any plausible verification window, short enough that the store
does not become an accumulating set of digests of private sentences. The bound is a named constant
next to `MessagesWatermark.guidCacheLimit`, for the same reason that one is a constant.

**`UsageLog.sanitise` is not the control here, and the task text says it is.** It strips quoted
content, addresses, URLs, paths and six-digit runs. **A third party's promotional offer is none of
those — it is prose, and it survives every rule in the function.** At sanitisation it is already too
late anyway. Enforcement is therefore at construction: the nine fields above, one `insert`, and the
self-test case that proves it (§5, IM-08b).

### 3.4 The match

A row matches a pending row when **all** of these hold:

| condition | why |
|---|---|
| the chat matches | a digest is worthless without the conversation |
| the digest matches | the discriminator; an assistant repeating the user's exact sentence is the case a time window alone would swallow |
| `matchedRowID == nil` | one send, one match — a second row cannot claim it |
| `date >= dispatchedAt - 60 s` | absorbs a clock that reads ahead |
| attachment digests match, when any were sent | a photo we sent is recognised as a photo we sent |

**The window is one-sided, and the reason is a measurement.** `STATUS.md`'s IM-01 side finding
records `message.date` reading **up to ~6 minutes in the future** on the newest rows. A symmetric
window therefore has to be six minutes wide on one side to avoid rejecting a real echo, and a
six-minute window swallows the user's next message — which is a far worse failure than a rejected
echo, because the rejected echo is answered by the breaker counting it. **The upper bound is the
pending row's expiry (`pendingExpiry = 10 minutes`) rather than a timestamp comparison**, and a
pending row that expires goes to `.expired` and can never match a later row.

Both numbers are one-line constants with their reasons, and **they are the two a real capture would
move.** The rule is correct for any pair that admits the measured spread; the numbers are the part
that is provisional.

**The pending row is written before the Apple Event is dispatched** — the task's rule, unchanged.
A crash in the gap is exactly what the store exists for, and the recovery is a pending row that
expires.

### 3.5 The breaker

`> 5` agent-authored messages in 10 seconds with no `.userCommand` in the window suspends sending and
raises `pausedReplying` once. The state is **in memory**: a ten-second window does not survive a
relaunch, nothing is lost by that, and persisting it would be a second store for a rate. A **user
row resumes it immediately** — a user's own message is the proof the loop is over, and waiting for a
timer to expire while the person is standing there is the "slow and clumsy" failure `AGENTS.md` rules
out.

---

## 4. Authority

### 4.1 The split, in three lines

- **`.userCommand` may act** — but only on `AgentRisk.observe`/`.read`, only with
  `agentAutoRunReadTools` on, and only under IM-12's first band, because a read is invisible to
  everyone else.
- **`.userCommand` may propose** — one card, one approval, for `.write`/`.send`/`.purchase`; and
  IM-12's third band needs the Mac, which no phone message can satisfy.
- **Every other class may only answer, and four of them answer nothing at all** — the four refusals
  of §1.4 produce no turn, so no tool is reachable and no proposal is possible; `.userCommand` is the
  only class in which a tool can run at all.

**A class is not an authority.** `AgentRisk` grades a *tool*; the class decides whether there is a
turn for a tool to run inside. The two are separate because they answer different questions and
because the second one is upstream: there is no band, and no manifest, that can make a stranger's
message into a turn.

**The memory gate.** `recordUser(_:source:)` is called for `.userCommand` and for nothing else, once,
and with the sender's own words. A `.nextNotes` row never reaches it — the task's single most
important negative assertion — and neither does `.fromSomebodyElse`, which is `--selftest-imessage-privacy`
case 6 and is red until this task lands.

### 4.2 A link is a link, and the answer is not "the user said it"

A real body on this Mac carried a `__kIMDataDetectedLinkAttributeName` URL and a
`__kIMLinkPreviewAttributeName` preview (§0, and `IM-17-DESIGN.md` §2.2). **The decoder's return
type means neither reaches this layer** — the only string in a body is the one the sender typed. So
the question is not about Apple's detected link; it is about a link **the sender typed themselves**,
and the answer has to be more than "the user said it", because a link is a capability request
dressed as a word: following one turns a string into a network fetch on a remote turn, which is a
`read`/`observe` on somebody else's server.

**The rule, in three parts:**

1. **A link does not change the class.** A sentence with a URL in it is still `.userCommand`, and
   `carriesLink` is the only thing that differs. Classification is about who wrote it.
2. **A link is content, not an instruction.** A remote turn whose words carry a link may be **answered
   from words**; it may not, on the strength of the link alone, cause a fetch, a sign-in, a download
   or a page to be opened. Following a link is at least `AgentRisk.read`, and a remote origin may
   only **lower** what policy permits (IM-12), so a phone cannot raise it.
3. **A turn that is nothing but a link answers with `linkNotFollowed`** — the one sentence, in §1.5,
   which states the limit and the next action without a rule number in it.

**The mechanism, and where the enforcement lives.** IM-08 contributes the flag and the sentence.
Whether `browser`/`fetch` is reachable on a `.iMessage` turn is **`AgentCapabilityManifest`'s**
decision, and it is made there and nowhere else — `AGENTS.md` is explicit that the manifest is the
one source of truth for what a turn may do, and a second tool list inside the iMessage feature is the
exact thing that rule exists to prevent. **Assumed: `AgentCapabilityManifest` exists and has a place
to take a transport.** It does exist (§4.3); if its builder has no transport input, the follow-up is
one field there, not a filter in this feature.

**And the reverse direction.** A link the app *puts in a reply* is the app's own text, so it is
`write`/`send`-shaped and IM-13's approval covers it. Nothing here widens that.

### 4.3 The types I am designing against, and which of them exist

| type | state on 2026-09-26 | used for |
|---|---|---|
| `MessageBody`, `MessageBodySource`, `MessageDecodeFailure` | **present** (`IMessage/Database/`) | the class's inputs (§1.1) |
| `ChatRow.participants`, `MessageRow.handleID` | **present** (`MessagesQueries.swift`) | membership and direction (§2.2) |
| `MemoryProvenance`, `MemoryGuard` | **present** | the memory gate and its 0.9 weight (§4.1) |
| `AgentRisk` | **present** (`Agent/AgentModels.swift:10`) | the ladder a class sits inside (§4.1) |
| **`AgentCapabilityManifest`** | **present** (`Agent/AgentCapabilityManifest.swift`) — `IM-17-DESIGN.md` §0 calls it **planned** and that is now out of date | the tool exclusion for a link turn (§4.2) |
| `IMessageUsage`, `IMessageCount` | **planned** (IM-17d) | the six counts (§2.4) |
| `RemoteIdentity`, `RemoteIdentityStore`, `IMessageConfiguration` | **planned** (IM-07) | `local`, `pairedChatGUID`, `lastInboundCommandAt` |
| `IMessageBridge` | **planned, this task** | the one actor that wires watcher → classify → ledger |
| `TaskBridge` | **planned** (AO P6) | nothing here; the ledger does not grow a task column |
| `PendingOutboundMessage` | **planned, this task** | the ledger row (§3.2) |

`ActionOriginContext` and `RemotePreparedAction` are IM-12's and IM-13's, and nothing here needs
them: the class carries no authority, and IM-12 is where the transport meets policy.

---

## 5. Tasks

Four, each small enough for one agent, lettered per `00-README` §8. **1.5 days was the wrong number
for this task** — the same correction `IM-17-DESIGN.md` §5 made — because a security task whose
trust signal is unmeasured, with six classes, a store, a rate limiter and a memory gate, is three
days of work wearing a one-and-a-half-day label.

`NextNotesApp.swift`, `Scripts/acceptance.sh` and `AGENTS.md` are single-writer (`00-README` §7): the
registrations below are handed to the orchestrator. The build lock is taken for build → install →
one test → release and released in a `trap`; `make build` only, `make install OPEN=0`, self-tests
through `Scripts/run-selftest.sh`, foreground, one at a time, never `&`.

**One new flag, `--selftest-imessage-class`.** `--selftest-imessage-loop` is already named in
`00-README` §9 with its marker and its home (`OutboundLedgerSelfTest.swift`) — it is not registered in
`NextNotesApp.swift` yet, because no IM task has run; IM-08a/08b/08c all write cases into the new flag
instead, because three flags for three pure functions is three registrations to keep in step for no
extra signal.

### IM-08a — the classification, as a pure value · **do this one first**

**Files** — `Sources/NextNotes/IMessage/Classify/IMessageClass.swift` (new: `IMessageClass`,
`IMessageClassification`, `DirectionEvidence`, `EchoVerdict`, `ResolvedSender`,
`IMessageClassifier`, `IMessageClassifierCopy`), `IMessage/Classify/IMessageClassSelfTest.swift`
(new).

**Marker** `IMESSAGE_CLASS_OK: <n> cases` / `IMESSAGE_CLASS_FAILED: <case>: <reason>`. **Tier**
INTEGRATION.

**Red-first**, 14 cases: each of the six classes from a fixture row; the two copies of one command
(the `55189`/`55190` shape — same 25 characters, opposite `is_from_me`) are **both** `.userCommand`
and produce **one** turn; a foreign row is `.fromSomebodyElse` with no turn, no memory and one
card; a row from a number that will not resolve is `.fromSomebodyElse` with `directionEvidence ==
.unresolved` and a *different* sentence; an unreadable body from either sender is `.couldNotRead` and
its `MessageDecodeFailure` reason survives on the envelope; `.absent` is `.nothingToRead` and says
nothing anywhere; **`.notText` built by the `U+FFFC` rule and `.notText` built by `is_audio_message`
classify identically** and neither copies a bundle id into any string; a two-pending-row ambiguity
is a command; a text body containing a URL is `.userCommand` with `carriesLink == true`; and **no
string in `IMessageClassifierCopy` contains any of the eleven forbidden words or a bundle id**.

**Why first:** it needs no grant, no pairing, no model and no store, and every later task is its
consumer. It is also the task that makes `--selftest-imessage-privacy` case 6 turn from red to
green.

**Verify** `--selftest-imessage-class`, `--selftest-imessage-decode`, `--selftest-persona`,
`--selftest-ui-strings`.

**Do not** — Do not pass `IMessageEnvelope` into the classifier; the four parameters are the
enforcement. Do not add a `String` to `IMessageClassification`. Do not write a sentence for
`.couldNotRead`; the canary has one.

### IM-08b — the outbound store, the match and the breaker

**Files** — `IMessage/Sending/OutboundMessageLedger.swift` (new: `PendingOutboundMessage`,
`OutboundState`, the digest, the match, the breaker), `IMessage/Sending/IMessageOutboundStore.swift`
(new: the SQLite store, `init(root:)`, `isolated()`), `IMessage/Sending/OutboundLedgerSelfTest.swift`
(new — the existing `--selftest-imessage-loop` home), `Support/SelfTestStoreGuard.swift` (**one
line**, `imessage-outbound.sqlite`, **in this commit**).

**Marker** `IMESSAGE_LOOP_OK: 100 replies, <n> new memories` / `IMESSAGE_LOOP_FAILED: <reason>`.
**Tier CORE.**

**Red-first** — the task's six cases, unchanged: 100 replies produce **0 new `MemoryEntry` rows, 0
new `AgentSession` rows and 0 new agent turns**; an unmatched user row is exactly one session row; two
identical pending rows and one user message is a command; a crash between *persisted* and
*dispatched* leaves a row that **expires** rather than swallowing the next message; 6 agent messages
in 10 s with no user row suspends and a user row resumes; a matched row never reaches `recordUser`
even when its text is imperative (*"remember that the sky is green"*). **Plus four the task's list
does not have:**

- **the store's own allowlist**, proved with a fixture that *contains* a promotional offer, a body
  and a file name: build a row from it, write it, and assert that none of the three appears in the
  file — read with `strings(1)`, the same check the corpus uses. A field-level assertion is not
  enough, because the question is what reached the disk.
- **the one-sided window**: a row dated 6 minutes *ahead* of the dispatch still matches, and a row
  dated 40 minutes ahead does not (it expired).
- **retention**: a landed row 8 days old is gone; a pending row is not.
- **isolation**: the harness run writes `NextNotesSelfTest-<pid>`, never the owner's file.

**Verify** `--selftest-imessage-loop`, `--selftest-memory`, `--selftest-store-isolation`,
`make acceptance TIER=core`.

**Do not** — Do not add a `status` or `task` column. Do not store a file name or a text. Do not
persist the breaker. Do not write the pending row after dispatching. Do not log message text.

### IM-08c — membership and direction, as two pure functions

**Files** — `IMessage/Classify/SelfChatMembership.swift` (new), `IMessage/Classify/IMessageDirection.swift`
(new: the handle resolution and the `ResolvedSender` rules), `IMessage/Classify/IMessageClassSelfTest.swift`
(**extended**), `IMessage/Database/MessagesQueries.swift` (**one statement**, the handle lookup).

**Marker** `IMESSAGE_CLASS_OK: <n> cases` (same flag) / `IMESSAGE_CLASS_FAILED: <case>: <reason>`.
**Tier INTEGRATION.**

**Blocked on IM-07 and IM-02**, and the block is honest: `local` is IM-07's
`RemoteIdentityStore.localIdentity` and the **canonical form for comparing an address to a handle is
IM-02's answer** (gate G2, still `todo`). Both subtasks are written so the canonicalisation is one
pure function — `RemoteIdentity.normalised(_:)` — and a caller that cannot resolve says
`unresolved` rather than comparing raw strings. **If IM-02 has not landed, IM-08c's membership
cases cannot be honest and this task is `blocked` with a note, not `red`.**

**Red-first**, 9 cases: a chat whose only participant is the local number is the self channel; a
chat with two participants is not; a group that *was* only the user stays paired after a second
handle appears, and the gained handle is a number in the report and nothing else (the phase file's
"re-derive on every pass" is what this case denies); `cannotTell` when the participants join is
absent, and it is fail-closed; a row whose chat cannot be read is counted `notPaired`, advances the
watermark, says nothing on either side, and is **not** answered; the three `sender` rows of §2.2;
`unresolved` fails closed; a normalised comparison that would match a *suffix* of the local number
does not — the comparison is whole-value, not `LIKE`.

**Verify** `--selftest-imessage-class`, `--selftest-imessage-db`, `--selftest-store-isolation`.

**Do not** — Do not read `chat.chat_identifier` or `display_name`; both are guesses about an
unmeasured format (§2.2). Do not re-derive membership on a poll. Do not add a deadline — the settle
budget is IM-06's.

### IM-08d — the bridge, and the two local notices

**Files** — `IMessage/IMessageBridge.swift` (new, the one actor: watcher subscription, the
watermark, the ledger match, the breaker, the card), `IMessage/IMessageBridgeSelfTest.swift` (new,
its cases in `--selftest-imessage-loop`), `UI/Agent/IMessageStatusRow.swift` (**IM-17f's file, one
line** — five writers, name the owner first) or a card in the existing island activity surface.

**Marker** `IMESSAGE_LOOP_OK: 100 replies, <n> new memories` / `IMESSAGE_LOOP_FAILED: <reason>`.
**Tier CORE.**

**What it does and, more usefully, what it does not do.** It turns a delivered envelope into exactly
one of: a `RemoteCandidate` for IM-11's adapter, a ledger match, a count, or a card. **It does not
call `RealtimeAgent` and it does not own a conversation** — the adapter is IM-11's, the session is
the one session, and the bridge hands over a value. A finished feature with no call site looks
exactly like a working one, and the seam here is deliberately thin enough that IM-11 has something
to attach to.

**Red-first** — the bridge's own cases: a `.userCommand` yields one candidate with the sender's own
words and nothing else; a `.fromSomebodyElse` yields none, and **forty foreign rows in a row yield
one card and a count of forty**; a `.userCommand` whose text is already in the recent-fingerprint
set yields no second turn (the two-row measurement, and the case that says which mechanism did it);
a matched row is a ledger row and nothing else; a re-delivered row after a simulated relaunch yields
no second candidate; and `recordUser` is called exactly once per `.userCommand` and never for
anything else.

**Verify** `--selftest-imessage-loop`, `--selftest-imessage-watch`, `--selftest-contention`,
`--selftest-activity`, `make acceptance TIER=core`.

**Do not** — Do not build the adapter (IM-11). Do not add a second conversation, a second store or a
second channel. Do not notify per row. Do not print a chat identifier, ever, including a debug line.

### Registration, handed to the orchestrator

`NextNotesApp.swift` for `--selftest-imessage-class`; `Scripts/acceptance.sh` for its INTEGRATION
tier; `AGENTS.md` for the flag list and for the two lines this design adds to the "Things that look
like bugs" list — *"`is_from_me` cannot identify a self-message"* and *"a conversation with yourself
is addressed to your own number, so a row in it can be from somebody else."*

---

## 6. Verify the whole task

```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-imessage-class        # the three pure tables
Scripts/run-selftest.sh --selftest-imessage-loop         # CORE — the memory assertions
Scripts/run-selftest.sh --selftest-imessage-decode
Scripts/run-selftest.sh --selftest-imessage-db
Scripts/run-selftest.sh --selftest-imessage-watch
Scripts/run-selftest.sh --selftest-memory
Scripts/run-selftest.sh --selftest-store-isolation
Scripts/run-selftest.sh --selftest-ui-strings
Scripts/run-selftest.sh --selftest-persona
make acceptance TIER=core
```

**What is deliberately still red after this task lands.**
`--selftest-imessage-privacy` case 6 turns green; its `_ABSENT` marker does not, because the
sanitised 14th corpus case is IM-17c's and it does not exist yet. `--selftest-imessage-pairing` is
IM-07's. `--selftest-imessage-send` is physical. **A CORE flag that is red on a dependency is left
red.**

---

## 7. What the roadmap got wrong about IM-08

Recorded rather than only in the diff, because each one would have shipped.

1. **`00-README` §11, verbatim: "A `from-me` row that matches a pending outbound is ours; everything
   else is a user command."** The second clause is wrong for this chat. A Messages conversation with
   yourself is a thread addressed to your own phone number, so a row in it can be from somebody
   else, and §13's own glossary already has `.otherParticipant`. **This is the sentence to correct**
   and the correction is §1.2's table.
2. **The `.notText` rule a classifier would be written from is the wrong one for an effect.** §2's
   table row — verbatim: *"`payload_data` present, `balloon_bundle_id` set | a non-text balloon named
   by its column — a tapback | `.notText(bundleID:)` — a state the agent layer can say out loud"* —
   is a **real** route and stays: a tapback does come that way. The mistake is writing the classifier
   as though it were *the* route. All four of the owner's measured effect rows have `payload_data`
   absent *and* `balloon_bundle_id` NULL, so a classifier that reaches for that pair to recognise an
   effect recognises **nothing**. The body is an ordinary `NSAttributedString` → `NSObject` text
   balloon whose entire string is `U+FFFC` — three bytes, Apple's marker for "an attachment is
   here" — with **237 of 314 bytes passed over unread**. §2's own correction note (added 2026-09-26)
   says the row is no longer the *only* route; **what was never written down is that it is not the
   route for the case a classifier most needs to recognise**, and `is_audio_message` is a second
   independent one. Either signal gives the same class, which is why the rule is written for both.
3. **The task's own order diagram answers two questions with one.** `matched → direction = .nextNotes`
   / `not matched → direction = .user` has no `.otherParticipant` cell, and it makes the ledger the
   source of *direction* when the ledger answers only "is this our echo". §2.1 splits it into three
   and says which is which.
4. **Effort: "1.5 days — the security task of this phase."** Wrong by a factor of two, and the way
   it is wrong is the dangerous way: a security task with a time box gets the rule that is easiest to
   write rather than the one that is right.
5. **"Do not put contents in a metrics row — `UsageLog.sanitise` exists for that and the ledger is
   not exempt."** The sanitiser is not the control and cannot be. A third party's promotional offer
   is prose; it survives quoted content, addresses, URLs, paths and six-digit runs. **Enforcement is
   at construction** — the ledger's nine fields and one `insert` — and the task text should say so.
6. **The file list has no classification file.** `OutboundMessageLedger`, `IMessageOutboundStore`,
   `IMessageBridge` and the self-test are listed; the thing the task is *named* for is not. It also
   has no `UI/` file, and this design needs two local notices.
7. **§1.2's table is absent, so two vocabularies coexist.** The glossary's three directions and the
   decoder's four body states are different axes, and the task's diagram spells them a third way.
   There is now one set of names (`IMessageClass`) and §1.2's mapping table is the reconciliation.
8. **The task is silent on which handle sent a row, and that is the only signal that answers
   "is this the user".** `MessageRow.handleID` is already projected and nothing resolves it;
   `is_from_me` cannot do the job, because the measurement is that one message produces two rows
   with opposite values.
9. **It is silent on a link in a remote turn**, and finding 5 makes that a hole rather than a nicety:
   a URL that reaches a model is a network fetch waiting to happen, and "the user said it" is not an
   answer to a capability question.

---

## 8. What I had to assume, and what would collapse the rule

| assumption | why it is an assumption | which measurement collapses it | what breaks if it goes the other way |
|---|---|---|---|
| **`message.handle_id` resolves to the sender on an incoming row** | not captured. The two candidate semantics (sender vs. recipient) **coincide for both cases this feature sees** — a self-chat's only handle is the user's, and a foreign row's handle is the stranger's either way — so the rule is written for both answers and neither changes a class | one capture of the paired chat with a foreign row, `handle_id` beside `handle.uncanonicalized_id` | nothing in the table; it would become a comment about the reader instead of a rule about the class |
| **the two copies of a self-message share a `message.guid`** | not recorded — the capture has row ids and byte counts, not guids. `TYPEDSTREAM-NOTES.md` asserts the guid cache stops the second copy, and that assertion **depends on it** | the same capture, with `guid` on both rows | if they differ, `MessagesWatermark` does not collapse them and the **command fingerprint** in IM-08d does. Written for both, and it is a bounded in-memory set, not a store |
| **a real voice note's body shape** | `voice-note-row-shape-from-a-real-message` is still blocked; the corpus row carries a two-byte body that refuses | a voice note sent to the owner's own conversation, with `is_audio_message` in the capture | **nothing in IM-08** — both signals already land in `.notText`, and `MessageBodySource` cannot reach the classifier. It changes IM-15's handling only |
| **the canonical form for comparing an address to a handle** | IM-02's report, gate G2, `todo` | IM-02 | IM-08c is `blocked`, and the classification stays honest as `.unresolved` — which is the fail-closed answer, so the failure mode is a silent feature rather than an unsafe one |
| **the clock spread** | `message.date` read up to ~6 minutes ahead on ten rows on one machine at one moment | a capture spanning a sleep/wake | `skew = 60 s` and `pendingExpiry = 10 min` are the two numbers that move. A wider spread widens them; the *rule* is the conjunction, not the numbers |

**And one thing I did not design for, because it is not a third possibility.** A foreign row in the
paired chat is in the glossary, is reachable in principle, and has a structural reason rather than a
guess: the thread is addressed to a number anybody can text. What is true is that **no foreign row
has ever been observed on this Mac** — at capture time it had no self-conversation at all, all 50
chats had somebody else in them, and IM-01's self-message produced the two-row shape rather than a
third-party one. So the `.fromSomebodyElse` cases are fixture-driven, and that is the honest state of
them: they prove the classifier's behaviour, not that the situation occurs.
