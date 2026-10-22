# IM-01 / Gates G1–G3 — paperwork closure, 2026-10-10

**Scope: DOCS ONLY.** No source edits, no builds, no installs, no self-test runs in this task.
This report closes the paperwork gap between the `IM-01` ledger row (`partial`, 2026-09-26)
and the `G1` gate row (`done`, 2026-09-28). It changes no code and no verdict: every
measurement below was already recorded in the three gate reports and the decoder rows.
This file only gathers them into the one place the Phase 0 exit row (`Phase gates`, Phase 0)
asks for (`Tests/Reports/imessage-gate-____.md`).

**Sources read for this report (no runs performed):**

- `roadmap/in-progress/NextNotes-iMessage/STATUS.md` — Gates rows G1/G2/G3, IM-01 row, IM-05/IM-05b/IM-05c/IM-05d/IM-05e rows, Phase gates Phase 0 row
- `Tests/Reports/imessage-self-flow.md` (2026-09-27, Q3 appended 2026-09-28)
- `Tests/Reports/imessage-send-path.md` (2026-09-27)
- `Tests/Reports/imessage-grants.md` (2026-09-27)

**Sanitised:** shapes only, as in the three source reports. No phone number, contact name,
chat identifier or message body beyond the two already-published fixture sentences
(`Hello Chikita!`, `Test intensifié` + emoji) appears here. `Tests/Reports/` is tracked.

---

## 1. G1 — self-flow (IM-01): Q1, Q2, Q3 all answered

Gate question: when the user sends an iMessage to themselves from their iPhone, what
exactly appears in `chat.db` — and is it `is_from_me = 1` or `0`?
Gate state before this report: `done` 2026-09-28. This report supplies the combined
write-up the Phase 0 row was missing; it does not re-answer anything.

### Q1 — the filter: `is_from_me` decides nothing

A self-message arrives as **TWO rows, opposite `is_from_me`, byte-identical bodies
sharing one raw timestamp**. Three captures, three separate sends, same shape
(`imessage-self-flow.md` §1; STATUS "two-row shape, reproduced twice more", 2026-09-27):

| sent from the phone | rows | `is_from_me` | body | characters |
|---|---|---|---|---|
| 25-char oracle sentence (text in `IMESSAGE_DECODE_REAL_BLOB`, not in the repo) | 55189 / 55190 | `true` / `false` | 202 B, byte-identical | 25 |
| `Hello Chikita!` | 55213 / 55214 | `true` / `false` | 189 B, byte-identical, same raw Apple-epoch integer | 14 |
| `Test intensifié` + emoji | 55215 / 55216 | `true` / `false` | 196 B, byte-identical | 17 |

Consequence (unchanged, already in IM-07): **pair by chat, never by row.** A watcher
filtering on the column answers half of every command. `is_from_me` answers "did this
Mac send it"; direction is the row's sender; the outbound ledger answers "is this our
own echo". A self-conversation is a thread addressed to the owner's own number, not a
private channel — a non-user row there is `.fromSomebodyElse` with no turn and no memory.

### Q2 — the decoder's specification

All nine captured rows agree on the header; none carries `payload_data`
(`imessage-self-flow.md` §2):

> first 16 bytes, **every row, all captures:** `04 0B 73 74 72 65 61 6D 74 79 70 65 64 81 E8 03`
> i.e. `04` · `0B` · `"streamtyped"` · `81 E8` · `03`

Streamer version 4, system version **1000 little-endian** — the shipped decoder's
default, byte-for-byte what `NSArchiver` writes. `payload_data` and `balloon_bundle_id`
are **absent on every row**, including the voice note and the reaction.

Length semantics — **byte count**, settled on a real body (`imessage-self-flow.md`
§2.1; STATUS "Bytes-versus-characters is closed", 2026-09-27): the owner sent
`Test intensifié` + emoji — **17 characters, 21 UTF-8 bytes** (one 2-byte `é`, one
4-byte astral emoji) — and the shipped decoder returned exactly that sentence from the
196-byte body. The oracle was the sender's own recollection supplied out of band, not
the decoder's output. The 25-char oracle sentence is 25 characters / 27 UTF-8 bytes
(two `é`, `0x1b` = 27 declared); three two-byte characters would be 28 bytes, so the
retired "three multi-byte characters" wording was irreconcilable with the body. An
all-ASCII sentence (14 chars = 14 bytes) **cannot** settle this, and the suite refuses
instead of passing — the refusal is the feature.

Decoder-half closure since IM-01 `partial` (why `partial` is now stale):

- **IM-05** (`0a9257b`): 22 cases + 5 `IMESSAGE_DECODE_BLOCKED:` lines deliberately
  uncounted; mutation-tested; found 7 factual errors in `TYPEDSTREAM-NOTES.md`.
- **IM-05b** (`f311cd4`, completed 2026-09-27): 9 of 9 real bodies decoded whole, no
  parser bug; byte-rewrite mutation (27→25) truncates silently with no error;
  **`IMESSAGE_DECODE_OK: 48 cases`, 0 blocked, 0 wrong** with artefacts
  (`IMESSAGE_DECODE_REAL_BLOB` + `IMESSAGE_DECODE_EFFECT_CASES`); unchanged 36 / 7
  blocked without — the count says which run is read.
- **IM-05c** (`9700abf`): an effect is a non-text balloon the roadmap's rule missed —
  owner's four effect rows have `text` NULL, `payload_data` absent,
  `balloon_bundle_id` NULL; body is an ordinary text balloon whose whole string is
  three `U+FFFC` bytes with 237 of 314 bytes unread. `MessageBody.notText` now carries
  `(bundleID: String?, discardedBytes: Int)`.
- **IM-05d** (`9c29f93`): voice-note ordering measured — **walk first** (a caption is the
  sender's words), **column last** (only signal on shapes the walk cannot reach).
- **IM-05e** (`1012830`): `is_audio_message` reads **0** on the real 466-byte voice
  note and on every captured row — Messages does not write that column for audio on
  this macOS, so the corpus `=1` case is a shape, not a measurement. Forcing it to 1
  changes nothing; the walk classifies first. `IMESSAGE_DECODE_AUDIO_CASES` deleted.

Effect vs reaction (same section, different animals): an **effect** is a text balloon
whose entire string is `U+FFFC` bytes; a **reaction** is a text balloon carrying
ordinary prose (`Liked "<sentence>"`, row 55205, 219 B). The walk reads a reaction as
`.text` — see §4 for the open classification gap this creates.

### Q3 — sleep/wake: per-message drain suffices (measured 2026-09-28)

One message before sleep, two during, capture after wake (`imessage-self-flow.md` §4):

| message | rows | characters | `attributedBody` | raw timestamp |
|---|---|---|---|---|
| first (before sleep) | 55271 / 55272 | 14 | 191 B | 812350428013682816 |
| second (during sleep) | 55273 / 55274 | 20 | 195 B | 812350885914726784 |
| third (during sleep) | 55275 / 55276 | 22 | 213 B | 812350901451834240 |

The two sleep-sent messages arrived as **separate rows with separate ROWIDs and
separate timestamps** (~155 s apart), each keeping the two-row shape. The watcher's
existing per-message handling (IM-06's ordered drain) is sufficient; IM-16 needs **no
special per-backlog drain**. Side finding (open, recency-related): `message.date`
reads up to ~6 minutes in the **future** on newest rows; Apple-epoch arithmetic is
right, so Messages writes ahead or the clock is off — check before ordering by date.

---

## 2. G2 — send path (IM-02): addressable as participant, never as chat

Gate question: how is a chat addressed by Apple Events on this macOS, and can a
self-conversation be addressed at all? Gate state: `answered` 2026-09-27
(`imessage-send-path.md`). Summary for the combined record:

- **Static half (no grant):** `Messages.sdef` carries exactly one command —
  `send` (`ichtsend`), `to` taking `participant` **or** `chat` — and four classes
  (`participant`, `chat`, `account`, `file transfer`) whose properties are all
  read-only. No `make new chat`: a conversation is addressable **by query**, never by
  construction. A `chat.guid` from `chat.db` is not convertible into a scripting
  address — there is no `chat` property taking a guid value.
- **Live half (Automation grant held):** `IMESSAGE_SEND_PATH_OK: 200 chats readable`
  (read-only probe, never calls `send`). 1 iMessage + 1 SMS + 1 RCS account; 198
  participants, **150 with a routable E.164 handle**. Of 200 sampled `chat.id`s,
  **zero carry the `iMessage` prefix** — every one is `any;-;…` — while the
  `chat.db` self-chat guid is `iMessage;-;…`. **The two namespaces do not meet: a guid
  is not an address.** The surviving route is `send … to <participant>` addressed by
  handle; the self-conversation is a thread to the owner's own number.
- **Remaining (not a grant):** the local identity in a comparable form — canonical
  comparison of `handle.uncanonicalized_id` vs scripting `handle` (IM-08c's
  blocked-on input). Until it exists, "self-chat is a participant with your own
  handle" is a measured mechanism with an unmeasured instance.

---

## 3. G3 — grants (IM-03): both held, signing threat retired

Gate question: can Full Disk Access and the Messages Automation grant be obtained, and
does ad-hoc signing make Automation unmaintainable? Gate state: `done` 2026-09-28
(`imessage-grants.md`). Summary:

- **Signing threat retired:** designated requirement is
  `identifier "ai.pivotstudio.nextnotes" and certificate leaf = H"96c8b8fa…"` — a
  real certificate leaf, not a cdhash — identical across rebuilds. Grants survive
  `make install` (`make signing-cert` already run).
- **FDA held**, proved by a live row read (`--imessage-self-flow --via-open` returned
  real rows; FDA has no query API, so `stat` passing means nothing).
- **Automation held**, proved by `IMESSAGE_SEND_PATH_OK: 200 chats readable`.
- **Launch-mode inversion** (cost an hour; opposite rules):

  | grant | direct shell launch | via LaunchServices (`--via-open`) |
  |---|---|---|
  | Full Disk Access | **denied** (responsible process is Terminal) | **granted** (app is responsible) |
  | Automation | **granted** (client is the app) | **silently `-1743`, no prompt** |

  Traps that looked like answers: bare `count of chats` fails `-2753` (AppleScript
  vocabulary, never addressed Messages); `-1743` with no dialog is a suppressed
  prompt, not a denial; `tccutil reset AppleEvents ai.pivotstudio.nextnotes` clears
  the wrong record (LaunchServices', not the app's). The probe runs **direct** and
  treats the first `-1743` as a question with retries.
- **No `+` button in the Automation pane:** FDA can be granted by hand; Automation
  appears only when the app asks, so a missing entry cannot be repaired by hand. The
  `Permissions` checklist's FDA row can offer a button; an Automation row never can —
  IM-17a's design fact.

---

## 4. What stays open — explicitly not closed by this report

1. **Experiments 2, 3, 4, 6, 8, 9, 10, 12 not run** (`imessage-self-flow.md` §5).
   Covered: 1, 5, 7, 11. The unrun set is listed, not waived.
2. **Tapback/reaction classification gap** (STATUS "A tapback is a **text** balloon",
   2026-09-27): a reaction is a text balloon with ordinary prose, so on IM-08a's table
   a `.text` body from the owner's number is `.userCommand` — reacting to a message
   or texting a tapback would be answered as a command. Prediction from a measured
   body (214-byte `Liked "…"` row), not a measured classification. Needs its own case
   and class before any bridge is built on the current table.
3. **`BLOBBODY_REAL` rename** (STATUS 2026-09-27): `firstBlobLiteral` returns the
   first row with a body, not *the* self-message body — it pointed at a reaction
   (219 B) while the self-message sat further down. Recommended small task with
   red-first case: rename to `BLOBBODY_FIRST` + header comment; `make-chatdb-fixture.sh`
   and `IMESSAGE_DECODE_EFFECT_CASES` follow the rename. **Nothing renamed here** (a
   silent fixture-generator break is worse than a documented misleading name).
4. **IM-16 production host stays `blocked`** (2026-09-30): G1-Q3's per-message-drain
   answer stands and is recorded, not lost — what is missing is entirely the
   durability layer (AGENT-OVERHAUL Phase 6 ledger/journal/recovery, TaskBridge,
   unknown-outcome reconciliation, never-auto-fire rule), not a measurement.
5. **Reader defect carried forward:** `participants` empty on all 50 printed chats
   (`ChatRow.participants` never populated; `isSelfChat` requires count == 1, so it
   is dead code on this machine) — now **IM-07's first task**, not guessed at here.
   The 2026-09-30 schema-variant note re-reads it (renamed join keys
   `message_id`/`chat_id`/`handle_id` measured live) without closing it.
6. **Recency side finding:** `message.date` up to ~6 min in the future — open before
   anything orders by date.
7. **G2 remainder:** local identity in comparable form (IM-08c input); live `send`
   words belong to a human (IM-09's; the 2026-09-30 sends at rows 55298/55299 and
   55305/55306 postdate this paperwork and are cited only to avoid confusion).
8. **Baseline gaps this report does not fill:** Messages sign-in state, `chat.db`
   presence flag, `make acceptance TIER=core` summary, AO Phase 3/P6 start status —
   the baseline table still carries its own `fill in` cells for those.

---

## 5. Decisions made in this task (every one)

1. **IM-01 `partial` → `done`, dated 2026-10-10.** The work was already done: G1
   closed 2026-09-28 (Q3 sleep/wake) and the decoder half closed 2026-09-27
   (IM-05b 48 cases, IM-05c/05d/05e). The ledger row still said `partial` with
   "Q3 partly" and "Left: run the decoder…", both stale. The date is the paperwork
   date, not a measurement date — each measurement keeps its own date in §§1–3.
2. **Evidence string cites the new gate report + 48-case decode + G1 done.**
   The old evidence's "Left" items are answered (decoder run: IM-05b; effect bubble:
   IM-05c). The new string points at this file, `IMESSAGE_DECODE_OK: 48 cases / 0
   blocked`, and the G1 `done` row so the next reader need not re-derive the gap.
3. **Baseline macOS filled as `macOS 27.0 (26A428)`.** Taken from the self-flow
   report header (2026-09-27 capture), the only pinned measurement; `sw_vers` was
   not re-run because this task performs no live probes.
4. **No source, no build, no install, no self-test run.** The gap is paperwork (a
   `partial` row vs a `done` gate); running code cannot answer it and risks
   unrelated-tree churn. Verified by `git diff --stat -- Sources/` containing no
   edit from this session (the tree's existing Sources diff is other workstreams';
   this session issued zero Source writes).
5. **Report filename `imessage-gate-2026-10-10.md`.** Fills the Phase 0 row's
   `Tests/Reports/imessage-gate-____.md` slot with the paperwork date.
6. **Row numbers, header bytes and byte-count oracle stated verbatim.**
   55189/55190, 55213/55214, 55215/55216; `04 0B "streamtyped" 81 E8 03`; 17 chars /
   21 bytes on `Test intensifié` + emoji — because those are the load-bearing facts
   IM-07/IM-08 build on, and the task required them.
7. **Open list is exhaustive, not reassuring.** Unrun experiments, tapback gap,
   BLOBBODY rename, IM-16 host, reader defect, date-future finding and G2 remainder
   are each named with owner and next step so `done` on IM-01 cannot be misread as
   done on any of them.
8. **Sanitisation held:** shapes and counts only; the 25-char oracle sentence stays
   in `IMESSAGE_DECODE_REAL_BLOB` (local artefact), never in this tracked file.
9. **`roadmap/` untouched by git.** The STATUS.md edit is working-tree only;
   `roadmap/` is git-ignored (`git check-ignore` confirms), so it is never staged.

## 6. Status updates made alongside this report

- `STATUS.md` IM-01 row: `partial` → `done`, date 2026-10-10, evidence rewritten
  per decision 2.
- `STATUS.md` Baseline table: macOS row filled per decision 3.
- `STATUS.md` Decisions: entry dated 2026-10-10 noting IM-01 paperwork closure
  changes no source (this task).
- Phase gates Phase 0 row still names `Tests/Reports/imessage-gate-____.md` as its
  report slot — the filler filename is the roadmap author's, left for them; this
  report is the content that fills it.
