# TTS follow-up: generated, rendered, estimated and acoustically observed start

22 October 2026, follow-up to the TTS agent's explicit coordination request. This is a
read-only review of its newer evidence plus a collector contract. No product edits,
speaker/microphone run, installation, default change or heavy benchmark was performed here.

## New evidence since the original alignment reply

The TTS [report](../../../Tests/Reports/tts-2026-10-22/README.md) and
[accepted component results](../../../Tests/Reports/tts-2026-10-22/accepted-results.json)
now record native generation and muted source/renderer checks. The agent identifies
commits `16020462` / `3e86baf9`. This supersedes the original reply's **uncompiled**
TTS snapshot for those bounded checks; it does not complete voice-turn integration.

| Engine | Reported warm median, five same-text trials |
|---|---:|
| Phonon | 7.80 ms |
| Apple | 8.98 ms |
| Pocket | 59.00 ms |
| Kokoro | 224.11 ms |
| Qwen | 2709.30 ms |

These measure known-text request to first **non-empty generated PCM**. Whole-clause
Qwen/Kokoro generation, warm repeated text, first-after-preparation, download/load and
inherited swap conditions are disclosed in the report. Five repeats support a small
exploratory median, not a promoted p95, speech-end latency or physical audible result.
The review did not rerun them. The component winner cannot yet establish the fastest
normal conversational voice on the reference workload.

## Existing collectors: what can be reused

| Producer | Existing evidence | Missing for physical onset |
|---|---|---|
| `AgentPCMRenderer.Core.render` | Post-source-gain samples and AudioTimeStamp host clock; bounded reverse reference | First **non-silent** sample receipt bound to output/graph generation |
| `AgentPCMRenderer.pollReceipts` | First copied-sample timestamp + output-latency wait, delivered by a ~10 ms polling task | Native sample timestamp is not exported by its token-only callback; callback arrival adds scheduling delay |
| `AgentSpeechSynthesizer.didBeginAudio` | Backend start acknowledgement; stamps `VoiceMark.firstAudible` | Code explicitly says it is not proof anybody heard sound; do not treat this mark as acoustic observation |
| `VoiceEchoLiveProbe.Meter` | Shared raw `AudioCaptureHub` observer, room baseline/playback RMS and frame counts | Drops capture host time/sample index; cannot establish first acoustic arrival |
| `AcousticEchoProbe` | Aggregate RMS/attenuation; separate diagnostic audio engines | Its tap discards AVAudioTime; it is not the production onset collector |

The live echo probe's `playbackOnly` meter is enabled by `.startAcknowledged`; using this
gate for onset would exclude sound arriving before that delayed acknowledgement. Arm
an onset observer **before** requesting synthesis. Reuse the existing hub subscription
pattern; do not open a second microphone path or run AEC on the raw observer again.

## Required timestamp contract

Keep these separate, with common monotonic origin, run/trial, provider/model, output token,
output generation, graph generation and input/output route identifiers:

1. `synthesisRequested`: ordinary selected-provider path accepted the text.
2. `firstGeneratedPCM`: first non-empty synthesis frame, including sample rate and leading silence.
3. `firstNonSilentRenderedSample`: sample index and host timestamp from the actual current
   renderer output after source gain; preserve downstream mixer/device gain/mute metadata.
4. `estimatedOutputPresentation`: a qualified render-host timestamp plus the appropriate
   downstream presentation-latency estimate for that exact graph/route.
5. `firstAcousticArrivalObserved`: timestamp of matching sound in the raw microphone
   observer, with detector threshold/window/confidence and input-route latency metadata.
6. `receiptDelivered`: when MainActor consumes the receipt, so polling/actor delay is measurable.

Detect non-silence inside the existing render callback using bounded arithmetic and
atomic receipt publication. Do not allocate, lock, log or run correlation/DSP there.
Include the offset of the qualifying sample in the render block; block start alone
misstates onset when generated PCM contains leading zeros. Zero gain/paused/underflow/
all-zero PCM has no audible-start receipt. Later consumer work exports the receipt.

Current first-sample behavior is intentionally compatible with zero PCM in renderer
self-tests; add a distinct measurement rather than silently breaking lifecycle receipts.
The native timestamp is authoritative for render timing, not the later poll/task clock.

Apple describes [`outputPresentationLatency`](https://developer.apple.com/documentation/avfaudio/avaudionode/outputpresentationlatency)
as maximum downstream render-pipeline latency. It is an **estimate**, not an external
microphone measurement. Validate the source-node versus output-node timestamp/latency
mapping on the actual graph before adding values; do not sum overlapping node/device
latencies. Existing `pollReceipts` already waits until `first + latency`: adding latency
again to its callback timestamp double-counts it. Publish raw render time, queried node,
latency, route and the resulting estimate so that arithmetic is reviewable.

Do not write `estimatedOutputPresentation` into the offline scorer's `first_audible` field
or claim G4 physical acceptance from it. Add explicitly named estimate/render columns
to the native report. Only the appropriately qualified observed boundary can populate
an acoustic-result column; missing observation is null/unsupported, never zero.

## Physical microphone observation

- Subscribe once to the existing raw hub feed with host-time-bearing owned chunks. Arm
  before the request; retain bounded observation state, not a recording or extra queue.
- Derive onset from the matching sample's `captureHostTime + offset/sampleRate`, not
  observer callback arrival. Invalidate on missing timestamps, route/format/generation
  changes or lost samples; do not reconstruct false precision.
- Measure a quiet-room baseline first. Freeze amplitude/SNR and minimum-duration criteria
  before comparing engines. Backtrack to the qualifying onset sample when a persistence
  window confirms it; expose temporal resolution and uncertainty.
- Require evidence the sound belongs to the requested rendered utterance, such as bounded
  correlation with its actual output reference. A door click, cough or unrelated app must
  not win the benchmark. Compare echo-only room audio, no-output/muted controls and known
  leading-silence fixtures. Do heavier matching off realtime callbacks.
- Label the result **speaker-to-microphone observed arrival**, including acoustic path
  and input hardware timing. It is not direct proof of a human's perceptual threshold.
  Do not subtract guessed microphone latency or acoustic travel time.
- Hold route, volume and observer thresholds fixed. Headphones without a valid external
  pickup or loopback yield missing physical-speaker evidence, not immediate arrival.
- Keep output-token freshness, native generation join, no stale PCM, AEC reference,
  pause/resume/duck and absence of real tool effects covered throughout the probe.

## Fair comparison, Settings percentages and a public page

Actual-output timing must traverse each engine's ordinary synthesis/backing/renderer path.
Apple's write-to-PCM component API cannot substitute for an unrelated system-speaking
path. Where paths differ, report them rather than presenting incomparable timestamps.

Use varied short/long texts and natural inter-request spacing; include at least 30 warm
trials per qualified cell and separate first-after-preparation/fresh-capture/reopen results.
One engine/model process at a time still applies to the component comparison. Separately
test the selected ASR + selected TTS + endpoint pipeline together before default promotion.
Report uncertainty, failures, sample counts, phrase/route and wall/presentation/observed
boundaries. Do not manufacture a full-turn number by adding medians from separate runs.

For the owner's requested speed/size percentages, define the denominator visibly in the
benchmark page and supporting data. For example, relative delay is
`100 * (engine latency / reference latency - 1)` for a fixed named boundary and phase;
it is not the same quantity as a higher-is-faster score. Avoid a rounded 100% claim that
hides uncertainty or unsupported physical results. Prefer actual milliseconds beside any
relative value. Benchmark device/route/date labels prevent a local result implying every
user gets that speed.

Report download bytes, installed/compiled bytes and runtime memory separately. Apple's
included OS assets are not a claim of zero storage/memory. Shared assets count once in
the app's storage view; document attribution if using a model-relative percentage. Keep
five plain voice choices, preserve explicit selection and use accurate readiness/download
state. Numeric scores do not replace language/voice quality and interruption qualification.

Public benchmark material should publish only reviewed aggregate results and reproducible
authored-text methodology, with model/build/device/date/sample-count and metric scope.
No owner audio, transcripts, machine-local paths or private roadmap links. Keep generated,
render-estimated and physically observed numbers in separate columns, and retain nulls
for unmeasured fields. New webpage publication and default switching remain owned by the
TTS task under its own direct user request; this roadmap review changes neither.

## Open gates after the component milestone

- Native first-non-silent render/presentation-estimate collector and negative controls.
- Timestamp-preserving acoustic observer and physical result, if a suitable route exists.
- New-engine real-room echo, interruptions, device transitions and reference-load tests.
- Statistical/quality/provider qualification before fastest-default promotion.
- Smart Turn native model/buffer/policy work and its latency/pause corpus remain todo.
