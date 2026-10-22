# Alignment with concurrent ASR and TTS work

22 October 2026. The owner explicitly authorized checking with the two existing Codex
agents. Both replied. This records agreed boundaries and current limitations, not approval
of unbuilt native integrations. Reconfirm live source and ownership before implementation.

## Coordination record

| Stream | Existing Codex chat | Relay identity | Response |
|---|---|---|---|
| ASR | Find current ASR implementation — `01a163d2-765b-78c2-a5ff-3b2b82208c33` | `asr-candidates-20261022` | Direct chat response received 22 October; source scope and audio/progress contract confirmed |
| TTS | Find current TTS options — `01a163cb-e239-7b60-8bf7-1826658e2e5c` | `codex-tts-20261022` | Relay reply `b4144ceb-dbc0-4f47-98f5-63163349e7b9` received/acknowledged; matrix and limitations confirmed |
| Turn detection | Review JOSIE’s VAD proposal — `01a163ca-3f9b-7e12-9a96-70b76721c9ed` | `codex-turn-roadmap-20261022` | Owns this documentation/benchmark-tool directory; no product edits/native runs |

Requests were also sent directly through agent-relay as `15344878-e24c-46dd-bd3e-97e295d6b4e9`
(TTS) and `d7228731-78a6-488e-bf64-f794fca89e7b` (ASR). Actual replies, rather than delivery
alone, establish the alignment recorded here. Later file/report changes require recheck.

## ASR agent's confirmed scope

- Current edits: Settings.swift and DictationSettingsTab label repair (reported five changed
  lines), plus candidate compatibility/artifact metadata under
  `Tests/Reports/asr-candidates-2026-10-22`. No Capture/EOU/playback edits.
- Existing Parakeet v3 through FluidAudio/CoreML remains the reference candidate path.
- Candidate expansion: Qwen3-ASR 0.6B/1.7B via MLX/native Swift; Whistle through newer
  Needle C API; Phonon-2 through phonon-coreml; Redux/Ultra through newer FluidAudio
  `.redux`/`.ultra`; Voz through a separate Swift SDK.
- Cached FluidAudio 0.15.6 lacks Redux/Ultra. An SDK upgrade is shared dependency work,
  not a reason to assume that enum cases compile or expose streaming progress now.
- Candidate native adapters are not implemented/benchmarked at the response boundary.
- Explicit agreement: one cleaned 16 kHz mono stream; processed-audio watermark,
  transcript finality and EOU are separate; preserve generations, echo ownership and duplex.
- Agent correction confirmed: Capture can adopt Parakeet EOU decoder text after catch-up;
  describing current Agent transcription as Apple-only would be wrong.
- Requested benchmark coverage: final-word coverage at early endpoints, resumed-speech
  invalidation, first partial and dictation key-up-to-final separate from batch RTFx.

### ASR handoff checklist

For each adapter, supply input format/rate, resampler/time mapping, snapshot revision
semantics, immutable-prefix semantics, supported languages and processed-through evidence.
Document whether processing completion guarantees decoded-tail coverage. Unknown progress
uses conservative fallback and stays unqualified for early partial-based commitment.

Keep dictation provider selection separate from Agent provider routing. Label/UI availability
does not prove use by `AgentCaptureController`, which currently constructs AppleSpeechEngine
and an independent local EOU detector. Route each future Agent provider explicitly through
the existing seam and prove the selected provider actually consumed audio and supplied text.

Preserve any independent meeting/hold transcription and their exact accepted audio. Turn
detection may segment a hands-free Agent request; it must not end a push-to-talk hold or
erase meeting speech during a pause. New ASR options do not silently change stored choices.

## TTS agent's confirmed scope

Matrix supplied by the agent:

| Engine | Native route / status at reply | Required turn-integration checks |
|---|---|---|
| Apple | AVSpeechSynthesizer, existing | Actual render/reference capability; audible timing and false echo |
| Pocket | FluidAudio INT8, existing | PCM stream, gain, pause/resume, cancellation/old-generation samples |
| Kokoro 82M Heart | FluidAudio, existing; disabled on macOS 26.4/26.5 | Preserve OS guard; qualify supported OS path only |
| Phonon 31M | ANE, pinned ptts 0.4.0 native streaming; source candidate | Render/gain/AEC, cold first PCM, interrupt/join |
| Qwen3-TTS 0.6B CustomVoice 4-bit Ryan | MLXAudioTTS 0.1.6; source candidate | Whole-clause latency and actual native drain before owner reuse |

Integration reuses AgentSpeechBacking, PocketSourceSpeechBacking and AgentPCMRenderer.
24 kHz mono synthesized audio converts through the existing 16 kHz rendered-reference
seam; there is no new capture pipeline. At reply, new source was **uncompiled**, disk gate
had refused, and no weights/build/native benchmark had run. These are candidate capabilities,
not verified new-engine acceptance. Consult the peer's eventual
`Tests/Reports/tts-2026-10-22` evidence before updating status.

Qwen's public streaming API does not confirm that its hidden native producer has joined
when the consumer cancels. The adapter therefore uses a joined **whole-clause** generation
call. First PCM includes full clause synthesis; do not advertise token-stream latency or
let a canceled consumer overlap mutable decoder state on the same model.

### TTS handoff checklist

- `firstGeneratedPCM`, `firstRenderedPCM`, `firstAudibleObserved`, and their provenance
  remain separate. A synthesis benchmark has no microphone/speaker endpoint latency.
- Post-gain, actual rendered PCM supplies the echo reference; speculative/unplayed PCM
  cannot be fed into AEC as if a person heard it.
- Pause preserves current output token and queued clauses; resume reuses it; committed
  interruption discards old-generation playback. Gain changes must reach the backing player.
- Device rate/format changes preserve sample/time identity and clear stale reference
  evidence. Missing reference support is explicit and receives a physical-route gate.
- An interruption can stop output immediately while native generation drains elsewhere;
  product capture must not await the join. No second mutable inference begins prematurely.
- First PCM from `--selftest-tts-benchmark` and `Tools/tts_compare.py` remains component
  evidence. Join records using explicit run/provider/model/build identifiers; no timing
  arithmetic splices independently timed component runs into a fabricated full-turn result.
- Respect one temporary candidate model/process at a time for the owner's component
  benchmark; preserve installed/shared models. Combined selected-engine qualification is
  separately required and cannot be replaced by serial component runs.

## File ownership and merge sequence

Claims observed through relay on 22 October; refresh before edits:

| Files | Owner / integration rule |
|---|---|
| `Package.swift`, `Agent/Speech/`, `ModelsSettingsTab.swift`, `Tools/tts_compare.py`, `Tools/tts_benchmark.swift` | TTS owner; do not edit for turn detection while claimed |
| `ModelDownloader.swift`, narrow `NextNotesApp.swift` dispatch | TTS has shared-file claims; serialize later Smart Turn downloader/flag work |
| `Settings.swift`, `DictationSettingsTab.swift`, ASR report directory | ASR owner |
| `roadmap/in-progress/VOICE-TURN-DETECTION/` | This roadmap owner |
| `roadmap/README.md`, P2-04 plan | This task's narrow documentation amendments only |
| Capture, LocalVoiceTurnDetector, TranscriptionEngine, RealtimeAudioSession | Proposed VTD/ASR/TTS shared integration; explicit narrow claims before code |
| `Scripts/acceptance.sh`, metrics/usage schemas | Shared registrations/schema; coordinate after adapter APIs settle |

Sequence: peers finish bounded source work -> reconfirm dependency lock/API -> VTD-00
baseline and shared contract -> VTD-01/02/03 disjoint implementation -> one Capture integrator
for VTD-04/05 -> serialized candidate build -> fixed-pair benchmark -> expanded pair matrix.
No test-result claim follows merely because all agents agree with the architecture.

## Open dependencies

1. Actual ASR candidate adapter APIs, native progress guarantees and Agent routing.
2. Supported shorter-window Silero export/runtime for the cold 200 ms target.
3. Qwen native stream cancellation/drain API; until fixed use its qualified whole-clause path.
4. Actual post-gain render/echo and audible-start evidence for each TTS provider/route.
5. Shared dependency upgrade compatibility across FluidAudio, MLX and TTS packages.
6. Current machine headroom and an agreed native test window. This task writes small
   documents and runs only lightweight offline scorer checks; no contention is introduced.

The roadmap is actionable with the current pair even while candidate adapters remain
unavailable. Keep their cells explicitly pending; do not block independent model/buffer/
policy work on a speculative all-engine rewrite.

## Later TTS evidence, same day

The TTS agent subsequently supplied native component results and muted production
source/renderer checks at commits `16020462` / `3e86baf9`. Its original uncompiled status
above is a dated response snapshot, not the latest TTS acceptance. See the
[audible-start follow-up](04-TTS-AUDIBLE-ALIGNMENT.md) for inspected evidence, the remaining
physical-output gap and actionable measurement requirements sent back to that agent.
No native result was rerun by this roadmap task; Smart Turn integration remains todo.
