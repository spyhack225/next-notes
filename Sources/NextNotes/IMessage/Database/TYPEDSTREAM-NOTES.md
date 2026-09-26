# `attributedBody` / typedstream — what is known, what is guessed, what IM-01 must measure

**Written:** 2026-09-25 · **against:** macOS 27.0 (26A428), Xcode SDK `MacOSX.sdk`
**For:** `IMessage/Database/MessagesDecoder.swift` (IM-05) and
`Tests/Reports/imessage-self-flow.md` (IM-01)

This file exists so the decoder is designed **once**. It is a research note, not
a specification: the format is Apple's and undocumented, so half of it is
inference, and the half that matters most is inference from outside this
repository. Every claim below is labelled with where it came from, and the
labels are not decoration — §1 is the part a plausible-looking wrong answer
would be built from.

## 0. Provenance of every claim in this file

| Label | Meaning |
|---|---|
| **[measured]** | Checked on this machine on 2026-09-25, and the command is given. |
| **[measured — Apple's encoder]** | Checked on this machine against bytes **`NSArchiver` wrote at test time**, not bytes Messages wrote. Says what the system encoder emits; says nothing about what Messages emits. The distinction is load-bearing and is stated at every use. |
| **[published]** | From a public reverse-engineering write-up. Not Apple documentation, not verified against a blob on this Mac, and not verified on macOS 27. |
| **[inferred]** | My reading of the above. Could be wrong. |
| **[UNMEASURED]** | Nobody knows, including this file. This is what IM-01 is for. |

**What was checked here, and what it rules out.** [measured] `~/Library/Messages/`
on this machine answers `ls: Operation not permitted` — no Full Disk Access — so
**there are no real message bytes available to this note at all.** Every
structural claim below is therefore `[published]` or `[inferred]`, with one
exception that arrived later and is labelled separately: claims about **what
Apple's own encoder writes** are `[measured — Apple's encoder]`, established by
asking `NSArchiver` to archive known objects and reading the bytes back. That
exception is narrower than it looks and does not narrow with repetition —
**`NSArchiver` and Messages are two different writers of the same format**, and
only the first has ever been observed. Not one claim here has been confirmed
against a blob written by Messages. That is not a reason to proceed; it is the
reason §3 exists and the reason the decoder must be built to refuse rather than
to guess.

**What [measured] *does* establish, and it is load-bearing.** From the SDK this
repo builds against (`NSArchiver.h`):

```objc
API_DEPRECATED("Use NSKeyedUnarchiver instead", macos(10.0,10.13), …)
@interface NSUnarchiver : NSCoder { … signed char streamerVersion; … }
```

`NSUnarchiver` is **present** on macOS 27 and is the class that owns a
`streamerVersion`. `NSKeyedUnarchiver` is not involved in this format at all
(§2). Also [measured] on this machine: `sw_vers` = 27.0 / 26A428, and
`/usr/bin/sqlite3` = 3.54.0 — the two facts a decoder has to be told rather than
assume.

---

## 1. What `attributedBody` is, structurally

### 1.1 What kind of container it is

[published] `attributedBody` is a **`typedstream`**: the undocumented binary
serialisation that sits *underneath* the deprecated `NSArchiver` /
`NSUnarchiver` pair. It is not a property list, not a keyed archive, and not
JSON. `file(1)` recognises a dumped blob as:

```
NeXT/Apple typedstream data, little endian, version 4, system 1000
```

`typedstream` descends from NeXTSTEP's object serialisation. It has never been
in any Foundation specification, Apple has never documented it, and Apple has no
commitment to it — which is the whole reason the version gate in §5 is data.

### 1.2 The 16-byte header — the version gate

[published] Every `attributedBody` inspected in the public reverse engineering
begins with the same 16 bytes, and `file(1)` decomposes them:

```
04 0b 73 74 72 65 61 6d 74 79 70 65 64 81 e8 03
^^  ^                          ^  ^^^^^^^^^^^
|   |                          |  u16 = 1000
|   |                          0x81 = "a 2-byte integer follows"
|   11 = length of the next 11 bytes
0x04 = the streamer version (`file` prints it as "version 4")
        "streamtyped"
```

So the gate is a **pair**: the streamer version at offset 0, and a system
version that is a typedstream integer **read from offset 13** — *not* a `u16`
read at 14–15. Those two bytes are only where the value *lands* when the head
byte in front of it happens to be `0x81`; a one-byte system version would sit at
13, a `0x82` one at 14–17. Reading a fixed `u16` at 14–15 is reading a dump, not
the format, and it is the kind of shortcut that works on every sample until the
day it does not. Both halves are in the header, both must be matched, and
neither is a macOS version — `1000` has been constant regardless of which macOS
wrote it.

[measured — Apple's encoder, 2026-09-25, macOS 27.0] **On this Mac that pair is
still `04` / `1000`.** `NSArchiver.archivedData(withRootObject:)` wrote
`04 0b "streamtyped" 81 e8 03` for all twelve root shapes tried — `NSString`,
`NSMutableString`, `NSAttributedString`, `NSMutableAttributedString`, with and
without attribute runs. This is no longer the blocking open question it was when
this file was first written, and the decoder's gate is now written as data
(`MessagesSchemaVersion.supported`) rather than as a guess.

**Attribute that precisely, because this file exists because the format is
undocumented and an over-claim here undoes the whole thing.** It is a
measurement of *Apple's own encoder on this Mac*. It is **not** a measurement of
what **Messages** writes, which is a different question, is still unknown, and is
still IM-01's job. `~/Library/Messages/` answers *Operation not permitted* on
this machine, so nothing in this repository has ever read a blob Messages
wrote. What moved from [UNMEASURED] to [measured] is *"the encoder still writes
this header"*; what did not move is *"Messages still writes this header"*. §3
is unchanged and is still what closes the gap.

[published] **The same container does carry other versions**, so the gate is
real rather than ceremonial: `message_summary_info` (Ventura and later, the
edit history) is a typedstream too and has been reported failing to parse with
`Invalid streamer version: 98`. A decoder that ignores the version byte will
mis-read a column that is not a message body at all.

### 1.3 How a payload is framed

[published] There is no self-describing framing. A stream is a **cursor** over
bytes, and the cursor only advances because the bytes tell it how much to read:

| byte | meaning |
|---|---|
| `0x84` | a new entry follows; a **length byte** or a **reference** follows it |
| `0x92` and up | a *reference* to an entry already seen (indices start at `0x92`) |
| `0x85` | nil / end of a class chain |
| `0x86` | end of an object |
| `0x81` | a 2-byte integer follows |
| `0x82` | a 4-byte integer follows |
| `0x83` | a float/double follows; width comes from the type tag |
| `0x87`–`0x91` | **reserved tags a real stream never writes** — not integers of any width |

[measured — Apple's encoder, 2026-09-25] **Correction to an earlier version of
this table, which listed `0x87` as an eight-byte integer marker. It is not, and
the decoder refuses `0x87`–`0x91` as tags rather than reading a number out of
nothing.** The public write-up the earlier table came from carries that row; the
encoder does not produce it, and a reader that treated it as a width would read a
64-bit length from a tag. `MessagesDecoder`'s `Tag` enum names only the tags it
sees (`0x81`, `0x82`, `0x84`, `0x85`, `0x86`) and every other head byte in the
tag range is `structureUnreadable`.

[measured — Apple's encoder, 2026-09-25] **`0x80`–`0x8F` are the *tag* range, so
the length is not written "one byte if it fits".** Two facts, and they are easy
to conflate: a length above 127 escapes to `0x81` + little-endian `u16` (a
540-byte payload does, and `--selftest-imessage-decode` asserts all 540 bytes
come back rather than 36), **and** a value that would land in `0x80`–`0x8F` is
two bytes even where it would fit in one. The second is the reason the first
cannot be implemented as a size test, and "one byte if it fits" is therefore not
a safe default applied to an edge case: it is a rule that is wrong on real
lengths and wrong in the middle of a class of lengths, with no error at all.
The decoder's `readUnsignedInteger` treats a head byte in the tag range that is
neither `0x81` nor `0x82` as a tag where a number belongs, and refuses.

[published] Two tables are being filled *as the stream is read*, and both are
addressed by index, which is why a reader that mis-numbers either one
desynchronises silently and starts returning plausible nonsense:

1. **A shared-string table.** Every string the archiver writes appears once, as
   a length plus its bytes, and is referenced by index thereafter. Class names,
   type-encoding strings (`i`, `I`, `+`, `@`, `d`, `q`), selectors, atoms and
   `char *` text all draw from this *one* table, in order of first appearance.
2. **An archived-object table.** Objects, class definitions and `char *`
   pointers each take an entry in order of appearance.

A "class entry" is a class name followed by a version byte, then a class-chain
of `0x85`-terminated superclass references. A value is then the field data for
that class, in a fixed order the format does not record — field *names* are not
in the stream.

### 1.4 Where the string sits, and how its length is encoded

[published] A plain text body's `attributedBody` is an `NSMutableString` nested
inside an `NSMutableAttributedString`, and the text is that string's field data:

```
… 84 08 "NSString" 01  95  84 01 2b  <length>  <UTF-8 bytes>  86 …
                     ^^  ^  ^^^^^  ^^^^^^^^
              class  +   |    |   length   content
                    version|    │
                  0x95 =  |   type tag `+` (0x2B) = a string
                  NSObject |
                  in the   |
                  object   |
                  table    |
                            the length is an *integer in typedstream's own
                            variable-width encoding*: one byte below 128,
                            else 0x81 + u16, or 0x82 + u32 — and never a value
                            that would land in the tag range, so it is not
                            "one byte if it fits" (see §1.3)

```

**This is the whole answer to "why not string-search for the first printable
run", and the roadmap's own prohibition (§2 of `02-PHASE-1-P0-SLICE.md`) is
right for a stronger reason than tidiness.** A scan produces a *prefix* of the
text, silently, with no error — and a truncated sentence is a sentence a person
will act on. A length-driven parse either produces the whole string or refuses.

[measured — Apple's encoder, 2026-09-25 · **confirmed against Messages' own bytes
2026-09-26**] **That length is a UTF-8 *byte* count, not a character count.** A
payload of `héllo 🌍 ok` — 10 characters, 14 bytes — is prefixed `0x0e`. Every
published sample is ASCII, where the two are the same, so the published work
could not have told; the case that tells them apart is exactly the one a person
most wants read, and a decoder that guessed wrong truncates every message with
an emoji or a CJK character in it.

**The Messages half of that is now measured too**, and it is the last open
question IM-01 had for this file. A real 202-byte self-message body — a sentence
of **25 characters** and **27 UTF-8 bytes**, two of them accented — declares
`0x1b` = **27**, and the shipped decoder returns all 25 characters with both
accents intact. The writer is counting bytes; the reader agrees. The
counterfactual was run rather than argued: rewriting that one length byte to the
*character* count makes the same decoder return 25 bytes of the sentence, its
last character gone, **with no error at all** — which is the truncation this rule
exists to prevent, and which §7 records. (The sentence itself is a person's own
message and is deliberately not quoted here; the transcript outside the
repository has it.)

[published] Three further things about the text that a decoder must know:

- A message with an attachment carries **`U+FFFC`** (object replacement
  character) in the string. It is not corruption and must not be stripped
  silently — it is how a photo is *marked*.
- Type-encoding strings are a **grammar, not a list**: `{_NSRange=QQ}` is a
  struct with two members, `[3i]` an array. A reader that maps one byte to one
  type desynchronises on `{CGSize=dd}`, whose *name* contains `C`, `S` and `i` —
  all real type tags — and starts reading a phantom unsigned short. A decoder
  that only needs the string should not need to model this; a decoder that does
  must parse the name and recurse.
- `NSArchiver` refuses to encode unions, bitfields and raw pointers, raising
  rather than writing. So those can be treated as **errors** rather than
  guessed at: a valid stream never contains them.

### 1.5 What could not be determined offline, in one list

**Settled for Apple's encoder on this Mac** (attributed as in §1.2):

- whether `04` / system `1000` still holds on macOS 27.0 — it does, per the
  twelve root shapes tried
- bytes vs characters for the string length — **bytes**

**Settled against Messages' own output on 2026-09-26** (§7): the header pair is
`04` / `1000` and the string length is a **byte** count.

**Still open, and this is the honest remainder.** Each of these needs a capture
that has not been made:

- the class-version bytes Messages writes for a *concrete* class —
  `NSAttributedString` v0 / `NSObject` v0 and `NSString` v1 on the 2026-09-26
  bodies, while `NSArchiver` wrote `NSMutableString` v1 / `NSString` v1 for the
  same shape. The decoder matches the **chain** rather than the leaf precisely
  because the two writers disagree, and the real bodies did not break that; but
  a third writer could.
- `U+FFFC` behaviour on this OS. The 2026-09-26 capture has no photo in it, and
  §1.3's claim that the first printable run in a real body is `streamtyped` was
  confirmed — a scan would have returned the format's own name on all nine.
- the `payload_data` + `balloon_bundle_id` shape for an effect bubble
  (IM-01 experiment 11) — nothing in this note claims to know it, and the
  2026-09-26 rows all had `payload_data=absent`
- whether an edited message's body is the edited text or both texts
- `message_summary_info`'s container, beyond the fact that its version differs

**None of the second list is answerable without a real blob**, and the first two
lists are why that is not fatal: the parser's *mechanics* were pinned against
Apple's own encoder before a Messages byte existed, and the layout Messages
actually writes is now measured for a text balloon. A parser written from this
file alone is still written from [published] inference about Messages' bytes, and
must therefore be built to refuse rather than to succeed. That is not a caveat on
the design; it *is* the design — and §7 is what a refusal on an unfamiliar macOS
will look like when it happens.

---

## 2. System API, or hand-written parser

### 2.1 `NSKeyedUnarchiver` is the wrong API, and not by a small margin

[measured + inference] A **keyed** archive is a binary plist with a `$archiver`
key naming `NSKeyedArchiver`, a `$version`, a `$top` and a `$objects` array.
A typedstream has *none* of those — it has a streamer version byte, a stream
name, and a byte cursor. `NSKeyedUnarchiver` given an `attributedBody` will
fail to open the archive. So the question "can `NSKeyedUnarchiver` read it?" has
the answer **no, and it was never the candidate**: it is the modern
*replacement* for `NSUnarchiver`, not a reader of the same format.

### 2.2 The API that *can* read it is the one that cannot fail safely

[measured] `NSUnarchiver` (`NSArchiver.h`, this SDK) is the wrapper around
typedstream and it is still present on macOS 27. It is
`API_DEPRECATED("Use NSKeyedUnarchiver instead", macos(10.0, 10.13))` — still
compiled, still shipping, and reported to work when called despite the warning.

The problem is its failure channel, and it is the reason this note recommends
against it:

- [measured] It has **no throwing API and no `decodeObjectOfClass:forKey:`**.
  Its entry points are `initForReadingWithData:` and `+unarchiveObjectWithData:`,
  and both signal failure by **raising an Objective-C exception**
  (`NSInvalidUnarchiveOperationException`, `NSInvalidArgumentException`).
- [inferred] Swift has no `@catch`. A raised `NSException` is **not a Swift
  error** — it propagates and terminates the process. There is no way to wrap
  this in `try`/`catch`, and there is no way to make it return `.unreadable`.

So the choice is not "safer system API vs. portable parser" in the abstract. It
is:

| | hand-written parser | `NSUnarchiver` |
|---|---|---|
| bad input | returns `.unreadable(reason:)` | raises; **terminates the app** |
| unfamiliar version | mismatch, returns `.unreadable` | raises; terminates |
| survives a macOS update | yes, by refusing | no |
| can be tested with a fixture | yes, in-process | no — the test *can* crash too |
| wrong answer possible? | yes, on a format it half-understands | no |

### 2.3 Which failure mode is worse here, and what the roadmap's rules point to

**The exception failure mode is strictly worse for this app, and it is not
close.** A macOS update that changes the format is *expected* — the roadmap says
so in three places, and the canary is a metric counting undecodable messages
(`03-PHASE-2-P1-SLICE.md` §*canary*). The entire designed response to a format
change is "degrade the feature and say so". `NSUnarchiver` converts that designed
response into a crash, and it does so **inside the message read path**, on
input the app does not control, on the user's own machine. A feature that reads
your iMessage history and can be killed by an OS update is not a feature.

The parser's failure mode is real but *designed for*: a wrong answer on a format
it half-understands. The roadmap already has the answer to that one, and it is
stated twice:

> `IMessageEnvelope.text` becomes `String?` and gains a `decodeState`, so
> **nothing downstream can read an undecodable message as a blank one.**

> Do not return `""` for a body you could not read. That is the whole task.

**So: hand-written parser, with the version gate as data and the refusal as a
first-class result.** The rules point there and not to the system API, because
the system's failure mode is a process exit and the roadmap's stated contract is
a value.

**One deliberate exception, and it belongs in the self-test, not in the app.**
`NSArchiver` is *deprecated but working* on this OS, and it will archive
whatever it is handed. That makes it an **oracle**: a self-test can archive a
known `NSString` / `NSAttributedString`, assert the decoder recovers exactly
that, and pin the parser's mechanics without a human and without an iPhone.
It proves length handling, the string table, integer widths and the
descriptor grammar — it does **not** prove the layout Messages writes, which is
a different question, and it must not be presented as though it did. Note that
`02-PHASE-1-P0-SLICE.md` §1 says "do not synthesise a typedstream"; generating
one *at test time from Apple's own encoder* is not synthesising one, but it is a
deviation and belongs in the commit message and in `STATUS.md`, not smuggled in.

**The deprecation is the point, and the warning is deliberately left standing.**
`NSArchiver` is deprecated in favour of `NSKeyedUnarchiver`, which cannot open a
typedstream at all (§2.1) — so there is no supported replacement to migrate to
and the deprecated call is not a shortcut, it is the only encoder of this format
the system still ships. The test therefore contains **exactly one** deprecation
warning, from the one call site in `MessagesDecoderSelfTest`'s oracle, and it is
intentional: a reviewer silencing it would be silencing the only statement the
codebase makes that this API is deprecated and is used anyway. It is confined to
the test, never to the message read path, for the reason in the paragraph above —
in a self-test a raised `NSException` costs the run; in production it costs the
process. `--selftest-imessage-decode` is the file that carries it, and
`--selftest-private-network`-style hygiene does not apply: nothing here opens a
network connection.

**What the oracle pins, and what it cannot.** Using it pins **this parser's
mechanics** — the header shape, the shared-string table, the byte-counted
length, the `0x81` escape, the class chain, the descriptor grammar, and the
refusal of everything else. It is **not evidence about Messages' own layout**,
and the distinction must not erode as the test grows: the case names say
`archiver_oracle_*` for that reason, the corpus cases say nothing of the sort,
and every claim that genuinely needs a Messages blob is a named
`IMESSAGE_DECODE_BLOCKED:` line in the self-test rather than a passing case. A
future agent adding a sixth oracle case is adding evidence about the parser; if
they are trying to close a gap about Messages, the gap belongs in IM-01.

---

## 3. What IM-01 must capture

### 3.1 The single most important thing

**One real `attributedBody` for a message whose exact text the sender already
knows, together with the 16-byte header and the macOS version — all three on one
line, or it is worth nothing.**

Everything else in this file is either inference or plumbing. That one artefact
converts §1 from [published] to [measured] and makes the whole decoder
buildable. Two parts of it matter more than the rest:

1. **The header pair, verbatim** — byte 0 (the streamer version) and the
   system version read out of the typedstream integer at offset 13 (whose bytes
   sit at 14–15 only because that head byte is `0x81`). That pair *is* the
   version gate, and §5 builds the gate out of exactly these two numbers.
   Whether **Messages** still writes `04` / `1000` is [UNMEASURED] and is what
   this capture blocks: Apple's own encoder writes it (§1.2), and Messages is a
   different writer.
2. **The expected output.** Not "the first printable run" — the text the person
   typed, character for character, which only the sender knows.

### 3.2 How to get it without leaking anything, and without hunting

**Have the sender type a body that is itself a placeholder.** Send, from the
phone, exactly:

```
FIXTURE-SENTENCE alpha bravo charlie
```

Then the expected decode *is* that string, it needs no sanitisation, it cannot
be a real conversation, and it lands in a tracked file safely. This one habit
removes the entire sanitisation problem from the most delicate artefact in the
roadmap, and it costs nothing.

**Do not go looking for a row that happens to have both `text` and
`attributedBody` populated.** The `both-paths` assertion does not need one. It
needs one real blob whose text is known; the fixture author then pairs it with a
`text`-populated row built from the same sentence, and the assertion becomes
*the real blob decodes to the sentence the person typed* — which is a stronger
claim than "two real rows happened to match", and needs one row instead of two.

Copy-pasteable capture, on a **copy**, never the live file:

```bash
cp ~/Library/Messages/chat.db* /tmp/imspike/
/usr/bin/sqlite3 "file:/tmp/imspike/chat.db?immutable=1" "
SELECT sw_vers_dummy; -- (no; run sw_vers separately and paste it in the header)
SELECT ROWID,
       hex(substr(attributedBody, 1, 16))  AS header16,
       length(attributedBody)              AS bytes,
       typeof(attributedBody)               AS kind,
       quote(text)                          AS text_column,
       balloon_bundle_id, quote(payload_data)
FROM message
WHERE attributedBody IS NOT NULL
ORDER BY ROWID DESC LIMIT 20;"
```

### 3.3 The rows to capture, and the columns

Minimum six, one per question in `01-PHASE-0-SELF-FLOW.md` §2.3 Q2:

| # | row | what it settles |
|---|---|---|
| 1 | **experiment 1** — self-message from the iPhone, placeholder body | the canonical blob, its header, whether `text` was NULL |
| 2 | experiment 1 again, **a body containing one non-ASCII character** (an emoji or `é`) | **bytes or characters** in the string length (§1.4) — the single cheapest high-value capture in the list |
| 3 | experiment 4 — image sent | whether `U+FFFC` appears in the string; `cache_has_attachments` |
| 4 | experiment 5 — voice message | `is_audio_message`, and whether a body blob exists at all for a non-text message |
| 5 | experiment 11 — effect bubble | `payload_data` + `balloon_bundle_id`, for `.notText` |
| 6 | experiment 8/9 — edit, then unsend | what the body blob becomes; whether `message_summary_info` is also involved |

For each: the ROWID, the §2.2 column list, and the header line. Plus in the
report header: `sw_vers -productVersion`, the build, and the SQLite build used.
Sanitise by construction, per §3.2.

---

## 4. Failure modes, and which ones a self-test can pin

**A self-test must fail when the thing it names did not happen.** The
distinction below is the difference between six green cases and six green cases
that mean something.

### 4.1 Assertable offline — and there are now two kinds of "offline"

This list was written when the only possible fixture was a real `attributedBody`
from IM-01. There are **two** fixture sources now, and which one an assertion
runs against is itself the claim it makes:

- the **corpus** in `Tests/Fixtures/chatdb/`, and a real blob when IM-01 lands —
  an assertion against these is a claim about **what Messages writes**;
- streams **Apple's own encoder** produces at test time (§2.3) — an assertion
  against these is a claim about **this parser's mechanics** and nothing else.

An item is asserted offline today if it is a mechanics claim. An item that is a
Messages claim stays blocked, and the blocked ones are named in
`--selftest-imessage-decode`'s `IMESSAGE_DECODE_BLOCKED:` lines and in
`02-PHASE-1-P0-SLICE.md` §2 rather than quietly dropped from this list.

- **No prefix ever decodes to a *different* string.** Take a whole stream and,
  for each `n` in `0..<count`, feed the first `n` bytes: the answer is either
  the *whole* expected sentence or a refusal — never a shortened one, never
  `""`, never a different sentence. This is the failure the section is reaching
  for: a truncated stream yielding a prefix of the text with no error, which is
  a sentence a person will act on.

  ⚠️ **An earlier version of this file said "every proper prefix of the real
  blob is refused". That was wrong, and it is recorded here rather than deleted
  because the wrong version is the one that looks obviously safe.** It is false
  for a structural reason: the message text sits *early* in the stream, so a
  prefix that already contains the whole sentence contains a body this Mac can
  read, and refusing it would be refusing real text. A test written to the old
  wording would have had to be weakened or deleted the first time it ran
  against a real blob, and a test that *has* to be weakened is a test whose
  failure would be rationalised away. `--selftest-imessage-decode` asserts the
  property above instead, under the name
  `a_truncated_stream_never_decodes_to_a_different_string`. **Do not restore the
  old wording.**
- **A declared string length that runs past the end is refused.** This is the
  classic out-of-bounds and the most likely defect in a hand-written parser.
- **A version byte outside the supported set is refused, and the reason names
  the byte it found.** An empty blob, a one-byte blob, and the corpus's
  `X'0001'` sentinel are all in this class already.
- **Every loop is bounded by the remaining byte count.** A parser that can fail
  to advance on an unknown byte will hang, and a hang inside the message read
  path is a silent stop. The bound is the assertion: if a case can run forever,
  the watchdog (`SelfTest.timeout`) catches it — but a *property* is better than
  a watchdog, and the self-test should assert the property by running every
  prefix case.
- **`.notText(bundleID:)` for a `payload_data` + `balloon_bundle_id` row**, and
  the bundle id survives to the value.
- **`.absent` when both body columns are NULL**, distinct from `.unreadable`.
- **`text` takes precedence** when a row has both columns. ✅ **Asserted since
  2026-09-26**, and the roadmap was wrong that no case has one: on the Mac IM-01
  read, **every one of the ten newest rows carried `text` *and* an
  `attributedBody`**, so this is the common shape rather than an exotic one. The
  assertion is
  `text_takes_precedence_over_a_real_decoded_stream` in
  `--selftest-imessage-decode`, and it runs against a real stream with a
  deliberately *different* sentinel in the `text` column so it cannot pass by
  agreeing with itself. It reads the bytes from the local artefact (§7), not from
  a fourteenth corpus case — see §7 for why no such case can be generated.
- **The two `both-paths` rows differ in exactly the two body columns** (and the
  three that identify the row) and are in the same chat. This one is assertable
  **today**, against the shipped corpus, with no real bytes — see
  `Tests/Fixtures/chatdb/README.md`.

### 4.2 Not assertable offline, at all

- that the gate's default version is right for **Messages** on this macOS —
  ⚠️ **this one is answered** as of 2026-09-26 for macOS 27.0 (§7): Messages
  writes `04` / `1000`, the same pair `NSArchiver` does. What is *not* answered
  is a future macOS, which is the canary's job.
- that the layout on this macOS is the layout §1 describes — ✅ **answered for a
  text balloon** (§7: nine of nine real bodies decoded whole, and every one of
  them at the offset §1.4 names for the string), and still open for a photo, a
  voice note, an effect bubble and an edit
- that a real decode produces the *whole* sentence — ✅ **answered** (§7: the
  known-text self-message round-tripped, and the byte counterfactual was run)
- anything about `message_summary_info`, effect bubbles, or the WAL
- that a *future* macOS still decodes — which is why the canary metric in
  `03-PHASE-2-P1-SLICE.md` exists, and why the failure is a capability

Bytes-vs-characters for non-ASCII used to be on this list twice: once for
Apple's encoder, which `archiver_oracle_length_counts_bytes` pins, and once for
Messages, which is now measured (§7) and pinned by
`real_body_decodes_to_the_sentence`. Neither is here any more, and the second one
is the last item on this list that a capture could have closed.

---

## 5. Recommended design for `MessagesDecoder`

### 5.1 One stored fact, two derived values

The point of `decodeState` is that a message nobody can read is *not* an empty
message. The way to make that structural rather than a convention: store one
enum, derive both, so they cannot disagree.

```swift
/// Written against macOS 27.0 / typedstream header 04 00 00 00 · see TYPEDSTREAM-NOTES.md
/// The supported-header set is DATA, not a branch: §4.1 is the test.
enum MessageBody: Equatable {
    case text(String)                                   // from `text` or from a decoded stream
    case unreadable(reason: MessageDecodeFailure)       // never ""
    case notText(bundleID: String)                      // an effect, a tapback, a retracted body
    case absent                                         // no body column at all
}

enum MessageDecodeFailure: Equatable {
    case unsupportedStreamVersion(found: UInt8, system: UInt16?)   // see the note below
    case notATypedStream(offset: Int)                            // see the note below
    case truncated(offset: Int)
    case structureUnreadable(offset: Int)
    case notAString(offset: Int)
    case tooLarge(bytes: Int)
}

struct IMessageEnvelope {
    let body: MessageBody        // the only stored fact
    let source: MessageBodySource // which path answered — four cases, see below
    var text: String? { if case .text(let t) = body { t } else { nil } }
    var decodeState: MessageDecodeState { /* derived from `body`, never stored */ }
}
```

Three properties this shape buys, each of which is a rule the roadmap already
states:

- **`text` is non-`nil` in exactly one case.** `.unreadable` cannot become `""`
  because there is no way to spell it — the enum has no empty-string
  representation, and `text` is a `switch`, not a stored field that someone can
  forget to set.
- **`text` and `decodeState` cannot drift**, because there is only one value.
- **A fifth case is a compile error at every call site.** An exhaustive
  `switch` is the enforcement, in the same spirit as `OutputToken` making "no
  backend independently decides to speak" a compile error rather than a
  convention. Every consumer must say what it does with a body it could not
  read, and the compiler asks, not the reviewer.

**Three places the built decoder departs from the sketch above, each with a
reason — the code is right and this paragraph is the record.** The reason each
one was adopted is a *fact about the world* the sketch could not have known, not
a preference.

1. **`systemVersion` in `unsupportedStreamVersion` is `UInt16?`, not `UInt16`.**
   The corpus's `X'0001'` refusal sentinel is **two** bytes, so the streamer
   version is present and the system version is not — it needs the whole 13-byte
   header before it exists. Writing `0` for bytes that are not there would put a
   fabricated reading into a log line and a canary metric, which is the exact
   failure §5.3's last bullet forbids. A missing measurement is `nil`.
2. **There is a `.notATypedStream(offset:)` case.** The five cases above have
   nowhere to put "these bytes are not this format at all", and that is a
   different fact from "this format is at a version I do not read" — it is what
   a bug report needs, because one means a corrupt column and the other means an
   unfamiliar file.
3. **`MessageBodySource` has four cases, not the two the sketch's comment
   lists.** `.textColumn` / `.attributedBody` / **`payloadData`** / `noColumn`.
   A `.textColumn` source attached to a body that came from `payload_data` would
   be a lie the three-case enum could not express, and a source that lies is
   worse than no source: every consumer downstream uses it to decide which
   column to trust.

### 5.2 The version gate as data

```swift
struct MessagesSchemaVersion: Equatable, Hashable {
    var streamerVersion: UInt8     // offset 0
    var systemVersion: UInt16      // a typedstream integer READ FROM offset 13;
                                   // 14–15 is only where its bytes land
                                   // when the head byte there is 0x81
    static let supported: Set<MessagesSchemaVersion> = [.init(streamerVersion: 0x04, systemVersion: 1000)]
}
```

`supported` is a `Set` on purpose. It is a lookup, not a branch, so
`--selftest-imessage-decode` can state the *policy* ("only these are decoded")
and a future macOS that needs a second entry is a one-line data change with a
test that says which entry. The file header names the macOS it was written
against, as `02-PHASE-1-P0-SLICE.md` requires.

**Two details of the built gate that this sketch did not have, and both are
load-bearing.** `readHeader()` checks the **streamer version before the
signature**, and the order is the point: the corpus's `X'0001'` sentinel is two
bytes, so the version byte is present and the signature is not, and a signature
check first would answer "these bytes are not a typedstream" and lose the fact
that the version is the thing that is wrong. And the streamer-version membership
test runs against the *streamer half* only, so a good version with a bad system
version is a version refusal rather than a signature refusal — which is what
makes the gate a pair rather than a byte. The name is `MessagesSchemaVersion`
rather than this section's earlier `StreamHeader`, because two other files quote
it; the value is the same and the spelling is the one that shipped.

### 5.3 Rules the parser must hold to

- **No string search, ever.** Length-driven or refuse. A prefix of a sentence is
  a sentence someone will act on.
- **Refuse, never repair.** A `length` past the end, an unknown type tag, a
  reference index outside the table, a class name this decoder does not know:
  each is `.truncated` / `.structureUnreadable`, and none of them is a reason to
  keep going and see what comes next.
- **Bound every loop by the bytes remaining.** A cursor that cannot advance must
  return, not spin.
- **Only the string is wanted, so only the string is modelled.** Do not build
  the attribute runs. `U+FFFC` is left **in** the text: it is the marker that
  says there is a photo, and stripping it makes a photo message look empty.
- **Cap the blob.** `maxBodyBytes`, and over it is `.tooLarge` — a refusal, not
  a truncation, and not a stall.
- **Parse off the main actor, bounded.** Microseconds of work, but it is on the
  read path, so it is a pure function on a `Sendable` input called from the
  reader's own context, with no lock and no channel.
- **Nothing from the blob reaches the log or a metric.** The
  `undecodable messages` canary counts *events*; the reason string carries the
  version byte and an offset, never the body, and goes through
  `UsageLog.sanitise` like everything else. §1.4's example strings must not end
  up in `usage.jsonl`.
- **The user-facing sentence is written in the caller, not in the decoder.** The
  decoder returns a reason; the layer that owns copy turns
  `.unreadable(reason: .unsupportedStreamVersion(found: 0x62, system: 1000))`
  into "Next · I received that but couldn't read it on this version of macOS",
  with no jargon, no column names and no format names in it. A version byte is
  a fact for the log and a bug report, never for a person.

### 5.4 What a reviewer should ask of the diff

- Does any code path produce a non-`nil` `text` that is not a whole decoded
  string? (One line to grep: `.unreadable` and `""` must not meet.)
- Is the version gate a `Set` membership test, or an `if version == 4`?
- Is the parser's failure an `enum` case, or an `Error` nobody constructs?
- Is the unreadable path reachable from every `switch` in the app, or does
  some consumer have a `default:` that drops it?
- Does the file header name the macOS version and the header pair it was written
  against?

---

## 2026-09-26 — MEASURED ON MESSAGES' OWN OUTPUT

The header above was measured twice on 2026-09-25 with `NSArchiver`, which proves what Apple's
*encoder* writes. On 2026-09-26 IM-01 read a real `chat.db` on this Mac (Full Disk Access granted to
Next Notes, so the app itself read it read-only) and the first 16 bytes of a real
`message.attributedBody` are:

```
04 0B 73 74 72 65 61 6D 74 79 70 65 64 81 E8 03
```

| offset | bytes | meaning |
|---|---|---|
| 0 | `04` | `streamerVersion` = 4 |
| 1 | `0B` | length of the name that follows = 11 |
| 2–12 | `streamtyped` | the name |
| 13 | `81` | an integer follows, **read from** offset 13 |
| 14–15 | `E8 03` | **little-endian** = **1000** = `systemVersion` |

So `MessagesSchemaVersion.supported = [.init(streamerVersion: 0x04, systemVersion: 1000)]` — the gate
the shipped `MessagesDecoder` already carries — is **correct on real Messages data**, not merely
consistent with what `NSArchiver` produces. Note the integer is little-endian: read big-endian,
`E8 03` is 59395 and the gate silently rejects every message.

### What this changed, and what it did not

**Changed:** the header question is closed for macOS 27.0 (26A428). §0's provenance table moves this
row from `[measured — Apple's encoder]` to `[measured — Messages, this machine]`.

**Still open, and this is the important part:**

1. **`message.text` was NOT null on any of the ten newest rows.** Every one had `text` set *and* an
   `attributedBody` — 14 to 213 characters of text beside a 184 to 3254-byte stream. This roadmap's
   central premise was that "`text` is usually NULL for iMessage", and on this machine it is the
   opposite: the stream is *always* there and `text` is usually there too. So `text` **taking
   precedence** is the rule that decides almost every real message, and the fallback path is the rare
   one. IM-05's blocked "text takes precedence" assertion is therefore the *most* valuable of the six,
   not a footnote — and the 14th fixture case the roadmap said did not exist is not exotic at all.
2. **This is ten rows from one machine at one moment.** It says the NULL-`text` case is rarer than
   believed, not that it does not happen: a message that arrived as an MMS or was carried over from
   an older install will still have `text` NULL, and that is the case the decoder exists for. Do not
   delete the fallback on the strength of one sample.
3. **No self-conversation exists on this Mac.** 50 chats, every one with someone else in it, so
   IM-01's Q1 — is a self-message `is_from_me = 1` or `0`? — is still unanswered, and the pairing
   filter IM-07 is built on is still unmeasured. This is the one experiment left.

### A self-message is TWO rows, and that is the whole of IM-01's Q1

A message sent from the phone to the phone's own conversation landed as **two** rows:

```
row 55189  fromMe=true   text=25 characters  attributedBody=202 bytes
row 55190  fromMe=false  text=25 characters  attributedBody=202 bytes
```

Same sentence, same 202-byte body, **opposite `is_from_me`**. So:

- **`is_from_me` cannot identify a self-message.** A filter written on it finds one copy and misses
  the other, and which copy it gets is not something the row decides. IM-07's pairing filter must be
  the **chat** whose only participant is you — never a row-level test. This is the answer the roadmap
  said was worth a human spike, and guessing `is_from_me = 1` would have shipped a watcher that
  answered half of every command.
- **Both copies carry the same body**, so the decoder sees the sentence twice. The GUID cache is
  what stops that becoming two replies, and its necessity is now measured rather than argued.

### The stream is an attribute graph, not a string

The real 202-byte and 1140-byte bodies are not text with a header. Inside one: `NSMutableString`,
`__kIMMessagePartAttributeName`, `__kIMDataDetectedResult`, `__kIMLinkAttributeName`,
`__kIMLinkPreviewAttributeName`, a `__kIMDataDetectedLinkAttributeName` URL, a
`com.apple.*` bundle id, and a **third-party promotional payload** carried as its own nested
object with a nested string and a date range.

Two consequences, both load-bearing:

1. **The "do not string-search for the first printable run" rule is not a style preference.** The
   first printable run in that blob is `streamtyped` at offset 2. A scan does not return a
   plausible-looking sentence — it returns the format's own name, and it would do so on every
   message forever.
2. **The length field is per-object, and the object holding the message is not the whole file.**
   So "bytes or characters" cannot be answered by comparing the file size to the sentence; it has
   to be answered by reading the string object the decoder actually uses, against a known text.
   The text here is 25 characters with three multi-byte characters in it, so the case is already
   in hand — and the decode has to run before the question can be closed.

**Not committed, deliberately:** the real body carries a live promo URL and a third party's offer,
so the blob stays a local artefact at
`~/Library/Caches/NextNotesBuild/imessage/self-flow-case.sh` and the *answer* goes in these notes.
The corpus keeps its synthetic placeholders.

---

## 2026-09-26 — THE DECODER HAS NOW READ A REAL BODY

The section above measured the **header**. This one records the **decode**: the shipped
`MessagesDecoder` was run over all nine real bodies, with `text` NULL so the answer could only come
out of the stream. **Nine of nine decoded, whole, with no refusal and no truncation.** There was no
parser bug, which is the outcome the notes above were written to make possible rather than to
avoid hoping for.

| body | bytes | declared length | characters the decoder returned | matches the diagnostic's count |
|---|---|---|---|---|
| self-message (the non-ASCII one) | 202 | `0x1b` = 27 | 25 chars / 27 UTF-8 bytes | ✅ 25 |
| 184 | 184 | 11 | 9 | ✅ 9 |
| 298 | 298 | `0x4b` = 75 | 75 | ✅ 75 |
| 1107 | 1107 | `0x81 84 00` = 132 | 132 | ✅ 132 |
| 1182 | 1182 | `0x81 be 00` = 190 | 190 | ✅ 190 |
| 1796 | 1796 | `0x81 8b 00` = 120 | 120 | ✅ 120 |
| 1950 | 1950 | `0x81 a1 00` = 161 | 158 chars (**one 4-byte emoji**) | ✅ 158 |
| 3254 | 3254 | `0x81 d6 00` = 214 | 213 chars | ✅ 213 |

The right-hand column is the important one, and it is an **independent** check rather than a
restatement: the diagnostic counted characters through SQLite's own `length(text)` and never printed
a body, so it could not have been derived from the decode. Nine for nine.

### The bytes-versus-characters question, answered both ways

**Forward:** the 202-byte self-message declares **27** for a sentence that is **25 characters** and
**27 UTF-8 bytes**. `NSArchiver`'s own encoder and **Messages** agree, and the length is a **byte**
count. A character count would be 25 and the writer did not write 25.

**Backward, as a real run rather than an argument:** rewriting that one length byte from `0x1b` to
`0x19` — the character count — makes the same decoder return **25 bytes** of the 27-byte sentence:
every character up to and including the first `c` of `café`, the accented `é` at the end gone, and
**no error of any kind**. That is precisely the failure §1.3 and §4.1 exist to rule out, produced on
demand by the shortest possible edit, and `real_body_decodes_to_the_sentence` catches it — it is
the one-character mutation in `~/Library/Caches/NextNotesBuild/imessage/IM-05b-mutation.txt`, which
also carries the literal string for anyone who needs to see it.

### Two structural claims, confirmed on real bytes

- **§1.3's "a scan would return `streamtyped`" is not a style preference.** The first printable run
  of the 202-byte body is the format's own name at offset 2, and of the 1140-byte one it is
  `streamtyped` too. A scan would have answered identically for all nine, forever.
- **§1.3's two tables are two tables, and Messages uses them.** Every real body opens
  `84 01 40` — `@`, registered as shared string 0 — and then reaches the *string* through a
  **reference** (`0x92`) to that same entry, inside a class chain whose leaf is `NSString` v1. A
  reader that numbered only one table, or that expected the object tag again instead of a
  reference, desynchronises here and nowhere earlier.
- **`NSAttributedString` v0 / `NSObject` v0 / `NSString` v1 is not what `NSArchiver` wrote for the
  same shape** (`NSMutableString` v1 / `NSString` v1). The decoder matched the **class chain**
  rather than the leaf, and the real bodies did not break that. That is the argument for matching
  the chain, and it is now an argument from measurement rather than from caution.

### The prefix property, on real bytes, for the first time

§4.1 warns that "every proper prefix of the real blob is refused" is **false and must not be
restored**. Confirmed, quantitatively: across all nine bodies — **10,175** prefixes, every one of
them — **no prefix decoded to a different string, none decoded to `""`, and none came back as a
non-body.** Prefixes split into two populations (refused, or the whole sentence) and the split is
structural: the text sits early enough that 101 of the 202 prefixes of the self-message already hold
all of it. The `0x1b` mutation above is the counterexample that matters: a prefix *can* hold a
different string, and the only thing standing between that and a person acting on a truncated
sentence is refusing what the length does not cover.

### Why there is still no permanent fixture case, and what replaced it

`make-chatdb-fixture.sh` **cannot** emit these bodies, and the reason is worth recording because it
is the guard working rather than the guard failing:

```
CHATDB_FIXTURE_FAILED: refusing to emit a fixture containing a bare 11-digit number: 00868699020 …
```

Its sanitisation guard scans the SQL it is about to write, and a multi-kilobyte hex string is full
of 11-digit runs. So the "add a sanitised stand-in with the same structure" option is not
available: any faithful stand-in **is** the real hex, and no edit that preserves the structure
avoids the guard. (A hand-synthesised body would avoid it, and the roadmap forbids synthesising a
typedstream in the first place — §2.3's oracle already exists for the mechanics.)

So the real-body assertions read the bytes from **outside the repository**, named by
`IMESSAGE_DECODE_REAL_BLOB` in `MessagesDecoderSelfTest`, and the honesty rule is the one that
matters:

| run | `IMESSAGE_DECODE_OK` | blocked |
|---|---|---|
| no artefact (CI, any other machine) | **22 cases** | 6 named lines |
| with IM-01's artefact | **26 cases** | 2 named lines |

A blocked line that silently became green would be the one failure this design exists to prevent,
so the mechanism is two-sided: **absent** → blocked and uncounted; **present but unusable** (a
missing file, an odd number of hex characters, an empty `text=`) → a **failed** case, not a block.
Both were run; the transcripts are `IM-05b-no-artefact.txt`, `IM-05b-green.txt` and
`IM-05b-mutation.txt` beside this file.

**The four cases** are `real_body_decodes_to_the_sentence` (which refuses to pass on an ASCII
sentence, because an ASCII sentence cannot tell bytes from characters and would look like an
answer), `real_body_and_the_text_column_agree` (`both-paths`, positive half),
`text_takes_precedence_over_a_real_decoded_stream` (with a deliberately different sentinel in the
`text` column), and `no_prefix_of_a_real_body_decodes_to_a_different_string`.

**Still blocked, and honestly so:** `effect-bubble-classification` (no effect bubble was captured
— all ten rows had `payload_data` absent) and `voice-note-as-not-text` (still needs a projected
`is_audio_message` column, which is IM-04's shape rather than this task's).

---

## 2026-09-26 — IM-17c: a walk is not a search, and the count is bytes

The section above measured a real body end to end. This one records what walking it *past* the
sentence found, and the one change to `MessagesDecoder` that IM-17c makes.

### The 202-byte body in full, as a graph

The whole blob, annotated. Offsets are into the 202 bytes; `+` is the unshared-string tag, `*` the
shared C-string tag, `@` an object. **The first six bytes after each offset are printed with it**, so
every line can be checked against `real-body.txt`'s `blob=` without a second tool:

```
0000  04 0b 73 74 72 65 61   "streamtyped" 81 e8 03  — the header, measured above
0010  84 01 40 84 84 84     new shared string 0 = "@"
0013  84 84 84 12 4e 53     the root's class chain: "NSAttributedString", v0
0029  00 84 84 08 4e 53     its superclass "NSObject", v0
0035  00 85 92 84 84 84     chain closed by nil; 0x36 is a field — a *reference* to shared 0,
                             so an object, and 0x84 84 08 is a nested "NSString", v1, its chain
                             closed by the reference 0x94
0046  84 01 2b 1b 48 c3     new shared string 4 = "+", then 0x1b = 27 — THE SENDER'S SENTENCE
0049  1b 48 c3 a9 6c 6c     27 bytes, read by their declared length. Two of them are one é.
0065  86 84 02 69 49 01     END of the nested string.  **THE WALK STOPS HERE: 101 of 202.**
0066  84 02 69 49 01 19     a two-character type tag, "iI", this decoder does not name
006a  01 19 92 84 84 84     two more bytes this note does not model either
006c  92 84 84 84 0c 4e     field: a reference to "@"; 0x6d opens the attribute graph
0070  0c 4e 53 44 69 63     "NSDictionary" (12 bytes, 0x71..0x7c), v0, chain closed at 0x7e
007f  84 01 69 01 92 84     a count of one entry, then a reference to "@"
0083  92 84 96 96 1d 5f     an object with an empty class chain; 0x87 = 29, a key of 29 bytes
0088  5f 5f 6b 49 4d 4d     __kIMMessagePartAttributeName, 0x88..0xa4
00a5  86 92 84 84 84 08     END; 0xa6 the value -- a field, then a chain: "NSNumber" v0 …
00bc  75 65 00 94 84 01     … "NSValue" v0 (0xb7..0xbd); 0xbf closes the chain, 0xc2 = "*"
00c9  86 86 86              three end-of-object markers, and the body ends at 0xc9
```

**Four things in there, and only one of them is the sender's words.** The walk reads 101 of the 202
bytes and stops at offset 101 (`0x65`, the end-of-object marker that closes the nested string). The
**101 bytes behind it** hold the `NSDictionary`, its count, one 29-byte key, and the value object —
and the key appears **twice**, once as the dictionary's key and once as a `char *` inside the value.
So even the *plain* body — the plain end of the range, with no link preview, no detected entity, no
bundle id and no third party in it — carries a named attribute, and the decoder passes over both
copies without naming either. `IM-17c`'s count is **101** on this body, and the count is **bytes**,
for the reason in the next section.

### Why the count is bytes and not attribute names, in one measured fact

`TYPEDSTREAM-NOTES.md` §1.4 says a reader that maps one byte to one type desynchronises on
`{CGSize=dd}`, and §5.3 says only the string is modelled. **Those two rules together mean the tail
cannot be walked.** The very first frame after the sentence's end-of-object marker is
`84 02 69 49` — a two-character type tag, `iI`, that this decoder does not name. Reading past it
means guessing a width, and a guessed width on a real attribute graph is how a reader desynchronises
and returns a plausible wrong answer. So:

- an accurate count of **named attributes** needs a grammar-aware skipper this decoder deliberately
  does not have;
- a count of **names** is the denylist bet the design refuses — one name is a bet on this macOS's
  attribute list;
- a count of **unread bytes** is exact, needs no guess, is about the *format* rather than about
  anybody's message, and moves when macOS attaches more graph.

`MessageBody.text` therefore carries `discardedBytes`, and `IM-17c`'s design called the field
`discardedAttributeCount`. The name is wrong and the number is the honest one, which is the
trade this file makes: **a number whose name says what it is beats a number whose name says what
it was meant to be.** `discardedBytes == 0` on a body that carries a nested object would mean the
walk had read the whole body, which is the one thing the guarantee says it never does.

### The walk is anchored, and that is the whole of the fix

The walk this replaced **searched**: it descended into nested objects until it found a string it
could justify, and carried on past a nested object that held none. Against the graph above that is
harmless — the sentence comes first. Against the 298-byte and ~1140-byte bodies from the same
capture it is not, because they carry a detected-entity list, a link preview, a `com.apple.*`
bundle id and a `__kMSHSMessage` **whose first field is its own nested string**. A search over that
graph can land on the offer, and a search that lands on the offer returns it as the message.

The rule now is one line and it is positive:

> The answer is the characters of the string this body **is** — the first string-typed field of an
> object whose class chain says it is a text balloon or a string — and nothing else in the graph
> is read as text at all.

One object, one field, one string. A root that is not a text balloon is `notAString`. A nested
object that is not a string is `notAString` — **not a place to keep digging**. The two sets of
names this needs (`stringClasses`, `textBalloons`) are *recognitions*, like
`MessagesSchemaVersion.supported`: they say what a message body **is**, and a reader that stopped
recognising one would refuse the body rather than misread it.

**What this changed about the design, said out loud.** `IM-17-DESIGN.md` §5 (IM-17c) says the walk
does not change. It had to: the design's own sentence is *"the decoder walks the streamer's object
graph **to the top-level `NSMutableString`**, returns that one string, and returns a refusal for
everything else"*, and the shipped walk was a search rather than a walk-to. Everything else the
design asked for is as written — one `Int`, no bag, no dictionary, no array of names, and the
count on the value rather than beside it. The field's *name* is the one thing not as written, for
the reason above.
