# Voice turn detection status

Updated: 22 October 2026. This ledger separates delivered planning/tooling from product
integration. Parent P2-04/P2-05/P2-07 acceptance is unchanged.

| Item | State | Evidence / next action |
|---|---|---|
| Source comparison and implementation plan | complete (documentation) | Overview + implementation; HEAD/dirty-tree caveat recorded |
| ASR agent coordination | response received | Direct reply; matrix, ownership, watermark/finality/EOU contract in alignment doc |
| TTS agent coordination | response received | Relay reply received/acknowledged; candidate matrix, PCM timing and cancellation limits recorded |
| Benchmark protocol and case recipes | complete (specification) | `02-BENCHMARKS.md`, `benchmark/cases.json`; no audio materialized |
| Offline trace scorer | complete (offline tooling) | [21 authored checks + CLI pass/fail controls](benchmark/VERIFICATION.md); cannot collect native latency |
| VTD-00 source freeze + native original baseline | todo | Refresh peers' final source/lock, claim window, run unchanged production path |
| VTD-01 Smart Turn assets/wrapper | todo | Verify pinned export + complete hashes, implement native owner |
| VTD-02 Silero events + cold window feasibility | todo | Existing 256 ms/confirmation path cannot establish cold <=200 ms |
| VTD-03 context + ASR progress | todo | Audio revision and per-turn processed/publication watermark |
| VTD-04 endpoint policy | todo | Original/fixed protected pauses, complete questions, stale-result rejection |
| VTD-05 speculation/playback/lifecycle | todo | Current generation/echo/effect authority preserved |
| VTD-06 native benchmark collector | todo | Real paced input/commit/render traces into offline scorer |
| VTD-07 calibration + providers | todo | Freeze thresholds; held-out corpus; every shipping pair smoke |
| VTD-08 physical/soak/rollout | todo | Reference Air, routes, concurrent load, normal session and rollback |

## Verification scope

Offline checks cover authored trace validation and scoring, deliberately green and red
timings, protected pauses, missing stages, duplicate commits, failed/absent native cases
and sample-count reporting. They do not load Silero/Smart Turn/ASR/TTS or exercise the app.
Native performance and model accuracy remain **unrun** in this roadmap-writing task.
The actual run used 21 authored self-checks and a 31-case x 30-trial authored CLI control;
see [verification](benchmark/VERIFICATION.md). There are 31 fixture recipes, not 31 audio files.

## Evidence inherited, not rerun

- P2-04 Smart Turn remains `todo` in AGENT-OVERHAUL STATUS.
- P2-05 retained cold duck ~593 ms fails 200 ms; warm replay ~146 ms is sample-time only.
- P2-07 native model reuse is bounded evidence; cold fresh input still needs roughly
  310 ms fill/confirmation on the current path. Residency is not a latency repair.
- TTS candidate source was uncompiled and ASR candidate adapters unimplemented at their
  coordination replies. Consult their final reports; no cross-provider native pass is claimed.

**Same-day TTS follow-up:** the peer now records five native generated-PCM component
comparisons and muted source/renderer checks. Reviewed its README/accepted-results and
current renderer/meter source; [requirements and scope](04-TTS-AUDIBLE-ALIGNMENT.md)
were sent back directly. Existing RMS probes do not retain acoustic-onset timestamps;
render receipts include zero PCM and delayed polling. No physical audible-start or
default-promotion claim follows. VTD product tasks and native turn benchmarks remain todo.

## Completion record required later

For each task add date, responsible producer, original failing case/source/binary pin,
fixed result, actual native versus substituted boundaries, peer integration receipts,
resource window and remaining parent gates. Document-only updates never change a product
row to done. Keep failure/absent/unsupported results; never erase a red original result.
