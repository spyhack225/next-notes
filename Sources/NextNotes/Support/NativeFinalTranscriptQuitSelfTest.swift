import AppKit
import FluidAudio
import Foundation

/// COMMON real final service -> CAF reader -> shared native queue -> default
/// MeetingPipeline regression. No injected decoder or replacement pipeline.
@MainActor
enum NativeFinalTranscriptQuitSelfTest {
    nonisolated static let modes = ["final-pass-active", "final-pass-cancel", "final-pass-closed"]
    nonisolated static var isRequested: Bool {
        let args = CommandLine.arguments
        guard SelfTest.requested == "--selftest-native-termination",
              let position = args.firstIndex(of: "--native-startup-case"),
              args.indices.contains(position + 1) else { return false }
        return modes.contains(args[position + 1])
    }
    private static var capturedTask: Task<Void, Never>?
    private static var diagnosticJoin: Task<Void, Never>?

    static func armIfRequested() async throws -> Bool {
        guard isRequested else { return false }
        let args = CommandLine.arguments
        guard SelfTest.isRunning,
              let position = args.firstIndex(of: "--native-startup-case"), args.indices.contains(position + 1),
              let assets = args.firstIndex(of: "--native-startup-assets"), args.indices.contains(assets + 1),
              let delegate = AppDelegate.current else { throw CocoaError(.fileReadNoPermission) }
        let mode = args[position + 1]
        let assetRoot = try NativeStartupTerminationSelfTest.validateAssets(
            URL(fileURLWithPath: args[assets + 1]), pocket: false)
        let trace = FinalTranscriptTerminationTrace()
        func check(_ label: String, _ accepted: Bool) {
            trace.checks += 1
            if !accepted {
                trace.failures += 1; SelfTest.failed = true
                SelfTest.diagnostic("FINAL_TRANSCRIPT_TERMINATION_ASSERT_FAILED: \(label)")
            }
        }
        let settings = Settings.shared
        guard settings.usesHarnessPreferencesForTesting, NotesService.sharedIfLoaded == nil else {
            throw CocoaError(.fileReadNoPermission)
        }
        check("I01 process-owned preferences", settings.usesHarnessPreferencesForTesting)
        check("I02 actual default Notes owner starts unloaded", NotesService.sharedIfLoaded == nil)
        settings.notesAutoGenerate = false
        settings.chooseDiarization(false)
        settings.notesRelatedContext = false
        // COMMON factory routes ONLY these validated exact modes before any owner
        // MeetingStore initializer. This is the actual singleton used by default pipeline.
        let store = MeetingStore.shared
        let id = UUID()
        let root = store.directory(for: id).deletingLastPathComponent().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = "NextNotesMeetingResumeTest-"
        guard root.path == root.resolvingSymlinksInPath().path,
              root.deletingLastPathComponent().path == temporary.path,
              root.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil else {
            throw CocoaError(.fileReadNoPermission)
        }
        check("I03 canonical actual shared temporary meeting store", true)
        let agent = AgentService.shared
        guard !agent.hasCachedAuthStatus, !agent.authState.isSignedIn, !agent.isReady else {
            throw CocoaError(.fileReadNoPermission)
        }
        check("I04 real fresh Agent refuses followups before account/context queries",
              !agent.hasCachedAuthStatus && !agent.authState.isSignedIn && !agent.isReady)
        let meeting = Meeting(id: id, title: "Synthetic final transcript quit",
                              start: Date(timeIntervalSince1970: 1_700_000_000), status: .transcribing,
                              audioFileName: MeetingStore.audioFile)
        // nil is the existing unknown-retention contract: the real error fallback
        // cannot remove this recording; no diarization/problem-store read is needed.
        let live = [TranscriptSegment(start: 0, end: 4, text: "Synthetic preserved final pass input.", source: .mic)]
        guard store.save(meeting), store.saveTranscript(live, for: id) else {
            throw CocoaError(.fileWriteUnknown)
        }
        check("I05 real persisted final-pass input", store.meeting(id: id)?.status == .transcribing
              && store.transcript(for: id) == live)
        let audio = store.directory(for: id).appendingPathComponent(MeetingStore.audioFile)
        let writer = try MeetingAudioWriter(url: audio)
        let second = (0..<16_000).map { Float(0.05 * sin(2 * Double.pi * 200 * Double($0) / 16_000)) }
        for _ in 0..<4 {
            await writer.append(second, from: .mic)
            await writer.append(second, from: .system)
        }
        await writer.finish()
        let written = await writer.resourceSnapshot()
        check("I06 real stereo CAF writer completed exact frames", written.writtenFrames == 64_000
              && !written.writeFailed && !written.writeInFlight)
        let mic = try AudioConversion.samples(fromFileAt: audio, sampleRate: ChunkedTranscriber.sampleRate,
                                               channel: MeetingAudioWriter.micChannel)
        let system = try AudioConversion.samples(fromFileAt: audio, sampleRate: ChunkedTranscriber.sampleRate,
                                                  channel: MeetingAudioWriter.systemChannel)
        check("I07 actual CAF channels decode at canonical 16 kHz", ChunkedTranscriber.sampleRate == 16_000
              && mic.count == 64_000 && system.count == 64_000
              && ChunkedTranscriber.containsSpeech(mic) && ChunkedTranscriber.containsSpeech(system))
        let recordFile = store.directory(for: id).appendingPathComponent(MeetingStore.recordFile)
        let transcriptFile = store.directory(for: id).appendingPathComponent(MeetingStore.transcriptFile)
        let recordBefore = try Data(contentsOf: recordFile)
        let transcriptBefore = try Data(contentsOf: transcriptFile)
        let audioBefore = try Data(contentsOf: audio)
        check("I08 owned input bytes are nonempty", !recordBefore.isEmpty && !transcriptBefore.isEmpty && !audioBefore.isEmpty)
        ModelHub.offlineMode = true
        let models = try ParakeetModels(terminationFixtureRoot: assetRoot,
                                       trace: StartupTerminationTrace(autoQuit: false))
        let queue = TranscriptionQueue.shared
        let native = ASRQueueTerminationTrace(mode: mode)
        try await queue.configureTerminationFixture(models: models, trace: native)
        try await queue.warmUp()
        _ = try await queue.transcribe(mic)
        let qualified = native.snapshot()
        guard qualified.successfulReturns == 1 && qualified.nativeActive == 0
                && qualified.workAssigned == 1 && qualified.workEnded == 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        check("I09 actual native qualification returned", true)
        check("I10 offline native policy", ModelHub.offlineMode)
        let service = FinalTranscriptService.shared
        try service.configureFinalTerminationFixture(id: id, store: store, trace: trace)
        func preservedBytes() -> Bool {
            (try? Data(contentsOf: recordFile)) == recordBefore
                && (try? Data(contentsOf: transcriptFile)) == transcriptBefore
                && (try? Data(contentsOf: audio)) == audioBefore
        }
        func preservedRow() -> Bool {
            let fresh = store.freshReaderForTesting()
            return fresh.meeting(id: id)?.status == .transcribing
                && fresh.meeting(id: id)?.transcriptPass == nil
                && fresh.transcript(for: id) == live
        }
        try delegate.configureStartupTerminationFixture(parakeet: nil, pocket: nil, queue: queue,
            reply: { reply in
                check("Q01 actual Cocoa quit returns Later", reply == .terminateLater)
                if mode == "final-pass-active" {
                    let observed = native.snapshot()
                    let overlap = observed.nativeActive == 1 && observed.successfulReturns == 1
                        && observed.workAssigned - observed.workEnded == 1 && trace.endedTasks == 0
                    check("Q02 actual final native await remains outstanding at quit", overlap)
                    if !overlap { trace.invalid = true }
                    check("F01 actual delegate captured the retained final owner", trace.firstCapturedCount == 1)
                    check("F02 actual delegate cancelled SAME captured final Task", capturedTask?.isCancelled == true)
                }
                SelfTest.diagnostic("FINAL_TRANSCRIPT_TERMINATION_REPLY_TRACE mode=\(mode) captured=\(trace.firstCapturedCount ?? -1) assigned=\(trace.assignedTasks) ended=\(trace.endedTasks) handoffs=\(trace.handoffs)")
            }, willExit: {
                let observed = native.snapshot()
                check("E01 actual native queue drains balanced API work", observed.nativeStarts == 2
                      && observed.nativeEnds == 2 && observed.nativeActive == 0 && observed.successfulReturns == 2)
                check("F15 actual final map is released only after Task body", !service.isRunning(id)
                      && trace.assignedTasks == trace.endedTasks)
                check("E03 no generated notes or proposals", store.notes(for: id) == nil
                      && store.proposals(for: id).isEmpty)
                check("E04 harness choices/fresh Agent refusal stay exact", settings.usesHarnessPreferencesForTesting
                      && !settings.notesAutoGenerate && !settings.meetingsDiarize && !settings.notesRelatedContext
                      && !agent.hasCachedAuthStatus && !agent.isReady && ModelHub.offlineMode)
                if mode == "final-pass-active" {
                    check("F03 native final pass publishes no late default pipeline handoff", trace.handoffs == 0)
                    check("F04 quit preserves exact resumable meeting/input bytes", preservedBytes())
                    check("F05 fresh stored final stage remains transcribing", preservedRow())
                    check("F06 quit creates no late default Notes owner", NotesService.sharedIfLoaded == nil)
                }
                SelfTest.diagnostic("FINAL_TRANSCRIPT_TERMINATION_EXIT_TRACE mode=\(mode) assigned=\(trace.assignedTasks) ended=\(trace.endedTasks) handoffs=\(trace.handoffs) captures=\(trace.captureCalls) firstCaptured=\(trace.firstCapturedCount ?? -1) nativeStarts=\(observed.nativeStarts) nativeEnds=\(observed.nativeEnds) active=\(observed.nativeActive) checks=\(trace.checks) failures=\(trace.failures) invalid=\(trace.invalid)")
                if trace.invalid {
                    SelfTest.failed = true
                    SelfTest.diagnostic("FINAL_TRANSCRIPT_TERMINATION_INVALID: actual final native overlap unavailable")
                } else {
                    SelfTest.diagnostic(trace.failures == 0
                        ? "FINAL_TRANSCRIPT_TERMINATION_OK: \(trace.checks) checks"
                        : "FINAL_TRANSCRIPT_TERMINATION_FAILED: \(trace.failures)/\(trace.checks)")
                }
                try? FileManager.default.removeItem(at: root)
            })
        native.onBoundary = { boundary in
            guard boundary == .activeNative else { return }
            native.onBoundary = nil
            let observed = native.snapshot()
            let overlap = observed.nativeActive == 1 && observed.successfulReturns == 1
                && observed.workAssigned - observed.workEnded == 1
            check("B01 same real final native call pending after prior native success", overlap)
            if !overlap { trace.invalid = true }
            guard let owned = service.finalTerminationTaskForTesting(id: id) else {
                check("B02 actual final map handle exists", false)
                trace.invalid = true; SelfTest.requestTermination(); return
            }
            capturedTask = owned
            check("B02 actual same final Task is owned before cancellation", service.isRunning(id)
                  && trace.assignedTasks == 1 && trace.endedTasks == 0 && !owned.isCancelled)
            if mode == "final-pass-active" {
                SelfTest.requestTermination()
                return
            }
            service.cancel(id)
            check("C01 captured original Task receives real cancellation", owned.isCancelled)
            check("F07 ordinary cancel retains native owner until actual Task completion", service.isRunning(id)
                  && service.finalTerminationTaskForTesting(id: id)?.isCancelled == true)
            var refusedReplacement: Task<Void, Never>?
            if mode == "final-pass-cancel" {
                let before = trace.assignedTasks
                service.process(meeting, store: store)
                check("F14 same-ID process cannot replace still-owned cancelled native pass",
                      trace.assignedTasks == before)
                if trace.assignedTasks != before {
                    refusedReplacement = service.finalTerminationTaskForTesting(id: id)
                    // ORIGINAL-only admitted successor is cancelled synchronously
                    // before it starts. Retain and join this SAME real handle too.
                    refusedReplacement?.cancel()
                }
            }
            if mode == "final-pass-closed" {
                let captured = service.beginTermination()
                check("F08 quit captures cancelled SAME map owner", captured.count == 1 && trace.firstCapturedCount == 1)
            } else {
                check("C02 ordinary cancellation test has not closed service", trace.captureCalls == 0)
            }
            // Identical COMMON diagnostic-only join. It does not pretend ordinary
            // MeetingController.stop or cancellation gained a product await.
            let replacementToJoin = refusedReplacement
            diagnosticJoin = Task { @MainActor in
                await owned.value
                await replacementToJoin?.value
                let joined = native.snapshot()
                check("C03 SAME real native call and final Task fully returned", joined.nativeStarts == 2
                      && joined.nativeEnds == 2 && joined.successfulReturns == 2 && joined.nativeActive == 0
                      && trace.assignedTasks == trace.endedTasks && !service.isRunning(id))
                check("F09 cancelled pass emits no default pipeline handoff", trace.handoffs == 0)
                check("F10 exact persisted final input bytes stay unchanged", preservedBytes())
                check("F11 fresh primary meeting remains resumable", preservedRow())
                check("F12 cancelled pass creates no default Notes owner", NotesService.sharedIfLoaded == nil)
                if mode == "final-pass-closed" {
                    let before = trace.assignedTasks
                    service.process(meeting, store: store)
                    let late = service.finalTerminationTaskForTesting(id: id)
                    check("F13 closed final owner refuses actual late process entry", late == nil && trace.assignedTasks == before)
                    // If ORIGINAL admits a late Task, cancel and join SAME handle
                    // immediately before it runs; never execute another native pass.
                    late?.cancel()
                    await late?.value
                    check("C04 refused/cancelled late entry runs no extra native call", native.snapshot().nativeStarts == 2)
                }
                SelfTest.diagnostic("FINAL_TRANSCRIPT_TERMINATION_JOIN_TRACE mode=\(mode) handoffs=\(trace.handoffs) assigned=\(trace.assignedTasks) ended=\(trace.endedTasks) preserved=\(preservedBytes()) transcribing=\(preservedRow()) notesLoaded=\(NotesService.sharedIfLoaded != nil)")
                SelfTest.requestTermination()
            }
        }
        SelfTest.diagnostic("FINAL_TRANSCRIPT_TERMINATION_INPUT_OK: actual CAF/default pipeline/shared queue, mode=\(mode)")
        service.process(meeting, store: store)
        return true
    }
}

/// MainActor scalar trace; no task registry, native gate, payload or timer.
@MainActor
final class FinalTranscriptTerminationTrace {
    var assignedTasks = 0
    var endedTasks = 0
    var handoffs = 0
    var captureCalls = 0
    var firstCapturedCount: Int?
    var checks = 0
    var failures = 0
    var invalid = false
    func assigned() { assignedTasks += 1 }
    func ended() { endedTasks += 1 }
    func handoff() { handoffs += 1 }
    func captured(count: Int) {
        captureCalls += 1
        if firstCapturedCount == nil { firstCapturedCount = count }
    }
}
