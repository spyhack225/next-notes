# Durable agent sessions — implementation ledger

Updated 22 October 2026. Owner requested a detailed roadmap. Documentation authored;
**no implementation, native tests, benchmarks, migration or installation performed**.
Read-only source assessment uses HEAD `6cf744cc` plus pre-existing working-tree changes;
implementation must freeze its own current pins. All target flags are proposals.

| ID | Status | Depends on | Acceptance / next action |
|---|---|---|---|
| PLAN | DONE (documentation only) | Owner request | Five roadmap documents; links/structure checked; relay scope broadcast |
| DS-00 | TODO | Current ownership and isolated seams | Characterize current call sites, original failures and timing/retention baseline |
| DS-01 | TODO | DS-00 | Separate durable conversation, context and capture identities through real consumers |
| DS-02 | TODO | DS-00/01; schema ownership | Existing SQLite migration/import; task saves preserve history; fresh-reader proof |
| DS-03 | TODO | DS-02 | Bounded projection and off-MainActor persistence without extra audio/turn gates |
| DS-04 | TODO | DS-01/02/03 | Durable new/reopen/switch and original-task result routing |
| DS-05 | TODO | DS-02/03/04 | Retention, deletion non-resurrection and compatible rollback; Slice A |
| DS-06 | TODO | DS-01/02/03 | Stable accepted-input deduplication through real dispatch |
| DS-07 | TODO | DS-06; attempt/receipt contracts | Semantic checkpoints and honest interrupted/delivered output |
| DS-08 | TODO | DS-07; route-specific P3/P6 | Exact restored cards and qualified continuation; Slice B |
| DS-09 | TODO | DS-03/05/07 | Durable whole-turn compaction and original retention/factual continuity |
| DS-10 | TODO | DS-04/07/08; P3/P6 | Background ownership and scoped multi-conversation execution |
| DS-11 | TODO | DS-08/09/10; backend contracts | Enable only individually qualified automatic recovery; Slice C |
| DS-12 | TODO | Chosen slices and acceptance plan | Reference workload, native/physical/semantic rollout and cleanup; Slice D |

No implementation task is claimed. Move the folder to `in-progress` only when product
work actually starts and update relative links/index as part of that move. This ledger
owns DS statuses; existing AGENT-OVERHAUL P3/P6 statuses remain in their parent ledgers.
No gate is green because a document or proposed test exists.

## Handoff

- Existing task ledger, receipts, voice ownership and current recovery are retained.
- Parent repeated-read, timing, semantic, physical and broader recovery gates stay open.
- Current ASR/TTS source/benchmark owners retain their files and machine claims.
- Documentation uses a new disjoint local roadmap folder and a targeted index insertion.
- No build artifacts or worktrees created; no existing artifacts deleted; reclaimed 0 B.
- Source/owner data/models/defaults/installed app unchanged by this task.
- Relay receipt is in `COORDINATION.json`; sent/delivered does not imply read/agreement.
