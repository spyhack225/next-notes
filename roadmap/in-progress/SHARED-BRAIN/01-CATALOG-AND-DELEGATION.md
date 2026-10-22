# SHARED-BRAIN — catalog, independent roles and runtime (SB-01…03)

Read `00-README.md`. The filename is retained for links; SB-02 no longer delegates
meetingNotes to Agent. Paths are relative to `Sources/NextNotes/` unless rooted.

## SB-01 — SharedModelCatalog + canonical artifact reuse

**Blocked on:** nothing. **Effort:** re-estimate after resolver/adoption audit.

**What lands:**

* New pure `Formatting/LLM/SharedModelCatalog.swift`: initial MiniCPM5-2B,
  Qwen3-4B-Instruct-2507 and Gemma-4-E4B entries. Each records exact revision,
  file/quantization, URL, bytes and verified digest; re-verify at implementation.
  Keep per-workload recommendations separate from artifact metadata. No universal
  Qwen flip, no dynamic quality score or model selector on a user's turn.
* `NotesModels.spec` becomes a compatibility accessor for the notes recommendation,
  initially its current Gemma spec. MiniCPM cleanup reads the same candidate metadata
  and library artifact through its existing `MiniCPMModels` seam when available.
  No dependency on a new catalog class before this task lands; integrate sequentially.
* Extend `InstalledModelLibrary`'s existing resolve/adopt path: exact verified file
  present → same row/path; verified identical file at another path/name → adopt by
  identity, no copy; mismatch/unverified/corrupt/auxiliary → no successful reuse.
  Use existing download ownership to join an in-progress fetch of the same artifact.
  Missing metadata can be verified once off the turn path; do not trust basename.
* Preserve `built-in/gemma-4-e4b`, existing model IDs, role tokens and imported files.
  A new recommendation cannot turn the old file into a missing model or redownload it.
  One physical file counts once even when several choices reference it.

**Files:** new catalog; `Formatting/LLM/NotesModels.swift`;
`Support/ModelLibrary/InstalledModelLibrary.swift`, `ModelLibraryStore.swift`;
existing MiniCPM metadata/resolver seam (coordinate with OpenCode).

**Red-first:** exact MiniCPM reused by cleanup/notes/Agent with zero fetch/copy;
identical verified bytes under another basename reused; same name/different bytes
and different quantization rejected; simultaneous consumers join one fetch; invalid
or auxiliary file refused; legacy file/ID still resolves.

**Verify:** `make build`, `make install OPEN=0`, `make test`;
`--selftest-model-roles`, `--selftest-hf-search`, `--selftest-model-unopenable`.
**Done when:** metadata/adoption fixtures pass, existing choices/files unchanged,
and STATUS SB-01 records evidence. No recommendation quality claim yet.

## SB-01a — Verify the existing artifact producer before catalog integration

**Claimed 2026-09-30; child of SB-01, no unmet prerequisite.** The downloader's
matching-length destination shortcut skipped trusted digest verification, and
the library producer discarded the checked-byte identity. Repair those existing
seams before adding an unused catalog or treating expected metadata as proof.

Bounded files: `Support/ModelDownloader.swift`, `Support/ModelLibrary/InstalledModelLibrary.swift`,
the verified-row/reuse boundary in `ModelLibraryStore.swift`, additive proof type
and focused fixtures. Hash only at the existing background download/adoption
boundary; preserve interrupted/resumed transfers and the single download owner.
On a same-length digest mismatch, preserve the installed destination and throw.
Record actual checked digest/bytes only with a stable file stamp before/after
hashing and again at registration; a changed file must not be registered as
verified or run through post-download selection/deletion policy. Old manifest
rows decode with nil proof, never silently upgraded from a name or expected SHA.

Reuse a current verified, runnable, non-auxiliary existing row/ID/path when exact
trusted digest and size match. Add no duplicate row for one physical file and
change no role/default/runtime/cleanup setting. If a caller cannot safely consume
the existing ID, leave that caller's adoption explicitly pending. Missing trusted
identity does not pass reuse. Parent catalog metadata, legacy-file verification,
all-workload integration, concurrent fetch and deletion/quality gates stay open.

Red-first tiny on-disk fixtures call the real downloader/library and assert
same-size wrong bytes rejected, matching bytes reused, failure preserves files
and choices, digest case handling, valid/corrupt complete partials, old row decode,
proof round-trip, alias identity and stale-proof rejection. Existing model-library
self-test integration is coordinated with root; no concurrent app builds or
real-weight hashing/downloads. Record exact markers and remaining gates in
`Tests/Reports/shared-artifacts/2026-09-30-sb-01a.md` and STATUS.

## SB-01b — Verify legacy installed rows before fetching the same artifact again

**Claimed 2026-10-01; depends on committed SB-01a.** Older rows decode without
checked-byte proof. The current pre-fetch producer only reuses proven rows, so
an identical runnable file under another basename can be fetched again. Repair
that producer through the existing library/download seam, rather than adding a
parallel catalog, assignment store or download owner.

Bounded files: `InstalledModelLibrary.swift`, `ModelLibraryStore.swift`, existing
artifact/library self-tests and a focused report. Before an explicitly requested
download, current proof may reuse immediately; otherwise check size-compatible,
runnable, non-auxiliary legacy candidates against the requested trusted digest
off the main/user-turn path. This slice checks legacy **manifest rows** only;
the synthesized built-in Gemma row does not yet retain proof across refresh,
and built-in adoption plus stale-nonnil-proof re-verification remain parent work.
Persist successful checked-byte proof on the same
row/ID/path and recheck current row/file identity at recording and use. A failed,
missing-digest, changed, auxiliary or unrunnable candidate is never successful
adoption and must not be overwritten, deleted, selected or silently upgraded.
Preserve manifest metadata, trial information, imported files and stored choices.
Use no duplicate rows, copies, extra registry/queue or per-turn weight hashing.

Tiny actual on-disk fixtures must show red before repair and green afterward for
legacy alias reuse without fetch/copy, exact proof reopen, mismatch/preservation,
different trusted identity/quantization refusal, stale-proof/race rejection and
unchanged role/active selection. Workers run no heavy builds, benchmarks,
downloads or owner-weight hashing; root integrates shared registrations and app
checks. Parent SB-01 catalog/revision metadata, cleanup/notes adoption, concurrent
fetch joining, deletion accounting and prescribed quality gates remain open.

## SB-02 — Independent meetingNotes, Agent and cleanup choices

**Blocked on:** SB-01. **Sequence:** before SB-03 on shared files.

**What lands:**

* Keep `.meetingNotes`, its own stored choice and `.agent` independent. Extend
  `ModelRole.canUse(.installedModel)` to meetingNotes with real runnable checks.
  Preserve existing tokens and settings; no redirects from `setChoice` to Agent.
* `resolve`/`provider` for notes follow the notes choice. Both roles may reference
  one artifact or different artifacts. `activeAgentModelID` stays an Agent preference,
  never the authority for every local workload. Read-only resolution stays read-only.
* Preserve `openRouterNotesModelID` and its context settings; never merge them into
  the Agent key. Per-role cloud readiness and consent are checked before a request.
  P4-09 consent covers Agent lanes only; notes transcript upload needs its own
  existing or explicitly introduced workload consent, scoped once to that choice.
  Document the actual notes consent seam before enabling it; no consent → local
  fallback or honest unavailable state, never inherited Agent authorization.
* Cleanup keeps its existing engine/settings seam, including OpenCode's MiniCPM
  default + Apple guard/fallback. Do not add a duplicate cleanup assignment store
  or force it into an unrelated Agent role. Reuse the shared artifact resolver.
* `repairUnanswerableRoles` repairs each affected choice without changing healthy
  siblings. Deletion/trial policy considers every role and cleanup consumer.
  `Meeting.notesModel` and usage rows name actual execution, not a global label.

**Files:** `Support/ModelRoles/ModelRoleStore.swift`, its self-test;
`InstalledModelLibrary.swift` / `ModelLibraryStore.swift` consumer checks;
notes consent caller/UI/settings if the audit finds no valid existing seam;
cleanup resolver only by agreement with its executor.

**Red-first:** Agent A/notes B/cleanup MiniCPM stay distinct; setting any one leaves
others unchanged; equal choices share a path; notes work with Assistant off;
cloud IDs/context stay independent; Agent cloud consent alone cannot upload notes;
old settings load losslessly; repairs do not rewrite healthy siblings.

**Verify:** build/install/test; `--selftest-model-roles`, `--selftest-settings`,
`--selftest-notes <fixture-wav>`, existing cleanup router/structure cases.
**Done when:** independence, consent and migration are pinned; STATUS updated.

## SB-03 — Request uses its chosen model; runtime and labels are correct

**Blocked on:** SB-01, SB-02. **Coordinate:** P0-14/P0-18/P1-28, P3-07, OpenCode cleanup.

**What lands:**

* Extend the existing `NotesModelRuntime` request/native ownership seam so resolved
  local artifact identity remains bound from acquisition through generation. Capture
  actual model metadata from that request. Do not resolve from Agent selection later.
* Awaiting `select` does not prove the requested model became active when its swap
  was deferred. Require exact identity at execution. Never run a different loaded
  file then depend on an output guard, or log it as the requested MiniCPM/notes model.
  Native ownership precedes compute ticket acquisition; preserve cancellation and
  lock ordering. One loader, no per-module actors with independent weight ownership.
* Same artifact can reuse resident weights. Keep workload prompts/history separate;
  use existing prefix ledger/reset rules. Separate contexts are capacity decisions
  under P3-07, not another download or a mandatory requirement of this task.
* Different artifact + active voice lease: do not evict or wait indefinitely on the
  user's cleanup path. Cleanup takes its existing bounded Apple fallback; background
  notes yield/wait visibly and remain cancellable. Shared runtime release/restoration
  cannot overwrite a newer user choice or another request's ownership.
* Provider labels, prewarm, NotesService/MeetingSession and diagnostics follow the
  requested role and actual acquired artifact; update hardcoded Gemma descriptions
  only where they falsely describe execution, preserving catalog/legacy/history names.

**Files:** `Formatting/LLM/NotesModelRuntime.swift`, `LlamaLLMProvider.swift`,
`LLMProvider.swift`; `ModelRoleStore.swift`; notes prewarm/callers where needed;
shared-runtime and cleanup ownership self-tests; existing eval diagnostic readers.

**Red-first:** concurrent Agent A/notes B/cleanup MiniCPM execute correct files;
deferred swap never executes as requested; held voice lease survives cleanup request;
same artifact reused with isolated prompts; cancellation frees ownership; late restore
cannot clobber another choice; logs identify Apple when fallback ran.

**Verify:** build/install/test; `--selftest-llm-metal`, `--selftest-llm-prefix-cache`,
`--selftest-model-roles`, `--selftest-voice-scheduling`, `--selftest-concurrent-voice`,
`--selftest-cleanup-router`, `--selftest-notes <fixture-wav>`.
**Done when:** correctness and bounded fallback proven; latency under overlapping
work recorded; no claimed simultaneous-model support without measurement; STATUS updated.
