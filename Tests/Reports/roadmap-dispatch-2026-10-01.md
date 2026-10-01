# Parallel roadmap implementation — 2026-10-01

Owner authorization to continue implementation resumed after the sequencing
revision. This report records actual source work, not completion of phase gates.
Roadmaps are already in `roadmap/in-progress/`; no further folder move is needed.

## Ownership and prerequisites

- Root owns Agent-overhaul P3-01's production voice-route tests, coordinator,
  RealtimeAgent and capture files; shared app registrations, builds, installation
  and model-backed checks remain serialized with root.
- `module_foundation` owns MOD-02: Sidebar, NavigationState, MainWindow and a
  narrow routing helper in the existing ModulePolicy. MOD-01 is committed as
  `450dbaa`; no further runtime/model dependency is required for navigation.
- `artifact_identity` owns bounded SB-01b: legacy manifest-row verification in
  InstalledModelLibrary, the ModelLibraryStore pre-fetch producer, cancellable
  existing SHA hashing and artifact/library fixtures. SB-01a is committed as
  `4476a82`. Parent SB-01 is incomplete.

Workers read the current dirty tree and preserve foreign iMessage, dictation,
cleanup, Settings and website edits. They do not change roles/defaults, load or
download models, hash owner weights, create another store/queue/runtime, or run
concurrent app builds. Local claims and current ownership are recorded in the
ignored roadmap ledgers, index and BUILD-ORDER.

## Producer evidence

MOD-02's actual Observation-backed NavigationState accepted disabled destinations
through restoration, direct setters and routing helpers. The old producer fails
538 of 1,184 fixture checks; the fixed NavigationState and exact Sidebar producers
pass 1,340 checks. Removing setter normalization fails 342 of 1,340. The full
Observation fixture caught recursion in an early candidate; the final single-field
computed setter avoids it. Shared self-test navigation now uses the existing
harness defaults suite, leaving the owner's navigation preference untouched.
[MOD-02 report](modules/2026-10-01-mod02-navigation.md) contains reproduction and
limitations. Root build/install and Settings/panes/UI strings/store isolation passed;
rendered UI evidence remains.

SB-01b addresses the pre-fetch producer rejecting identical legacy alias rows
solely because they lack checked-byte proof. Tiny real downloader/library fixtures
reproduced missing reuse, proof persistence and durable reopening as
`MODEL_ARTIFACT_FAILED`. The main expanded suite subsequently returned
`MODEL_ARTIFACT_OK`, using actual byte hashing and the source pre-fetch method.
Proof is recorded on the original row/ID/path; mismatch, races and cancellation
preserve existing files and choices. Root's registered installed model-library check passed against the actual store. The final expanded isolated verification
returns `MODEL_ARTIFACT_OK`, including failed-hash/removal and stale-backend cases.
Root corrected a fixture-only throwing expression after the first build finished;
no compiler input was changed during the freeze. [SB-01b report](shared-artifacts/2026-10-01-sb-01b.md)
records reproduction, exact changed seams and pending integration. Source remains
frozen for root.

## Remaining checks

Root must complete serial build/install and the installed relevant regressions.
MOD-02 remains in progress pending integration/visual evidence and a scoped
commit. SB-01b remains in progress pending the registered app check and scoped
commit. No parent quality gate or phase is marked passed.
Built-in reuse remains a specific gap: `reloadFromDisk` synthesizes
`built-in/gemma-4-e4b` without proof on every refresh, and the notes downloader
does not retain its checked proof in the library. The SB-01b fixtures use
non-built-in manifest rows and do not establish zero-fetch builtin Gemma reuse.
Catalog/revision metadata, built-in/stale-proof adoption, cleanup/notes consumers,
concurrent fetch joining and deletion accounting remain SB-01 work. MOD-03 and
runtime/onboarding work remain separate tasks.

The unchanged Agent quick/full/owner and latency bars, model-promotion criteria,
privacy, effect/receipt contracts and user choices remain required.

## Root integration outcome

P3-01 is implemented with original routing/budget red→green and specific C1/nil
frontend mutation proof; restored actual worker resumes its next round in 8 ms.
All nine required flags pass. CORE is 17/18, sole unchanged wake failure.
[Root P3 report](voice-production/2026-10-01-p3-01.md).
SB-01b bounded manifest adoption is integrated; parent SB-01 stays open. MOD-02
source is integrated; required by-eye rendering review stays open. Scoped commits
exclude foreign iMessage, Settings, dictation/cleanup and site changes.
