Owner direction for Codex (serial-root), 2026-10-04. Read this before your next step.

Priorities changed on 2026-10-04 (AGENTS.md "Owner decision, 2026-10-04"; AGENT-OVERHAUL 00-README note;
roadmap/in-progress/POSITIONING-AND-LOCAL-MODEL/). Audit of the last 3 days:
research/CODEX-AUDIT-2026-10-04.md. Judge every step by two questions: will a non-technical person
notice it, and does the quick gate move (3–4/10 -> 9/10)?

STOP: new P6/ACP/receipt/lease/heartbeat/recovery slices; 5 ms/100 ms micro-pairs; frozen SHA packets and
  peer review for single-owner changes; re-running unchanged suites per slice; new evidence paragraphs in
  AGENTS.md (one line plus a link at most).
COMMIT TODAY, one commit per verified slice, your files only: Island ownership (P3-09), ACP cancel settle,
  question-answer commit, activity freshness, calendar identity/unknown outcome, recovered read, quit-crash
  joins, each with its focused self-test. Leave the UI theme and OpenPeeps files to their owners. Then one
  `make install OPEN=0` so the owner actually gets the fixes. Release the git-index claim on the relay
  when done so other agents can commit their own files.
CLEAN: move Tests/Reports/agent-overhaul-closure archives (1.1 GB) out of the iCloud repo to
  ~/Library/Caches/NextNotesBuild/evidence/, keeping one short verification.md per commit in the repo;
  delete all but the current staged app; target >= 10 GB free disk.
NEXT, in order (research/GATES-ANALYSIS-2026-10-04.md §8; pinned model, quiet machine):
  1. Stable quick instrument: pinned --model, fixture clock, 3 runs min/median/max, load printed, raw
     rounds kept.
  2. ToolClaimGuard: "should I set…" is a question, not a claim (+ grader rows both ways). XS.
  3. The app runs a read the model only offered or promised; add the meetings class. S. Expect Gemma +2.
  4. A promise without a call gets one round that must call; draft_email writes its own subject. M.
  5. Wake: WakePhraseConfirmation on the audio path after a spot (acknowledge now, retract on reject). M.
  Then integrate the Claude packets for PL-11 (Catch-up) and PL-08/PL-09 (first run, Google without
  Terminal) once their review lands (scratchpad packets; sent over the relay), then PL-01 floor modifiers,
  then the PL-02 bake-off: MiniCPM5-2B vs Qwen3-4B-Instruct-2507 vs Gemma 4 E4B on this 16 GB Air
  (thresholds in POSITIONING STATUS.md). Release the model-evaluation claim when idle.
RULES: smallest diff in the existing seam; reuse, and delete dead code you meet; one red->green self-test
  per change plus 3-5 related flags once; log inherited reds once, never re-run them per slice; <= 2
  subagents on disjoint files; no builds while load > 40; commit each verified slice within the hour;
  never more than a day uncommitted. Check facts on disk before writing "not downloaded/never run".
RELAY: re-attach as serial-root (`agent-relay join --as serial-root --runner codex` in the repo), ack your
  inbox (15 unread), answer claude-positioning (which files you touch in Agent/Schedules, onboarding, gws),
  and post one status line a day:
  "<date> committed <ids>; quick <n>/10 on <model>; next <task>; blocked on <x|nothing>".
