# SHARED-BRAIN — workload benchmarks and shared-file gate (SB-07…08)

## SB-07 — Pick recommendations per workload on evidence

**Blocked on:** SB-01…06 for final runs/flips; corpus preparation may start earlier.

Write `Tests/Reports/MODEL-ROLES-BENCHMARK-<date>.md`. Keep exact artifact,
quantization, build, planner path, prompts/corpus version and flags with every row.
Do not change the corpus/grader between models. Unavailable runs are incomplete,
not scores. No benchmark writes owner choices/history or downloads unrequested files.

| Workload | Quality gate | Performance/resource evidence |
|---|---|---|
| Agent | Fixed quick diagnostic; two full runs ≥25/30 and owner-case gates from AO Phase 1; no LEAK/ERROR/fabricated effects | First verified result/answer and total p50/p95, load/prefill, repairs, disk/RAM |
| Meeting notes | Fixed short/long meeting corpus with decisions/actions/owners and source facts; factuality, omissions, attribution, coverage and truncation | Single-pass/map-reduce rate, tokens/s, duration, disk/RAM |
| Dictation cleanup | Existing cleanup corpus with rawCleanup and guarded output, original-word/name/number preservation, structure, Apple rejection/fallback cases | Warm/cold and overlapping-work p50/p95, fallback rate, disk/RAM |

**Meeting corpus task:** author sanitized transcript/audio fixtures and expected
source facts before comparisons. Set measurable acceptance criteria before runs,
record review/rubric, and do not choose thresholds after seeing a favored candidate.
`--selftest-notes-truncation` uses fake providers: it is a retry-behavior regression,
not a candidate truncation measurement. Live candidate passes must assert the actual
provider/artifact so harness defaults cannot make three rows test the same model.

**Agent paths:** paired existing planner/Needle-first results are separate arms.
P1-31 owns whether Needle-first becomes normal; SB-07 cannot override that decision,
lower its bar or choose a model from a nine-case prototype. Capture latency regressions
under simultaneous notes/cleanup as well as isolated turns.

**Current Agent diagnostic (2026-09-30):** [P1-31a paired report](../../../Tests/Reports/toolloop-live/2026-09-30-p1-31-investigation.md)
uses exact existing artifacts and one frozen binary. Four quick candidate comparisons
and Qwen full ordinary 17/30 vs Needle 16/30 (owner 7/10 vs 8/10) qualify no
recommendation; whole-case p95 is 49.038 vs 51.012 s. Gemma/Qwen3.5 Needle arms
are incomplete on engine timeouts. This supplies Agent-only diagnostics, not SB-07
completion, notes/cleanup quality evidence or overlap admission. Parent P1-31 stays open.

**Cleanup:** the owner already chose MiniCPM + Apple guard/fallback. Coordinate with
OpenCode and reuse its reports/corpus; do not overwrite its default or claim its
implementation/gate complete. Later alternatives need cleanup-specific evidence.

Initial candidates: MiniCPM5-2B, Qwen3-4B-Instruct-2507, Gemma 4 E4B. Additional
models are catalog entries and report rows. Use existing per-family templates; arch
support follows P0-16/upstream policy. No model-specific provider branches to win.

Regression flags: model roles, llm-metal, prefix cache, function calls, notes and
notes truncation/longform, cleanup router/structure, voice scheduling/concurrency.
Cloud fixture comparisons require explicit `--allow-cloud`; role consent still applies.

Change only the recommendation for the workload whose gate passed, cite the report,
and preserve explicit existing choices. A failed Agent gate cannot be hidden by a
strong notes result. If no candidate passes, retain the current/default fallback and
record the unresolved quality gap; do not print a successful recommendation flip.

**Files:** report and fixture/harness files, catalog recommendation data only.
**Done when:** ≥3 candidates measured for applicable Agent/notes workloads, cleanup
report integrated, recommendations supported by their own gates, HF/online/reuse
regressions pinned, overlap latency recorded; STATUS names incomplete work honestly.

## SB-08 — `--selftest-shared-brain` pins independent roles and shared files

**Blocked on:** SB-07. Keep the legacy flag/`SHARED_BRAIN_OK` marker for links.
Implement a runner in `Formatting/LLM/SharedModelSelfTest.swift`; no owner stores.

Red-first cases:

* Catalog entries have complete verified metadata; per-role recommendations resolve;
  old IDs/settings load; legacy NotesModels alias resolves the notes recommendation.
* Agent A/notes B/cleanup MiniCPM remain independent; equal artifacts reuse a single
  path; changing/resetting one role leaves siblings and cloud IDs/context unchanged.
* Same artifact under another basename is adopted; same name/different bytes,
  other quantization and auxiliary head cannot be accepted. Two consumers join one
  fetch; artifact disk total counts once. Synthetic fourth candidate needs no branch.
* Full disk with Apple gives workload-local fallback and zero fetch; unrelated model
  does not count as ready; no Apple answers honestly. Cleanup unavailable/busy/failed/
  rejected → Apple from original input, with actual-provider usage records.
* Held voice lease/deferred swap never executes MiniCPM/notes request on another file;
  cancellation and late restore preserve ownership and newer user choices.
* Disable Meetings while Agent or cleanup uses the file → no deletion. In-flight
  notes retain files even after module-off. Sole unused file offered once after work
  releases it; explicit library deletion preserves repair/trial invariants.
* Agent cloud consent alone never authorizes notes/dictation upload. Shared weights
  never widen graph/file consent or merge conversation/notes/cleanup histories.
* Existing HF runnable-file selection, probe/trial/resume, legacy decoding and
  independent OpenRouter choices remain functional. No execution label hardcodes
  Gemma when another file/Apple ran; historical/catalog names remain valid.

`SHARED_BRAIN_OK` means the functional contract passed, not that every model's quality
is good. SB-07's role-quality reports remain a separate required exit gate.

**Files:** runner, `NextNotesApp.swift` registration, `Scripts/acceptance.sh`
INTEGRATION entry, `AGENTS.md` flag registration, STATUS (single-writer coordination).
**Verify:** build/install/test; shared-brain, model roles, notes, cleanup router/
structure, llm-metal/prefix cache, voice scheduling/concurrent voice;
`make acceptance TIER=integration`. Red-first verified per branch, no thresholds
or skip semantics changed to get green. STATUS closes only measured gates.
