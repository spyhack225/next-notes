# OpenCode handoff — MiniCPM cleanup and shared artifacts

**Owner decision, 2026-09-30.** Keep your MiniCPM5-2B default cleanup work with
Apple as guard/fallback. Coordinate with the revised
[model contract](00-README.md) and [build order](../../BUILD-ORDER.md).
The documentation executor changes plans/guidance only; you own implementation.

## Requirements for your current change

1. Cleanup's MiniCPM choice is independent of Agent and meetingNotes. Do not write
   activeAgentModelID, redirect another role or make cleanup follow the Agent picker.
   Your current Settings initializer still selects Apple for an unset preference.
   Align with the owner's requested preferred default: MiniCPM when its exact
   verified artifact is ready, Apple as the no-download fallback otherwise. Preserve
   explicit existing choices; fixture both installed-MiniCPM and fresh/absent cases.
2. Resolve the exact compatible MiniCPM artifact from InstalledModelLibrary's
   existing files before offering a download. Reuse its verified row/path, including
   another basename when identity is proven; no module-specific copy/download/cache.
   Filename/family alone is insufficient: revision/quantization/bytes/digest must
   match. Do not hash weights on every cleanup. Corrupt/unverified/auxiliary files
   must not count as ready; use existing adoption/probe/trial machinery.
3. Sharing storage does not prove the right model is executing. Inspect your
   MiniCPMModels.selectPinned / generation / CleanupRouter.restore seam: a deferred select can
   currently leave another file resident. Hold existing request/native ownership
   through generation and verify actual artifact identity; never run whichever
   file is loaded and call it MiniCPM. If the exact model is busy/unavailable,
   take the existing bounded Apple fallback promptly, preserving voice leases.
   A late restore must not overwrite a newer choice or another request's model.
4. Use existing NotesModelRuntime/ComputeScheduler/native lease ordering. No
   second per-module runtime, permanent store, queue or usage log. Coordinate
   runtime/library edits with SB-01…04/P3-07; do not evict Agent conversation for
   background work or put a new wait/model selector on the dictation path.
5. Preserve your deterministic structure/dictionary/grounding safeguards and Apple
   guard/fallback design. Apple fallback receives the original transcript, never
   rejected MiniCPM output. If both fail, preserve grounded text. No extra always-run
   model pass, second confirmation or new fixed delay to implement file sharing.
6. Module disable/replacement must not delete MiniCPM while Dictation, Meetings,
   Agent, pending work, a runtime lease or required fallback still needs it. Until
   module guards land, do not claim they protect the file. Derive consumers from
   existing choices/work rather than a new reference-count ledger.
7. usage.jsonl records actual MiniCPM/Apple execution and fallback outcome without
   source text. Sharing a file never shares prompts/history/permissions. Cleanup
   stays local; Agent cloud consent is not permission to send dictation elsewhere.

## Verification to include

Extend existing isolated cleanup/model-role/scheduling cases rather than creating
another harness. Confirm red first for: exact file reused with zero fetch; basename
collision rejected; valid identical artifact under a different name reused; Agent
A/notes B/cleanup MiniCPM assignments unchanged; deferred swap/held voice lease takes
Apple without wrong-file inference; cancellation/late restore does not clobber a
choice; original transcript reaches fallback; shared-file delete retained; actual
engine attribution. Include the rawCleanup path so rejected outputs cannot score
as perfect. Measure cold/warm and overlapping-work dictation latency, not only quality.

Use make build, make install OPEN=0, make test and foreground
Scripts/run-selftest.sh runs. Record missing models/grants honestly. Do not rewrite
other dirty source/doc changes or claim SHARED-BRAIN/MODULES gates have already shipped.

**Explicit owner switch, 2026-09-30:** root AGENTS records the owner setting `activeAgentModelID` to the existing MiniCPM5-2B artifact for cleanup residency, while the Agent role remains cloud. Preserve that explicit choice. The prohibition on rewriting `activeAgentModelID` binds silent cleanup reuse; it does not undo this owner switch or authorize changing another role. Agent-local quality is a separate workload gate; sharing a file is not a recommendation.
