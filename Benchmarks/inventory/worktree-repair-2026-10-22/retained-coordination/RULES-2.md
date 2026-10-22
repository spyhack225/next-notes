# Rules for every parallel agent, round 2 (2026-10-08). Supersedes RULES.md.

You are one of several agents working in parallel. Each of you has your own git worktree under
`~/Library/Caches/NextNotesBuild/wt/<name>` on branch `claude2/<name>`, cut from main commit `c6d850c`.
`AGENTS.md` in your worktree is binding. Read its top sections ("What we optimize for", "Reuse,
integrate and clean up", "Fix bugs at the source") before you change anything, plus
`PERFORMANCE-STANDARDS.md` if you touch capture, models, voice, meetings or dictation.

## Who else is on this Mac (read this twice)
- **Other agents are working in the canonical checkout** (`~/Documents/Claude/Projects/speechify`) and
  hold a Sources/Resources freeze there. **Never edit, build in, stash, checkout or commit in that
  checkout.** You may read it. Everything you write goes in your own worktree.
- The canonical working tree has uncommitted edits by others; the list is in
  `~/Library/Caches/NextNotesBuild/wt/MAIN-DIRTY-SOURCES.txt`. If your change must touch one of those
  files, put your change in your branch anyway but flag the file in `RESULT.md` as "will conflict with
  uncommitted work", so the integrator can merge by hand.
- `meeting-performance` is running guarded native release builds and a live meeting acceptance. Do not
  disturb it: see "Heavy jobs".
- Never install an app, never `make install`, never push, never kill another agent's process, never
  open the GUI, never read or seed the owner's stores in Application Support.

## Heavy jobs: builds, native runs and any model load
Writing code is free. Anything that compiles Swift, launches `NextNotes`, loads a model or runs a
`--selftest-*` is heavy and goes through the wrapper, one at a time on this 16 GB Mac:

```sh
H=~/Library/Caches/NextNotesBuild/wt/heavy.sh
S=$HOME/Library/Caches/NextNotesBuild/wt-scratch/<name>
$H "make webrtc-audio && swift build -c debug -j 2 --scratch-path $S"
$H "$S/debug/NextNotes --selftest-<flag> --selftest-out \$TMPDIR/<name>-\$\$.log"
```

- The wrapper takes the shared lock, waits out any priority hold, and enforces the gate: swap <= 8 GB,
  load <= 40, free disk >= 10 GB. A gate exit of 75 means "held, not run". It is never a pass: retry.
- **Wait for foreign heavy work.** If another agent's compiler, `NextNotes --selftest-*` or model
  process is running (`pgrep -fl "swift-frontend|swift-build|NextNotes --selftest|llama"`), do not
  start yours until it ends. This is not optional: `meeting-performance` needs a quiet machine for
  its acceptance checks. When `heavy.sh` v2 exists it does this for you; until then do it by hand.
- Never run a build outside the wrapper, never in the background with `&`, never in a loop, never two
  at once. Prefer one build and a batch of flags per slot, not many tiny runs.
- When you finish or stop, delete `wt-scratch/<name>` unless your brief says to keep it, and delete any
  `$TMPDIR` folders your tests created.

### heavy.sh v2 usage (tooling, 2026-10-08)

Use `RELAY_ID=claude2-<name> "$H" "command"` so the temporary machine `build` claim
has your identity. Default identity is `claude2-heavy`; absent identities are joined automatically.
The wrapper uses the existing lock inode (macOS `lockf` inherited-descriptor mode), checks
priority again inside the lock, waits for foreign compiler/selftest/model processes and
machine `build`, `native`, or `model-evaluation` claims, then runs the gate and claims `build`.
Foreign waits poll every 20 seconds, report PID/short command/elapsed time or claim owner once
per minute, and return 75 after three hours without running the command. `claude2-*` and
`claude-positioning` claims are excluded from the foreign view; a conflicting build claim
still cannot be stolen. Existing claims owned by the caller remain owned by the caller.

The gate also requires `memory_pressure`'s VM-statistics-based free percentage >= 50%.
Its codes remain 0 pass, 2 unreadable values, 75 priority held, and 1 resource timeout
(two hours). Command exit codes pass through. HUP/INT/TERM stop the wrapper's own command
group and release only the claim it acquired; normal/error exits release it too. Relay
unavailability is reported and allows running with the lock/process/resource checks.
These scripts use macOS `/bin/sh` (bash 3.2 compatible) and Node, already used by agent-relay.
`HEAVY_RELAY_PROJECT` optionally selects another existing relay project room; by default it
is the shared speechify room. No application or product audio path uses this wrapper.

Shell-only tests: `/bin/bash tooling/heavy-tests.sh` from the `wt` directory. They use actual
renamed sleep processes, an isolated relay daemon/data directory, and a temporary lock.
Only with `HEAVY_TESTING=1`: `HEAVY_TEST_ROOT` is required, `HEAVY_TEST_GATE` replaces the gate,
`HEAVY_TEST_POLL`, `HEAVY_TEST_LIMIT`, `HEAVY_TEST_REPORT` change timing in seconds,
`HEAVY_TEST_PROCESS_ROOT` restricts the process census to that PID's tree (0 means all), and
`HEAVY_TEST_RELAY_BIN` can simulate relay failure. Relay is forced to ROOT/relay via both
`AGENT_RELAY_HOME` and `--data-dir`, with ROOT as its project; production paths are untouched.
Only with `GATE_TESTING=1`: `GATE_TEST_ROOT` is required; `GATE_TEST_SWAP` (MB), `GATE_TEST_LOAD`,
`GATE_TEST_DISK` (GB), and `GATE_TEST_MEMORY` (percent) replace measured metrics;
`GATE_TEST_POLL`/`GATE_TEST_LIMIT` shorten the gate wait. Never set these overrides for a real job.

## Relay
Join once and tell the orchestrator when you start and finish, in one short message each:

```sh
agent-relay join --as claude2-<name> --runner codex     # claude2-<name> for Sonnet agents too
agent-relay send --as claude2-<name> --to claude-positioning --message "<one line>"
```

Use `agent-relay inbox --as claude2-<name> --unread` at the start and when you finish, in case someone
sent you a constraint. A message sent is not a message read: never treat silence as agreement.

## Commits and done
- Small commits on your own branch, each with the test that proves it. Original regression RED first,
  then GREEN, using the same fixture. Report the real final marker of every check.
- Fix causes at their producer. Do not weaken a test, a threshold or a grader to get green.
- Write `RESULT.md` in your worktree root: commits, each check and its exact final marker, what you did
  not or could not verify and why, files changed, files that will conflict with uncommitted work, and
  anything the owner or another agent must decide. Plain words.
- Never claim a gate is promoted, a task is complete or a model is the default because your checks pass.

Tooling FIFO candidate (2026-10-08, tooling/heavy.sh; shared wrapper not installed): heavy.sh takes a numbered PID/agent/time ticket in ~/Library/Caches/NextNotesBuild/heavy-queue/ before waiting; only the lowest live ticket takes the shared lock, dead tickets are reaped, exit/HUP/INT/TERM remove the ticket, and queue position reports every minute (all v2 gates/claims/codes remain).
