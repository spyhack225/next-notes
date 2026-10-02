# Next existing-owner producer contract (Apple first)

## First broken contracts in current source

1. VoiceContracts inputDiscarded changes paused to playing solely from historical output.heard, before capture invokes the physical resume. RealtimeAudioSession.voiceShadowOutputSnapshot independently returns playing from voiceShadowHeard or currentClauseRendered once paused is false. Neither value establishes a new current playback observation.
2. AVSpeechBacking.bufferPlayed guards only token/pending count. Its native .dataPlayedBack callback crosses MainActor with only token. didBegin emits onset once; subsequent completed positive buffers carry no semantic playback receipt. AgentSpeechSynthesizer.didBeginAudio then emits startAcknowledged(String), discarding origin identity beyond the token check. RealtimeAudioSession converts that event to unqualified firstAudio. A pause/resume retains token and outputGeneration, so those checks cannot distinguish a pre-pause event delivered after resume.
3. Pocket has the same token-only callback hop and firstFramePlayed one-time gate. Kokoro reports only first 20ms buffer completion as onset, then the entire remaining buffer as finish. PocketSource/AgentPCMRenderer has real copied-sample timestamps/counts, but delivers firstDelivered once and uses a different selected backing. Switching to it would not repair Apple or preserve the existing owner/default.

These are source findings. The actual original94 regression is pending, so this report does not label the product failure reproduced or repaired.

## Smallest actionable implementation boundary

Keep physical playback fully duplex and unchanged. Existing pause/resume remains synchronous; no extra buffering, fixed delay, model, store, queue or new audio owner. Root needs leases on AgentSpeechSynthesizer.swift (including AVSpeechBacking), RealtimeAudioSession.swift and VoiceContracts.swift; root also owns common regression/related expectation amendments. Capture requires no producer change for this frontier. UI/Island ownership and other speech backing implementations are not included in the first lease.

Implement current receipt identity **at the real AVSpeechBacking native callback before its MainActor Task**, not when scheduled and not when received by the consumer. Proposed immutable packet fields:

- existing clause token;
- active pause/resume phase stamp captured at callback entry;
- actual positive frame count, sample rate and the scheduled buffer's immutable per-token frame interval/ordinal;
- actual callback kind (must dataPlayedBack), plus callback-observation host clock if recorded.

Maintain phase stamp in the existing Apple backing: inactive0; an active even stamp; accepted pause changes to odd; accepted resume to the next even stamp; stop invalidates before player.stop. An atomic integer (Synchronization already used by AgentPCMRenderer) allows a snapshot before the actor hop without reading MainActor-isolated state from a native callback. It is per-current-backing metadata, not a new ledger/cache/channel. Native .dataPlayedBack callbacks can occur because stop unscheduled audio, so positive frame count and callback kind alone are insufficient: stamp/token/current owner must still match at handling. A captured old packet must not be relabelled with the new stamp at delivery. Preserve buffer-drain bookkeeping independently from whether a packet is usable for current semantic playback.

Carry this packet on the existing synthesizer playback event path, including subsequent Apple positive-buffer acknowledgements. Do not create a second playback channel. Initial first-audio and latency/echo historical evidence remain distinct from resumed-speaking authority. Add an explicit awaiting-resume output phase to existing lifecycle/shadow metadata. inputDiscarded frees the floor and requests resume but cannot manufacture playing; actual successful current-owner resume emits pending-resume metadata synchronously. Existing legacy projection must expose that same conservative phase. An old firstAudio packet may preserve historical heard, but cannot clear paused/awaiting-resume. Only a validated positive current resume receipt can clear awaiting state and publish playing, respecting pending proposal priority. Avoid a universal heard+playing restoration helper. Unknown/unsupported backing capability remains unknown, not a forged receipt.

The frozen negative fixture can prove that no receipt is manufactured at resume and that the actual held old onset cannot reactivate speaking. It cannot alone validate a fresh native packet, stop discrimination, callback-thread capture or exact played interval. Those need common actual backing probes before both original/fixed (next paragraph).

## Native epoch/range prerequisites before positive-resume claim

Use a SelfTest-only nil callback interceptor at the existing Apple scheduleBuffer completion, **after capturing immutable packet identity but before MainActor forwarding**. Retain actual original packets, release each once, and preserve housekeeping. Required actual controls:

- hold one real callback before pause; pause and resume same token; release old packet; it preserves historical evidence but grants no fresh speaking;
- allow a later real positive callback; require its exact current token/phase/positive interval plus a verified post-resume frame boundary; it reaches existing synth→RealtimeAudio→shadow consumer once;
- stop while real buffers remain queued; post-stop callback cannot be semantic played evidence; current token invalidation and actual completion/drain behavior retained;
- repeated pause/resume with held packets from both older phases, and new clause token/output-generation replacement, reject each stale packet without cancelling current output.

No task/context cancellation substitute or fake notifyTestingFirstAudio is valid. Do not extend a timeout or suppress later native receipts to make the verdict green. Capture input interval and backend played interval are different coordinate systems; do not compare them numerically without a real format/timeline contract.

## Exact unresolved boundary; no naive range-cut claim

The local Apple SDK AVAudioPlayerNode header documents .dataPlayedBack as buffer/file finished playback, including output device latency. It also documents completion on stop and non-main callback threads. These are buffer-completion observations, not an exact native timestamp for the boundary where a pause took effect. A callback first invoked after resume may refer to a buffer that finished before pause. Callback epoch alone fences already-observed/queued packets, not every delayed native notification.

The SDK says playerTime(forNodeTime:) returns nil while not playing, and player sample time does not advance while paused. A lastRenderTime/playerTime read before pause is not a proven upper bound on the final paused player sample. Reading after pause is not a documented available exact cut. Therefore this report deliberately supplies **no invented paused sample endpoint**, and does not accept buffer.end > pre-pause lastRenderTime as proof that new frames played after resume. Buffer scheduling epoch is also wrong: old scheduled backlog legitimately resumes.

The smallest next capability experiment must use the SAME owned Apple player and its actual SDK timeline to establish an immutable pause/resume consumed-frame upper bound with raw traces, including callback-origin host time, buffer ranges, node/player time availability and native render progression. If that bound cannot be established, use the existing output-mixer tap's real render timestamps only after proving exact active Apple token/phase attribution and non-silence belonging to that player; it currently observes silence and has only global stop epoch, so it is not already a resumed-voice receipt. No new tap/channel or selected-backend switch is justified by this audit. This additional endpoint proof is required before claiming freshly resumed physical samples or granting live UI authority; the four initial target failures can still be reproduced now.
