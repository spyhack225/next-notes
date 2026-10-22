# Next Notes iMessage Remote Access — status ledger

**2026-10-02 current dependency update:** P6-03 is committed `1c68d3e` with37
installed actual journal/tool/approval cases and owner isolation green. P6-04a-1 held/strict-read foundation is committed `6f50e07` (56 installed cases, 12 related flags and owner isolation green); P6-04a-2 SQL authority migration is committed `5de382a` and installed (authority54/recovery56/durability37, all13 targeted flags green; parent open). P3-06a remains
open: bounded foundation `5ecc7e6` passes scripted capture/output/replay with
zero observed disagreements; physical/full-suite coverage remains open. The cited CORE15/18 is historical 2026-10-01 evidence, not a current core rerun.
Bounded typed-local attempt/receipt admission and normal typed ACP attempt admission
are now verified. ACP receipt startup admission (`e946ecd`: original65 RED9 → fixed66
worker731), completion admission (`404725b`: original67 RED4 → fixed68 worker764),
and permission selected/cancelled encoding (`4f37916`: original69 RED3 → fixed70
permission22/origin68/worker764) pass; app70 all20 focused flags pass. Those focused
checks are not CORE or model evaluations. Remote origin/attempt authority, live
lease/session/current-client authority, receipt reconciliation, crash recovery/retry,
TaskBridge, OutputScheduler and durable delivery remain open; IM-16 stays blocked.
Parent Phase6 and the unchanged quick9/full/owner/latency gates remain open.

**Model alignment, 2026-09-30:** follow the
[independent-role/shared-file contract](../SHARED-BRAIN/00-README.md).
Existing model/engine measurements below remain dated evidence. The model contract
revision changes no iMessage task states; remote turns remain Agent-role work, not a
new model assignment or authority for notes/dictation cloud uploads.

This is the only progress record. Update it after every task, following `00-README.md` §7 step 11.

States: `todo` · `red` (test written and confirmed failing on old code) · `green` (gate passed,
regressions unchanged) · `done` (committed) · `blocked` (see §BLOCKED notes).

Dates are `YYYY-MM-DD`. Evidence is the final marker line plus any measured numbers with units. The
commit is a short hash.

## Baseline

Capture once, before the first code change, on a freshly installed build of the current tree.

```bash
B=~/Library/Caches/NextNotesBuild/imessage/baseline; mkdir -p "$B"
make build && make install OPEN=0
# Only flags that exist today. The 2026-09-25 draft listed `conversation` and
# `jobs-report-does-not-exist`, neither of which is a flag; and the nine IMESSAGE_*
# flags are not registered until their tasks run.
for f in tasks scheduler memory persona ui-strings activity store-isolation; do
  Scripts/run-selftest.sh --selftest-$f > "$B/$f.txt" 2>&1; tail -1 "$B/$f.txt"
done
Scripts/run-selftest.sh --usage-report > "$B/usage-report.txt" 2>&1; tail -1 "$B/usage-report.txt"
df -h / | tail -1
```

| Item | Value |
|---|---|
| Commit (`git rev-parse --short HEAD`) | `78cebc9` (tree dirty — two other workstreams in flight) |
| Date | 2026-09-25 |
| Free disk | record it; IM-05 decodes large blobs |
| macOS version (`sw_vers -productVersion`) | macOS 27.0 (26A428) — from `Tests/Reports/imessage-self-flow.md` header (2026-09-27 capture; no live probe re-run in the 2026-10-10 paperwork task) |
| Messages signed in on this Mac | **fill in** |
| `chat.db` present (`~/Library/Messages/chat.db`) | **fill in** |
| `make acceptance TIER=core` summary | **fill in** |
| AGENT-OVERHAUL Phase 3 / P6 status at start | **fill in — IM-11 and IM-16 have soft dependencies** |

**The folder moved to `roadmap/in-progress/` on 2026-09-25** — IM-04 has no dependency since the
IM-04/IM-04a split, so code lands here and this directory is where landed code belongs. **These three
gates are still open** and the table above is how that stays visible. When a gate closes, its row
changes; no folder move is needed.

## Gates

These are not tasks and not code. Nothing in Phase 1 is safe to start until all three close.

| Gate | Question | Needs | Report | State | Date | Notes |
|---|---|---|---|---|---|---|
| **G1** self-flow (IM-01) | When the user sends an iMessage to themselves from their iPhone, what exactly appears in `chat.db` — and is it `is_from_me = 1` or `0`? | a human, an iPhone, Messages signed in | `Tests/Reports/imessage-self-flow.md` | **done** | 2026-09-28 | **Q1, Q2 and Q3 all answered.** **Q1: a self-message is TWO rows, `is_from_me` 1 and 0, byte-identical bodies sharing one raw timestamp — so the column decides nothing and IM-07 must pair by chat.** **Q2: header `04 0B "streamtyped" 81 E8 03` on every row; the length is a BYTE count, settled on `Test intensifié 🫡` (17 chars / 21 bytes).** **Q3 (sleep/wake, 2026-09-28): the two messages sent during sleep arrived as separate rows with separate ROWIDs and separate timestamps — not as a single batched row. Each message still has the two-row shape. The watcher's existing per-message handling is sufficient; IM-16 does not need a special per-backlog drain.** |
| **G2** send path (IM-02) | How is a chat addressed by Apple Events on this macOS, and **can a self-conversation be addressed at all**? | ~~a human~~ — **none needed**; the Automation grant was obtained | `Tests/Reports/imessage-send-path.md` | **answered** | 2026-09-27 | **The report exists and the grant is held.** `send`'s `to` takes a participant **or** a chat, and all four suite elements are read-only, so a conversation is addressable by query and never by construction. **200 chats readable, 1 iMessage account, 198 participants of which 150 carry a routable E.164 handle.** **The finding: not one of the 200 `chat.id`s carries the prefix `iMessage` — every one is `any;-;…`, so a `chat.guid` from `chat.db` is NOT an address.** A self-conversation is reachable only as a **participant by handle**. **Still open, and it is not a grant: the local identity in a comparable form**, which is IM-08c's blocked-on input. `--imessage-send-path`, read-only, never calls `send` |
| **G3** grants (IM-03) | Can Full Disk Access and the Messages Automation grant be obtained — and does ad-hoc signing make the Automation grant unmaintainable? | a human, System Settings | `Tests/Reports/imessage-grants.md` | **done** | 2026-09-28 | **Both grants held, signing threat retired, report file exists.** The requirement is `identifier "ai.pivotstudio.nextnotes" and certificate leaf = H"96c8b8fa…"` — a real certificate leaf, not a cdhash — so grants survive `make install`. FDA proved by a live row read, Automation by `IMESSAGE_SEND_PATH_OK: 200 chats readable`. The report carries the launch-mode inversion and the no-`+`-button finding |

## Ledger

| ID | Title | Phase | Depends on | State | Date | Evidence | Commit |
|---|---|---|---|---|---|---|---|
| IM-01 | Self-flow spike: what an iPhone self-message actually is in `chat.db` | 1 | none | **done** | 2026-10-10 | **Q1, Q2 and Q3 answered (G1 `done` 2026-09-28). Paperwork closed 2026-10-10 via `Tests/Reports/imessage-gate-2026-10-10.md`; decoder half closed by IM-05b (`IMESSAGE_DECODE_OK: 48 cases`, 0 blocked) + IM-05c/05d/05e.** Run as the app (`--imessage-self-flow --via-open`), not through a shell — a direct launch is attributed to Terminal and denied a grant the app plainly holds. **A self-message is TWO rows**, `is_from_me` 1 and 0, same 202-byte body — so the filter must pair by *chat*, never by row. Header confirmed on Messages' own output: `04 0B "streamtyped" 81 E8 03`, systemVersion **1000 little-endian**. `text` was **not** null on any of the ten newest rows. **Formerly left, now closed:** decoder run over real bytes (IM-05b, bytes-vs-characters settled on `Test intensifié` 17 chars / 21 bytes) and the effect bubble (IM-05c; reaction tapback classification gap stays open — see the 2026-10-10 gate report §4). | — |
| IM-02 | Send-path spike: how Messages is addressed here, and can a self-conversation be addressed | 0 | none | **answered** | 2026-09-27 | **`Tests/Reports/imessage-send-path.md`, and the Automation grant is held.** New read-only diagnostic `--imessage-send-path` (`MessagesSendPathProbe.swift`, `IMESSAGE_SEND_PATH_OK` / `_DENIED` / `_FAILED`) — **it never calls `send`**, and every identifier it prints is reduced to a *shape*. `200 chats readable · iMessage 1, SMS 1, RCS 1 · 198 participants, 150 E.164 handles`. **Not one of the 200 `chat.id`s says `iMessage`** — all are `any;-;…`, so a `chat.guid` is not an address and IM-09 must address a **participant by handle**. Open: the local identity in a comparable form | — |
| IM-03 | The grants ledger: FDA, Automation, and what ad-hoc signing does to IM-09 | 0 | none | **done** | 2026-09-28 | **`Tests/Reports/imessage-grants.md` exists.** Both grants held, signing threat retired (certificate leaf, not cdhash). The report carries the launch-mode inversion — `--via-open` grants FDA and **silently suppresses** Automation — and the fact that the Automation pane has **no `+` button**, so a missing Automation grant cannot be repaired by hand. The `Permissions` checklist's FDA row can offer a button; an Automation row never can. That is IM-17a's design fact | — |
| IM-04 | Read-only `chat.db`: capability probes, `PRAGMA query_only`, the query actor | 1 | **none** (split 2026-09-25) | **done** | 2026-09-25 | `1253959`. `IMESSAGE_DB_OK: 17 cases` · red first: `IMESSAGE_DB_FAILED: open: basic-text fixture did not open — IM-04 is not implemented` · **mutation-tested** — `query_only` broken → `IMESSAGE_DB_WRONG: a second connection read 0, not 1` · regressions green: `STORE_ISOLATION_OK: 14 files and 23 defaults`, `SETTINGS_OK: 12 panes`, `UI_STRINGS_OK` · `make acceptance TIER=core` **not run** — tree did not compile (CleanupRouter.swift / DictationHygieneSelfTest.swift, other workstream) | — |
| IM-04a | The Full Disk Access probe and the permissions row | 1 | IM-04 | **done** | 2026-09-26 | Probe + section in `d3211ae`, registry lines and the advice in `32174e4`/`e0038bc`, one-answer cleanup in `f176365`. `IMESSAGE_DB_OK: 26 cases`. **The probe reads one row** — that read *is* the answer, since FDA has no query API — and it is deliberately not `hasFullDiskAccess`: `chat.db` is world-readable and answers `authorization denied`, so a `stat` passes where a real read fails. The ✓ comes from a pure `MessagesAccessVerdict` a self-test can hold; case 26 mutation-checked. **Full Disk Access is the only pane with no Next Notes already in it**, so `fdaAddAdvice` names the `+` button and `fdaRepairAdvice` covers a stale entry | — |
| IM-05 | The `attributedBody` decoder: typedstream → text, refusals as values | 2 | IM-04 | **done** | 2026-09-25 | `0a9257b`. `IMESSAGE_DECODE_OK: 22 cases` + **5 `IMESSAGE_DECODE_BLOCKED:` lines deliberately not counted in the 22**. Red first by mutation (`.unreadable`→`""` reddens 5 cases). **All 5 assertions that were blocked on IM-01 are answered as of 2026-09-27** — see IM-05b and *Bytes-versus-characters is closed* below; the suite is 48 cases / 0 blocked on real bytes. Wrote the decoder and it found **7 factual errors in our own docs**; all corrected, the code is the evidence | — |
| IM-05b | ↳ Run the shipped decoder over IM-01's real bytes, and unblock what that unblocks | 1 | IM-05, IM-01 | **done** | 2026-09-26, **completed 2026-09-27** | `f311cd4`. **9 of 9 real bodies decoded whole, no parser bug.** The string length is a **byte** count: the self-message declares `0x1b` = 27 for a 25-character sentence; rewriting that one byte to 25 makes the decoder return 25 bytes with the last character gone **and no error** (mutation-proven). `IMESSAGE_DECODE_OK: 22 cases` with no artefact, **26 with** `IMESSAGE_DECODE_REAL_BLOB`. The corpus generator refuses the real hex (sanitisation guard, 11-digit runs), so no sanitised stand-in is possible and the bytes stay a local artefact. Regressions: IM-04 26, IM-06 15, `UI_STRINGS_OK`. **CLOSED 2026-09-27 — the last blocked assertions are answered, not deferred:** with both artefacts set the suite is **`IMESSAGE_DECODE_OK: 48 cases`, 0 blocked, 0 wrong**, and bytes-versus-characters is settled on real bytes with the owner's own sentence as the oracle. Unchanged at 36 / 7 blocked with no artefact | — |
| IM-04c | ↳ Fold `message_attachment_join` / `attachment` into the one place a column name is written down | 1 | IM-04, IM-06 | **done** | 2026-09-26 | `0f28544`. `IMESSAGE_WATCH_OK: 15 cases` (was 14). `AttachmentJoinResolver` no longer names a column, holds a `PRAGMA` or a column reader. **One behaviour change, safer:** `canReadAttachments` is a conjunction over both tables, so a reduced `attachment` table now answers `joinTableAbsent` where the old probe would have taken `no such column` in a watcher. **Mutation-proven** — putting `probedTables` back to five tables reddens four cases including the new one | — |
| IM-06 | The WAL watcher: a landed row becomes an envelope in ~150 ms, once, in order | 1 | IM-05 | **done** | 2026-09-25 | `3ad3c91`. `IMESSAGE_WATCH_OK: 14 cases` (CORE). Red first: 12/13 failed on the ordering case. **Per-message deadline proven, not just implemented:** rows 2 and 3 delivered at 12 ms while row 1 never settles and lands at 2037 ms (budget 8 × 250 ms = 2000 ms) — a 170× gap, and row 1 arrives **last**. **Mutation-proven** too. Event source and clock are both injectable, so no test depends on real filesystem timing. Regressions: IM-04 17, IM-05 22, `CONTENTION_OK`. **It found 2 contradictions in its own spec and 1 error in mine** — see the notes below | — |
| IM-07 | Self-channel pairing, with the filter IM-01's answer chose | 1 | IM-06, IM-01 | **done** | 2026-09-28 | `--selftest-imessage-pairing` → **`IMESSAGE_PAIRING_OK: 18 cases`**, zero blocked, zero wrong. **The filter is by chat, never by row** (IM-01's answer): a matching self-message is `text == "Hi Next"` AND `rowID > pairingStartRowID` AND the chat is a direct self-conversation (`;-;` in the guid, not `;+;`). The boundary is **exclusive** — a row at `rowID == pairingStartRowID` is refused. A group chat is refused in V1. A second pairing attempt inside the window is refused. `imessage-settings.json` round-trips through `RemoteIdentityStore` and a settings file written without the new keys decodes with defaults (`decodeIfPresent` on every field). The confirmation send is part of the gate: pairing has not succeeded until the confirmation row is observed. Regressions: IM-04 26, IM-06 15, IM-08a 14, IM-08b 15, `STORE_ISOLATION_OK: 18 files`, `UI_STRINGS_OK` | — |
| IM-08 | Classification and the outbound ledger — which gates **memory**, not only dispatch | 1 | IM-07 (and `IM-08c` on IM-02) | **done** | 2026-09-28 | **`IM-08a`, `IM-08b`, `IM-08c`, `IM-08d` all shipped.** **IM-08c:** `SelfChatMembership.swift` and `IMessageDirection.swift` — membership and direction as two pure functions. **IM-08d:** `IMessageBridge.swift` — the one actor that turns a watcher delivery into a candidate, a ledger match, a count or a card. The ledger runs first (an echo is ours whatever the body says), then the classifier, then the class decides: `.userCommand` produces a candidate and resumes the breaker; `.fromSomebodyElse` increments a counter and shows one card on the first; the rest return. The command fingerprint (a bounded set of text digests) collapses the two-row shape's second copy. `MessagesWatcherDelivery` gained `chatGUID` and `senderHandle` fields. `IMESSAGE_LOOP_OK: 19 cases` (was 15, +4 IM-08d cases). Regressions: IM-04 26, IM-06 15, IM-08a 25, `STORE_ISOLATION_OK: 18 files`, `UI_STRINGS_OK` | — |
| IM-09 | Send through Messages.app by Apple Events in-process, addressed via Contacts | 1 | IM-08, IM-02, IM-03 | **done — sent and verified** | 2026-09-28, **sent 2026-09-30** | **SENT AND OBSERVED.** `--imessage-send-test "Hi! I'm Will, your personal assistant. I'm here to help with whatever you need."` (owner-approved words in the style of the reference screenshot they supplied) → new twin rows 55298 (`is_from_me` 1) / 55299 (`0`), same 79-char text and 254-byte body. The send mechanism is `NSAppleScript` in-process under the one-time Automation grant — the raw-descriptor construction it replaced dispatched without error and delivered nothing, twice (first attempt: no row in 30 s, verified absent). `MessagesSender` is still the one sender (ledger row before dispatch, breaker, typed outcome); only the event-building changed. Regressions: all iMessage flags green (db 26, decode 36, watch 15, class 25, loop 19, pairing 18), `STORE_ISOLATION_OK: 18 files`, `UI_STRINGS_OK`, `make test` 30/30. One decode run failed mid-day on disk pressure (`unable to open database file` building a temp fixture at 483 MiB free) and passed on rerun — environmental, not code | — |
| IM-10 | Send verification: watch for the row, and produce an `ActionReceipt` | 1 | IM-09 | **done** | 2026-09-30 | **New `IMessageActionVerifier.swift` + `send-verify` fixture + 6 cases in `--selftest-imessage-db` (now `IMESSAGE_DB_OK: 32 cases`).** `verify()` polls an injected fetch for an `is_from_me` row with a matching text digest: `is_delivered` set (and the capability present) → `.delivered(guid)`; any other found row → `.landed(guid)`; bounded wait with nothing → `.failed`, never landed. Receipts come from the existing `ActionReceiptStore` (no second store): frozen intent with `arguments["textHash"]` hex, guid captured into `verification`, same-`actionID` re-record upserts (crash case). **Live proof:** `--imessage-send-test` now verifies through it and records to the shared store — twin 55305/55306 observed, receipt `tool imessage.send` on file with the textHash. Regressions: decode 36, watch 15, class 25, loop 19, pairing 18, format 8, `STORE_ISOLATION_OK`, `UI_STRINGS_OK`, `make test` 30/30 | — |
| IM-11 | Route a remote turn: `.iMessage` on `AgentUtteranceSource` + the adapter | 2 | IM-08, IM-10; soft AO P3-03b, P1-03 | **done** | 2026-09-30 | **`AgentUtteranceSource.iMessage` (the one-line change in `RealtimeAgent.swift` — nothing else touched there) + new `IMessage/Agent/`: `RemoteAgentTurn` (source computed `.iMessage`, unroutable as voice by type), `IMessageConversationMapper` (chat→session, rebinds across sessions, capped at 32), `IMessageInteractionAdapter` (record once → resolve → perform; `live()` binds the real session + entry point for the future TaskBridge). No-TTS holds structurally: every voice gate in `handle` reads `== .voice`. **5 cases in `--selftest-imessage-loop` (now 24):** record-once + `.iMessage` source, echo never performs through bridge→adapter wiring, live command performs once, session continuity + rebind, mapper bound. **Deviation recorded:** `--selftest-voice-turns` left alone — its suite is capture policy and the no-TTS property is pinned at the adapter boundary instead (VOICE_TURNS_OK unchanged). **Soft deps:** P1-03 `AgentCapabilityManifest` now exists (another workstream built it); P3-03b `TaskBridge` still absent, adapter stands alone until then. Verify: loop 24, db 32, decode 36, watch 15, class 25, pairing 18, format 8, voice-turns/conversation OK, store-isolation OK, ui-strings OK, make test 30/30, **acceptance CORE 16/17** (both iMessage entries pass; the one red is the documented standing `--selftest-wake-live`) | — |
| IM-12 | Remote authority: `ActionOriginContext` beside `ActionAuthority`, and the broker | 2 | IM-11 | **done** | 2026-09-30 | **No new authority case** (decode-compat pinned): new `Agent/Permissions/RemoteAccessPolicy.swift` holds `AgentTransport`, `ActionOriginContext` (all-`decodeIfPresent`), the four bands and two gates. Broker gains `origin:` + `remoteAccessSuspended:` (both defaulted — existing callers untouched): suspension/authority-escalation/denied-band run before grants (a grant names a tool, never a command), then auto→allow, channel→`.ask`, local→new `.askLocal`, plus standing-grants-don't-cover-remote. Executor + ACP + computer switches handle `.askLocal` (same local card today, with the IM-13 must-not-satisfy-from-phone marker). Suspension state in `imessage-settings.json` (`suspendRemoteAccess` anywhere, `resumeRemoteAccessLocally` local-only by single-writer rule); adapter short-circuits suspended turns with the paused sentence; pair-now consults `mayEnterPairing`. **11 cases in new `--selftest-imessage-authority`** (bands, sudo, no-grant-ride, review-authority, suspension, re-pair, 6-way decode, sudo predicate). Verify: authority 11, loop 24, db 32, decode 36, watch 15, class 25, pairing 18, format 8, tool-review + routine-authority OK, store-isolation OK, make test 30/30, **acceptance CORE 16/17** (standing wake-live red only). Deferred, owned: turn→executor origin threading (no live remote turns yet — adapter `live()` ready), remote grant-writing (IM-13's constraint), credential/keychain/policy tools (none exist; land denied/by-id when added) | — |
| IM-13 | Approval over iMessage: `RemotePreparedAction`, frozen, expiring, exact-match | 2 | IM-12 | **done** | 2026-09-30 | **New `IMessage/Approval/RemoteApproval.swift` (types + matcher + firer + offer card) and 12 cases in new `--selftest-imessage-approval` (CORE).** In-memory offers (a restart clears them — a reply then clarifies; approval can never outlive its payload), 10-min TTL, exact whole-message keywords, oldest-pending-on-its-chat matching, paired-channel-only, two-pending clarifies without consuming, firing hands the offered bytes to an injected deliver (other kinds `.unsupported`), receipt links by approvalID + textHash. `.phoneCall` declared with minimal `PhoneCallRequest` (Phone-Calls owns the shape); full-action Codable round-trips. Offer card wears the runtime name. Verify: approval 12, loop 24, db 32, decode 36, watch 15, class 25, pairing 18, format 8, authority 11, tool-review + persona OK, store-isolation OK, make test 30/30, **acceptance CORE 17/18** (new approval entry passes; standing wake-live red only). Not yet: live hosting (no watcher→bridge→adapter→matcher loop runs in production — IM-16's), production `.sendMessage` delivery binding, other-kind firers | — |
| IM-14 | Attachments: copy out, size limits, MIME, and never-execute | 2 | IM-13 | **done** | 2026-09-30 | **New `IMessage/Attachments/`: `MessagesAttachmentPolicy` (UTI-first kind, 25/50/100 MB limits, video metadata-only, `transfer_state` deliberately uninterpreted), `MessagesAttachmentReader` (new `attachmentRows` accessor on the database — throws when the join is absent rather than answering empty), `MessagesAttachmentCopier` (paired-chat first, realpath containment, size-before-bytes, atomic + 0600, never execute). No `MessagesAttachment.swift`: the type already lives in `MessagesQueries.swift` (moved there 2026-09-26, after the task was written). **6 cases in new `--selftest-imessage-attachment` (INTEGRATION):** byte-identical copy + hash + 0600, real `/private` resolving, over-limit with limit named, symlink escape refused with target untouched, other-chat refused unread, attachment words as tool output refused twice (injection scan + provenance) with the store empty. Verify: attachment 6, loop 24, db 32, decode 36, watch 15, class 25, pairing 18, format 8, authority 11, approval 12, file-index + memory OK, store-isolation OK, make test 30/30, **acceptance CORE 17/18** (standing wake-live red only) | — |
| IM-15 | Voice notes: an attachment that is a file, not a duplex turn | 2 | IM-14 | **done** | 2026-09-30 | **New `VoiceNoteTranscriber` (decode once → same `ChunkedTranscriber` windowing as `--selftest-transcribe`, no transcode; model call injected, no hidden default lane; segments `.mic` for "You" attribution only) + bridge hook (`voiceNoteText` closure, default nil, transcript re-enters as the row's words for classification/candidacy). No mic, hub, session or TTS path touched anywhere. **2 cases in attachment suite (now 8):** quiet-fixture transcription to the fake's words with hub consumers empty before/after, 65 s note chunked within max windows tiling input with source file byte-identical. **1 case in loop suite (now 25):** voice-note delivery performs its transcript once as `.iMessage`. Verify: attachment 8, loop 25, db 32, decode 36, watch 15, class 25, pairing 18, format 8, authority 11, approval 12, contention OK, store-isolation OK, make test 30/30, **acceptance CORE 17/18** (standing wake-live red only). One transient: a loop run hung 600 s on a leftover process, passed in seconds after cleanup — environmental, not the suite | — |
| IM-16 | Durable delivery, sleep/wake backlog, and crash-safety | 2 | IM-15; hard AO task/delivery + durable attempt/receipt/recovery contracts | **blocked 2026-09-30** | See BLOCKED note below. G1-Q3's answer stands (per-message drain suffices; no special backlog shape needed) — what is missing is entirely the durability layer, not a measurement | — |
| IM-17 | Onboarding UX, observability, metrics, and the privacy assertion | 2 | IM-16, IM-13 | **designed** | 2026-09-26 | **`IM-17-DESIGN.md`, 855 lines, written 2026-09-26.** No code, no build, no self-test. Split into **`IM-17a`…`IM-17f`** (§5) because 1.5 days was wrong for the whole of it. **The two open decisions are now decided:** the grant is asked **in a sheet from the feature's switch**, four screens, the switch is not the consent, and a refusal is one sentence (`That's fine. Dictation, meetings and your assistant all keep working — only talking to me from your phone is off.`); and the privacy assertion is enforced at **`MessagesDecoder`'s return type**, structurally, because it is the only place the blob exists as bytes and it is upstream of the classifier, the memory gate, the index, the model and the usage log. **Case 6 of `--selftest-imessage-privacy` is red until IM-08 lands, and that is correct.** §7 of `03-PHASE-2-P1-SLICE.md` was rewritten to point at the design; its 12 errors, omissions and contradictions are listed in the design's §7 | — |

| IM-17c | ↳ The privacy assertion, at the decoder's return type | 1 | IM-05, IM-17 | **done** | 2026-09-26 | `c1e08fc`. **`IMESSAGE_DECODE_OK: 26 cases`** with no artefact (was 22) and **31 with** `IMESSAGE_DECODE_REAL_BLOB` (was 26), plus `IMESSAGE_DECODE_COUNT: real body — 101 of 202 bytes passed over unread, and one named attribute is in them`. **`MessageBody` gained one field, `case text(String, discardedBytes: Int)`** — one string and one `Int`, no bag, no array of names. **The walk is anchored, not a search:** the answer is the characters of the string the body *is*, and a root that is not a text balloon is `notAString` rather than a place to keep digging. **Mutation-proven:** putting the old searching walk back answers `archiver_a_foreign_payload_is_never_the_message` with the third party's 63-byte offer, and also reddens `a_declared_length_past_the_end_is_refused` (`structureUnreadable(50)` instead of `truncated`). Regressions: IM-04 26, IM-06 15, `UI_STRINGS_OK`. **Two deviations from the design, both recorded in `TYPEDSTREAM-NOTES.md`:** the walk *did* change (the design said it would not — see below), and the field is `discardedBytes` rather than `discardedAttributeCount` | — |
| IM-17a | ↳ The consent decision, as a pure value | 2 | IM-17 | **done** | 2026-09-30 | **New `IMessage/Consent/`: `IMessageConsentState` + transition table + verbatim copy type, 11 cases in new `--selftest-imessage-consent` (INTEGRATION).** Four steps in order, no-click readable skip, granted-on-entry skip, three refusals with own reasons, later switch-on restarts identically, remote origin refuses everything, connected→off immediate, unlisted defaults to nil, no literal agent name in copy (trigger referenced as the constant, step-4 name interpolated). Regressions: persona + ui-strings OK, all iMessage flags green, store-isolation OK, make test 30/30 | — |
| IM-17b | ↳ The sheet, and the switch that opens it | 2 | IM-17a | **done** | 2026-09-30 | **New `UI/Settings/IMessageSettingsSection.swift` (switch + refusal + Stop + status, one-line registration in `AgentSettingsTab`) + `UI/Onboarding/IMessageSetupSheet.swift` (four steps on the pure machine, embedded grant section, pair-now check, approved test send verified before the switch turns on) + `Settings.imessageEnabled` key.** Red-first honored by a `--selftest-ui-strings` reference case (proven firing on an unwired tab). Deviation recorded: no 13th tab — the design's "12→13" contradicts its own "do not add a thirteenth case", so registration is proven by reference instead of count. Also repaired another workstream's `Task {}`-less `await` in the model-library branch (their `await` preserved) and taught the ui-strings verdict to count structural lines. Verify: ui-strings + settings (12 panes) + model-library OK, loop 25, store-isolation OK, make test 30/30 | — |
| IM-17d | ↳ The metrics rows | 2 | IM-17 | **done** | 2026-09-30 | **Two `UsageFeature` cases (`agent.imessage`, `imessage.event`) + new `IMessage/Observability/`: `IMessageCount` (closed per-pass vocab), `IMessageUsage` (the only writer — no text/GUID/count/hash/filename params, `errorMessage` always absent).** Both features group under Other work (explicit mapping; no fifth group). **New IM group in `--selftest-usage-log` (now 26):** per-pass round-trips with whitelisted keys only, errorMessage absent, hostile prose/guid/digits absent from encoded rows, wrong-table counts refused, group + visible-strings gates. Verify: usage-log 26, store-isolation OK, make test 30/30 | — |
| IM-17e | ↳ The canary | 2 | IM-17 | **done** | 2026-09-30 | **New `IMessage/Observability/IMessageHealth.swift` (`IMessageCanary` + pure decide + verbatim copy) and 7 cases in new `--selftest-imessage-observe` (INTEGRATION, in `IMessageReportSelfTest.swift`).** Ordinary rows never count (photos, SMS, own bounds, parsed-but-wordless); three format failures do; 9 never fires, 10/50 fires, 10/200 does not, cooldown holds then releases; copy passes the consumer lint with no agent name. Settings row + `postUnreadableMessages` (no button, stable id) added; canary window lives in `imessage-settings.json` (no second store). Verify: observe 7, ui-strings + persona + settings OK, pairing 18, loop 25, store-isolation OK, make test 30/30 | — |
| IM-17f | ↳ The report, and the one visible status row | 2 | IM-17 | **done** | 2026-10-01 | **New `IMessage/IMessageReport.swift` (pure `format` + live reader + `--imessage-report` diagnostic) and `UI/Agent/IMessageStatusRow.swift` (exactly the two §3.4 strings, wired into the activity rail).** Formatter/input split: hostile guid in, presence out (digit-runs/URLs/prefix discipline asserted); counts aggregated from usage rows with unknown keys dropped; percentiles nearest-rank (the suite caught a floor-vs-rank bug); marker EMPTY when nothing to say. Bridge stamps `lastInboundCommandAt` on accepted commands. **4 format cases join observe suite (now 11); activity suite pins both strings.** Live run: paired, readable, watermark, cloud role, canary zeros, OK 10 lines. Unapplied design asks: no `--selftest-imessage-privacy` flag exists (folded into decode long ago), so no `_ABSENT` rule to record; unhosted watcher/bridge/ledger read honestly. Verify: observe 11, activity OK, usage-log 26, store-isolation OK, make test 30/30 | — |
| IM-05c | ↳ An effect is a non-text balloon, and the roadmap's rule for it was wrong | 1 | IM-05, IM-01 | **done** | 2026-09-26 | `9700abf`. *(Row added 2026-09-26 by IM-05d — the commit shipped without one.)* **The owner's four effect rows have `text` NULL, `payload_data` absent and `balloon_bundle_id` NULL**, so the `payload_data` + `balloon_bundle_id` rule fires on none of them; the body is an ordinary `NSAttributedString` → `NSObject` text balloon whose whole string is three bytes of `U+FFFC`, with **237 of 314 bytes** unread. `MessageBody.notText` became `notText(bundleID: String?, discardedBytes: Int)` so a non-text balloon can no longer be required to name an app, and `IMessageEnvelope.discardedBytes` stopped answering `0` for every non-`.text` body. **Found a real hole in IM-17c's own leak check** — it compared maximal printable runs, so a transfer GUID that arrived without its one-byte `+` tag sailed through; now sub-runs plus a delimited-match rule, after sub-runs alone produced 9 false positives (`Message` in `IMessageEnvelope`, `ttribute` in `attributedBody`). 3 mutations, `IM-05c-red.txt` | — |
| IM-05d | ↳ A voice note is a non-`.text` balloon, and which signal says so is measured | 1 | IM-05, IM-05c | **done** | 2026-09-26 | `9c29f93`. The last blocked assertion (`voice-note-as-not-text`) was blocked on **a file restriction, not on anything unknown** — `MessageRow` did not project `is_audio_message` — so the restriction was lifted and the question answered. **The corpus `voice-note` row has no class chain to read at all:** its `attributedBody` is the two-byte `X'0001'` sentinel, the walk stops at byte 0 and refuses, so the column is the *whole* signal there — which is exactly what IM-05 recorded as a refusal. Order is now measured, not assumed: **walk first** (a caption beside the marker is the sender's words and stays text), **column last** (it only ever answers a row the walk cannot reach). One line stayed blocked, and it is the one this row created. 3 mutations + the splice table below, `IM-05d-red.txt` | — |
| IM-05e | ↳ A **real** voice note, measured — and the roadmap's named signal is not a signal | 1 | IM-05d, IM-01 | **done** | 2026-09-26 | `1012830`. The last blocked Phase 1 line is gone, and **the answer is not the one the roadmap expected**: `is_audio_message` reads **0** on the real 466-byte voice note, and 0 on every row the capture described — **Messages does not write that column for audio**, so the corpus case that has carried `is_audio_message=1` since IM-04 is a *shape*, not a measurement. The walk classifies it, and the class chain is not what says so: `NSAttributedString` → `NSObject`, byte for byte the chain a 25-character sentence and a 314-byte effect carry — the signal is the equality `U+FFFC == U+FFFC`. `.notText(bundleID: nil)`, 389 of 466 bytes passed over, ending immediately after the three marker bytes, **120 of which are Messages' own transcript of the audio** and which the walk never reads because the positive rule stops at the balloon's first string. **The column route is kept deliberately, on measured reasoning:** it is the only signal on the two row shapes the walk cannot reach (a body it refuses, a row with no body), and deleting it would turn the corpus sentinel row into a refusal, crying wolf once per audio message. What changed is the *claim* — every place that named it a signal now says what it is measured to be — and a real counterfactual pins walk-first on real bytes: **forcing `is_audio_message=1` changes nothing at all about the answer.** `IMESSAGE_DECODE_AUDIO_CASES` is **deleted** rather than left for a column that selects nothing on a real capture. **And a fourth leak hole, in the assertion rather than the code:** `nothingPassedOverReaches` scanned `blob.suffix(discardedBytes)`, so the number the check verified was choosing what it verified — a decoder reporting 250 of 466 (over half, so the magnitude bound passed) left every leak assertion green while the scan stopped covering the first 139 unread bytes, which is exactly where the transcript and the transfer GUID are. Now a property of the bytes: the three in front of the discarded region *are* the marker. `IMESSAGE_DECODE_OK: 36 cases` and 7 blocked with no artefact, unchanged; **48 cases and 0 blocked with both artefacts set** (5 lower than IM-05d's 53 because today's capture holds one text-NULL row rather than four — not a dropped assertion). Mutations M1/M1b/M3b/M4/M5/M6 + M6c in `IM-05e-red.txt` | — |
| IM-08a | ↳ What a remote message **is**, as a pure function | 1 | IM-05, IM-08 design | **done** | 2026-09-26 | `0df7941`. `--selftest-imessage-class` → **`IMESSAGE_CLASS_OK: 14 cases`**, two `IMESSAGE_CLASS_BLOCKED:` lines uncounted (`IM-08a-green.txt`). **The parameter list is the design:** `classify(body:isFromMe:sender:echo:) -> IMessageClassification` — `IMessageEnvelope` is not an input and there is nowhere to pass one, *proved by the compiler* (a temporary envelope argument was refused), and the result has three fields and no `String`, so a field added to the envelope later has nowhere to land. `MessageBodySource` likewise never arrives, **which is the whole answer to the voice-note question**: both `.notText` routes classify identically, so the still-open measurement could not change IM-08a. **`is_from_me` is never a filter** — IM-01's two rows are the *same class* with *different directions*, which is the finding turned into an assertion, and the column's power is one-directional (it can make a row the user's, never the reverse). **`.ownEcho`'s silence is four independent mechanisms**, not a comment: no echo case in the speaker enum, no echo constant in the copy, both output seams return `.nothing`, and `remoteSpeaker` is `nil`. Refusals are **direction-free** — `directionEvidence` gained a fifth case `.notConsulted` rather than fabricating a direction in the one field a report counts over. A link is content, not an instruction, and whether `browser`/`fetch` is reachable on a remote turn is `AgentCapabilityManifest`'s decision. Red first: 11 of 14 reddened on the old `00-README` §11 rule, then 18 targeted mutations each named against the case it reddened, plus two honest negatives. Verified: class 14 · decode 36 · db 26 · watch 15 · `UI_STRINGS_OK` · `PERSONA_OK` · `make test` 30 tests. **Six builds of this tree failed on another workstream's files mid-run** — all recorded verbatim, none touched here | — |
| IM-08b | ↳ The outbound ledger, the match and the breaker | 1 | IM-08 design, IM-08a | **done** | 2026-09-27 | `7e06b52`. `--selftest-imessage-loop` → **`IMESSAGE_LOOP_OK: 15 cases`**, **zero** blocked, zero wrong (re-verified 2026-09-27 on `0098a09` after a fresh `make install OPEN=0`). **CORE**, because replying to a message Next Notes itself sent is the failure the whole ledger exists to prevent. 762-line self-test + store + ledger, 1,839 lines, all additive; `SelfTestStoreGuard` extended with the one database. **The privacy claim is read off the disk, not off the type:** `UsageLog.sanitise` is blind to prose — a third party's promotional offer is prose and survives every rule in it — so case 9 builds a send from a fixture carrying an offer, a link and a file name, writes it, and runs `strings(1)` over the database **and its `-wal` and `-shm` siblings**, because a row in the WAL has not been checkpointed and a check reading only the main file would pass on a store that had just written somebody's sentence next door. Also pinned: the one-sided window (6 minutes ahead matches, 40 does not), retention (8 days), the breaker (>5 in 10 s, `> 5` on the design's own numbers), **the breaker is not persisted**, and harness isolation. **Do-nots held:** no `status`/`task` column, no file name, no text, no pending row written after dispatch. Type is `MessagesLedgerSelfTest` in `OutboundLedgerSelfTest.swift` — **the file and the type do not share a name**, which is how this row came to be reported as having no caller; it is registered at `NextNotesApp.swift:2015` and in `Scripts/acceptance.sh:123` (CORE) | |

`Phone-Calls` reuses IM-02, IM-03, IM-12 and IM-13. If you change one of those four, say so in
`STATUS.md` — the phone roadmap's V1.4 and V1.9 are not separate implementations.

## IM-05d — a leak that got through, and what it cost (2026-09-26)

`nothingPassedOverReaches` has a documented hole: a payload that arrives **spliced** onto
another value is interior to a longer identifier in the rendered value, and the delimited rule
is about delimiters. IM-05c reasoned about it. **IM-05d measured it**, on the new audio-column
route, where filling `bundleID` is the tempting wrong thing to do:

| mutation | what reached the caller | what caught it |
|---|---|---|
| M1 — search the discarded region for a long printable run | the 21-byte class name | the case's own `bundleID == nil` |
| M1b — the same, that assertion relaxed | the same 21 bytes | the leak sweep, on a whole delimited value |
| M1c — the same, pasted onto `com.apple.` | the same 21 bytes | the leak sweep: `.` is itself a delimiter |
| **M1d — the same, pasted between two letters** | **the same 21 bytes** | **nothing. `IMESSAGE_DECODE_OK: 36 cases`** |

Two things follow, and both are in the code rather than in this file.

1. **The corpus fixture could not have caught any of it.** `voice-note`'s body is two bytes, so
   there is nothing in it to leak. A leak assertion on this route only means anything over a
   body that *carries* a graph, which only `NSArchiver` can produce — and that is a claim about
   the parser's mechanics, not a claim about Messages, so the oracle is the right instrument and
   `IMESSAGE_DECODE_REAL_BLOB` would have been the wrong one.
2. **On this route the exact-value assertions are the primary defence and the sweep is the
   backstop** — the reverse of IM-17c, where a `.text` body has no second string to carry an id
   at all. A leak spliced into a longer word is not detected by any rendering-based check in this
   tree, and closing it means comparing against known values rather than a reflection, which is
   what `envelopeCarriesNoMarker` does for the marker alone.

**And a false positive worth knowing about**, because it will bite whoever writes the next
fixture: a row whose `guid` was `FIXTURE-AUDIO-0001`, read against a foreign payload whose prose
opens `FIXTURE-THIRD-PARTY-OFFER`, reports a 7-byte "leak" that is not one. Two *whole words*,
delimited on both sides by design — the exact shape the rule is built to catch, with both sides
coming from this file's own vocabulary. The repair was the fixture's, not the rule's.

**The next agent needs two things.** A voice note sent to the owner's own conversation, and
`is_audio_message` in the capture: `IMESSAGE_DECODE_AUDIO_CASES` wants a `cases.sh` block whose
audio row carries `is_audio_message=1` in its `msg` line, and IM-01's `--imessage-self-flow`
does not emit that column today. The reader that block will be read by is already
mutation-free and case-covered — the classification is the only thing waiting.


## Phase gates

| Phase | `make test` | `make acceptance TIER=core` vs baseline | Exit flags | Report | Date | Commit |
|---|---|---|---|---|---|---|
| 0 | — | — | the three reports exist and the gate row closes | `Tests/Reports/imessage-gate-____.md` | | |
| 1 | `make test` 30 tests in 2 suites, green 2026-09-26 (IM-08a's regression run) | **run 2026-09-28 — see below** | `IMESSAGE_DB_OK: 26` ✅ · `IMESSAGE_DECODE_OK: 36` ✅ / **48 on real bytes, 0 blocked** ✅ · `IMESSAGE_WATCH_OK` (CORE) 15 ✅ · `IMESSAGE_CLASS_OK: 25` ✅ (+11 IM-08c) · `IMESSAGE_LOOP_OK` (CORE) 15 ✅ · `IMESSAGE_PAIRING_OK: 18` ✅ · `--selftest-imessage-send` ⬜ needs a paired conversation + a person to approve the words | `Tests/Reports/NextNotes-iMessage-P1-____.md` | 2026-09-28 (partial) | — |

**Phase 1's CORE tier: `15/17 PASS`, run 2026-09-27** — the run owed since 2026-09-25, unblocked by
`TOOLLOOP_PRODUCTION_OK`. **Both iMessage CORE entries pass**: `--selftest-imessage-watch` (6 s) and
`--selftest-imessage-loop` (1 s), alongside dictation, capture, stream, voice conversation, acoustic
replay, duplex, action runtime, activity, meeting live, tool loop, computer use, ACP and MCP.
Logs: `~/Library/Caches/NextNotesBuild/acceptance/20260927-031406-78822/`.

**The two CORE reds are both other workstreams', and one is a documented standing red:**

| flag | verdict | owner |
|---|---|---|
| `--selftest-wake-live` | `17/24 hits, 3/32 false at sensitivity 0.6 — 0.71 under the 0.8 bar` | **Known and documented in `AGENTS.md`** — the 2026-09-22 tuning pass took the measured trade-surface maximum and the remaining fix is real-room recordings, not a lowered bar. Unchanged by anything here. |
| `--selftest-meeting-resume` | `a segment inside the interval wrote anyway (0 → 1)` | **DICTATION-MEETINGS-LIMITS** — this is M-16c's `TranscriptSaveThrottle`, whose contract `AGENTS.md` states as *"at most one write per `interval`"*. A segment inside the interval writing is that contract broken, and it is a real regression rather than an absent precondition. **New information: this flag was last recorded green.** |

Per `AGENTS.md`: a known-red entry is left red rather than special-cased green, so the tier exits
non-zero and **Phase 1 does not exit on this run.**
`--selftest-imessage-loop` (15) and `--selftest-imessage-watch` (15) are both green and both are
IM-08b's and IM-06's CORE entries. **The phase still cannot exit**: `IMESSAGE_PAIRING_OK` needs IM-07,
`--selftest-imessage-send` needs a paired conversation and a *person* to approve the words, and G1's
Q3 needs one sleep/wake experiment.
| 2 | | | every flag above, plus `IMESSAGE_APPROVAL_OK` (CORE), `IMESSAGE_RECOVERY_OK` (CORE, IM-16), `IMESSAGE_ATTACHMENT_OK`, `IMESSAGE_PRIVACY_OK` (CORE), `IMESSAGE_CONSENT_OK`, `IMESSAGE_OBSERVE_OK` (both INTEGRATION, IM-17), `IMESSAGE_AUTHORITY_OK` (CORE, if IM-12 split it), and `--imessage-report` prints honestly | `Tests/Reports/NextNotes-iMessage-P2-____.md` | | |

A CORE FAIL exits non-zero. A known-red entry is left red, not special-cased green.

## Progress — 2026-09-25

| What | State | Evidence |
|---|---|---|
| **`Tests/Fixtures/chatdb/`** — 12-case sanitised corpus + `--degraded`, deterministic | **done** | 16/16 byte-identical sha256 across runs; degraded mode confirmed to drop `attributedBody`/`payload_data`; sanitisation scanned with `strings(1)`. Transcript: `~/Library/Caches/NextNotesBuild/imessage/fixture-verify.txt`. No build was run to produce it |
| IM-04/IM-04a split so Phase 1 needs no grant | **done** | ledger, README §8/§8.1, the mermaid graph and the phase file's task text now agree. `02-PHASE-1-P0-SLICE.md` §1a is IM-04a's task section, which the split had left missing |
| Audit of this folder against the tree | **done** | ~115 checks by a sub-agent + re-verification by hand. Fixed: 2 flag typos, 6 drifted anchors, 4 wrong names, the false "Phase 1 touches no existing file" claim in 3 places, G3's target, 2 nonexistent baseline flags, 4 prose/number errors |
| Cross-roadmap file collision matrix | **done** | `roadmap/BUILD-ORDER.md` — 444 files with a writer, 12 `COLLISION`, 143 `SERIALISE`. **The usage three-way and the `CallPolicy` pair are both already coordinated in writing on both sides, so they are `SERIALISE`, not `COLLISION`.** The live one is `AgentSettingsTab.swift`, 5 writers |
| IM-04 → IM-10 implementation | **not started — queued** (as of 2026-09-25; **superseded** — checked 2026-10-04: IM-04 to IM-15 are `done` in the task table above, their sources are committed, e.g. `Sending/` and `Approval/` in `38bfccb`/`8888474`, and `action-receipts.json` holds one fired `imessage.send` on 2026-09-30) | blocked behind the two live builders, not behind a dependency. See the build lock in README §8.2 |

### Two corrections an audit forced, worth not losing

1. **`TaskBridge`, `OutputScheduler`, `TaskRecord`, `TaskDurability`, `TaskEvent`, `TaskReceipt`,
   `TaskDelivery`, `AgentDeliveryMode` and `AgentCapabilityManifest` are PLANNED, not present.**
   `grep -rl TaskBridge Sources/NextNotes` → **0 files**. They are AO's `todo` rows P3-03a/b,
   P3-04a/b, P6 and P1-03. README §4 now splits PRESENT from PLANNED, and the §4 table's
   "verified 2026-09-25" claim no longer covers them.
2. **`handle(_:source:)` is `async` and returns `AgentTurn`.** The real signature is
   `func handle(_ utterance: String, source: AgentUtteranceSource) async -> AgentTurn` at
   `Agent/RealtimeAgent.swift:262` (was cited as `:258` and treated as synchronous). `recordUser` is
   `:1208`, `runRequestedSelfTest` is `:479`.

**The tree moved a great deal while this folder was written** — AO committed `P0-20c`, `P0-12` and
the **Phase 0 gate** (`db9a84f`), so it is now in Phase 1; DM committed `D-01b`, `M-03`, `M-09`, `M-10`,
`M-12`. **`RealtimeAgent.swift` and `RealtimeAgent+ToolLoop.swift` are modified right now**, which
confirms IM-11 must stay blocked on P3-03b.

## Decisions and deviations

Record each on one line: date, task, what you changed relative to the task text, and why.

- 2026-09-30 (toolchain): **Swift 6.4 does not accept a bare `try` on a `rethrows` call with a throwing trailing closure — only `do/catch` satisfies it.** Measured six ways on minimal files: nested or top-level, `throws` or `rethrows`, trailing or explicit closure — the bare-`try` form fails and the `do/catch` form compiles. Every existing suite reads this way for the same reason (their corpus/`do` blocks); a new suite written without it fails naming the wrong line. The attachment suite carries the rule as a comment. (Side find on the way past: the suite also needs `@MainActor` for the memory APIs — that one the errors did name.)
- 2026-09-30 (prefix): **agent replies now carry the runtime name — `Will · …` — applied early from IM-13's rule.** Same Apple account renders both authors identically with no styling API, so attribution lives in content. New pure `AgentMessageFormat.prefixed` (idempotent, empty-name falls back to unprefixed, name always a parameter so no hardcoded identity), applied centrally in `MessagesSender.sendText` so digest, ledger row and dispatch all cover the final string; `IMessageSendTest` digests the same final string (drift fails loudly as a non-match). New `--selftest-imessage-format` (`IMESSAGE_FORMAT_OK: 8 cases`, INTEGRATION tier, AGENTS.md list). Full gate re-verified after the disk recovery: db 26, decode 36, watch 15, class 25, loop 19, pairing 18, format 8, `STORE_ISOLATION_OK: 18 files and 23 defaults`, `UI_STRINGS_OK`, `make test` 30/30. No prefixed send has gone out yet — the next words still need the owner's approval.
- 2026-09-30 (first send): **a `send` that dispatches without error can still deliver nothing — `.noReply` makes the silence total.** The first approved send reported `.sent` and no row arrived in 30 s (verified absent via `--imessage-self-flow`: newest row still 55296). New flag `--imessage-send-test <text>` (modifier: owner's words as the argument, no default text; sends, then watches for an `is_from_me` row with a matching text digest) and read-only `--imessage-address-probe` (`exists participant …`, booleans only). Measured: **by-name resolves, by-id is absent, and the hand-built specifier answers `-1700`** — an AERecord is not an object specifier. The send is now the by-name form via in-process `NSAppleScript` (same TCC posture as a raw descriptor — the old "no scripting" note was about the `osascript` binary, not in-process compilation), with a pure `literal()` escaper and a 30 s AppleScript timeout; `MessagesSender`'s ledger-first/breaker/typed-outcome contract is unchanged. **Retry discipline held throughout:** the second attempt went out only after the tail proved the first landed nowhere, with the same approved words. Two anomalies recorded, neither blocking: `exists participant "<chat-guid>"` answers true (against IM-02's expectation — noted, not chased), and raw Apple Events under `--via-open` get `-1743` where a direct launch is answered, while the G2 probe passed via-open on 2026-09-27 with the same cert leaf — so agent-launch-mode vs grant evaluation is still an open question, and Automation diagnostics run **direct** while FDA diagnostics run `--via-open`.
- 2026-09-30 (disk): **at 219 MiB free, `codesign` fails with "internal error in Code Signing subsystem"** — which reads as a signing problem and is a disk problem. Two stale `install-<pid>` dirs from the previous day (the kind `install-bundle.sh` reaps) freed 264 MiB and the build went green. A `--selftest-imessage-decode` run failed in the same window building a temp fixture and passed on rerun. This Mac is at 90%+ with minutes of headroom; any future mysterious failure should check `df` first.
- 2026-09-30 (pair-now fix): **`--imessage-pair-now` never ran — three compounding bugs, all in the trigger, none in the shipped tasks.** (1) It was dispatched inside `runRequestedSelfTest`, whose guard requires `SelfTest.isRunning`, which is false for any flag without the `--selftest` prefix — so the branch was unreachable and the runner waited for a verdict line that never came (the "timeout, no output"). Moved to `applicationDidFinishLaunching` beside `--imessage-self-flow`. (2) It used `print`, which under `--via-open` goes nowhere — now every line goes through `writeSelfTest` with an `IMESSAGE_PAIR_NOW_OK` / `_FAILED` marker last. (3) It read `messages(after: 0, limit: 50)`, which returns the *oldest* rows — now anchored at `latestRowID - 1000`. New file `IMessage/Pairing/IMessagePairNow.swift`; the old `runPairingTrigger` is deleted.
- 2026-09-30 (schema variant): **macOS 27 renamed the join keys, and that is measured, not guessed.** `IMESSAGE_PAIR_NOW_JOIN` printed the probed names: `chat_message_join=[chat_id,filter_action,filter_sub_action,index_state,message_date,message_id]`, `chat_handle_join=[chat_id,handle_id]` — `message_id`/`chat_id`/`handle_id` where the code (and every fixture) says `message_rowid`/`chat_rowid`/`handle_rowid`. `MessagesQueries` now resolves each join's key columns by presence, old spelling preferred, so fixture SQL is byte-identical and the self-tests stayed green (db 26, watch 15, loop 19, class 25, pairing 18). Two standing measurements are re-read by this: IM-01's "participants empty on every chat" was the probe failing to read them, not their absence — and they are *still* empty, because `chat_handle_join.chat_id` does not match `chat.ROWID`, so the handle join answers nothing on this Mac either. Pairing therefore proves the chat by **containment** (the twin's rows are found through the working message join) and takes the handle from `message.handle_id`, falling back to the holding chat's `chat_identifier` — which is what paired row 55278. `message.handle_id` did not resolve on the twin rows; whether its column is renamed is still open. `message_attachment_join` is deliberately untouched (IM-14's): guessing its new spelling would be describing, not measuring.
- 2026-09-27 (status audit): **IM-08b was reported as having no caller, and it was wrong.**
  `OutboundLedgerSelfTest.swift` declares **`MessagesLedgerSelfTest`**, not `OutboundLedgerSelfTest`,
  and the audit grepped the *file* name — so it found no caller and concluded the ledger's 762-line
  self-test was dead code, which is this folder's own recurring failure mode (`00-README` §5, and
  AGENTS.md's "a finished feature with no call site looks exactly like a working one"). **The flag
  was registered all along**, at `NextNotesApp.swift:2015` and `Scripts/acceptance.sh:123`, and
  `IMESSAGE_LOOP_OK: 15 cases` was re-verified on `0098a09` after a fresh install. **The lesson is
  the one this file keeps earning: grep for the type and the registration, not for the file name**,
  and a "dead code" claim about a landed task is a claim to verify by running the flag before it is
  written down. The one *real* gap the audit did find was narrower: `AGENTS.md`'s flag list named
  three of the five iMessage flags, so `--selftest-imessage-class` and `--selftest-imessage-loop`
  were missing from the list `00-README` §7 step 3 requires — now added.
- 2026-09-27 (status audit): **`00-README.md` claimed "Phase 1 is complete (2026-09-25)" in two
  places**, on the strength of IM-04/IM-05/IM-06, while its own Phase 1 table listed four open
  tasks. Corrected to "foundation done 2026-09-26; five tasks still open", and the Gates table's
  G1 row moved `todo` → `partial` because its question is answered even though its report file is
  still unwritten. **A gate whose question is answered but whose report is missing is not a closed
  gate**, and the distinction is the only reason the table is worth reading.
- 2026-09-25 (roadmap authoring): the predecessor
  `roadmap/todo/NextNotes_iMessage_Integration_Roadmap.md` (1,796 lines) was **deleted** and replaced
  by this folder. The substantive changes are in `REVIEW-LOG.md` §1–§3. The biggest: its
  `AgentResultBus`/`AgentJob`/`ExecutionAgent` vocabulary was replaced with AGENT-OVERHAUL's real
  types after that roadmap rejected those same names on 2026-09-25.
- 2026-09-25 (roadmap authoring): the folder is in `roadmap/todo/`, not `in-progress/`, because
  IM-01…IM-03 need a human and an iPhone and no code task can start until they close. Moving the
  folder up is a one-line change once the gate row closes.
- 2026-10-10 (paperwork): **IM-01 `partial` → `done` closes a paperwork gap, not a work gap — no source changed, no build, no install, no self-test run.** G1 already said `done` 2026-09-28 (Q3 sleep/wake) and the decoder half already closed 2026-09-27 (IM-05b 48 cases + IM-05c/05d/05e); the ledger row still said `partial` with stale "Left" items. New `Tests/Reports/imessage-gate-2026-10-10.md` gathers the G1/G2/G3 answers plus the explicit open list (unrun expts 2,3,4,6,8,9,10,12; tapback classification; BLOBBODY rename; IM-16 host). Baseline macOS filled from the self-flow header. `roadmap/` is git-ignored — this edit is never staged.


### IM-04 / IM-05 — the build blocker, resolved 2026-09-25 (kept for the next agent)

Tried: `make build` before committing, to re-verify the green run and run the task's
regression flags.
Failing line: none from IM-04. The compiler stops in someone else's file:
`Sources/NextNotes/Meetings/NotesGenerator.swift:826:22 unterminated string literal`, plus
`expressions are not allowed at the top level` on the same line.
Missing: **another workstream's uncommitted partial write.**

The line in the working tree is `n Apple Intelligence."` — the tail of a longer string, i.e. a
write that was cut off partway. `git show HEAD:Sources/NextNotes/Meetings/NotesGenerator.swift`
line 826 is clean, and the last commit touching the file is `bf8fe44` (P1-14). **So the break is
uncommitted, is recoverable from HEAD, and is not this roadmap's.** The same shape as
AGENT-OVERHAUL's 2026-09-24 note: *"HEAD without abc6535 does not compile."*

**What was verified without a build:** all four files parse clean
(`swiftc -parse -target arm64-apple-macos26.0`, 0 errors each), and the app **built and ran** them
at 22:46 to produce the 17-case green. `NextNotesApp.swift`'s only diff is the 11-line
`--selftest-imessage-db` registration block this roadmap added.

**Resolved:** the truncated write was the other agent mid-edit; by 23:19 it had finished and the file was
back to 825 lines with a valid one-line change. The build then moved on to a *different* workstream's real
errors (`CleanupRouter.swift` Sendable captures, `DictationHygieneSelfTest.swift` missing AppKit) — those are
DICTATION-MEETINGS-LIMITS' to fix, not this roadmap's. IM-04 was committed anyway: its four files are
additive, they compiled and ran green at 22:46, and they do not touch either failing file. `make acceptance TIER=core` is still owed once the tree builds.

## BLOCKED notes

Use this format for each note, newest first:

```
### IM-NN — blocked <YYYY-MM-DD>
Tried: …
Failing line: `<NAME>_FAILED: …` (output at ~/Library/Caches/NextNotesBuild/imessage/IM-NN-….txt)
Missing: <grant | device | paired conversation | owner decision | other agent's uncommitted work>
Next step when unblocked: …
```

### IM-16 — current dependency handoff 2026-10-02

Still blocked for production hosting. Agent P6-01 is now committed (`ff40a93`),
with the installed real-store restart baseline, tasks and owner isolation passing.
P6-02a's canonical SQLite mirror is committed (`670bc35`): 18 installed cases,
existing tasks and isolation of 21 files/23 defaults passed. P6-04a-2 now switches to SQL primary with tagged JSON export; P6-02b evidence/UI and parent P6-02 remain open. P3-02 interleaving and
correction safety are committed (`7e3aba1`), with three installed duplex runs and
related regressions passing. P6-03's journal is committed `1c68d3e` (37 cases),
P6-04a-1 held/strict-read foundation is committed `6f50e07` (56 installed cases, 12 related flags and owner isolation green); P6-04a-2 SQL authority migration is committed `5de382a` and installed (authority54/recovery56/durability37, all13 targeted flags green; parent open), and P3-06a bounded shadow foundation `5ecc7e6` passes scripted comparisons; physical/full-suite
coverage remains open. Bounded typed-local attempts/receipt joins and normal
typed ACP attempt/startup/completion admission are now verified; the ACP permission
wire also preserves selected/cancelled outcomes (P6-06j/P6-06k/P6-06l above). Remote
origin/attempt authority, live lease/session/current-client authority, receipt-aware
unknown-outcome recovery, TaskBridge, OutputScheduler and durable delivery remain
unverified. The cited CORE15/18 is historical; app70 all20 focused passes supply
neither a new core verdict nor model/latency acceptance. Production hosting and
automatic restart replay remain blocked.

The blocker is crash semantics: after an action fires but before its reply is
recorded, a relaunch must retain the unknown outcome and reconcile or ask again;
it must never infer “did not run” and repeat an irreversible action. Keep the
existing isolated tests while AO supplies those shared contracts. See
[IM-16 current dependency handoff](03-PHASE-2-P1-SLICE.md#6-im-16--durable-delivery-sleepwake-and-crash-safety).

### IM-16 — historical blocked audit 2026-09-30

Tried: looked for the durability layer IM-16 builds on — `TaskRecord`, `TaskEvent`
journal, `agent-jobs.sqlite`/`agent-tasks.sqlite`, `TaskBridge`, recovery planner —
in `Sources/` and in the AGENT-OVERHAUL ledger.
Failing line: none — there is nothing to run. Every P6 row (P6-01…P6-10, incl. 6A)
is `todo`, P3-03 (`TaskBridge`) is `todo`, and no durability type exists in code.
Missing: AGENT-OVERHAUL Phase 6 (6A at minimum: durable task ledger + event journal
+ recovery planner + the rule that a recovered task never auto-fires).
Next step when unblocked: IM-16 §1–4 (remote turn → spawn with ledger transport,
wake backlog drain in ROWID order with the "I'm back" reply, iMessage as
pending-delivery presenter with batching, exactly-once crash recovery) plus
`--selftest-imessage-recovery` (CORE). Nothing was hand-rolled in the meantime:
no parallel durability, no resend-on-wake. G1-Q3's finding (per-message drain
suffices) is recorded and waiting, not lost.

### A tapback is a **text** balloon, and the classifier has no case for it (2026-09-27)

Found by accident, while trying to unblock the last five decode assertions and pointing
`IMESSAGE_DECODE_REAL_BLOB` at the wrong row.

**What happened.** The owner's sentence was attested into the keyed file and the shipped decoder ran
against `BLOBBODY_REAL` from the 20:01 capture. It did not return the sentence. It returned
`Liked "Héllo - checking the café"` — **a reaction to** the self-message. The blob is **214 bytes**,
which is why it never matched the 202 the notes document: **it is not the self-message row at all.**

**Two things this settles, and one it opens.**

1. **The owner's attested sentence is confirmed, and it is not in the repo.** It is 25 characters
   and 27 UTF-8 bytes, both multi-byte characters being `é`, and the decoder reproduced it verbatim
   inside the reaction. That is the non-circular check working: their recollection, not the
   decoder's own output, was the oracle. The `25 chars / 0x1b = 27 bytes` arithmetic in
   `TYPEDSTREAM-NOTES.md` is now **attested rather than asserted**, and the "three multi-byte
   characters" wording is corrected to two in both places it appeared.
2. **The capture's window has moved past the self-message.** Its rows are **55205–55212**; IM-01's
   self-message was **55189 / 55190**. So the 202-byte body those five assertions need **is not in
   this artefact** and cannot be recovered from it — a fresh capture that includes the row is the
   only route, which is why the ask is one text message from a phone rather than a decision.
3. **The finding, and it is a real gap in IM-08.** IM-05c measured that an *effect* is a text
   balloon whose entire string is three bytes of `U+FFFC`. **A reaction is a different animal: it
   is a text balloon whose string is ordinary prose** — the reaction verb and the quoted original.
   So the walk reads it as `.text`, not `.notText`, and on IM-08a's table a `.text` body from the
   user's own number is **`.userCommand`**. Which means **texting yourself a tapback, or reacting to
   a message, would be answered as though you had typed a command** — and `00-README` §11's
   *"everything else is a user command"* is wrong for a second class of row, after the third party's
   payload found on 2026-09-26.

   **This is a prediction from a measured body, not a measured classification.** What is measured
   is the body: a reaction is a text balloon carrying the reaction text. What is *not* yet run is
   `IMessageClassifier.classify` over one, and nothing here runs it, because the class self-test is
   IM-08a's file and a case for a body nobody has captured as a fixture would be a fixture asserting
   itself. **It needs its own case, and a class for it, before IM-08d builds the bridge on the
   current table** — a bridge built now would answer a tapback.

### Bytes-versus-characters is closed, on real bytes, with the owner's sentence as the oracle (2026-09-27)

**`IMESSAGE_DECODE_OK: 48 cases`, 0 blocked, 0 wrong**, with `IMESSAGE_DECODE_REAL_BLOB` and
`IMESSAGE_DECODE_EFFECT_CASES` both pointed at the live capture. Every one of the seven blocked
lines is now a running assertion. Without the artefacts the suite is unchanged at **36 cases / 7
blocked** — the count says which run you are reading, and a blocked line that stopped being blocked
is not silent.

| measurement | on a real row |
|---|---|
| the self-message body | **101 of 196 bytes passed over unread**, and one named attribute is among them |
| the effect row (55211) | **389 of 466 unread**, ending immediately after the three `U+FFFC` marker bytes |
| `is_audio_message` on that row | **0** — the column is not a signal, restated on today's capture |
| non-text balloons found | **1**, and every one is a text balloon whose whole string is `U+FFFC` |

**The answer to the question IM-05 was blocked on, and the oracle is the point.** The owner sent
`Test intensifié 🫡` from the phone: **17 characters, 21 UTF-8 bytes** — a 2-byte `é` and a 4-byte
astral emoji, so bytes and characters genuinely differ. The shipped decoder returned exactly that
sentence from the real 196-byte body. **The expected output was the sender's own recollection, not
the decoder's output** — which is the only way the assertion is not the decoder agreeing with itself,
and it is why `text=` is a separate line in the keyed file rather than something the test derives.

**Three wrong turns got here, and the suite caught all three.** Pointed at `BLOBBODY_REAL` it
returned a *reaction* (`Liked "…"`). Pointed at the 14-character `Hello Chikita!` it **refused**:
*"the artefact's sentence is 14 bytes and 14 characters, so it cannot tell bytes from characters —
capture a body with a non-ASCII character in it"*, which is the assertion declining to conclude
something it cannot. And the first attempt matched three 196-byte bodies and took the wrong one until
each row was paired with its own annotation. **An assertion that answers on an all-ASCII sentence
would have gone green and proved nothing**, so the refusal is the feature: it is the same rule as
counting a blocked line out of the denominator.

Next: nothing. This closes IM-05b's blocked assertions and IM-05's item 2.

### `BLOBBODY_REAL` is not the real body, and it is a trap with a one-word fix (2026-09-27)

`MessagesSelfFlowReport.firstBlobLiteral` returns the **first row that has a non-empty body**, and
nothing more. The intent is stated in the code and is sound — *"so there is exactly one place in the
block a human copies hex into"* — but the **name reads as *the* real body**, which everywhere else
in this folder means one specific thing: the self-message `attributedBody` the decoder assertions
run against.

**It cost a wrong turn, and it will cost the next agent the same.** On 2026-09-27 the owner sent a
fresh self-message and the capture was regenerated; `BLOBBODY_REAL` came back as **219 bytes** — the
*reaction* to the earlier message, which is the oldest row in the window — while the self-message the
whole exercise is about sat two rows further down with its own inline hex. The decoder ran against
the reaction and reported, correctly, that it had been handed `Liked "…"`.

**Recommended, as its own small task with its own red-first case:** rename it to
`BLOBBODY_FIRST` and add a line to the block's own header comment saying which row it is and that
**the self-message row is not necessarily it** — the newest self-message moves with every message
sent, so naming a row is the only stable handle. The rename is **not** a one-liner in practice:
`make-chatdb-fixture.sh` resolves `$BLOBBODY_REAL` when the block is pasted in, and
`IMESSAGE_DECODE_EFFECT_CASES` reads the same block, so both follow the rename or the block stops
working. **Nothing was changed here on the way past** — a rename that silently breaks the fixture
generator is worse than a misleading name that is at least now written down.

### The two-row shape, reproduced on a fresh row (2026-09-27)

The owner sent a new self-message from the phone and the capture was re-run
(`--imessage-self-flow --via-open`, 02:06). **IM-01's headline finding held on a row nobody had
seen before:** the message landed as **two rows, 55213 `fromMe=true` and 55214 `fromMe=false`, the
same 189-byte body and the same timestamp** — the raw Apple-epoch value is identical on both. So
*pairing by chat and never by row* is not a quirk of the first capture, and `is_from_me` still
decides nothing about which copy this is. This row is **14 characters**, which also gives the decoder
a second attested shape to work against: the first capture's 25-character sentence exercised a
multi-byte length, this one does not.

Next step when unblocked: one text message from the owner's phone into the paired conversation, then
`--imessage-self-flow --via-open` again, and the freshest row is the self-message.

### The two-row shape, reproduced twice more (2026-09-27)

The owner sent two further self-messages from the phone and the capture was re-run each time
(`--imessage-self-flow --via-open`). **IM-01's headline finding held on every row nobody had seen
before**, three captures running:

| sent | rows | body | characters |
|---|---|---|---|
| `Hello Chikita!` | 55213 `fromMe=true` · 55214 `fromMe=false` | 189 B, identical, **same raw timestamp** | 14 |
| `Test intensifié 🫡` | 55215 `fromMe=true` · 55216 `fromMe=false` | 196 B, identical | 17 |

So *pairing by chat and never by row* is not a quirk of the first capture, and `is_from_me` still
decides nothing about which copy this is. **The two messages also gave the decoder two attested
shapes to work against** — the 25-character sentence with two `é` (27 bytes) and this 17-character
one with a 2-byte `é` and a 4-byte astral emoji (21 bytes) — which is what finally made
bytes-versus-characters answerable rather than merely arguable.

Next step when unblocked: nothing for the two-row shape. G1's **report file** is still owed.

### The tool-roster red was one prompt with two budgets — resolved, and the real number found (2026-09-27)

**`TOOLLOOP_PRODUCTION_OK`.** The red was never the tool roster. It was **one prompt carrying two
different budgets**, two hundred lines apart in the same file.

`RealtimeAgentToolLoopSelfTest.swift:733` held the conversational first pass to `persona + 1_500`
while the `PROMPT_SIZE` check held *the same prompt* to **4,500**. A 4,229-character pass satisfied one
and failed the other, and the failing message said *"the conversational prompt still carries the full
tool roster"* — **which was false, and the roster was never in it.** A budget that disagrees with
itself produces a red that names the wrong thing, which is worse than a tight one: it sends the next
person to look for a leak in a prompt that has none.

**Fixed as one constant, `voiceFirstPassBudget = 4_500`, at two call sites**, so the next person who
moves it moves it once. **And the previously untested half was added** — a voice turn that wants no
tool, which must not reach the catalogue at all, held to the *same* budget rather than a stricter
invented one, because a second number would be the mirror image of the mistake just fixed. The old
check could only ever see a tool-shaped utterance, so *"the speech path does not pick up the roster"*
was asserted exclusively about a turn that legitimately has one.

**What the red was hiding, now measured** — `--selftest-voice-grounding` prints the apportionment:

```text
PROMPT_SIZE: planner=5452 chars over 63 tools, first-pass=4229, spoken-answer=1787
PROMPT_SIZE_PARTS: first-pass persona=999 grounding=639 rules=2587 memory=0 capabilities=0 skills=0
```

**The rules block is 2,587 characters — 61% of the whole first pass, and three times the persona
and four times the grounding.** That is the prompt a person is waiting on, so it is the latency
story, and it is the next lever on the spoken path. **`memory` is 0 on this machine, so a Mac with
memory carries more again.**

**Not touched here, deliberately.** 2,587 characters of voice-routing rules is content someone chose,
and `AGENTS.md` is explicit that the persona and rules blocks carry decisions ("no technical detail
or jargon", "no filler or flattery") that a size-driven edit would quietly undo. Trimming it is a
judgement about what the voice path may say, and it does not belong in the same turn as a budget
fix. **It is now measured, named, and apportioned, which is what the next owner needs.**

**This also unblocked `--selftest-store-isolation`**, the CORE entry that was reading FAIL because
`StoreIsolationSelfTest.swift:44,49` runs this suite with `_ = await` and the sub-test's `print`
landed after the marker. `STORE_ISOLATION_OK: 17 files and 23 defaults unchanged` is now the last
verdict token again.

### `--via-open` and the Automation grant are opposite rules, and getting it backwards costs an hour (2026-09-27)

Obtaining the Messages Automation grant on 2026-09-27 took four runs and a wrong turn, and the
reason is that **the launch rule for Full Disk Access is the exact inverse of the rule for
Automation.** This is the single most expensive thing learned in this phase and it is worth more
than any individual gate answer.

| grant | direct launch from a shell | via LaunchServices (`--via-open`) |
|---|---|---|
| **Full Disk Access** | **denied** — TCC blames the *responsible* process, which is Terminal | **granted** — the app is the responsible process |
| **Automation (Apple Events)** | **granted** — the *client* is the app that sent the event | **silently `-1743`, no prompt at all** |

**Why they differ.** FDA is keyed to the *responsible process* — who launched the binary — so
LaunchServices must be in the chain or the grant is somebody else's. Automation is keyed to the
*client* — the process that actually sent the Apple Event — so the prompt belongs to the app, and
`--via-open` inserts LaunchServices as the responsible process, which is precisely what stops the
prompt being presented. A direct launch makes Next Notes both, and the grant lands on the first try.

**Three things that each looked like the answer and were not**, recorded because the next agent will
meet them:

1. **A bare `count of chats` never asks for anything.** `NSAppleScript` compiles against *AppleScript's*
   vocabulary, not the target's, so it failed with `-2753, "The variable chats is not defined"` — a
   script error, not a permission one. It never addressed Messages, so it never provoked a prompt.
   `tell application "Messages" to …` is what makes the event leave the process.
2. **`-1743` with no dialog is not evidence of a denial.** It is what a suppressed prompt looks like.
3. **`tccutil reset AppleEvents ai.pivotstudio.nextnotes` changed nothing** — for the same reason. The
   record it clears belongs to Next Notes; the record that mattered belonged to LaunchServices. **A
   probe that resets the wrong row looks exactly like a probe whose grant cannot be obtained.**

**And the asymmetry that makes this a product problem, not a testing one.** The Automation pane has
**no `+` button.** Full Disk Access can be granted by hand; Automation cannot — an entry appears only
when an application asks. So a missing Automation grant **cannot be repaired by hand at all**, and the
only route is a prompt a person has to be alive to answer. The `Permissions` checklist's FDA row can
therefore offer a button and an Automation row never can, which is a design fact rather than an
omission, and it belongs in IM-17a's consent sheet.

**What the probe now does about it:** `--imessage-send-path` is launched **directly**, and the first
`-1743` is treated as a *question* rather than a result — it prints a waiting line, sleeps, and asks
again up to four times, because the first attempt is the one that raises the prompt. An app that asks
once and exits has declined to give the person a chance, and the grant then never appears in the
list at all, which is exactly what the Automation pane was showing.

### The tool-roster red was a misapplied bound, and behind it is a real one (2026-09-27)

`--selftest-toolloop-production` had been red since 2026-09-26 with
`RealtimeAgentToolLoopSelfTest.swift:733`, *"conversation prompt still carries the full tool roster
(4229 chars, persona 999)"*. It also made `--selftest-store-isolation` (a **CORE** entry, and IM-08b's
own regression flag) read FAIL, because `StoreIsolationSelfTest.swift:44,49` runs that suite with
`_ = await` — the result is discarded but the sub-test **prints**, so the process's last verdict token
was the wrong flag's.

**The assertion was wrong, not the code.** It held the round-1 system prompt to
`persona + 1_500` — the *header* pass's bound — on a voice turn whose utterance is **"tell me which app
is frontmost"**, a request for a tool and therefore a planner turn whose first pass is the planner
prompt and is *supposed* to carry the fitted roster. It failed at 4,229 having found nothing wrong
with anything: a correct planner prompt inside a header's budget.

**Fixed by branching on the thing the check was about** — whether the roster is in the prompt, read off
the prompt — instead of on an assumption about which pass this is. Where the roster is required it is
held to the **planner's 8,000**; where it is not, to the header's 1,500. **This is a bound change and
a reviewer should check the reasoning rather than take it.**

**And the half that was never tested is now written, and it found something.** The old check could
only ever see a tool-shaped utterance, so *"the speech path does not pick up the roster"* was
asserted exclusively about a turn that legitimately has one. The new case runs a voice turn that
wants no tool — and it passes the roster assertion while **failing the size assertion at the same
4,229 characters**.

**So the roster was never the story.** The speech path's first system prompt is **4,229 characters on
every voice turn, tool-shaped or not**, and it is not the tool roster. It comes from
`AgentPromptContext.assemble(.toolLoop, rules: voiceRoutingRules(voice:))`
(`RealtimeAgent+ToolLoop.swift:883`), so the ~3,230 non-persona characters are grounding, rules and
memory by `AgentPromptPath`'s budget — **not yet apportioned, and apportioning it is
AGENT-OVERHAUL's call rather than a guess from here.** For contrast the planner side is healthy:
`PROMPT_TOKENS: 1894 for 24 tools`, `FITTED_PROMPT: 4 round(s), worst total 3076 tokens of 4,096`.

**The new case is left red on purpose.** A known-red CORE entry stays red rather than being
special-cased green, and a speech-path prompt that is 4,229 characters before a single word is spoken
is worth one honest red more than one quiet threshold.

### Phase 1's `make acceptance TIER=core` is blocked on another workstream's red (2026-09-27)

Tried: `make acceptance TIER=core`, owed to this phase since 2026-09-25, now that the tree compiles
clean.
Failing line: `TOOLLOOP_PRODUCTION_FAILED` — the last verdict token in the process
(`~/Library/Caches/NextNotesBuild/imessage/status-check/tlp.txt`).
Missing: **another workstream's fix.** It is not an iMessage defect and nothing in
`Sources/NextNotes/IMessage/` is involved.

**The assertion** is `RealtimeAgentToolLoopSelfTest.swift:733` — *"conversation prompt still carries
the full tool roster (4229 chars, persona 999)"*, which requires the voice path's first system pass to
be under `persona + 1,500` characters and is 3,230 over. The file is `Sources/NextNotes/Agent/`, last
touched by `1c6e9e8` (2026-09-26, *"the Agent was inventing a mail filter the user never asked for"*)
— AGENT-OVERHAUL's P1-02/P1-13 territory. **It reproduces on its own**:
`Scripts/run-selftest.sh --selftest-toolloop-production` is `TOOLLOOP_PRODUCTION_FAILED` with no
iMessage flag in the command line, so it is a standing red rather than interference.

**And it is why `--selftest-store-isolation` cannot be read as its own result**, which matters here
because store-isolation is a **CORE** entry *and* this roadmap's own IM-08b regression flag.
`StoreIsolationSelfTest.swift:44,49` deliberately runs `ModelRoleSelfTest.run()` and
`RealtimeAgentToolLoopSelfTest.run()` with `_ = await` — the result is discarded, but the sub-test
**prints**, so the process's last verdict token is `TOOLLOOP_PRODUCTION_FAILED` rather than
`STORE_ISOLATION_OK`. The store-isolation assertion itself passed:
**`STORE_ISOLATION_OK: 17 files and 23 defaults unchanged`** (IM-04's baseline said 14 files; the
three that arrived since are other workstreams' stores, and `imessage-outbound.sqlite` is IM-08b's).
The acceptance classifier keys on the **last** verdict token, so this entry reads FAIL however green
its own marker is.

Next step when unblocked: the owner of `RealtimeAgentToolLoopSelfTest.swift` fixes the voice first
pass (or the assertion's bound). **Nothing here is edited on the way past** — §"the build blocker is
recurring, and it is never ours" applies to a test as much as to a build. The three-line fix is
elsewhere's call about whether the roster belongs in the voice prompt at all.

### IM-05 — what the next agent inherits (2026-09-25)

**Green:** 22 cases. **Blocked, and named so the count stays honest:** 5, all printed as
`IMESSAGE_DECODE_BLOCKED:` and none counted in the 22.

1. a real `attributedBody` — needs IM-01 Q2 experiment 1
2. the `both-paths` **positive** half — its structure, column equality and row B's refusal are green; only
   the real bytes are missing
3. `text` taking precedence over a decoded stream — needs a **14th** fixture case that does not exist
4. the effect bubble — needs IM-01 experiment 11 (the `reaction` tapback stands in for the assertable half)
5. `voice-note` as `.notText` — the corpus README is **wrong**: `MessageRow` does not project
   `is_audio_message`, so nothing distinguishes it from a text body that failed to decode. Fixing it
   means a projected column in `MessagesQueries`, which IM-05 was not allowed to edit.

**The lesson worth keeping:** writing the decoder found seven errors in the design note it was built
from — `0x87` is a reserved tag, the system version is read from offset 13 rather than living at
14–15, the prefix claim was false, and four more. Two of those had been carried as settled for days.
`TYPEDSTREAM-NOTES.md` now separates **measured** (Apple's encoder, on this Mac) from **still open**
(what Messages writes), because a note that over-claims is worse than no note.

**Do not close a blocked line with an oracle case.** `NSArchiver` is used in the test on purpose and
pins the parser's mechanics; it is not evidence about Messages' own layout.

### The build blocker is recurring, and it is never ours

It has now appeared three times, each time in a **DICTATION-MEETINGS-LIMITS** or **AGENT-OVERHAUL**
file, and each time cleared without this roadmap doing anything:

| when | file | error |
|---|---|---|
| 22:32 | `Meetings/NotesGenerator.swift:826` | unterminated string literal — a **truncated write**, the agent's tool call died mid-edit; finished at 23:19, 825 lines, valid |
| 23:30 | `Formatting/CleanupRouter.swift:1931`, `Support/DictationHygieneSelfTest.swift:218` | Sendable closure captures, argument order, `NSPasteboard` not in scope |
| after `abc5933` | `Formatting/IncrementalCleanup.swift:98` | assigning non-escaping parameter `rules` to an `@escaping` closure |

**The rule that follows, because getting it wrong twice is expensive:** a build error outside
`Sources/NextNotes/IMessage/` is **not** this roadmap's to fix. Do not revert it, do not
"repair" it to unblock yourself — the first entry above looked exactly like a dead file and was a
live agent's half-finished edit 47 seconds old. Verify with `git show HEAD:<file>` whether the break
is committed or in the worktree, record it verbatim so the owning workstream gets the file:line, and
retry with backoff. IM-04 and IM-05 were both committed while this was true, on the evidence that
their files are additive and had compiled and run green.

### IM-06 — three things it caught, all now recorded (2026-09-25)

1. **The spec contradicted itself on the settling race.** Requirement 4 said "waits 100–250 ms"
   *and* "8 retries / 2 s maximum". Only the top of that band satisfies both. Fixed in the spec:
   250 ms x 8 = 2 s exactly, so the retry **count** is the harder number and the **interval** is what
   bends. Two numbers written independently is how they drift.
2. **"Process in ROWID order" and "must not block the next message" are not both satisfiable.** A
   row 1 that never settles *is* a 2 s block on row 2. The spec now says what the code does:
   **processing** is strictly ROWID, **delivery** is in order for rows ready inline, and a row
   waiting on its join is delivered when it settles, flagged `deferred: true`, without holding the
   rows behind it. The guarantee is processing order, not completion order — and the mutation that
   collapses it produces `delivery order is [1, 2, 3]`, which is the failure the assertion exists to
   catch.
3. **My own acceptance tier was wrong and the subagent said so rather than editing it.** I anchored
   the move on `selftest-contention`, which is in **EXPERIMENTAL**, not CORE — so IM-06 landed in
   the wrong tier. Fixed, and then *verified by parsing the arrays* rather than trusting the anchor
   a second time: `--selftest-imessage-watch` is CORE, the other two iMessage flags INTEGRATION.

**Known debt, not folded in on purpose:** `MessagesQueries` claims to be the only place a Messages
column name is written down, and `probedTables` does not list `message_attachment_join` or
`attachment`. The watcher therefore carries its own probe and its own names, and says so at the
break. Restoring the invariant is a small change to IM-04's two files — deliberately a **separate**
task, because one task rewriting another's committed files is how a roadmap stops being able to say
what is done.

### Commit-hygiene incident: I did the wave commit to somebody else (2026-09-25)

Commit `32174e4` is mine and its message is accurate about the iMessage work — but it also
swept in **another workstream's `--live-mail` registration** in `NextNotesApp.swift` (the
`GWS_LIVE_MAIL` reading block, ~20 lines). I did exactly what finding C3 warns about: I checked the
diff with `head -8`, the extra hunks were below the cut, and I staged the whole file.

**Consequences, stated plainly:**
- That work is now in history under my commit message. Its owner should **not** re-commit it, and
  should know their message will not describe it.
- It is **not reverted**, and deliberately so: removing it would break a live workstream's flag, and
  rewriting shared history with four orchestrators running is far worse than a mislabelled commit.
- The five IM-04a source files were themselves swept into `d3211ae` by a wave commit from the other
  direction, so both directions of this have now happened on this branch.

**The rule, for whoever reads this next:** a per-file `git diff | head` is not a check. Either diff
the **whole** file and read every hunk, or stage with `git add -p` / a blob-level index write the
way the iMessage commits did. The isolated-index method used for `1253959`, `0a9257b` and `3ad3c91`
is what makes this impossible; I abandoned it for `32174e4` because the diff *looked* clean.

### IM-01 — partial, 2026-09-26: the app did it, no Terminal involved

Full Disk Access granted to Next Notes, and `--imessage-self-flow` read the real `chat.db`
read-only **as the app**. Note the launch: `Scripts/run-selftest.sh --via-open`. A direct shell launch
reported the same `authorization denied` while the grant was already on, because TCC blames the
*responsible* process and that was Terminal. The grant was never wrong; the launcher was.

**Answered:**
- **Q2, the header.** `04 0B "streamtyped" 81 E8 03` — streamerVersion 4, systemVersion **1000**
  little-endian. Identical to what `NSArchiver` wrote, so the shipped version gate is correct.
- **The "14th case" exists in bulk.** All ten newest rows had `text` **and** `attributedBody` set.
- A 97-line sanitised fixture case was generated automatically at
  `~/Library/Caches/NextNotesBuild/imessage/self-flow-case.sh`, with `REDACTED-*` placeholders, so no
  hex is ever transcribed by hand.

**Q1 — ANSWERED, 2026-09-26, and it is not the one either guess would have given.** The user
messaged themselves from the phone. The message landed as **two rows** with identical 202-byte
bodies and opposite flags: `55189 fromMe=true` and `55190 fromMe=false`. So `is_from_me` does not
identify a self-message at all, and **IM-07's filter must pair by chat, never by row.** Guessing
`is_from_me = 1` would have shipped a watcher answering half of every command.

**Still open, and it is now a decode rather than a permission:**
- Bytes-versus-characters is **answered by running the decoder over the real 202-byte body**, not
  by comparing file size to the sentence — the stream is an attribute graph, so the length that
  matters belongs to the string object, not the file. The text is 25 characters with **two**
  multi-byte characters in it, so the case is in hand. **Corrected 2026-09-27 from "three":** the
  owner's own sentence, attested against the decoder, is 25 characters / 27 UTF-8 bytes with two
  `é` and nothing else above 0x7F. Three two-byte characters would be 28 bytes, and a three-byte
  character would be 29, so the old wording could not be reconciled with the `0x1b` = 27 the body
  declares. **The sentence is not written here** — it is in `IMESSAGE_DECODE_REAL_BLOB`, and it
  stays out of the repo.
- The real body carries a live promo URL and a third party's offer, so it stays a **local artefact**
  (`~/Library/Caches/NextNotesBuild/imessage/self-flow-case.sh`) and the *answer* goes in
  `TYPEDSTREAM-NOTES.md`. The corpus keeps synthetic placeholders. This is also the first evidence
  that a self-chat body can carry a third party's promotional payload, which IM-08's classifier and
  IM-17's privacy assertion both need to know.

**Side finding:** `message.date` read up to ~6 minutes in the future on the newest rows. Not a
conversion bug — the Apple-epoch arithmetic is right — so either Messages writes slightly ahead or
the clock is off. Worth one look before anything depends on recency ordering.

### The permission surface, audited for a person who is not technical (2026-09-26)

Asked for because a grant the app does not explain is a grant that stays off. Every row below is a
place a person can be stuck, and each one says the **exact next click**.

| grant | asked where | how | stuck? |
|---|---|---|---|
| Microphone | first run, `dictation` step | the OS prompt | opens the pane if refused — the prompt only ever appears once |
| Accessibility | first run, `dictation` step | prompt + pane | **yes, covered** — `accessibilityRepairAdvice` for the "switch looks on but nothing works" case |
| Calendar | first run, `meetings` step | the OS prompt | opens the pane if refused |
| System audio | first run, `meetings` step | provokes the tap, then the pane | honest "ask", never a false ✓ — no query API exists |
| Notifications | first run, `meetings` step | the OS prompt | its own Settings extension, not a privacy pane — `openNotificationSettings` knows that |
| Google Workspace | first run + Settings | installs Google's own tool via a `.command` file | one double-click, no Terminal typing |
| **Full Disk Access** | **Settings only** — see below | the button opens the pane | **was NOT covered; now is** |

**The gap that was found and fixed.** Full Disk Access is the *only* pane where Next Notes is not
already listed, so every other row's "flip the switch" advice is wrong there — the task is pressing
`+` and picking the app out of a file browser. The row was a button that opened a list containing
nothing and said nothing about what to do with it. `fdaAddAdvice` now names the control; after a
press the line becomes `fdaRepairAdvice`, because a stale entry (a Full Disk Access entry is a
*path*, so an entry made against an earlier build keeps its switch on while the database stays
unreadable) is the other explanation and has a different fix. The owner's own System Settings
showed three entries for this app, which is exactly the confusion that string exists to defuse.

**Still true, and deliberate: FDA is not in first-run onboarding.** The iMessage feature is opt-in,
and `AGENTS.md` is explicit that safety lives at the boundary, not in the path of everything — a
first-run person is asked for nothing they have not yet asked to use. **Now designed, 2026-09-26:**
the grant is asked in context, in a sheet presented from the feature's switch, and the switch
becomes *on* only when the sheet connects. See `IM-17-DESIGN.md` §1 and §5 (IM-17a/IM-17b). The
one honest gap left in the onboarding story is now a specified task rather than a roadmap task.

### IM-17 — designed, and what the third party's payload means (2026-09-26)

`IM-17-DESIGN.md` is written. Two decisions are closed and one contradiction this roadmap has been
carrying is now on the record.

**The finding, in one sentence.** On 2026-09-26 IM-01 read a real `chat.db` and found that one
`attributedBody` on this Mac contains, inside a single stream, an `NSMutableString`, five `__kIM*`
attribute names, a **link-preview URL**, a **detected-entity list**, a `com.apple.*` **bundle id**,
and **a third party's promotional payload carried as its own nested object with a nested string and
a date range** (`TYPEDSTREAM-NOTES.md`, *The stream is an attribute graph, not a string*).

**What it means for IM-08 (the classifier), and this is the part that changes a rule.** A Messages
conversation with yourself is a thread addressed to your own phone number, so **a row in it can be
from somebody else** — and IM-01 measured the same fact from the other side: one self-message, two
rows, opposite `is_from_me`. So the paired chat is not a private channel, and
`00-README` §11's *"everything else is a user command"* is **wrong for it**. `00-README` §13's
glossary already carries the right vocabulary — `.user` / `.otherParticipant` / `.nextNotes` — and
this note is the correction to §11. **Being in the paired chat is necessary and not sufficient for
`.user`.** How IM-08 establishes direction is still IM-08's decision, from IM-01's evidence; the
ledger match decides *is this our echo*, and direction decides *is this the user*, and `is_from_me`
decides neither. A non-user row in the paired chat must be `.otherParticipant`, must produce no
`MemoryEntry`, and must produce no turn.

**What it means for IM-17, and why the task is not a formality.** IM-17's own three original
assertions — a non-paired chat returns nothing, the bridge always passes the paired `chatGUID`, a
second paired chat cannot be added without a local act — **would all have gone green with the third
party's payload fully readable inside the paired chat.** The privacy claim therefore has a second
half, and its enforcement point is **`MessagesDecoder`'s return type**: `MessageBody` has exactly
one string in it, it is the one the sender typed, and it is upstream of the classifier, the memory
gate, the knowledge index, the model prompt and `usage.jsonl`. Structural, not a scrubber — a
denylist is a bet on the current macOS release, and the measured graph held a nested object whose
shape nobody here knows.

**The other half of the finding is about the sanitiser, and it is a hole.** `UsageLog.sanitise`
strips quoted content, addresses, URLs, paths and six-digit runs. **A third party's promotional
offer is none of those — it is prose, and it survives every rule in the function.** `sanitise` is
excellent at identifiers and blind to prose, and the content most likely to appear in this feature's
failures is prose. So `errorMessage` is **absent on every iMessage row** and the reason is an
`UsageErrorClass`; enforcement is at row construction, because at sanitisation it is already too
late. A case in `--selftest-imessage-privacy` proves it with the real string in hand.

**And a gate nobody has to build, because it is a sentence.** The canary now has a threshold, two
destinations and its copy: only the three `MessageDecodeFailure` cases that mean *the format
changed* count — **not** `.notText`, which is a photo or a tapback and is a successful
classification, and not `.absent`, `truncated` or `tooLarge`. Threshold **≥ 20 % over 24 h and at
least 10**, 24 h notification cooldown. Details and the exact words in `IM-17-DESIGN.md` §4.

**What IM-17c needs before it can be green.** The real 202-byte body was deliberately not
committed — the local artefact at `~/Library/Caches/NextNotesBuild/imessage/self-flow-case.sh`
carries a live promo URL and a third party's offer. IM-17c's first commit is the **sanitised** 14th
case at `Tests/Fixtures/chatdb/` (sender's sentence verbatim, URL and offer replaced with
`REDACTED-*` sentinels, and a file listing the sentinels so the sanitisation is checkable). Until
it exists `--selftest-imessage-privacy` prints `IMESSAGE_PRIVACY_ABSENT: …` and **never OK**.

### IM-17c — the walk had to change, and why the design thought it would not (2026-09-26)

`IM-17-DESIGN.md` §5 (IM-17c) says: *"`MessagesDecoder.swift` (one field, `discardedAttributeCount`, counted in the
existing walk — **the walk does not change**)"*. It is the one instruction in the task that could not be
followed as written, and the reason is worth the paragraph.

**What the design believed.** §2.3: *"the decoder walks the streamer's object graph **to the top-level
`NSMutableString`**, returns that one string, and returns a refusal for everything else."* That is a
description of a walk with a destination.

**What the code did.** `string(inObjectAt:)` had no destination. It opened an object, read a field, and
if the field was an object it **descended**, and if that nested object produced no string it **carried
on with the parent's next field**. That is a search, and a search over a graph that carries a third
party's payload can land on that payload: `__kMSHSMessage`'s first field is its own nested string, so
the offer is reachable and the old rule would return it as the message. IM-17c's own fixture proves
it — `NSArchiver` writes a non-balloon object whose first field is a 63-byte offer, and the mutated
build answers with the offer.

**So the change is the minimum that makes the design's own sentence true**, and nothing else moved:
one object, one field, one string, and a refusal for a root that is not a text balloon or a nested
object that is not a string. The version gate, the shared tables, the byte-counted length, the class
chain and every refusal case are as they were, and the real-body count moved from *nothing* to 101 of
202, which is a change in what is *read* and not only in what is returned.

**The field's name is the other deviation, and it is the design's that is wrong.** The design asks for
`discardedAttributeCount`, on the grounds that *"it is a volume, so a macOS update that starts
attaching twenty attributes per message is visible"*. A count of **attributes** is not obtainable
without modelling the attribute grammar, and §1.4 of `TYPEDSTREAM-NOTES.md` is the reason: the tail's
**first frame on the real body is a two-character type tag (`iI`) this decoder does not name**, and
reading past it means guessing a width, which is how a length-driven parse becomes a plausible wrong
answer. A count of **names** is the denylist bet the whole design refuses. So the count is
`discardedBytes` — exact, no guess, about the format rather than about anybody's message — and the whole
202-byte body is annotated in `TYPEDSTREAM-NOTES.md` so the next agent can check the arithmetic.

**Two facts the fixture measured that are now in `TYPEDSTREAM-NOTES.md` §"a walk is not a search":**

1. **Even the plainest real body carries a named attribute.** The 202-byte self-message's 101 unread
   bytes hold an `NSDictionary` keyed by `__kIMMessagePartAttributeName`, and the key appears **twice**
   — once as the dictionary's key, once as a `char *` inside the value. It is the plain end of the
   measured range: no link preview, no detected entity, no bundle id, no third party.
2. **`NSArchiver` raised an `NSException` at a self-test fixture and terminated the process.** The
   stand-in object did not say `: NSCoding`, so its `encode(with:)` was never bridged to
   `encodeWithCoder:` and the archiver raised `unrecognized selector` — uncaught, uncatchable, no verdict.
   That is §2.2's argument in miniature, on this machine, in a test rather than in the read path.

**Not built here, and why.** The design also asks for `--selftest-imessage-privacy` with six cases.
**Not added**: cases 1, 2, 4, 5 and 6 need IM-07, IM-08, IM-12 and IM-17d, — registering a new flag means
editing `NextNotesApp.swift` and `Scripts/acceptance.sh`, which `00-README.md` §7 makes single-writer —
and §2.4's own marker is `IMESSAGE_PRIVACY_ABSENT` until a `self-flow-real.REDACTED` fixture that §7 of
`TYPEDSTREAM-NOTES.md` proves **cannot be generated** (the corpus sanitiser refuses the real hex; a
faithful stand-in *is* the hex). A CORE gate that can only ever print `_ABSENT` tells a reader nothing.
The design's own instruction for this task's half — *"`--selftest-imessage-decode` gains the discard case
and stays at one final marker"* — is what was followed. **The flag's registration is handed to the
orchestrator with IM-17d's.**

### IM-17c shipped — `c1e08fc`. The safety property the feature rests on.

`MessageBody.text(String, discardedBytes: Int)`. One string, one `Int`. No bag, no dictionary, no
array of names, and `IMessageEnvelope` derives both `text` and `decodeState` from it, so a new string
field becomes a **compile error** at every `case .text`.

**The mechanism is a positive rule, and that is the whole design decision.** The answer is the
characters of the string the body *is* — the first string-typed field of an object whose class chain
names it a text balloon — and the walk **stops there**. A root that is not a text balloon is
`notAString`; a nested object that is not a string is `notAString`, not a place to keep digging. The
only names in the decoder are *recognitions* that say what a body **is**, so a macOS that attaches a
ninth attribute changes nothing here: the walk never reads it.

**It was tempted to write a denylist twice and did not, and that is the finding worth keeping.**
Once to skip `__kIMMessagePartAttributeName` — a bet on this release. Once to tell "this is a
balloon, that is a payload" — which needs a grammar-aware skipper, because the tail's first frame on
the real body is a two-character type tag (`iI`) the decoder cannot name. Instead the walk reports
unread **bytes**: exact, guess-free, and it grows when macOS attaches more.

**Measured on the real 202-byte body: 101 of 202 bytes passed over unread**, and one named attribute
is among them. The oracle bodies scale the way they should — 0 attributes → smallest count, 1 → more,
3 → more — all decoding to the same sentence.

Counts: `IMESSAGE_DECODE_OK` **22 → 26** with no artefact, **26 → 31** with it. Blocked 6 → 7 and 2 → 2.
Every assertion has a named mutation: restoring the searching walk reddens
`archiver_a_foreign_payload_is_never_the_message` with *"a foreign object answered as the message —
63 bytes"*, and a count that does not move with the graph reddens the growth case.

**Nothing third-party reaches a caller, a log or a usage row.** The count is an `Int`; no hash of
content is computed anywhere; the fixture offer and link are `example.invalid`. The negative assertion
compares printable runs from the *discarded* region and prints only counts and lengths.

### The measured find that justifies the hand-written parser, in miniature

**The fixture terminated the test process.** `NSArchiver` raised
`-[… encodeWithCoder:]: unrecognized selector` on a class that had not declared `: NSCoding`, and a
raised `NSException` **cannot be caught in Swift**. This is exactly the argument in
`TYPEDSTREAM-NOTES.md` §2.2 for refusing the system API — reproduced at fixture scale, on a class we
wrote ourselves. It is the strongest form of that argument: the failure is not hypothetical, it is
what the only supported reader actually does.

### What IM-17c deliberately did not do, and why

- **No `--selftest-imessage-privacy` flag.** Its cases need IM-07, IM-08, IM-12 and IM-17d, and
  §2.4's own marker is `_ABSENT` until a `self-flow-real.REDACTED` fixture that
  `TYPEDSTREAM-NOTES.md` §7 proves **cannot be generated** — any body with this structure *is* this
  hex, so the sanitiser's guard kills it. A CORE gate that can only print `_ABSENT` says nothing, so
  the assertions went into `--selftest-imessage-decode` instead, which is what the design's own
  instruction for this half said. The flag's registration is handed over with IM-17d.
- **The design said the walk does not change, and it had to.** §2.3 describes the walk as going *to*
  the top-level `NSMutableString`, while the shipped walk was a search with a fall-through — so the
  design's own sentence was untrue of the code. The change is the minimum that makes it true.
- **`discardedBytes`, not `discardedAttributeCount`.** An accurate attribute count needs the skipper
  the design refuses, because getting it means naming attributes.

### IM-08 — designed, and the two rules that changed under it (2026-09-26)

`IM-08-DESIGN.md` is written. The task's own answer to "what is a remote turn" was wrong in two
places, and both were already disproved by measurements in this file — which is the argument for
reading the notes before implementing rather than after.

**Rule one, and it is the task's headline: the ledger match is not the direction.** The task's order
diagram is `matched → .nextNotes / not matched → .user`, and that answers *two* questions with one.
The ledger answers **"is this row our own echo"**; **"is this row from the user"** is a different
question with a different input — the row's **sender**, not a column. The proof is IM-01's two rows:
**one self-message arrived as `55189` `fromMe=true` and `55190` `fromMe=false`, same 25-character
sentence, same 202-byte body.** A flag that cannot tell which copy of a message it is looking at
cannot be the direction. So: the ledger decides *echo*, the sender decides *direction*, and
`is_from_me` decides neither — it only contributes "this Mac sent it". The design keeps both rows
classified `.userCommand` and collapses them into **one** turn by content, and a foreign row becomes
`.fromSomebodyElse`, which `00-README` §13's glossary has carried all along and §11's "everything
else is a user command" contradicts.

**Rule two, and it is IM-05c's measurement, not a design preference: the `payload_data` +
`balloon_bundle_id` pair cannot be how a classifier recognises an effect.** The task wrote
`payload_data present + balloon_bundle_id set → .notText(bundleID:)`, and on the owner's four measured
effect rows **both columns are NULL** — a classifier reaching for that pair recognises **nothing**.
An effect is an ordinary `NSAttributedString` → `NSObject` text balloon whose entire string is
**`U+FFFC`** (3 bytes, Apple's marker for "an attachment is here"), with **237 of 314 bytes passed
over unread**. `02-PHASE-1-P0-SLICE.md` §2 already corrected itself on 2026-09-26 to say the pair is
not the *only* route; what was never written down is that it is **not the route for the case a
classifier most needs to recognise**, and `is_audio_message` is a second independent one. A voice note
takes the same class, and a bundle id is now `String?` because nothing names an effect. **The design
makes the class a function of `MessageBody` alone**, so `MessageBodySource` cannot reach it — which
is why the still-blocked real-voice-note measurement can change IM-15's *handling* and **cannot change
IM-08**.

**Three decisions worth carrying forward, because each is a refusal designed rather than assumed:**

- **A refused case says nothing on the remote side and everything on the local side.** Four of the
  six classes produce no turn, so no tool is reachable and no proposal is possible; a stranger's row
  gets a card on the Mac and **silence on the phone**, because a refusal is an answer and an answer
  confirms the channel exists.
- **`UsageLog.sanitise` is not the ledger's control, and the task text says it is.** The task's "Do
  not" list says every metrics row goes through the sanitiser. A third party's promotional offer is
  **prose**, and it survives quoted content, addresses, URLs, paths and six-digit runs. The ledger's
  answer is an **allowlist**: nine fields, every one a number, a digest, an app-minted id or a closed
  enum, **no free `String` at all**, one `insert`, and a case that writes a row built from a fixture
  carrying a promo string, a body and a file name and then reads the file with `strings(1)`.
- **The pairing rule is frozen at pairing and never re-derived.** A chat that later gains a second
  handle stays paired, and the gained handle is a *number* in `--imessage-report` and nothing else —
  because a foreign row is refused by the row-level sender test whether the chat has one participant
  or three. Re-deriving membership on a poll would revoke a working feature on an event the person
  neither caused nor can see.

**`AgentCapabilityManifest` is present, not planned.** `IM-17-DESIGN.md` §0 and the IM-08 brief both
record it as AO `P1-03`, `todo`. It is in the tree at `Sources/NextNotes/Agent/AgentCapabilityManifest.swift`
with its self-test, and `AGENTS.md` now names it as the one source of truth for what a turn may do.
**The design leans on it for one thing** — whether a link inside a remote turn can reach `browser` or
`fetch` — which is the right place for that answer, and a tool list inside the iMessage feature would
be the second one `AGENTS.md` forbids. IM-17's §0 needs the same correction.

**Still assumed, and the assumption is named.** `message.handle_id` has never been captured beside
`handle.uncanonicalized_id`, so its sender-vs-recipient semantics are unmeasured; the two readings
**coincide for both cases this feature sees**, so the rule is written for both and neither changes a
class. Whether the two copies of a self-message share a `message.guid` is also unrecorded — if they
do, `MessagesWatermark`'s guid cache already collapses them, and if they do not, the design's
command fingerprint does. `IM-08c` is **`blocked` on IM-07 and IM-02** until the local identity has
IM-02's canonical form; it is not `red`, because a membership case written without it would be
dishonest rather than failing.
