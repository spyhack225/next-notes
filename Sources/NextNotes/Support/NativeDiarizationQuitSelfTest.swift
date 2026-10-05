import AppKit
import FluidAudio
import Foundation

/// COMMON real service/CAF/native clustering/default pipeline fixture. Exact
/// diagnostic watchdog trigger exercises its installed closure, not elapsed health.
@MainActor
enum NativeDiarizationQuitSelfTest {
    nonisolated static let modes = ["diarizer-active", "diarizer-cancel", "diarizer-closed",
                                    "diarizer-stall", "diarizer-stall-cancel", "diarizer-stall-quit"]
    nonisolated static var isRequested: Bool {
        let args = CommandLine.arguments
        guard SelfTest.requested == "--selftest-native-termination",
              let index = args.firstIndex(of: "--native-startup-case"), args.indices.contains(index + 1) else { return false }
        return modes.contains(args[index + 1])
    }
    private static var capturedTask: Task<Void, Never>?
    private static var diagnosticJoin: Task<Void, Never>?

    nonisolated static func validateAssets(_ candidate: URL) throws -> URL {
        let fm = FileManager.default
        let root = candidate.standardizedFileURL
        let temporary = fm.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = "NextNotesStartupTerminationTest-"
        guard root.path == root.resolvingSymlinksInPath().path,
              root.deletingLastPathComponent().path == temporary.path,
              root.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil else { throw CocoaError(.fileReadNoPermission) }
        let directory = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directory.isDirectory == true, directory.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
        let modelNames = ["Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc"]
        let models = root.appendingPathComponent("speaker-diarization", isDirectory: true)
        for name in modelNames {
            let model = models.appendingPathComponent(name, isDirectory: true)
            let value = try model.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard value.isDirectory == true, value.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
            let core = try model.appendingPathComponent("coremldata.bin").resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard core.isRegularFile == true, core.isSymbolicLink != true, (core.fileSize ?? 0) > 0 else { throw CocoaError(.fileReadCorruptFile) }
        }
        for name in ["speaker-diarization/plda-parameters.json", "fr-dialogue.wav"] {
            let value = try root.appendingPathComponent(name).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard value.isRegularFile == true, value.isSymbolicLink != true, (value.fileSize ?? 0) > 0 else { throw CocoaError(.fileReadCorruptFile) }
        }
        guard let items = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]) else { throw CocoaError(.fileReadNoPermission) }
        for case let item as URL in items {
            let canonical = item.standardizedFileURL
            guard canonical.path.hasPrefix(root.path + "/"), canonical.path == canonical.resolvingSymlinksInPath().path else { throw CocoaError(.fileReadNoPermission) }
            let value = try item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard value.isSymbolicLink != true, value.isDirectory == true || value.isRegularFile == true else { throw CocoaError(.fileReadNoPermission) }
            let relative = String(canonical.path.dropFirst(root.path.count + 1))
            let allowed = relative == "fr-dialogue.wav" || relative == "startup.log"
                || relative == "speaker-diarization" || relative == "speaker-diarization/plda-parameters.json"
                || modelNames.contains { relative == "speaker-diarization/" + $0 || relative.hasPrefix("speaker-diarization/" + $0 + "/") }
            guard allowed else { throw CocoaError(.fileReadNoPermission) }
        }
        return root
    }
    static func isConfinedMeetingStore(_ store: MeetingStore) -> Bool {
        let root = store.directory(for: UUID()).deletingLastPathComponent().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = "NextNotesMeetingResumeTest-"
        return root.path == root.resolvingSymlinksInPath().path && root.deletingLastPathComponent().path == temporary.path
            && root.lastPathComponent.hasPrefix(prefix)
            && UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil
    }

    static func armIfRequested() async throws -> Bool {
        guard isRequested else { return false }
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--native-startup-case"), args.indices.contains(index + 1),
              let assets = args.firstIndex(of: "--native-startup-assets"), args.indices.contains(assets + 1),
              let delegate = AppDelegate.current, SelfTest.isRunning else { throw CocoaError(.fileReadNoPermission) }
        let mode = args[index + 1]
        let assetRoot = try validateAssets(URL(fileURLWithPath: args[assets + 1]))
        let trace = DiarizationTerminationTrace()
        let native = DiarizerNativeTrace()
        func check(_ label: String, _ accepted: Bool) {
            trace.checks += 1
            if !accepted { trace.failures += 1; SelfTest.failed = true; SelfTest.diagnostic("DIARIZATION_TERMINATION_ASSERT_FAILED: \(label)") }
        }
        let settings = Settings.shared
        guard settings.usesHarnessPreferencesForTesting, NotesService.sharedIfLoaded == nil else { throw CocoaError(.fileReadNoPermission) }
        check("I01 isolated preferences and initially unloaded Notes", settings.usesHarnessPreferencesForTesting && NotesService.sharedIfLoaded == nil)
        settings.chooseDiarization(false); settings.notesAutoGenerate = false; settings.notesRelatedContext = false
        let store = MeetingStore.shared
        guard isConfinedMeetingStore(store) else { throw CocoaError(.fileReadNoPermission) }
        check("I02 actual shared MeetingStore confined before default pipeline", true)
        let agent = AgentService.shared
        guard !agent.hasCachedAuthStatus, !agent.authState.isSignedIn, !agent.isReady else { throw CocoaError(.fileReadNoPermission) }
        check("I03 actual fresh Agent is unready", true)
        let id = UUID()
        let meeting = Meeting(id: id, title: "Synthetic diarization owner", start: Date(timeIntervalSince1970: 1_700_000_000), status: .diarizing, audioFileName: MeetingStore.audioFile)
        let live = [TranscriptSegment(start: 0, end: 4, text: "Synthetic preserved speaker input.", source: .system)]
        guard store.save(meeting), store.saveTranscript(live, for: id) else { throw CocoaError(.fileWriteUnknown) }
        let samples = try AudioConversion.samples(fromFileAt: assetRoot.appendingPathComponent("fr-dialogue.wav"), sampleRate: 16_000, channel: nil)
        guard samples.count > 800_000, ChunkedTranscriber.containsSpeech(samples) else { throw CocoaError(.fileReadCorruptFile) }
        let audio = store.directory(for: id).appendingPathComponent(MeetingStore.audioFile)
        let writer = try MeetingAudioWriter(url: audio)
        var cursor = 0
        while cursor < samples.count {
            let end = min(cursor + 16_000, samples.count)
            let packet = Array(samples[cursor..<end])
            await writer.append([Float](repeating: 0, count: packet.count), from: .mic)
            await writer.append(packet, from: .system)
            cursor = end
        }
        await writer.finish()
        let written = await writer.resourceSnapshot()
        check("I04 actual synthetic stereo CAF complete", written.writtenFrames == samples.count && !written.writeFailed && !written.writeInFlight)
        let system = try AudioConversion.samples(fromFileAt: audio, sampleRate: 16_000, channel: MeetingAudioWriter.systemChannel)
        check("I05 actual system CAF carries synthetic speech", system.count == samples.count && ChunkedTranscriber.containsSpeech(system))
        let record = store.directory(for: id).appendingPathComponent(MeetingStore.recordFile)
        let transcript = store.directory(for: id).appendingPathComponent(MeetingStore.transcriptFile)
        let recordBefore = try Data(contentsOf: record)
        let transcriptBefore = try Data(contentsOf: transcript)
        let audioBefore = try Data(contentsOf: audio)
        func preserved() -> Bool { (try? Data(contentsOf: record)) == recordBefore && (try? Data(contentsOf: transcript)) == transcriptBefore && (try? Data(contentsOf: audio)) == audioBefore }
        func resumable() -> Bool { let fresh = store.freshReaderForTesting(); return fresh.meeting(id: id)?.status == .diarizing && fresh.transcript(for: id) == live }
        ModelHub.offlineMode = true
        let diarizer = MeetingDiarizer.shared
        try await diarizer.configureTerminationFixture(directory: assetRoot, trace: native)
        try await diarizer.prepare()
        let qualification = try await diarizer.speakerRuns(in: system)
        let qualified = native.snapshot()
        guard !qualification.isEmpty, qualified.starts == 1, qualified.ends == 1, qualified.active == 0, qualified.successes == 1 else { throw CocoaError(.fileReadCorruptFile) }
        check("I06 actual native clustering qualification returned speaker runs", true)
        check("I07 real source bytes and native offline policy", preserved() && resumable() && ModelHub.offlineMode)
        let service = DiarizationService.shared
        try service.configureTerminationFixture(id: id, store: store, trace: trace)
        let healthyStall = mode == "diarizer-stall"
        let cocoaActive = mode == "diarizer-active" || mode == "diarizer-stall-quit"
        var measuredInitialReply = false
        var measuredFinalVerdict = false
        var safeExitVetoes = 0
        func measureFinalVerdict() {
            guard !measuredFinalVerdict else { return }
            measuredFinalVerdict = true
            let observed = native.snapshot()
            check("F15 native API brackets drain before accepted exit", observed.starts == 2 && observed.ends == 2 && observed.active == 0)
            check("F03 map releases only after actual service Task ends", !service.isRunning(id) && trace.assignedTasks == trace.endedTasks)
            if cocoaActive {
                check("F04 quit publishes no default pipeline handoff", trace.handoffs == 0)
                check("F05 exact original record transcript and audio retained", preserved() && resumable())
                check("F06 no late Notes singleton construction", NotesService.sharedIfLoaded == nil)
            }
            SelfTest.diagnostic("DIARIZATION_TERMINATION_FIRST_FINAL_REPLY_TRACE mode=\(mode) nativeActive=\(observed.active) nativeEnds=\(observed.ends) assigned=\(trace.assignedTasks) ended=\(trace.endedTasks) handoffs=\(trace.handoffs) preserved=\(preserved())")
        }
        try delegate.configureStartupTerminationFixture(parakeet: nil, pocket: nil, diarizer: diarizer,
            finalReply: { accepted in
                guard accepted else { return false }
                measureFinalVerdict()
                let pending = native.snapshot().active > 0 || trace.endedTasks < trace.assignedTasks
                guard pending else { return true }
                // COMMON safety AFTER first actual product verdict: refuse exit,
                // then join the SAME captured original task. This cannot repair
                // or overwrite the already measured first-verdict failures.
                guard safeExitVetoes == 0, let owned = capturedTask else {
                    trace.invalid = true; SelfTest.failed = true
                    SelfTest.diagnostic("DIARIZATION_TERMINATION_INVALID: safe cleanup has no exact owner")
                    return false
                }
                safeExitVetoes += 1
                SelfTest.diagnostic("DIARIZATION_TERMINATION_SAFE_EXIT_VETO: pending exact owner after measured verdict")
                diagnosticJoin = Task { @MainActor in
                    await owned.value
                    SelfTest.requestTermination()
                }
                return false
            }, reply: { reply in
                guard !measuredInitialReply else { return }
                measuredInitialReply = true
                check("Q01 actual Cocoa quit is asynchronous", reply == .terminateLater)
                if cocoaActive {
                    let observed = native.snapshot()
                    let overlap = observed.active == 1 && observed.successes == 1 && trace.endedTasks == 0
                    check("Q02 native clustering owner outstanding at actual quit", overlap)
                    if !overlap { trace.invalid = true }
                    check("F01 delegate captures retained same diarizer Task", trace.firstCapturedCount == 1)
                    check("F02 actual captured Task cancelled before native return", capturedTask?.isCancelled == true)
                }
            }, willExit: {
                let observed = native.snapshot()
                measureFinalVerdict()
                check("E02 harness choices preserved", settings.usesHarnessPreferencesForTesting && !settings.meetingsDiarize && !settings.notesAutoGenerate && !settings.notesRelatedContext && !agent.isReady && ModelHub.offlineMode)
                check("E03 no generated notes or proposals", store.notes(for: id) == nil && store.proposals(for: id).isEmpty)
                SelfTest.diagnostic("DIARIZATION_TERMINATION_EXIT_TRACE mode=\(mode) nativeStarts=\(observed.starts) nativeEnds=\(observed.ends) active=\(observed.active) successes=\(observed.successes) assigned=\(trace.assignedTasks) ended=\(trace.endedTasks) handoffs=\(trace.handoffs) captured=\(trace.firstCapturedCount ?? -1) progressReplay=\(trace.replayed) safeVetoes=\(safeExitVetoes) checks=\(trace.checks) failures=\(trace.failures) invalid=\(trace.invalid)")
                if trace.invalid { SelfTest.failed = true; SelfTest.diagnostic("DIARIZATION_TERMINATION_INVALID: actual native progress overlap unavailable") }
                else { SelfTest.diagnostic(trace.failures == 0 ? "DIARIZATION_TERMINATION_OK: \(trace.checks) checks" : "DIARIZATION_TERMINATION_FAILED: \(trace.failures)/\(trace.checks)") }
                try? FileManager.default.removeItem(at: store.directory(for: id).deletingLastPathComponent())
            })
        trace.onFirstProgress = {
            let observed = native.snapshot()
            let overlap = observed.active == 1 && observed.successes == 1 && trace.endedTasks == 0
            check("B01 actual second native API still pending at real progress callback", overlap)
            if !overlap { trace.invalid = true; SelfTest.requestTermination(); return }
            guard let owned = service.ownedTerminationTaskForTesting(id: id) else { trace.invalid = true; SelfTest.requestTermination(); return }
            capturedTask = owned
            check("B02 same live uncancelled Task owns pending service", service.isRunning(id) && !owned.isCancelled && trace.assignedTasks == 1)
            if mode.contains("stall") {
                check("W01 real installed onStall closure invoked", service.triggerActualWatchdogForTesting(id: id))
                check("W02 real watchdog marks problem and cancels exact handle", service.problem(for: id) == StageWatchdog.stallMessage && owned.isCancelled)
            }
            if cocoaActive { SelfTest.requestTermination(); return }
            if !healthyStall {
                service.cancel(id)
                check("C01 ordinary cancel cancels captured real Task", owned.isCancelled)
            }
            check("F07 native owner retained until body really returns", service.isRunning(id) && service.ownedTerminationTaskForTesting(id: id)?.isCancelled == true)
            let before = service.fraction(for: id)
            trace.replayHeldProgress()
            check("F08 cancelled old progress cannot stamp current UI clock/fraction", service.fraction(for: id) == before)
            if mode == "diarizer-closed" {
                let handles = service.beginTermination()
                check("F09 close captures same cancelled owner", handles.count == 1 && trace.firstCapturedCount == 1)
            }
            diagnosticJoin = Task { @MainActor in
                await owned.value
                let joined = native.snapshot()
                check("J01 exact real pending Task and API ended", joined.starts == 2 && joined.ends == 2 && joined.active == 0 && trace.assignedTasks == trace.endedTasks)
                if healthyStall {
                    check("W03 intended watchdog fallback forwards exactly once", trace.handoffs == 1)
                    check("W04 actual default pipeline finishes stalled meeting", store.freshReaderForTesting().meeting(id: id)?.status == .done && NotesService.sharedIfLoaded != nil)
                    check("W05 healthy stalled fallback holds retry audio and problem", service.problem(for: id) == StageWatchdog.stallMessage && store.audioURL(for: store.meeting(id: id) ?? meeting) != nil)
                } else {
                    check("F10 explicit cancellation suppresses default handoff", trace.handoffs == 0)
                    check("F11 cancellation preserves exact resumable bytes", preserved() && resumable())
                    check("F12 cancelled owner constructs no late Notes", NotesService.sharedIfLoaded == nil)
                }
                SelfTest.diagnostic("DIARIZATION_TERMINATION_JOIN_TRACE mode=\(mode) handoffs=\(trace.handoffs) nativeEnds=\(joined.ends) preserved=\(preserved()) resumable=\(resumable()) notesLoaded=\(NotesService.sharedIfLoaded != nil)")
                SelfTest.requestTermination()
            }
        }
        SelfTest.diagnostic("DIARIZATION_TERMINATION_INPUT_OK: real synthetic CAF and default pipeline, mode=\(mode)")
        service.process(meeting)
        return true
    }
}

@MainActor
final class DiarizationTerminationTrace {
    var assignedTasks = 0; var endedTasks = 0; var handoffs = 0
    var captureCalls = 0; var firstCapturedCount: Int?
    var checks = 0; var failures = 0; var invalid = false; var replayed = false
    var onFirstProgress: (@MainActor () -> Void)?
    private var heldProgress: (@MainActor () -> Void)?
    private var didHold = false
    func assigned() { assignedTasks += 1 }
    func ended() { endedTasks += 1 }
    func handoff() { handoffs += 1 }
    func captured(count: Int) { captureCalls += 1; if firstCapturedCount == nil { firstCapturedCount = count } }
    func holdFirstProgress(_ operation: @escaping @MainActor () -> Void) -> Bool {
        guard !didHold else { return false }
        didHold = true; heldProgress = operation
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { self.onFirstProgress?() } }
        return true
    }
    func replayHeldProgress() { replayed = true; heldProgress?(); heldProgress = nil }
}

final class DiarizerNativeTrace: @unchecked Sendable {
    struct Snapshot: Sendable { let starts: Int; let ends: Int; let active: Int; let successes: Int }
    private let lock = NSLock()
    private var starts = 0; private var ends = 0; private var successes = 0
    func nativeEntered() { lock.lock(); starts += 1; lock.unlock() }
    func nativeReturned(succeeded: Bool) { lock.lock(); ends += 1; if succeeded { successes += 1 }; lock.unlock() }
    func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return Snapshot(starts: starts, ends: ends, active: starts - ends, successes: successes) }
}
