# Committed-turn acknowledgement: final evidence

The selected Pocket/alba native, file-fed release run meets the brief's committed-endpoint gate: **ACK median 120 ms, p95 129 ms, min 116 ms, max 129 ms, n=5**. Both matched timing arms end `VOICE_LATENCY_OK`, exit 0. The original 39 controls and all 38 cache/input controls pass. All eight requested related roots exit 0. This branch was not installed, pushed or merged. The first native preparation refusal remains unexplained; later successful preparation does not fix or explain it.

## Producer and original/fixed proof

`3d1a5070` captures the missing committed-turn producer: the actual coordinator/scheduler/audio/history seams with held model streams, substituted environment/ready clips and a recording answer backing fail 10 of 39 checks, `VOICE_ACK_FAILED`, exit 1. Suppression cases pass. The unchanged fixture SHA is `127b39cea63b5ba723e39428188082828b47f36c03c9fe47d7cc0a233e4a7fd7`. [Original output](red.txt), [source pins](red-source-pins.json) and [build](red-build.log) retain the failure. Final native scripted replay passes those identical 39 checks. These fixtures establish control contracts, not physical meeting/dictation or microphone acoustics.

`4832a60f` adds the idle-selected Pocket/Kokoro clip producer and existing speech-owner playback. Two finite mono 24 kHz clips, at most two seconds each, live in memory and the existing `Library/Caches/NextNotesTTS` folder. Tests use an admitted, confined temporary root. Selection changes refuse stale clips; Apple selection or unavailable/invalid PCM stays silent. Native prewarm retains and cancels/joins the same Pocket session; capture shutdown joins its task off the conversational path. No clip is rendered at commit.

The same commit fixes an actual output-completion gap. The original optimized producer passes 39 controls but fails exactly one of the 34 cache checks: natural answer completion releases output without rearming idle clips. Audio/Synth are not Observable in this base. The same `didFinishAudio` completion hop now notifies optional prewarm after queue/lifecycle release. [RED](output-idle-red.log) -> [GREEN](green-policy.log), with retained original/fixed pins, changes only that producer hook. No await, timer, graph, store or speech gate was added.

`e36ac834` fixes the actual cleaned-input producer. An eligible held-model coordinator turn owns courtesy, then the actual capture level hop receives cleaned level 0.07 with `nearCandidate=false`. Original cache/input 38 fails one assertion: courtesy does not stop. Removing only its near-candidate condition cancels courtesy synchronously while preserving capture and the ordinary answer's 120 ms/near-candidate rules. [Original replay](cleaned-resume-red.log) -> [same-fixture debug replay](cleaned-resume-green-trace.log) -> [optimized final replay](green-policy-final.log). All 39+38 checks pass. This does not establish acoustic classification or physical microphone behavior.

`b782ad3b` retains native preparation tracing and final playback measurement. The coordinator's committed-turn seam creates an independent 40 ms grace task. OutputScheduler admits a current committed turn and mints the existing output capability; Synth plays already prepared PCM through its existing player/engine/echo-reference transport. The first played 10 ms buffer supplies the conservative ACK receipt. It does not close the answer turn or replace L3. Courtesy adds no reply/history/delivery, semantic speaking floor or user-word echo entry. Answer stream admission preempts synchronously, before PCM preparation, with no wait or courtesy queue. This conservative admission boundary is earlier than first answer PCM; it is not universal first-PCM arbitration proof.

The native harness forces Pocket with the shared Mini `VoiceDiagnosticSpeech` helper and silent failure backing. The exact actual Apple text-synthesis entry counter remains zero. Merely playing Pocket PCM through the old backing's transport is not Apple synthesis. Ordinary global fallbacks outside this task remain a no-Apple integration dependency. Prompts, budgets, defaults, samplers and Formatting/LLM are unchanged.

## Matched optimized timing

Same unbundled release SHA `561e23082548c165c2f6be0e692e7c8ae514d0450bd34754fbd419b190d5067a`, same authored listen2 WAV SHA `ec9f48e5b38281e2ef3022904db9eb2e3eb5b69bdcbaab94faf000a9c91fbeab`, one excluded warm-up and five counted turns per arm. Times are seconds. p95 is nearest rank, therefore the maximum at n=5; output precision is 1 ms.

| Arm / column | Median | p95 | Min | Max | n |
|---|---:|---:|---:|---:|---:|
| No ACK / ACK | absent | absent | absent | absent | 0 |
| No ACK / L1 | .680 | .683 | .677 | .683 | 5 |
| No ACK / L2 | 2.635 | 3.041 | 2.454 | 3.041 | 5 |
| No ACK / L3 | 2.792 | 3.191 | 2.634 | 3.191 | 5 |
| No ACK / speech-end to commit | 1.005 | 1.007 | 1.004 | 1.007 | 5 |
| ACK / ACK | **.120** | **.129** | **.116** | **.129** | **5** |
| ACK / L1 | .675 | .677 | .673 | .677 | 5 |
| ACK / L2 | 2.941 | 3.008 | 2.669 | 3.008 | 5 |
| ACK / L3 | 3.065 | 3.159 | 2.815 | 3.159 | 5 |
| ACK / speech-end to commit | 1.008 | 1.016 | 1.006 | 1.016 | 5 |

`VOICE_ACK_GATE=PASS target_median_s=0.200 n=5`; actual Apple synthesis calls 0. All counted endpoints are localEOU. No-ACK warm-up uses VAD with EOU preparation 4.326 s; ACK warm-up uses localEOU with preparation 3.075 s and ACK .120 s. These cold observations are excluded, not repaired or promoted. L1/L2 remain above the old 200 ms bars. About one second of endpointing occurs before commit and is outside the owner's ACK definition. The answer remains seconds away. The measured L2/L3 medians are higher in the ACK arm; this small, single ordered pair with varying generated answers establishes neither causal speed improvement nor statistical equivalence. Synchronous preemption/no-queue controls, not those medians, establish the bounded no-added-wait contract.

[Raw no-ACK](before-no-ack-final.log), [raw ACK](after-ack-final.log), [analysis](native-analysis.json), [binary/model/source pins](native-artifact-pins.json), and [eleven-run invariance](final-invariance.json) retain actual values. All twelve changed source hashes match the tested artifact; the same binary hash is verified before/after every final flag. Apple FM is system managed and independently unhashable here; ASR/EOU artifacts are not independently pinned. Pocket cached artifact hashes and int8 configuration are retained.

The machine is Apple M3, 16 GiB, macOS 27.2 build26B5091g, AC power; thermal queries report no recorded warnings, not temperature measurements. Start swap is 6528.44 / 6496.44 MiB for the two arms; load5.17 /2.85. Normal owner app PID52144 and hosted model/audio services remain present. One-second samples of our own process only: before118 samples, peak footprint606,128,024 B / RSS1,004,568,576 B; after121 samples, footprint618,219,656 B / RSS1,077,542,912 B. Hosted services/children and continuous peaks are excluded. No quiet-machine, memory-ceiling or live soak claim is made.

## Every final root

| Flag / mode | Exact final marker | Exit |
|---|---|---:|
| voice-latency policy | VOICE_ACK_OK (39+38, zero failures) | 0 |
| voice-latency no-ACK | VOICE_LATENCY_OK | 0 |
| voice-latency ACK | VOICE_LATENCY_OK; VOICE_ACK_GATE=PASS | 0 |
| voice-pipeline | VOICE_PIPELINE_OK | 0 |
| voice-turn-routing | VOICE_TURN_ROUTING_OK | 0 |
| concurrent-voice | CONCURRENT_VOICE_OK | 0 |
| voice-conversation | VOICE_CONVERSATION_OK | 0 |
| duplex | DUPLEX_OK | 0 |
| voice-scheduling | VOICE_SCHEDULING_OK | 0 |
| tts | TTS_OK | 0 |
| store-isolation | STORE_ISOLATION_OK: 21 files and 0 defaults unchanged | 0 |

Duplex/TTS markers are in stdout, which the collector preserves. Duplex retains two `VOICE_SESSION_DIVERGENCE` turnPending diagnostics. Store isolation retains nested `TOOLLOOP_PRODUCTION_FAILED` and 18 A02 fixture-admission assertions, the inherited requested-flag wiring defect named in the brief. Its outer privacy pass is limited to those 21 files and zero watched defaults. These nested failures are not passes or repaired bugs.

## Preparation investigation and failed attempts retained

The first optimized batch's no-ACK arm passes; its ACK arm stops before turns with `VOICE_LATENCY_ABSENT: selected Pocket acknowledgement clips did not become ready`, exit1. [First pins](first-native-artifact-pins.json) and [first output](after-ack.log) stay retained. Its generic optional-cache refusal supplies no exact original PCM/error. Its cause is still unattributed.

The four-phrase native diagnostic prints Pocket/alba finite 24 kHz raw/body counts13440/13440,24960/24960,26880/26880,24960/24947. All fit the original two-second bound; it intentionally publishes/plays none and ends ABSENT. The guard rejects the proposed raw-limit/text/schema correction. This probe did not establish a length refusal; stochastic later counts do not disprove that possibility for the unretained first output. [Profile trace](native-clips-red-retry.log) and [pins](native-clips-profiles-artifact-pins.json) retain the evidence.

The faithful original two-clip pipeline then passes with raw/prepared21120/21120 and19200/19194, exact selection/generation, real WAV writing/splitting and ready2. The final release arm passes with raw/prepared46080/46080 and36480/36480. Native lengths vary substantially. Bounds, phrases (`Mm.`, `Okay.`) and schema (`ack-v1`) were never changed. Later success is not a fix for the first refusal, a deterministic readiness guarantee, or audible-quality proof.

The initial release compile fails five explicit-self annotations before tests, then succeeds after correction. A native diagnostic omits the explicit WAV argument and ends missing-fixture ABSENT before rendering. A SHA-bound resume refuses a changed shared debug executable (voice-settings source roots) before native execution. Its retry rebuilds/pins inside one admitted slot. The faithful-cache trace helper's first compile fails a missing MainActor annotation; correction adds no await. Every failed build/refusal, source pin and driver remains in this directory. The completed final driver is `cache-path-slot.sh`; it does not weaken any threshold, timeout or model grader. Multiple diagnostic slots were required; they are disclosed rather than claimed as one successful first attempt. All builds/runs used `RELAY_ID=claude2-voice-ack ../heavy.sh`, shared assigned scratch.

## Integration and remaining acceptance

No-Apple deletes the original backing; map our raw hooks to its existing `PreparedPCMSpeechBacking` (`6336fb7...`) and generic receipt types, preserving the same graph/echo/timeline and `stop(advanceGeneration:)` refusal fencing. Require its actual `availability == .ready` and exact cached engine/voice identity. Retain round2 capability publication/request epoch/unknown-pressure fixes and round4 token/text-owned failed-reply settlement (`f6265ca2` / `8097108a`). Do not restore the deleted Apple sink or add another player. Consume its automatic optional-preparation admission, rather than bypassing pressure/ASR/recording through explicit preparation. Combined branches have not been built or measured here.

Deduplicate Mini's exact shared `VoiceDiagnosticSpeech` helper/counter/harness hunks. No-Apple's neutral `shared.speechSynthesisCallsForTesting` counts allowed Pocket/Kokoro request entries, excludes prepared playback/warm predictions and is not a forbidden-Apple counter. Replace obsolete zero-Apple getter assertions with combined sink census plus retained silent-failure/spy proofs. Our direct session.enqueue bypasses its facade: use the existing `PocketAgentVoice.noteSynthesisRequestForTesting()` at that actual enqueue if counting two idle native renders. Disk restoration/raw playback add zero requests.

Catch-up must synchronously pause its file player at admitted courtesy PCM entry; courtesy bypasses text-enqueue hooks. Its latest saved-file design still fails the one-channel acceptance contract. A pause alone does not supply echo-reference or barge receipts. [Transport diff](prepared-transport.patch) records our exact seam. Ordinary Pocket/Kokoro qualified resume, Settings crash, subjective clip quality, physical microphone/echo/cancellation, native Kokoro timing, normal startup/resource admission, statistical latency repeatability and first-refusal attribution remain open. No task/model/default/phase readiness or aggregate9/10 promotion is claimed.

[Read-only conflict check](integration-conflicts.json) finds no declared/current dirty canonical overlap for our source/performance scope at canonical55d402ee. Peer branch overlaps above still require manual merging. No canonical edit/build or owner-store migration occurred.

All own final children joined. Positioning relay1156, settings1166 and prior Mini1055 explicitly release shared scratch; [cleanup](cleanup.json) records removal of assigned `wt-scratch/voice`,3,464,863,744 allocated bytes before removal. Earlier cleanup removed only SHA/UUID-matched obsolete own release executable/symbols. Models, owner data, foreign scratch/processes remain. Harness roots clean up on their normal exits. No global reclaimed-space attribution is made.
