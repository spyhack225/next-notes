# Branch and worktree evidence audit

Audited 2026-10-22T18:21:55.907605+00:00. Read-only snapshot; no branch was merged or worktree removed.

[Full pinned inventory, compressed JSON](git-audit.json.gz) · [Compact summary](git-audit-summary.json) · [Conversation audit](../CONVERSATIONS.md)

Git blobs preserve committed versions. Uncommitted differences are pointers to their owning worktree, not backed-up content; retain those worktrees until their owners integrate the evidence. Counts include historical copies, not independent measurements.

| Git ref or preserved snapshot | Pinned commit | Evidence files |
|---|---|---:|
| refs/heads/main | `fa8f72be3269d6e54801b33a5dd94f439d793c87` | 3371 |
| refs/remotes/origin/HEAD | `f2f5b6067e6283026d417edf007420113681941b` | 830 |
| refs/remotes/origin/claude/open-source-license-setup-d0l8u9 | `7290fd2086c397d11b898b954d0e6329096e258d` | 107 |
| refs/remotes/origin/main | `f2f5b6067e6283026d417edf007420113681941b` | 830 |
| refs/remotes/origin/personal-agent | `871b699e5e7ffb75cd0978e42ffaf3f25bc5ec40` | 107 |
| preserved/agent-delivery | `61fadf0a206cf460d301a58a75e5238bd9483a2a` | 947 |
| preserved/dictation-perf | `b9f3ee6fc944aaae6bd42efc6c0ca0caa9ae6e66` | 2289 |
| preserved/bakeoff2 | `8b6391c59fda6d7a21346f88e5289bdf324220ca` | 2288 |
| preserved/catchup | `33bc14f0f0c2d943a9f83922bf2aff53ba0a70d0` | 815 |
| preserved/catchup-audio | `b117c8941ac1c7eeb6a3292a214bcdf0734e24a2` | 2361 |
| preserved/catchup-final | `01dc32276ec5222b1b95a10849ad2cc401d44671` | 2450 |
| preserved/catchup-port | `134f485b00fd31ded3388fc8081ec4d8e53c8600` | 2288 |
| preserved/catchup-ui | `b4a56a66524b8afbd2b596628c92d69a8d71e1ea` | 815 |
| preserved/catchup-ui2 | `c0d3746236719dfa994abecd47918754f26d0c08` | 2288 |
| preserved/clockfix | `31577e272165e6fa8d6f0fda837e79abd96fc0d2` | 2346 |
| preserved/google | `180b0704eef572191cfe0a581412554ff637ded5` | 818 |
| preserved/google-c | `8fa825ae474e49d40b9340ea89e0731d7784f926` | 2731 |
| preserved/listen | `3e2eef1a696de4e0287c97d02b67b3a93d65ae7c` | 815 |
| preserved/listen2 | `bb718d649d9f64c7795d6f777ec173d68ea9d8d5` | 2415 |
| preserved/no-apple | `261bcb10cd67289b2d94e9998ecc10e035b06ebf` | 2567 |
| preserved/thinking | `54136866adaca3e5eae0d8d0dd0cf6f84fe0b14b` | 815 |
| preserved/thinking-review | `5def549f5d9af6a9558f8b488f961d78939ada84` | 2321 |
| preserved/tooling | `ad9783ed5868a1b2349617cd70d22aebc6a0a4e0` | 2292 |
| preserved/voice-ack | `700f865650d10928d0ff7af6482d811ca516c9c9` | 2657 |
| preserved/voice-mini | `52ef3734100df232d2711d59792f8ba88ce5e951` | 2484 |
| preserved/voice-settings-ui | `08fd03c47a2a4cccedfb3113a8fd02b5394d3084` | 2652 |
| preserved/scratch-review-google | `db262996486ff1ef6740aaaa007f433e4c7c5cab` | 0 |
| preserved/scratch-voice-audit | `3775d5022b60f1728dcc35ad4965ca017b515736` | 0 |
| preserved/scratch-review-leak | `bd8a319451725e03f3ae7a2191472eea986aa30e` | 0 |
| preserved/scratch-review-noapple | `ef1aa7bc0ad2437481c9b30aac95c468180873db` | 0 |
| preserved/scratch-review-audio | `2501f0df5c62538a28e6b18e530fb053d4ccde00` | 0 |
| preserved/task-bakeoff | `6853a94234ce386859c293c13ee9554a24e5ae20` | 0 |
| preserved/task-review-ack | `345fb57804c923a36cd7b943d80ffdd8b4b43b7b` | 0 |
| preserved/task-review-catchup | `44e0b16721d41038e242b000e034244b930360bb` | 0 |
| preserved/task-review-ui | `c9aeb6af80516e8c6af56e792984b02fbd29f924` | 0 |
| preserved/task-roadmap | `90141824118373c760cf6e560effdd990b66d60a` | 0 |

| Worktree | Branch / detached | Evidence files | Different or absent in canonical |
|---|---|---:|---:|
| [next-notes](/Users/sergekadjo/Documents/Claude/Projects/next-notes) | refs/heads/main | 3379 | 0 |

## Retrieve a historical result

Use the exact commit and path in the JSON with `git show <commit>:<path>`. Do not substitute a branch tip after it moves. A historical result does not qualify the current build.

This scans current local/remote refs and worktrees plus main-reachable public recovery sources from retired checkouts. Public sources exclude ignored recovery archives and command/session logs. Original exact snapshots and ignored archives are retained privately on the owner machine under refs/archive/private-worktree-history-20261022 and its private backup bundle; never push that ref. Preserved sources are not additional branches, worktrees or independent measurements. It does not claim recovery of inaccessible chats or external owner recordings.


[Browse historical-only evidence](historical.md). Files above 4 MiB are listed without a working-file content hash; committed Git blob identities remain in the archive.
