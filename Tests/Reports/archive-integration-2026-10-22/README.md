# Archived source integration — 22 October 2026

Baseline: `0dbba940`. The earlier archive merges retain source snapshots but do not activate their implementations. This follow-up ports selected source hunks into the canonical application. No checkout, model, owner store or installed app is replaced.

## Reviewed selection

| Archived work | Integration decision and reason |
| --- | --- |
| thinking-review | Port `8e4243d6` plus `0be933e6`: hide marked reasoning at the native stream producer, hold split controls, preserve visible incomplete prefixes at EOF. Preserve newer runtime admission, scheduling, cancellation and usage accounting. |
| google-c | Port reviewed round-five backend `7ac342ce`, excluding duplicate recovered-history prerequisite. Preserve newer calendar failure evidence and credential-free Settings previews. Reconcile account/grant generation and calendar cache publication at their existing producers. Add original native fixtures and dispatch. This is the reviewed backend; the historical proposal for a new one-click Settings/onboarding card was never built and is not claimed here. Real Google grants and public verification remain untested. |
| clockfix | Port `083a2c1b`: pinned evaluation clock reaches account reads and grounding defaults. Explicit clocks/dates retain precedence. Scripted provider is restricted to diagnostic C01/C04 and cannot qualify a model. |
| dictation-perf snapshot | 183 of 196 dirty source paths are byte-identical to baseline. Remaining paths contain older capture/conversion/coverage implementations or older shared App/model/settings code; preserve canonical later fixes. |
| agent-delivery | Snapshot has no uncommitted source delta; original HEAD already in canonical history before archival. |
| thinking | Separate per-request thinking budgets/model sampler policy are not the independently reviewed stream repair. Retain for a dedicated native semantic/budget evaluation; do not silently change the current runtime policy. |
| google | Earlier Mac-account/tool-routing work overlaps later canonical authority changes and the reviewed Google-C backend; reconcile through the latter instead of restoring stale whole files. |
| catchup, catchup-ui, catchup-ui2, catchup-audio, catchup-final | Existing schedules are retained. Final candidate still uses saved-file PCM outside the shared echo-reference/audio owner (its own round-two report explicitly rejects this transport). Do not introduce the parallel playback path into the live app. Final candidate supersedes the earlier UI variants; their separate snapshots are not additional features. |
| catchup-port | Documentation only; no production source delta. |
| listen, listen2 | Resident/prefill candidates did not satisfy native cold completion and latency/quality gates. Do not promote their routing/model experiments. |
| voice-mini | Resident answerer failed qualification (0/5); no-cold-load diagnostic repair depends on that excluded experiment. Preserve current answerer and full-duplex paths. |
| no-apple, voice-settings-ui | Old two-engine policy and settings census conflict with the newer owner-requested Qwen/Phonon integration actively owned by the TTS agent. Do not replace its explicit choices with stale files. Text-only failure/approval and recovery protections require a reconciled current-engine native check. |
| voice-ack, voice-ack2 | Latest successor snapshot `fc8aa2af` retains an actual failed round-two check: `VOICE_ACK_CACHE_CHECKS=57 failures=1`, “held prewarm entered actual cache producer,” then `VOICE_ACK_FAILED` (exit 1). Its census repair passes separately. Resolve this remaining regression and reconcile current-engine speech/output ownership before integration; the earlier 120ms file-fed acknowledgement-start result does not override the later failure. See `ack-latest-retained-verdict.json`. |
| bakeoff2 | Evidence only; resource refusals do not choose/promote a model. |
| tooling | Historical development queue is preserved as evidence. Current machine coordination uses agent-relay; do not introduce a second queue or a product gate. |

All 20 branch source inventories are retained in `source-comparison-before.json`; `reflog-revision-review.json` records the 64 additional retained revisions. These include rebased/squashed voice predecessors, diagnostic scaffolds, disproven Settings lifetime hypotheses, and older meeting/dictation/durable-worker implementations; the current dictation retry (`canStartHold` / error generation), capture coverage and worker backing checks are retained. Current Windows copyright and root license already match the retained licensing changes. `older-reflog-feature-comparison.json` records selected file comparisons; differing old snapshots are not restored over newer implementations. Recovery snapshots remain reachable through main. Superseded/rejected/pending candidates are explicitly distinguished from integrated source. Original review/evidence remains available from the snapshot IDs in the inventory, including `.worktree-preservation/ignored.tar.gz` for ignored author/reviewer reports.

## Coordination and verification

The TTS agent owns the active release compiler, Speech, App, ModelsSettings and Makefile. No Swift source writes occur during its baseline compile. After baseline regression, reviewed disjoint ports share the ASR agent's bounded measurement slot; a single coordinated optimized rebuild will serve both scopes. No model measurement is presented as uncontended while a compiler runs.

The frozen 658-case stream fixture is extracted from `0be933e6`. Its component adapter substitutes model/native decoding and runtime setup; actual output producer logic remains the code under test. Original native evidence for the three selected repairs is copied byte-for-byte under `retained/`, with original commit/path and SHA-256 in `retained/provenance.json`. These historical verdicts do not qualify this build.

Current component result: original `0dbba940` decoded-piece loop adapter fails 552 assertions across the unchanged 658 cases; integrated producer passes all 658. Both compile/run processes exited and disposable binaries were deleted. `stream-component-summary.json` pins the fixture/source/binaries and substitutions. Full-app/native entry, vocabulary, store isolation and original user-flow verification are reported separately; a component pass cannot stand in for them.

Status: 34 source/build paths applied and pinned in `source-ready.json`; full application module typecheck and optimized release link pass (`combined-typecheck.json`). Eleven selected native root flags, including the once-only CPU/private-S1 prefix-cache companion after the serial TTS window, pass on executable `6369272fa8fcc9cee16658f2f56288e5200fc8cb5bd17ff81f3f8e27175b513f`. The actual Makefile packaging target passes seven synthetic boundary cases (`oauth-packaging.log`). The first peer build failed in its TTS benchmark Codable declaration before these ports; the TTS owner repaired it. No binary from that failed build is accepted.


## Catalog repository-link producer repair

During this integration, another agent had uncommitted benchmark reports. The catalog scanner included those paths even though the integration commit and a clean CI checkout could not contain them. An unchanged synthetic peer-report test fails against the original scanner (`catalog-peer-original.log`). Discovery now reads the Git index, including staged evidence and excluding uncommitted reports; registered result manifests remain automatically discovered. All 12 catalog boundary tests pass (`catalog-peer-fixed.log`). Stage the run/report before the final render so generated repository links match the commit. No peer report or work is staged by this integration.


## Current optimized app verdicts

`check-native.py` runs the native fixture batch serially under the agreed slot, with a 115-second outer deadline and per-flag timeout. `native-summary.json` pins the exact executable and exits; owned processes joined and temporary fixtures were removed before handoff.

| Check | Current result |
| --- | --- |
| Google connect | Native exit 0, 402 actual assertions, `GOOGLE_CONNECT_OK` |
| GWS, Calendar Google errors, Mac accounts, capability manifest, UI strings | Five native exits 0 and their expected root markers |
| Chat template | Native exit 0; 658 stream cases / 0 failures, live vocabulary checks, `CHAT_TEMPLATE_OK` |
| Notes truncation | Native exit 0, `NOTES_TRUNCATION_OK` |
| Scripted clock | Native exit 0; actual parser/tool/fixture/grader C01/C04 score 2/2, default and explicit-clock probes pass |
| Store isolation | Root exit 0; 21 files and 0 internally observed defaults unchanged |
| External preference witness | Owner domain exported in memory before/after: all 89 keys hash-identical; values never saved or printed |
| Prefix cache | Native exit 0, `LLM_PREFIX_CACHE_OK`; 646/666 tokens reused on existing S1-mini, exact model SHA unchanged; external 21-file/89-key witness unchanged |

Store isolation retains the inherited nested `TOOLLOOP_PRODUCTION_FAILED` and 18 browser WRONG lines. This is a failed embedded functional scope, not a browser pass; it does not revoke the narrower file/preference witness. No fixture guard, grader, timeout or acceptance bar was relaxed. `native-clock.md` / `.json` retain the generated clock report. Real Google consent, visible Settings interactions, physical voice, model quality, performance qualification and default promotion remain outside these synthetic/isolated checks. The installed owner app is unchanged.

The prefix-cache companion ran exactly once (`prefix-cache-summary.json`), with a private CPU runtime, a 75-second self-test timeout and an 85-second outer bound. Its 1.43s/0.17s prefill observations are diagnostic, not reference-machine throughput or full-duplex qualification. No model was downloaded or deleted; the owner’s existing 484,219,808-byte S1-mini hash remains `3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634`.
