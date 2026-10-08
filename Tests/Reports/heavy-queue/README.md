# Heavy wrapper FIFO evidence

Shell-only macOS tests; no builds, app launches or model loads. The relay daemon,
HOME, gate metrics, process census and lock are isolated by the existing test harness.
The production wrapper remains `/bin/sh` / bash 3.2 compatible. The signal test
launcher uses Python 3 to reset inherited ignored INT/HUP before exec.

Reproduce from the tooling worktree:

```sh
HEAVY_QUEUE_ONLY=1 HEAVY_WRAPPER="$PWD/Tests/Reports/heavy-queue/heavy-v2.sh" /bin/bash heavy-tests.sh
/bin/bash heavy-tests.sh
```

`heavy-v2.sh` is the untouched original shared wrapper associated with the
06d4ba6c test baseline, SHA256
`b9ed8b1d79385f299cee805335827da2189631c50abbd32349f07771ac6f597c`.
The final original and fixed executions use identical tests. Logs record their
markers and actual FIFO order. Timing overrides shorten polling/reporting for tests;
production queue reports use the existing 60-second report interval.

The original producer admitted callers directly to an unordered lock. The same
three overlapping wrappers are held at a priority barrier. The oldest live waiter
is SIGSTOP'd; newer jobs must retain their places until it resumes. This makes
original overtaking deterministic rather than betting on the kernel wake order.
It proves FIFO by published ticket order, including a paused live head.

The repair serializes only short ticket-number allocation with a separate inherited
file-descriptor lock; it is automatically released on death. The persistent counter
is atomically replaced before noclobber ticket creation, so interrupted allocation
may leave a gap but cannot reuse a published number. Fixed-width ticket filenames
include the PID, making a partially written ticket a live reservation. Contents
include PID, relay identity and UTC creation time. Waiters remove dead-PID tickets
using kill -0. Each wrapper keeps its ticket through the existing shared lock,
priority/foreign-work/resource checks, relay claim and command. Claim-only release
on an ambiguous relay reply must retain the ticket; final cleanup removes it.

SIGKILL cannot run any shell cleanup. Peers reap those tickets; HUP/INT/TERM run
cleanup themselves. The crash test lets the short fake child exit, kills its paused
holder, and observes a same-caller successor before releasing the retained fixture
claim. This preserves v2's caller-owned-claim inheritance. It does not establish
recovery of a different caller's relay lease or kill surviving command descendants:
the inherited heavy descriptor intentionally protects a still-running command.
PID reuse can conservatively retain an old ticket; the requested kill -0 liveness
check is not a process-identity lease. No live shared queue or real workload was run.

The first exploratory harness inherited ignored HUP/INT from background launch;
it was corrected before the retained RED/GREEN runs. Those preliminary interrupted
runs are not acceptance evidence.

Final retained verdicts:

- `red-v2.log`: `FIFO_ORDER=2,3,1,`, `HEAVY_QUEUE_CHECKS=21 FAILURES=7`,
  `HEAVY_QUEUE_TESTS_FAILED` (exit 1). Two FIFO assertions, position reporting,
  and four ticket-existence assertions fail; the crash baseline already proceeds.
- `green.log`: `FIFO_ORDER=1,2,3,`, `HEAVY_CHECKS=84 FAILURES=0`,
  `HEAVY_TESTS_OK` (exit 0): 21 queue checks and all 63 v2 checks.
- `/bin/sh -n heavy.sh`, `/bin/bash -n heavy-tests.sh`, `git diff --check`:
  exit 0, no diagnostics.

Final SHA256 pins:

- heavy.sh: `e6e02efd4ca8355526f92fbf517910de6d7a017bbc8e80b9692e9c30c064c0ef`
- heavy-tests.sh: `464e6e93280783446218e98e0a5bf0de74808c1e48112c6026b090333b39e22a`

The requested parent RULES-2.md append is also retained verbatim in
`RULES-2-append.txt`; the parent coordination file is outside this worktree's git.
