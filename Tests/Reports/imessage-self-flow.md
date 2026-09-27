# IM-01 / gate G1 — what a self-message from your own phone actually is

**What this answers:** when you text yourself from your iPhone, what appears in `chat.db` on the Mac,
and whether that row is distinguishable from one the Mac sent.

**Date:** 2026-09-27 · **macOS 27.0 (26A428)** · **Full Disk Access:** granted, and the probe read a
row out of the live `~/Library/Messages/chat.db` to prove it · **Sanitised:** handles are
`REDACTED-HANDLE-1` and every identifier is a shape. `Tests/Reports/` is tracked; no phone number,
contact name or message body appears in this file.

**Gate G1 does not close.** Q1 and Q2 are answered, three times over, and Q3 was never run. What is
missing is named in §5 rather than left as a silence.

---

## 1. Q1 — the filter. `is_from_me` decides nothing.

**A message you send to yourself from your iPhone arrives as TWO rows, with opposite `is_from_me`
and an identical body.** Three captures, three separate sends, three times the same shape:

| sent from the phone | rows | `is_from_me` | body | characters |
|---|---|---|---|---|
| `Hello Chikita!` | 55213 / 55214 | `true` / `false` | **189 B, byte-identical, same raw timestamp** | 14 |
| `Test intensifié 🫡` | 55215 / 55216 | `true` / `false` | **196 B, byte-identical, same raw timestamp** | 17 |
| (earlier capture) | 55189 / 55190 | `true` / `false` | 202 B, byte-identical | 25 |

The two rows of each pair carry the **same raw `message.date` value** — not merely the same wall
clock, the identical Apple-epoch integer.

**Therefore:**

- **IM-07's filter must pair by chat, never by row.** The original roadmap text assumed a self-message
  is a `from-me` row. It is not: one of the two copies is `is_from_me = 0`. A watcher that filtered on
  the column would have answered **half of every command you sent**, silently, forever.
- **`is_from_me` is not a direction.** It answers "did this Mac send it", and it cannot even tell
  the two copies of one message apart. Direction is the row's **sender**; the outbound ledger answers
  "is this our own echo". Three different questions, three different inputs — which is what
  `IM-08-DESIGN.md` concluded and what this measurement forced.
- **A conversation with yourself is not a private channel.** It is a thread addressed to your own
  number, so a row in it can be from somebody else. "Everything else is a user command" is wrong for
  it, and a non-user row there must be `.fromSomebodyElse` with no turn and no memory.

## 2. Q2 — the decoder's specification

All nine captured rows agree on the header, and none carries a `payload_data`:

> first 16 bytes, **every row, all captures:** `04 0B 73 74 72 65 61 6D 74 79 70 65 64 81 E8 03`
> i.e. `04` · `0B` · `"streamtyped"` · `81 E8` · `03`

**The version gate is confirmed on this macOS: streamer 4, system version 1000 little-endian** — the
shipped decoder's default, and byte-for-byte what `NSArchiver` writes. `payload_data` and
`balloon_bundle_id` are **absent on every row**, including the voice note and the reaction.

| row | `text` | `attributedBody` | what it is |
|---|---|---|---|
| 55205 | 38 chars | 219 B | **a reaction** — decodes to `Liked "<your sentence>"` |
| 55206 | 123 chars | 1760 B | a link preview, third-party content |
| 55207 | 131 chars | 1774 B | a third party's promotional payload |
| 55208 | 21 chars | 196 B | an automatic reply |
| 55209 | 33 chars | 213 B | a message carrying an emoji |
| 55211 | **NULL** | 466 B | **a voice note** — 389 of 466 bytes unread |
| 55212 | 234 chars | 1226 B | a long message |
| 55213 / 55214 | 14 chars | 189 B | the self-message, both copies |
| 55215 / 55216 | 17 chars | 196 B | the self-message, both copies |

### 2.1 Bytes or characters — **bytes**, settled on a real body

The owner sent `Test intensifié 🫡`: **17 characters, 21 UTF-8 bytes** (a 2-byte `é`, a 4-byte astral
emoji). The shipped decoder returned exactly that sentence from the 196-byte body. The length field
inside the stream is a **byte** count.

The oracle matters: the expected output was **what the owner typed**, supplied out of band, not the
decoder's own output. Deriving `text=` from the blob would have made the assertion the decoder
agreeing with itself.

An all-ASCII sentence **cannot** answer this — 14 characters is 14 bytes — and the suite says so
rather than passing:

```text
IMESSAGE_DECODE_FAILED: real_body_decodes_to_the_sentence: the artefact's sentence is
14 bytes and 14 characters, so it cannot tell bytes from characters — capture a body
with a non-ASCII character in it
```

**Now `IMESSAGE_DECODE_OK: 48 cases`, 0 blocked, 0 wrong** with the live capture; unchanged at 36
cases / 7 blocked without it, so the number says which run you are reading.

### 2.2 Two corrections this spike forced on our own notes

- **`TYPEDSTREAM-NOTES.md` said the sentence had "three multi-byte characters".** It has **two** (both
  `é`). Three two-byte characters would be 28 bytes and a three-byte character 29; the body declares
  `0x1b` = 27. The old wording could not be reconciled with the body it described.
- **`BLOBBODY_REAL` in the generated capture is not "the real body".** It is the **first row that has
  one** — a de-duplication convenience — so it has pointed at a reaction, then at a 1,774-byte
  third-party row. The self-message always has its own inline hex further down. Cost me two wrong
  turns; recommended fix and its two dependencies are in `STATUS.md`.

### 2.3 An effect and a reaction are **not** the same animal

- An **effect** is a text balloon whose entire string is three bytes of `U+FFFC` (Apple's attachment
  marker), with 237 of 314 bytes unread, and `payload_data` and `balloon_bundle_id` both NULL. So the
  roadmap's "`payload_data` present + `balloon_bundle_id` set" rule **fires on none of the measured
  effects** — it cannot be how a classifier recognises one.
- A **reaction** is a text balloon carrying **ordinary prose** — the verb and the quoted original. So
  the walk reads it as `.text`, and on IM-08a's current table a `.text` body from your own number is
  **`.userCommand`**.

**Which means reacting to a message, or texting yourself a tapback, would be answered as though you
had typed a command.** This is a *prediction from a measured body*, not a measured classification:
what is measured is that a reaction is a text balloon carrying the reaction text. It needs its own
case and its own class before IM-08d builds a bridge on the current table.

### 2.4 `is_audio_message` is not a signal

The real voice note (row 55211) reads **`is_audio_message = 0`**, as does every row in the capture.
Messages does not write that column for audio on this macOS, so the corpus's `voice-note` case — which
has carried `is_audio_message=1` since IM-04 — is a *shape*, not a measurement. The column is kept
anyway, on measured reasoning: it is the only signal on the two row shapes the walk cannot reach (a
body it refuses, a row with no body). Forcing it to 1 on the real row **changes nothing** about the
answer, because the walk classifies the note first.

## 3. A defect this found in the reader: `participants` is empty on every chat

`--imessage-self-flow` reports the self-chat as:

```text
IMESSAGE_SELF_FLOW_SELF_CHAT: none of the conversations above looks like one
```

and **all 50 chats it printed carry `who=[nobody named]`** — `ChatRow.participants` is empty for every
one. `MessagesSelfFlowReport.isSelfChat` requires `participants.count == 1`, so **it can never be
true on this machine**, and the predicate is dead code rather than a wrong answer.

This is load-bearing, because the generated fixture emits a *synthetic* paired chat
(`iMessage;-;REDACTED-HANDLE-1`, one handle) while the report says it cannot find a real one. **The
fixture asserts a self-chat exists; the reader cannot find one.** Those contradict, and the fixture is
the synthetic half.

`participants` is gated on `MessagesQueries.participantsPresent(schema)`, which requires
`schema.has("handle", "ROWID")` — and `PRAGMA table_info` **does not list an implicit `ROWID`**. That
is the leading hypothesis and it is *not* confirmed: Apple's `message` and `chat` declare `ROWID`
explicitly, which is why `missingIdentity` passes and the database opens. Distinguishing the two
needs one more line in the report printing the probe's own verdict, which is a small change and is
**IM-07's first task**, not something to guess at.

## 4. Q3 — the delay. **Not measured.**

Experiment 12 (send, sleep the Mac, send two more, wake) was **never run**, so:

- whether rows arrive together after wake, and in what order, is **unknown**;
- whether the WAL or the main file carries them is **unknown**;
- IM-16's per-message-vs-per-backlog drain is therefore **still undetermined**.

This is the reason G1 stays open. It is one experiment and it needs a person to sleep a Mac.

**A side finding that should be looked at before anything depends on recency:** `message.date` reads
up to ~6 minutes in the **future** on the newest rows, across all captures. The Apple-epoch arithmetic
is right, so either Messages writes slightly ahead or the clock is off. A watcher that orders by date
needs to know which.

## 5. Gate status — what is answered and what is not

| requirement (`01-PHASE-0-SELF-FLOW.md` §"Done when") | state |
|---|---|
| the report exists, is committed, and is sanitised | ✅ |
| **Q1** answered explicitly | ✅ three captures, `is_from_me` shown to decide nothing |
| **Q2** answered explicitly | ✅ header, bytes-vs-characters, the effect/reaction/voice shapes |
| **Q3** answered explicitly | ❌ **experiment 12 never run** |
| G1 row says `done` | ❌ **it says `partial`, and that is the honest state** |
| IM-07's task text amended for the Q1 answer | ✅ recorded in `STATUS.md`; **the reader defect in §3 is now IM-07's first task** |

Experiments **1, 5, 7, 11** are covered by these captures. **2, 3, 4, 6, 8, 9, 10, 12** were not run.

## Reproduce

```bash
make build && make install OPEN=0
# through LaunchServices: Full Disk Access is keyed to the responsible process, and a direct
# shell launch is attributed to Terminal and reports a denial that is not one
Scripts/run-selftest.sh --via-open --imessage-self-flow --selftest-out /tmp/self-flow.txt
```

The real body stays a **local artefact**
(`~/Library/Caches/NextNotesBuild/imessage/self-flow-case.sh`) and is never committed: it carries a
live link and a third party's promotional payload. The corpus keeps synthetic placeholders, and the
corpus generator's sanitisation guard refuses the real hex outright — a 314-byte body is full of
11-digit runs, which is the guard working rather than a gap in it.
