# PL-12 phase 2 — listen2, 8 October 2026

Step 1 source investigation is complete. Step 2 is blocked before its required
fresh native baseline and RED regression. No preparation behavior, model choice,
default, runtime, scheduler or audio path has been changed.

Inspected worktree: `claude2/listen2`, base `c6d850c`. Canonical sources and the
roadmap were read only. This analysis uses the existing production call sites and
the retained October 5 native run cited by the October 8 audit. It does **not**
measure the complete current main or substitute that old run for this brief's
required fresh baseline. The old paused branch reports and the rejected
single-decision report were also read.

## Where the retained 0.671s and 2.448s go

Historical authored haiku fixture, Apple Foundation Models split frontend, Pocket
TTS, one warmup excluded and five counted file-fed turns. Original retained log:
`~/Library/Caches/NextNotesBuild/integration/listen-acceptance/green-native.log`,
SHA-256 `d907bdbd05d766d99592eb8794e2b231f2b8b01ec3714e4cc65a7ded4fe1f064`.
The compact [extracted columns](Tests/Reports/pl12-listen2/retained-latency.json)
preserve all five counted rows. Values below are seconds, nearest-rank p95.

| Historical measure | Median | p95 | Min | Max |
|---|---:|---:|---:|---:|
| L1 onset to preparation handoff | 0.671 | 0.678 | 0.659 | 0.678 |
| L2 endpoint to first answer consumed | 2.448 | 2.557 | 2.309 | 2.557 |
| L3 endpoint to first audible | 2.649 | 2.784 | 2.521 | 2.784 |
| Speech end to committed endpoint | 1.008 | 1.021 | 1.003 | 1.021 |
| Endpoint to frontend request | 0.019 | 0.021 | 0.017 | 0.021 |
| Endpoint to route done (per-row L2 minus route-to-token) | 1.056 | 1.172 | 0.915 | 1.172 |
| Route done to first answer token | 1.385 | 1.394 | 1.319 | 1.394 |
| First clause to Pocket PCM | 0.119 | 0.127 | 0.109 | 0.127 |
| First PCM to audible | 0.094 | 0.104 | 0.092 | 0.104 |

**L1 is dominated by the first ASR partial.** The first native local partial in
the counted turns arrived at voice+0.664/0.669/0.655/0.660/0.667s. Preparation
handoff followed at 0.671/0.676/0.659/0.669/0.678s: differences 7/7/4/9/11ms.
The two logged clocks/rounding are not a precise main-actor queue benchmark, but
they establish that the roughly 670ms is overwhelmingly recognizer availability,
not the removed four-word or 220ms gate. Current `noteModelPartial` stamps
`asrFirstPartial`; its actual consumer reaches
`prepareResponseForRecognizedSpeech` and then `prepareResponseIfUseful` without
the minimum speech duration gating useful lexical preparation. The shadow floor
retains that independent duration condition. `LocalVoiceTurnDetector` uses
`StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: 320)`. This cadence is
not itself a first-token or sub-200ms ASR guarantee.

L1's current timeline note is stamped immediately **before** the actor handoff to
`FrontendResponder.speculate`. It is not native prefill entry/completion. A future
diagnostic must report native entry and queue separately in the same timeline
notes, preserving the historical handoff column rather than relabeling it.

**L2 is dominated by Apple model work.** On each retained counted turn,
`L2 - route_to_first_token` leaves 0.915–1.172s from commit until routing finishes;
another 1.319–1.394s then elapses before answer text. Their medians do not need to
sum exactly to the headline median. The request construction is only 17–21ms.
The retained route column reports total 4.222–4.482s and overlaps preparation;
it is not an additional cost to add to L2. Old provisional revisions and the
generation identity must be inspected before interpreting this total as the
duration of one particular final route. Current `VoiceLatencyTimeline.mark` now
replaces the route start/done pair on a new route start. No per-generation native
trace was collected here to qualify that newer behavior.

Current `streamSplitDecision` collects the complete typed Apple route before
starting `streamSplitAnswer`. Apple answers use the exact staged session where
admitted. The SDK exposes prewarm, not an application-owned KV prefill API. That
route-to-first-token span includes answer session/SDK work and consumer delivery;
the retained columns cannot isolate Apple kernel TTFT from every one of those
hops. Nevertheless it is the largest individual measured L2 component.

EOU endpointing adds about one second **before** L2/L3's committed-endpoint origin.
It is material to felt response time but cannot explain the 2.448s *after* that
origin. Pocket preparation is **after** answer text: warm counted clause-to-PCM
median119ms, then PCM-to-audible94ms. It dominates neither L1 nor L2. The cold
warmup's Pocket cost was larger and is excluded from these warm distributions.

The historical request-to-lane column is rounded 0.000s; it is not proof of a
zero-wait native llama lease. Current split Apple routing takes no local compute
ticket. The llama answer diagnostic acquires its own existing runtime reservation
and realtime compute lane. A fresh native run is needed to measure that wait.

Both retained L1 and L2 miss 200ms. Removing llama answer prefill alone cannot
remove the remaining validated Apple routing work or make unavailable ASR words
arrive sooner. No listening or latency gate is promoted here.

## Exact prefill seam and smallest proposed diff

The old `listen/RESULT-previous.md` correctly identifies the seam:
`NotesModelRuntime.preparePrefix(_:context:jobID:optional:)` under `withLane`.
It renders the loaded family's template, tokenizes with its vocabulary/BOS rule,
uses `PrefixReuse.keepCount(cached:prompt:)`, trims sequence0 from the exact
shared token prefix with `llama_memory_seq_rm`, and decodes only the new suffix.
The existing `kvTokens` ledger is updated after each successful native chunk.
Removal refusal clears the native memory and ledger before a full prefill.

**The old cancellation warning is stale on this base.** Both `preparePrefix`
and `streamWhileScheduled` now preserve known successfully decoded entries on
`CancellationError` and clear them on other decode errors. Existing
`PrefixCacheSelfTest.cancellationReuseFailures` probes partial native prefill and
completed prefill cancelled before sampling, expecting128 reused tokens or
promptCount-1 respectively. This is inspected source and retained test intent,
not a fresh passing verdict.

Proposed runtime addition: `prepareInteractiveConversation(system:messages:maxTokens:)`
on the existing actor. Enter `withLane(.realtimeAgent)`, load/check vocabulary,
render/tokenize **the same** prompt as `streamInteractiveConversation`, validate
the same context budget, call `ensureContext` with the eventual sampling budget,
then `preparePrefix` and return existing prefill statistics without constructing
or running a sampler. Schedule idle handling through the existing seam. A
completed prefill leaves `kvTokens` intact and releases the native reservation
and compute ticket. A revised rendered prompt trims exact tokens through that
same method; common words alone are insufficient.

No new token ledger, cache, model runtime, queue or long-held speculative lease
is needed. At commit the existing sampling stream revalidates the full rendered
prompt through `preparePrefix`, replaying at least its final token for fresh
logits. Thus a matched undisturbed prefill reduces commit to reservation plus
one-token decode/sampling. Intervening notes/tool work, model/context changes,
or a final ASR revision may require more decoding; do not promise sampling-only
in those cases. No new sequential wait on a speculative task belongs at commit.

`LlamaLLMProvider.runtime` is already accessible: the frontend can call the new
runtime entrance through that exact provider, with no change to the three
off-limits files. Reuse the coordinator's existing revision task and frontend's
speculative ownership/correlation slot. The slot must distinguish prefill from
an answer buffer: prefill completion is never answer success. A stale/empty
revision must cancel only its own earlier producer; successfully completed native
chunks remain reusable, but no stale route/control/result may be delivered.
Answer generation starts only at committed EOU in this diagnostic.

Routing is an unresolved acceptance boundary, not permission to repeat the
rejected single-decision experiment. Retain complete validated split routing.
If it has not finished by commit, report its remaining latency honestly. Moving
to native routing would require separate authored/native routing and history
qualification; this brief supplies no evidence to adopt that alternative.

## Candidate and RED-first sequence when the machine is available

Choose resident **MiniCPM5-2B, thinking off**, only for the answering experiment.
Apple remains the owner's default and the split route remains validated. Use
the existing isolated `--voice-latency-model` resolution, additionally requiring
an explicit proposed `--voice-latency-prefill` switch and the exact verified Mini
artifact. No Settings or role-store selection changes. This switch is a design,
not implemented code. The current Mini template already closes the thinking
prefix; it still needs real quality and first-text evidence, especially given
the other agent's retained stream/control-marker concerns.

1. Run fresh baseline on the same retained authored WAV: SHA-256
   `ec9f48e5b38281e2ef3022904db9eb2e3eb5b69bdcbaab94faf000a9c91fbeab`.
   Verify that hash before use. It exists in the historical integration fixture
   directory; the default `voice-fixtures/haiku16k.wav` is absent.
2. Add scripted/fake native backing to the existing isolated test seam, then
   capture RED for prefill-only entry: no sampling, exact append/revision trim,
   completed-prefix retention, failed native decode invalidation, same-context
   sampling at commit. Preserve the actual renderer/tokenizer/native reservation
   admission rather than replacing the coordinator with a helper.
3. Add the runtime entrance and make those same tests GREEN. Add coordinator/
   frontend slot RED cases for short/revised/equivalent/empty partials, stale
   task/correlation/context, no speech/history/tools before commit, no blocking
   prefill join on commit, and exactly one committed answer. Then wire the path
   and make those unchanged cases GREEN.
4. One quiet native before/after pair and the required eight-flag batch through
   `../heavy.sh`, with exact markers and L1/L2/L3 median/p95/min/max. Report handoff,
   native entry/completion, runtime wait and sampling separately; no model
   promotion or inference from a scripted timing test.

## L4 design only

Listening sounds would request the existing `OutputScheduler` audio-start token
only after a natural quiet pause, at most once for that pause. Resumed user words
invalidate the pending sound before playback. The output kind must exclude it
from answer text/history, reply completion and barge-in interpretation, while
retaining the existing echo reference and single audio channel. Dictation never
requests it. No L4 implementation is justified before (a)–(c) and their evidence.

## External blocker and conflict review

The baseline build was attempted through `../heavy.sh`; the current shared gate
reported `swap 5347M, load 108, free 7G, memory 33%`. Its limits are swap≤8192M,
load≤40, free≥10G and memory≥50%. The owned waiting wrapper was stopped after55s
without starting compilation (`wrapper_exit=124`); [raw evidence](Tests/Reports/pl12-listen2/heavy-baseline.log).
No test/model/app run occurred. The scratch directory did not exist and nothing
was allocated there. Shared scripts, foreign jobs/caches and owner data were
preserved. Baseline, RED, prototype, GREEN and native after are unavailable.

Worktree and read-only canonical `git log --since=2026-10-06 --stat` checks of all
three scoped producers show `1af0ca2` touching `NotesModelRuntime.swift`; neither
other producer appears in that date range. `../MAIN-DIRTY-SOURCES.txt` lists
`NotesModelRuntime.swift` as **will conflict with uncommitted work** if the
prototype later edits it. The coordinator and frontend are absent from that
list, but integrators must recheck ongoing ownership. This report changes none
of those files and currently has no producer merge conflict.
