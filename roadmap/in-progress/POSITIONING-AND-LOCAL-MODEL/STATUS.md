# POSITIONING-AND-LOCAL-MODEL status ledger

> ## Reconciled 2026-10-08
>
> Documentation-only pass from the [status audit](../../../Tests/Reports/agent-overhaul-progress/2026-10-08-status-audit.md) and the compact reports it links. No build, model run,
> install or source edit. The SHAs below are the **commits of the committed report files**, not product
> source commits. No overall completion percentage is asserted. The creation text further down ("Nothing
> here is implemented yet", quick 3/10, 2.894 s warm audio) is Historical.
>
> **Position on 2026-10-08 (Mini = MiniCPM5-2B Q4_K_M, the owner's one local brain)**
> - Quick, native planner, baseline sampler: **10/10 x3** on installed `d32b123` ([52c7e4d](../../../Tests/Reports/agent-overhaul-progress/native-quick-d32b123/verification.md)), then **9/10 x3** on installed `c2b11e7`, A02 ungrounded each time ([daf325e](../../../Tests/Reports/agent-overhaul-progress/a02-page-inspection/verification.md)). Quick bar 9/10 is met on these Mini artifacts; it is a typed-fixture score, not a floor or default qualification.
> - Full + owner on the latest retained pair (installed `2afe575`): **25/30 and 23/30**, owner **9/10 both**, required O01-O09 **8/9** (O08 refuses) ([da6e668](../../../Tests/Reports/agent-overhaul-progress/r01-write-after-read/verification.md)). The full gate (two runs >= 25/30, all mandatory owner cases) is **still open**; earlier pairs at `a5b443c` (25, 24), `ae5af51` (25, 26) and `e118639` (25, 26) are in the AGENT-OVERHAUL ledger and do not erase the later failures.
> - Speed: Mini **C1 decode 42.20 tok/s median, p10 36.14**, 604.28 s, 96 rounds, all overlapping ASR, peak RSS 1,965,965,312 B, on the M3/16 GB ([dfdc40c](../../../Tests/Reports/agent-overhaul-progress/c1-mini-decode/verification.md)). That is the decode workload only: **C2 (decode with the whole voice path) and the resource/default rows are not accepted**.
> - Live voice, owner target L1/L2 < 200 ms: matched pair L1 1.778 -> **0.671 s**, L2 3.322 -> **2.448 s**, L3 3.777 -> **2.649 s** ([5bbdf53](../../../Tests/Reports/agent-overhaul-progress/voice-preparation/verification.md)). **Not met.** Cold VAD duck 593 ms vs 200 ms ([5a8a363](../../../Tests/Reports/agent-overhaul-progress/p2-vad-duck/verification.md)).
> - Thinking per role and the vendor sampler profile (owner decision 2026-10-05): every candidate was **withheld**, not adopted: baseline 9/9/9 vs vendor-only 5/5/5, thinking candidate TIMEOUT ([703e498](../../../Tests/Reports/agent-overhaul-progress/mini-thinking-qualification/verification.md)); combined 5/10 ([cfbceeb](../../../Tests/Reports/agent-overhaul-progress/thinking-native-qualification/verification.md)); vendor-only 3/10, baseline-sampler thinking 9/10 once ([fe89d0b](../../../Tests/Reports/agent-overhaul-progress/thinking-sampler-arms/verification.md)); baseline 9,10,10 vs vendor 5,5,4 ([602f60e](../../../Tests/Reports/agent-overhaul-progress/sampler-comparison/verification.md)). The decision stands as direction; no default or setting changed.
> - Catch-up (PL-11) core is integrated on `main` ([5c7df10](../../../Tests/Reports/agent-overhaul-progress/catch-up-core/verification.md)); Mac-account Mail/Calendar default path for the agent (the PL-09 "Option A" direction) is integrated on `main` ([77b8141](../../../Tests/Reports/agent-overhaul-progress/mac-google/verification.md)).
>
> **Parallel branches from 2026-10-05, largely superseded by `main`.** `claude/listen` (3e2eef1; main has its own voice-preparation change, matched pair above), `claude/catchup` (2ce054c; main has the Catch-up core), `claude/google` (1261420; main has the Mac-account work, the Google sign-in backend continues as `claude2/google-c`), `claude/thinking` (d152964; main has the rejected thinking/sampler qualification), `claude/catchup-ui` (aad357d; replaced by `claude2/catchup-ui2`). They sit read-only in `~/Library/Caches/NextNotesBuild/wt/{listen,catchup,google,thinking,catchup-ui}` (base 1d23e79). Round 2 is `claude2/*` cut from `main` c6d850c (checked in `git worktree list`): tooling, catchup-port, google-c, listen2, thinking-review, bakeoff2, catchup-ui2. "Largely superseded" is from the reports and the orchestrator's brief; **the branch diffs were not compared line by line**.
>
> **Tooling:** agent-relay 0.2.0 (`@wearer-haitch/agent-relay`, version read from `/Users/sergekadjo/Tools/agent-relay/package.json`) is reported live on npm and GitHub (Wearer-Lab/agent-relay) by the orchestrator; npm and GitHub publication were **not checked** here. The earlier "`relay-improvements` not deployed, needs owner OK" line below is Historical.
>
> **Owner decisions still in force (unchanged):** one local brain MiniCPM5-2B (AGENTS.md, 2026-10-04); thinking per role on that one file (2026-10-05; implementation withheld, see above); voice listens and processes while the person talks, answers when they stop, L1/L2 < 200 ms (2026-10-05, [PL-12-LISTEN-WHILE-TALKING.md](PL-12-LISTEN-WHILE-TALKING.md)); the PL-02 thresholds and bake-off set (2026-10-04); Google Option A default with B/C as backups (2026-10-04).
>
> **Unverified by this pass:** every number is copied from its report and was not re-run; silent default (PL-03), fresh-profile first run, three outside people, M2 hardware, battery, real-room wake clips and the Google verification timeline are untouched. ID note: the ledger's PL-12 is "Noticing what's coming" while the 2026-10-05 entries and `PL-12-LISTEN-WHILE-TALKING.md` call the listen-while-talking work "PL-12"; the collision is flagged for the owner, not renumbered here.

**Historical (creation text, 2026-10-04):**

**Created 2026-10-04 from the owner's positioning and low-end-floor decision.** Nothing here is
implemented yet. A task changes state only with evidence linked below.

States: `todo` not started; `red` failing gate demonstrated; `green` gate passed; `done`
implementation committed; `blocked` missing precondition recorded below; `in progress` claimed
with verification/commit pending. Roadmap edits are local/ignored; commits name production,
tests and reports only.

## Ledger

| ID | Title | Blocked on | State | Date | Evidence | Commit |
|---|---|---|---|---|---|---|
| PL-01 | Floor modifiers on `--selftest-llm-metal` and `--selftest-voice-latency` | nothing | in progress (C0/C1 verified; C2 qualification open) | 2026-10-08 | **Reconciled 2026-10-08 (was `todo`):** the floor modifiers exist and are committed. C0/C1 instrument ([ce27700](../../../Tests/Reports/agent-overhaul-progress/floor-c0-c1/verification.md)): Mini C0 ten native 256-token generations median 45.24 / p10 41.81 tok/s; first C1 median 41.53 / p10 38.83, CONTENDED (pressure warning), not floor acceptance; original `d64c9c6` ignored the new modifiers. Ten-minute C1 on installed `9c5db1b` ([efa96f8](../../../Tests/Reports/agent-overhaul-progress/floor-c1-9c5db1b/verification.md)): 602.11 s, 92 rows, median 41.99 / p10 39.32, native status CONTENDED (thermal-end), root FAILED_OR_CONTENDED, kept as diagnostic. Qualified C1 on installed `22675db` ([dfdc40c](../../../Tests/Reports/agent-overhaul-progress/c1-mini-decode/verification.md)): 604.28 s, 96 rounds, median **42.20** / p10 **36.14** tok/s, minute-1 41.15, final requested minute 39.23, all rounds overlap ASR, `C1_DECODE_QUALIFIED`, thermal nominal->fair at 340 s. C2 instrument ([43590de](../../../Tests/Reports/agent-overhaul-progress/floor-c2/verification.md)): committed, but the authored long WAV split into two committed turns with no native answering pass, exit 1, 0 fixed samples; ten-turn run not admitted. **C2 is not accepted** and the Floor gate (02-FLOOR-BENCHMARK section 4, C1 and C2 on a clean run) remains open. **Historical:** state was `todo` with no evidence recorded. | |
| PL-02 | Candidate bake-off on the floor machine (Agent, cleanup, notes) | PL-01; PL-05 for persona rows; SB-07 corpus for notes rows | in progress (partial; resumed 2026-10-08 as claude2/bakeoff2) | 2026-10-08 | **Reconciled 2026-10-08 (was `todo`):** quick-gate evidence exists for three candidates; speed, memory and Apple/Qwen3.5 rows are not recorded as complete, so no verdict and **no winner is named**. Mini: 10/10 x3 on `d32b123` ([52c7e4d](../../../Tests/Reports/agent-overhaul-progress/native-quick-d32b123/verification.md)), 9/10 x3 on `c2b11e7` ([daf325e](../../../Tests/Reports/agent-overhaul-progress/a02-page-inspection/verification.md)); full 25/30 and 23/30 on `2afe575` ([da6e668](../../../Tests/Reports/agent-overhaul-progress/r01-write-after-read/verification.md)). Qwen3-4B-Instruct-2507 (SHA `3605803b...`): reported 9/10 x3 on `d32b123`, with its F03 unsupported recipient re-graded as a failure (qualified delta 8/10 x3) ([e65fee7](../../../Tests/Reports/agent-overhaul-progress/native-full-ae5af51/verification.md)); earlier 10/10 x3 on `847c1b7` ([323d740b](../../../Tests/Reports/agent-overhaul-progress/qwen-quick-847c1b7/verification.md)) and 8/8/8 on `87e251c` and `8aeb7fb` with M05/F03 ungrounded ([dea6977a](../../../Tests/Reports/agent-overhaul-progress/qwen-current-quick/verification.md), [7237c6cc](../../../Tests/Reports/agent-overhaul-progress/quick-qwen-current/verification.md)). Gemma 4 E4B: reported 7/10 once on `d32b123` (qualified delta 8/10 once); its 4.98 GB file still exceeds the 3.0 GB per-artifact budget. Apple FM and Qwen3.5-4B: not recorded. Sampler arms: see the thinking/vendor-sampler line above (vendor profile loses on Mini). **Historical:** state was `todo` with no evidence recorded. | |
| PL-03 | Pin the winner as the silent default | PL-02; SB-01, SB-04, SB-05; MOD-08/09 | todo | | | |
| PL-04 | Augment the winner past the stock model | PL-02 | todo | | | |
| PL-05 | Persona scenario evals (H, W, L, E sets) | nothing | todo | | | |
| PL-06 | Proactive help per person | AO P4-04/05/06/13; X06 | todo | | | |
| PL-07 | File organisation: shoot-date find, plan + one approval, compare | reads: nothing; writes: AO P1-21, P6-06 | todo | | | |
| PL-08 | Onboarding with no technical question | PL-03 for the silent download (model step still downloads the pinned default); MOD-08, SB-05, UX-09, X09 coordination | in progress | 2026-10-08 (previous: 2026-10-04) | **Reconciled 2026-10-08 (state unchanged):** the code-side packet from `claude/google` is superseded by what `main` integrated; the onboarding/Google-row views were explicitly left outside the integrated commit ([77b8141](../../../Tests/Reports/agent-overhaul-progress/mac-google/verification.md): "views/theme are outside this commit"). First-run/onboarding, fresh-profile and outside-people runs remain open. **Historical (2026-10-04, state `in progress`):** **packet ready for integration** (code side): size removed from the assistant screen, optional one-tap "what fills your week" (stored in `Settings.weekFocus`, picks a starter example only for a capability that works), Google row in the meetings step (hidden when no client). `--selftest-google-connect` 137 checks green from the unpackaged build; `--selftest-onboarding` extended but needs the packaged bundle (fonts), so serial-root must run it. Not done: PL-03 silent default, floor-machine timing, fresh-profile runs, three outside people. Packet: `PL-08-09-first-run-google.md` | |
| PL-09 | Connect Google without Terminal | **blocked on owner action:** register a project-owned Desktop OAuth client, put its id/secret in `Resources/Info.plist` (`NextNotesGoogleClientID/Secret`), and take it through Google verification (restricted Gmail scopes need a security assessment); record decision, cost and timeline here | in progress | 2026-10-08 (previous: 2026-10-04) | **Reconciled 2026-10-08 (state unchanged; still blocked on the owner's OAuth verification for the sign-in route):** the Mac-account default path is integrated on `main` ([77b8141](../../../Tests/Reports/agent-overhaul-progress/mac-google/verification.md)): Mail/Calendar through the existing workspace runner, actual sender identity fixed at proposal and compose, exact selected sender retained in AppleScript, reordered/replaced accounts refused, Calendar verified by its saved native identifier, uncertain Mac saves keep `unknown outcome` with no fabricated Google artifacts. Original 9 failed assertions -> green on unchanged inputs; no real Mail send or account read happened. Real Automation/FDA/EventKit, onboarding views, OAuth and native sends are **unproven**. The nine-scope Google sign-in backend continues on `claude2/google-c`. **Historical (2026-10-04, state `in progress`):** **packet ready for integration** (code side, fails closed with a plain sentence until a client is registered): one "Connect your Google account" button, app-owned loopback+PKCE sign-in, pinned checksum-verified `gws` fetched by the app (no Homebrew/Terminal), app token handed to the one runner via `GOOGLE_WORKSPACE_CLI_TOKEN`, granted scopes recorded, revoked grant = one reconnect button, own client / own `gws` kept as opt-in. `--selftest-google-connect` green against a loopback fixture. Not proven: real consent page, Google verification, real mailbox, native views, first live approved write. Packet: `PL-08-09-first-run-google.md` | |
| PL-10 | Apple Calendar and Reminders for the agent, without Google | nothing (PL-05 H cases for red-first) | todo | 2026-10-08 | **Reconciled 2026-10-08 (state unchanged `todo`):** the Mac-account Mail/Calendar path ([77b8141](../../../Tests/Reports/agent-overhaul-progress/mac-google/verification.md)) overlaps the Calendar half; Reminders and the PL-05 H-case red-first work are not recorded. Owner/serial-root to confirm whether PL-10 is partly covered. **Historical:** state was `todo` with no evidence recorded. | |
| PL-11 | Catch-up: one warm routine replacing the morning podcast and digest | nothing for template/trigger work; AO P4-06 owns the offer path | in progress (core integrated on main; gaps open) | 2026-10-08 (previous: 2026-10-05) | **Reconciled 2026-10-08:** the packet was integrated through the existing scheduler ([5c7df10](../../../Tests/Reports/agent-overhaul-progress/catch-up-core/verification.md)): one moment-titled routine replaces digest/podcast; stable template identity, legacy migration, return trigger and shared cooldown; text returns before its single-voice file render; reads-only/no-web authority enforced. Original regression failed 8 (refused primary save lost audio links 3, overlapping file renders 2, unowned quit callers 3) -> all pass after fixing the existing producers; Catch-up, schedule, scheduler, routine authority, tasks and store isolation pass. Real installed Pocket synthesis produced a decoded non-silent 19.36 s AAC (160,789 bytes, peak 0.692, 10.0 s incl. model start). **Open:** live creation and spoken catch-me-up, typed closing offers, person-specific emphasis, opt-in news; listened audio, notification/UI playback and live quit under real synthesis are unproven; full/owner/latency/default gates. Remaining gaps are `claude2/catchup-port`; screens are `claude2/catchup-ui2`. **Historical (2026-10-05, state `packet ready for integration, revision 2 after review (not done)`):** [packet](/private/tmp/claude-501/-Users-sergekadjo-Documents-Claude-Projects-speechify/db20ed61-e5ec-42f2-96f4-75ba2ca92f30/scratchpad/packets/PL-11-catch-up.md); `--selftest-catch-up` CATCH_UP_OK, cooldown cases fail on old code; real Pocket render via `--real-voice` OK (about 18.6 s audio, peak 0.67, 9–21 s, sample .m4a saved, not listened to); gaps: in-memory return detection, one-way cooldown, offer path, quit-during-render | |
| PL-12 | Noticing what's coming (patterns, recurring deadlines, habits, seasons) | PL-05 fixtures; coordinate AO P4-05 suggestion lane | todo | | | |

## Gates

| Gate | Passes when |
|---|---|
| Floor | One artifact passes every row of `02-FLOOR-BENCHMARK.md` §4 under C1 and C2 on a clean floor run |
| Silent default | PL-03 fresh-profile runs pass and the default-path disk total is within budget |
| Beats stock | PL-04's augmented winner beats the stock weights on two consecutive full Agent runs, with no gated row regressed |
| Persona promise | PL-05 sets reported for the shipped model; PL-06 weeks pass inside X06; PL-08/09 first-run sessions succeed without help |

AGENT-OVERHAUL's quick 9/10, full ≥25/30 twice and owner-case gates are unchanged and are
required for any public claim that the agent is good.

## Facts recorded at creation (2026-10-04)

- Owner machine: `Mac15,12` (MacBook Air 13-inch, M3), 16 GB, 245.1 GB disk, 8.5 GiB free;
  Models folder about 12.7 GB (MiniCPM5-2B, Qwen3-4B-Instruct-2507, Qwen3.5-4B, Gemma 4 E4B,
  S1-mini, embedding and Needle files).
- Latest fixed quick: 3/10 (AO STATUS, quick156). Warm speech-end-to-first-audio median
  2.894 s vs 0.9 s. Wake 17/24 with 3/32 false.
- Silent Agent/notes default today: `.builtIn` → Gemma 4 E4B, 4.98 GB; `ModelFitEstimator`
  predicts ~13 tok/s for it on the floor (estimate, not measurement).
- No code-model candidate is named in the repo yet.

## Open owner decisions

| Decision | Proposed | Needed by |
|---|---|---|
| ~~Memory ceiling~~ | **Decided 2026-10-04:** app peak ≤ 6 GB under C2, pressure stays normal, swap growth ≤ 256 MB | PL-02 verdicts |
| ~~Disk budget~~ | **Decided 2026-10-04:** one LLM artifact ≤ 3.0 GB; default-path models ≤ 5 GB total | PL-02, PL-03 |
| ~~Warm first token~~ | **Decided 2026-10-04:** ≤ 0.4 s for the voice route under C2 | PL-02 |
| ~~Bake-off candidates~~ | **Decided 2026-10-04:** MiniCPM5-2B vs Qwen3-4B-Instruct-2507 (GGUF) vs Gemma 4 E4B, with Apple Foundation Models as the no-download baseline. No code model in this round. | PL-02 |
| Sustained rule | Minute-10 decode ≥ 20 tok/s under C1 | PL-02 |
| Battery run | Recorded only, or gating | PL-02 |
| M2 machine | Borrow an M2 Air before naming M2 publicly | Any public floor claim |
| Code model | Dropped from the first bake-off round (owner, 2026-10-04); revisit only with a named artifact | — |
| Google OAuth client | Register, verify (restricted Gmail scopes need a security assessment), timeline | PL-09 |

## BLOCKED notes

For each blocker record ID/date, what was tried, the exact failing or absent marker, the
missing precondition and the next step. An absent model, grant or account is not a pass.

## Decisions and deviations

- 2026-10-04: Folder created by owner decision. Personas, floor machine, model strategy and
  competitive map recorded in `00-README.md`. Sibling roadmaps (AGENT-OVERHAUL, SHARED-BRAIN,
  MODULES-ACTIVATION, WEBSITE-TO-MAC-EXPERIENCE) carry pointer notes written by their own
  editors; no sibling task changed state.
- 2026-10-04: Owner feedback — the four personas are a starting point. Added
  `01-PERSONAS-AND-ICP.md` (outcomes, limits, approach, capability map, adjacent people,
  spoken examples) and a "Messaging rules" section in `00-README.md`. Task files renumbered
  02–05 (IDs unchanged). Writing it found PL-10 (agent cannot use Apple Calendar/Reminders).
- 2026-10-04: Owner decision on voice and personality (personal, anticipatory, never
  organisational). Added "Voice and personality" to `00-README.md`, per-person feel and
  anticipation plus predictive job rows to `01-PERSONAS-AND-ICP.md`, and
  `06-CATCH-UP-AND-ANTICIPATION.md` with PL-11 (Catch-up replaces the morning podcast and
  digest) and PL-12 (noticing what's coming). Verified while writing: both templates have no
  production offer path (already recorded by AO P4-06); the routine output budget and render
  transform are matched by title, so moment titles need a stable identity first; no
  return-after-absence trigger and no web read for routines exist.
- 2026-10-04: Owner set the PL-02 thresholds (≤ 6 GB app peak, ≤ 3.0 GB per LLM artifact and
  ≤ 5 GB default-path total, ≤ 0.4 s warm first token on the voice route) and the bake-off set:
  MiniCPM5-2B vs Qwen3-4B-Instruct-2507 GGUF vs Gemma 4 E4B (Apple as baseline). Note: Gemma 4
  E4B's 4.98 GB file exceeds the 3.0 GB per-artifact budget as pinned today, so it is measured
  for comparison but cannot become the default without a smaller quantization that passes.
  Same day dispatched: website polish, a gate analysis (quick 4/10, CORE 21/22), PL-11 and
  PL-08/PL-09 implementation agents; Source work is handed to the Codex root as packets.
- 2026-10-04: Owner decision on Google connection: **Option A default** (the Google account
  already on the Mac: Calendar via EventKit; mail reads from Apple Mail's local store under the
  Full Disk Access grant the app already asks for iMessage; drafts/sends via Mail automation),
  **B (Composio-managed) and C (own Google sign-in) as backups**. End users never see Google Cloud.
  Option C registered the same day: Google Cloud project `next-notes-mac` (org wearer.xyz),
  branding "Next Notes", audience External / Testing (owner account is a test user; 100-user
  lifetime cap until verification), Desktop client "Next Notes for Mac" declared as used by an
  AI agent, nine APIs enabled (Gmail, Calendar, Drive, Docs, Sheets, Slides, Tasks, People,
  Forms) and the full scope set declared — owner decision: **all permissions requested at the
  first sign-in**, no incremental re-consent. Restricted scopes (`gmail.modify`, `drive`) need
  Google verification plus the yearly CASA audit before public release. The client JSON lives
  privately at `~/Library/Application Support/NextNotesBuild/google-oauth-client.json` (600) and
  the Makefile injects it into the built bundle only; the repo keeps its placeholder.
  Option A covers mail, calendar, contacts and reminders; Docs/Sheets/Slides/Drive/Tasks/Forms
  need Google's API (C, or B as fallback).
- 2026-10-05: Codex took the steering note: no new P6, committed 12516e9 / 354e121 / 7efe301 /
  ce5e88a / da8dc41 / e2ae29f / acc966f / c2cc422 / 0bd0643 / 9385abb / 6be7c39 / baf304c /
  0e8ba80 / 7437967, installed 7437967. Pinned Gemma 4 E4B quick baseline **3/10 median** (4,3,3);
  P2 claim inversion and P1 offered reads landed but the score has not moved yet (M03 reads but
  UNGROUNDED; M04 omits subject; R02 still claims without a call). Evidence moved out of iCloud to
  `~/Library/Caches/NextNotesBuild/evidence/agent-overhaul-closure` (short notes in
  `Tests/Reports/agent-overhaul-verification/`). PL-11 Catch-up and PL-08/09/09A Google packets
  handed to Codex for integration from `~/Library/Caches/NextNotesBuild/packets/claude-positioning-2026-10-05/`.
  Owner rule: the main Claude session no longer writes code (Codex gpt-6.1-sol for code, Sonnet 5.5 for UI).
- 2026-10-05: MiniCPM5-2B model card (owner-supplied) recommends llama.cpp sampling temp 1.0 /
  top_p 0.95 / **min_p 0** (warns min_p 0.05 causes repetition) and is a deep-thinking model; the
  app runs every GGUF at temp 0.6 / top_p 0.9 / min_p 0.05 with thinking forced off
  (`NotesModelRuntime.swift:2143`, `ChatTemplate.swift:139`). Possible cause of MiniCPM scoring
  below Gemma locally despite the card's tool-use claim (BFCL 66.6 vs 47.0, vendor-reported).
  Added to PL-02 as arms: baseline / vendor sampler profile / vendor sampler + small thinking
  budget on tool turns. DSpark (SGLang only) and the MLX build (second runtime) are out of scope.
- 2026-10-05 **owner decision — thinking per role on the one MiniCPM file:** dictation cleanup
  thinking OFF; Agent thinking ON for tool/work turns (conversational voice replies stay OFF for
  first-audio latency); meeting notes thinking ON. Hard per-role thinking cap (~512 agent, ~1024
  notes) added on top of the visible budget; thinking text never shown, spoken, stored or logged
  (count only in usage.jsonl), stripped while streaming; prefix cache must hold. Vendor sampler
  profile for MiniCPM where thinking is on. Handed to Codex after the PL-02 arms; gate = quick
  score, first-token/first-audio latency, notes cut-short rate, unchanged dictation tail.
- 2026-10-05 **owner target — live voice time to first token < 200 ms.** Measured from the
  committed end of the spoken turn to the first generated token of the answering model, on the
  M3 16 GB with ASR + voice running, warm model; median gate, p95 reported, first audio reported
  separately (Oct 1 baseline: first-audio median 4.776 s). Implies resident model, prefix prefilled
  before commit, no thinking on spoken replies, nothing awaited before generation.
- 2026-10-05 **owner decision supersedes the TTFT line above:** full duplex = process while the
  person talks, answer only when they stop, listening sounds allowed in between. Gates: L1 speech
  onset → processing started < 200 ms; L2 end of turn → first answer token < 200 ms; L3 first audio
  reported. Spec: [PL-12](PL-12-LISTEN-WHILE-TALKING.md). Handed to Codex.
- 2026-10-05 PL-12 phase 1 (branch `claude/listen`, commit 3e2eef1, not merged): voice preparation
  now starts on the first stable partial (the 4-word minimum and the 220 ms wait are removed; scripted
  producer starts 141/6/6/3 ms for 1–4 words). Native measurement on the M3 16 GB, Apple FM answering,
  Pocket TTS, 1 warm-up + 5 turns of a 3.2 s utterance, median (p95):
  L1 onset→preparation 1.78 s → **0.67 s** (0.67); L2 end of turn→first token 3.52 s → **2.67 s** (2.78);
  L3 end of turn→first audio 3.79 s → **3.06 s** (3.17). Targets L1/L2 < 200 ms are not met; the
  remaining L1 is ASR first-partial latency and L2 needs incremental prefill (phase 2, llama seam
  `NotesModelRuntime.preparePrefix`; cancellation currently clears the KV cache).
- 2026-10-05 bake-off (partial, pinned quick, installed build): MiniCPM5-2B 5/5/5, Qwen3-4B-2507 6/6/6,
  Gemma 4 E4B median 3. Qwen3.5-4B and Apple FM pending; speed/memory pending.
- 2026-10-05 16:40Z **PAUSED by owner.** Main installed build: `ad5113d`, after df3035c M04 subject,
  b915ced F03 false-send and ad5113d wrong inbox read. Pinned quick medians so far: Qwen3-4B 6/10,
  MiniCPM 5/10, Gemma 3/10 (Qwen3.5 and Apple pending). Parallel branches, kept in worktrees
  `~/Library/Caches/NextNotesBuild/wt/<name>`, base 1d23e79, none merged, all to be rebased onto
  the newest main before handoff:
  - `claude/listen` 3e2eef1: PL-12 phase 1, verified; serial-root was qualifying it for merge.
  - `claude/catchup` 2ce054c (+3 uncommitted): PL-11 plus the cooldown fix. Open: quit join for the
    detached render, foldArtifacts on refused primary save, passChain render serialisation.
  - `claude/google` 1261420 (4 commits, +2 uncommitted): PL-08/09/09A. Open: serial-root review
    `integration/google-9d5046c-review/handoff.md` (pre-save alreadyThere without retained identity,
    unknownOutcome eventID on the Mac path, Mail accountTag); commits C/D still to verify.
  - `claude/thinking` d152964 (+5 uncommitted): per-role thinking and the sampler profile. Open: voice
    turns get thinking ON via TaskLocal precedence (`integration/thinking-precedence-review`), the
    sampler-arm runtime API (`integration/sampler-arm/peer-api.md`), and the MeetingAgent tools-dispatch
    seam (serial-root).
  - `claude/catchup-ui` aad357d (+2 uncommitted): Sonnet Catch-up screens, unfinished.
  - bake-off: paused; partial runs in `~/Library/Caches/NextNotesBuild/quick/bakeoff-2026-10-05-*`.
  - agent-relay upgrade: branch `relay-improvements` (6 commits, 68/68 tests). Not deployed; it needs
    the owner's OK to merge and restart the broker.
  Shared tooling: `wt/RULES.md`, `wt/heavy.sh`, `wt/gate.sh`, `integration/` (serial-root reviews).
- 2026-10-08 **RESUMED by owner, round 2.** Old `claude/*` branches (base 1d23e79, 181–184 commits behind
  main) are retained read-only in `~/Library/Caches/NextNotesBuild/wt/{catchup,google,thinking,listen,catchup-ui}`.
  New branches `claude2/*` are cut from main `c6d850c` in `wt/<name>`; none edits the canonical checkout.
  Agents (Codex gpt-6.1-sol unless noted): `tooling` (heavy.sh v2 that waits for foreign builds/model
  runs), `catchup-port` (Catch-up gaps still missing in main), `google-c` (nine-scope Google sign-in
  backend + client injection), `listen2` (PL-12 phase 2, live-voice L1/L2 < 200 ms), `thinking-review`
  (read-only review of the rejected thinking/sampler work), `bakeoff2` (Qwen3.5/Gemma/Apple/Qwen3-2507
  quick + speed + MLX benchmark on the installed app), `roadmap` (Sonnet: reconcile ledgers),
  `catchup-ui2` (Sonnet: Catch-up screens). Rules: `wt/RULES-2.md`. Integration of reviewed branches
  waits for serial-root's answer on who owns AGENT-OVERHAUL integration.
- 2026-10-09 01:40Z **Round-2 state (orchestrator hit its usage limit; agents keep running).** All branches `claude2/*`
  in `~/Library/Caches/NextNotesBuild/wt/<name>`, cut from main c6d850c (no-apple/voice-settings-ui from 55d402ee); NOTHING merged.
  Manifest: `wt/INTEGRATION.md`. Rules: `wt/RULES-2.md`; fair build queue `wt/heavy.sh` (tickets in `heavy-queue/`).
  READY (reviewed APPROVE): `thinking-review` stream leak fix, cherry-pick 8e4243d6 + 0be933e6, skip prerequisite copy.
  IN FIX/REVIEW: `google-c` (round 3 after 2 REJECTs; head 59b8bbba + 3 repairs queued), `catchup-ui2` (c0d37462, review fixes done) +
  `catchup-audio` (9f1261ff, review APPROVE WITH FIXES, fixes queued; needs a combined re-review),
  `voice-settings-ui` (Sonnet), `no-apple` (Apple TTS removal, 1f658023/d5ba6655, native batch queued; owner decisions: auto-download Pocket,
  text-only fallback, rule covers the app's own voice only), `voice-ack` (instant "mm/okay" ack < 200 ms, Pocket/Kokoro only),
  `voice-mini` (resident MiniCPM answerer: park unless qualified runs say otherwise; keep the no-cold-load fallback), `bakeoff2` (Qwen3.5 3/10 on installed
  ed67302f with a clock divergence open; needs 3 runs/model incl. MiniCPM control on one build).
  Findings for the owner: committed main c6d850c does not compile alone (test 811f3bb needs uncommitted AgentTaskStore.recoveredReadHistory);
  the "inherited browser failure" is a test-wiring defect (StoreIsolationSelfTest.swift:49 vs AgentToolExecutor.swift:22);
  Google Option C: nine scopes need justification for public verification (5 scopes have no tools yet) and Testing-mode sign-ins expire after 7 days;
  the app currently violates the no-Apple-voice rule until `no-apple` lands. Live-voice 200 ms: substantive answer not reachable (Apple route ~1.1 s + first word ~1.5 s);
  owner chose to pursue both an instant acknowledgement and MiniCPM as answerer; resident Mini unproven.
