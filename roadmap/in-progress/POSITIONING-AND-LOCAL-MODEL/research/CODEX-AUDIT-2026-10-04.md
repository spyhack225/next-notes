# Codex audit: is the AGENT-OVERHAUL agent on track? (2026-10-04)

Read-only audit by a Claude session, written at about 20:15 EDT on 2026-10-04. Nothing was built,
run, staged or messaged. Codex's files, worktrees and relay inbox were left untouched; the inbox
was only listed, and its acked flags were not changed.

**Evidence used.**
- The five Codex rollouts named in the brief, streamed into a compact event list:
  - root `serial-root` (`rollout-2026-09-30T15-16-27`);
  - its long-lived subagents `/root/closure_frontier` (Maxwell, 10-01T19-26-22),
    `/root/agent_closure_audit` (Euclid, 10-02T03-20-36) and
    `/root/acp_unverified_receipt_audit` (Anscombe, 10-02T08-00-40);
  - the separate UI/website Codex session `codex:01a0ee02` (09-29T12-32-23).
- `git log`, `git status`, `git diff` and `git worktree list`.
- `agent-relay agents`, `agent-relay status` and `agent-relay inbox --as serial-root` (read only).
- The AO roadmap files, AGENTS.md, and the POSITIONING ledger and gates analysis.

**Conventions.** Times are EDT unless marked Z (UTC). Tool-call classes come from a regex
classifier over the `exec` commands, so they are approximate. Inter-agent message bodies are
encrypted in the logs; only their counts are used.

---

## Verdict

**Not on track for the owner's current priorities, and not efficient.** Codex is working hard:
21–22 active hours a day and about 10,000 tool calls on 10-04 alone. It is also careful, and its
fixes are real producer fixes with original→fixed proof.

But since 10-01 roughly half of its effort has gone into a durable-jobs, ACP and receipt
correctness frontier (Phase 6). None of the four personas will touch that frontier soon. It has
produced:
- no movement on the quick gate (4/10 → 3/10 → one killed run; no quick run at all on 10-04);
- none of the five ranked gate fixes (`ToolClaimGuard`, `AgentAccountRead`, `AgentRefusalGuard`,
  `WakeWord*` and the live-eval harness have no diff);
- no commits for about 47 hours;
- no install for the owner since 10-02 21:23.

The process itself has become the product. Per slice it now runs:
- original/fixed staged pairs, with build numbers up to **app438**;
- "qualified" result JSONs;
- frozen peer-review "packets" with SHA manifests over 1,140+ compiler inputs;
- 20–30 "related flag" reruns.

The verification archive this produced is **1.1 GB** inside the iCloud-synced repo, on a
16 GB / 256 GB MacBook Air that has **3.7 GiB free**.

## Top findings

1. **The work does not match the owner's priority.**
   - Share of Codex's progress messages that are about P6 durable/receipt/ACP/lease work:

     | Day | P6 share |
     |---|---|
     | 10-01 | 42% |
     | 10-02 | 46% |
     | 10-03 | 33% |
     | 10-04 | 54% |

   - Share about the quick gate or tool quality: 4% on 10-02, **0%** on 10-03, **1%** on 10-04.
   - The word "receipt" appears in 553, 750 and 1,544 assistant messages on 10-02, 10-03 and
     10-04.
   - The quick gate is the owner's stated bar (4/10 → 9/10). The gates analysis gives five
     ranked producer fixes, the two cheapest being XS and S. None of them has started.
2. **Process overhead dwarfs code change.**
   - On 10-04, of 10,208 tool calls:

     | Activity | Calls |
     |---|---|
     | Reads | 3,828 |
     | Inter-agent messages | 2,961 |
     | Hash/compare | 1,167 |
     | Evidence/roadmap writes | 723 |
     | Builds/self-tests | 285 |
     | `apply_patch` edits | **20** |

   - Calls mentioning a packet or manifest: 20 on 09-30, then 610, 1,134 and 1,532 a day from
     10-02 to 10-04.
   - Since 09-30, self-test Swift outweighs product Swift. Committed: +19,985 self-test lines
     vs +12,641/−1,822 product. Uncommitted: 22,029 of the 26,089 new untracked Sources lines
     (84%) are `*SelfTest.swift`.
3. **Nothing has been committed or installed for about two days, and the pending pile is large.**
   - Last commit: `f4d2a16`, 10-02 20:52. Last install: 10-02 21:23.
   - Pending tracked work: 225 modified files, +13,684/−3,927 lines. Sources alone account for
     192 files, +12,277/−2,110. Ten files (+880) are partly staged.
   - Pending untracked work: 232 paths. They include 83 new self-test files and about 23,600
     evidence files under `Tests/Reports/agent-overhaul-closure`.
   - That untracked new code includes `OutputScheduler.swift` and `TaskBridge.swift`, which
     AGENTS.md already describes as the existing seams.
   - Codex's own diagnosis, 10-04 22:03Z: "staging these files wholesale would combine work from
     multiple owners."
4. **Codex is not reading the Agent Relay.**
   - `serial-root`'s relay status was last updated at 2026-10-03T00:52Z. Its task line still
     reads "Next actual Based-on UI approval/result handoff under frozen packet review".
   - 15 inbox messages sent since 10-03 00:58Z are unacked, including both `claude-positioning`
     messages (22:03Z and 22:29Z, `notified: []`).
   - `claude-positioning` and its message text appear **0 times** in any of the five rollouts.
   - Codex now talks to the UI agent only through the Codex TUI thread tool, so the relay it
     built on 10-02 at the owner's request is effectively off for it.
5. **The machine is its own bottleneck, and Codex adds to it.**
   - Load average was about 180 at 22:55Z on 10-04, by Codex's own snapshot, with about 7 GB of
     compressed memory.
   - Timeout strings in tool output rose from 34 to 75 to 138 a day between 10-02 and 10-04.
   - The quick gate's own timeouts come from this load (gates analysis §5.7). Quick162 was
     killed, −9, before scoring.
   - Disk is at 3.7 GiB free. That is below the app's own 5 GB meeting-audio guard.
   - Codex reclaimed 3.3 GiB of worktrees and builds when the owner asked on 10-04, but kept
     adding staged bundles: app436, app437 and app438 at about 207 MB each.
   - It also keeps 1.1 GB of evidence inside the iCloud tree, which AGENTS.md warns slows every
     build.

---

## 1. What Codex worked on, and what the owner asked

The owner's messages are in the root rollout. Times are EDT.

| Day | Owner asked | Codex did | Match |
|---|---|---|---|
| **09-30** | 15:17–16:37: align roadmaps; one shared model file per module; then "What about AGENT-OVERHAUL?" → "go for it." | 9 commits. P1-31a/b/c (Needle first steps, honest stops, mail grounding, explicit memory saves at the producer), MOD-01, SB-01a, F-01a/b. 7 quick runs. | **Good.** Quality-gate work, small slices, committed. |
| **10-01** | 22:13 (09-30): "fix at the producer" rule. 00:00: "can we continue without 9/10?" → yes. 00:54: "So you were doing nothing. Why?" 01:34: iMessage agent blocked on IM-16, which needs Phase 6. 10:52: goal "finalize this roadmap… deploy as many parallel agents". | 28 commits: P6-01…P6-04a (SQLite task ledger, journal, held restart, authority migration), voice shadow reducer, P4-04a/P4-07a/P4-12, CU-05, P0-20a. Committed +151.8k lines, of which **131k were `Tests/Reports`**. | **Partly.** P6 was pulled forward legitimately to unblock iMessage hosting (IM-16). The quick gate stopped being worked. |
| **10-02** | 01:07–01:33: build a cross-agent channel. **03:18: "you got distracted again… delegate… focus on your main goal."** 03:19: full access, deploy agents. 13:08: continue. 15:11: more parallel. 15:58: "what are you waiting for?" | 40 commits, nearly all P6-05x/P6-06x. ACP session-ID fencing, nested permission admission, terminal receipt persistence, heartbeat age diagnostics, receipt source provenance, worker-handle observation. Plus P3 playback-shadow fixes, P4 prompt fitting, and **P1-10a-1/2 (C04 result fitting, the one gate-relevant gain)**. Agent Relay built, then delegated. Committed +654.9k lines, **641k of them `Tests/Reports`**. | **Drifting.** The relay detour cost the morning. The rest went deep into ACP edge cases (stdout EOF, offered-option encoding, post-Gate epochs) that no persona reaches. |
| **10-03** | 21:24 (10-02): quit-crash report (PID41058). **02:24: "Did you finish?" 02:43: "list exactly what needs to be done." 03:04: "Don't get lost again… If things are not on the roadmap, delegate."** | No commits. P6-06q ACP offered options (151 checks), quit-crash native-owner joins as staged pairs (S1, embedding, diarization, final pass), P4-07/P4-08/P4-11 memory and knowledge (staged155–174), voice frontend staging, and REMAINING-WORK.md. No quick run after 03:46Z. | **Mixed.** The quit crash was a real owner report; the memory and knowledge work is roadmap work. Still no gate work, and nothing landed. |
| **10-04** | 12:40: "merge old worktrees, delete old builds… reuse, clean up, DRY". 14:31: status. 14:34: continue with parallel subagents. 18:03/18:29 (relay, unread): positioning decisions and a coordination request. | No commits. 3.3 GiB cleanup and an AGENTS.md rule. Calendar duplicate readback (420/421), calendar resource identity (426/427), unknown outcome (434/436), recovery characterization (422) and recovered-read continuation (430/431), schema-probe (423/424), ACP 100 ms latency tracing, P3-09 Island ownership (409/410: 12 RED → 32 PASS), question-answer commit (163 checks), activity freshness (69 checks), filesystem receipt. | **Off-priority.** Island ownership is the only item a person would see. Everything else is receipt/recovery correctness for paths with no persona journey yet. |

Hourly activity: 8 active hours on 09-30, then 16, 22, 19 and 21. Codex works around the clock,
so effort is not the issue; direction is.

## 2. Time per task family and what a person would notice

**Share of progress messages** (classifier over all four root/subagent rollouts):

| Family | 10-01 | 10-02 | 10-03 | 10-04 | What a person would notice |
|---|---|---|---|---|---|
| P6 durable/receipt/ACP/lease | 42% | 46% | 33% | 54% | **Nothing yet.** No restart recovery, retry or iMessage host is shipped (all "remain open" per AGENTS.md). ACP is the coding-agent bridge, not a persona feature. |
| P3 duplex/Island/playback | 10% | 9% | 10% | 9% | Island no longer overwritten by background work (staged410, uncommitted, not installed). The rest is shadow-mode reducers: "commands remain shadow diagnostics". |
| Quit crash/shutdown | 1% | 8% | 6% | 0% | Possibly a fixed quit crash. Not verified end to end, uncommitted, not installed. |
| P4 memory/knowledge | 3% | 5% | 11% | 2% | Library answers fit a 4k window; explicit memory hooks. Staged only. |
| P1 tool quality/quick gate | 2% | 4% | 0% | 1% | C04 ("summarize my emails and tomorrow's events") passes 11/13 on Gemma since P1-10a. This is the only quick-gate case gained. |
| Relay/infra/cleanup | 4% | 1% | 3% | 4% | 3.3 GiB disk back. |

**Gate trend.**
- Quick gate: 4/10 on 10-01 and 10-02 (Gemma fallback), then **3/10** at quick156, then
  quick162 killed (−9, no score). No quick run since 10-03 03:46Z. Bar 9/10.
- CORE: 21/22 unchanged, with wake-live red in all 14 runs.
- Latency targets: Codex's own related suites keep failing them (receipt 5 ms, ACP 100 ms).
  Codex records these as "inherited" and re-runs them with every slice.

## 3. Drift and over-engineering signs (quantified)

- **Ceremony per slice.** A typical 10-04 slice:
  1. Write a red self-test.
  2. Build a staged "original" bundle (about 207 MB) and run it.
  3. Freeze a source "packet" with SHA manifests for 1,140+ compiler inputs.
  4. Get a peer-agent review.
  5. Apply the packet, build a staged "fixed" bundle and run the identical fixture.
  6. Write a `*-qualified-results.json`.
  7. Run 14–26 related flags.
  8. Write a roadmap paragraph and an AGENTS.md paragraph.

  Builds that fail to compile are kept and labelled `INPUT_INVALID` (428, 429, 435). Build
  numbers rose from about app12 on 10-01 to **app438**.
- **Single-number targets are being chased with original/fixed pairs.** Examples are "one
  validated schema-version read instead of two" (423/424) and "all64 writers change from two
  validated version reads to one" (432/433). Both are self-described as "not latency closure".
- **AGENTS.md is becoming an evidence log.**
  - It grew from 2,082 lines (09-30, `2b414f4`) to 2,922 lines today.
  - Lines 298–914 (about 617 lines) are P6/P3 proof paragraphs such as "original app61 fails three
    assertions… app62 worker701". The file has 73 lines carrying "original", "RED" or "fixedN".
  - Every agent from every runner loads this file at session start.
- **The roadmap is 27,674 lines** across the 13 AO files. STATUS.md alone is 2,126 lines.
- **Evidence volume.**
  - `Tests/Reports` is 1.1 GB.
  - Committed: 4,420 files, 3,481 of them under `agent-overhaul-closure`.
  - Untracked: about 23,600 more files. They include 5,512 `.swift` source snapshots, 533 patches
    and 13,194 JSON files.
  - Tests/Reports lines committed: 131k on 10-01 and 641k on 10-02.
- **Re-verification of unchanged things.**
  - Hash/compare calls: 72 on 10-01, then 482, 745 and 1,167 a day.
  - "Owner isolation21files32defaults" and "worker NNNN" suites are re-run on every slice
    (worker1908 → 2,761 → 2,933 cases).
- **Retries of the same failure.**
  - ACP history 100 ms and C03/F09 receipt 5 ms fail in nearly every related run from 10-03 to
    10-04 (fixed432: 127.7/104.7 ms; fixed436: 114.0 ms). Each failure is "retained, cause
    unproven" and runs again with the next slice.
  - The quick gate repeated Gemma's fixed failure pattern 13 times (gates analysis §3) without a
    fix to any of the six stable failures.
- **Coordination volume.**
  - 6,408 inter-agent `send_message` calls, 523 `followup_task` and 458 `wait_agent`.
  - The UI agent's 10-02 relay traffic alone (lines 113–199 of the owner-message list) is about
    45 messages of lease, refreeze and SHA handshakes over three Settings files.
- **Off-roadmap detours.**
  - Agent Relay, about 01:00–03:20 on 10-02, until the owner intervened.
  - The ACP protocol frontier (P6-06l…q, P6-05i/k). It is on the roadmap, but its value depends
    on ACP and iMessage hosting, which the 10-04 owner decision does not prioritise.

## 4. Why nothing has been committed since 10-02 20:52

1. **Ownership entanglement in one working tree.**
   - The tree mixes several owners' changes:
     - Codex root fixes;
     - UI-agent theme and Settings work: `DesignSystem.swift` +469, `SettingsSheet.swift` +537,
       `FormattingSettingsTab`, Onboarding and fonts;
     - an OpenCode illustration owner's `Resources/OpenPeeps/` and `PeepFigure.swift`, which
       refused Codex's freeze request (relay 10-03 01:23Z);
     - partly staged UI hunks.
   - New seams that several fixes depend on (`OutputScheduler`, `TaskBridge`, `IslandOwnership`)
     are untracked.
   - Codex's own words, 10-04 22:03Z: "staging these files wholesale would combine work from
     multiple owners."
2. **The bar for "commit-ready" has crept up.** Since 10-03 each slice waits on a frozen-packet
   peer review plus related suites that include inherited reds (5 ms and 100 ms). The 10-02
   rhythm of commit-per-slice was replaced by "verified, retained, open".

   This is an inference from the message stream; Codex does not say it explicitly.
3. **The relay's `git-index` claim** is still held by `serial-root`, claimed 10-03 00:17Z, so no
   other agent will commit either.

**Pending:** about 225 tracked files (+13.7k/−3.9k) plus about 26k lines of new Swift, of which
about 4k are product code.

## 5. Is it blocked?

**Not for its chosen work, and not for the gate work either.** The five gate fixes are pure code
plus the fixture eval, and need no grant, account or model download (Gemma, Qwen and MiniCPM are
on disk).

Real constraints:
- **Machine load.** Load average 95–180, timeouts doubling daily. Parallel subagents, staged
  builds and suites share one 16 GB Air, which is also the floor machine PL-02 must benchmark
  on quietly.
- **Disk.** 3.7 GiB free:
  - 6.3 GB in `~/Library/Caches/NextNotesBuild`, with four staged apps at about 200 MB each,
    1.9 GB scratch, 2.3 GB `claude-scratch` and 1.1 GB worktrees;
  - 1.1 GB of evidence in iCloud.
- **Owner-only items** (not on Codex's path today):
  - wake real-room captures;
  - PL-09 Google OAuth client registration;
  - physical UI and Computer Use checks (CUA denied access to Next Notes).

## 6. Relay

- **Not being read.** Facts are in Top finding 4: status frozen at 10-03 00:52Z, 15 unacked
  messages including both `claude-positioning` ones, and 0 mentions in any rollout.
- **It did work earlier.** On 10-02 relay notices arrived as user turns ("Agent Relay
  coordination notice… Message 50a22f7b…").
- **What changed (hypothesis).** The root's watch/attach seems to have stopped after a session
  reload. Since then Codex coordinates its UI peer through `mcp__codex_tui__send_message_to_thread`
  instead.
- **Action.** Re-attach (`agent-relay attach codex --thread 01a0f3bf-… --as serial-root` or
  `watch`), or have the owner paste the brief directly.

---

## DRAFT steering brief to Codex (`serial-root`)

```
Owner priority changed 2026-10-04 (AO 00-README "Owner decision 2026-10-04"; POSITIONING-AND-LOCAL-MODEL).
Judge each step by: will a non-technical person notice it, and does the quick gate move (3/10 -> 9/10)?
STOP: new P6/ACP/receipt/lease/heartbeat/recovery slices; 5 ms/100 ms micro-pairs; frozen SHA packets
  and peer review for single-owner changes; re-running unchanged suites per slice; evidence in AGENTS.md.
COMMIT TODAY, one commit each, your files only: Island ownership (P3-09), ACP cancel settle, question-
  answer commit, activity freshness, calendar identity/unknown outcome, recovered read, quit-crash joins,
  with their seams (OutputScheduler, TaskBridge, IslandOwnership) and focused self-tests. Leave UI theme
  and OpenPeeps to their owners. Then one `make install OPEN=0` so the owner actually gets the fixes.
CLEAN: move Tests/Reports/agent-overhaul-closure archives out of iCloud to ~/Library/Caches/NextNotesBuild/
  evidence/; keep one short verification.md per commit; delete all but the current staged app; >= 10 GB free.
NEXT, in order (gates analysis §8; pinned model, quiet machine):
  1. Stable quick instrument: pinned --model, fixture clock, 3 runs min/median/max, load printed, all raws.
  2. ToolClaimGuard: "should I set..." is not a claim (+ grader rows both ways). XS.
  3. App runs a read the model only offered or promised; add the meetings class. S. Expect Gemma +2.
  4. A promise without a call gets one round that must call; draft_email composes its own subject. M.
  5. Wake: WakePhraseConfirmation on the audio path after a spot (acknowledge now, retract on reject). M.
  Then PL-01 floor modifiers, then the PL-02 bake-off (release the model-evaluation claim when idle).
RULES: smallest diff in the existing seam; delete dead code you meet; one red->green self-test per change
  plus 3-5 related flags once; log inherited reds once, never re-run them per slice; <= 2 subagents on
  disjoint files; no builds while load > 40; commit each verified slice within the hour; never > 1 day
  uncommitted.
RELAY: re-attach as serial-root, ack the inbox, answer claude-positioning (which files you touch in
  Agent/Schedules, onboarding, gws). Post one line a day:
  "<date> committed <ids>; quick <n>/10 on <model>; next <task>; blocked on <x|nothing>".
```
