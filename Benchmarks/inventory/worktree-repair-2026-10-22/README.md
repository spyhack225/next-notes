# Worktree consolidation — 22 October 2026

Owner authorized repair, preservation of all work, consolidation and removal of secondary checkouts/local task branches. The TTS and ASR agents confirmed a development write freeze and no retention needs in the retired checkouts. Their shared `NextNotesBuild/scratch`, models, source and reports remain retained. No build, model inference, push, installation or owner-store change is part of this operation.

## What “merged” means here

The current shared checkout was committed first, with its original staged state in `10f29d4f` and the complete working source/benchmark/owned-roadmap checkpoint in `8b3d4f8a`. Native acceptance remains open exactly as recorded in those reports.

Every secondary checkout was then committed as an exact WIP recovery snapshot. All original branch histories and these snapshots are joined to `main` by an **archive merge** that keeps the canonical application tree. This preserves work; it does **not** claim that every old feature implementation has been reconciled or activated. Historical candidates include mutually incompatible speech policies, a shared-audio-channel gap and rejected/unqualified latency/default experiments. Activating those during disk cleanup would be an unverified product change. [Per-branch content and verdict review](branch-content-review.json) records that disposition.

[Snapshot manifest](snapshots.json) gives the exact original path, branch, head and recoverable snapshot commit. These commits are parents/ancestors of main, so removing branch names and checkout directories does not orphan their work. The previously branch-only voice-ack history is included too. GitHub remains unchanged.

## Preservation proof

- All 21 broken outgoing Git links repaired using `git worktree repair`.
- Ordinary Git status succeeds in all 21 repaired folders.
- Before/after repair and snapshot creation: every original HEAD, index hash, staged/working diff digest, porcelain status and 1,342 changed/untracked/ignored path records remained identical.
- Snapshot trees verify original changed/untracked file bytes. Ignored files, including local reports and the nested research checkout under dictation-perf, are retained in verified compressed Git blobs at `.worktree-preservation/ignored.tar.gz` in the corresponding snapshot.
- Original worktree indexes and staged patches are retained inside snapshot commits. No original checkout/index was rewritten to create a preservation commit.
- Five empty scratch Git repositories and five non-Git task folders have independent recovery commits. All 60 working files were checked, including reports hidden by the canonical repository's different ignore rules. Empty scratch Git metadata is archived too.
- Seven coordinator notes/scripts are retained [here](retained-coordination/), with [file hashes](coordinator-files.json).
- Main's disposable Python bytecode and external imported reference trees are not application work and were not added to the preservation checkpoint. They remain in place; no unrelated cache was swept.

[Repair verification](repair-verification.json) · [Repair output](git-repair.txt). Final retirement counts and filesystem measurements are recorded separately after completion.

## Recover one piece of work

Use `git show <snapshot-commit>:<repository-relative-file>` to read a file. To resume an entire candidate, create **one** checkout with `git worktree add --detach <new-empty-path> <snapshot-commit>` using its manifest SHA. This restores the candidate's tracked and formerly untracked working files.

Ignored content is in that snapshot's `.worktree-preservation/ignored.tar.gz`. List and review the archive, then extract only into the new recovery checkout. It includes local-only material and must not be published blindly. The manifest, original index and staged patch in `.worktree-preservation/` retain the original staging context. Recover one task at a time rather than recreating the whole set of checkouts.

This is local Git retention, not an off-machine backup or a qualified combined application build. Separately tested source integration is still required before activating archived alternative implementations.

## Completed outcome

- **1 local branch and 1 worktree remain: main.** Removed all 21 secondary checkouts and 21 old local branch names, plus 10 obsolete standalone review/task folders.
- All 31 verified WIP recovery snapshots and 64 additional reflog-only commits are reachable from main. Temporary preservation refs were removed after that reachability check.
- Retired checkout directories accounted for 1,776,947,200 bytes (1.655 GiB) by du. Available filesystem space rose from 185,380,864 to 2,164,146,176 bytes during retirement; this observed increase includes filesystem/system activity and is not an APFS-exclusive reclamation measurement. Shared build/model caches remain.
- Full `git fsck --full --no-reflogs` exits 0. Remaining dangling tree/blob notices were not pruned; no missing/corrupt object was reported.
- Eleven catalog tests pass. An actual temporary Git repository reproduces the old audit losing retired-snapshot evidence (original 1 failure); corrected audit discovers committed and ignored-archive reports after source branch/checkouts are gone. Archived report retrieval uses immutable Git commits, replacing stale local-worktree links.
- The benchmark index now retains 5 live Git refs, 31 preserved snapshot sources and 1 current worktree. These are evidence sources, not 36 local branches. All 37 registered run manifests validate; private results remain excluded from public projection unless approved.
- Application source, Package files, Resources and Makefile are byte-for-byte the current shared checkpoint across the archive merges. No historical alternative was activated. No native build or model test, push, install or GitHub branch deletion occurred.

[Final verification](final-verification.json) · [Retirement receipts](retirement.json) · [Archive merge](merge.json) · [Reflog retention](reflog-retention.json) · [Original/fixed catalog regression](catalog-regression.json).

The one-off [preservation procedure](procedure-preserve.py) and [retirement procedure](procedure-retire.py) are retained for audit, not for rerunning against the current checkout. Temporary indexes, duplicate hash snapshots and local execution traces were removed after their relevant evidence was retained here.
