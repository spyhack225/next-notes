# Qualified current resume receipt on the existing playback path

## Existing call chain and minimal API

The physical owners remain AgentSpeechSynthesizer -> selected backing -> existing player/source renderer. RealtimeAudioSession owns current output ID/kind/outputGeneration; VoiceSession remains a shadow reducer. There is no new store, channel, queue, task timer, foreground await, model pass or speaker owner.

Extend the existing backend acknowledgement bridge with an immutable qualified receipt, then carry that value on the existing synthesizer onPlaybackEvent path. Do not make a second consumer stream or read a LAST cache as receipt authority. An Apple-first implementation can add its structured callback alongside the existing onset/finish bridge and wire only systemBacking in the existing synth initializer; it does not require a broad optional protocol getter or affect other defaults. If a later common getter is actually consumed through `any AgentSpeechBacking`, declare it in the protocol itself; an extension-only default getter is not dynamic concrete dispatch.

Receipt API sketch (not applied):

```
CurrentResumeReceipt {
    callerToken: UInt64
    backendEpoch: UInt64
    backendGeneration: UInt64? // renderer only; never confuse with callerToken
    positiveFrameRange: Range<Int64>
    sampleRate: Double
    origin: nativePlayerCompletion | actualSourceRender
    originHostTime: UInt64
    checkpoint: Int64
}
PlaybackEvent.resumeAcknowledged(CurrentResumeReceipt)
```

Backend must capture origin token/epoch/positive interval before an actor/utility-lane hop. Synth verifies current actual backing identity, current clause token, pending resume binding, backend's still-current epoch/generation and no stop/pause. Then it clears resumePending and emits the immutable receipt, without modifying physical playback. RealtimeAudioSession rechecks output ID/generation and the current receipt binding before emitting the matching shadow playback fact. It cannot label a packet with current identity at delivery.

Reducer stores the current requested resume identity with the output. Exact event additions can be `resumeRequested(token: UInt64, epoch: UInt64)` and `resumed(token: UInt64, epoch: UInt64)`, with optional output resumeToken/resumeEpoch fields. A newly requested resume is awaiting; resumed requires exact current output ID/token/epoch and awaiting state. A repeated pause/request supersedes prior identity. FirstAudio only preserves past heard while paused/awaiting. Resumed positive sets heard/playing and publishes speaking only with free floor and no pending approval; the existing proposal priority remains. End/stop/new output clears resume binding. No generic approvalResolved or historical-heard helper restores speaking.

All those checks occur at existing synchronous callback/owner hops. A rejected stale packet still performs its existing independent drain accounting; it must not leak pending buffers or deadlock playback. A stop invalidates before calling the native player/renderer stop, because native stop can itself invoke completion. Enqueue or a successful `play()` is not the receipt.

## Backend-specific real producers

| Backing | Actual current positive producer | Necessary minimal next change/proof | Scope and limit |
|---|---|---|---|
| Apple AVSpeechBacking | Positive copied PCM scheduled into same player; dataPlayedBack callback; onset only once | Promote only a reviewed actual current token/phase packet that exceeds a verified post-resume checkpoint. Preserve native atomic capture/stop invalidation. Require coordinate/clock controls and repeated-phase/late-native regressions before semantic use | Existing AgentSpeechSynthesizer file; first independent positive implementation. Native diagnostic candidate alone is not authority |
| PocketSpeechBacking | Generated 24k frames -> player dataPlayedBack; firstFramePlayed once | Same native origin/epoch/stop protections, but establish the actual player-relative scheduled origin first. It calls player.play before awaiting model frames, so first nil-scheduled buffer begins in an already-advancing timeline, not frame0 | PocketAgentVoice.swift after actual owner handoff. Reusing Apple's per-token zero origin is invalid. A smallest possible producer change moves initial play after the first actual schedule (no extra await), but must prove unchanged first-audio/full-duplex behavior and fresh-clause origin; do not assume it safe |
| KokoroSpeechBacking | First20ms buffer -> onset; all remaining PCM -> one completion/finish | Must obtain positive resumed progress before whole remainder ends. Two-buffer completion-only design cannot do that promptly. Native epoch/stop guard still required | KokoroAgentVoice.swift lease. Do not add a polling timer, delay or pretend the rest-buffer completion is early resume. Consider bounded segmentation of the already-generated rest through existing player only if actual CPU/latency/full-duplex proof supports it; existing output mixer tap is another unproven seam, not a ready receipt |
| PocketSourceSpeechBacking / AgentPCMRenderer | Source render reads copied>0 actual samples; exact renderedSamples and timestamps; firstDelivered once | Capture renderer phase at the render callback, bind renderer generation plus caller token, and record the first positive suffix after resume within existing Core. Existing receipt poll can deliver it once after presentation latency; no new timer. Preserve old render facts and queued sample ownership | PocketSourceSpeechBacking.swift and AgentPCMRenderer.swift leases; no model/backend switch. Atomic paused/count alone needs simultaneous generation/phase proof because a render can read paused=false just before MainActor pause and finish afterward |

Source-node coordinates are renderer 16k after conversion; Pocket input frames are24k. Do not compare either with capture audio or Apple/Pocket player units without the actual conversion/timeline contract. PocketSource uses a separate monotonically minted renderer generation specifically because callers can reuse tokens in selftests; preserve that mapping and its existing stop checks.

## Required controlled real cases

Keep original94 common28 for the negative producer correction. Each positive backend has a separately frozen actual producer fixture:

1. Initial actual positive onset, confirmed pause, actual same-token resume, then a strictly qualified new receipt reaches synth -> RealtimeAudioSession -> shadow once. Historical heard stays intact.
2. A native/render packet captured before pause is held before its actor hop; release after resume. It cannot clear awaiting or publish speaking. Also retain firstAudio at the existing listener as original94 does.
3. Two pause/resume cycles retain packets from each older epoch. Current receipt survives, both old packets refuse; no current queue/buffer cancellation or mic/model serialization.
4. Stop with queued real audio releases actual completion callbacks; none qualify. Every buffer drain/renderer notification joins without invented timeout extensions.
5. Actual next-clause token, replacement output generation, fallback backend and session close refuse mismatched packets; saved backend/voice choice remains unchanged. A first callback from a NEW clause is not automatically an old clause's resume receipt; preserve identity through the event.
6. A late native callback first invoked after resume for data completed earlier must not qualify by phase alone. Use actual owned-player timing/frame controls; a scripted fake packet cannot prove that hardware ordering.

Harmless native fixtures can bypass model synthesis only via explicit existing backing preparation seams and real PCM playback; such a test proves playback producer/consumer, not model quality. Actual original user flow and selected-model speech tests remain necessary before backend completion. No owner conversation/history/model payload may be seeded or decoded.

## Current timeline diagnostic limits to preserve

Initial native96 recorder overflow was invalid evidence, not a valid three-failure feature red. Root owns the bounded recorder-capacity correction and same-source reruns. This plan assumes no PASS result.

Actual logs can have nodeHostTime greater than observedHostTime: audio timestamps may describe a render position in the presentation pipeline. Therefore nodeHost>=resume-request alone is not a proven wall-clock render-after-resume statement. The diagnostic's max(cursor, first completed end) is deliberately a conservative candidate checkpoint, not an exact pause cut. Raw cursor0...scheduledEnd/rate/origin/monotonic progression and actual late-origin cases must hold before promoting it.

A useful smallest additional proof is two SAME-player post-resume cursor observations with strictly advancing player frame and node-host coordinates, followed by a real completed interval strictly beyond the later checkpoint. It uses existing callback opportunities, not a timer or foreground wait. SDK says the player timeline accounts for pause and does not advance while paused, so such progression is stronger than relabelling one future-dated timestamp; it still requires actual native verification and must not be declared proven from this proposal. If that bound is unavailable, keep awaiting/unknown and leave positive receipt open rather than borrowing historical heard, enqueue or player.isPlaying.
