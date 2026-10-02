# Standalone original entry review — 2026-10-02

Read-only review of root's corrected entry.swift.txt and standalone-runner.swift.txt.
No Sources, app, native test, subprocess or git index changed by this review.
This is source evidence; root owns compilation and launch verification.

## Verdict

Corrected routing addresses the blocking mixed-flag startup problem. Entry tests
RAW presence of the dedicated flag, before App.main. BOTH argument orders of the
dedicated flag plus another named test enter runStandalone, whose guard refuses
them. The earlier requested-equality entry was unsafe: requested chooses the first
named flag, so another flag first would have entered App.main and original owner UI.

The runner's invalid-modifier refusal is now print-only. Before any fixture or
SelfTest.diagnostic call, accepted output resolves under canonical temporary root
and excludes Application Support. Unsafe output refusal is print-only too, so
that failure cannot write through an unvalidated output path. Test outside-root
refusal with an OWN nonexistent sentinel; never supply an actual owner task path.

## Actor and startup source assessment

The entry enum is @MainActor and its static main is synchronous. The fixture enum
is @MainActor; its extension's synchronous runStandalone and originalCases use
actual same-actor Store/Manager APIs without an async hop, task or run loop.
The returned Int32 is passed to outer exit. Therefore originalCases cleanup and
runner cleanup defers run BEFORE exit; moving exit inside those frames would
skip Swift stack defers and should be avoided.

On the dedicated route, there is no call to App.main, App construction,
NSApplicationDelegateAdaptor, NSApp, scene graph or owner-backed UI. Reading
SelfTest.requested parses command-line strings/harness flag constants only.
Actual fixture supplies every Store/Manager explicitly. TaskStore constructor
only assigns URL; denied mirror is never opened. Completed synthetic controls
start no worker. Shared/default stores and owner snapshots are absent.

Other launch routes call the original NextNotesApp.main and retain its scene/
delegate flow; only the old App struct's @main attribute is removed. Root still
must compile this entry shape and test actual launches. Framework imports/load
are not the same as invoking their application lifecycle; no model load or
framework-dependency stubbing is proposed.

## Direct launcher proof from actual source

Scripts/run-selftest.sh consumes its --under-lock/--out/--via-open/--tcc modifiers.
It forwards remaining ARGS across the lock reexec, verifies the app signature,
builds cmd from BIN plus exact ARGS and optional --selftest-out, then foreground
execs that array. Thus default direct mode preserves the dedicated flag and its
argument order. It calls no AppKit launcher and propagates the binary exit status.

Do not use --via-open or --tcc for original evidence: those choose LaunchServices
and output-polling mode. Use direct mode, with safe temporary output or stdout
capture owned by root. The script's lock/signature checks do not read task JSON.

## Required root original-launch negatives

Before calling any original normal app route:

- Dedicated flag alone: only synthetic actual canary consumer runs; capture RED.
- Dedicated then another named flag, AND reverse order: nonzero generic refusal,
  no App.main.
- Dedicated plus live diagnostic modifier: nonzero generic refusal, no App.main.
- Dedicated plus outside-temporary output sentinel: nonzero generic refusal and
  sentinel remains absent; no owner path/content is used.

Keep entry and standalone fixture byte-identical original/fixed. Root will add
the shared worker-fixture call only after privacy fix proof, before other normal
installed flags. Native default-reader order and related functional evidence
remain root-owned; a no-write owner snapshot alone does not prove read privacy.

## Explicit minor limits

The current flag allowlist is not a complete token parser: it permits extra
positional words and does not enforce harness flag cardinality/value syntax.
Missing/duplicate output/timeout values are not all explicit refusals. Path
validation still precedes diagnostic writes, and raw flag routing still blocks
owner startup, so these do not reopen the confirmed privacy path.

Accepted --selftest-timeout does NOT install the ordinary AppDelegate watchdog
because App.main never runs. This synchronous isolated fixture needs no model/
grant and uses unique temp storage, but do not claim the timeout is enforced.
Any tighter syntax/timeout contract should stay local to this standalone route.
Canonical output validation is not a concurrent filesystem race guarantee;
controlled temporary outputs are assumed for this original regression.
