# POSITIONING-AND-LOCAL-MODEL status ledger

**Created 2026-10-04 from the owner's positioning and low-end-floor decision.** Nothing here is
implemented yet. A task changes state only with evidence linked below.

States: `todo` not started; `red` failing gate demonstrated; `green` gate passed; `done`
implementation committed; `blocked` missing precondition recorded below; `in progress` claimed
with verification/commit pending. Roadmap edits are local/ignored; commits name production,
tests and reports only.

## Ledger

| ID | Title | Blocked on | State | Date | Evidence | Commit |
|---|---|---|---|---|---|---|
| PL-01 | Floor modifiers on `--selftest-llm-metal` and `--selftest-voice-latency` | nothing | todo | | | |
| PL-02 | Candidate bake-off on the floor machine (Agent, cleanup, notes) | PL-01; PL-05 for persona rows; SB-07 corpus for notes rows | todo | | | |
| PL-03 | Pin the winner as the silent default | PL-02; SB-01, SB-04, SB-05; MOD-08/09 | todo | | | |
| PL-04 | Augment the winner past the stock model | PL-02 | todo | | | |
| PL-05 | Persona scenario evals (H, W, L, E sets) | nothing | todo | | | |
| PL-06 | Proactive help per person | AO P4-04/05/06/13; X06 | todo | | | |
| PL-07 | File organisation: shoot-date find, plan + one approval, compare | reads: nothing; writes: AO P1-21, P6-06 | todo | | | |
| PL-08 | Onboarding with no technical question | PL-03 for the silent download (model step still downloads the pinned default); MOD-08, SB-05, UX-09, X09 coordination | in progress | 2026-10-04 | **packet ready for integration** (code side): size removed from the assistant screen, optional one-tap "what fills your week" (stored in `Settings.weekFocus`, picks a starter example only for a capability that works), Google row in the meetings step (hidden when no client). `--selftest-google-connect` 137 checks green from the unpackaged build; `--selftest-onboarding` extended but needs the packaged bundle (fonts), so serial-root must run it. Not done: PL-03 silent default, floor-machine timing, fresh-profile runs, three outside people. Packet: `PL-08-09-first-run-google.md` | |
| PL-09 | Connect Google without Terminal | **blocked on owner action:** register a project-owned Desktop OAuth client, put its id/secret in `Resources/Info.plist` (`NextNotesGoogleClientID/Secret`), and take it through Google verification (restricted Gmail scopes need a security assessment); record decision, cost and timeline here | in progress | 2026-10-04 | **packet ready for integration** (code side, fails closed with a plain sentence until a client is registered): one "Connect your Google account" button, app-owned loopback+PKCE sign-in, pinned checksum-verified `gws` fetched by the app (no Homebrew/Terminal), app token handed to the one runner via `GOOGLE_WORKSPACE_CLI_TOKEN`, granted scopes recorded, revoked grant = one reconnect button, own client / own `gws` kept as opt-in. `--selftest-google-connect` green against a loopback fixture. Not proven: real consent page, Google verification, real mailbox, native views, first live approved write. Packet: `PL-08-09-first-run-google.md` | |
| PL-10 | Apple Calendar and Reminders for the agent, without Google | nothing (PL-05 H cases for red-first) | todo | | | |
| PL-11 | Catch-up: one warm routine replacing the morning podcast and digest | nothing for template/trigger work; AO P4-06 owns the offer path | packet ready for integration, revision 2 after review (not done) | 2026-10-05 | [packet](/private/tmp/claude-501/-Users-sergekadjo-Documents-Claude-Projects-speechify/db20ed61-e5ec-42f2-96f4-75ba2ca92f30/scratchpad/packets/PL-11-catch-up.md); `--selftest-catch-up` CATCH_UP_OK, cooldown cases fail on old code; real Pocket render via `--real-voice` OK (about 18.6 s audio, peak 0.67, 9–21 s, sample .m4a saved, not listened to); gaps: in-memory return detection, one-way cooldown, offer path, quit-during-render | |
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
