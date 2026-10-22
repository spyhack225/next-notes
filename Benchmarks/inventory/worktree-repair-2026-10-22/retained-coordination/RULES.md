# Rules for every parallel agent (2026-10-05)

You are one of several agents working in parallel on Next Notes, each in its own git worktree under
`~/Library/Caches/NextNotesBuild/wt/<name>` on branch `claude/<name>` (base `1d23e79` = main).
`AGENTS.md` in your worktree is binding: read its top sections ("What we optimize for", "Reuse,
integrate and clean up", "Fix bugs at the source") before you change anything.

## Ownership
- Change only the files your brief names, plus new files it allows. If you need another file,
  stop and write the need in `RESULT.md`. Do not edit it.
- Never touch the main checkout in iCloud (`~/Documents/Claude/Projects/speechify`),
  `/Applications/Next Notes.app`, other worktrees, or the owner's stores in Application Support.
- No git push, no install, no `make install`. Commit on your own branch only: small commits, each
  with its test.

## One heavy job at a time on this 16 GB Mac (UPDATED 2026-10-05 06:50)
Use the wrapper. It waits while serial-root's priority hold is on, then takes the shared lock and the
gate (swap ≤ 8 GB, load ≤ 40, free ≥ **10** GB). Build with at most **2 parallel jobs**, because cold builds
pushed load to 59:

```sh
H=~/Library/Caches/NextNotesBuild/wt/heavy.sh
S=$HOME/Library/Caches/NextNotesBuild/wt-scratch/<name>
$H "make webrtc-audio && swift build -c debug -j 2 --scratch-path $S"
$H "$S/debug/NextNotes --selftest-… --selftest-out \$TMPDIR/<name>-\$\$.log"
```

A gate exit of 75 means the job was held and did not run. It is never a pass. Retry it via the wrapper.

(The older form below is superseded.)
Every build or self-test goes through the shared lock, and only when the machine gate passes:

```sh
G=~/Library/Caches/NextNotesBuild/wt/gate.sh
lockf -k ~/Library/Caches/NextNotesBuild/heavy.lock sh -c "$G && make build SCRATCH=$HOME/Library/Caches/NextNotesBuild/wt-scratch/<name>"
lockf -k ~/Library/Caches/NextNotesBuild/heavy.lock sh -c "$G && $HOME/Library/Caches/NextNotesBuild/wt-scratch/<name>/debug/NextNotes --selftest-… --selftest-out \$TMPDIR/<name>-\$\$.log"
```

- `gate.sh` waits until swap is at most 8 GB, load is at most 40 and free disk is at least 8 GB.
- Never run a build outside the lock, never with `&`, and never in a loop.
- Do not run model-loading evals (`--selftest-toolloop-live`) or `--via-open` tests unless your
  brief says so.
- When you finish, delete your scratch dir (`wt-scratch/<name>`) and any `$TMPDIR` folders your tests
  created.

## Done
Write `RESULT.md` in your worktree:
- commits;
- each focused check, with its exact final marker, run as red→green where your brief asks for a
  regression;
- what is unverified and why;
- files changed.

Plain words.
