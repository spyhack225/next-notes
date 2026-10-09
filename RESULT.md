# voice-ack result

Implemented instant committed-turn courtesy playback on branch `claude2/voice-ack`, based on listen2 `73f4dde8`. **Native Pocket/alba ACK: median 120 ms, p95 129 ms, min 116 ms, max 129 ms, five counted turns; the strict 200 ms gate passes.** No install, push or merge. Full evidence: [report](Tests/Reports/voice-ack/README.md).

The selected Pocket/Kokoro voice renders two short clips while idle and stores them in memory and the existing speech cache. Commit only plays a ready clip through OutputScheduler and the existing speech transport/echo reference. A separate 40 ms grace leaves the answer free to start; answer admission cancels courtesy synchronously. Clips rotate, occur at most once per turn, cancel on resumed input and stay out of answers/history/delivery/semantic speaking floor. Apple selection/unavailable native PCM stays silent. The normal global fallback removal is still the no-Apple branch's work.

## Commits

- `3d1a5070`: actual original missing-producer reproduction, 39 checks/10 failures.
- `4832a60f`: selected ready clips through existing owner; actual output-completion prewarm gap RED 34/1 -> GREEN 34/0. First native ACK preparation refusal retained, not final acceptance.
- `e36ac834`: actual cleaned-input producer cancels courtesy without optional near-candidate gate; unchanged cache/input 38 RED 1 -> GREEN 0, ordinary answer qualification unchanged.
- `b782ad3b`: native preparation traces and matched playback receipt evidence; unchanged 39+38 pass and ACK gate PASS5.
- Final evidence/documentation commit retains this result, report, performance standard, all attempts/resources and cleanup.

## Exact final checks

All rows exit 0 on the same invariant unbundled release SHA 561e23082548c165c2f6be0e692e7c8ae514d0450bd34754fbd419b190d5067a.

| Check | Final marker |
|---|---|
| voice-latency policy | VOICE_ACK_OK (39+38 zero failures) |
| voice-latency no-ACK | VOICE_LATENCY_OK; ACK column absent |
| voice-latency ACK | VOICE_LATENCY_OK; VOICE_ACK_GATE=PASS n=5 |
| voice-pipeline | VOICE_PIPELINE_OK |
| voice-turn-routing | VOICE_TURN_ROUTING_OK |
| concurrent-voice | CONCURRENT_VOICE_OK |
| voice-conversation | VOICE_CONVERSATION_OK |
| duplex | DUPLEX_OK |
| voice-scheduling | VOICE_SCHEDULING_OK |
| tts | TTS_OK |
| store-isolation | STORE_ISOLATION_OK: 21 files and 0 defaults unchanged |

Duplex/TTS markers are in retained stdout. Duplex still prints two turnPending divergence diagnostics. Store isolation still contains nested TOOLLOOP_PRODUCTION_FAILED with 18 A02 admission failures, the known requested-flag wiring problem. These remain failures, despite the outer root passing. Actual Apple synthesis calls are zero in both timing arms and silent-failure boundary checks.

Matched same authored WAV, one excluded warm-up then five counted turns each. Seconds, median/p95/min/max:

| Arm | L1 | L2 | L3 | Speech-end to commit |
|---|---|---|---|---|
| No ACK | .680/.683/.677/.683 |2.635/3.041/2.454/3.041 |2.792/3.191/2.634/3.191 |1.005/1.007/1.004/1.007 |
| ACK | .675/.677/.673/.677 |2.941/3.008/2.669/3.008 |3.065/3.159/2.815/3.159 |1.008/1.016/1.006/1.016 |

ACK itself .120/.129/.116/.129. All counted endpoints are localEOU. About 1 s of endpointing precedes commit and is excluded by the owner's definition. L1/L2 retain old 200 ms failures; answers still take seconds. The higher ACK-arm L2/L3 medians do not establish a causal regression or equivalence in one small ordered pair with varying generated replies. Scripted synchronous preemption proves no courtesy queue/wait was added. Apple M3/16 GiB/macOS 27.2, AC; owner app and hosted services present. Own one-second sampled peak footprint606,128,024 /618,219,656 B, excluding services/children/continuous peaks. Twelve source hashes and all eleven final executable hashes match the pinned artifact.

## Remaining limits and integration

The first native ACK arm stopped before turns with preparation ABSENT/exit 1; it remains unexplained. A four-phrase trace found valid finite 24 kHz PCM, so the guarded raw-limit/text/schema correction was rejected. Later faithful/final two-clip preparation passes under unchanged limits/phrases/schema, with varying lengths. Later success does not fix or explain the first refusal. Missing-fixture, changed shared executable, initial compile capture errors and trace-helper annotation failure are retained as actual failed attempts, not native passes. All heavy work used the required relay wrapper; no gate/threshold/deadline/grader was relaxed.

Physical microphone/echo/cancellation, subjective voice quality, native Kokoro timing, normal startup/resource admission and combined-branch playback are unverified. ASR/EOU artifacts and the system-managed Apple language model are not independently hashed; cached Pocket artifacts are pinned. No aggregate 9/10, model/default or phase readiness promotion.

Merge Mini's common speech helper/counter/harness once. With latest no-Apple `8097108a`, map raw playback to its existing neutral PreparedPCMSpeechBacking, preserve refusal/request-epoch/token-text settlement/capability/pressure fixes, gate availability.ready plus selected identity and use automatic preparation admission. Its allowed synthesis-request counter is not our zero-Apple counter; preserve census/silent-spy checks and count our two direct session enqueues through its existing counter when testing. Never restore the deleted Apple text sink or add another graph.

Pause Catch-up's file player at admitted courtesy PCM entry; the text-enqueue hook does not cover courtesy. Its saved-file path still lacks one-channel/echo/barge acceptance. No combined branch was built here. The owner/integrator must merge these contracts and assess real clip sound and live acoustics; those are not proven by callbacks.

## Files and cleanup

Changed source files (relative to this branch's listen2 base):

- Activation/AgentCaptureController.swift
- Agent/Duplex/OutputScheduler.swift
- Agent/RealtimeAudioSession.swift
- Agent/Speech/AgentSpeechSynthesizer.swift
- Agent/VoiceConversationCoordinator.swift
- Agent/Voice/VoiceAcknowledgement.swift
- Agent/Voice/VoiceAcknowledgementClips.swift
- Agent/Voice/VoiceAcknowledgementSelfTest.swift
- Agent/Voice/VoiceAcknowledgementClipSelfTest.swift
- Agent/Voice/VoiceDiagnosticSpeech.swift
- Agent/Voice/VoiceLatencySelfTest.swift
- Agent/Voice/VoiceLatencyTimeline.swift

Paths above are under Sources/NextNotes. Also PERFORMANCE-STANDARDS.md, this RESULT.md and Tests/Reports/voice-ack. Formatting/LLM is unchanged. Read-only declared/current canonical dirty checks find no overlap for this scope at 55d402ee; peer branch overlaps above require manual merging. No canonical edit/build or owner migration.

All own child processes joined. Mini, settings and positioning explicitly released shared scratch; assigned wt-scratch/voice removed after pins, 3,464,863,744 allocated bytes before removal. Own obsolete release executable/symbols were earlier SHA/UUID-verified before removal. Temporary harness roots clean up on normal exit. Foreign scratch/processes, models and owner data preserved; no global space-reclamation claim. Findings and remaining contracts shared through agent-relay; sending is not proof of reading.
