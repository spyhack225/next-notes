# Branch and worktree evidence audit

Audited 2026-10-22T16:05:05.575572+00:00. Read-only snapshot; no branch was merged or worktree removed.

[Full pinned inventory, compressed JSON](git-audit.json.gz) · [Compact summary](git-audit-summary.json) · [Conversation audit](../CONVERSATIONS.md)

Git blobs preserve committed versions. Uncommitted differences are pointers to their owning worktree, not backed-up content; retain those worktrees until their owners integrate the evidence. Counts include historical copies, not independent measurements.

| Git ref or preserved snapshot | Pinned commit | Evidence files |
|---|---|---:|
| refs/heads/main | `5558f381eb41c039a2a1c36bb0edee1396658857` | 3219 |
| refs/remotes/origin/HEAD | `f2f5b6067e6283026d417edf007420113681941b` | 830 |
| refs/remotes/origin/claude/open-source-license-setup-d0l8u9 | `7290fd2086c397d11b898b954d0e6329096e258d` | 107 |
| refs/remotes/origin/main | `f2f5b6067e6283026d417edf007420113681941b` | 830 |
| refs/remotes/origin/personal-agent | `871b699e5e7ffb75cd0978e42ffaf3f25bc5ec40` | 107 |
| preserved/agent-delivery | `3651851c2a85fd514c9a66d23c37d9c1626e6baa` | 947 |
| preserved/dictation-perf | `2e257dd10b9f366f47ce6a4106b89497f36539d8` | 2299 |
| preserved/bakeoff2 | `cfadc1d5d63d2728f2ec11b9326bfa8e0e17efa1` | 2288 |
| preserved/catchup | `2d41f7930894f30ac4bbae7c74a254d4f3984597` | 815 |
| preserved/catchup-audio | `fb932322883f7ec0da8ee1fcf4c7932e7e5112a9` | 2361 |
| preserved/catchup-final | `6b2779376cf719102cf73f59ccc86e064e3c0e0b` | 2450 |
| preserved/catchup-port | `772a350f143e8080961b1c51537a133df88fc1c5` | 2288 |
| preserved/catchup-ui | `06f00f90d1980d1285b29290d574650a0293873d` | 815 |
| preserved/catchup-ui2 | `7b092587661617f089a7f799358f2ff0362b0418` | 2288 |
| preserved/clockfix | `4effa7b2dbc9def9a39a6fabd829270621517e97` | 2346 |
| preserved/google | `55e856d710d250d0e6ad3b9fd816e90ce0eae6a8` | 818 |
| preserved/google-c | `9634bb996b4f31218d6b0607c55dbac6a90f6217` | 2731 |
| preserved/listen | `224ba2d01f3792dcd7cd3a7f4f9e0613633d8ff9` | 815 |
| preserved/listen2 | `e2e578776281344a41aca0d31752c963236fd1f6` | 2415 |
| preserved/no-apple | `c6d59c4128721e3e7b7a084b1985b56e7c0a5af9` | 2567 |
| preserved/thinking | `2d19780a26265a48d3fbf6bacc49ec7f55c29150` | 815 |
| preserved/thinking-review | `a1c850242cb1af0cb1ebd0e9ba9bde56f9fb4928` | 2321 |
| preserved/tooling | `90aea6c48471729f83563d3e5a152bedaad8586b` | 2292 |
| preserved/voice-ack | `fc8aa2af6e492987a81f1a5672a70af8eb9afa67` | 2658 |
| preserved/voice-mini | `b168b67f0535afb3f53c8a669e96dc3a1b881e35` | 2484 |
| preserved/voice-settings-ui | `e15fee2ca7076f6298796def5dbe3498097989b5` | 2652 |
| preserved/scratch-review-google | `9c1d43621fb492f0f1a6d6e7a5d60e79e830b8f9` | 0 |
| preserved/scratch-voice-audit | `9afcaccc87fe45a5a4950489b80a03d5ef536181` | 0 |
| preserved/scratch-review-leak | `648c8a87d7f22ac9a3dd0b9aacd418a323cac504` | 0 |
| preserved/scratch-review-noapple | `45ae74d83d3a58ae383ce91dfcfc071c76b154d2` | 0 |
| preserved/scratch-review-audio | `04c3de8d92b453853adaa3c023ba84c8693e82b4` | 0 |
| preserved/task-bakeoff | `6a757807c03f2bcc9d73383bdbc101da05a0c8c9` | 0 |
| preserved/task-review-ack | `45360fef3b3af604a9aee4fd86d46eee562632cf` | 0 |
| preserved/task-review-catchup | `23e728efe9e7dd9e8c4576110d0520e168ab0d4e` | 0 |
| preserved/task-review-ui | `8337efcc09d485eaf8db489da1863602d3b7748d` | 0 |
| preserved/task-roadmap | `803be7cb3fbba52aebeca622fc4b94000df3484b` | 0 |

| Worktree | Branch / detached | Evidence files | Different or absent in canonical |
|---|---|---:|---:|
| [next-notes](/Users/sergekadjo/Documents/Claude/Projects/next-notes) | refs/heads/main | 3219 | 0 |

## Retrieve a historical result

Use the exact commit and path in the JSON with `git show <commit>:<path>`. Do not substitute a branch tip after it moves. A historical result does not qualify the current build.

This scans current local/remote refs and worktrees plus main-reachable recovery snapshots from retired checkouts. Preserved snapshots are evidence sources, not additional branches or worktrees. It does not claim recovery of deleted/unreachable commits, ignored temporary files, inaccessible chats, or external owner recordings.


[Browse historical-only evidence](historical.md). Files above 4 MiB are listed without a working-file content hash; committed Git blob identities remain in the archive.
