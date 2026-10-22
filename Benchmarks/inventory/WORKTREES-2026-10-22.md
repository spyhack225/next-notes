# Next Notes branches and worktrees — 22 October 2026

Read-only audit at 2026-10-22T15:30:05.765878+00:00. No branch, Git link, worktree, process or application file was changed or removed. Counts are a snapshot while the main checkout is active.

**22 local branches; 3 live GitHub branches; 22 registered worktrees; 5 extra standalone scratch repositories; 5 non-Git task folders.**

[Machine-readable snapshot](worktree-state-2026-10-22.json)

## Findings

- Current work is concentrated in the canonical `main` checkout. ASR and TTS agents have current source/build claims there; active native compiler processes were observed there. Agent Relay has no active branch claims on the secondary worktrees.
- All 21 secondary worktrees exist and remain registered, but their `.git` files point to `/Users/sergekadjo/Documents/Claude/Projects/speechify/.git/worktrees/...`. That old repository path no longer exists. The real shared metadata now lives under `next-notes/.git/worktrees/...`. Ordinary Git commands fail in those folders. This is a broken outgoing Git link after the repository path changed, not 21 missing directories.
- Their working states were inspected with explicit `--git-dir` and `--work-tree`, using `GIT_OPTIONAL_LOCKS=0`. The links were not repaired. Sixteen secondary worktrees contain changes; five are clean. A failed ordinary `git status` was never counted as a clean result.
- No secondary worktree had a process cwd or open file in the observed lsof snapshot. This establishes no observed use, not permission to discard retained evidence or future owner intent.
- GitHub `main` is 259 commits behind local `main`, with no commits ahead of it, at the queried tips. Main also contains substantial staged/unstaged/untracked work. Having a GitHub remote configured does not back up these local commits or uncommitted files.
- All 20 `claude/` and `claude2/` branches exist only locally under these names, and their tips are not ancestors of any of the three queried GitHub branch tips. They do not have upstreams. They retain commits absent from local main; patch-id comparisons did not establish those changes as already cherry-picked into main. Manual equivalents inside the dirty canonical tree were not semantically adjudicated.
- Secondary working folders account for about 1.65 GiB by du (1,694.6 MiB). APFS sharing, filesystem accounting and ignored artifacts mean this is not a guaranteed space-reclamation figure. The common `.git` database and shared build caches are not included in that secondary-folder total.

## Live GitHub branches

Verified with `git ls-remote --heads origin`; no fetch, push or ref update was performed.

| Branch | GitHub tip | Local relationship |
|---|---|---|
| [claude/open-source-license-setup-d0l8u9](https://github.com/spyhack225/next-notes/tree/claude%2Fopen-source-license-setup-d0l8u9) | `7290fd2086c3` | Remote-only local name; historical license setup |
| [main](https://github.com/spyhack225/next-notes/tree/main) | `f2f5b6067e62` | Local main is 259 commits ahead |
| [personal-agent](https://github.com/spyhack225/next-notes/tree/personal-agent) | `871b699e5e7f` | Same tip; merged into both local and GitHub main |

## Every local branch and its checkout

Paths below are linked. `wt/` means `~/Library/Caches/NextNotesBuild/wt/`. “Commits outside main” counts history reachability, not independently reviewed changes. Change counts include untracked files. All secondary checkout links to Git metadata are broken as explained above.

| Local branch | Checkout | Last commit (New York date) | Commits outside main | Changed entries | Assessment |
|---|---|---|---:|---:|---|
| `claude/catchup` | [wt/catchup](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/catchup) | 2026-10-05 | 2 | 3 | Dormant, local-only; preserve/reconcile unmerged work |
| `claude/catchup-ui` | [wt/catchup-ui](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/catchup-ui) | 2026-10-05 | 2 | 2 | Dormant, local-only; preserve/reconcile unmerged work |
| `claude/google` | [wt/google](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/google) | 2026-10-05 | 1 | 2 | Dormant, local-only; preserve/reconcile unmerged work |
| `claude/listen` | [wt/listen](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/listen) | 2026-10-05 | 1 | 0 | Dormant, local-only; preserve/reconcile unmerged work |
| `claude/thinking` | [wt/thinking](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/thinking) | 2026-10-05 | 2 | 5 | Dormant, local-only; preserve/reconcile unmerged work |
| `claude2/bakeoff2` | [wt/bakeoff2](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/bakeoff2) | 2026-10-09 | 5 | 3 | Dormant, local-only; preserve/reconcile unmerged work |
| `claude2/catchup-audio` | [wt/catchup-audio](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/catchup-audio) | 2026-10-09 | 14 | 1 | Dormant, local-only; preserve/reconcile unmerged work |
| `claude2/catchup-final` | [wt/catchup-final](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/catchup-final) | 2026-10-09 | 21 | 3 | Dormant, local-only; preserve/reconcile unmerged work |
| `claude2/catchup-port` | [wt/catchup-port](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/catchup-port) | 2026-10-08 | 1 | 0 | Dormant, local-only; preserve/reconcile unmerged work |
| `claude2/catchup-ui2` | [wt/catchup-ui2](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/catchup-ui2) | 2026-10-08 | 9 | 0 | Dormant clean checkout; commits retained in catchup-final; checkout retirement candidate |
| `claude2/clockfix` | [wt/clockfix](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/clockfix) | 2026-10-09 | 3 | 13 | Dormant, local-only; preserve/reconcile unmerged work |
| `claude2/google-c` | [wt/google-c](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/google-c) | 2026-10-09 | 20 | 9 | Dormant, local-only; preserve/reconcile unmerged work |
| `claude2/listen2` | [wt/listen2](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/listen2) | 2026-10-08 | 10 | 1 | Dormant, local-only; preserve/reconcile unmerged work |
| `claude2/no-apple` | [wt/no-apple](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/no-apple) | 2026-10-09 | 39 | 9 | Dormant, local-only; preserve/reconcile unmerged work |
| `claude2/thinking-review` | [wt/thinking-review](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/thinking-review) | 2026-10-08 | 6 | 1 | Dormant, local-only; preserve/reconcile unmerged work |
| `claude2/tooling` | [wt/tooling](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/tooling) | 2026-10-08 | 2 | 1 | Dormant, local-only; preserve/reconcile unmerged work |
| `claude2/voice-ack` | No worktree | 2026-10-09 | 15 | — | Dormant branch only; unmerged; no checkout |
| `claude2/voice-ack2` | [wt/voice-ack](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/voice-ack) | 2026-10-09 | 43 | 82 | Dormant, local-only; preserve/reconcile unmerged work |
| `claude2/voice-mini` | [wt/voice-mini](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/voice-mini) | 2026-10-08 | 13 | 0 | Dormant, local-only; preserve/reconcile unmerged work |
| `claude2/voice-settings-ui` | [wt/voice-settings-ui](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/voice-settings-ui) | 2026-10-09 | 46 | 9 | Dormant, local-only; preserve/reconcile unmerged work |
| `main` | [main checkout](/Users/sergekadjo/Documents/Claude/Projects/next-notes) | 2026-10-13 | 0 | 1476 | Active; preserve; GitHub branch exists, local commits unpushed |
| `personal-agent` | No worktree | 2026-09-17 | 0 | — | Old, fully merged and GitHub-synced; branch-pointer cleanup candidate |

## Detached worktrees

These add two checkouts but no named branches.

| Checkout | HEAD | Last commit | Commits outside main | Changed entries | Assessment |
|---|---|---|---:|---:|---|
| [agent-delivery](/Users/sergekadjo/Library/Caches/NextNotesBuild/agent-delivery) | `61fadf0a206c` | 2026-10-06 | 0 | 0 | Clean; HEAD already in main; best archive/removal candidate after ignored-artifact and owner-retention check |
| [claude-worktrees/dictation-perf](/Users/sergekadjo/Library/Caches/NextNotesBuild/claude-worktrees/dictation-perf) | `c6d850c69674` | 2026-10-08 | 0 | 227 | HEAD in main, but substantial uncommitted work; preserve |

## Unconnected standalone scratch repositories

These five folders contain their own `.git` directories: no commits, no branch refs, no remotes. They are not linked worktrees or full application clones. Their untracked briefs/reviews/logs are not backed up by GitHub. No runtime use was observed. Archive their evidence before any cleanup.

| Folder | Untracked files | Approx. MiB |
|---|---:|---:|
| [review-google](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/review-google) | 12 | 0.80 |
| [voice-audit](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/voice-audit) | 4 | 0.90 |
| [review-leak](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/review-leak) | 6 | 0.68 |
| [review-noapple](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/review-noapple) | 15 | 2.09 |
| [review-audio](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/review-audio) | 4 | 1.05 |

## Other abandoned task folders without Git metadata

These are not branches or Git worktrees. They contain retained briefs, reviews or logs; their existence is not a reason to delete the evidence.

| Folder | Files | Approx. MiB |
|---|---:|---:|
| [bakeoff](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/bakeoff) | 3 | 0.42 |
| [review-ack](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/review-ack) | 4 | 0.61 |
| [review-catchup](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/review-catchup) | 4 | 1.08 |
| [review-ui](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/review-ui) | 4 | 0.04 |
| [roadmap](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/roadmap) | 4 | 0.41 |

## Overlap and cleanup candidates

- `personal-agent`: fully contained in both local main and GitHub main; no attached checkout. Its branch pointer is an old merged reference.
- Detached `agent-delivery`: clean, no commits outside main, no observed process/open file. This is the strongest secondary-checkout retirement candidate, subject to an ignored-file and retained-baseline check.
- `claude2/catchup-ui2`: clean; its committed history is contained in `claude2/catchup-final`. Its checkout can be considered for retirement while preserving successor history and evidence. The successor is still local-only.
- `claude2/catchup-audio` is also contained in `claude2/catchup-final`, but has an untracked file. `claude2/listen2` is contained in `claude2/voice-ack` and `claude2/voice-mini`, but has an untracked file. `claude2/no-apple` is contained in `claude2/voice-ack2`, but has nine untracked entries. These require preserving their working files before consolidation.
- The remaining feature histories are not fully in main. Old age and no active agent do not make them disposable. The retained [integration manifest](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/INTEGRATION.md) records reviewed, blocked, parked and rejected slices; it explicitly says integration was pending. Its 9 October decisions are historical, not current acceptance.
- No worktree repair, prune, merge, archive, deletion, commit, push or model/build cleanup was performed. `git worktree prune --dry-run --verbose` proposed no stale registrations; it does not detect the broken outgoing `.git` links above.

## Filesystem search coverage

`find` walked `/System/Volumes/Data` and the mounted `/Volumes/Recovery`, looking for `.git` markers, pruning only the contents of each Git metadata entry. `/Volumes/Macintosh HD` is a symlink to the already-covered startup volume. The read-only OS volume was not treated as a development workspace. The scan found 74 Git markers: 27 project-related checkouts/scratch repositories, 18 dependency repositories and 29 repositories belonging to other projects. No additional unregistered Next Notes linked worktree or independent Next Notes clone was found in the readable scanned locations.

There were 948 permission/privacy-denied locations and 8 paths that vanished or were unavailable during traversal. Root-owned services, protected application data and unreadable mounted content cannot be claimed searched. No elevated access was requested or protections bypassed. Bare repositories without a `.git` marker, anonymous source copies without Git metadata, unmounted drives and other machines are outside the Git-marker census. The five named leftover task folders were checked separately.

Raw scan/error/status/process snapshots are retained locally under `.scratch/worktree-audit-2026-10-22/`; unrelated project paths and raw process-file listings are not copied into this report.
