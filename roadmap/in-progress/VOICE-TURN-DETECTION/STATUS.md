# Voice turn detection status

Updated: 23 October 2026. Candidate implementation is integrated in source and remains
opt-in while qualification is incomplete. Parent P2-04/P2-05/P2-07 acceptance is unchanged.
Actual measurements and retained failures: [implementation report](../../../Tests/Reports/voice-turn-2026-10-23/README.md).

| Item | State | Evidence / next action |
|---|---|---|
| Source comparison and implementation plan | complete (documentation) | Overview + implementation; HEAD/dirty-tree caveat recorded |
| ASR agent coordination | response received | Direct reply; matrix, ownership, watermark/finality/EOU contract in alignment doc |
| TTS agent coordination | response received | Relay reply received/acknowledged; candidate matrix, PCM timing and cancellation limits recorded |
| Benchmark protocol and case recipes | complete (specification) | `02-BENCHMARKS.md`, `benchmark/cases.json`; seven synthetic PCM cases materialized; all original failures retained |
| Offline trace scorer | complete (offline tooling) | [21 authored checks + CLI pass/fail controls](benchmark/VERIFICATION.md); cannot collect native latency |
| VTD-00 source freeze + native original baseline | partial | ASR/TTS coordination complete; historical original retained, paired current-app comparison remains open |
| VTD-01 Smart Turn assets/wrapper | implemented; native component tested | Immutable hashes for every compiled file, verified staging, bounded owner and native drain |
| VTD-02 Silero events + cold window feasibility | implemented; partial | Exact512-frame recurrence; native onset93–126ms on seven paced synthetic inputs, physical/cold-zero-preroll unproved |
| VTD-03 context + ASR progress | implemented; authored controls pass | Eight-second ring, ordered publication/native generation fences, complete bounded successor replay |
| VTD-04 endpoint policy | implemented; quality FAIL | Native model calls mark unfinished split-synthesized prefix complete at all six protected pauses; ordinary rollout held |
| VTD-05 speculation/playback/lifecycle | source integrated; partial | Existing effect/playback owners retained; cancellation joins native work; physical duplex/soak open |
| VTD-06 native benchmark collector | implemented; native21-trial FAIL | 21 real paced production capture/ASR/tick/commit trials;15 premature splits and9 unverified tails; no audible stages |
| VTD-07 calibration + providers | open | No threshold separates observed unfinished prefix from finished sentence; held-out human/continuous speech and every provider pair needed |
| VTD-08 physical/soak/rollout | held | No installation/default promotion; candidate opt-in, quality and reference-machine acceptance open |

## Verification scope

Offline checks cover authored trace validation and scoring, deliberately green and red
timings, protected pauses, missing stages, duplicate commits, failed/absent native cases
and sample-count reporting. They do not load Silero/Smart Turn/ASR/TTS or exercise the app.
Native component performance and the protected-pause quality failures are now recorded in the implementation report; whole-pipeline and physical acceptance remain separate.
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


## Implementation coordination, 23 October

ASR peer confirmed the full revisable-snapshot contract: `isFinal` closes the session,
not a voice turn. Dictation-only Phonon/Voz choices do not replace voice Apple/Parakeet.
Apple publishes this result's recognized audio end; local progress is valid completed
80ms shifts, excluding buffered lookahead. Native publication revisions are announced
before the MainActor hop and checked at the commit/reset transaction.

The existing capture ring recovers all post-cut audio, including already-consumed
successor chunks. It reuses the existing six-second ASR backlog, suppresses duplicate
late enqueue/retired returns and refuses a commit if the full tail cannot fit. No
second microphone, ASR queue, store or usage ledger is introduced.

TTS stays owned by its existing agent. Its separate owner-authorized temporary
Phonon preference is preserved; generated PCM, physical audible onset and complete
voice response remain distinct measurements. These tests replace replies with the
existing test sink and do not load TTS, execute tools or change devices.

The32nd recipe adds the observed600ms regression without removing the original700ms recipe. Seven synthetic cases are materialized; absent recipes remain required coverage.

Final validation: optimized full application build passes1060.07s; final app
`TURN_POLICY_OK`; offline21 controls pass. Upstream and CoreML agree on all13
snapshots (maximum probability difference0.00150), including all six incomplete
prefix failures. Native application child exits0 and joins after21 trials; full
scorer deliberately exits1 and keeps qualification red. Preservation verifies
25 store/settings files and143 meeting files unchanged across native runs.
No installation or normal-default promotion. See the linked report for exact
source/binary pins, latency/word boundaries, cleanup and remaining physical gates.

Collector-only follow-up: a full optimized rebuild passes763.43s, policy controls
pass again, and two real fresh captures both carry correct `cold_capture` labels.
The original21-trial nominal labels stay preserved/disclosed. Framework/rpath
preflight rejects the observed malformed probe before launch; the signed fixed
probe completes native runs. The final repeated25-store/143-meeting preservation
check passes. These functional controls do not change speech-quality acceptance.
