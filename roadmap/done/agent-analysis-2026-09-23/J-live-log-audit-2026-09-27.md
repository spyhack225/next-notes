# J — What the owner's real Agent logs show, 13–27 Sep 2026

Read-only audit of `~/Library/Application Support/Next Notes/`, done on 2026-09-27. Nothing there was
modified. Quotes are the owner's or the Agent's own words, kept short; people are not named, and no
email content or address is reproduced.

**Examined.**
- `agent-audit.jsonl`: 690 rows. That is 225 user requests (158 spoken, 67 typed), about 265 real
  replies, 38 wakes, and about 61 rows written by self-tests.
- `action-receipts.json`: 76 receipts. 30 completed, 43 failed, 3 could not be verified.
- `agent-tasks.json`: 35 tasks.
- `metrics.jsonl`: 513 rows, 23–27 Sep.
- `usage.jsonl`: 13 rows, 26–27 Sep.
- `agent-memory-review.json`: 200 runs.
- `next-memory.json`: 2 memories.
- `knowledge.sqlite`: **0** conversation chunks.
- `agent-conversation.json`: one session, 27 Sep.

**Models seen.** Qwen3-4B-Instruct-2507 on the local llama runtime, Apple Intelligence, OpenRouter
(rate-limited), Codex (out of quota), Claude Code via ACP, and the local voice front-end model.

**Caveat on the 27 Sep session.** The installed app was replaced at 07:11Z, ten minutes after the
session ended, so its exact build is unknown. P1-11 (`fd8ebc3`) was committed at 18:57Z on 26 Sep.
L1 below is still a gap whatever the build, because P1-11's phrase list cannot see it (§Coverage).

## Findings

| ID | Behaviour | Count | Dates | Severity | Evidence (short) |
|---|---|---|---|---|---|
| L1 | Invented emails (senders, subjects) with no mail read, then confirmed "I pulled the latest messages directly from your inbox" | 5 replies, 1 session | 27 Sep 06:54–07:01Z | High | No tool row and no `toolsProposed` in usage; no `search_email` receipt that day |
| L2 | Said it had done things it had not ("Opening Chrome…", "Showing you the latest messages", "ran the calendar tool", "7,831 files searched") | ~7 | 15, 20, 24, 27 Sep | High | audit vs receipts |
| L3 | "Summarise my emails" never succeeded | ~11 attempts, 0 successes | 14–27 Sep | High | the combination of L1, L4, L6 and L14 |
| L4 | "I don't have access" while the tool was on | 22 | 14–27 Sep | High | "Please paste the text" said 5×, while the owner said "Check your tools" |
| L5 | Offered instead of acting; "yes" and "go for it" ignored | 9 | 22, 27 Sep | High | 27 Sep: "Want to see the latest messages?" 3×, after P1-02 and P1-07 |
| L6 | Timeouts, including on "Hi" (18.7 s) and "Can you hear me?" | 15 | 14, 15, 26 Sep | High | one "Timed out on search_email" whose receipt had completed |
| L7 | Model and runtime failures shown to the owner | 19 replies, 6 failed loads, 31 memory-review failures | 14–24 Sep | High | before the Phase 0 fixes |
| L8 | Replies cut off mid-sentence without saying so | 2 | 24 Sep | Medium | "…install tools, and" |
| L9 | Internals shown or spoken: tool markup, raw tool ids, Gmail ids read aloud, provider errors, a prompt fragment, "0 results from memory" | ~40 | 14–27 Sep | Medium–High | the 27 Sep Portrait draft is a raw `<tool_call>` block |
| L10 | Heard its own voice as the owner; one search looped 11× in 4 minutes | 6 requests | 14 Sep | High | before AEC landed (16 Sep) |
| L11 | Answered side talk; 13× the same line with a **wrong time** ("1:45 AM on 2026-09-23" at about 21:10 local) | ~52 utterances in 7 episodes | 15–24 Sep | High | therapy-style replies to a building-repair conversation |
| L12 | "Can you hear me?" handled badly ("I don't have ears", "didn't catch that" 5×) | 16 asks | 14, 22 Sep | Medium | |
| L13 | Wrong tool or arguments: a sentence used as a document id and **approved**; a 2023 agenda for "today"; the wrong app | ~12 | 13–24 Sep | High | `append_doc` with id "You open Google Chrome" |
| L14 | Invalid Gmail queries; "unknown sender" on every read | 5 queries; 12 of 12 reads | 14–26 Sep | High | fixed by P1-09; not seen since |
| L15 | Old context bleeding in: "Hi" answered with the last search; an investor memory pushed into side talk | 4 | 23–24 Sep | Medium | |
| L16 | Identity and tone: called itself "Next Notes", mixed up "you"/"I", recited the persona, catchphrases, could not name its model | ~10 | 22–27 Sep | Medium | |
| L17 | Memory review: 200 runs → 4 saved; 33 unrequested "forget" attempts, 17 on one fact; a product setting saved as a personal fact; **other people's speech kept in its request list** | — | 22–26 Sep | Medium (privacy) | |
| L18 | Tasks started from chatter; 3 then failed "quit while running"; one garbled ACP reply | 24 voice tasks | 14–24 Sep | Low–Medium | |
| L19 | Self-test rows in the owner's logs | ~61 audit rows, 9 tasks | 13–14 Sep | Low | before P0-11 |
| L20 | **Past conversations are never indexed or kept** | 0 of ~18 ended sessions | throughout | Medium | `agent-conversation.json` holds only 27 Sep |
| L21 | Knowledge search finds nothing | 9 of 10 searches returned 0 hits | 23, 27 Sep | Medium | embedder off; L20 empties the corpus |
| L22 | Approvals: the one Workspace write card had a nonsense target and was approved in ~8 s; "Open Chrome" was refused with no card | 2 | 20 Sep | Medium | no Workspace write has ever succeeded |
| L23 | Multi-part requests half done | 4 | 14, 22 Sep | Medium | |
| L24 | Wake word: 6 false wakes flagged; misses never logged | 6 | 13–23 Sep | Medium | |
| L25 | "This takes a few steps" notice with no steps | 1 | 27 Sep | Low | P0-22 misfire |

**Latency.**
- Typed request to reply: median 6 s, 90th percentile 18 s. The 27 Sep session's median was 13 s.
- Spoken through the model: median 7 s, 90th percentile 18 s. Through the local front-end: median 2 s.
- Qwen3-4B planner: first token median 8.3 s.
- Prefill: median 4.5 s. The prompt prefix was reused on 7 of the 12 passes measured.
- 27 Sep: the model **reloaded 4 times in 16 minutes**.
- Speech stops about 11 ms after an interruption.

**What the logs cannot tell.**
- There is no turn id joining the audit, usage and metrics rows.
- No card shown, dismissed or expired events are recorded.
- No "conversation cleared" event is recorded.
- Missed wakes and speech-recognition confidence are not logged.
- Spoken text is not recorded separately from shown text.
- The audit log is capped, so anything before 13 Sep is gone.
- Self-test rows are not flagged in the audit log.

## Coverage against AGENT-OVERHAUL (2026-09-27)

| Finding | Status | Where |
|---|---|---|
| L7, L10, L14, L19 | **Fixed**, with a gate | P0-01…P0-14, P1-14 and AEC (16 Sep), P1-09, P0-11 |
| L12 | Fixed | 09-22 gate reversal; `--selftest-voice-turn-routing` |
| L25 | Minor; the notice rule is P0-22's | — |
| **L1** | **Marked done, still open → P1-24.** `ToolClaimGuard.claimPhrases` (`Agent/ToolClaimGuard.swift:40-46`) are fixed first-person verbs ("i ran", "i searched", "i checked", "i read your", …). "I pulled … from your inbox" is not one, and a list of invented items with no claim verb at all is invisible to it | P1-11 (done `fd8ebc3`) |
| **L5** | **Marked done, still open → P1-24.** `PendingAction.offerPhrases` (`Agent/PendingAction.swift:51-52`) has "want me to" but not the elliptical "Want to see …?", so no pending action is set and "go for it" has nothing to carry | P1-02, P1-07 (done) |
| L2 | Partly: P1-11 covers verb claims; "Showing you…"/"Opening…" are present-tense and not matched | P1-11 |
| L9 | Planned: P1-10b (todo). The Portrait pass path is **not** in P1-10b's scope | P1-10b |
| L6 | Planned, late: typed-planner latency has no Phase-1 task; P2 is voice-first | P1-06 (done), Phase 2 |
| L8 | Partly: `finishedByLimit` exists for notes and OpenRouter; the local Agent reply path does not say "cut short" | P0-17 |
| L11, L18 | Planned, late | P3-10 (Phase 3), P3-05 |
| L13 (date) | **P4-01 moved into Phase 1** (owner, 2026-09-27) | P4-01 |
| L13 (arguments) | Filed | **P1-25** |
| L15, L16 | Planned, late | P1-11 (history), P4-03 (identity, persona scoping) |
| L17 | Privacy filed | **P1-30**; the review's quality stays P4-11 |
| L20, L21 | **Traced:** **Clear conversation** deletes every indexed conversation, not a failure to index; the 0-hit searches are most likely empty queries from opening the screen | **P1-26**, P1-29 |
| L22 | Planned | P1-16, P1-19 |
| L23 | Planned, late | P6-10 (6B) |
| L24 | Known red; misses are unlogged | `--selftest-wake-live`, `--wake-mic-record` |
| Prefix reuse missed on 5 of 12 passes; 4 reloads in 16 minutes | **Traced:** context growth wipes the cache, the prompt's middle varies per request, and the 4 loads were 4 processes | **P1-28** |
| Logging gaps | Filed | **P1-29** |

Filed on 2026-09-27: P1-24…P1-30, P4-01 moved into Phase 1, the P1-10b amendment, and Phase 1 gate item 2b. See REVIEW-LOG §9.
