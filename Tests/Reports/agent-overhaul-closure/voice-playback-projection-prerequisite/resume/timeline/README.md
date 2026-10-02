# Executed owned Apple player diagnostic

Current authoritative result: corrected original97 RED3 → identical fixed98 PASS22, retained in [actual verification](verification.md). First96 audio proof was invalid due bounded recorder overflow, retained explicitly. Common corrected67ff is used before both97/98 and again99. The root99 shutdown repair is independent; resumed-speaking authority still fails4 and is not promoted.

Preparation below describes the source design and its limitations; future-harness/raw-clock caveats in verification override any pending preparation wording.

# Same owned Apple player timeline — concrete off-source diagnostic

Source/native/build/registration ownership remains root. This worker prepared code, inspected actual Source and local SDK, and ran no compiler/model/native audio. Independent [static review](independent-receipt-timeline-review.md) passed for this bounded experiment; compilation and native verdicts remain pending. This is not a fresh-resume producer fix or live Island permission.

## Files root can mount

1. `original-diagnostic-AgentSpeechSynthesizer.swift.txt`: original full Source plus nil/default SelfTest-only diagnostic support; actual post-resume checkpoint getter returns nil. Default production scheduling/callback path is unchanged. Initial original full file is retained separately.
2. `common-ApplePlaybackTimelineSelfTest.swift.txt`: new `Sources/NextNotes/Agent/Duplex/ApplePlaybackTimelineSelfTest.swift`, identical for both runs.
3. `registration-snippet.swift.txt`: additive `--selftest-apple-playback-timeline` branch; root coordinates dispatcher ownership.
4. After the missing-observation original result, mount `proposed-diagnostic-AgentSpeechSynthesizer.swift.txt`: **only diagnosticCheckpoint body differs**. `checkpoint-only-producer.patch.txt` pins that delta. `common-timeline-diagnostic.patch.txt` is the complete current-proposal delta from the retained real baseline; do not apply that fixed patch as the original.

This requires one existing Source lease (Agent/Speech/AgentSpeechSynthesizer.swift, which owns AVSpeechBacking) plus the new test and root registry. No Capture/RealtimeAudio/VoiceContracts/UI, selected backend, preference, mixer tap or saved model change. `appleTimelineObserverForTesting` and `appleNativeCompletionInterceptorForTesting` address the existing `systemBacking`, not a second backing/player. Their default is nil and setup requires SelfTest.

## Actual producer/fixture contract

The actual Apple native callback captures immutable token, buffer ordinal, contiguous scheduled frame interval, sample rate, phase stamp, callback kind, host time and thread observation **before** a native SelfTest interceptor or MainActor Task. The backing's per-current-token atomic phase starts at 2, pauses at 3, resumes at 4; it invalidates to 0 before player.stop. Stop-caused completion and stale token/phase packets remain observable but cannot be current candidates. Existing buffer-drain bookkeeping still executes once per callback; semantically unusable packets are not discarded from that housekeeping.

The diagnostic reads the SAME AVAudioPlayerNode cursor after actual resume/play. It requires player.isPlaying, valid node host and player sample time, exact scheduled-buffer rate, player cursor within 0...scheduledEnd, and nodeHostTime >= resumeRequestedHostTime. It never reads a pre-pause cursor as an exact pause cut. If the immediate post-play cursor is unavailable, the first later current-phase real callback can establish `max(validPlayerCursor, thisCompletedBufferEnd)`. That first completed packet itself cannot qualify. A later real positive current packet must have end > the retained prior checkpoint. Callback-origin host must also be >= the current resume request. Unknown clocks remain nil; no retry, timer or polling is added to the product.

The native fixture:

- starts one silent long clause through real AgentSpeechSynthesizer/System backing and requires actual positive onset;
- holds a subsequent actual completion before its actor hop using a bounded thread-safe **SelfTest-only callback barrier**;
- pauses/resumes the same token/generation, releases the exact old native packet once, and verifies old phase is not relabelled/current/candidate;
- allows real later callbacks, records the post-resume cursor/checkpoint and verifies a positive exact current packet ends strictly beyond a previous checkpoint;
- stops that player, joins every scheduled callback, starts a distinct actual clause, holds a real callback, invalidates/stops, releases it and verifies all post-stop handled packets remain noncurrent/noncandidate;
- checks contiguous positive intervals, unchanged rate/zero player origin, exact scheduled joins, no duplicate callback, bounded storage, closed/released barrier and owner-store/default isolation.

The single native clause is below the actual 280-character policy cap; the first onset verifies no queued follow-up clause. Positive observation waits only for a candidate or actual playback drain, within the existing 10-second harness bound; there is no arbitrary count of callbacks. The initial draft with a three-callback exit is preserved as unexecuted historical preparation.

There are **22 checks** if actual input/cleanup controls are reached. The common nil-getter original predicts **three missing-observation failures** (checkpoint, later-candidate, checkpoint clock), not a confirmed existing product bug. The retained original94 resume regression is separate real product evidence. Missing onset/next buffer, early natural drain, unrelated token/rate, absent current-phase callbacks or failed joins are invalid input/control failures; they are not feature red. Raw cursor unavailability must be examined in logs before calling the diagnostic fixed.

All waiting is bounded harness waiting. The product gets no wait, new PCM queue, timer, ledger, UI owner, output graph or consequential effect. The barrier closes and releases every retained continuation once on every exit; after normal actual stop, the harness explicitly waits for native callbacks to join before restoring observers. Exceptional early-return cleanup cannot manufacture a successful join; missing joins are never a pass.

## Limits before using this as resumed-speaking authority

A valid post-resume cursor plus a strictly later completed interval is a diagnostic candidate. This does not prove a person's hearing or grant a live UI ownership switch. The actual probe must first demonstrate cursor/range coordinate compatibility and native packet ordering on this installed player. Scheduling nil means contiguous playback in the same sample-rate timeline, and stop resets the player origin, according to SDK; the actual recorded origin/rate/interval assertions are required.

This first fixture covers one accepted resume phase plus held pre-pause packet and explicit stop; it does not independently cover repeated pause/resume, native callback initially invoked late after resume for already-completed data, spontaneous engine loss, replacement-generation callback overlap or other backends. A post-resume node host timestamp is a stronger bound than a pre-pause lastRenderTime value, but raw actual measurements are required before treating it as complete acoustic authority. Do not relabel the diagnostic as an exact paused endpoint. Pocket/Kokoro/PocketSource remain open; do not change saved choices or switch the default backend to make this probe work.

Root serial commands: mount common nil original, build/install, run `Scripts/run-selftest.sh --selftest-apple-playback-timeline`; retain binary/Source/bundle/isolation and raw packet logs. Change only the checkpoint body, repeat the same fixture and related actual speech/reducer/suspend tests. Keep initial resume regression green once a separately reviewed producer fix is applied. No parent P3 or P3-09 readiness claim follows from this diagnostic.
