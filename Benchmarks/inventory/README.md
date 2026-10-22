# Branch and worktree evidence audit

Audited 2026-10-22T15:14:34.346787+00:00. Read-only snapshot; no branch was merged or worktree removed.

[Full pinned inventory, compressed JSON](git-audit.json.gz) · [Compact summary](git-audit-summary.json) · [Conversation audit](../CONVERSATIONS.md)

Git blobs preserve committed versions. Uncommitted differences are pointers to their owning worktree, not backed-up content; retain those worktrees until their owners integrate the evidence. Counts include historical copies, not independent measurements.

| Ref | Pinned commit | Evidence files |
|---|---|---:|
| refs/heads/claude/catchup | `2ce054cd8d39122f6ef6879e05d781503ec00e91` | 815 |
| refs/heads/claude/catchup-ui | `aad357dbc5186231ad9c7c29151c7c85da66ee27` | 815 |
| refs/heads/claude/google | `1261420cf0ac852ecce024934345fafc3f407ab5` | 818 |
| refs/heads/claude/listen | `3e2eef1a696de4e0287c97d02b67b3a93d65ae7c` | 815 |
| refs/heads/claude/thinking | `d152964433a8cb7f8073796ab4c494113750078b` | 815 |
| refs/heads/claude2/bakeoff2 | `690a358f6cf6db8a5dd3e19a2f0965b6d1f7fe7a` | 2288 |
| refs/heads/claude2/catchup-audio | `63a7e4718c718b47feb84527d6113ba3266cdd9a` | 2361 |
| refs/heads/claude2/catchup-final | `b42c574e840f6b287754b545f6f0bbb633c6d394` | 2450 |
| refs/heads/claude2/catchup-port | `134f485b00fd31ded3388fc8081ec4d8e53c8600` | 2288 |
| refs/heads/claude2/catchup-ui2 | `c0d3746236719dfa994abecd47918754f26d0c08` | 2288 |
| refs/heads/claude2/clockfix | `bac18b68d8ea38f1b4f276b52ba03c2728360d17` | 2346 |
| refs/heads/claude2/google-c | `7ac342cece493248caa947ec716048abc1ac453d` | 2731 |
| refs/heads/claude2/listen2 | `73f4dde8b8166608e119e8eb621919899ef09f5c` | 2415 |
| refs/heads/claude2/no-apple | `19a212a888220e665d087fb39023fc20b0710c1d` | 2567 |
| refs/heads/claude2/thinking-review | `6d2c66aa7f7ebd0a0fb655c8a0819276e4db976e` | 2321 |
| refs/heads/claude2/tooling | `dae49e1d1f3e81892aa469a080f0dce207a80cb0` | 2292 |
| refs/heads/claude2/voice-ack | `baf562318b5002ec645852ef6aca5234d7170c44` | 2528 |
| refs/heads/claude2/voice-ack2 | `52def96e2f510a0b69046720f38fb4f469fd5826` | 2592 |
| refs/heads/claude2/voice-mini | `52ef3734100df232d2711d59792f8ba88ce5e951` | 2484 |
| refs/heads/claude2/voice-settings-ui | `458aae5a0f8d5929470e1f12955617cdb90cb465` | 2652 |
| refs/heads/main | `6cf744cc4a27ed4a57bd3fea2c233ea999506fc0` | 2378 |
| refs/heads/personal-agent | `871b699e5e7ffb75cd0978e42ffaf3f25bc5ec40` | 107 |
| refs/remotes/origin/HEAD | `f2f5b6067e6283026d417edf007420113681941b` | 830 |
| refs/remotes/origin/claude/open-source-license-setup-d0l8u9 | `7290fd2086c397d11b898b954d0e6329096e258d` | 107 |
| refs/remotes/origin/main | `f2f5b6067e6283026d417edf007420113681941b` | 830 |
| refs/remotes/origin/personal-agent | `871b699e5e7ffb75cd0978e42ffaf3f25bc5ec40` | 107 |

| Worktree | Branch / detached | Evidence files | Different or absent in canonical |
|---|---|---:|---:|
| [next-notes](/Users/sergekadjo/Documents/Claude/Projects/next-notes) | refs/heads/main | 3097 | 0 |
| [agent-delivery](/Users/sergekadjo/Library/Caches/NextNotesBuild/agent-delivery) | detached | 0 | 0 |
| [dictation-perf](/Users/sergekadjo/Library/Caches/NextNotesBuild/claude-worktrees/dictation-perf) | detached | 0 | 0 |
| [bakeoff2](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/bakeoff2) | refs/heads/claude2/bakeoff2 | 0 | 0 |
| [catchup](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/catchup) | refs/heads/claude/catchup | 0 | 0 |
| [catchup-audio](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/catchup-audio) | refs/heads/claude2/catchup-audio | 0 | 0 |
| [catchup-final](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/catchup-final) | refs/heads/claude2/catchup-final | 0 | 0 |
| [catchup-port](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/catchup-port) | refs/heads/claude2/catchup-port | 0 | 0 |
| [catchup-ui](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/catchup-ui) | refs/heads/claude/catchup-ui | 0 | 0 |
| [catchup-ui2](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/catchup-ui2) | refs/heads/claude2/catchup-ui2 | 0 | 0 |
| [clockfix](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/clockfix) | refs/heads/claude2/clockfix | 0 | 0 |
| [google](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/google) | refs/heads/claude/google | 0 | 0 |
| [google-c](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/google-c) | refs/heads/claude2/google-c | 0 | 0 |
| [listen](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/listen) | refs/heads/claude/listen | 0 | 0 |
| [listen2](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/listen2) | refs/heads/claude2/listen2 | 0 | 0 |
| [no-apple](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/no-apple) | refs/heads/claude2/no-apple | 0 | 0 |
| [thinking](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/thinking) | refs/heads/claude/thinking | 0 | 0 |
| [thinking-review](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/thinking-review) | refs/heads/claude2/thinking-review | 0 | 0 |
| [tooling](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/tooling) | refs/heads/claude2/tooling | 0 | 0 |
| [voice-ack](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/voice-ack) | refs/heads/claude2/voice-ack2 | 0 | 0 |
| [voice-mini](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/voice-mini) | refs/heads/claude2/voice-mini | 0 | 0 |
| [voice-settings-ui](/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/voice-settings-ui) | refs/heads/claude2/voice-settings-ui | 0 | 0 |

## Retrieve a historical result

Use the exact commit and path in the JSON with `git show <commit>:<path>`. Do not substitute a branch tip after it moves. A historical result does not qualify the current build.

This scans all current local/remote refs and worktrees, including untracked evidence visible to rg. It does not claim recovery of deleted/unreachable commits, ignored temporary files, inaccessible chats, or external owner recordings.


[Browse historical-only evidence](historical.md). Files above 4 MiB are listed without a working-file content hash; committed Git blob identities remain in the archive.
