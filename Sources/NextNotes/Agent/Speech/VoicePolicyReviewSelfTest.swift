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
            synth.setVoiceReadinessForTesting(engine: "pocket", ready: true)
            synth.setVoiceReadinessForTesting(engine: "kokoro", ready: true)
            synth.prepareForStream() // actual selector, no clause/model entry
            if synth.supportsQualifiedResumeReceipt != false { failures.append("R1: \(engine) lacks an honest unsupported resume capability contract") }
        }
        synth.engineOverrideForTesting = "pocket"
        let failedPlayback = PCMReceiptSpeechBacking()
        synth.useTestingBacking(failedPlayback)
        let failedClause = "The selected voice failed during playback."
        synth.speak(failedClause)
        failedPlayback.onFailure?(failedClause, 1, synth.currentPlaybackToken)
        if synth.availability != .failed || synth.outputAvailability != .failed || failedPlayback.isSpeaking {
            failures.append("R2: actual backing failure did not settle selected availability")
        }
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
        let readyControlBefore = audioCalls
        do {
            _ = try await LongFormSynthesisFactory.live()(.init(text: "Explicit recovery allows the selected ready voice.", speaker: nil))
        } catch { failures.append("R2: ready control rejected") }
        if audioCalls != readyControlBefore + 1 { failures.append("R2: ready control entry count") }
        LongFormSynthesisFactory.audioForTesting = { audioCalls += 1; throw ReviewFixtureError.unavailable }
        do { _ = try await LongFormSynthesisFactory.live()(.init(text: "File voice fails once.", speaker: nil)) } catch { }
        if synth.availability != .failed { failures.append("R2: file synthesis failure did not latch selected availability") }
        let failedFileCalls = audioCalls
        do { _ = try await LongFormSynthesisFactory.live()(.init(text: "Do not retry the failed file voice.", speaker: nil)) } catch { }
        if audioCalls != failedFileCalls { failures.append("R2: subsequent Catch-up retried failed file synthesis") }
        synth.setVoiceFailureForTesting(false)
        LongFormSynthesisFactory.audioForTesting = { throw CancellationError() }
        do { _ = try await LongFormSynthesisFactory.live()(.init(text: "Cancelled rendering is not a voice failure.", speaker: nil)) } catch { }
        if synth.availability != .ready { failures.append("R2: cancellation latched a voice failure") }
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
        let explicitRetryBefore = failedLoads
        failedOwner.initializeForTesting = { failedLoads += 1 }
        await failedOwner.prepare() // explicit retry is allowed
        if failedLoads != explicitRetryBefore + 1 || !failedOwner.isReady || failedOwner.errorMessage != nil {
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
        // Observe the actual queued lane, rather than assuming a scheduled Task ran.
        var queuedPreparation = false
        for _ in 0..<100 {
            if await scheduler.occupancy().isBusy(.background) { queuedPreparation = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if !queuedPreparation { failures.append("R4: preparation has no owned background admission") }
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
        let downloadingOwner = PocketAgentVoice()
        var downloadPressure = ModelResidencyPolicy.PressureLevel.normal
        var downloads = 0, downloadLoads = 0, downloadWarms = 0
        downloadingOwner.schedulerForTesting = ComputeScheduler()
        downloadingOwner.pressureForTesting = { .init(level: downloadPressure, generation: 0, changedAt: Date()) }
        let download: @MainActor () async throws -> Void = {
            if downloads == 0 { downloads += 1; downloadPressure = .critical }
        }
        downloadingOwner.assetsForTesting = download
        // Original SDK initialize bundles download then native load. The fake
        // preserves that order until the owner separates the existing downloader.
        downloadingOwner.initializeForTesting = {
            if downloads == 0 { try await download() }
            downloadLoads += 1
        }
        downloadingOwner.warmForTesting = { downloadWarms += 1 }
        await downloadingOwner.prepareAutomatically()
        if downloads != 1 || downloadLoads != 0 || downloadWarms != 0 || !downloadingOwner.isPreparing {
            failures.append("R4: no resource recheck between asset wait and native initialization")
        }
        downloadingOwner.beginTermination(); await downloadingOwner.finishTermination()
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
        let unavailableControlBefore = synth.speechSynthesisCallsForTesting
        synth.useUnavailableVoiceForTesting()
        synth.speak("Unavailable output stays written.")
        if synth.speechSynthesisCallsForTesting != unavailableControlBefore { failures.append("R8: unavailable selector entered synthesis") }
        if SelfTest.failed { failures.append("harness propagated an independent failure") }
        return failures
    }
}

private enum ReviewFixtureError: Error { case unavailable }
