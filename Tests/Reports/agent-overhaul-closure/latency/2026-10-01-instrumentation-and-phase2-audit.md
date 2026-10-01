# Agent Phase 2 instrumentation and completion audit — 2026-10-01

This is an implementation/evidence report for P2-01, not a Phase 2 completion claim.
The target stays warm speech-end→first audio ≤0.9 s over five runs, worst main-actor stall
≤100 ms, barge duck ≤200 ms and inter-clause gap ≤50 ms. No threshold, default, model,
voice owner, permissions, real store, microphone or audio-device setting was changed.

## Confirmed producer failures and repairs

1. **Healthy measured zero disappears from the metrics store.** A complete actual
   `VoiceLatencyTimeline` turn, with every ordinary required mark and no late ping, had
   `mainStallSeconds=0` in memory and in its actual usage summary, but zero persisted
   `voice.main_actor_stall` rows. The unchanged production `validateStore` rejected it with
   “voice.main_actor_stall was measured but not stored.” `span(for:)` discarded the zero.
   The producer now writes the real zero through the existing writer.
2. **A mark unlocks twice.** `mark` installed a deferred unlock and also unlocked explicitly
   before emission. A checked-lock diagnostic copy of the same body observed 13 unmatched
   unlocks for 13 marks. The native run did not crash; this report makes no native-crash
   claim. The single explicit unlock remains; file emission stays outside the critical
   section. No lock, gate, wait or queue was added.
3. **Snapshot construction ran on the stamping thread.** An observation inserted at entry
   to the actual `ProcessSnapshot.current()` found 15 calls on the main stamping thread,
   zero on the metrics writer, for one complete turn. The old producer built the span
   before `recordAsync { built }`. Construction now happens inside that existing writer
   closure; the same observation is main=0, writer=15. The closure accepts an optional
   span so a genuinely absent stage remains absent. This establishes thread placement,
   not a measured 0.3–0.6 s user-visible stall fix. Generic `LatencyTrace.record/end`
   construction still runs before `persist`; that broader contract is open.

4. **The latency harness accepted unmeasured/misattributed turns.** Its ordinary validator
   treated split-mode lane/route boundaries as always optional, accepted a zero/multiple
   committed count, and its store validator let an unstored revision borrow the earlier
   turn's rows. At the actual validator boundary, the original source accepted all four
   invalid fixtures. The producer-side harness now receives the real observed commit count
   and command-line deterministic frontend mode from oneRun, enforces conditional stages,
   and matches the exact session+turn revision. The same missing-stage, count and revision
   inputs are rejected. Speculation-hit and single-decision exceptions remain valid. This
   is a repaired measurement/verdict contract; it is not evidence that a real capture
   session ever committed two turns or that a real split route failed to run.

## Isolated evidence

`run-instrumentation-driver.py` copies the actual Timeline, MetricsStore, UsageLog,
UsageRecord schema and LatencyTrace into a temporary compiler directory. The original
production `validateStore` is extracted verbatim. App bootstrap identity is a temp-only
harness stub. The unrelated error-classification method in UsageRecord is replaced with
an unused `.other` shim to avoid loading tool/backend implementations; the producer,
store readers/writers, span construction and validated schema are unchanged. No owner
Application Support directory is referenced. Compiler cache and binary are temporary.
The committed-count negative controls drive the actual validator boundary: the old
signature did not accept count/mode from oneRun, so the driver explicitly calls that old
signature and checks its missing rejection. They do not synthesize capture callbacks or
claim actual production sessions committed zero/two turns. The unstored revision is an
explicit negative-control VoiceClosedTurn carrying no emitted store rows.
The optional checked-lock and snapshot observations are separate diagnostic copies,
not changes to production lock/ProcessSnapshot types.

| Evidence directory | Actual result |
|---|---|
| `red-native` | Compile 0, run 1: required measured zero missing from store; 2 assertions |
| `red-checked` | Compile 0, run 1: same missing row plus 13 unmatched unlocks; 3 assertions |
| `red-snapshot-thread` | Compile 0, run 1: 15 main-thread snapshots, 0 writer snapshots |
| `green-all` | Compile 0, run 0: one zero stall row, 0 unmatched unlocks, 0 main/15 writer snapshots |
| `mutation-zero-stall` | Compile 0, run 1: restoring the original zero omission fails the original consumer and persisted-row assertion |
| `green-pure-suite` | Compile 0, run 0: actual emission/zero/missing PCM/discard/incomplete usage cases and the actual 200 ms labelled stall-probe check |
| `red-consumer-contracts` | Compile 0, run 1: unchanged validators accept missing split stages, counts 0/2 and an unstored next revision; four invalid-fixture assertions |
| `green-consumer-contracts` | Compile 0, run 0: three missing split-stage errors, counts 0/2 rejected, unstored next revision rejected; hit/single-mode exceptions preserved |
| `green-final-pure-suite` | Compile 0, run 0: final actual validators + all current pure fixture methods and actual labelled 200 ms probe |
| `mutation-final-zero-stall` | Compile 0, run 1: actual final pure suite and original consumer reject restored zero omission; four assertions |

Each directory contains raw compile/run output and SHA256 source manifests. The mutation
only changes a temporary copied source. The production `VoiceLatencySelfTest` includes the
zero case and exposes it with the existing flag plus `--voice-latency-instrumentation`.
That modifier prints `VOICE_LATENCY_INSTRUMENTATION_ONLY`; it measures no audio/model
latency, and a green modifier result cannot satisfy the full latency or phase gate.

Installed app/consumer integration and existing `--selftest-metrics`/store-isolation checks
are pending root's serial build/install. The copied-source proof is not an installed-app
or physical audio proof.

## Full P2-01 contract audit

| Task contract | Current source / evidence | Completion verdict |
|---|---|---|
| Six generated Float32 mono/16 kHz fixtures and pause-duration check | Existing executable `Scripts/make-voice-fixtures.sh` creates all six and checks pause-mid duration | Source exists; this worker did not generate them. Default haiku fixture absent on read-only audit |
| One stage vocabulary and no duplicate clock/file | Existing VoiceMark/VoiceStageSpan/LatencySpanID, shared metrics/usage stores | Actual producer/store tested in the isolated driver; installed metrics check pending |
| `source=voice/text/worker` on first-token spans | Tracker carries source; coordinator passes voice; typed tracker chooses text/worker | Source path exists; early typed no-token/cancelled trace endings still omit source |
| Off-main encoding, write and snapshot | Existing serial MetricsStore writer; Timeline lazy span construction repaired | Timeline thread proof green; generic LatencyTrace snapshot placement still open |
| Per-session/turn lifecycle, required stages, nonzero events | Live/file stamps exist in AgentCaptureController, coordinator, frontend, speech buffer, Pocket and synthesizer | Bounded producer/store proof green; production audio baseline pending |
| Conditional lane/route stages | Existing VoiceStageSpan predicate requires lane on a miss and split-route boundaries; hit/single-mode exceptions preserved | Actual old-validator red→final-validator green; installed/full run pending |
| Exact per-turn persisted stage proof | validateStore matches source+session+revision | Actual old-validator red→final-validator green; installed/full run pending |
| Exactly one committed turn per counted run | oneRun passes its actual observed committed count; validator requires exactly one | Old-boundary red→final-validator green; actual file-fed run pending |
| One usage turn row and frontend pass rows joined by turn ID | Existing validateUsageLog and shared correlation; actual turn row emitted | Summary exercised in driver; actual frontend model/pass join pending full run |
| Unavailable sub-reasons | Coordinator emits barrier_timeout/missing_latest_user/apple_unavailable and zero marker | Source wired; no new live unavailable/pipeline execution in this audit |
| Probe accuracy and named site attribution | Actual 200 ms probe case green in copied-source suite; ASR/island/echo/played/session wrappers exist | Probe accuracy green; no current real stall attribution or Instruments evidence |
| Full installed warm-up + five measured turns, tables and medians | Existing app registration and VoiceLatencySelfTest file-fed loop | Not run here; default WAV absent; Pocket/Parakeet EOU directories present, Apple availability unmeasured |
| EXPERIMENTAL catalogue entry, 600 s budget and AGENTS instructions | App flag exists; catalogue currently lacks voice-latency; root owns shared docs/registry | Root pending; no CORE/default promotion |
| Actual attributed >100 ms stall fixed, island-on/off and regression list | No newly measured real user stall in this worker | Open; lazy snapshot thread fix does not substitute for this requirement |

## Phase 2 remaining work

P2-01 remains in progress until the full baseline and every task contract are verified.
Do not start P2-02…P2-08 based solely on instrumentation green. Current-source audit
confirms per-session `LocalVoiceTurnDetector()` construction and close at session end,
so P2-07 residency is still genuine work. The shared capture hub now has consumer-specific
callback bounds (meeting 256, others 8); P2-08 must re-read that producer and coordinate
external dictation/meeting ownership before changing it. Ducking, Smart Turn, speculative
append reuse and TTS pipeline gates require their own actual producer and physical/file-fed
proof; shadow VoiceSession greens are not these gates.
