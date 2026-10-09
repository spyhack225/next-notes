# Remaining Google re-review repairs

This packet addresses the three remaining findings in the independent
`review-google/REVIEW.md` at reviewed head `59b8bbba`.

The earlier GREEN missed three specific contracts:

1. R3 held `invalid_grant` and cancellation, but never held delivery of a successful,
   already completed refresh across a real reconnect. Scope admission also preceded a
   token actor hop without carrying the record identity. The new fixtures hold the
   creator and joining waiter after `task.value`, reconnect through the actual loopback
   OAuth flow, separately replace the same-token record without actor invalidation, and
   replace the grant at scope/token, after-token, and inside-spawn boundaries. Real
   temporary executable markers pin zero backing on refusal and positive backing when
   unchanged. The repair carries the scope-approved identity into token acquisition,
   checks generation and record identity at both awaited deliveries, and compares the
   record under the existing replacement lock through `process.run()`.
2. R6 populated then withdrew through `CalendarService.connectGoogle`, which explicitly
   cleared the list. The controller instead switched Calendar off and skipped the list
   refresh; disconnect hit an enabled guard that returned without clearing. The new
   populated controller connect/disconnect cases call the same controller orchestration,
   grant application, and service seam with a disabled switch. That service now clears
   on disabled entry, before provider/token/network backing. Controller grant application
   always reaches it with the actual granted enabled value.
3. The old harness accepted any `FAIL Rn` prefix. Earlier retained native RED logs did
   contain behavioral failures, but this did not enforce future harness quality. The new
   setup-only synthetic control fails the old harness (it incorrectly returns 0) and
   passes the fixed harness, which requires six independently named behavior assertions
   and exit 1. Broad-prefix, missing-finding, wrong-exit and unrelated controls also
   refuse. Setup cannot satisfy any supported RED mode.

`GoogleRemainingChecks.sh` runs one guarded FIFO slot: reviewed-decision replay RED,
original six-finding native replay for the named gate, fixed seven flags, three producer
mutations, restored seven flags, invariant fixture hashes and final credential scans.
Replay keeps new hooks/signatures and restores only reviewed bad decisions; it is not an
untouched historical binary. All HTTP/executable/Keychain work is isolated fixture data.

Native counts, markers, commit IDs and limitations are recorded in root `RESULT.md`.
No private OAuth JSON, owner stores, app installation, GUI, push or merge is involved.
