# chatdb — synthetic Apple Messages `chat.db` fixtures

> **Every `attributedBody` in this directory is synthetic, and that is now a decision
> rather than a wait.** IM-01's spike produced real bodies on 2026-09-26 and the shipped
> decoder reads all nine of them, but they cannot go here: the biggest carries a live
> promotional URL and a third party's offer, and `make-chatdb-fixture.sh` refuses them
> anyway — its sanitisation guard scans the SQL it is about to write, and a
> multi-kilobyte hex string is full of 11-digit runs, so it dies with *"refusing to emit a
> fixture containing a bare 11-digit number"*. **A sanitised stand-in is not available
> either**, because any body with the same structure *is* this hex. So
> `--selftest-imessage-decode` reads the real bytes from outside the repository, named by
> `IMESSAGE_DECODE_REAL_BLOB`, and prints its real-body cases as
> `IMESSAGE_DECODE_BLOCKED:` — uncounted — when that variable is not set. See
> [`Sources/NextNotes/IMessage/Database/TYPEDSTREAM-NOTES.md`](../../../Sources/NextNotes/IMessage/Database/TYPEDSTREAM-NOTES.md)
> §7 for the measurement and for the transcripts.

Schema-complete, sanitised, deterministic `chat.db` files for **IM-04** (read-only
access and capability probes), **IM-05** (the `attributedBody` decoder) and
**IM-06** (the WAL watcher). This directory is the long pole for all three: it is
the only part of that work that can be written and verified without compiling
Swift, and the only one that needs no Full Disk Access and no iPhone.

## No case contains real Messages data

**Nothing here was read out of anyone's `~/Library/Messages/`.** There is no real
phone number, no real name, no real address and no real message text in any file
here, and `make-chatdb-fixture.sh` refuses to emit a fixture that contains one —
it scans every statement it is about to write and fails on any `+digits` run
that is not a `+1555000NNNN` placeholder and on any email-shaped string. The
whole corpus is placeholders: `+15550000000` is the user, `+15550000001…3` are
other people, `REDACTED-PERSON-*` / `REDACTED-SELF` / `REDACTED-CHAT` are
names, and message bodies are `FIXTURE-BODY-*` strings rather than sentences so
a fixture that leaks into a transcript is recognisable as a fixture.

## The `attributedBody` bodies are placeholders, not typedstreams

**The `X'0001'` blob is not a typedstream and must never be treated as one.** It
is two bytes whose leading byte is a version header the decoder will not
recognise, which is exactly what IM-05's `.undecodable` case needs and nothing
more. Synthesising a real typedstream was not attempted: the format is Apple's,
undocumented, and versioned per macOS release, and a hand-rolled one would
assert that this decoder works against an encoding that does not exist.

`both-paths` carries the same placeholder, and that is deliberate rather than a
shortcut. It is the case for IM-05's second assertion — *the same row, once with
`text` populated and once with `text` NULL, decodes identically* — and it holds
**the same sentence twice in one chat**, once in `text` with `attributedBody`
NULL and once with `text` NULL and `attributedBody` set. Because no placeholder
decodes to that sentence, the identity assertion is **structurally impossible to
pass today**. That is the useful property: the only ways to make it green are to
invent a typedstream, or to widen the equality until a refusal equals a string.
So it is the fixture that catches the two real failures in advance — a decoder
that returns `""` for a body it could not read, and a test that compares two
`nil`s and calls it agreement.

What the case *does* prove today, without a real byte anywhere: the two rows
exist, they are joined to the same `chat`, and **every column except `guid`,
`ROWID`, `date`, `text` and `attributedBody` is equal** — the same handle, the
same direction, the same service. One variable, two rows, so a test comparing
them is comparing the two decode paths. The positive half ran against a real
stream on 2026-09-26 (`real_body_and_the_text_column_agree`) and agreed; it runs
from the local artefact rather than from here, and this row's placeholder stays
because swapping it in would be a sanitisation incident rather than a fixture.

The real bytes arrived with **IM-01** — `Tests/Reports/imessage-self-flow.md`,
question Q2, experiments 1, 4, 5 and 11 — and they **replace** these placeholders
in every case except the two that would carry a third party's words. The
roadmap calls the fixtures provisional for exactly that reason
(`00-README.md` §8.1: *"IM-05 built now is a decoder written against synthetic
typedstream, because IM-01's real bytes do not exist yet. The first thing IM-01
does with them is replace the synthetic fixtures."*). So the decoder could be
written, its refusal path pinned, and its degradation pinned, and only the
success path waited — and on 2026-09-26 the success path was measured against
real bytes from outside this directory rather than inside it.

## Regenerating

```bash
Tests/Fixtures/chatdb/make-chatdb-fixture.sh --list          # every case and its purpose
Tests/Fixtures/chatdb/make-chatdb-fixture.sh basic-text      # -> basic-text.sqlite
Tests/Fixtures/chatdb/make-chatdb-fixture.sh basic-text --degraded
Tests/Fixtures/chatdb/make-chatdb-fixture.sh voice-note-unlabelled --no-audio
Tests/Fixtures/chatdb/make-chatdb-fixture.sh --all           # every case
Tests/Fixtures/chatdb/make-chatdb-fixture.sh basic-text --sql   # print the SQL, write nothing
```

`SQLITE=`, `SCHEMA=` and `CASES=` override the three inputs. `CASES=` exists
because a sanitisation guard that is only reachable by hand-editing the corpus
is a guard nothing checks: pointing it at a planted corpus is how the guard is
proven to fire, which is what a self-test should do.

**Generated `.sqlite` files are not committed.** This directory holds four text
files — this README, the script, `schema.sql` and `cases.sh` — and a self-test
that needs a database builds it into its own temporary directory at run time,
which is also what IM-04's task text specifies. A committed binary in a tracked
directory cannot be reviewed in a diff, and a stale one that disagrees with
`cases.sh` would fail a test for the wrong reason. There is deliberately no
`.gitignore` entry: nothing generates into the repo unless someone asks for it
with no `--outdir`.

Each case prints one line — table count, per-table row count, and which optional
columns the built file actually has:

```
CHATDB_FIXTURE basic-text -> …/basic-text.sqlite | tables 7 | rows 7 [message 2, chat 1, handle 1, …] | optional columns present:attributedBody payload_data balloon_bundle_id …
```

`--degraded` prints the same line with `absent:attributedBody payload_data`, and
`--no-audio` with `absent:is_audio_message`.

## The cases

| case | what it exercises | roadmap task · self-test assertion | data |
|---|---|---|---|
| `basic-text` | one DM: row 1 `text` populated, row 2 `text` NULL with no `attributedBody` at all | **IM-04** · the four query methods return the expected rows; **IM-05** · a row with no `attributedBody` returns `nil` text with `decodeState == .absent`, not an error | synthetic |
| `self-message` | the self-chat (`chat_identifier` = the user's own placeholder), two rows, `is_from_me` 1 and 0 | **IM-04** · both directions decode as *rows*; **IM-07** · whichever filter IM-01's Q1 answer chooses, a filter that only works for one of the two fails here | synthetic |
| `direct-message` | a DM chat joined to **two** handles, one message each way | **IM-04** · the join methods; **IM-09** · walking `chat_handle_join` → `handle.uncanonicalized_id` to a send target | synthetic |
| `group-message` | `chat.guid` shaped `iMessage;+;<opaque>`, three handles joined | **IM-09** · the guid says nothing addressable, so the only route to a target is the join; three handles so "returns the first" is distinguishable from "returns all" | synthetic |
| `sms` | `service`/`service_name` = `SMS`, `text` populated, `attributedBody` genuinely NULL | **IM-05** · the developer's-own-test row — a decoder that reads only `text` passes here and fails everywhere else | synthetic |
| `voice-note` | an `attachment` with the CAF voice UTI, joined via `message_attachment_join`; `is_audio_message=1`, `cache_has_attachments=1` | **IM-05** · a voice note is `.notText`, never text and never `.unreadable`, and the **column** is what classifies this row — its `attributedBody` is the `X'0001'` sentinel, so there is no class chain to read at all. IM-15 · a voice note is a file, not a duplex turn | synthetic |
| `voice-note-unlabelled` | **the same voice note**, same chat, same attachment, same unreadable body — and the one line that would name it is not written, so `is_audio_message` takes its default `0` | **IM-05** · the honest degradation, and the reason the classification is the column's and not the attachment's: `cache_has_attachments` and the settled join row are identical to `voice-note`, so a decoder that classified on those would classify this row too | synthetic |
| `reply` | two rows, the second's `thread_originator_guid` (and `_part`) pointing at the first | **IM-05** · IM-01 experiment 6; grouping is by the originator pair | synthetic |
| `reaction` | a tapback row: `type=2000`, `associated_message_guid` at its target, `balloon_bundle_id` + `payload_data` | **IM-05** · a `payload_data` + `balloon_bundle_id` row returns `.notText(bundleID:)` | synthetic |
| `edit` | an edited row: `date_edited` non-zero, `associated_message_guid` at the row it replaced | **IM-05** · IM-01 experiment 8; an edit must not decode as if it never happened | synthetic |
| `unsend` | a retracted row: `is_retracted=1`, `text` NULL, `attributedBody` present | **IM-05**/IM-08 · IM-01 experiment 9; both states it could decode into — empty body and refusal — are reachable from the row | synthetic |
| `delayed-attachment-join` | one row with `cache_has_attachments=1`, an `attachment` row present, and **zero** `message_attachment_join` rows | **IM-06** · the settling race: the row gains its join row on the third refetch, and a *different* never-settling message must not block it | synthetic |
| `empty-attributed-body` | `text` NULL, `attributedBody` = the `X'0001'` non-typedstream sentinel | **IM-05** · returns `.undecodable`, **and the value is proven not to be `""`** — the refusal is the feature | **awaiting IM-01** |
| `both-paths` | one sentence twice in the same chat: row 1 `text` set with `attributedBody` NULL, row 2 `text` NULL with `attributedBody` set; every other column equal, so the only variable is the column the body came from | **IM-05** · the *same row with `text` populated and with `attributedBody` populated decodes identically* — the assertion that proves the typedstream path is **right** rather than merely non-crashing. **Buildable now only in its negative half:** the row shape, the shared chat, the column-level equality and the refusal are assertable; the decode-identically half cannot pass against a placeholder and is `blocked` on IM-01 rather than weakened | **awaiting IM-01** |

`both-paths` is the case the roadmap's own IM-05 text names as a gap
(`02-PHASE-1-P0-SLICE.md` §2: *"It needs a 13th case, `both-paths`, holding the
same sentence twice … and its `attributedBody` must be a real stream, which only
IM-01 can supply."*). It is here now, with the real stream still the one part it
cannot have.

`--degraded` works for the seven cases that do not write the two removed columns
(`basic-text`, `self-message`, `direct-message`, `group-message`, `sms`,
`reply`, `edit`) and is **refused**, with a one-line reason, for the six that do
(`voice-note`, `reaction`, `unsend`, `delayed-attachment-join`,
`empty-attributed-body`, `both-paths`). A half-built degraded database would be a
fixture that looks like a capability probe and asserts nothing — and for
`both-paths` a degraded build could not express the case at all, since the whole
case is one row per body column.

**`--no-audio` removes exactly one column, and it is not `--degraded`.** It drops
`is_audio_message` and nothing else, and it exists for a reason the two body
columns do not have a reason for. Those two ask "can this Mac read the body of a
message"; this one asks "can this Mac tell a voice note from a body it failed to
read", and on that row the answer changes what the row **is** — `.notText` with
the column, `.unreadable` without it. A test that used a row holding a NULL where
the column *should* be would prove a reader's nil-handling and nothing about the
probe, so `--no-audio` builds `voice-note-unlabelled` into a database whose
`message` table really has no such column, and
`MessagesQueries` projects `NULL AS isAudioMessage` for it. The two modes are
independent: a `--degraded` build keeps the audio column (a degraded fixture is
this database with two columns missing, not a smaller database) and a
`--no-audio` build keeps both body columns.

`--no-audio` is **refused for `voice-note`**, with a one-line reason, because that case is the
one that writes the column — so the mode cannot quietly build a database whose only message is a
voice note that nobody can see. Every other case builds under it, and `voice-note-unlabelled` is
the one it exists for.

Both modes are driven by a marker in `schema.sql` rather than by a list in the
script, so the full schema and the two reduced schemas cannot drift apart, and
`--optional:` is not a substring of `--optional-audio:` — the two filters are
separate. The summary line reports the audio column like any other, so a
`--no-audio` build says `absent:is_audio_message` on its face.

## Determinism

Two runs of the same case produce a **byte-identical** file. Every ROWID is
pinned, every `date` is derived from a fixed base
(`1700000000000000000` + ROWID × 60 s, Apple epoch nanoseconds), there is no
`random()` and no `date('now')`, and the whole database is written in a single
transaction so the file change counter is fixed too. This matters because a
fixture that differs run to run cannot be committed, diffed, or compared between
two machines, and a self-test that seeds from one cannot be reasoned about from
the other.

**Verified, not asserted.** All twelve cases plus four degraded variants were
built twice and compared by `shasum -a 256`: 16/16 identical. The transcript is
at `~/Library/Caches/NextNotesBuild/imessage/fixture-verify.txt`, outside the
repository. It also covers the table set per case, the full `PRAGMA table_info`
listing, the degraded-mode check, the zero-join-row check, the sanitisation scan
over every live value *and* a raw `strings(1)` byte scan of every file, and the
guard's refusal of four planted non-placeholder values.

`both-paths` was added after that run and verified on its own, in a second
transcript at `~/Library/Caches/NextNotesBuild/imessage/both-paths-verify.txt`:
built twice with matching digests, the two rows in one `chat`, equal in every
column except the five that identify the row or carry the body, the
`text`/`attributedBody` split confirmed by `typeof()` rather than by eye, a
`strings(1)` scan of the file, and the `--degraded` refusal. The other sixteen
builds were not re-run, so the count above still describes the twelve-case corpus
and the thirteenth is covered separately.

`voice-note-unlabelled` and the `--no-audio` mode joined on 2026-09-26 (IM-05d),
and were verified the same way rather than asserted: both new builds twice with
matching digests, `voice-note` twice likewise, and — the half that matters and
that a `strings(1)` scan cannot give — the **column's real absence**, read back
with

```bash
/usr/bin/sqlite3 voice-note-unlabelled-no-audio.sqlite \
  "SELECT count(*) FROM pragma_table_info('message') WHERE name='is_audio_message'"
```

which answers `0`, while a query naming it answers `no such column`. That is the
difference between a database that lacks the column and one that has it holding
a NULL, and the whole reason this mode exists. The digests are not in the
transcripts: they change whenever a case does, and the check that matters is the
one above, run twice.

One thing that verification caught, recorded because it is the kind of bug a
fixture corpus hides: **a default of the bare word `NULL` becomes the
four-character text `'NULL'`, not SQL NULL.** An earlier draft of the row writer
returned `NULL` as a default and let the quoting pass make it a string, so every
defaulted column held the text "NULL" — and `sms`, whose whole point is a
genuinely absent `attributedBody`, would have satisfied `attributedBody IS NULL`
with a *present* four-character string. Defaults that mean "no value" are
`sql:NULL`, and the transcript asserts the difference with `typeof()` over the
whole corpus.

## What is in `schema.sql` and what is not

The schema is the roadmap's `01-PHASE-0-SELF-FLOW.md` §2.2 column list — every
one of them, including the four that list flags as often-missed: `payload_data`,
`balloon_bundle_id`, `is_sent`, and `handle.uncanonicalized_id` — plus the small
number of extra columns `MessagesCapabilities` needs to have something to probe.
No FTS tables, no indices beyond the implicit `UNIQUE` ones, no triggers.

Three columns are **modelled rather than observed**, and are the honest weak
points of this corpus:

| column | why it is here | status |
|---|---|---|
| `is_retracted` | IM-05's `hasRetractionMetadata` probe needs a column to probe, and IM-01's experiment 9 will say which one that really is | **synthetic.** IM-01 replaces it |
| `date_edited` | the same for `hasEditMetadata` | believed real, **unconfirmed** |
| `type` = 2000, and `balloon_bundle_id` = `com.apple.messages.Emoji.TapbackEffect` | a reaction and a non-text balloon both need *some* recognisable value | values are **unverified constants**; the columns are real |

Two columns §2.2 does not name are modelled because §2.1's experiments imply
them: `is_audio_message` (experiment 5, a voice note) and
`associated_message_type` (a reaction's target type). `date_edited` and
`is_retracted` are not in §2.2 at all — the roadmap names them as
*capabilities* to probe without saying which columns carry them, so they are
marked as such above. `is_audio_message` joined the third removal mode on
2026-09-26 (IM-05d) as `MessagesCapability.audioMessage`, because unlike the
other nine a missing `is_audio_message` changes a row's classification rather
than only what a field can say; the reason is in
`MessagesCapabilities.hasAudioMessage`'s comment.

The join tables are modelled with their own `ROWID` rather than as composite-key
rowid aliases, which is what real `chat.db` does. That is deliberate:
`delayed-attachment-join`'s whole assertion is
`SELECT count(*) FROM message_attachment_join` equalling zero, and under a
composite key that count would be an assertion about a constraint instead of
about a settling race.
