# Phase 1 — the P0 slice: text in, text out, loop-proofed, routed

Tasks `IM-04`…`IM-10`. Text receive · self-channel detection · loop prevention · text send ·
Interaction Agent routing.

**This phase touches no existing file** outside `Sources/NextNotes/IMessage/` plus the three
registry files, which is why it can run alongside AGENT-OVERHAUL and DICTATION-MEETINGS-LIMITS. That
is a scheduling property worth protecting: if a task here turns out to need
`Agent/RealtimeAgent.swift` or `Agent/ActionRuntime.swift`, it belongs in Phase 2 and the task text
says so.

**Do not start any of it until the `STATUS.md` gate row is closed.**

---

## 1. IM-04 — Read-only `chat.db`

**Finding(s):** the database is TCC-protected and undocumented  **Effort:** 1 day
**Depends on: none** (split 2026-09-25 — see §1a)  **Unblocks:** IM-05, IM-04a

**Goal:** a queryable, **provably** read-only view of a `chat.db`, built against fixtures.

**Files you will change**
- `Sources/NextNotes/IMessage/Database/MessagesDatabase.swift` (new, `actor`)
- `Sources/NextNotes/IMessage/Database/MessagesSchema.swift` (new — capability probes)
- `Sources/NextNotes/IMessage/Database/MessagesQueries.swift` (new — the only raw column names)
- `Sources/NextNotes/IMessage/Database/MessagesDatabaseSelfTest.swift` (new — `--selftest-imessage-db`)

**Nothing outside `Sources/NextNotes/IMessage/Database/` in this task.** The health probe, the
`Permissions` row and the Settings section were moved to **IM-04a**; this task used to carry them and
its dependency on IM-03 (a human grant task) with them, which put the two highest-risk tasks in this
roadmap behind someone having to be at a Mac. They no longer do.

**A fixture corpus already exists** — `Tests/Fixtures/chatdb/` (built 2026-09-25; **13** sanitised
cases — the 13th, `both-paths`, was added on 2026-09-25 and is what IM-05 waits on — a `--degraded`
mode with `attributedBody` and `payload_data` genuinely absent, 17/17 byte-identical across runs,
verified with `/usr/bin/sqlite3`). **Use it. Do not write a second
generator, and do not synthesise a typedstream** — no case has one, by design.

**Read for context (do not change):** `Transcription/WisprReader.swift:72` — the read-only
external-database pattern (`SQLITE_OPEN_READONLY | SQLITE_OPEN_URI`), and the only precedent in the
app for a database Next Notes does not own. `Knowledge/KnowledgeStore.swift` — the *opposite*
pattern, for a database it does own; the difference is the flags and the absence of migrations.

**Current behaviour:** nothing. There is no Messages code.

**Target behaviour**
1. `sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)`, then
   `PRAGMA query_only = ON` **before any other statement**. A bridge that only *intends* to be
   read-only is one refactor away from writing to a database iCloud syncs.
2. The path is built from the home directory, never hardcoded, and resolved with **`realpath(3)`** —
   the file is replaced on some macOS versions. `URL.resolvingSymlinksInPath()` is wrong here for
   the reason AGENTS.md records twice: it strips `/private` while `FileManager.enumerator` reports
   it, so a prefix test between the two matches nothing and every lookup silently returns empty.
   `FileIndexStore.canonical` is the pattern.
3. **Capability probes at open**, via `PRAGMA table_info` and `sqlite_master`, producing
   ```swift
   struct MessagesCapabilities {
       var hasThreadOriginatorGUID: Bool
       var hasAssociatedMessageGUID: Bool
       var hasEditMetadata: Bool
       var hasRetractionMetadata: Bool
       var hasDeliveryState: Bool
       var hasAttributedBody: Bool
       var hasPayloadData: Bool
       var hasBalloonBundleID: Bool
       var hasIsSent: Bool
   }
   ```
   Every query in `MessagesQueries` is written against the capabilities value, so a column's
   disappearance is a degradation and not a crash. The last four are the ones that decide whether
   text can be decoded at all.
4. The actor's API: `latestRowID()`, `messages(after:chatGUID:)`, `message(guid:)`,
   `chat(guid:)`, `chats(limit:)`.
5. The database path is injectable: a `root:` URL on the actor, so a test can point it at a fixture
   and production at `~/Library/Messages/chat.db`. **This is what makes the task runnable without a
   grant**, and it is why `--selftest-imessage-db` has no TCC requirement.

**Red-first self-test:** `--selftest-imessage-db`, INTEGRATION,
`IMESSAGE_DB_OK: <n> cases` / `IMESSAGE_DB_FAILED: <reason>`. Cases:
- **`PRAGMA query_only` reads back `1` from a second connection.** This is the load-bearing case:
  it fails the moment someone drops the pragma.
- the **`Tests/Fixtures/chatdb/`** corpus, generated into the test's temp directory by
  `make-chatdb-fixture.sh` (never committed as a binary blob). `basic-text` and `direct-message`
  cover the four query methods; `self-message` gives one `is_from_me = 1` and one `= 0` row, which
  decode as *rows* — direction is IM-08's job, not this one's.
- a fixture **missing** `attributedBody` and `payload_data`: the capability struct reports them
  absent and `messages(after:)` still returns rows rather than throwing.
- a fixture with `is_from_me = 1` and one with `0`; both decode as *rows* — direction is IM-08's
  job, not this one's.
- `MessagesDatabaseHealth.probe()` against a path that does not exist returns `.unreadable`, not a
  throw.

**Verify**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-imessage-db
Scripts/run-selftest.sh --selftest-store-isolation
Scripts/run-selftest.sh --selftest-settings
make acceptance TIER=core
```

**Do not**
- Do not open the database read-write, ever, not even "just to check".
- Do not add a database dependency. `SQLite3` is already linked in 11 files.
- Do not spread raw column names outside `MessagesQueries`.
- Do not add a second permissions row for Contacts — that is `Phone-Calls` PH-05 and one framework
  means one prompt.

**Done when:** [ ] the four files exist; [ ] `query_only` is asserted green; [ ] the capability
struct drives every query; [ ] a `--degraded` fixture is handled without throwing; [ ] the path is
injectable so the test needs no grant.

---

## 1a. IM-04a — The Full Disk Access probe and the permissions row

**Finding(s):** FDA is a grant with no read API  **Effort:** 0.5 day  **Depends on:** IM-04, IM-03
**Unblocks:** IM-17

**Goal:** one honest row in the Permissions checklist, and a live status line during onboarding.

**Files you will change**
- `Sources/NextNotes/IMessage/Database/MessagesDatabaseHealth.swift` (new — the probe)
- `Sources/NextNotes/Support/Permissions.swift` — one new row, `hasMessagesAccess`
- `Sources/NextNotes/UI/Settings/MessagesAccessSection.swift` (new)
- `Sources/NextNotes/UI/Settings/AgentSettingsTab.swift` — **one line** to register the section
- registry: nothing new; the flag is IM-04's

**Read for context (do not change):** `Support/Permissions.swift:42` — `hasHeardSystemAudio`, and
the reasoning that makes this task honest: *"a tap without the grant succeeds and delivers zeroed
samples, so one non-silent buffer is proof the grant exists, and it is the only proof there is."*
FDA is the same shape, and the row is the same kind of row.

**Current behaviour:** `Permissions` has four rows — accessibility, microphone, system audio,
calendar. There is no Messages row, because there is no Messages code.

**Target behaviour**
1. `MessagesDatabaseHealth.probe()` opens `chat.db` read-only and reads **one row**. That is the FDA
   proof. It returns a real state, never a query: there is no API to ask.
2. `Permissions.hasMessagesAccess` reads the probe, and its `canRequest` is **`false`** — like
   Accessibility, FDA is granted in System Settings and cannot be provoked. **Do not add a
   `hasFullDiskAccess` that queries something**; that is the mistake `00-README` §11 names.
3. `MessagesAccessSection` renders the live `○` / `✓` from the probe, and the **copy is IM-03's,
   verbatim**: *"Next Notes needs Full Disk Access to read the iMessage conversation you choose for
   remote access. Messages are processed on this Mac."*
4. `AgentSettingsTab` gains **one line**. It is a section, not a thirteenth tab — and note from
   `roadmap/BUILD-ORDER.md` finding C3 that this file has **five** writers across the roadmaps,
   so land the section file and hand the one-line registration to the orchestrator rather than
   batching it with a task you do not own.

**Red-first self-test:** extend `--selftest-imessage-db` (one marker, cases added). Cases: the probe
against a path that does not exist returns `.unreadable` rather than throwing; against the
`basic-text` fixture it returns `.readable`; `canRequest` is `false`; and the rendered section shows
`✓` **only** when the probe succeeded — assert the absence of a `✓` on a failure, because that is
the whole task.

**Verify**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-imessage-db
Scripts/run-selftest.sh --selftest-settings
Scripts/run-selftest.sh --selftest-ui-strings
make acceptance TIER=core
```

**Do not**
- Do not add a `hasFullDiskAccess` query. `00-README` §11.
- Do not add a `SettingsTab` case.
- Do not put "SQLite", "chat.db", "Full Disk Access" as a *technical* requirement in the copy — the
  grant is named, the mechanism is not.
- Do not touch `Support/Permissions.swift` and `AgentSettingsTab.swift` in the same commit as
  anything `Phone-Calls` owns. `BUILD-ORDER.md` C3.

**Done when:** [ ] the probe is a real read, not a query; [ ] `canRequest == false`;
[ ] the copy is IM-03's verbatim and passes `--selftest-ui-strings`; [ ] the `✓` is absent on
failure.

---

## 2. IM-05 — The decoder

**Finding(s):** `message.text` is routinely NULL for iMessage  **Effort:** 2 days — **the highest-risk
task in this roadmap**  **Depends on:** IM-04  **Unblocks:** IM-06

**Goal:** an `attributedBody` typedstream becomes text, a non-text balloon becomes an honest
refusal, and neither case ever returns a plausible-looking empty string.

**Why this task exists at all:** the predecessor roadmap listed `message.attributedBody` in its
field inventory and then never mentioned it again. For a message sent over **iMessage** rather than
SMS the body is *also* available as a **typedstream** — Apple's versioned, undocumented
encoding. A decoder that reads only `text` passes every developer's own SMS test and returns empty
for every real message. That is the most likely way this feature ships broken, and it is why IM-01
experiment 1 exists.

**Files you will change**
- `Sources/NextNotes/IMessage/Database/MessagesDecoder.swift` (new)
- `Sources/NextNotes/IMessage/Database/MessagesDecoderSelfTest.swift` (new —
  `--selftest-imessage-decode`)

**The fixture corpus already exists — do not write a second one.** `Tests/Fixtures/chatdb/`
(built 2026-09-25, 13 cases, `--degraded` mode, 17/17 deterministic, verified with
`/usr/bin/sqlite3` and no build). Its `README.md` says which case serves which assertion.

**The parser decision is already made — hand-written, not `NSUnarchiver`.** `TYPEDSTREAM-NOTES.md`
(discussed 2026-09-25) answers this, and the answer is not the obvious one: a typedstream has no
`$archiver`/`$objects` plist, so `NSKeyedUnarchiver` **cannot open it at all**, and the API that can
read it, `NSUnarchiver`, has no throwing entry point — it signals failure by raising `NSException`,
which Swift cannot catch. An unfamiliar format version would then become a **process exit inside the
message read path**. That is strictly worse than a parser returning plausible garbage, because the
whole designed response to a format change is "degrade and say so", and `unreadable(reason:)` is a
value to degrade *to* while an exception gives nothing to degrade to. So: a hand-written parser, and
its version gate is **data** rather than a branch.

**Two gaps the corpus still has, both stated rather than papered over:**

1. **No case carries a real typedstream.** `basic-text` carries **no** `attributedBody` at all, so
   it is the `.absent` case, not the `.unreadable` one, and this task's second assertion — "the
   same row with `text` populated and with `attributedBody` populated decodes identically" — is
   **structurally unpassable today**. `both-paths` (added 2026-09-25) now pins the *structure* of
   that case: one handle, one chat, two rows holding the identical sentence, the only two
   differences between all 32 columns being `text`, `attributedBody`, `guid`, `date` and `ROWID`.
   Its `attributedBody` is the corpus sentinel, so only the **negative** half runs today. Add the
   real blob when IM-01 lands.
2. **A 14th case is needed and does not exist yet: a row with `text` AND `attributedBody` both
   populated.** Without it, the rule that `text` **takes precedence** is unpinned, and that rule is
   what makes a hybrid balloon safe. `both-paths` deliberately does not serve this — IM-01 should
   not go hunting for a row with both columns set; see IM-01.

**So: build the decoder's structure, the `payload_data` path, the refusal cases and the `.absent`
case now, against the existing corpus. Fill `both-paths` and add the 14th case when IM-01 lands, and
mark this task `blocked` on IM-01 for the decode-identically assertion rather than weakening it.**

**Read for context:** IM-01's report `Tests/Reports/imessage-self-flow.md`, question Q2. The
fixture bytes come from there, not from a description. Also read `Knowledge/KnowledgeStore.swift`'s
`text(_:)` and `optionalDouble(_:)` helpers for the column-to-value shape.

**Target behaviour.** Four paths, in priority order, and **the order is
load-bearing rather than incidental** — the non-text check is *third* and not
first, because a photo message carries `payload_data` too and checking it before
the blob would turn every photo into a refusal and throw away the caption:

| Case | Signal | Result |
|---|---|---|
| `text` present and non-empty | `text` | the text — an empty `text` falls through, because `""` is not a message |
| `attributedBody` present, parseable, string is **not** `U+FFFC` alone | `attributedBody` | the `NSMutableString`/string value from the stream |
| `attributedBody` present, **one string field equal to `U+FFFC` and nothing else** | a balloon with no sentence in it — an effect, a captionless photo | `.notText(bundleID:)` — the id is the row's `balloon_bundle_id` when there is one, and `nil` when nothing named it |
| `attributedBody` present, **not** parseable on this macOS | versioned header mismatch, or any refusal | `.unreadable(reason:)` — **never** `""` |
| `payload_data` present, `balloon_bundle_id` set | a non-text balloon named by its column — a tapback | `.notText(bundleID:)` — a state the agent layer can say out loud |
| neither body column | an SMS, or a row older than iMessage | `.absent` — an ordinary answer, not an error |

> **The `U+FFFC` row and the optional id were added on 2026-09-26, and the row they replaced was
> wrong.** The table used to read "`payload_data` present, `balloon_bundle_id` set → a non-text
> balloon" as though that were the **only** route, and an **effect** is a non-text balloon. The
> owner's own measurement settled it: sending an effect to their own conversation produced four rows
> with `text = NULL`, a 314-byte `attributedBody`, and **both** of those columns absent — so the
> rule fired on none of them. The body is an ordinary **text balloon** (`NSAttributedString` →
> `NSObject`, the identical chain a sentence carries) whose one string field is **three bytes of
> `U+FFFC` and nothing else**. Two consequences, both load-bearing:
>
> - **The class chain does not identify an effect.** §1's "match the chain, not the leaf" is the
>   rule that survives a format change, and here it has nothing to say. The only signal is the
>   three bytes the walk read.
> - **`.notText`'s bundle id is now `String?`, and it is not decoration.** There is no bundle id
>   in the stream: the 237 unread bytes hold three `__kIM*` attribute names and one 36-character
>   `s`-prefixed UUID under `__kIMFileTransferGUIDAttributeName` which is **different in each of
>   the four rows** — a per-message transfer id, not an app identity. No `com.` substring appears
>   anywhere in the 314 bytes. The type could not express "arrived, and nothing named it", and the
>   only two ways to force it to were to invent an id or to pass `""`. **The invariant the change
>   buys: a non-text balloon can no longer be required to name an app.**
>
> **A fifth case was considered and rejected.** `.notText` already means "not a text balloon: a
> tapback, an effect, an app extension's message" — an effect *is* that, and the measurement
> corrected its payload rather than showing the state was the wrong one. `.notText` also now
> carries `discardedBytes`, because this is where the unread payload is **largest**: 237 of 314
> bytes, against the old property that answered `0` for every non-`.text` body on the reasoning
> that a body with no words has nothing to have passed over. It has nothing to *read* and 237 bytes
> to pass over. See `TYPEDSTREAM-NOTES.md`, *IM-05c*.

> **Naming, settled 2026-09-25.** The state is **`.unreadable(reason:)`**, and
> that is the spelling that shipped in `MessagesDecoder.swift` and the one
> `TYPEDSTREAM-NOTES.md` §5.1 uses. An earlier draft of this table said
> `.undecodable(reason:)`; the two names had drifted apart and the note's was
> adopted. "undecodable" survives in this roadmap only as the name of the
> **`undecodable messages` canary metric** (§*canary* of
> `03-PHASE-2-P1-SLICE.md`), which is a metric name and not a state name.

**The refusal is the feature.** An empty string is a lie the user cannot distinguish from silence;
"Next · I received that but couldn't read it on this version of macOS" is a sentence they can act
on. `IMessageEnvelope.text` becomes `String?` and gains a `decodeState`, so **nothing downstream can
read an undecodable message as a blank one.**

Also: the typedstream layout differs across macOS releases, so the decoder's version gate is data
(`MessagesSchemaVersion`) and its failure is a *capability*, not an exception. Record the version it
was written against in the file header, as `KnowledgeStore` records its `user_version`.

### Three places the built decoder departs from this task's text

Adopted on 2026-09-25 after `MessagesDecoder.swift` was written, and the code is right in all three.
Each is a fact about the world this task text could not have known, not a preference — the reasons
are the point, so they are recorded here and not left in a file header.

1. **`systemVersion` in `unsupportedStreamVersion(found:system:)` is `UInt16?`, not `UInt16`.** The
   corpus's `X'0001'` refusal sentinel is **two** bytes: the streamer version is there and the system
   version is not, because it needs the whole 13-byte header before it exists. Writing `0` for bytes
   that are not there would put a fabricated reading into a log line and a canary metric — the exact
   failure the "nothing from the blob reaches a metric" rule forbids. **A missing measurement is
   `nil`.**
2. **There is a `.notATypedStream(offset:)` refusal case.** The five cases this task named have nowhere
   to put "these bytes are not this format at all", and that is a *different* fact from "this format
   is at a version I do not read" — one means a corrupt column, the other an unfamiliar file, and a bug
   report needs to tell them apart.
3. **`MessageBodySource` has four cases, not the two this task's table implied:** `.textColumn`,
   `.attributedBody`, `.payloadData`, `.noColumn`. A `.textColumn` source attached to a body that came
   from `payload_data` would be a lie the three-case enum could not express, and every consumer
   downstream reads that field to decide which column to trust.

**Red-first self-test:** `--selftest-imessage-decode`, INTEGRATION,
`IMESSAGE_DECODE_OK: <n> cases` / `IMESSAGE_DECODE_FAILED: <case>: <reason>`.

> **Read the case count as what it is, and note that it is two numbers.** The run
> also prints `IMESSAGE_DECODE_BLOCKED: <name> — <what it waits for>` lines, and
> those are **deliberately not counted** in the `IMESSAGE_DECODE_OK: <n> cases`
> figure. That is the difference between an honest count and a flattering one: a
> number that includes a case nobody ran is a claim about the test rather than
> about the decoder. **`22` — the default, with no real bytes present — does not
> mean "everything is covered"**: it means 22 cases ran and passed and six named
> ones did not run at all. **With `IMESSAGE_DECODE_REAL_BLOB` pointed at IM-01's
> artefact it is `26`**, and only two lines are blocked. A blocked line is never a
> silent skip, and a line that *stops* being blocked is never silent either: the
> count moves, and the transcript says which.
>
> The cases come from **two** fixture sources, and the difference is the claim each
> makes: the sanitised corpus is a claim about **what Messages writes**, and
> streams **Apple's own encoder** produces at test time are a claim about **this
> parser's mechanics**. `NSArchiver` is deprecated and the test uses it anyway, on
> purpose and under `TYPEDSTREAM-NOTES.md` §2.3's one sanctioned exception — it is
> the only encoder of this format the system still ships, `NSKeyedUnarchiver`
> cannot open a typedstream at all, and the single deprecation warning it produces
> is left standing rather than silenced. **It pins the parser. It is not evidence
> about Messages' own layout**, and no blocked line below may be closed by adding
> an oracle case.

Cases, all from the sanitised corpus unless named `archiver_oracle_*`:

| Case | Source | Asserts |
|---|---|---|
| a real `attributedBody` blob with `text` NULL | ✅ real bytes, **2026-09-26** — blocked and uncounted without `IMESSAGE_DECODE_REAL_BLOB` | decodes to the expected sentence, and refuses to pass on an ASCII one |
| the **same row with `text` populated** | ✅ real bytes, **2026-09-26** | decodes identically — the two paths agree, which proves the typedstream path is right rather than merely non-crashing |
| a row with **both** columns populated | ✅ real bytes, **2026-09-26** | `text` takes precedence over a stream that *does* decode, with a different sentinel in the column so agreement cannot pass for precedence |
| every prefix of a **real** body | ✅ real bytes, **2026-09-26** | 10,175 prefixes, none decoding to a different string, to `""`, or to a non-body |
| a blob whose version header does not match | corpus (`X'0001'` sentinel) | returns `.unreadable`, **and the value is not `""`** |
| a `payload_data` + `balloon_bundle_id` row | corpus (`reaction`) | returns `.notText` with the bundle id surviving |
| a row with no `attributedBody` at all | corpus (`basic-text`, `sms`) | `nil` text with `decodeState == .absent`, not an error |
| a retracted row | corpus (`unsend`) | refuses rather than answering empty |
| every prefix of a whole stream | `archiver_oracle_*` | **no prefix ever decodes to a *different* string** — never a shortened one |
| a declared length past the end | `archiver_oracle_*` | refused as `.truncated`, not read out of bounds |
| a bad *system* version, good streamer version | `archiver_oracle_*` | the gate is a **pair**, not a byte |
| the non-ASCII length, and the `0x81` escape | `archiver_oracle_*` | the length is a **byte** count and a long string is not truncated |
| an `NSNumber` root | `archiver_oracle_*` | its first field is a `char *` and is **refused**, not read as `q` |

⚠️ **"Every proper prefix of the real blob is refused" was wrong and must not be
restored.** `TYPEDSTREAM-NOTES.md` §4.1 asserted it; it is false for a structural
reason — the message text sits *early* in the stream, so a prefix that already
contains the whole sentence contains a body this Mac can read, and refusing it
would be refusing real text. A test written to that wording would have had to be
weakened the first time it ran against a real blob, and a test that *has* to be
weakened is a test whose failure gets rationalised away. The property that holds,
and that the test asserts under
`a_truncated_stream_never_decodes_to_a_different_string`, is the one in the table.

### The five blocked assertions, by name — three answered 2026-09-26

Inherited work, not a to-do list invented later. Each prints as
`IMESSAGE_DECODE_BLOCKED: <name> — <what it waits for>` and none is counted.

**Status after IM-01's real bytes were run through the shipped decoder
(2026-09-26): 9 of 9 real bodies decoded whole, no parser bug, and the length is
counted in bytes.** The full record is
`Sources/NextNotes/IMessage/Database/TYPEDSTREAM-NOTES.md` §7. Three of the five
are answered — but **answered from a local artefact, not from a fixture**, and
that distinction is the mechanism, not an evasion:

> `make-chatdb-fixture.sh` **cannot** emit a real body. Its sanitisation guard
> scans the SQL it is about to write and a multi-kilobyte hex string is full of
> 11-digit runs, so it fails with *"refusing to emit a fixture containing a bare
> 11-digit number"*. A sanitised stand-in with the same structure is the same
> hex, and a hand-synthesised one is what §1 forbids. So the real-body cases read
> the bytes from `IMESSAGE_DECODE_REAL_BLOB`, a keyed file outside the repository
> (`text=` the sentence the sender typed, `blob=` the hex), and
> `--selftest-imessage-decode` prints them as blocked — **uncounted** — when that
> variable is unset.

| run | `IMESSAGE_DECODE_OK` | blocked lines |
|---|---|---|
| no artefact (CI, any other machine) | **22 cases** | 6 |
| with IM-01's artefact | **26 cases** | 2 |

1. **`attributed-body-from-a-real-message`** — ✅ **ANSWERED.**
   `real_body_decodes_to_the_sentence`. The 202-byte self-message declared
   `0x1b` = **27** for a **25-character, 27-byte** sentence and the decoder
   returned all 25 characters with both `é`s intact, so **the length is a byte
   count** — the last open question IM-01 had for `TYPEDSTREAM-NOTES.md`. The
   case refuses to pass on an ASCII sentence, because an ASCII sentence cannot
   tell bytes from characters and would look like an answer.
2. **`both-paths-decodes-identically`** — ✅ **ANSWERED.**
   `real_body_and_the_text_column_agree`: one sentence out of `text` and the same
   sentence out of the real stream, same chat, same row shape. The structural
   half and row B's refusal are still green against the committed corpus.
3. **`text-takes-precedence-over-a-decoded-stream`** — ✅ **ANSWERED, and the
   premise was wrong.** `text_takes_precedence_over_a_real_decoded_stream`
   runs against the real stream with a deliberately *different* sentinel in the
   `text` column. This is not an exotic shape: **all ten of the newest real rows
   carry `text` *and* a stream**, so the rule decides almost every real message
   and the 14th corpus case the roadmap asked for is not needed.
4. **`effect-bubble-classification`** — ✅ **ANSWERED, and the premise was wrong.**
   `effect_row_55198_is_not_text_and_not_unreadable` and
   `effect_row_55198_passes_over_its_whole_attribute_graph`, plus the same two for rows 55199,
   55200 and 55201, run against **four real effect rows** the owner produced by sending an effect
   to their own conversation — the first measured rows on this machine with `text = NULL`,
   `payload_data` absent **and** `balloon_bundle_id` NULL. So the rule this assertion was going to
   pin (`payload_data` + `balloon_bundle_id`) fires on none of them, and the four rows answer a
   different question: the body is a text balloon whose one string is `U+FFFC` and nothing else,
   which is **`.notText` with a `nil` id** and **237 of 314 bytes passed over unread**. The
   corpus's `reaction` row still stands as the tapback half — the same state reached from a
   different column, and the one route that arrives with an id — and
   `tapback_is_not_text` is now also the case that says the two routes report different
   `MessageBodySource`s. The bytes stay a local artefact, and
   `make-chatdb-fixture.sh`'s sanitisation guard is why: asked to emit them it refuses the hex of a
   314-byte body as a bare 11-digit number. The case reads IM-01's `cases.sh` block through
   `IMESSAGE_DECODE_EFFECT_CASES`; unset, it prints `IMESSAGE_DECODE_BLOCKED:` and does not move
   the count. Three mutations redden it and are recorded in
   `~/Library/Caches/NextNotesBuild/imessage/IM-05c-red.txt` — and the third of them, a search of
   the discarded region for an id, **found a real hole in IM-17c's leak check** (it compared
   maximal printable runs, so a value that arrived without its one-byte type tag was invisible) and
   that fix is part of this task. See `TYPEDSTREAM-NOTES.md`, *IM-05c*.
5. **`voice-note-as-not-text`** — ⛔ **still blocked, and
   `Tests/Fixtures/chatdb/README.md` is wrong about this row.** It lists
   `voice-note` as IM-05's `.notText` case. That case **cannot be built today**:
   IM-04's `MessageRow` does not project `is_audio_message`, and the row's
   `attributedBody` is the sentinel, so nothing distinguishes a voice note from
   a text body that failed to decode. The decoder classifies it as a **refusal**,
   which is honest and is *not* what the README claims. Fixing it needs **a
   projected `is_audio_message` column in `MessagesQueries`** — IM-04's shape, not
   this task's. Do not "fix" the mismatch by weakening the classifier: `U+FFFC`
   and `payload_data` are the signals a real photo/effect carries, and a voice
   note carrying neither is genuinely unreadable until the column is projected.

**A fourth case came with the real bytes, and it is the one this task cares most
about:** `no_prefix_of_a_real_body_decodes_to_a_different_string`. Across all
10,175 prefixes of the nine bodies, no prefix decoded to a *different* string,
none to `""` and none to a non-body — and rewriting the self-message's length
byte to the *character* count makes the same decoder return
`Héllo - checking the caf` with no error at all. That is the counterfactual
§1.4 predicts, run for real; the transcript is
`~/Library/Caches/NextNotesBuild/imessage/IM-05b-mutation.txt`.

**Verify**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-imessage-decode
Scripts/run-selftest.sh --selftest-imessage-db
make acceptance TIER=core
```

**Do not**
- Do not return `""` for a body you could not read. That is the whole task.
- Do not commit a fixture containing a real phone number, name or address. Sanitise, and use
  `REDACTED-HANDLE-1` style placeholders.
- Do not parse `attributedBody` by string-searching for the first printable run. A typedstream
  carries lengths and offsets; a scan produces plausible garbage.
- Do not make the decoder tolerate a schema change by ignoring the failure. Degrade the *feature*
  and say so.
- Do not add a parsing dependency without a licence check (BSD/MIT/Apache-2.0/ISC/OFL) and a
  `THIRD-PARTY-NOTICES.md` entry.
- Do not let the `NSArchiver` oracle stand in for a Messages blob. It pins the parser's mechanics and
  nothing else; a blocked line closed with an oracle case is a blocked line that will fail in
  production.
- Do not silence the oracle's deprecation warning. It is one line, it is in the test, and it is the
  only statement this codebase makes that a deprecated API is being used on purpose.

**Done when:** [x] every case that can be built offline is green, and the five blocked ones are named
on `IMESSAGE_DECODE_BLOCKED:` lines rather than skipped; [x] the refusal is proven not to be empty
from four directions; [x] no prefix of a whole stream decodes to a *different* string; [x] the file
header names the macOS version it was written against; [ ] the two `text`-present and `text`-absent
fixtures produce identical text — **still open, blocked on IM-01's real blob.**

---

## 3. IM-06 — The WAL watcher

**Finding(s):** polling `chat.db` every 500 ms is the thing this replaces  **Effort:** 1 day
**Depends on:** IM-05  **Unblocks:** IM-07

**Goal:** a new row in the paired chat becomes an envelope within ~150 ms of it landing, exactly
once, in ROWID order — or the app is asleep.

**Files you will change**
- `Sources/NextNotes/IMessage/Watcher/MessagesWatcher.swift` (new)
- `Sources/NextNotes/IMessage/Watcher/MessagesWALWatcher.swift` (new)
- `Sources/NextNotes/IMessage/Watcher/MessagesWatermark.swift` (new)
- `Sources/NextNotes/IMessage/Watcher/AttachmentJoinResolver.swift` (new)
- `Sources/NextNotes/IMessage/Watcher/MessagesWatcherSelfTest.swift` (new —
  `--selftest-imessage-watch`)

**Read for context (do not change):** `Knowledge/Files/FileIndexWatcher.swift`. ⚠️ **This section
was wrong about that file and the correction matters** (2026-09-25). It is **FSEvents**, not
`DispatchSourceFileSystemObject`: it watches *directories* with `kFSEventStreamCreateFlagFileEvents`
and a 2 s coalescing latency, and it holds **no watermark at all** — the incremental logic lives in
its caller. Read it for the lifecycle discipline (teardown in `deinit`, `stop()`, a dedicated
`DispatchQueue`, `kFSEventStreamCreateFlagIgnoreSelf`, and the log line when the stream refuses),
which is genuinely worth copying, and for the comment explaining *why* a folder is watched rather
than a timer.

But do **not** copy its mechanism here. FSEvents is the right unit for a Downloads folder because
the unit of work is "re-list this directory"; the unit of work here is "these three rows landed in
**one file**", and an FSEvents stream over `~/Library/Messages/` fires for every file Messages or
its daemons touch. `DispatchSourceFileSystemObject` on the `-wal` descriptor is the narrower,
cheaper signal, and the debounce and watermark are **yours to write** — the precedent solved
neither.

**Target behaviour**
1. `DispatchSourceFileSystemObject` on `chat.db-wal`, optionally `chat.db` and `chat.db-shm`.
   **One file event is not one message.**
2. Debounce 50–150 ms, then `messages(after: watermark.rowID)`, decode, **process in ROWID order**,
   advance the watermark.
   ⚠️ **Requirement 2 and requirement 4 contradict each other as originally written** (found
   2026-09-25): strict delivery order *plus* "a never-settling attachment must not block another
   message" is not satisfiable, because a row 1 that never settles **is** a 2 s block on row 2. The
   resolution, which the self-test now pins by mutation:
   **processing** is strictly in ROWID order, and **delivery** is in ROWID order for every row that
   is ready inline; a row still waiting on its join row is delivered **when it settles**, flagged
   `deferred: true`, and the rows behind it are **not** held back for it. So the guarantee is
   *processing* order, not *completion* order — and the test that catches the collapse is the one
   asserting a never-settling row arrives **last**, not first.
3. **Two** idempotency mechanisms, both required: `lastProcessedRowID` **and** `processedMessageGUIDs`.
   The GUID cache is what protects against schema and join races and against replay during recovery;
   the row id alone does not.
4. `AttachmentJoinResolver`: a row with `cache_has_attachments` and no `message_attachment_join` row
   yet waits and refetches, **8 retries / 2 s maximum, per message.** A single global deadline is
   wrong: one slow attachment would then stall a queue of text commands, which is precisely the
   "Next stopped responding" symptom the predecessor's sleep/wake section promises to avoid.
   ⚠️ **This section was self-inconsistent** (found 2026-09-25): it also said "waits 100–250 ms",
   and only the top of that band satisfies 8 retries in 2 s. **250 ms × 8 = 2 s exactly**, so the
   two numbers are one number counted twice and cannot drift apart — the **retry count is the harder
   number, so the interval is what bends.** Settle the count, derive the interval, and do not write
   both independently again.
5. The watcher is **almost idle** when nothing arrives. No timer per message, no periodic `SELECT`.

**Red-first self-test:** `--selftest-imessage-watch`, **CORE**,
`IMESSAGE_WATCH_OK` / `IMESSAGE_WATCH_FAILED: <reason>`. Cases:
- one file event carrying three rows emits three envelopes **in ROWID order**.
- three separate file events carrying the same row emit **one** envelope (the GUID cache).
- a replay from `ROWID 40` after a simulated restart emits nothing for 40–60 and emits 61+.
- **the settling race**: use the `delayed-attachment-join` fixture — it ships with
  `cache_has_attachments=1`, an `attachment` row present, and **zero** `message_attachment_join`
  rows, which is exactly this case. Assert a row that gains its join row on the third refetch resolves, and
  the per-message deadline means a *different* message with a never-settling attachment does not
  block it.
- a message whose body is undecodable (IM-05) still **advances the watermark** and still notifies
  its listener — a decode failure must not wedge the watcher. This case is the one that would
  otherwise be discovered in production.
- with the paired-chat filter already known, a row in a non-paired chat emits nothing.

**Verify**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-imessage-watch
Scripts/run-selftest.sh --selftest-imessage-decode
Scripts/run-selftest.sh --selftest-contention
make acceptance TIER=core
```

**Known debt, found while implementing (2026-09-25) — do not treat as done.** IM-04's
`MessagesQueries` carries the comment *"this file is the only place a Messages column name is written
down"*, and `MessagesSchemaProbe.probedTables` does not list `message_attachment_join` or
`attachment`. This task therefore carries **its own** probe and **its own** column names, and says so
at the point of the break rather than quietly widening IM-04's files. Folding the two join tables
into `probedTables` and `MessagesQueries` restores the invariant and is a small, separate change to
IM-04's two files — **it is not folded in here**, because one task should not rewrite another's
committed files. Until it is done, two files name Messages columns and the comment is a lie.

**Do not**
- Do not poll on a timer. Filesystem signal plus an incremental query, or the feature is a battery
  bug.
- Do not use a single deadline for the settling race.
- Do not let a decode failure stop the watermark advancing.
- Do not run this in a tight loop against a live database in a self-test; every case uses a fixture
  copy.

**Done when:** [ ] the six cases green; [ ] the watcher is event-driven with no periodic query;
[ ] the per-message settling deadline is asserted, not just implemented.

---

## 4. IM-07 — Self-channel pairing

**Finding(s):** G1's answer chooses the filter  **Effort:** 1 day  **Depends on:** IM-06, IM-01
**Unblocks:** IM-08

**Goal:** one conversation becomes the command channel, chosen by a deliberate act, and expires.

**Read the task text of §3 in `01-PHASE-0-SELF-FLOW.md` first.** If G1 answered "`is_from_me = 0`",
this task's filter is *not* "watch from-me rows" and the task text must be amended before you start,
with the amendment recorded in `STATUS.md`.

**Files you will change**
- `Sources/NextNotes/IMessage/Pairing/SelfChannel.swift`, `SelfChannelPairing.swift` (new)
- `Sources/NextNotes/IMessage/Pairing/RemoteIdentity.swift`, `RemoteIdentityStore.swift` (new)
- `Sources/NextNotes/IMessage/Pairing/SelfChannelSelfTest.swift` (new —
  `--selftest-imessage-pairing`)
- `Sources/NextNotes/IMessage/IMessageConfiguration.swift` (new — `imessage-settings.json`)
- `Sources/NextNotes/Support/SelfTestStoreGuard.swift` — add `imessage-settings.json`

**Target behaviour**
1. `IMessageConfiguration` persists, in `imessage-settings.json` (six scalars — JSON is right, and
   `PersonResolutionStore` is the precedent for choosing JSON deliberately):
   `enabled`, `pairedChatGUID`, `pairedAt`, `lastProcessedRowID`, `localIdentity`,
   `remotePolicyVersion`, plus `chatHandleCache` (IM-09's AE target, resolved once at pairing) and
   `lastInboundCommandAt` (the UI's "Last request · 2 min ago").
2. **Five-minute pairing mode.** On entering, record `pairingStartRowID`. Watch only rows newer than
   it. On a matching self-message (`text == "Hi Next"` **and** `rowID > pairingStartRowID` **and** the
   chat is a direct self-conversation), persist the `chat.guid` and the local identity.
3. **The confirmation send is part of the gate.** "Next is ready. Message me here whenever you want
   something handled on your Mac." is sent, and **pairing has not succeeded until that row is
   observed.** If the send fails, the settings screen must not read `Connected` — this one send
   validates the outbound path, so it is the cheapest possible end-to-end test and it happens at
   exactly the moment the user is watching.
4. `localIdentity` comes from IM-02's chosen method. It is stored because the trust boundary needs
   "expected account/service", not only a GUID.

**Red-first self-test:** `--selftest-imessage-pairing`, INTEGRATION. Cases: the five-minute window
accepts a matching row inside it and **refuses the same text outside it**; a row at
`rowID == pairingStartRowID` is refused (the boundary is exclusive); a group `chat.guid` is refused
in V1, because IM-09 cannot address one; a second pairing attempt inside the window is refused;
`imessage-settings.json` round-trips through `RemoteIdentityStore`; and **a `settings.json` written
without the new keys decodes with defaults** — the same `decodeIfPresent` rule as `AgentTask` and
`MemoryEntry`, because a settings file is written by more than one build.

**Verify**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-imessage-pairing
Scripts/run-selftest.sh --selftest-store-isolation
make acceptance TIER=core
```

**Do not**
- Do not pair a group conversation in V1. `00-README` §13's glossary says V1 is a direct
  self-conversation and IM-09's report settles whether that can change.
- Do not infer the pair from message *wording* — the predecessor's exit criterion is explicit that
  wording alone is not enough.
- Do not show `Connected` before the confirmation send is observed.
- Do not let a remote command change the paired chat. That is IM-12's rule and it is a local act.

**Done when:** [ ] the window, the boundary and the group refusal are green; [ ] the confirmation
send is verified before `Connected`; [ ] the settings file decodes from an older shape.

---

## 5. IM-08 — Classification and the outbound ledger

> **The design for this task is `IM-08-DESIGN.md` (written 2026-09-26). Read it instead of this
> section.** It carries the classification table and its precedence, the reconciliation of the two
> vocabularies, the pairing rule and its three failure modes, the ledger's **permitted-field
> allowlist**, the authority split, the copy register, and §7's list of what this section got wrong.
> **This section is the summary; the design is the specification.** Its effort line is wrong by a
> factor of two and the design splits the task into `IM-08a`…`IM-08d`.

**Finding(s):** a `from-me` row is not a user request  **Effort:** ~~1.5 days~~ **3 days, split into
`IM-08a`…`IM-08d`** — it remains **the security task of this phase**  **Depends on:** IM-07 (and
`IM-08c` on IM-02)  **Unblocks:** IM-11

**Goal:** make the loop impossible **and** make an echo unable to poison memory.

**The problem**

```text
Next sends a response
   → Messages writes a from-me row
   → the watcher sees a from-me row
   → Next treats it as a new command
   → infinite loop
```

**And the quieter problem, which the predecessor stated as two unconnected facts.** Its §13
establishes that a `from-me` row must be matched against an outbound ledger before it is treated as
a command; its §38 then says a user-written iMessage is "trusted user words" for memory. In this
codebase "trusted user words" is concrete: `MemoryProvenance.TrustedSource.userSaidToAgent` at
**confidence 0.9** (`Memory/MemoryGuard.swift:8`), `requiredAuthority` `.user`, with
`MemoryGuard` refusing to let `readToolOutputThisTurn` text through.

**So if a `from-me` row is classified as the user before the ledger match, every message Next
Notes itself sent becomes a 0.9-confidence memory of something the user said, and every result
delivery becomes a durable fact.** That is a memory-poisoning bug, and the ledger match must be the
gate on classification, and classification must be the gate on
`AgentSession.recordUser(_:source:)` (`Agent/RealtimeAgent.swift:1208`) — not merely on dispatch.

### 5.1 What the 2026-09-26 measurements changed in this section — **measured, not assumed**

Three of this section's rules are now known to be wrong, and the design rewrites all three.

**1 · `is_from_me` cannot identify a self-message, so it cannot identify anything.** One self-message
landed as **two rows** — `55189` `fromMe=true` and `55190` `fromMe=false`, the same 25-character
sentence and the same 202-byte body. A filter written on the flag finds one copy and misses the
other, and which copy it gets is not something the row decides. **Measured**, in
`TYPEDSTREAM-NOTES.md` (*A self-message is TWO rows*) and `STATUS.md`'s IM-01 row. The pairing filter
must be the **chat**; direction must be the **row's sender**; and the only thing the flag still
contributes is "this Mac sent it".

**2 · A self-chat is a thread on your own number, so a row in it can be from somebody else.** Being
in the paired chat is **necessary and not sufficient** for `.user`, which is what
`00-README` §13's glossary has said all along and what §11's "everything else is a user command"
contradicts. **That sentence in §11 is the one to correct**, and the correction is the design's
classification table: `.user` splits into two classes by whether the body carried a sentence, and
`.otherParticipant` — which this section's diagram has no cell for — is reachable.

**3 · A classifier cannot reach for `payload_data` + `balloon_bundle_id` to recognise an effect;
both are NULL and the pair fires on nothing.** All four of the owner's measured effect rows have
`payload_data` absent *and* `balloon_bundle_id` NULL. The body is an **ordinary**
`NSAttributedString` → `NSObject` text balloon whose entire string is `U+FFFC` — three bytes, Apple's
marker for "an attachment is here" — with **237 of 314 bytes passed over unread**. **Measured**, in
`TYPEDSTREAM-NOTES.md` (IM-05c) and in §2's own correction note. The rule a classifier must use is
**`U+FFFC` and nothing else**, `is_audio_message` is a second independent route to the same class, and
§2's `payload_data` row remains a genuine third route for a tapback — it is simply not the one an
effect takes. **Neither the class nor the authority changes with the answer**, which is why the
design makes `MessageBodySource` a field the classifier cannot see.

**4 · A voice note is 466 bytes with `text = NULL`, and either signal gives the same class.** Whether
`U+FFFC` or `is_audio_message` classifies it, the result is `.notText`, and the design keeps the
*source* on the envelope while the *class* is computed from the body alone — so the still-blocked
measurement (`voice-note-row-shape-from-a-real-message`) can change IM-15's handling and **cannot
change IM-08**.

**Files you will change** — as listed below, **plus the classification the design adds and this list
omits**: `Sources/NextNotes/IMessage/Classify/` — `IMessageClass.swift`, `SelfChatMembership.swift`,
`IMessageDirection.swift`, `IMessageClassSelfTest.swift` (new — `--selftest-imessage-class`), and one
statement in `IMessage/Database/MessagesQueries.swift` to resolve `message.handle_id`, which is
already projected and which nothing in the tree reads. **A `UI/` file is also needed** for the two
local notices (`IMessageStatusRow.swift` is IM-17f's; name the owner), which this list has never
mentioned.
- `Sources/NextNotes/IMessage/Sending/OutboundMessageLedger.swift` (new)
- `Sources/NextNotes/IMessage/Sending/IMessageOutboundStore.swift` (new — `imessage-outbound.sqlite`)
- `Sources/NextNotes/IMessage/IMessageBridge.swift` (new — the actor that wires it together)
- `Sources/NextNotes/IMessage/Sending/OutboundLedgerSelfTest.swift` (new —
  `--selftest-imessage-loop`)
- `Sources/NextNotes/Support/SelfTestStoreGuard.swift` — add `imessage-outbound.sqlite`

**Why SQLite and not JSON:** the ledger needs uniqueness on a pending row, an append-only history,
a mutable `matchedMessageGUID`, and a verification status a crash can leave half-written. That is
relational. `KnowledgeStore` is the template. `imessage-settings.json` stays JSON because it is
six scalars.

**Target behaviour** — items 1, 3 and 5 stand; **2 and 4 are superseded**, and the design gives the
replacement for each.
1. `PendingOutboundMessage` is **persisted before** the Apple Event is dispatched. Before, not after —
   a crash in the gap is exactly the case the ledger exists for. **The row's fields are an allowlist,
   not a denylist** (design §3.2): nine fields, every one a number, a digest, an id this app minted or
   a closed enum, and **no free `String` at all** so there is nothing for a caller to put a sentence
   in. A matched row needs `chatGUID`; a `usage.jsonl` row never carries one, and the two rules are
   different on purpose (design §3.2).
2. ~~Matching compares chat GUID · text hash · attachment filenames/hashes · a dispatch **time
   window** · the local message GUID if discoverable.~~ **Superseded.** The same conjunction, with
   three corrections: **filenames never**, only attachment digests; the **window is one-sided**
   (`date >= dispatchedAt - 60 s`, with the pending row's 10-minute expiry as the upper bound) because
   `message.date` read up to **6 minutes in the future** on this Mac and a symmetric window would be
   six minutes wide on one side; and a match requires **`matchedRowID == nil`**, not
   `matchedMessageGUID == nil`, because the row id is the thing the watcher has already ordered by.
3. **Ambiguity resolves toward "command".** If two pending rows match, the row is a **user
   command**. The direction of that default is deliberate: treating a real request as our own echo
   **loses it silently**, which is the dangerous outcome; treating our own echo as a command is a
   no-op that the circuit breaker counts. Fail toward the recoverable error. **Note that this
   default moves a row toward the user side and never away** — the *sender* test fails **closed**
   instead, because answering an unidentifiable sender executes a remote command (design §1.3).
4. ~~The order is load-bearing.~~ **Superseded, and this is the most important correction in the
   section.** The diagram below answers **two** questions with one — the ledger says *is this our
   echo*, and *is this the user* is a different question with a different input. `.otherParticipant`
   has no cell in it at all, which is how §11's wrong sentence survived. The design's order is
   **ledger → body refusals → direction**, one pure function, four parameters, and
   `IMessageEnvelope` is **not** one of them (design §1.1–§1.3):
   ```text
   row arrives → ledger match ──► matched   → .ownEcho          → never record, never answer
                    │ not matched
                    ▼
              body state?  ──► unreadable → .couldNotRead      → nothing, either side
                    │        ──► absent    → .nothingToRead     → nothing, either side
                    ▼ not a refusal
              direction ──► this Mac / local number → .userCommand  → one turn, one memory
                          ──► foreign number       → .fromSomebodyElse → nothing remote, one card
                          ──► unresolved           → .fromSomebodyElse → nothing remote, one card
                    ▼
        AgentSession.recordUser(_:source:)   ← the only path into memory
   ```
5. The **circuit breaker**: more than 5 agent-authored messages in 10 seconds with no confirmed
   user row suspends iMessage sending and raises a local notice. **In memory, not persisted** — a
   ten-second window does not survive a relaunch and persisting it would be a second store.

**Red-first self-test:** `--selftest-imessage-loop`, **CORE**,
`IMESSAGE_LOOP_OK: 100 replies, <n> new memories` / `IMESSAGE_LOOP_FAILED: <reason>`, **plus a new
`--selftest-imessage-class`** (`IMESSAGE_CLASS_OK: <n> cases` / `IMESSAGE_CLASS_FAILED: <case>:
<reason>`, INTEGRATION) holding the classification, the membership rule and the store's allowlist —
design §5, `IM-08a`…`IM-08d`. Cases:
- send 100 replies through the bridge; then assert **zero new `MemoryEntry` rows, zero new
  `AgentSession` rows, and zero new agent turns.** Asserting only "the agent did not respond" passes
  while memory is still poisoned — the memory assertion is the task.
- a user row that is *not* matched becomes exactly one session row and is answerable.
- the ambiguity case: two identical pending rows, one user message → treated as a command.
- a crash between "persisted" and "dispatched" leaves a pending row that expires rather than
  swallowing the user's next message.
- the circuit breaker: 6 agent messages in 10 s with no user row suspends sending, and a *user*
  message resumes it.
- a matched row is never passed to `AgentSession.recordUser` even when its text is imperative
  ("remember that the sky is green").

**Verify**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-imessage-loop
Scripts/run-selftest.sh --selftest-imemory
Scripts/run-selftest.sh --selftest-store-isolation
make acceptance TIER=core
```

**Do not**
- Do not treat `is_from_me` as the trust signal. The ledger match is. **And do not treat it as the
  direction signal either** — §5.1's two rows make that impossible, and the flag cannot even say
  which copy of one message it is looking at.
- Do not write the pending row after dispatching.
- Do not let a matched row reach `AgentSession.recordUser`. That is the single most important
  negative assertion in this roadmap.
- Do not log message text. Digests and counts only; `00-README` §12.
- ~~Do not put contents in a metrics row — `UsageLog.sanitise` exists for that and the ledger is not
  exempt.~~ **Corrected: `UsageLog.sanitise` is not the control and this line should not be
  followed.** It strips quoted content, addresses, URLs, paths and six-digit runs, and **a third
  party's promotional offer is none of those — it is prose, and it survives every rule in the
  function.** Enforcement is **at construction**: a closed row type, one `insert`, and a case that
  writes a row built from a fixture carrying a promo string, a body and a file name and then reads
  the file with `strings(1)` to prove none of the three reached the disk (design §3.3).
- Do not add a `status`, `task` or approval column to the ledger. `TaskBridge` owns task state.

**Done when:** [ ] the 100-reply case shows 0 new memories and 0 new session rows; [ ] ambiguity
resolves to "command"; [ ] the breaker suspends and resumes; [ ] both new store filenames are on
the isolation list in this commit.

---

## 6. IM-09 — Send through Messages.app by Apple Events

**Finding(s):** G2 and G3  **Effort:** 1.5 days  **Depends on:** IM-08, IM-02, IM-03
**Unblocks:** IM-10

**Goal:** send text and attachments without touching any Apple database, addressed by a target this
app can actually resolve.

**Files you will change**
- `Sources/NextNotes/IMessage/Sending/MessagesSender.swift` (new, `actor`)
- `Sources/NextNotes/IMessage/Sending/MessagesAppleEvent.swift` (new)
- `Sources/NextNotes/IMessage/Pairing/RemoteIdentity.swift` — the resolved local address (IM-02's
  chosen method; this task links it)

**Read for context:** IM-02's report `Tests/Reports/imessage-send-path.md` — the dictionary terms
are **verified there**, and they were renamed at least once. `Resources/NextNotes.entitlements`
already carries `com.apple.security.automation.apple-events`, so no signing change is needed for the
entitlement; the TCC Automation grant is a runtime prompt.

**Target behaviour**
1. `actor MessagesSender` with `sendText(_:to:)` and `sendAttachments(_:text:to:)` returning
   `OutboundDispatch`.
2. **In-process `NSAppleEventDescriptor`.** `NSAppleScript` is acceptable.
   **`/usr/bin/osascript` is not** — the app already lists `osascript` on
   `Shell/ShellExecutor.swift:7`'s `privilegedPrefixes`, so a send through it would demand approval
   on *every message*, which is the predecessor's own "no scripting" principle violated by its own
   policy. This is the one place the predecessor's "osascript only as a fallback" is wrong here.
3. `IMessageChat` carries the **AE target** alongside the `chat.guid`:
   ```swift
   struct IMessageChat {
       let guid: String            // Next Notes' join key, for filtering
       let displayName: String?
       let service: IMessageService
       let handles: [String]       // handle.uncanonicalized_id, for AE addressing
       let appleScriptTarget: String   // the term IM-02 verified
   }
   ```
   For a direct self-conversation, `handles` holds the user's own address — which is why
   **Contacts is on this path** and why `Phone-Calls` shares it.
4. The ledger row is written **before** dispatch (IM-08), and the returned `OutboundDispatch` carries
   the pending id so IM-10 can correlate.
5. A send failure is a **typed** outcome with copy a person can act on:
   *"Next can receive your messages but can't reply yet. Open Next Notes on your Mac to finish
   Messages permission."* Never a raw Apple Event error number.

**Red-first self-test:** no automatic flag. The send needs a paired conversation and a TCC grant, so
the honest test is physical:
- `--selftest-imessage-send` — `IMESSAGE_SEND_OK` / `IMESSAGE_SEND_FAILED: <reason>`, a `via-open`
  entry, run by hand and recorded in `STATUS.md`. It asserts: the text appears on the iPhone, the
  row lands in `chat.db`, the ledger row is matched rather than orphaned, and a repeat send does not
  trip the circuit breaker.
- The **unit** half belongs to IM-10's flag: the AE target is built correctly from a fixture chat,
  with the Apple Event's `descriptorForKeyword` assertions checked on a fake target.

**Verify**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-imessage-send          # by hand, --via-open
Scripts/run-selftest.sh --selftest-imessage-loop
make acceptance TIER=core
```

**Do not**
- Do not shell out to `osascript`. See (2).
- Do not write to `chat.db` to "make it look sent". Sending is Apple Events; the database is a
  consequence.
- Do not support tapbacks, unsend, edits or group addressing in V1. `00-README` §5 and the glossary.
- Do not add a display name to a message body to fake an identity. The prefix is a *format*
  (`Next · Done.`), and its shape is IM-17's, not this task's.

**Done when:** [ ] a send lands on the iPhone and in the database; [ ] the ledger row is matched;
[ ] no `osascript`; [ ] the AE terms match IM-02's report; [ ] the failure copy names the fix.

---

## 7. IM-10 — Send verification

**Finding(s):** a successful Apple Event is not a delivery  **Effort:** 1 day  **Depends on:** IM-09
**Unblocks:** IM-11

**Goal:** `dispatched` is not `landed`, and the difference is an `ActionReceipt`.

**Files you will change**
- `Sources/NextNotes/IMessage/Sending/IMessageActionVerifier.swift` (new)
- `Sources/NextNotes/IMessage/Sending/IMessageActionVerifierSelfTest.swift` (new —
  `--selftest-imessage-approval` is IM-13's; this task's cases go into `--selftest-imessage-db`
  until then, or a `IMESSAGE_SEND_OK` extension)

**Read for context (do not change):** `Agent/ActionRuntime.swift:285` `ActionReceipt`, `:329`
`ActionReceiptStore` (→ `action-receipts.json`, already on the isolation list), and `:638`
`verifyResult(tool:arguments:result:)`. The predecessor implies a parallel iMessage receipt store;
**do not build one.** The prepared-payload-equals-payload-fired guarantee is asserted in one place
today, and this feature is exactly the case where a second store would quietly break it.

**Target behaviour**
1. ```swift
   enum IMessageSendVerification: Sendable, Equatable {
       case dispatched
       case landed(messageGUID: String)
       case delivered(messageGUID: String)
       case failed(String)
   }
   ```
2. After dispatch, wait for the matching `chat.db` row: verify it exists, capture the GUID, capture
   `is_sent` / `date_delivered` when the capabilities allow, and **return an `ActionReceipt`** built
   by the existing store, with the iMessage detail as its payload.
3. `.failed` is honest. A send that Apple Events accepted and that never landed is `.failed`, not
   `.dispatched` after a timeout.

**Red-first self-test:** extend `--selftest-imessage-db` (or IM-13's flag, if it lands first).
Cases: a dispatched message whose row never appears → `.failed` within a bounded wait, **and the
test asserts the failure is not reported as landed**; a row with `is_sent = 0` → `.landed` not
`.delivered`; a receipt exists and carries the `textHash`; a crash between dispatch and verification
leaves the ledger row pending and **does not create a second receipt**; and — the one that matters —
**the receipt's payload equals the payload that was dispatched**, byte for byte.

**Verify**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-imessage-db
Scripts/run-selftest.sh --selftest-imessage-send     # by hand
Scripts/run-selftest.sh --selftest-store-isolation
make acceptance TIER=core
```

**Do not**
- Do not create an iMessage-specific receipt store. Extend `ActionReceipt`.
- Do not report `.delivered` when the capability probe says the column is absent. Degrade to
  `.landed` and say which.
- Do not retry the send on verification failure. A retry is IM-08's decision under the receipt rule,
  and it is a *person's* decision for anything consequential.

**Done when:** [ ] the five cases green; [ ] the receipt comes from `ActionReceiptStore`;
[ ] the payload equality assertion is real; [ ] a failed send never reads as landed.

---

## 8. Phase 1 exit

`make test` passes. `make acceptance TIER=core` has not regressed. `IMESSAGE_DB_OK`,
`IMESSAGE_DECODE_OK`, `IMESSAGE_PAIRING_OK`, and the two CORE flags `IMESSAGE_WATCH_OK` and
`IMESSAGE_LOOP_OK` all report `*_OK`. `--selftest-imessage-send` has been run by hand and recorded.

**The two claims that make the feature safe, each pinned by a flag:** a `from-me` row that is ours
never becomes a command *or a memory* (`IMESSAGE_LOOP_OK`), and the database is provably read-only
(`IMESSAGE_DB_OK`).

Report: `Tests/Reports/NextNotes-iMessage-P1-____.md`, with a flag → final line table before and
after.
