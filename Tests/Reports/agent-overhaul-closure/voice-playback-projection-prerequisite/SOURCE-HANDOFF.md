# Ready original/common/fixed handoff

No Source lease is claimed by this worker. Root can apply the following bounded files after coordinating existing owners; no additional producer capability or UI-owner unblock is needed for an isolated original run.

| Source path | Mount original/common first | Mount fixed only after retained valid red | Owner scope required |
|---|---|---|---|
| Agent/Duplex/VoiceContracts.swift | original-VoiceContracts.swift.txt | proposed-VoiceContracts.swift.txt | Root producer lease; no other worker edits this Source in this package |
| Agent/Duplex/VoiceSessionReducerSelfTest.swift | common-expectation-VoiceSessionReducerSelfTest.swift.txt | Exact same common file | Root existing test lease; original old expectations retained separately |
| Agent/Duplex/VoicePlaybackProjectionSelfTest.swift (NEW) | common-VoicePlaybackProjectionSelfTest.swift.txt | Exact same common file | Root new isolated test lease |
| NextNotesApp.swift | registration-snippet.swift.txt additive new flag branch | Exact same registration | Root coordinates registry owner; alternatively calls fixture through an existing root-owned test dispatcher |

Paths are relative to Sources/NextNotes. Capture/RealtimeAudio/Speech/VoiceSession/Island sources require no write lease for this candidate: they are real consumers/producers called unchanged. External website peer owns only off-source consumer review; no peer UI/Activation file is changed here.

## Existing producer seam audit

AgentSpeechSynthesizer.engineOverrideForTesting is honoured only when SelfTest.isRunning; selectedEngine returns it before any Settings read. The value apple routes to its existing systemBacking in prepareForStream. The conductor restores System backing, runs in a fresh single-flag process, rejects --voice-pocket-source, and sets no saved model/voice preference. There is no download/model preparation. Require retained actual playback route=settings AVSpeechBacking stdout to pin the selected native path; no fake playback backing or notifyTestingFirstAudio appears in native cases.

The real Apple backend's makeRenderCallback requires pcm.frameLength>0 and copies that buffer; play schedules .dataPlayedBack; bufferPlayed requires the actual token and pendingBuffers>0 before onUtteranceStarted, which calls the actual synthesizer didBeginAudio. The fixture wraps the existing synth onPlaybackEvent after RealtimeAudioSession.begin installed its consumer, preserving/calling that consumer exactly once per event. Late mode invokes the real capture cumulative partial producer before forwarding the native receipt, producing actual confirmed queued pause. No production await/timer/callback seam is added.

AgentCaptureController.simulateCumulativeSpeech primes its existing minSpeech timestamp; setting turnHandlerForTesting prevents both stageFrontendIfNeeded and prepareResponseForRecognizedSpeech from loading/staging/speculating. beginSession(captureAudio:false) skips microphone permission, speech decoder/audio capture and voice-model preparation. Native playback can still require a working signed-app audio route; missing actual callback is a failed input prerequisite, never green. EndSession/stop handle cleanup; owner StoreGuard compares files/defaults, without seeding or decoding the owner's conversation or task history.

The fake/recorded permission events in pureCases are explicitly reducer ownership controls, not an actual live pending Gate/card test. Existing physical playback is real; no speaker-audibility claim is made. Numeric frame-count metadata is absent from the callback API and cannot be invented. The current source positive-buffer guard plus native receipt is the evidence grade for this bounded onset/pause contract.

## Root serial commands and verdict discipline

Mount common files and original reducer, then make build / make install OPEN=0 through root's serial slot. Execute Scripts/run-selftest.sh --selftest-voice-playback-projection; retain exact stdout/out, Source/binary/bundle pins and Apple route. Optional original --selftest-voice-session-reducer uses the SAME amended common command expectations and intentionally exposes old projection mismatches; preserve the earlier unamended test separately. Do not treat a failed onset/control or premature natural drain as the intended producer red.

After valid original failure, change ONLY VoiceContracts producer bytes to the proposed fixed snapshot, repeat exact fixture, then run prescribed related reducer/duplex/work/suspend/live/isolation/latency checks. No loop waits for a broader UI gate before this bounded proof. No live speaking UI, approvalResolved restoring speak, inputDiscarded awaiting receipt or stale PREPAUSE→AFTERresume fence is granted. Full P3-09 owner switch and consumer acceptance remain distinct dependencies.
