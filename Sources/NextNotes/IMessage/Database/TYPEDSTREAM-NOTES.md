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
| **[published]** | From a public reverse-engineering write-up. Not Apple documentation, not verified against a blob on this Mac, and not verified on macOS 27. |
| **[inferred]** | My reading of the above. Could be wrong. |
| **[UNMEASURED]** | Nobody knows, including this file. This is what IM-01 is for. |

**What was checked here, and what it rules out.** [measured] `~/Library/Messages/`
on this machine answers `ls: Operation not permitted` — no Full Disk Access — so
**there are no real bytes available to this note at all.** Every structural
claim below is therefore `[published]` or `[inferred]`, and not one of them has
been confirmed against a blob written by macOS 27. That is not a reason to
proceed; it is the reason §3 exists and the reason the decoder must be built to
refuse rather than to guess.

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
version as a little-endian `u16` at offsets 14–15. Both are in the header, both
must be matched, and neither is a macOS version — `1000` has been constant
regardless of which macOS wrote it.

[UNMEASURED] **Whether that pair is still `04` / `1000` on macOS 27.0.** The
published work is from 2025 and the last macOS it names is not stated. This is
the single most important number in this file and it is a number nobody has
measured. See §3.

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
| `0x87` | an 8-byte integer follows |
| `0x83` | a float/double follows; width comes from the type tag |

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
                           variable-width encoding*: one byte if it fits,
                           else 0x81 + u16, 0x82 + u32, 0x87 + u64
```

**This is the whole answer to "why not string-search for the first printable
run", and the roadmap's own prohibition (§2 of `02-PHASE-1-P0-SLICE.md`) is
right for a stronger reason than tidiness.** A scan produces a *prefix* of the
text, silently, with no error — and a truncated sentence is a sentence a person
will act on. A length-driven parse either produces the whole string or refuses.

[UNMEASURED] **Whether that length is in bytes or in characters** for non-ASCII.
Every published sample is ASCII, where the two are the same. A message with an
emoji or a CJK character is the case that tells them apart, and a decoder that
guesses wrong will truncate exactly the messages a person most wants read.
IM-01 must capture one.

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

- whether `04` / system `1000` still holds on macOS 27.0 (**the** blocking one)
- the class-version bytes Messages actually writes today (`NSString` v1, etc.)
- bytes vs characters for the string length
- `U+FFFC` behaviour on this OS
- the `payload_data` + `balloon_bundle_id` shape for an effect bubble
  (IM-01 experiment 11) — nothing in this note claims to know it
- whether an edited message's body is the edited text or both texts
- `message_summary_info`'s container, beyond the fact that its version differs

**None of these is answerable without a blob.** A parser written from this file
alone will be written from [published] inference, and must therefore be built to
refuse rather than to succeed. That is not a caveat on the design; it *is* the
design.

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
  this in `try`/`catch`, and there is no way to make it return `.undecodable`.

So the choice is not "safer system API vs. portable parser" in the abstract. It
is:

| | hand-written parser | `NSUnarchiver` |
|---|---|---|
| bad input | returns `.undecodable(reason:)` | raises; **terminates the app** |
| unfamiliar version | mismatch, returns `.undecodable` | raises; terminates |
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
   little-endian `u16` at offsets 14–15. That pair *is* the version gate, and
   §5 builds the gate out of exactly these two numbers. Whether it is still
   `04` / `1000` on macOS 27.0 is [UNMEASURED] and blocks the gate's default.
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

### 4.1 Assertable offline, once one real blob exists

- **Every proper prefix of the real blob is refused.** Take the real blob, and
  for each `n` in `0..<count` feed the first `n` bytes: every one must be
  `.undecodable`, and `text` must be `nil` — never `""`, never `.decoded`. This
  is truncation coverage with no fuzzer, and it is the case that catches a
  cursor which reads past the end or desynchronises into returning a prefix.
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
- **`.absent` when both body columns are NULL**, distinct from `.undecodable`.
- **`text` takes precedence** when a row has both columns. ⚠️ **No fixture case
  currently has a row with both columns set** — `both-paths` deliberately has one
  column each, because that is the one-variable design. This precedence is
  therefore **unpinned** and wants a 14th case. Flagged, not fixed here: it is
  outside what this task was asked to add.
- **The two `both-paths` rows differ in exactly the two body columns** (and the
  three that identify the row) and are in the same chat. This one is assertable
  **today**, against the shipped corpus, with no real bytes — see
  `Tests/Fixtures/chatdb/README.md`.

### 4.2 Not assertable offline, at all

- that the gate's default version is right for this macOS
- that the layout on this macOS is the layout §1 describes
- bytes-vs-characters for non-ASCII
- that a real decode produces the *whole* sentence (only IM-01's known-text row
  can assert this)
- anything about `message_summary_info`, effect bubbles, or the WAL
- that a *future* macOS still decodes — which is why the canary metric in
  `03-PHASE-2-P1-SLICE.md` exists, and why the failure is a capability

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
    case unsupportedStreamVersion(found: UInt8, system: UInt16)
    case truncated(offset: Int)
    case structureUnreadable(offset: Int)
    case notAString(offset: Int)
    case tooLarge(bytes: Int)
}

struct IMessageEnvelope {
    let body: MessageBody        // the only stored fact
    let source: MessageBodySource // .textColumn | .attributedBody — which path answered
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

### 5.2 The version gate as data

```swift
struct StreamHeader: Equatable, Hashable {
    var streamerVersion: UInt8     // offset 0
    var systemVersion: UInt16      // offsets 14–15, little endian
    static let expected: Set<StreamHeader> = [.init(streamerVersion: 0x04, systemVersion: 1000)]
}
```

`expected` is a `Set` on purpose. It is a lookup, not a branch, so
`--selftest-imessage-decode` can state the *policy* ("only these are decoded")
and a future macOS that needs a second entry is a one-line data change with a
test that says which entry. The file header names the macOS it was written
against, as `02-PHASE-1-P0-SLICE.md` requires.

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
- Is the undecodable path reachable from every `switch` in the app, or does
  some consumer have a `default:` that drops it?
- Does the file header name the macOS version and the header pair it was written
  against?
