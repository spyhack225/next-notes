import Foundation

/// Actual selected owner/adapter admission; native init/warm and file samples are scripted.
@MainActor
enum VoicePolicyReviewSelfTest {
    static func run() async -> [String] {
        guard SelfTest.isRunning else { return ["harness required"] }
        var failures: [String] = []
        let synth = AgentSpeechSynthesizer.shared
        defer { synth.stop(); synth.restoreSystemBacking(); synth.clearVoiceReadinessForTesting() }
        for engine in ["pocket", "kokoro"] {
            synth.restoreSystemBacking()
            synth.engineOverrideForTesting = engine
            synth.pocketReadinessForTesting = true; synth.kokoroReadinessForTesting = true
            synth.prepareForStream() // actual selector, no clause/model entry
            if synth.supportsQualifiedResumeReceipt { failures.append("R1: \(engine) claims unavailable qualified resume capability") }
        }
        synth.engineOverrideForTesting = "pocket"
        synth.setVoiceFailureForTesting(true)
        var audioCalls = 0
        LongFormSynthesisFactory.audioForTesting = {
            audioCalls += 1
            return .init(samples: [0.25, -0.25], sampleRate: 24_000)
        }
        defer { LongFormSynthesisFactory.audioForTesting = nil }
        do {
            _ = try await LongFormSynthesisFactory.live()(.init(text: "Catch-up stays written after voice failure.", speaker: nil))
            failures.append("R2: failed selected voice produced file audio")
        } catch { }
        if audioCalls != 0 { failures.append("R2: failed Catch-up reached synthesis entry") }
        synth.setVoiceFailureForTesting(false)
        do {
            _ = try await LongFormSynthesisFactory.live()(.init(text: "Explicit recovery allows the selected ready voice.", speaker: nil))
        } catch { failures.append("R2: ready control rejected") }
        if audioCalls != 1 { failures.append("R2: ready control entry count") }
        let failedOwner = PocketAgentVoice()
        var failedLoads = 0
        failedOwner.initializeForTesting = { failedLoads += 1; throw ReviewFixtureError.unavailable }
        failedOwner.warmForTesting = { }
        await failedOwner.prepare() // one explicit failed load
        do { _ = try await failedOwner.frames(for: "No implicit load retry.", voice: "alba") } catch { }
        do { _ = try await failedOwner.makeReplySession(voice: "alba") } catch { }
        if failedLoads != 1 || failedOwner.errorMessage == nil {
            failures.append("R2: failed native owner silently retried through frames/session")
        }
        failedOwner.initializeForTesting = { failedLoads += 1 }
        await failedOwner.prepare() // explicit retry is allowed
        if failedLoads != 2 || !failedOwner.isReady || failedOwner.errorMessage != nil {
            failures.append("R2: explicit owner retry failed")
        }
        failedOwner.beginTermination(); await failedOwner.finishTermination()
        for initialLevel in [ModelResidencyPolicy.PressureLevel.warning, .critical] {
            var level = initialLevel
            let owner = PocketAgentVoice()
            let scheduler = ComputeScheduler()
            var loads = 0, warms = 0
            owner.schedulerForTesting = scheduler
            owner.pressureForTesting = { .init(level: level, generation: 1, changedAt: Date()) }
            owner.initializeForTesting = { loads += 1 }
            owner.warmForTesting = { warms += 1 }
            await owner.prepareAutomatically()
            if loads != 0 || warms != 0 || owner.isReady { failures.append("R4: \(level) admitted native initialization/warm") }
            if !owner.isPreparing || owner.errorMessage != nil { failures.append("R4: deferred preparation is not truthfully getting ready") }
            level = .normal
            NotificationCenter.default.post(name: Notification.Name("NextNotesOptionalModelAdmissionChanged"), object: nil)
            for _ in 0..<100 where !owner.isReady { try? await Task.sleep(for: .milliseconds(10)) }
            if loads != 1 || warms != 1 || !owner.isReady { failures.append("R4: normal event did not retry the existing owner once") }
            owner.beginTermination(); await owner.finishTermination()
        }
        let owner = PocketAgentVoice(), scheduler = ComputeScheduler()
        owner.schedulerForTesting = scheduler
        var waitingPressure = ModelResidencyPolicy.PressureLevel.normal
        owner.pressureForTesting = { .init(level: waitingPressure, generation: 0, changedAt: Date()) }
        var loads = 0, warms = 0
        owner.initializeForTesting = { loads += 1 }
        owner.warmForTesting = { warms += 1 }
        let asr = await scheduler.acquire(.realtimeASR)
        let preparing = Task { @MainActor in await owner.prepareAutomatically() }
        // Bounded observation only; not a product delay.
        try? await Task.sleep(for: .milliseconds(40))
        if loads != 0 || warms != 0 { failures.append("R4: ASR hold admitted initialization/warm") }
        waitingPressure = .critical
        await scheduler.release(asr); await preparing.value
        if loads != 0 || warms != 0 || !owner.isPreparing { failures.append("R4: no pressure recheck after ASR wait") }
        waitingPressure = .normal
        NotificationCenter.default.post(name: Notification.Name("NextNotesOptionalModelAdmissionChanged"), object: nil)
        for _ in 0..<100 where !owner.isReady { try? await Task.sleep(for: .milliseconds(10)) }
        if loads != 1 || warms != 1 || !owner.isReady { failures.append("R4: released existing preparation did not initialize/warm once") }
        owner.beginTermination(); await owner.finishTermination()
        let recordingOwner = PocketAgentVoice()
        var recording = true, recordingLoads = 0, recordingWarms = 0
        recordingOwner.schedulerForTesting = ComputeScheduler()
        recordingOwner.pressureForTesting = { .init(level: .normal, generation: 0, changedAt: Date()) }
        recordingOwner.recordingForTesting = { recording }
        recordingOwner.initializeForTesting = { recordingLoads += 1 }
        recordingOwner.warmForTesting = { recordingWarms += 1 }
        await recordingOwner.prepareAutomatically()
        if recordingLoads != 0 || recordingWarms != 0 || !recordingOwner.isPreparing {
            failures.append("R4: active meeting/dictation admitted optional native work")
        }
        recording = false
        NotificationCenter.default.post(name: Notification.Name("NextNotesOptionalModelAdmissionChanged"), object: nil)
        for _ in 0..<100 where !recordingOwner.isReady { try? await Task.sleep(for: .milliseconds(10)) }
        if recordingLoads != 1 || recordingWarms != 1 || !recordingOwner.isReady { failures.append("R4: idle activity did not retry existing preparation") }
        recordingOwner.beginTermination(); await recordingOwner.finishTermination()
        let withdrawingOwner = PocketAgentVoice()
        var nativePressure = ModelResidencyPolicy.PressureLevel.normal
        var stageLoads = 0, stageWarms = 0
        withdrawingOwner.schedulerForTesting = ComputeScheduler()
        withdrawingOwner.pressureForTesting = { .init(level: nativePressure, generation: 0, changedAt: Date()) }
        withdrawingOwner.initializeForTesting = { stageLoads += 1; nativePressure = .warning }
        withdrawingOwner.warmForTesting = { stageWarms += 1 }
        await withdrawingOwner.prepareAutomatically()
        if stageLoads != 1 || stageWarms != 0 || withdrawingOwner.isReady || !withdrawingOwner.isPreparing {
            failures.append("R4: pressure change during init did not defer warm prediction")
        }
        withdrawingOwner.beginTermination(); await withdrawingOwner.finishTermination()
        let pcm = PCMReceiptSpeechBacking()
        synth.useTestingBacking(pcm)
        synth.speak("Malformed receipts must reach the real receiver without fake filtering.")
        let token = synth.currentPlaybackToken
        synth.notifyTestingFirstAudio(token: token)
        synth.pauseForListening(); synth.resumeAfterListening()
        let good = pcm.resumeReceipt(token: token)
        let bad = PCMResumePlaybackReceipt(packet: good.packet, earlier: good.later,
            later: good.earlier, checkpoint: good.checkpoint, checkpointBuffer: good.checkpointBuffer)
        pcm.onResumePlaybackAcknowledged?(bad)
        if !synth.voiceLifecycleSnapshot.resumePending { failures.append("R6: actual synth accepts reversed native cursor receipt") }
        synth.stop(); synth.restoreSystemBacking()
        failures += await NativePCMReceiptSelfTest.run()
        let beforeCalls = synth.speechSynthesisCallsForTesting
        PocketAgentVoice.shared.initializeForTesting = { throw ReviewFixtureError.unavailable }
        defer { PocketAgentVoice.shared.initializeForTesting = nil }
        do { _ = try await PocketAgentVoice.shared.frames(for: "Diagnostic synthesis request.", voice: "alba") }
        catch { }
        if synth.speechSynthesisCallsForTesting != beforeCalls + 1 { failures.append("R8: neutral counter does not observe allowed synthesis entry") }
        synth.useUnavailableVoiceForTesting()
        synth.speak("Unavailable output stays written.")
        if synth.speechSynthesisCallsForTesting != beforeCalls + 1 { failures.append("R8: unavailable selector entered synthesis") }
        return failures
    }
}

private enum ReviewFixtureError: Error { case unavailable }
